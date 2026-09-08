---
title: "The Desktop Looked Right: 2,093 Parse Errors a Boot, and 10.9 Seconds That Weren't Doing Anything"
published: false
description: "A Debian desktop that looked and behaved correctly was throwing 2,093 CSS parse errors per boot and spending 10.9 seconds of a 39-second boot waiting on nothing. Neither is visible on screen. Both are in the journal, and both were introduced by the script that was supposed to set the machine up."
tags: debian, linux, claudecode, devops
cover_image: https://raw.githubusercontent.com/xbill9/chromeos-boot/main/docs/feedback-loops/cover.33f0beb1.jpg
---

This article walks through one afternoon of Debian system management, in which the machine turned out to have been reporting two of its own defects continuously, for as long as it had been configured, to nobody.

**Debian tells you almost everything. It just does not tell you on screen.** The kernel ring buffer, the systemd journal, `systemd-analyze`, `dpkg`, `apt-cache policy` and `/sys` between them describe the state of the machine in far more detail than any settings panel — and a desktop can look completely correct while those sources are recording a failure a few hundred times a minute.

What that gap creates is a feedback loop with a missing half. The machine emits the evidence; nothing reads it. The two defects below had both been present since the day the setup script was written, both were sitting in plain text in the journal, and neither was discoverable from the desktop:

- The GTK theme was **discarded at parse time**, 161 rules per application launch,
  **2,093 log lines in the boot I measured**, while reporting success and looking
  approximately right.
- **10.9 seconds of a 39.3-second boot** were spent waiting for something nothing
  was waiting for.

Both were introduced by `flex`, the script in this repository whose job is to configure the machine:

https://github.com/xbill9/chromeos-boot

## The Machine

One laptop, measured on 2026-09-08:

| | |
|---|---|
| Hardware | Lenovo Yoga 9i, Intel CometLake-H, NVIDIA GTX 1650 Ti Mobile |
| OS | Debian 13 (trixie) |
| Kernel | `7.1.8+deb13-amd64` (from `trixie-backports`) |
| Desktop | GNOME 48, Wayland, gdm3 |
| GTK | `libgtk-4-1` **4.18.6**, `libadwaita-1-0` **1.7.6** |

That GTK version is the whole article, and nothing on the desktop ever mentions it.

## At This Point You Should Have

- A Debian desktop you have customised with something — a script, a dotfile
  repo, a settings panel, an afternoon of `gsettings` — and that appears to work
- `sudo`, or membership of `adm` / `systemd-journal`. **Check this first**, for
  reasons in Step 0
- `systemd-analyze`, `journalctl`, `dpkg`, `apt-cache` — all base install
- Somewhere durable to write findings that is not your shell scrollback

None of the diagnosis below changes anything. Steps 0 through 3 are reads.

## Step 0 — Find Out Whether You Can Read the Evidence At All

This step exists because the investigation nearly started with a wrong answer.

The first `journalctl` run reported four errors this boot, all of them GNOME session scopes failing to start, and that looked like the whole picture. It was not the whole picture. It was the picture available to an unprivileged user:

```bash
id
```

```plaintext
uid=1000(xbill) gid=1000(xbill) groups=1000(xbill),24(cdrom),25(floppy),
27(sudo),29(audio),30(dip),44(video),46(plugdev),100(users),101(netdev),
102(scanner),106(bluetooth),108(lpadmin),989(docker),992(render)
```

**No `adm`, no `systemd-journal`.** Without either, `journalctl` silently narrows to your own user journal rather than refusing — you get output, it is correctly formatted, and it is a small fraction of what happened. The kernel buffer is closed off separately:

```bash
dmesg | tail -3
```

```plaintext
dmesg: read kernel buffer failed: Operation not permitted
```

The difference between the two views on this machine:

| View | `err` and above, this boot |
|---|---|
| Unprivileged `journalctl` | **4** |
| `sudo journalctl` | **17** |

Four against seventeen, and nothing in the first view indicates the other thirteen exist. **A loop that reads a filtered log converges on a wrong answer confidently**, which is worse than not reading it. Add yourself to `adm` and log back in, or accept that everything downstream needs `sudo` — but decide it deliberately, because the failure mode is silence, not an error.

