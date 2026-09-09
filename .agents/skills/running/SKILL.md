---
name: running
description: >-
  Survey AI and tooling processes running on this Mac.
  Use when the captain invokes /running or asks what AI, MCP, or tooling servers are running, what is listening, or whether leftover processes are holding ports.
user-invocable: true
metadata:
  internal: true
---

# running

Show the captain what AI and tooling processes are running on this Mac, grouped by what owns them, and whether anything leftover is holding a port.
`bin/fm-running.sh` owns every detection rule, grouping walk, port listing, and orphan heuristic.
This skill only runs that command and relays the result.

## What it does

1. **Run the survey.**
   From this firstmate checkout, run `bin/fm-running.sh`.
   Pass `--all` only when the captain asked for every non-system process or invoked `/running --all`.
   The script's header and `--help` own flags, filters, and output shape.
   Do not add grep, `ps`, or `lsof` of your own, and do not re-match, regroup, or second-guess what the script printed.

2. **Report outcomes, not the dump.**
   Read the output, then tell the captain in plain language per `AGENTS.md` section 9: what is running, which app owns the tool servers, which ports are held, and whether anything is wrong.
   Name processes, apps, ports, working directories, and leftovers in the captain's nouns.
   Do not paste the raw survey back into chat.

3. **Call out leftovers without touching them.**
   If the script flagged a stale or orphaned process, say so, give the reason it printed, and recommend the exact stop command it offered.
   Never stop, kill, or signal any process unless the captain has just given that explicit word for that process.
   Offering the stop command is fine.
   Running it is not.
