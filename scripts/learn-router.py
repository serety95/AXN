#!/usr/bin/env python3
"""Zero-dependency Expected-Cost & ROI EMA routing weight learner for AXN.

Reads telemetry JSON via --ingest-stdin (or replays routing-ledger.jsonl),
validates schema/types/sanitization allowlists, rejects symlinks, tracks
per-tier scores, sample counts, and timestamps with cold-start acceleration
and staleness decay, minimizes expected cost under task-specific safety floors
in --recommend, aggregates instinct lift & sanitized failure signatures for
--roi-report, locks concurrent writes across POSIX/Windows, and rotates
the ledger.
"""

import argparse
import contextlib
import json
import os
import re
import sys
import tempfile
import time
from datetime import datetime, timezone

try:
    import fcntl  # type: ignore
except ImportError:
    fcntl = None

try:
    import msvcrt  # type: ignore
except ImportError:
    msvcrt = None

TIER_ORDER = ("T0_local", "T1_scout", "T2_builder", "T3_architect")
TIER_ALIASES = {
    "T0": "T0_local",
    "T0_local": "T0_local",
    "T1": "T1_scout",
    "T1_scout": "T1_scout",
    "T2": "T2_builder",
    "T2_builder": "T2_builder",
    "T3": "T3_architect",
    "T3_architect": "T3_architect",
}
DEFAULT_TIER_COSTS = {
    "T0_local": 0.0,
    "T1_scout": 1.0,
    "T2_builder": 20.0,
    "T3_architect": 40.0,
}
HIGH_RISK_TASKS = {"security_audit", "architecture_plan", "race_condition_debug"}
DEFAULT_SAFETY_FLOOR = 0.75
HIGH_RISK_SAFETY_FLOOR = 0.90
STALE_DAYS = 14
SAFE_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
INSTINCT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
FAILURE_SIG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
MAX_INSTINCTS_PER_TURN = 16
MAX_FAILURE_SIGS_PER_TURN = 10
MAX_STDIN_BYTES = 65536
EMA_ALPHA = 0.2
COLD_START_ALPHA = 0.4
COLD_START_SAMPLES = 3
RECOMMEND_MIN_SAMPLES = 3
MAX_LEDGER_LINES = 10000
SCHEMA_VERSION = "2.1.0"