## Step 1 — Count Before You Read

`err` and above is where people look, and on this machine it was almost entirely a red herring. The volume was one priority down:

```bash
sudo journalctl -b -p err     --no-pager -q | wc -l
sudo journalctl -b -p warning --no-pager -q | wc -l
```

```plaintext
17
1032
```

A thousand warnings is too many to read, so collapse them into shapes first. Normalising the numbers and hex out of each message turns a thousand lines into a histogram of distinct problems:

```bash
sudo journalctl -b -p warning --no-pager -q -o cat \
  | sed 's/[0-9a-f]\{8,\}/HEX/g; s/[0-9]\+/N/g' \
  | sort | uniq -c | sort -rn | head -5
```

```plaintext
    795 Theme parser error: libadwaita.css:N:N-N: Unknown @ rule
     27 blacklist: Duplicate blacklisted hash bin:HEX
     24 Can't update stage views actor unnamed [StBin] is on because it needs an allocation.
     10 Theme parser error: libadwaita-tweaks.css:N:N-N: Unknown @ rule
      7 Unable to get default source
```

**805 of the 1,032 warnings on this system were one defect.** It had never appeared on screen, in any settings panel, or in the output of the script that caused it — which had reported, and still reports, success.

## Step 2 — Attribute the Message Before You Believe the Field

The obvious next question is which program is producing them, and the obvious way to ask is the journal's own `_COMM` field. That gives a wrong answer, and it is worth showing because the same trap applies to any log the agent will read.

```plaintext
  1288  cat
   322  gnome-control-c
   161  gnome-software
   161  xdg-desktop-por
   161  mutter-x11-fram
```

`cat` is not a GTK application and does not parse stylesheets. Pulling one of those 1,288 records apart explains it:

```plaintext
_COMM=cat  _PID=11105  _EXE=/usr/bin/cat
MESSAGE=(chrome:11097): Gtk-WARNING **: 09:20:36.757: Theme parser error: ...
```

The webapp launchers this repository installs pipe their stderr, so journald attributes the line to the process that *wrote* it rather than the process that *produced* it. The real emitter is in the message payload, in the `(name:pid)` prefix that GLib puts there.

**The structured field describes the plumbing; the unstructured payload describes the event.** Grouping by `_COMM` credits 1,288 parse errors to `cat` and hides Chrome entirely. Parse the prefix instead:

```bash
sudo journalctl -b -q -o cat | grep "Theme parser error: libadwaita" \
  | sed -E 's/^\(([a-zA-Z0-9_.-]+):[0-9]+\).*/\1/' | sort | uniq -c | sort -rn
```

Corrected, the emitters are `gnome-control-center`, `gnome-software`, `xdg-desktop-portal-gtk`, `mutter-x11-frames` and Chrome — every GTK4 process on the system, each one failing identically, every time it starts.

## What the Theme Declared, and What GTK Served

161 distinct parse failures per process: 159 in `libadwaita.css`, 2 in `libadwaita-tweaks.css`. At `warning` and above each one appeared exactly five times — 159 × 5 = 795, 2 × 5 = 10 — one set per GTK4 process running at boot. Across all priorities, including the Chrome instances started later from the shelf, **2,093 lines in one boot.**

The message names the construct:

```plaintext
Theme parser error: libadwaita.css:94:1-7: Unknown @ rule
```

Columns 1-7 of line 94:

```css
@media (prefers-color-scheme: dark) { @define-color window_bg_color #222226; ... }
```

`@media`. GTK's CSS parser is not a browser's, and **GTK 4.18 does not implement `@media`.** It reports the rule as unknown and discards the entire block.

Which block is discarded matters more than the noise. `flex` installs adw-gtk3 from the upstream release tarball, pinned:

```bash
grep ADW_VERSION flex
```

```plaintext
ADW_VERSION=${ADW_VERSION:-v6.5}
```

Upstream's own release notes, read in order, are unambiguous about what that pin means:

