---
name: running
description: >-
  Survey processes, memory, and swap on this Mac.
  Use for /running, slow or lagging computers, memory or swap use, AI or tooling servers, listening ports, and leftover processes.
user-invocable: true
metadata:
  internal: true
---

# running

Show the captain what is using memory and swap, what AI and tooling processes are running, and whether anything leftover is holding a port.
`bin/fm-running.sh` owns the memory calculations, detection rules, grouping walk, port listing, and orphan heuristic.
This skill only runs that command and relays the result.

## What it does

1. **Run the survey.**
   From this firstmate checkout, run `bin/fm-running.sh`.
   Pass `--all` only when the captain asked for every non-system process or invoked `/running --all`.
   The script's header and `--help` own flags, filters, and output shape.
   Do not add grep, `ps`, or `lsof` of your own, and do not re-match, regroup, or second-guess what the script printed.

2. **Report outcomes, not the dump.**
   Read the output, then tell the captain in plain language per `AGENTS.md` section 9: RAM used and total, memory pressure, swap used and total, top memory-consuming apps with process counts, what is running, which app owns the tool servers, which ports are held, and whether anything is wrong.
   Name processes, apps, ports, working directories, and leftovers in the captain's nouns.
   Do not paste the raw survey back into chat.

3. **Call out leftovers without touching them.**
   If the script flagged a stale or orphaned process, say so, give the reason it printed, and recommend the exact stop command it offered.
   Never stop, kill, or signal any process unless the captain has just given that explicit word for that process.
   Offering the stop command is fine.
   Running it is not.
