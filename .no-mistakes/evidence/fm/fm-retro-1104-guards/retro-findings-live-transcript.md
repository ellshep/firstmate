# Live CLI transcripts: retro findings 1, 2, 3, 5, 6 (fm/fm-retro-1104-guards)

All runs below invoked the real binaries (bin/fm-tasks-axi.sh, bin/fm-wake-drain.sh,
bin/fm-session-start.sh, bin/fm-supervise-daemon.sh's housekeeping, bin/fm-brief.sh,
bin/fm-promote.sh, bin/fm-spawn.sh) against disposable, throwaway fixtures built for
this run only (temp dirs under /tmp, torn down afterward; a marked `fm-lab-home`
for the fm-spawn.sh case, torn down with `rm -rf` in the same turn). No real fleet,
Herdr session, or operator state was touched.

## Finding 1 — fm-tasks-axi.sh update: append mode + empty/shrink guard, UTF-8 preserved

```
$ fm-tasks-axi.sh show note-1 --json
error: "Unknown flag: --json"
   (confirms the retro's root cause: --json is not a real flag; show --full is)

$ fm-tasks-axi.sh update note-1 --body-file empty.txt
fm-tasks-axi: body file must be a readable nonempty regular file: .../empty.txt   [refused]

$ fm-tasks-axi.sh update note-1 --body-file empty.txt --force-body
fm-tasks-axi: body file must be a readable nonempty regular file: .../empty.txt   [refused; force does not waive nonempty]

$ fm-tasks-axi.sh update note-1 --body-file oneline.txt      # one-line replace of a long note
fm-tasks-axi: replacement body drops more than half the current note; use --append-body or explicit --force-body   [refused]
$ fm-tasks-axi.sh show note-1 --full | grep body:
  body: A long existing note with several important lines and decisions that firstmate must not lose.   [unchanged]

$ fm-tasks-axi.sh update note-1 --append-body append1.txt
ok: updated note-1 (body)
$ fm-tasks-axi.sh show note-1 --full | grep body:
  body: "A long existing note with ... must not lose.\nNew detail learned later."   [old + new preserved]

$ fm-tasks-axi.sh update note-1 --body-file oneline.txt --force-body
ok: updated note-1 (body)
$ fm-tasks-axi.sh show note-1 --full | grep body:
  body: one line   [explicit force allowed the shrink]
```

UTF-8 regression check (round-2 fix: perl decode with no :raw layer corrupting café -> single byte):

```
$ fm-tasks-axi.sh add note-u "Note" --body 'A "quoted" café note with accents.'
$ fm-tasks-axi.sh update note-u --append-body cafe.txt   # "Additional café detail."
$ fm-tasks-axi.sh show note-u --full | grep body: | xxd
00000000: 2020 626f 6479 3a20 2241 205c 2271 756f    body: "A \"quo
00000010: 7465 645c 2220 6361 66c3 a920 6e6f 7465  ted\" caf..  note     <- c3 a9 = correct UTF-8 'é'
00000030: 4164 6469 7469 6f6e 616c 2063 6166 c3a9  Additional caf..      <- c3 a9 = correct UTF-8 'é'
```
No `e9` (corrupted latin-1 byte) anywhere. Byte-exact preservation confirmed both before and after append.

## Finding 2a — fm-wake-drain.sh: open decisions print in full only when changed

```
$ echo 'needs-decision [key=one]: choose first path' > state/decision.status
$ fm-wake-drain.sh                 # 1st drain: NEW -> full print
OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):
...

$ fm-wake-drain.sh                 # 2nd drain: UNCHANGED -> collapses
OPEN DECISIONS: 1 open, unchanged since 2026-11-04T14:48:54-0600; full records in .../state/*.status.
   (full text "choose first path" NOT repeated - grep -c == 0)

$ echo 'needs-decision [key=two]: choose second path' >> state/decision.status
$ fm-wake-drain.sh                 # 3rd drain: CHANGED -> full set re-prints, including the old item
decision [key=one] needs-decision: choose first path
decision [key=two] needs-decision: choose second path
```

## Finding 2b — fm-session-start.sh --reemit: capped section + single deterministic pointer file

Ran via the shipped behavior tests `test_reemit_cue_survives_the_hook_output_preview` and
`test_agents_baseline_stays_at_true_start_and_reemits_on_every_drifted_pi_compact`
(tests/fm-session-start.test.sh), invoked standalone (every other test call in the file
commented out for this run) against the real bin/fm-session-start.sh with a disposable
git+FM_HOME fixture:

```
ok - --reemit puts its read cue in the first 2000 characters and a normal start omits it
ok - true-start AGENTS baselines stay immutable while every drifted Pi compact re-emits the current contract
```
These assert: a >10KB captain.md section is capped at 8192 bytes with a
`[section capped at 8192 bytes; full output: <path>]` pointer, the pointed-at file exists
and is larger than the capped digest, and six successive `--reemit` calls across a drifted
Pi-compact scenario leave exactly ONE `.session-reemit-full.txt` file in state/ (not six).