| Release | Upstream's note | `@media` in the GTK4 CSS |
|---|---|---|
| **v5.7** | "New release for GNOME 48 and libadwaita 1.7" | **0** |
| v6.3 | last release before the change | 0 |
| **v6.4** | **"The GTK4 theme now requires GTK 4.20 or later."** | 3 |
| **v6.5** | "Release for GNOME 50." | **159** |

The machine runs GNOME 48, GTK 4.18.6 and libadwaita 1.7.6. The pin was `v6.5` — GNOME 50, GTK 4.20+. There is a release named for this exact platform, in upstream's own words, and it is two major versions below the pin.

`git log` says the pin was never wrong *later*; it was wrong from the start:

```bash
git log --oneline -L58,58:flex
```

```plaintext
12a0ddc Add flex: Debian desktop customization to mimic ChromeOS Flex
+ADW_VERSION=${ADW_VERSION:-v6.5}
```

The newest release at the time, taken as the right one because it was newest, never checked against the desktop it had to run on.

## Why Nothing Looked Wrong

A theme silently dropping 159 rule blocks should be visible, and it was not. Two reasons, and the second is the expensive one.

First, libadwaita applications largely do not use the GTK theme at all — they carry their own stylesheet and follow `color-scheme` directly. Most of the desktop stayed dark because most of the desktop was never asking the theme.

Second, and much worse:

```bash
T=~/.local/share/themes
for f in $(cd $T/adw-gtk3/gtk-4.0 && find . -type f | sort); do
  cmp -s "$T/adw-gtk3/gtk-4.0/$f" "$T/adw-gtk3-dark/gtk-4.0/$f" \
    && echo "identical: $f" || echo "DIFFERS:   $f"
done
```

```plaintext
identical: ./assets/bullet-symbolic.svg
identical: ./assets/check-symbolic.svg
identical: ./assets/dash-symbolic.svg
identical: ./assets/devel-symbolic.svg
identical: ./gtk.css
identical: ./gtk-dark.css
identical: ./libadwaita.css
identical: ./libadwaita-tweaks.css
```

At v6.5, **every one of the eight files under `gtk-4.0/` is byte-identical between `adw-gtk3` and `adw-gtk3-dark`.** From v6.4 upstream stopped shipping two GTK4 stylesheets. There is one file, and dark is selected at runtime by the `@media` query — the query GTK 4.18 throws away.

So the dark theme's own file defines the light value, unconditionally, and the dark value only inside the block that never executes:

```plaintext
adw-gtk3-dark/gtk-4.0/libadwaita.css:62:
    @define-color window_bg_color #fafafb;      <- light, applied
inside @media (prefers-color-scheme: dark):
    @define-color window_bg_color #222226;      <- dark, discarded
```

**46 of the 154 `@define-color` rules in that file are inside `@media` blocks.** All 46 were being dropped. And because the two GTK4 trees are identical, `set-mode.sh` — the helper this repository installs specifically to flip light and dark — could not change a GTK4 application's palette at all. It flipped a setting between two names that pointed at the same bytes.

That is the shape of the whole problem: **the setting declared a dark theme, and the filesystem served a light one.** Nothing in the declaring layer knows what the serving layer did with it, and the only place the two are compared is the log.

## The Fix, and the Second Bug It Exposed

Moving the pin to `v5.7` is one line. Applying it was not, and the reason is a bug the first bug was hiding.

```bash
bash flex theme
```

```plaintext
==> theme: adw-gtk3 v5.7 into /home/xbill/.local/share/themes
    already installed -- skipping
```

The stage's idempotence guard tested that the theme *directories existed*, not which version was in them. That is fine while the pin is right and fatal once it is wrong: **correcting the pin was a no-op, because the evidence of the bad install was also the thing that suppressed the repair.** Every re-run confirmed the wrong theme.

Idempotence has to mean "on the pinned version", not "something is there". The guard now records what it installed and compares:

```sh
if [ -d "$THEMES/adw-gtk3-dark" ] && [ -d "$THEMES/adw-gtk3" ] \
   && [ "`cat "$THEMES/.adw-gtk3-version" 2>/dev/null`" = "$ADW_VERSION" ] ; then
  step "already installed at $ADW_VERSION -- skipping"
  return
fi
```

