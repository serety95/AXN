#!/usr/bin/env python3
"""Zero-dependency EMA routing weight learner for AXN.

Reads telemetry JSON via --ingest-stdin (or replays routing-ledger.jsonl),
validates schema/types, rejects symlinks, fixes escalation attribution
(penalizing initial_tier on retries/escalation and rewarding final_tier on pass),
and atomically writes routing-weights.json under AXN_STATE_DIR.
"""

import argparse
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone

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


def get_state_dir():
    state_dir = os.environ.get("AXN_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".axn", "state"
    )
    if os.path.islink(state_dir):
        raise ValueError(f"Refusing symlink state directory: {state_dir}")
    os.makedirs(state_dir, exist_ok=True)
    return state_dir


def assert_not_symlink(path):
    if os.path.islink(path):
        raise ValueError(f"Refusing symlink path: {path}")


def normalize_tier(raw, field_name):
    if not isinstance(raw, str) or raw not in TIER_ALIASES:
        raise ValueError(f"Invalid {field_name}: {raw!r}")
    return TIER_ALIASES[raw]


def validate_record(data):
    if not isinstance(data, dict):
        raise ValueError("Telemetry payload must be a JSON object")
    task_type = data.get("task_type")
    if not isinstance(task_type, str) or not SAFE_ID_RE.match(task_type):
        raise ValueError(f"Invalid task_type: {task_type!r}")
    stack = data.get("stack", "general")
    if not isinstance(stack, str) or not SAFE_ID_RE.match(stack):
        raise ValueError(f"Invalid stack: {stack!r}")

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

    passed = data.get("passed", False)
    if not isinstance(passed, bool):
        raise ValueError(f"Invalid passed flag: {passed!r}")

    return {
        "ts": data.get("ts") or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "task_type": task_type,
        "stack": stack,
        "initial_tier": initial_tier,
        "final_tier": final_tier,
        "retries": retries,
        "escalated": escalated,
        "passed": passed,
    }


def apply_ema(weights, record):
    bucket_key = f"{record['task_type']}:{record['stack']}"
    buckets = weights.setdefault("buckets", {})
    scores = buckets.setdefault(
        bucket_key,
        {"T0_local": 0.5, "T1_scout": 0.5, "T2_builder": 0.5, "T3_architect": 0.5, "samples": 0},
    )

    init_t = record["initial_tier"]
    final_t = record["final_tier"]
    retries = record["retries"]
    escalated = record["escalated"]
    passed = record["passed"]

    if escalated and init_t != final_t:
        # Penalize initial_tier for failing and needing escalation; reward/penalize final_tier separately.
        init_reward = 0.0
        scores[init_t] = round((1.0 - EMA_ALPHA) * scores[init_t] + EMA_ALPHA * init_reward, 4)
        final_reward = 1.0 if passed else 0.0
        scores[final_t] = round((1.0 - EMA_ALPHA) * scores[final_t] + EMA_ALPHA * final_reward, 4)
    else:
        if passed:
            reward = max(0.2, 1.0 - 0.2 * retries)
        else:
            reward = 0.0
        scores[final_t] = round((1.0 - EMA_ALPHA) * scores[final_t] + EMA_ALPHA * reward, 4)

    scores["samples"] = int(scores.get("samples", 0)) + 1
    weights["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_weights(weights_path):
    assert_not_symlink(weights_path)
    if not os.path.isfile(weights_path):
        return {"version": "1.0.0", "alpha": EMA_ALPHA, "buckets": {}}
    with open(weights_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        return {"version": "1.0.0", "alpha": EMA_ALPHA, "buckets": {}}
    return data


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


def main():
    parser = argparse.ArgumentParser(description="AXN EMA routing weight learner")
    parser.add_argument("--ingest-stdin", action="store_true", help="Ingest one telemetry JSON object from stdin")
    parser.add_argument("--recompute", action="store_true", help="Recompute routing-weights.json from routing-ledger.jsonl")
    parser.add_argument("--summary", action="store_true", help="Print current routing-weights.json")
    args = parser.parse_args()

    state_dir = get_state_dir()
    ledger_path = os.path.join(state_dir, "routing-ledger.jsonl")
    weights_path = os.path.join(state_dir, "routing-weights.json")
    assert_not_symlink(ledger_path)
    assert_not_symlink(weights_path)

    if args.ingest_stdin:
        raw = sys.stdin.read(MAX_STDIN_BYTES + 1)
        if len(raw) > MAX_STDIN_BYTES:
            raise ValueError("Stdin telemetry exceeds 64 KiB limit")
        raw = raw.lstrip("\ufeff")
        record = validate_record(json.loads(raw))
        with open(ledger_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, sort_keys=True) + "\n")
        weights = load_weights(weights_path)
        apply_ema(weights, record)
        atomic_write_json(weights_path, weights, state_dir)
    elif args.recompute:
        weights = {"version": "1.0.0", "alpha": EMA_ALPHA, "buckets": {}}
        if os.path.isfile(ledger_path):
            with open(ledger_path, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    record = validate_record(json.loads(line))
                    apply_ema(weights, record)
        atomic_write_json(weights_path, weights, state_dir)
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