## Finding 3 — fm-supervise-daemon.sh: escalation names the owning task id

Sourced the daemon's pure functions (the same technique its own test suite uses - the
daemon's main loop is skipped when sourced) and called `housekeeping` directly against a
disposable state dir with a fake tmux:

```
# paused task, fixture: held-w11.status = "paused: holding for the upstream tool release"
$ cat state/.subsuper-escalations
paused 5000s (awaiting external, recheck whether the wait still holds): sess:fm-held-w11 task=held-w11

# captain-held task, fixture: held-w11h.status = "captain-held [key=route]: tracked by task-decision-route"
$ cat state/.subsuper-escalations
captain-held 5000s (awaiting the captain, answer the held decision or release the hold): sess:fm-held-w11h task=held-w11h
```
Both escalation lines now carry `task=<id>` beside the window, closing the retro's
"firstmate searched state/*.meta each time" friction.

## Finding 5 — downgrade requires --mode-reason (fm-brief.sh, fm-promote.sh, fm-spawn.sh)

Registry: `data/projects.md` = `- proj [no-mistakes] - fixture (added 2026-01-01)`.

```
$ fm-brief.sh mr-1 proj --mode direct-PR                         # no reason, standing=no-mistakes
error: --mode direct-PR is weaker than resolved default no-mistakes for proj; pass --mode-reason

$ fm-brief.sh mr-1 proj --mode direct-PR --mode-reason 'firstmate-repo sync, captain approved direct-PR for this one'
scaffolded: .../mr-1/brief.md                                    # succeeds; DOD carries "Mode reason: ..."

$ fm-brief.sh mr-nl proj --mode no-mistakes --mode-reason $'first line\nsecond line'   # NOT a downgrade
error: --mode-reason must be one line                            # unconditional newline check

$ fm-promote.sh scout-1 --mode direct-PR --yolo off               # scout on a no-mistakes project, no reason
error: --mode direct-PR is weaker than resolved default no-mistakes for proj; pass --mode-reason
$ fm-promote.sh scout-1 --mode direct-PR --yolo off --mode-reason 'firstmate-repo sync approved by captain'
promoted scout-1 to ship mode=direct-PR yolo=off
$ cat state/scout-1.meta | grep mode
mode=direct-PR
mode_reason=firstmate-repo sync approved by captain

$ fm-promote.sh scout-2 --mode no-mistakes --yolo off --mode-reason $'first line\nsecond line'  # NOT a downgrade
error: --mode-reason must be one line                            # round-4 fix: unconditional, outside the downgrade branch
$ cat state/scout-2.meta
kind=scout   (unchanged - refused multi-line reason never promoted the task)
```

fm-spawn.sh (driven via a marked disposable lab home per docs/herdr-backend.md's lab
mechanism, with a fake tmux that always exits 1 so nothing actually launches - the
mode-reason guard runs before any backend/tmux work):

```
$ fm-spawn.sh spawn-dev-1 <proj> claude --mode direct-PR --yolo off
error: --mode direct-PR is weaker than resolved default fm-lab-proj...; pass --mode-reason

$ fm-spawn.sh spawn-dev-1 <proj> claude --mode direct-PR --yolo off --mode-reason 'firstmate-repo sync approved'
error: --mode-reason must match the brief's Mode reason line        # brief lacked the matching line

# after adding "Mode reason: firstmate-repo sync approved" to the brief:
$ fm-spawn.sh spawn-dev-1 <proj> claude --mode direct-PR --yolo off --mode-reason 'firstmate-repo sync approved'
(no mode-reason error; fails later only because the fixture's fake tmux always refuses)

$ fm-spawn.sh spawn-dev-2 <proj> claude --mode no-mistakes --yolo off --mode-reason $'first line\nsecond line'  # NOT a downgrade
error: --mode-reason must be one line                                # round-4 fix present in fm-spawn.sh too
(no state/spawn-dev-2.meta written)

$ fm-spawn.sh spawn-scout-1 <proj> claude --scout --mode-reason nope
error: --mode-reason applies only to ship spawns
```

## Finding 6 — generated no-mistakes ship brief embeds the validation continuation

```
$ fm-brief.sh mr-nm proj --mode no-mistakes
scaffolded: .../mr-nm/brief.md
$ sed -n '/# Definition of done/,$p' .../mr-nm/brief.md
...
When the implementation is committed, append `validation-ready [at=<epoch>]: {summary}` to the status file, then run /no-mistakes yourself and continue through its gates.
Route every ask-user finding to firstmate, never pass `--yes`, and report the PR when CI first goes green; the pipeline owns the push.
...
- ask-user findings are never yours to answer: escalate to firstmate ...
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
...
Then append `done [at=<epoch>]: PR {url} checks green` and stop.
```
The worker's own generated brief now contains the exact continuation firstmate previously
had to hand-type after every `validation-ready` status (run no-mistakes, route ask-user to
firstmate, never pass --yes, report the PR when CI first goes green) - confirming the extra
supervisor turn the retro flagged is gone.