It also removes the old tree before extracting rather than unpacking over it. The layout changed between the two releases — v6.3 added `libadwaita.css` and `libadwaita-tweaks.css` to `gtk-4.0`, and v5.7 has neither — so extracting v5.7 on top of v6.5 would have left both files orphaned on disk, imported by nothing and still found by anything globbing the directory.

Re-run, and the two themes are two themes again:

```plaintext
adw-gtk3/gtk-4.0/gtk.css:      @define-color window_bg_color #fafafb;
adw-gtk3-dark/gtk-4.0/gtk.css: @define-color window_bg_color #222226;
```

```bash
sudo journalctl -b -o cat -q | grep -c "Theme parser error"
```

```plaintext
0
```

**2,093 to 0**, and `warning`-and-above for the whole system fell from 1,032 to 151. ✅

## The Same Loop, Three More Times

One defect found this way could be luck. The value is in the loop, so it is worth running it against three other subsystems — each with its own evidence source, and each teaching something different about how to read one.

### Drivers: the error you must refuse to act on

The kernel log's firmware section looks alarming and mostly is not:

```bash
sudo journalctl -b -k -q -o cat | grep -i iwlwifi
```

```plaintext
iwlwifi 0000:00:14.3: Detected Intel(R) Wi-Fi 6 AX201 160MHz
iwlwifi 0000:00:14.3: firmware: failed to load iwl-debug-yoyo.bin (-2)
iwlwifi 0000:00:14.3: firmware: failed to load iwl-debug-yoyo.bin (-2)
iwlwifi 0000:00:14.3: firmware: failed to load iwl-debug-yoyo.bin (-2)
iwlwifi 0000:00:14.3: loaded firmware version 77.2753b721.0 QuZ-a0-hr-b0-77.ucode
```

Three failures, then success. `iwl-debug-yoyo.bin` is an optional debug blob that Debian does not ship and the driver does not need; the device is working. **An agent that treats "failed" as actionable installs packages to fix a working radio.** The correction is cheap and general: read the lines *after* the error before acting on it, and prefer the state of the device to the wording of the log.

The genuinely interesting driver finding was on the other side, and it is a non-event worth confirming rather than assuming:

```bash
sudo dkms status
```

```plaintext
nvidia/610.57.04, 6.12.107+deb13-amd64, x86_64: installed
nvidia/610.57.04, 7.1.8+deb13-amd64, x86_64: installed
```

This machine runs a **backports kernel** with an out-of-tree NVIDIA module, which is the configuration most likely to break on an upgrade. DKMS had rebuilt against both kernels, and both header packages are present — so the next kernel will not silently land without a GPU. The taint word says exactly what is loaded and why:

```bash
cat /proc/sys/kernel/tainted     # 12289 -> bits 0, 12, 13
mokutil --sb-state               # SecureBoot disabled
```

Proprietary, out-of-tree, unsigned — all three expected here, and all three would be worth an alarm on a machine where Secure Boot was on.

### Packages: what apt declares against what apt will serve

`apt` will happily tell you a package is available without telling you it will never choose it:

```bash
apt-cache policy | grep -A1 backports | head -4
```

```plaintext
 100 https://deb.debian.org/debian trixie-backports/main amd64 Packages
     release o=Debian Backports,a=stable-backports,n=trixie-backports
```

**Priority 100 against 500 for everything else.** Backports is enabled and will never be selected automatically — which is correct, and is also why the running kernel had to be asked for by name. Six third-party origins are configured on this box (Docker, Chrome, cloud-sdk, CUDA, Claude Desktop, and backports), and `apt-cache policy` is the only place that relationship is written down.

The rest of the package state was one line of debris and one pending upgrade:

```plaintext
rc  linux-image-6.12.94+deb13-amd64   (removed, config files remain)
containerd.io  2.3.4 -> 2.3.5  (upgradable)
```

Neither is a problem. Both are the kind of thing that is invisible until something asks.

### Tuning: the wait that nothing was waiting for

`systemd-analyze` is the least-used excellent tool on a Debian desktop, because it does not report which unit is *slow* — it reports which unit is *in the way*:

```bash
systemd-analyze critical-chain
```

