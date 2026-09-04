# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Two **unrelated** Bash scripts that share a repo and a theme, not one tool with two
modes. Do not factor out "shared" helpers between them; the duplicated `log`/`warn`/`die`
block is deliberate.

- `stage` — bootstraps a fresh Crostini container from a private GCS bucket. Must stay
  dependency-free: it runs where nothing is installed yet.
- `flex` — turns a stock Debian 13 / GNOME 48 desktop into a ChromeOS Flex lookalike.
  Standalone; no bucket, no gcloud.

## Verification

There is no build, no test framework, no linter config and no CI. **Idempotence is the
test**: every stage is re-runnable, and re-running is how a failed stage is repaired.
Anything you add must preserve that.

Static checks worth running after an edit: `bash -n flex` and `shellcheck -S warning flex stage`
(both clean today).

## Shell style

Match the surrounding file; these differ from common Bash advice on purpose.

- **No top-level `set -e`/`set -euo pipefail`** in `flex` or `stage`. Stages degrade
  non-fatally (no sudo, no network → `warn` and continue), which requires commands to be
  allowed to fail. Use explicit `|| die`, `|| warn`, `|| return`. The embedded helper
  scripts in heredocs *do* set it — that is correct, they are separate programs.
- **Backticks, not `$( )`**, in the top-level scripts. `$( )` appears only inside heredoc'd helpers.
- `printf`, never `echo`, for user-facing output. Use the `log`/`step`/`warn`/`die` helpers.
- 2-space indent, no tabs. `case`-based option parsing, not `getopts`.
- **ASCII in the scripts**: `--` for dashes. The README uses real em dashes. Keep that split.
- British spelling in prose and comments (`colour`, `centred`), but gsettings/GNOME key
  names keep their upstream American spelling (`color-scheme`, `accent-color`).
- Comments explain *why*, including rejected alternatives. This is the dominant
  characteristic of the codebase — match the density, do not strip it.

## Adding or changing a `flex` stage

Four places must stay in sync, and three of them fail silently:

1. The `STAGES` string (line ~39) — dispatch is `"stage_$s"` by string match.
2. A `stage_<name>` function.
3. A column-80 banner comment with the name right-aligned.
4. A matching undo in `do_revert`, or revert leaves debris.

`bash flex revert` **resets to GNOME defaults, it does not restore** prior values —
nothing is snapshotted. Treat it as destructive to the user's own customization.

Alt+1..9 in `stage_keys` is positionally coupled to the `favs` list in `stage_look`:
inserting a web app shifts every shortcut after it out by one.

## Gotchas

- `stage` must be run with process substitution — `bash <(curl -sSL ...)`, never
  `curl | bash`. The script would occupy stdin, which `gcloud auth login` needs.
- `flex` is GNOME + Wayland + gdm3 only. Wayland cannot restart gnome-shell in place, so
  shelf, themes and app grid changes need a full log out/in; wallpaper and keybindings are live.
- `stage_shelf` sets `enabled-extensions` wholesale, which disables any other extension.
- `flex` depends on upstream layouts that can rot: the pinned `ADW_VERSION`, the Papirus
  master tarball, the extensions.gnome.org API, gstatic icon URLs.

## Docs

`README.md` and the prose in `docs/` track the scripts — when behaviour changes, update
them in the same commit.

**Exception:** `docs/evidence/*.txt` are frozen snapshots taken for a published article and
are already stale relative to the scripts. Never refresh or auto-sync them.

## Commits

Imperative mood, sentence case, no trailing period, no `feat:`/`fix:` prefixes. Subjects
state the reason, not just the change ("Use process substitution so stdin stays free for
gcloud auth login"). Bodies are substantial, wrapped at ~76 chars, and explain trade-offs.