def repo_root_dir():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_tier_costs(config_path=None):
    costs = dict(DEFAULT_TIER_COSTS)
    cfg = config_path or os.path.join(repo_root_dir(), "config", "cost-tiers.yaml")
    if not cfg or os.path.islink(cfg) or not os.path.isfile(cfg):
        return costs
    try:
        with open(cfg, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return costs
    try:
        import yaml  # type: ignore

        data = yaml.safe_load(text)
        tiers = data.get("tiers", {}) if isinstance(data, dict) else {}
        if isinstance(tiers, dict):
            for tier in TIER_ORDER:
                entry = tiers.get(tier)
                if isinstance(entry, dict) and isinstance(entry.get("relative_cost"), (int, float)):
                    val = float(entry["relative_cost"])
                    if val >= 0:
                        costs[tier] = val
            return costs
    except Exception:
        pass

    current_tier = None
    for line in text.splitlines():
        m_tier = re.match(r"^\s{2}(T0_local|T1_scout|T2_builder|T3_architect):\s*$", line)
        if m_tier:
            current_tier = m_tier.group(1)
            continue
        if current_tier:
            if re.match(r"^\S", line):
                current_tier = None
                continue
            m_cost = re.match(r"^\s{4}relative_cost:\s*([0-9]+(?:\.[0-9]+)?)\s*(?:#.*)?$", line)
            if m_cost:
                costs[current_tier] = float(m_cost.group(1))
    return costs


def get_state_dir(override=None):
    state_dir = override or os.environ.get("AXN_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".axn", "state"
    )
    if os.path.islink(state_dir):
        raise ValueError(f"Refusing symlink state directory: {state_dir}")
    os.makedirs(state_dir, exist_ok=True)
    return state_dir


def assert_not_symlink(path):
    if os.path.islink(path):
        raise ValueError(f"Refusing symlink path: {path}")


@contextlib.contextmanager
def state_lock(state_dir, timeout_sec=5.0):
    lock_path = os.path.join(state_dir, ".learn-router.lock")
    assert_not_symlink(lock_path)
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(lock_path, flags, 0o600)
    locked_msvcrt = False
    try:
        if fcntl is not None:
            fcntl.flock(fd, fcntl.LOCK_EX)
        elif msvcrt is not None:
            if os.lseek(fd, 0, os.SEEK_END) == 0:
                os.write(fd, b"\0")
            deadline = time.monotonic() + timeout_sec
            while True:
                try:
                    os.lseek(fd, 0, os.SEEK_SET)
                    msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                    locked_msvcrt = True
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError(f"Timed out waiting for lock: {lock_path}")
                    time.sleep(0.05)
        yield
    finally:
        try:
            if fcntl is not None:
                fcntl.flock(fd, fcntl.LOCK_UN)
            elif msvcrt is not None and locked_msvcrt:
                os.lseek(fd, 0, os.SEEK_SET)
                msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
        finally:
            os.close(fd)


def normalize_tier(raw, field_name):
    if not isinstance(raw, str) or raw not in TIER_ALIASES:
        raise ValueError(f"Invalid {field_name}: {raw!r}")
    return TIER_ALIASES[raw]


def validate_safe_id(raw, field_name):
    if not isinstance(raw, str) or not SAFE_ID_RE.match(raw) or ".." in raw:
        raise ValueError(f"Invalid {field_name}: {raw!r}")
    return raw


def validate_token_list(raw, field_name, pattern, max_items):
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise ValueError(f"Invalid {field_name}: expected list")
    if len(raw) > max_items:
        raise ValueError(f"Too many items in {field_name}: {len(raw)} > {max_items}")
    seen = set()
    cleaned = []
    for item in raw:
        if not isinstance(item, str) or not pattern.match(item) or ".." in item:
            raise ValueError(f"Invalid item in {field_name}: {item!r}")
        if item not in seen:
            seen.add(item)
            cleaned.append(item)
    return cleaned


def parse_iso_utc(ts_str):
    if not isinstance(ts_str, str) or not ts_str:
        return None
    try:
        dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except ValueError:
        return None


def validate_record(data):
    if not isinstance(data, dict):
        raise ValueError("Telemetry payload must be a JSON object")
    task_type = validate_safe_id(data.get("task_type"), "task_type")
    stack = validate_safe_id(data.get("stack", "general"), "stack")

    raw_initial = data.get("initial_tier") or data.get("tier")
    initial_tier = normalize_tier(raw_initial, "initial_tier")
    raw_final = data.get("final_tier") or initial_tier
    final_tier = normalize_tier(raw_final, "final_tier")

    retries = data.get("retries", 0)
    if isinstance(retries, bool) or not isinstance(retries, int) or not (0 <= retries <= 20):
        raise ValueError(f"Invalid retries: {retries!r}")

    escalated = data.get("escalated", False)
    if not isinstance(escalated, bool):
        raise ValueError(f"Invalid escalated flag: {escalated!r}")

    escalated_effort = data.get("escalated_effort", False)
    if not isinstance(escalated_effort, bool):
        raise ValueError(f"Invalid escalated_effort flag: {escalated_effort!r}")

    passed = data.get("passed", False)
    if not isinstance(passed, bool):
        raise ValueError(f"Invalid passed flag: {passed!r}")

    instincts_used = validate_token_list(
        data.get("instincts_used", []),
        "instincts_used",
        INSTINCT_ID_RE,
        MAX_INSTINCTS_PER_TURN,
    )
    failure_signatures = validate_token_list(
        data.get("failure_signatures", []),
        "failure_signatures",
        FAILURE_SIG_RE,
        MAX_FAILURE_SIGS_PER_TURN,
    )

    ts = data.get("ts")
    if ts is None:
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    elif not isinstance(ts, str) or len(ts) > 64 or parse_iso_utc(ts) is None:
        raise ValueError(f"Invalid ts: {ts!r}")

    return {
        "ts": ts,
        "task_type": task_type,
        "stack": stack,
        "initial_tier": initial_tier,
        "final_tier": final_tier,
        "retries": retries,
        "escalated": escalated,
        "escalated_effort": escalated_effort,
        "passed": passed,
        "instincts_used": instincts_used,
        "failure_signatures": failure_signatures,
    }


def safety_floor_for_task(task_type):
    return HIGH_RISK_SAFETY_FLOOR if task_type in HIGH_RISK_TASKS else DEFAULT_SAFETY_FLOOR


def effective_tier_score(entry, now=None):
    score = float(entry.get("score", 0.5))
    samples = int(entry.get("samples", 0))
    last_updated = entry.get("last_updated")
    if samples <= 0 or not last_updated:
        return round(score, 4), False, 0.0
    dt = parse_iso_utc(last_updated)
    if dt is None:
        return round(score, 4), False, 0.0
    now_dt = now or datetime.now(timezone.utc)
    age_days = max(0.0, (now_dt - dt).total_seconds() / 86400.0)
    if age_days >= STALE_DAYS:
        decayed = round(0.5 + (score - 0.5) * 0.5, 4)
        return decayed, True, round(age_days, 2)
    return round(score, 4), False, round(age_days, 2)


def expected_tier_cost(tier, p_eff, costs):
    idx = TIER_ORDER.index(tier)
    base = float(costs[tier])
    esc_tier = TIER_ORDER[idx + 1] if idx + 1 < len(TIER_ORDER) else tier
    esc_cost = float(costs[esc_tier])
    return round(base + (1.0 - p_eff) * esc_cost, 4)


def default_bucket():
    bucket = {
        tier: {"score": 0.5, "samples": 0, "last_updated": None} for tier in TIER_ORDER
    }
    bucket["samples"] = 0
    bucket["recommended_tier"] = None
    return bucket


def compute_recommended_tier(bucket, task_type="", costs=None, now=None):
    costs = costs or load_tier_costs()
    floor = safety_floor_for_task(task_type)
    candidates = []
    for idx, tier in enumerate(TIER_ORDER):
        entry = bucket.get(tier)
        if not isinstance(entry, dict):
            continue
        samples = int(entry.get("samples", 0))
        if samples < RECOMMEND_MIN_SAMPLES:
            continue
        p_eff, _, _ = effective_tier_score(entry, now=now)
        if p_eff < floor:
            continue
        e_cost = expected_tier_cost(tier, p_eff, costs)
        candidates.append((e_cost, idx, tier))
    if not candidates:
        return None
    candidates.sort()
    return candidates[0][2]


def find_reprobe_candidate(bucket, rec_tier, task_type="", now=None):
    floor = safety_floor_for_task(task_type)
    limit_idx = TIER_ORDER.index(rec_tier) if rec_tier in TIER_ORDER else TIER_ORDER.index("T2_builder")
    for tier in TIER_ORDER[:limit_idx]:
        entry = bucket.get(tier)
        if not isinstance(entry, dict):
            continue
        samples = int(entry.get("samples", 0))
        raw_score = float(entry.get("score", 0.5))
        _, stale, _ = effective_tier_score(entry, now=now)
        if samples >= 1 and stale and raw_score < floor:
            return tier
    return None


def normalize_bucket(raw, task_type="", costs=None, now=None):
    bucket = default_bucket()
    if not isinstance(raw, dict):
        return bucket
    for tier in TIER_ORDER:
        val = raw.get(tier)
        if isinstance(val, dict):
            score = float(val.get("score", 0.5))
            samples = int(val.get("samples", 0))
            last_updated = val.get("last_updated")
            if last_updated is not None and parse_iso_utc(last_updated) is None:
                last_updated = None
            bucket[tier] = {
                "score": round(score, 4),
                "samples": max(0, samples),
                "last_updated": last_updated,
            }
        elif isinstance(val, (int, float)) and not isinstance(val, bool):
            bucket[tier] = {"score": round(float(val), 4), "samples": 0, "last_updated": None}
    bucket["samples"] = max(0, int(raw.get("samples", 0)))
    bucket["recommended_tier"] = compute_recommended_tier(
        bucket, task_type=task_type, costs=costs, now=now
    )
    return bucket


def new_weights_doc():
    return {
        "version": SCHEMA_VERSION,
        "alpha": EMA_ALPHA,
        "cold_start_alpha": COLD_START_ALPHA,
        "cold_start_samples": COLD_START_SAMPLES,
        "recommend_min_samples": RECOMMEND_MIN_SAMPLES,
        "safety_floor_default": DEFAULT_SAFETY_FLOOR,
        "safety_floor_high_risk": HIGH_RISK_SAFETY_FLOOR,
        "stale_days": STALE_DAYS,
        "totals": {
            "runs": 0,
            "passes": 0,
            "retries": 0,
            "actual_cost": 0.0,
            "baseline_t2_cost": 0.0,
            "baseline_t3_cost": 0.0,
        },
        "cohort_stats": {
            "with_instincts": {"runs": 0, "passes": 0, "retries": 0},
            "without_instincts": {"runs": 0, "passes": 0, "retries": 0},
        },
        "instinct_stats": {},
        "failure_signatures": {},
        "buckets": {},
    }


def _update_tier_ema(bucket, tier, reward, ts):
    entry = bucket[tier]
    tier_samples = int(entry.get("samples", 0))
    alpha = COLD_START_ALPHA if tier_samples < COLD_START_SAMPLES else EMA_ALPHA
    prev_score = float(entry.get("score", 0.5))
    entry["score"] = round((1.0 - alpha) * prev_score + alpha * reward, 4)
    entry["samples"] = tier_samples + 1
    entry["last_updated"] = ts


def apply_ema(weights, record, costs=None, now=None):
    costs = costs or load_tier_costs()
    task_type = record["task_type"]
    bucket_key = f"{task_type}:{record['stack']}"
    buckets = weights.setdefault("buckets", {})
    bucket = normalize_bucket(buckets.get(bucket_key), task_type=task_type, costs=costs, now=now)
    buckets[bucket_key] = bucket

    init_t = record["initial_tier"]
    final_t = record["final_tier"]
    retries = record["retries"]
    escalated = record["escalated"]
    escalated_effort = record["escalated_effort"]
    passed = record["passed"]
    ts = record["ts"]

    if escalated and init_t != final_t:
        _update_tier_ema(bucket, init_t, 0.0, ts)
        _update_tier_ema(bucket, final_t, 1.0 if passed else 0.0, ts)
        run_cost = float(costs[init_t]) + float(costs[final_t])
    else:
        if passed:
            if escalated_effort:
                reward = max(0.5, 1.0 - 0.1 * retries)
            else:
                reward = max(0.2, 1.0 - 0.2 * retries)
        else:
            reward = 0.0
        _update_tier_ema(bucket, final_t, reward, ts)
        run_cost = float(costs[final_t]) * (1.0 + 0.25 * min(retries, 4))

    bucket["samples"] = int(bucket.get("samples", 0)) + 1
    bucket["recommended_tier"] = compute_recommended_tier(
        bucket, task_type=task_type, costs=costs, now=now
    )

    totals = weights.setdefault("totals", new_weights_doc()["totals"])
    totals["runs"] = int(totals.get("runs", 0)) + 1
    totals["passes"] = int(totals.get("passes", 0)) + (1 if passed else 0)
    totals["retries"] = int(totals.get("retries", 0)) + retries
    totals["actual_cost"] = round(float(totals.get("actual_cost", 0.0)) + run_cost, 4)
    totals["baseline_t2_cost"] = round(
        float(totals.get("baseline_t2_cost", 0.0)) + float(costs["T2_builder"]), 4
    )
    totals["baseline_t3_cost"] = round(
        float(totals.get("baseline_t3_cost", 0.0)) + float(costs["T3_architect"]), 4
    )

    cohorts = weights.setdefault("cohort_stats", new_weights_doc()["cohort_stats"])
    cohort_key = "with_instincts" if record["instincts_used"] else "without_instincts"
    c_entry = cohorts.setdefault(cohort_key, {"runs": 0, "passes": 0, "retries": 0})
    c_entry["runs"] = int(c_entry.get("runs", 0)) + 1
    c_entry["passes"] = int(c_entry.get("passes", 0)) + (1 if passed else 0)
    c_entry["retries"] = int(c_entry.get("retries", 0)) + retries

    inst_stats = weights.setdefault("instinct_stats", {})
    for iid in record["instincts_used"]:
        entry = inst_stats.setdefault(iid, {"uses": 0, "passes": 0, "retries": 0, "last_used": ts})
        entry["uses"] = int(entry.get("uses", 0)) + 1
        entry["passes"] = int(entry.get("passes", 0)) + (1 if passed else 0)
        entry["retries"] = int(entry.get("retries", 0)) + retries
        entry["last_used"] = ts

    fail_sigs = weights.setdefault("failure_signatures", {})
    for sig in record["failure_signatures"]:
        entry = fail_sigs.setdefault(sig, {"count": 0, "last_seen": ts})
        entry["count"] = int(entry.get("count", 0)) + 1
        entry["last_seen"] = ts

    weights["version"] = SCHEMA_VERSION
    weights["alpha"] = EMA_ALPHA
    weights["cold_start_alpha"] = COLD_START_ALPHA
    weights["cold_start_samples"] = COLD_START_SAMPLES
    weights["recommend_min_samples"] = RECOMMEND_MIN_SAMPLES
    weights["safety_floor_default"] = DEFAULT_SAFETY_FLOOR
    weights["safety_floor_high_risk"] = HIGH_RISK_SAFETY_FLOOR
    weights["stale_days"] = STALE_DAYS
    weights["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_weights(weights_path, costs=None, now=None):
    assert_not_symlink(weights_path)
    if not os.path.isfile(weights_path):
        return new_weights_doc()
    with open(weights_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        return new_weights_doc()
    doc = new_weights_doc()
    costs = costs or load_tier_costs()
    raw_buckets = data.get("buckets", {})
    if isinstance(raw_buckets, dict):
        for k, v in raw_buckets.items():
            if isinstance(k, str):
                task_type = k.split(":", 1)[0] if ":" in k else ""
                doc["buckets"][k] = normalize_bucket(v, task_type=task_type, costs=costs, now=now)
    for meta_key in ("totals", "cohort_stats", "instinct_stats", "failure_signatures"):
        if isinstance(data.get(meta_key), dict):
            doc[meta_key] = data[meta_key]
    if "updated_at" in data:
        doc["updated_at"] = data["updated_at"]
    return doc


def atomic_write_json(path, data, state_dir):
    assert_not_symlink(path)
    fd, tmp_path = tempfile.mkstemp(prefix=".weights-", suffix=".tmp", dir=state_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp_path, path)
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise


def append_ledger(ledger_path, record, max_lines=MAX_LEDGER_LINES):
    assert_not_symlink(ledger_path)
    backup_path = f"{ledger_path}.1"
    assert_not_symlink(backup_path)
    if os.path.isfile(ledger_path):
        with open(ledger_path, "r", encoding="utf-8", errors="replace") as fh:
            line_count = sum(1 for _ in fh)
        if line_count >= max_lines:
            os.replace(ledger_path, backup_path)
    with open(ledger_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, sort_keys=True) + "\n")


def ingest_record(state_dir, record, max_ledger_lines=MAX_LEDGER_LINES, costs=None):
    ledger_path = os.path.join(state_dir, "routing-ledger.jsonl")
    weights_path = os.path.join(state_dir, "routing-weights.json")
    costs = costs or load_tier_costs()
    with state_lock(state_dir):
        append_ledger(ledger_path, record, max_lines=max_ledger_lines)
        weights = load_weights(weights_path, costs=costs)
        apply_ema(weights, record, costs=costs)
        atomic_write_json(weights_path, weights, state_dir)
    return weights


def recompute_weights(state_dir, costs=None):
    ledger_path = os.path.join(state_dir, "routing-ledger.jsonl")
    backup_path = f"{ledger_path}.1"
    weights_path = os.path.join(state_dir, "routing-weights.json")
    costs = costs or load_tier_costs()
    with state_lock(state_dir):
        weights = new_weights_doc()
        for path in (backup_path, ledger_path):
            assert_not_symlink(path)
            if os.path.isfile(path):
                with open(path, "r", encoding="utf-8") as fh:
                    for line in fh:
                        line = line.strip()
                        if not line:
                            continue
                        record = validate_record(json.loads(line))
                        apply_ema(weights, record, costs=costs)
        atomic_write_json(weights_path, weights, state_dir)
    return weights


def recommend_tier(state_dir, task_type, stack, costs=None, now=None):
    task_type = validate_safe_id(task_type, "task_type")
    stack = validate_safe_id(stack, "stack")
    costs = costs or load_tier_costs()
    weights_path = os.path.join(state_dir, "routing-weights.json")
    weights = load_weights(weights_path, costs=costs, now=now)
    bucket_key = f"{task_type}:{stack}"
    bucket = weights.get("buckets", {}).get(bucket_key)
    if bucket is None:
        bucket = default_bucket()

    floor = safety_floor_for_task(task_type)
    rec = compute_recommended_tier(bucket, task_type=task_type, costs=costs, now=now)
    reprobe = find_reprobe_candidate(bucket, rec, task_type=task_type, now=now)

    tier_views = {}
    for tier in TIER_ORDER:
        entry = bucket[tier]
        p_eff, stale, age_days = effective_tier_score(entry, now=now)
        e_cost = expected_tier_cost(tier, p_eff, costs)
        samples = int(entry.get("samples", 0))
        tier_views[tier] = {
            "score": float(entry.get("score", 0.5)),
            "effective_score": p_eff,
            "samples": samples,
            "relative_cost": costs[tier],
            "expected_cost": e_cost,
            "eligible": samples >= RECOMMEND_MIN_SAMPLES and p_eff >= floor,
            "stale": stale,
            "age_days": age_days,
            "last_updated": entry.get("last_updated"),
        }

    return {
        "bucket": bucket_key,
        "task_type": task_type,
        "stack": stack,
        "recommended_tier": rec,
        "reprobe_candidate": reprobe,
        "fallback": "config/cost-tiers.yaml",
        "samples": bucket.get("samples", 0),
        "min_tier_samples": RECOMMEND_MIN_SAMPLES,
        "safety_floor": floor,
        "stale_days": STALE_DAYS,
        "tiers": tier_views,
    }


def load_indexed_instincts(index_path=None):
    path = index_path or os.path.join(repo_root_dir(), "instincts", "INDEX.md")
    if not path or os.path.islink(path) or not os.path.isfile(path):
        return []
    ids = []
    seen = set()
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = re.match(r"^\|\s*`([a-z0-9][a-z0-9_-]{0,63})`\s*\|", line.strip())
                if m and m.group(1) not in seen:
                    seen.add(m.group(1))
                    ids.append(m.group(1))
    except OSError:
        return []
    return ids


def generate_roi_report(state_dir, instincts_index=None, costs=None, now=None):
    costs = costs or load_tier_costs()
    weights_path = os.path.join(state_dir, "routing-weights.json")
    weights = load_weights(weights_path, costs=costs, now=now)
    totals = weights.get("totals", {})
    runs = int(totals.get("runs", 0))
    passes = int(totals.get("passes", 0))
    actual_cost = round(float(totals.get("actual_cost", 0.0)), 4)
    base_t2 = round(float(totals.get("baseline_t2_cost", 0.0)), 4)
    base_t3 = round(float(totals.get("baseline_t3_cost", 0.0)), 4)

    savings_t2 = round(base_t2 - actual_cost, 4)
    savings_t3 = round(base_t3 - actual_cost, 4)
    savings_t2_pct = round((savings_t2 / base_t2) * 100.0, 2) if base_t2 > 0 else 0.0
    savings_t3_pct = round((savings_t3 / base_t3) * 100.0, 2) if base_t3 > 0 else 0.0

    cohorts = weights.get("cohort_stats", {})
    with_c = cohorts.get("with_instincts", {"runs": 0, "passes": 0, "retries": 0})
    without_c = cohorts.get("without_instincts", {"runs": 0, "passes": 0, "retries": 0})

    def rate(num, den):
        return round(num / den, 4) if den > 0 else None

    w_runs = int(with_c.get("runs", 0))
    wo_runs = int(without_c.get("runs", 0))
    w_pass_rate = rate(int(with_c.get("passes", 0)), w_runs)
    wo_pass_rate = rate(int(without_c.get("passes", 0)), wo_runs)
    lift = (
        round(w_pass_rate - wo_pass_rate, 4)
        if w_pass_rate is not None and wo_pass_rate is not None
        else None
    )

    inst_stats = weights.get("instinct_stats", {})
    per_instinct = {}
    for iid, st in sorted(inst_stats.items()):
        uses = int(st.get("uses", 0))
        i_pass_rate = rate(int(st.get("passes", 0)), uses)
        per_instinct[iid] = {
            "uses": uses,
            "pass_rate": i_pass_rate,
            "avg_retries": rate(int(st.get("retries", 0)), uses),
            "lift_vs_without_instincts": (
                round(i_pass_rate - wo_pass_rate, 4)
                if i_pass_rate is not None and wo_pass_rate is not None
                else None
            ),
            "last_used": st.get("last_used"),
        }

    indexed_ids = load_indexed_instincts(instincts_index)
    unused_instincts = [iid for iid in indexed_ids if iid not in inst_stats]

    fail_sigs = weights.get("failure_signatures", {})
    promotion_candidates = []
    for sig, info in fail_sigs.items():
        cnt = int(info.get("count", 0))
        if cnt >= 2:
            promotion_candidates.append(
                {"signature": sig, "count": cnt, "last_seen": info.get("last_seen")}
            )
    promotion_candidates.sort(key=lambda item: (-item["count"], item["signature"]))

    stale_reprobe = []
    for b_key, bucket in sorted(weights.get("buckets", {}).items()):
        for tier in TIER_ORDER:
            entry = bucket.get(tier, {})
            if int(entry.get("samples", 0)) <= 0:
                continue
            p_eff, stale, age_days = effective_tier_score(entry, now=now)
            if stale:
                stale_reprobe.append(
                    {
                        "bucket": b_key,
                        "tier": tier,
                        "score": float(entry.get("score", 0.5)),
                        "effective_score": p_eff,
                        "age_days": age_days,
                    }
                )

    return {
        "version": SCHEMA_VERSION,
        "cost_summary": {
            "runs": runs,
            "overall_pass_rate": rate(passes, runs),
            "actual_cost": actual_cost,
            "baseline_t2_cost": base_t2,
            "baseline_t3_cost": base_t3,
            "savings_vs_t2": savings_t2,
            "savings_vs_t2_pct": savings_t2_pct,
            "savings_vs_t3": savings_t3,
            "savings_vs_t3_pct": savings_t3_pct,
        },
        "instinct_roi": {
            "indexed_instincts": indexed_ids,
            "with_instincts_runs": w_runs,
            "with_instincts_pass_rate": w_pass_rate,
            "with_instincts_avg_retries": rate(int(with_c.get("retries", 0)), w_runs),
            "without_instincts_runs": wo_runs,
            "without_instincts_pass_rate": wo_pass_rate,
            "without_instincts_avg_retries": rate(int(without_c.get("retries", 0)), wo_runs),
            "pass_rate_lift": lift,
            "per_instinct": per_instinct,
            "unused_instincts": unused_instincts,
        },
        "failure_promotion_candidates": promotion_candidates,
        "stale_reprobe_candidates": stale_reprobe,
    }


def run_self_test():
    with tempfile.TemporaryDirectory(prefix="axn-learn-router-test-") as tmp:
        costs = dict(DEFAULT_TIER_COSTS)

        # 1. Expected-cost routing: T1 at 0.812 (in [0.75, 0.85)) beats T2 at >=0.90 on non-security
        for retries_val in (0, 0, 1):
            ingest_record(
                tmp,
                validate_record(
                    {
                        "task_type": "lint_fix",
                        "stack": "typescript",
                        "initial_tier": "T1",
                        "final_tier": "T1",
                        "retries": retries_val,
                        "passed": True,
                    }
                ),
                costs=costs,
            )
        for _ in range(3):
            ingest_record(
                tmp,
                validate_record(
                    {
                        "task_type": "lint_fix",
                        "stack": "typescript",
                        "initial_tier": "T2",
                        "final_tier": "T2",
                        "retries": 0,
                        "passed": True,
                    }
                ),
                costs=costs,
            )
        rec = recommend_tier(tmp, "lint_fix", "typescript", costs=costs)
        t1_eff = rec["tiers"]["T1_scout"]["effective_score"]
        t2_eff = rec["tiers"]["T2_builder"]["effective_score"]
        assert DEFAULT_SAFETY_FLOOR <= t1_eff < 0.85, t1_eff
        assert t2_eff >= 0.85, t2_eff
        assert rec["tiers"]["T1_scout"]["expected_cost"] < rec["tiers"]["T2_builder"]["expected_cost"]
        assert rec["recommended_tier"] == "T1_scout", rec

        # 2. High-risk safety floor (0.90): T1 at 0.812 (<0.90) is rejected; T2 >=0.90 is chosen
        for retries_val in (0, 0, 1):
            ingest_record(
                tmp,
                validate_record(
                    {
                        "task_type": "security_audit",
                        "stack": "python",
                        "initial_tier": "T1",
                        "final_tier": "T1",
                        "retries": retries_val,
                        "passed": True,
                    }
                ),
                costs=costs,
            )
        for _ in range(4):
            ingest_record(
                tmp,
                validate_record(
                    {
                        "task_type": "security_audit",
                        "stack": "python",
                        "initial_tier": "T2",
                        "final_tier": "T2",
                        "retries": 0,
                        "passed": True,
                    }
                ),
                costs=costs,
            )
        sec_rec = recommend_tier(tmp, "security_audit", "python", costs=costs)
        assert sec_rec["safety_floor"] == HIGH_RISK_SAFETY_FLOOR
        assert sec_rec["tiers"]["T1_scout"]["eligible"] is False
        assert sec_rec["recommended_tier"] == "T2_builder", sec_rec

        # 3. Staleness decay (>14 days) + reprobe candidate surfacing
        stale_ts = "2026-01-01T00:00:00Z"
        now_ts = datetime(2026, 1, 20, 0, 0, 0, tzinfo=timezone.utc)
        for _ in range(3):
            ingest_record(
                tmp,
                validate_record(
                    {
                        "ts": stale_ts,
                        "task_type": "feature_impl",
                        "stack": "rust",
                        "initial_tier": "T1",
                        "final_tier": "T1",
                        "passed": False,
                        "failure_signatures": ["cargo:.rs"],
                    }
                ),
                costs=costs,
            )
        for _ in range(3):
            ingest_record(
                tmp,
                validate_record(
                    {
                        "ts": "2026-01-19T00:00:00Z",
                        "task_type": "feature_impl",
                        "stack": "rust",
                        "initial_tier": "T2",
                        "final_tier": "T2",
                        "passed": True,
                        "instincts_used": ["bounded-slice-reads"],
                    }
                ),
                costs=costs,
            )
        rust_rec = recommend_tier(tmp, "feature_impl", "rust", costs=costs, now=now_ts)
        assert rust_rec["recommended_tier"] == "T2_builder", rust_rec
        assert rust_rec["reprobe_candidate"] == "T1_scout", rust_rec
        assert rust_rec["tiers"]["T1_scout"]["stale"] is True
        assert rust_rec["tiers"]["T1_scout"]["effective_score"] > rust_rec["tiers"]["T1_scout"]["score"]

        # 4. ROI report: cost savings, instinct lift, unused bloat, failure promotion candidates
        temp_index = os.path.join(tmp, "INDEX.md")
        with open(temp_index, "w", encoding="utf-8") as fh:
            fh.write("| `bounded-slice-reads` | runtime | high | ok |\n")
            fh.write("| `unused-bloat-instinct` | shell | low | unused |\n")
        report = generate_roi_report(tmp, instincts_index=temp_index, costs=costs, now=now_ts)
        assert report["cost_summary"]["runs"] > 0
        assert report["cost_summary"]["savings_vs_t3"] > 0
        assert "unused-bloat-instinct" in report["instinct_roi"]["unused_instincts"]
        assert report["instinct_roi"]["per_instinct"]["bounded-slice-reads"]["uses"] == 3
        assert report["instinct_roi"]["pass_rate_lift"] is not None
        assert report["failure_promotion_candidates"][0]["signature"] == "cargo:.rs"
        assert report["failure_promotion_candidates"][0]["count"] == 3
        assert len(report["stale_reprobe_candidates"]) >= 1

        # 5. Recompute matches live state
        recomputed = recompute_weights(tmp, costs=costs)
        assert recomputed["totals"]["runs"] == report["cost_summary"]["runs"]
        assert recomputed["failure_signatures"]["cargo:.rs"]["count"] == 3

        # 6. Sanitization & validation guards
        for bad in (
            {"task_type": "<explore|implement>", "initial_tier": "T1"},
            {"task_type": "explore", "initial_tier": "T1|T2"},
            {"task_type": "explore", "initial_tier": "T1", "instincts_used": ["../secret"]},
            {"task_type": "explore", "initial_tier": "T1", "instincts_used": ["BadUpper"]},
            {"task_type": "explore", "initial_tier": "T1", "failure_signatures": ["/etc/passwd"]},
            {"task_type": "explore", "initial_tier": "T1", "failure_signatures": ["err:../foo"]},
            {"task_type": "explore", "initial_tier": "T1", "failure_signatures": ["has space"]},
            {"task_type": "explore", "initial_tier": "T1", "instincts_used": [f"id-{i}" for i in range(17)]},
            {"task_type": "explore", "initial_tier": "T1", "failure_signatures": [f"sig:{i}" for i in range(11)]},
        ):
            try:
                validate_record(bad)
                raise AssertionError(f"Expected validation failure for {bad!r}")
            except ValueError:
                pass

        # 7. Ledger rotation
        rot_dir = os.path.join(tmp, "rot")
        os.makedirs(rot_dir, exist_ok=True)
        for _ in range(5):
            ingest_record(
                rot_dir,
                validate_record(
                    {
                        "task_type": "explore",
                        "stack": "go",
                        "initial_tier": "T1",
                        "final_tier": "T1",
                        "passed": True,
                    }
                ),
                max_ledger_lines=3,
                costs=costs,
            )
        assert os.path.isfile(os.path.join(rot_dir, "routing-ledger.jsonl.1"))
        rot_recomputed = recompute_weights(rot_dir, costs=costs)
        assert rot_recomputed["buckets"]["explore:go"]["samples"] == 5

        # 8. Symlink rejection (when OS permits symlink creation)
        sym_target = os.path.join(tmp, "target")
        sym_dir = os.path.join(tmp, "symlink-state")
        os.makedirs(sym_target, exist_ok=True)
        try:
            os.symlink(sym_target, sym_dir, target_is_directory=True)
        except (OSError, NotImplementedError):
            sym_dir = None
        if sym_dir is not None:
            try:
                get_state_dir(override=sym_dir)
                raise AssertionError("Expected symlink state dir rejection")
            except ValueError:
                pass

    print("[PASS] learn-router.py self-test passed")


def main():
    parser = argparse.ArgumentParser(description="AXN Expected-Cost & ROI EMA routing learner")
    parser.add_argument("--ingest-stdin", action="store_true", help="Ingest one telemetry JSON object from stdin")
    parser.add_argument("--recompute", action="store_true", help="Recompute routing-weights.json from ledger")
    parser.add_argument("--summary", action="store_true", help="Print current routing-weights.json")
    parser.add_argument("--recommend", action="store_true", help="Recommend lowest expected-cost safe tier")
    parser.add_argument("--roi-report", action="store_true", help="Print ROI, instinct lift, and failure-promotion report")
    parser.add_argument("--task-type", help="Task type identifier for --recommend")
    parser.add_argument("--stack", default="general", help="Stack identifier for --recommend (default: general)")
    parser.add_argument("--instincts-index", help="Optional path to instincts/INDEX.md for --roi-report")
    parser.add_argument("--self-test", action="store_true", help="Run built-in isolated verification suite")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0

    state_dir = get_state_dir()
    weights_path = os.path.join(state_dir, "routing-weights.json")
    ledger_path = os.path.join(state_dir, "routing-ledger.jsonl")
    assert_not_symlink(ledger_path)
    assert_not_symlink(weights_path)

    if args.ingest_stdin:
        raw = sys.stdin.read(MAX_STDIN_BYTES + 1)
        if len(raw) > MAX_STDIN_BYTES:
            raise ValueError("Stdin telemetry exceeds 64 KiB limit")
        raw = raw.lstrip("\ufeff")
        record = validate_record(json.loads(raw))
        ingest_record(state_dir, record)
    elif args.recompute:
        recompute_weights(state_dir)
    elif args.recommend:
        if not args.task_type:
            raise ValueError("--recommend requires --task-type")
        print(json.dumps(recommend_tier(state_dir, args.task_type, args.stack), indent=2, sort_keys=True))
    elif args.roi_report:
        print(json.dumps(generate_roi_report(state_dir, instincts_index=args.instincts_index), indent=2, sort_keys=True))
    elif args.summary:
        print(json.dumps(load_weights(weights_path), indent=2, sort_keys=True))
    else:
        parser.print_help()
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"[learn-router] error: {exc}", file=sys.stderr)
        sys.exit(1)