```plaintext
graphical.target @10.626s
└─power-profiles-daemon.service @10.547s +78ms
  └─multi-user.target @10.545s
    └─docker.service @9.507s +1.037s
      └─network-online.target @9.505s
        └─NetworkManager-wait-online.service @1.730s +7.774s
```

**7.774 seconds, on the path to the desktop appearing, spent blocking until the network was routable** — because `docker.service` asks for `network-online.target` and `NetworkManager-wait-online` is what satisfies it. Docker does not need a routable address at start; it needs one when a container asks. The dependency is a default, not a decision.

And one phase up, the loader was carrying a 5-second GRUB menu nobody reads — on a machine whose own repository already ships `boot-splash.sh` to remove it, documented as installed-but-never-run.

Both changed, one reboot, measured:

| phase | before | after | delta | |
|---|---|---|---|---|
| firmware | 16.064s | 14.448s | −1.616s | (not touched) |
| loader | 8.014s | 2.776s | **−5.238s** | `GRUB_TIMEOUT` 5 to 0 |
| kernel | 4.617s | 4.978s | +0.361s | (not touched) |
| userspace | 10.626s | 4.941s | **−5.685s** | `wait-online` disabled |
| **total** | **39.324s** | **27.144s** | **−12.180s** | |

**The attributable figure is −10.9 s, not −12.180 s**, and the table says why. Firmware and kernel are phases nothing in this change touches, and they moved by −1.255 s between the two runs on their own. That is the run-to-run noise of the measurement, and it is the reason the two columns cannot simply be subtracted: *a change measured against the previous boot is measured against time as well.* One boot either side is a weak design, and the honest claim is a bound — around eleven seconds, of which 5.238 s and 5.685 s land in exactly the two phases that were altered.

`network-online.target` is still reached, incidentally. It is reached at **@1.720 s instead of @9.505 s**, because nothing is now blocking on it. Docker started clean.

### And the loop immediately found the next thing

```bash
systemd-analyze blame | head -3
```

```plaintext
3.303s nvidia-persistenced.service
2.689s plymouth-quit-wait.service
2.208s thermald.service
```

`nvidia-persistenced` is now **3.303 s of a 4.941 s userspace boot** and sits on the critical chain where `wait-online` used to. That is not a disappointment; it is the loop working. Removing the largest cost promotes the next one into view, and it was invisible while a 7.8-second wait was in front of it. ✅

## Where the Agent Actually Fits

Nothing above required a capability Debian was missing. Every number came from `journalctl`, `systemd-analyze`, `dpkg`, `dkms`, `apt-cache` and `cmp` — all of them installed, all of them documented, none of them new. The evidence had been there, in the same files, since the machine was configured.

What was missing was the other half of the loop: **something willing to read a thousand warnings, at the moment they stop being free to ignore.**

That is a specific job, and it is worth being precise about which parts of it are the agent's:

- **Reading at volume without triage fatigue.** 1,032 warnings is where a human
  starts sampling. The 805-line defect was in the histogram's first row, and the
  histogram is trivial to build — the reason nobody had built it is that nobody
  had a reason to.
- **Correlating across sources that share no vocabulary.** The finding needed a
  journal message, a CSS file, a `dpkg -l` version, four GitHub release notes and
  a `git log -L` on one line of a shell script. Each is unremarkable alone.
- **Acting, then re-reading.** The fix is only confirmed by the same query that
  found it returning 0 — and by `warning+` dropping 1,032 → 151, which is a
  different check than "the desktop still looks fine".

And the parts that are not:

- **Deciding what is worth fixing.** The `iwlwifi` line is a failure the correct
  action is to ignore. An agent that treats every `error` as work will find
  plenty of it.
- **Anything that touches the boot chain.** `boot-splash.sh` is in this
  repository precisely because it edits GRUB, and this repository deliberately
  never runs it for you. Reading it first was a human decision; so was accepting
  that Docker would now start without waiting for the network.
- **Believing the log's own metadata.** `_COMM` said `cat` 1,288 times.

The loop that produced everything above is four steps and does not need tooling: **read the evidence, form a claim about which layer disagrees with which, change one thing, re-read the same source.** The last step is the one that distinguishes it from a guess, and it is the step a settings panel cannot offer, because a settings panel only ever shows you what was declared.

