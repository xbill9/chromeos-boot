---
title: "ChromeOS Lookalikes, Two Ways: One With Drivers, One Without"
published: false
description: "chromeos-boot holds two unrelated scripts under one name: stage seeds a real Crostini container from a private bucket, flex skins a bare-metal Debian desktop to look like one. The split exists because Crostini's guest kernel can't load the NVIDIA driver."
tags: chromeos, linux, debian, gnome
cover_image: https://raw.githubusercontent.com/xbill9/chromeos-boot/main/docs/cover-stage-vs-flex.da9dad60.jpg
---

This article covers two scripts that live in the same repository for the same underlying reason — getting a Linux box to behave like a Chromebook — and that end up doing almost nothing alike, because they solve that problem for two different machines.

https://github.com/xbill9/chromeos-boot

#### Two Scripts, One Theme

`chromeos-boot` is not one tool with two modes. It is two standalone scripts that happen to share a repo and a name:

- **`stage`** — brings a fresh ChromeOS Linux (Crostini) *container* up from nothing, when everything else it needs lives in a private Cloud Storage bucket.
- **`flex`** — turns a stock Debian *desktop* into a ChromeOS Flex lookalike: shelf, web apps, keybindings, wallpaper. No bucket, no gcloud, nothing private.

`stage` gets a machine to where it can read the bucket. `flex` makes a machine look like the thing it is imitating — and that word "imitating" only applies to one of them. `stage` runs inside an actual Crostini container, on actual ChromeOS; it has nothing to fake. `flex` runs on a desktop that gave up ChromeOS entirely, so everything about the look is manufactured. Two ChromeOS lookalikes, and only one of them is actually pretending.

#### Why Two, Not One

The reason there's a machine running `flex` at all is that Crostini's Linux environment cannot load the NVIDIA driver, and that's a kernel problem before it's a permissions one.

Crostini's container doesn't run on the ChromeOS kernel directly. Enabling Linux spins up a lightweight VM (Termina) with its own guest kernel, one that Google builds, signs, and ships as part of the OS image — and your Debian container runs inside that VM, sharing its kernel rather than bringing one of its own. The NVIDIA driver isn't a userspace package; the installer's whole job is to compile `nvidia.ko` against the exact kernel that's running and load it with `insmod`. Termina's kernel has no headers shipped for that build, no writable path to drop a module into `/lib/modules` that survives the next ChromeOS update, and no interest in accepting an unsigned out-of-tree module on a kernel that's otherwise locked down by verified boot.

Even past the module problem, there's no card to attach it to. Graphics inside Crostini go through virtio-gpu — the VM sees a paravirtualized display device good enough for compositing and OpenGL/Vulkan passthrough, not the raw PCI device a discrete GPU actually is. The NVIDIA driver wants to bind directly to that PCI device. Crostini never hands it one.

So the fix was to stop going through ChromeOS for this at all: put Debian directly on the laptop's metal, where `apt install nvidia-driver` is building against a kernel you actually control, against a GPU that's actually visible on the PCI bus. That solves the driver problem and creates the one `flex` exists to solve — a stock Debian/GNOME desktop looks and behaves nothing like ChromeOS, and none of what came free inside Crostini comes free here. `flex` puts the shelf, the Google web apps, the keybindings, and the wallpaper back by hand.

`stage` and `flex` are answers to two different questions, not two takes on one. `stage` is what you run *because* you're still inside ChromeOS. `flex` is what you run *because* the kernel made you leave.

#### stage: Staging a Fresh Crostini Container

**At this point you should have** a brand-new Crostini container — the default state after enabling Linux on a Chromebook — and nothing else. No `git`, no `gcloud`, nothing installed.

That is a chicken-and-egg problem: reading the private bucket needs `gcloud`, and a bare container has no `gcloud`. `stage` is the one piece that has to be fetchable without credentials, so it is the only thing in this workflow that lives outside the bucket, pasted in or pulled straight from GitHub:

```sh
bash <(curl -sSL https://raw.githubusercontent.com/xbill9/chromeos-boot/main/stage)
```

Process substitution rather than a pipe is deliberate. `curl ... | bash` hands the script to bash on **stdin**, which is the same stdin `gcloud auth login` needs to read answers from; the login then fails or silently eats the rest of the script. `bash <(curl ...)` passes it as a file descriptor and leaves stdin attached to the terminal.

What it does, in order:

1. Installs the Google Cloud CLI from the tarball into `$HOME` — no sudo, no apt, no keyring.
2. Logs in, opening a browser tab. Crostini hands that URL to the ChromeOS browser, which is already signed in, so this is usually two clicks.
3. Copies `nnn` out of the bucket into `~/bin` and runs it, which fetches everything else — scripts, dotfiles.
4. Replaces the tarball with the apt-managed `google-cloud-cli` in `/usr/bin`, then deletes `~/google-cloud-sdk`.

Step 1's tarball is not the copy meant to stick around — it exists only to read the bucket once, before apt is reachable. Step 4 swaps it for the package apt will keep current, and is non-fatal: without sudo, or with apt unreachable, `stage` warns and leaves the tarball in place rather than failing the run.

Four commands finish the job, the last two coming from the `.bashrc` that step 3 just fetched:

```sh
bash <(curl -sSL https://raw.githubusercontent.com/xbill9/chromeos-boot/main/stage)
exec bash -l
bootstrap
bootstrap code
```

`stage` never asks what kind of hardware it is running on, because it doesn't need to know. Everything it touches — the bucket, `gcloud`, the dotfiles — is the same regardless of the laptop underneath. That is the shape of a script solving a *credentials* problem, not a *hardware* one.

#### flex: Skinning a Stock Debian Desktop

**At this point you should have** Debian 13 (trixie) with GNOME 48, installed on real hardware — not a container. `flex` is written from, and matches, the customization actually run on a Yoga 9 with an NVIDIA GPU.

```console
$ bash flex -l
pkgs
theme
icons
shelf
webapps
appgrid
look
keys
helpers
wallpaper
```

Ten stages, run in that order by default, or individually to repair one without redoing the rest:

```console
$ bash flex -h

Turn a stock Debian 13 (trixie) / GNOME 48 desktop into a ChromeOS Flex
lookalike.

Companion to `stage`.  `stage` gets a machine to where it can read the
private bucket; `flex` makes the machine look like the thing it is imitating:
a bottom shelf, the Google web apps as first-class icons, ChromeOS
keybindings, a pruned app grid, and a matching pair of wallpapers.

usage: bash flex [--light|--dark]        everything (dark unless told otherwise)
       bash flex -l                      list the stages
       bash flex <stage> [<stage>...]    run only those
       bash flex revert                  undo it
```

Nothing here needs root except `pkgs` (apt, non-fatal without sudo), and everything it creates lives under `$HOME`.

#### The Ten Stages, Briefly

- **`pkgs`** — Roboto, gnome-tweaks, and Chrome if no Chromium-family browser is already there. The only stage that touches apt.
- **`theme`** — adw-gtk3, light and dark, from the upstream tarball (trixie ships no package for it), so GTK3 apps match the libadwaita GTK4 ones.
- **`icons`** — Papirus and Papirus-Dark, user-level. ~60MB, the slower of the two heavyweight stages.
- **`shelf`** — installs dash-to-panel in place of the packaged dash-to-dock, because only dash-to-panel merges the taskbar and system tray into one bar — the ChromeOS shelf is one bar, not two. Bottom, 56px, 75% opacity, Google-Blue running-app dots, Alt+1–9 for the first nine pinned apps. The per-monitor layout is resolved through Mutter's `DisplayConfig` at run time rather than a hardcoded panel ID, so the same script works on a laptop panel and an external monitor without editing.
- **`webapps`** — the nine Google apps (Gmail, Calendar, Drive, Docs, Sheets, Keep, Photos, Maps, YouTube) as windowless `--app=` launchers, each with its own shelf icon fetched from gstatic with a favicon-service fallback.
- **`appgrid`** — hides the apps ChromeOS doesn't have (LibreOffice, xterm, Disk Utility, and 30-odd others) by shadowing each system `.desktop` file with a copy carrying `NoDisplay=true`. A copy, not a stub, so MIME associations and "Open with" keep working. Nothing is uninstalled.
- **`look`** — Roboto as the UI/document/titlebar font, blue accent, no hot corners, time-only clock, one workspace, shelf favorites pinned.
- **`keys`** — Caps Lock becomes Super, the ChromeOS Launcher key. Alt handles window minimize/maximize/tile; Alt+Tab cycles windows rather than app groups (which move to Super+Tab); Ctrl+F5 is overview; Ctrl+Shift+F5 is screenshot; Ctrl+Shift+Q signs out; Ctrl+Alt+T opens a terminal.
- **`helpers`** — installs `set-mode.sh`, `gen_wallpaper.py`, and `boot-splash.sh` under `~/.local/share/chromeos-flex/`.
- **`wallpaper`** — renders both wallpaper variants with a hand-rolled PNG encoder (no PIL, no numpy on a stock desktop) — a diagonal gradient, four Google-palette blobs with a quadratic falloff, and an ordered dither to stop a 2560px gradient banding.

