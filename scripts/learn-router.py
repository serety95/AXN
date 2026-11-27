#!/usr/bin/env python3
"""Zero-dependency EMA routing weight learner for AXN.

Reads telemetry JSON via --ingest-stdin (or replays routing-ledger.jsonl),
validates schema/types, rejects symlinks, tracks per-tier scores & samples
with cold-start acceleration, computes recommended_tier, handles cross-tier
vs. in-tier effort escalation, locks concurrent state writes across POSIX/Windows,
rotates the ledger, and exposes --recommend and --self-test modes.
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
SAFE_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
MAX_STDIN_BYTES = 65536
EMA_ALPHA = 0.2
COLD_START_ALPHA = 0.4
COLD_START_SAMPLES = 3
RECOMMEND_MIN_SAMPLES = 3
RECOMMEND_MIN_SCORE = 0.85
MAX_LEDGER_LINES = 10000
SCHEMA_VERSION = "2.0.0"


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
    if not isinstance(raw, str) or not SAFE_ID_RE.match(raw):
        raise ValueError(f"Invalid {field_name}: {raw!r}")
    return raw


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

    ts = data.get("ts")
    if ts is None:
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    elif not isinstance(ts, str) or len(ts) > 64:
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
    }


def default_bucket():
    bucket = {tier: {"score": 0.5, "samples": 0} for tier in TIER_ORDER}
    bucket["samples"] = 0
    bucket["recommended_tier"] = None
    return bucket


def compute_recommended_tier(bucket):
    for tier in TIER_ORDER:
        entry = bucket.get(tier)
        if (
            isinstance(entry, dict)
            and int(entry.get("samples", 0)) >= RECOMMEND_MIN_SAMPLES
            and float(entry.get("score", 0.0)) >= RECOMMEND_MIN_SCORE
        ):
            return tier
    return None


def normalize_bucket(raw):
    bucket = default_bucket()
    if not isinstance(raw, dict):
        return bucket
    for tier in TIER_ORDER:
        val = raw.get(tier)
        if isinstance(val, dict):
            score = float(val.get("score", 0.5))
            samples = int(val.get("samples", 0))
            bucket[tier] = {"score": round(score, 4), "samples": max(0, samples)}
        elif isinstance(val, (int, float)) and not isinstance(val, bool):
            bucket[tier] = {"score": round(float(val), 4), "samples": 0}
    bucket["samples"] = max(0, int(raw.get("samples", 0)))
    bucket["recommended_tier"] = compute_recommended_tier(bucket)
    return bucket


def new_weights_doc():
    return {
        "version": SCHEMA_VERSION,
        "alpha": EMA_ALPHA,
        "cold_start_alpha": COLD_START_ALPHA,
        "cold_start_samples": COLD_START_SAMPLES,
        "recommend_min_samples": RECOMMEND_MIN_SAMPLES,
        "recommend_min_score": RECOMMEND_MIN_SCORE,
        "buckets": {},
    }


def _update_tier_ema(bucket, tier, reward):
    entry = bucket[tier]
    tier_samples = int(entry.get("samples", 0))
    alpha = COLD_START_ALPHA if tier_samples < COLD_START_SAMPLES else EMA_ALPHA
    prev_score = float(entry.get("score", 0.5))
    entry["score"] = round((1.0 - alpha) * prev_score + alpha * reward, 4)
    entry["samples"] = tier_samples + 1


def apply_ema(weights, record):
    bucket_key = f"{record['task_type']}:{record['stack']}"
    buckets = weights.setdefault("buckets", {})
    bucket = normalize_bucket(buckets.get(bucket_key))
    buckets[bucket_key] = bucket

    init_t = record["initial_tier"]
    final_t = record["final_tier"]
    retries = record["retries"]
    escalated = record["escalated"]
    escalated_effort = record["escalated_effort"]
    passed = record["passed"]

    if escalated and init_t != final_t:
        # Cross-tier escalation: penalize initial_tier; reward/penalize final_tier separately.
        _update_tier_ema(bucket, init_t, 0.0)
        _update_tier_ema(bucket, final_t, 1.0 if passed else 0.0)
    else:
        # Same-tier execution (including in-tier effort bumps without cross-tier penalty).
        if passed:
            if escalated_effort:
                reward = max(0.5, 1.0 - 0.1 * retries)
            else:
                reward = max(0.2, 1.0 - 0.2 * retries)
        else:
            reward = 0.0
        _update_tier_ema(bucket, final_t, reward)

    bucket["samples"] = int(bucket.get("samples", 0)) + 1
    bucket["recommended_tier"] = compute_recommended_tier(bucket)
    weights["version"] = SCHEMA_VERSION
    weights["alpha"] = EMA_ALPHA
    weights["cold_start_alpha"] = COLD_START_ALPHA
    weights["cold_start_samples"] = COLD_START_SAMPLES
    weights["recommend_min_samples"] = RECOMMEND_MIN_SAMPLES
    weights["recommend_min_score"] = RECOMMEND_MIN_SCORE
    weights["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_weights(weights_path):
    assert_not_symlink(weights_path)
    if not os.path.isfile(weights_path):
        return new_weights_doc()
    with open(weights_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        return new_weights_doc()
    doc = new_weights_doc()
    raw_buckets = data.get("buckets", {})
    if isinstance(raw_buckets, dict):
        for k, v in raw_buckets.items():
            if isinstance(k, str):
                doc["buckets"][k] = normalize_bucket(v)
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


def ingest_record(state_dir, record, max_ledger_lines=MAX_LEDGER_LINES):
    ledger_path = os.path.join(state_dir, "routing-ledger.jsonl")
    weights_path = os.path.join(state_dir, "routing-weights.json")
    with state_lock(state_dir):
        append_ledger(ledger_path, record, max_lines=max_ledger_lines)
        weights = load_weights(weights_path)
        apply_ema(weights, record)
        atomic_write_json(weights_path, weights, state_dir)
    return weights


def recompute_weights(state_dir):
    ledger_path = os.path.join(state_dir, "routing-ledger.jsonl")
    backup_path = f"{ledger_path}.1"
    weights_path = os.path.join(state_dir, "routing-weights.json")
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
                        apply_ema(weights, record)
        atomic_write_json(weights_path, weights, state_dir)
    return weights


def recommend_tier(state_dir, task_type, stack):
    task_type = validate_safe_id(task_type, "task_type")
    stack = validate_safe_id(stack, "stack")
    weights_path = os.path.join(state_dir, "routing-weights.json")
    weights = load_weights(weights_path)
    bucket_key = f"{task_type}:{stack}"
    bucket = weights.get("buckets", {}).get(bucket_key)
    if bucket is None:
        bucket = default_bucket()
    rec = bucket.get("recommended_tier")
    return {
        "bucket": bucket_key,
        "task_type": task_type,
        "stack": stack,
        "recommended_tier": rec,
        "fallback": "config/cost-tiers.yaml",
        "samples": bucket.get("samples", 0),
        "min_tier_samples": RECOMMEND_MIN_SAMPLES,
        "min_tier_score": RECOMMEND_MIN_SCORE,
        "tiers": {tier: bucket[tier] for tier in TIER_ORDER},
    }


def run_self_test():
    with tempfile.TemporaryDirectory(prefix="axn-learn-router-test-") as tmp:
        # 1. Cold-start: 3 consecutive passes at T1_scout unlock recommended_tier == T1_scout
        for idx in range(3):
            w = ingest_record(
                tmp,
                validate_record(
                    {
                        "task_type": "lint_fix",
                        "stack": "typescript",
                        "initial_tier": "T1",
                        "final_tier": "T1",
                        "retries": 0,
                        "escalated": False,
                        "escalated_effort": False,
                        "passed": True,
                    }
                ),
            )
            bucket = w["buckets"]["lint_fix:typescript"]
            if idx < 2:
                assert bucket["recommended_tier"] is None, "Should not recommend before 3 samples"
        assert bucket["T1_scout"]["samples"] == 3
        assert bucket["T1_scout"]["score"] >= RECOMMEND_MIN_SCORE, bucket["T1_scout"]
        assert bucket["recommended_tier"] == "T1_scout"

        rec = recommend_tier(tmp, "lint_fix", "typescript")
        assert rec["recommended_tier"] == "T1_scout", rec
        cold = recommend_tier(tmp, "feature_impl", "rust")
        assert cold["recommended_tier"] is None and cold["samples"] == 0, cold

        # 2. Cross-tier escalation: penalizes T1_scout, rewards T2_builder
        w = ingest_record(
            tmp,
            validate_record(
                {
                    "task_type": "feature_impl",
                    "stack": "python",
                    "initial_tier": "T1_scout",
                    "final_tier": "T2_builder",
                    "retries": 2,
                    "escalated": True,
                    "escalated_effort": True,
                    "passed": True,
                }
            ),
        )
        fb = w["buckets"]["feature_impl:python"]
        assert fb["T1_scout"]["score"] < 0.5 and fb["T1_scout"]["samples"] == 1
        assert fb["T2_builder"]["score"] > 0.5 and fb["T2_builder"]["samples"] == 1

        # 3. In-tier effort bump: no cross-tier 0.0 penalty even if escalated=true & same tier
        before_score = fb["T2_builder"]["score"]
        w = ingest_record(
            tmp,
            validate_record(
                {
                    "task_type": "feature_impl",
                    "stack": "python",
                    "initial_tier": "T2_builder",
                    "final_tier": "T2_builder",
                    "retries": 1,
                    "escalated": False,
                    "escalated_effort": True,
                    "passed": True,
                }
            ),
        )
        fb = w["buckets"]["feature_impl:python"]
        assert fb["T2_builder"]["score"] >= before_score, fb

        # 4. Recompute reproduces weights from ledger
        recomputed = recompute_weights(tmp)
        assert (
            recomputed["buckets"]["lint_fix:typescript"]["T1_scout"]
            == w["buckets"]["lint_fix:typescript"]["T1_scout"]
        )
        assert (
            recomputed["buckets"]["feature_impl:python"]["T2_builder"]
            == w["buckets"]["feature_impl:python"]["T2_builder"]
        )

        # 5. Ledger rotation at custom max_ledger_lines
        rot_dir = os.path.join(tmp, "rot")
        os.makedirs(rot_dir, exist_ok=True)
        for i in range(5):
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
            )
        assert os.path.isfile(os.path.join(rot_dir, "routing-ledger.jsonl.1"))
        with open(os.path.join(rot_dir, "routing-ledger.jsonl"), "r", encoding="utf-8") as fh:
            assert len(fh.readlines()) == 2
        rot_recomputed = recompute_weights(rot_dir)
        assert rot_recomputed["buckets"]["explore:go"]["samples"] == 5

        # 6. Validation guards
        for bad in (
            {"task_type": "<explore|implement>", "initial_tier": "T1"},
            {"task_type": "explore", "initial_tier": "T1|T2"},
            {"task_type": "explore", "initial_tier": "T1", "retries": 99},
            {"task_type": "explore", "initial_tier": "T1", "escalated_effort": "yes"},
        ):
            try:
                validate_record(bad)
                raise AssertionError(f"Expected validation failure for {bad!r}")
            except ValueError:
                pass

        # 7. Symlink rejection (when OS permits symlink creation)
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
    parser = argparse.ArgumentParser(description="AXN EMA routing weight learner")
    parser.add_argument(
        "--ingest-stdin",
        action="store_true",
        help="Ingest one telemetry JSON object from stdin",
    )
    parser.add_argument(
        "--recompute",
        action="store_true",
        help="Recompute routing-weights.json from routing-ledger.jsonl",
    )
    parser.add_argument(
        "--summary",
        action="store_true",
        help="Print current routing-weights.json",
    )
    parser.add_argument(
        "--recommend",
        action="store_true",
        help="Recommend tier for --task-type and --stack from learned weights",
    )
    parser.add_argument(
        "--task-type",
        help="Task type identifier for --recommend (matches config/cost-tiers.yaml)",
    )
    parser.add_argument(
        "--stack",
        default="general",
        help="Stack identifier for --recommend (default: general)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run built-in isolated verification suite",
    )
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