## Cheat Sheet

Nothing here writes:

```bash
# 0. can you actually see the system's evidence, or only your own?
id | grep -o 'adm\|systemd-journal' || echo "unprivileged view -- use sudo"

# 1. volume first, at warning, not just err
sudo journalctl -b -p err     --no-pager -q | wc -l
sudo journalctl -b -p warning --no-pager -q | wc -l

# 2. collapse a thousand lines into distinct problems
sudo journalctl -b -p warning --no-pager -q -o cat \
  | sed 's/[0-9a-f]\{8,\}/HEX/g; s/[0-9]\+/N/g' \
  | sort | uniq -c | sort -rn | head -20

# 3. attribute by payload, not by _COMM
sudo journalctl -b -q -o cat | grep "<pattern>" \
  | sed -E 's/^\(([a-zA-Z0-9_.-]+):[0-9]+\).*/\1/' | sort | uniq -c | sort -rn

# 4. what is in the way of the desktop -- not what is slow
systemd-analyze
systemd-analyze critical-chain
systemd-analyze blame | head -10

# 5. out-of-tree modules against every installed kernel
sudo dkms status ; cat /proc/sys/kernel/tainted ; mokutil --sb-state

# 6. what apt will actually serve you, priorities included
apt-cache policy ; apt list --upgradable 2>/dev/null ; dpkg -l | grep '^rc'

# 7. re-read the exact query that found it -- this is the step that confirms
```

## Summary

The goal of this article was to find out what a correctly-behaving Debian desktop was failing to mention, and whether reading its own logs systematically would repay the effort. The key to the solution was treating the configuration layer and the serving layer as two separate claims that have to be compared — what `gsettings` declared against what GTK parsed, what a unit file requested against what the boot actually waited for — because every defect found was invisible in the declaring layer and plainly stated in the serving one. The measured results were:

- **2,093 CSS parse errors per boot went to 0.** The theme pin was two major
  versions above what the desktop's GTK could parse, from the first commit that
  introduced it.
- **System-wide `warning`-and-above fell 1,032 → 151.** `err`-and-above stayed at
  17, correctly — none of those were theme-related.
- **46 of 154 `@define-color` rules were being discarded**, and all eight
  `gtk-4.0` files were byte-identical between the light and dark themes, so the
  mode switcher could not change a GTK4 application at all.
- **Boot went 39.324 s → 27.144 s, of which −10.9 s is attributable** — 5.238 s
  of GRUB timeout and 5.685 s of `NetworkManager-wait-online` — with the
  untouched phases drifting −1.255 s as noise.
- **`network-online.target` is now reached at @1.720 s rather than @9.505 s**, and
  Docker starts clean without it being waited on.
- **A second bug was hidden by the first**: the theme stage's idempotence guard
  tested only that files existed, so correcting the pin was a no-op until the
  guard was made version-aware.

Scope: one laptop, one operating system, measured 2026-09-08 on Debian 13 with GNOME 48, GTK 4.18.6 and kernel 7.1.8+deb13-amd64 from backports. The boot figures are **n = 1 on each side** — a single boot before and a single boot after — which is why the attributable claim is stated as a bound rather than a measurement, and the ±1.255 s drift in the two untouched phases is the only estimate of noise available from that design; repeated boots on each configuration are queued and would replace it. The 2,093 → 0 result is not subject to the same weakness, being a count of a deterministic parse failure rather than a timing. Whether any application's appearance visibly changed as a result of the theme fix was **not** measured: the five confirmed emitters prove the file was parsed, not that a user could see the difference, and libadwaita applications never consulted the theme either way. `nvidia-persistenced` at 3.303 s is now the largest item on the critical chain and has not been investigated.

The strategy of reading the system's own evidence at volume, attributing it by payload rather than metadata, changing one thing, and re-running the query that found it was validated with an incremental step by step approach.

*Disclosure: I ran this with Claude Code as the diagnostic agent — it swept the journal, built the histograms, traced the pin to the upstream release notes, wrote the fix and re-measured after the reboot, while I steered and made the calls about what to touch. The commands, the counts and both defects are real and archived in the repository.*
