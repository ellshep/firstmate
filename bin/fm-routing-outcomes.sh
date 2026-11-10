#!/usr/bin/env bash
# Append routing evidence for a dispatched task to this home's private ledger.
# Usage: fm-routing-outcomes.sh launch|finalize <task-id> [<spawn-gen> <stalled> <escalated> <failed> <success>]
# launch reads the resolver record and task metadata after a successful spawn.
# finalize is called after teardown has captured status flags and uses its saved
# spawn generation. Each event is append-only and deduplicated under an OS file
# lock. Missing evidence stays null; brief text and provider replies are never read.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

case "${1:-}" in launch|finalize) ;; *) echo 'usage: fm-routing-outcomes.sh launch|finalize <task-id> [<spawn-gen> <stalled> <escalated> <failed> <success>]' >&2; exit 2 ;; esac
[ "$#" -ge 2 ] || { echo 'fm-routing-outcomes: task id required' >&2; exit 2; }
case "$2" in ''|*[!a-zA-Z0-9_-]*) echo 'fm-routing-outcomes: invalid task id' >&2; exit 2 ;; esac
[ -d "$DATA" ] || { echo 'fm-routing-outcomes: data directory missing' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'fm-routing-outcomes: python3 required' >&2; exit 1; }

python3 - "$1" "$2" "$DATA" "$STATE" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" <<'PY'
import fcntl
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

phase, task, data, state, generation, stalled, escalated, failed, success = sys.argv[1:]
ledger = Path(data) / "routing-outcomes.jsonl"
meta = Path(state) / (task + ".meta")

def lines(path):
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return []

def meta_value(name):
    values = [line.partition("=")[2] for line in lines(meta) if line.startswith(name + "=")]
    return values[-1] if values else None

def flag(value):
    return {"true": True, "false": False}.get(value)

if phase == "launch":
    generation = meta_value("spawn_gen")
    if not generation:
        raise SystemExit("fm-routing-outcomes: spawn generation missing")
    resolution = Path(data) / task / "dispatch-resolution.json"
    try:
        proposal = json.loads(resolution.read_text(encoding="utf-8"))
    except FileNotFoundError:
        proposal = {}
    confidence = proposal.get("confidence")
    pick = proposal.get("jev_pick")
    confidence_floor = proposal.get("qualification_floor", 0.6)
    score = proposal.get("qualification_score", confidence)
    proposed = proposal.get("profile") or {}
    actual = {"harness": meta_value("harness"), "model": meta_value("model"), "effort": meta_value("effort")}
    actual = {key: (None if val in (None, "", "default") else val) for key, val in actual.items()}
    override = meta_value("dispatch_override")
    if not override and proposal.get("status") == "clear":
        if any(actual.get(key) != proposed.get(key) for key in ("harness", "model", "effort")):
            override = "final profile differs from Jev proposal"
    suggestion = proposal.get("suggested_effort")
    difference = None
    if suggestion in ("low", "medium", "high") and actual["effort"] in ("low", "medium", "high") and actual["effort"] != suggestion:
        order = {"low": 0, "medium": 1, "high": 2}
        floor = proposal.get("selected_effort_floor")
        ceiling = proposal.get("selected_effort_ceiling")
        if floor in order and order[suggestion] < order[floor] and actual["effort"] == floor:
            difference = "rule effort floor"
        elif ceiling in order and order[suggestion] > order[ceiling] and actual["effort"] == ceiling:
            difference = "rule effort ceiling"
        elif actual["effort"] == proposed.get("effort"):
            difference = "fixed profile effort"
        else:
            difference = "firstmate final effort differs from Jev suggestion"
    event = {"event": "launch", "task": task, "spawn_gen": generation,
             "at": datetime.now(timezone.utc).isoformat(),
             "resolver_status": proposal.get("status"), "jev_pick": pick,
             "selected_rule": proposal.get("selected_rule"), "confidence": confidence,
             "suggested_effort": proposal.get("suggested_effort"),
             "final": actual, "override_reason": override,
             "effort_difference_reason": difference,
             "would_have_qualified": (score >= confidence_floor if isinstance(score, (int, float)) else None)}
else:
    generation = generation or meta_value("spawn_gen") or "unversioned"
    event = {"event": "outcome", "task": task, "spawn_gen": generation,
             "at": datetime.now(timezone.utc).isoformat(),
             "review_rounds": None, "stalled": flag(stalled),
             "escalated": flag(escalated), "failed": flag(failed),
             "success": flag(success), "review_cost": None}

fd = os.open(ledger, os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, "r+", encoding="utf-8") as stream:
    fcntl.flock(stream, fcntl.LOCK_EX)
    content = stream.read()
    seen = []
    for raw in content.splitlines():
        try:
            old = json.loads(raw)
        except ValueError:
            continue
        seen.append(old)
    if phase == "finalize":
        # Relaunch changes the current meta generation without making a new
        # routing decision. Attach the outcome to the latest open launch.
        open_launches = []
        launches = []
        for old in seen:
            if old.get("task") != task:
                continue
            key = old.get("spawn_gen")
            if old.get("event") == "launch":
                open_launches.append(key)
                launches.append(key)
            elif old.get("event") == "outcome" and key in open_launches:
                open_launches.remove(key)
        if open_launches:
            event["spawn_gen"] = open_launches[-1]
        elif launches:
            event["spawn_gen"] = launches[-1]
        spend = Path(data) / "pipeline-spend.jsonl"
        for raw in lines(spend):
            try:
                row = json.loads(raw)
            except ValueError:
                continue
            if row.get("task") == task and row.get("spawn_gen") in (generation, event["spawn_gen"]):
                review = next((p for p in row.get("purposes", []) if p.get("purpose") == "review"), None)
                event["review_rounds"] = review.get("invocations") if review else (0 if row.get("source") == "no-mistakes-state" else None)
    for old in seen:
        if old.get("event") == event["event"] and old.get("task") == task and old.get("spawn_gen") == event["spawn_gen"]:
            raise SystemExit(0)
    encoded = json.dumps(event, separators=(",", ":"), ensure_ascii=False) + "\n"
    if content and not content.endswith("\n"):
        stream.write("\n")
    stream.write(encoded)
    stream.flush()
    os.fsync(stream.fileno())
PY
