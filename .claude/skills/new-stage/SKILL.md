---
name: new-stage
description: Add a new stage to the flex script, wiring up all four places that must stay in sync (STAGES, the stage_ function, the banner comment, and do_revert). Use when adding, renaming, or removing a flex stage.
---

# Adding a stage to `flex`

Dispatch is `for s in $STAGES ; do wants "$s" && "stage_$s" ; done` — a string match. A
stage that is defined but not listed never runs, and a stage listed but not defined dies
with "command not found". Neither is caught by any test.

Take the stage name from `$ARGUMENTS` if given; otherwise ask.

## 1. Read first

Read `flex` around the `STAGES` line and read two existing stages that resemble the new
one — one that touches gsettings and one that writes files under `$HOME`. Match their
shape rather than inventing one.

## 2. The four edits

**a. `STAGES`** (line ~39). Order is execution order, and it matters: `pkgs` first because
later stages need what it installs, `wallpaper` last because it is slow. Insert
accordingly, do not just append.

**b. The banner comment.** A `#` rule padded to exactly column 80 with the name
right-aligned:

```
####################################################################### theme
```

**c. The `stage_<name>` function.** Requirements:

- **Idempotent.** Re-running is how a failed stage is repaired — this is the only
  verification this repo has. Guard file creation, prefer `gsettings set` (naturally
  idempotent), and make downloads skip or overwrite cleanly rather than appending.
- **Non-fatal where it can be.** No sudo, no network, or a missing prerequisite should
  `warn` and `return 0`, not `die`. Only a genuinely unusable state calls `die`. Do not
  add `set -e`.
- Announce with `log`, report each action with `step`.
- Backticks not `$( )`, `printf` not `echo`, 2-space indent, `--` not em dash.

**d. `do_revert`.** Anything written under `$HOME` needs a matching undo, and any
gsettings key you set needs to appear in the reset list for its schema. Missing entries
here are silent — revert simply leaves the debris behind.

Note that revert *resets* to GNOME defaults rather than restoring prior values. Keep that
behaviour; do not add snapshotting to one stage in isolation.

## 3. Check the couplings

- **Alt+1..9**: if the stage touches the `favs` list in `stage_look`, every keyboard
  shortcut after the insertion point shifts by one. Say so explicitly in the commit body —
  commit `1284307` is the precedent for how this is recorded.
- **Extensions**: `stage_shelf` writes `enabled-extensions` wholesale. If your stage
  enables an extension, it must not be clobbered by shelf running later.
- **Multi-monitor**: dash-to-panel keys are per-monitor JSON keyed by EDID with no global
  fallback.

## 4. Verify

```sh
bash -n flex
shellcheck -S warning flex
bash flex -l                 # the new stage should be listed
bash flex <name>             # run it alone
bash flex <name>             # run it again -- must be a clean no-op or a clean repeat
bash flex revert             # then confirm the stage's traces are gone
```

The second run is the real test. If it errors, duplicates an entry, or appends to a file,
the stage is not idempotent yet.

## 5. Documentation

Update the stage list and any affected prose in `README.md` in the same commit. Do **not**
touch `docs/evidence/*.txt` — those are frozen article snapshots.