Wayland can't restart `gnome-shell` in place, so the shelf, the GTK theme, and the app grid only take effect after a full log out and back in. The wallpaper and the keybindings are live immediately.

#### Flipping Light and Dark Without Rerunning Everything

The look is roughly fifteen `gsettings` calls that only make sense moving together — color scheme, GTK theme, icon theme, both wallpaper keys, the lock screen, and eight dash-to-panel colors. `helpers` installs `set-mode.sh` once so that switching modes afterward doesn't mean rerunning the whole script:

```console
$ ~/.local/share/chromeos-flex/set-mode.sh light
switched to light
$ ~/.local/share/chromeos-flex/set-mode.sh
current: 'prefer-light'
  gtk-theme  'adw-gtk3'
  icon-theme 'Papirus'
  wallpaper  'file:///home/xbill/.local/share/backgrounds/chromeos-element-light.png'
```

#### boot-splash.sh: Installed, Not Run

`helpers` writes one more file: `boot-splash.sh`, which edits `/etc/default/grub` to kill the boot menu and hand off to the Plymouth splash trixie already ships. `flex` drops it on disk and stops — it's the only piece of either script that touches the boot chain, it needs root, and GRUB is not something to hand to a stage list without reading it first.

It's not really a speed fix. On the machine it was written for, boot ran about 44 seconds, and roughly 30 of that was firmware and the boot loader before GRUB even started — killing the GRUB timeout only claws back the last 5 seconds or so. What it actually buys is continuity: no text menu flashing past on the way to the desktop, same as an actual Chromebook.

#### Where They're Alike

Different problems, same habits. Both scripts:

| | |
|---|---|
| **Stages** | Broken into named, independently runnable steps (`bootstrap <stage>` / `bash flex <stage>`) |
| **Idempotent** | Re-running is how a half-finished run gets repaired, not something to avoid |
| **Listable** | `bootstrap -l` / `bash flex -l` print the stage names before you commit to any of them |
| **Self-documenting** | Usage lives in a comment block at the top of the file, read back out with `-h`/`--help` |
| **Fail soft** | A missing prerequisite warns and skips rather than aborting the rest of the run |
| **No secrets on the command line** | `stage`'s bucket name isn't sensitive — IAM gates the objects, not the name — and `flex` needs no credentials at all |

#### Where They Differ

| | `stage` | `flex` |
|---|---|---|
| **Target** | A Crostini *container* | A bare-metal Debian *desktop* |
| **Needs** | `gcloud`, an authorized Google account, a private bucket | Nothing — no bucket, no login, no network dependency beyond the packages it fetches |
| **Privilege** | Runs entirely unprivileged; the apt-managed `gcloud` swap is the one non-fatal exception | Only `pkgs` touches `sudo`/apt; the boot splash needs root but is never auto-run |
| **Scope** | Bootstraps a dev environment: language runtimes, Docker, cloud and agent CLIs | Cosmetic and GNOME-settings only: theme, shelf, keybindings, wallpaper |
| **State model** | Additive — there is no `stage revert` | Explicit `bash flex revert`, which *resets* touched settings to GNOME defaults rather than restoring whatever was there before |
| **Hardware awareness** | None — the same script regardless of what's underneath | Written for, and against, one specific machine's GPU and monitor, generalized via Mutter's `DisplayConfig` rather than hardcoded |
| **Why it exists** | Reading credentials before credentials exist | Recreating what real ChromeOS gave up when the GPU drove the OS choice |

#### Summary

The goal here was to get a real NVIDIA driver stack under a ChromeOS-shaped workflow, without giving up the parts of ChromeOS that make a laptop pleasant to use day to day. The key to the solution was accepting that this is two separate problems, not one script with a hardware flag: `stage` solves *getting credentials onto a machine that has none*, and `flex` solves *making a desktop look like ChromeOS after leaving ChromeOS entirely* — for the same underlying reason, on two different machines, sharing nothing but a repo and a theme.

The strategy for making Linux look like ChromeOS — once inside a sandboxed container, once on the bare metal underneath it — was validated with an incremental, stage-by-stage approach on both sides.
