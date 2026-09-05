# chromeos-boot

Two unrelated scripts that share a name because they share a theme: getting a
Linux box to behave like a Chromebook.

- **`stage`** — bring a fresh ChromeOS Linux (Crostini) *container* up from
  nothing, when the things you want to install live in a **private** Cloud
  Storage bucket.
- **`flex`** — turn a stock Debian *desktop* into a ChromeOS Flex lookalike:
  shelf, web apps, keybindings, wallpaper. No bucket, no gcloud, nothing
  private — this one is standalone.

## stage

That is a chicken-and-egg problem: reading the bucket needs `gcloud`, and a
bare container has no `gcloud`. This script is the one piece that has to be
fetchable without credentials, so it lives here instead of in the bucket.

### Use

```sh
bash <(curl -sSL https://raw.githubusercontent.com/xbill9/chromeos-boot/main/stage)
```

No `git` required — `curl` is enough, so there is nothing to `apt-get install`
first.

Process substitution rather than a pipe is deliberate. `curl ... | bash` hands
the script to bash on **stdin**, which is the same stdin `gcloud auth login`
needs to read your answers from; the login then fails or silently eats the rest
of the script. `bash <(curl ...)` passes it as a file descriptor instead and
leaves stdin attached to your terminal.

If your shell has no process substitution, download and run in two steps:

```sh
curl -sSL https://raw.githubusercontent.com/xbill9/chromeos-boot/main/stage -o /tmp/stage
bash /tmp/stage
```

### Full sequence

`stage` leaves you with a container that can read the bucket. Four commands
take it the rest of the way:

```sh
bash <(curl -sSL https://raw.githubusercontent.com/xbill9/chromeos-boot/main/stage)
exec bash -l
bootstrap
bootstrap code
```

- **`stage`** — gcloud, login, then `~/bin` and the dotfiles out of the bucket.
- **`exec bash -l`** — load-bearing, and easy to skip. `bootstrap` is a shell
  function defined in the `.bashrc` that `stage` has just fetched, so it does
  not exist until a new login shell reads it.
- **`bootstrap`** — apt packages, node, python, rust, go, docker, aws and the
  agent CLIs. Every stage is idempotent, so re-running is how you repair one
  that failed; `bootstrap <stage>` runs a single one and `bootstrap -l` lists
  them. The python stage compiles CPython and is slow.
- **`bootstrap code`** — clones the repos. Kept out of the default set because
  it takes a while.

Two things then need the steps above to have finished:

- **Log out and back in.** The docker stage adds you to the `docker` group,
  which a session that is already running will not pick up.
- **Re-run `nnn`.** A couple of the scripts in `~/bin` are symlinks into a
  cloned repo rather than copies from the bucket, so they cannot be linked
  until `bootstrap code` has cloned it. `nnn` warns and skips them until then.

### What it does


1. Installs the Google Cloud CLI from the tarball into `$HOME` — **no sudo,
   no apt, no keyring setup**.
2. Logs you in, opening a browser tab. Crostini hands the URL to the ChromeOS
   browser you are already signed into.
3. Copies `nnn` out of the bucket into `~/bin` and runs it, which fetches
   everything else.
4. Replaces the tarball with the apt-managed `google-cloud-cli` in `/usr/bin`,
   then deletes `~/google-cloud-sdk`.

It is idempotent: existing `gcloud` and an active login are detected and
skipped, so re-run it to repair a half-finished container.

### Why gcloud is installed twice

The tarball is the only kind of `gcloud` a bare container can install: no sudo,
no keyring, no apt repo to add — and adding one needs `gnupg`, which may not be
there yet either. It exists to read the bucket once, and is deliberately never
added to `PATH`.

It is not the copy you want to keep. Step 4 adds Google's apt repo and installs
`google-cloud-cli` into `/usr/bin`, which is what everything downstream expects
and what gets updated along with the rest of the machine, and then removes
`~/google-cloud-sdk`. This used to be left to the `bootstrap` function in the
fetched `.bashrc`; `stage` now does it, so `bootstrap`'s `gcloud` stage finds
the CLI already in place and does nothing.

Step 4 is non-fatal. Without `sudo`, or with apt unreachable, it warns, keeps
the tarball and leaves the job to `bootstrap gcloud`.

Credentials live in `~/.config/gcloud`, a separate directory shared by both
copies, so you log in exactly once and removing the tarball does not log you
out.

### Bucket

Defaults to the stage bucket; pass another as the first argument, or set
`BUCKET`. The name is not sensitive - the bucket is private and IAM gates every
object in it, so knowing the name gets you nothing without an authorised
account. Step 2 is what establishes that.

## flex

Turn a stock Debian 13 (trixie) / GNOME 48 desktop into a ChromeOS Flex
lookalike: a bottom shelf, the Google web apps as first-class icons, ChromeOS
keybindings, a pruned app grid, and a matching pair of wallpapers. Written
from — and matches — the customisation actually run on this Yoga Pro 9
16IRP8 install.

Unlike `stage`, this one is self-contained: no bucket, no gcloud, nothing
private. Everything it touches lives under `$HOME` except the `repos` and
`pkgs` stages (apt, and non-fatal without sudo) and `boot-splash.sh`, a
script it installs but never runs, since that one edits GRUB.

### Display manager

Install GNOME with **gdm3** — the Debian installer's default desktop task
gives you that; take it and change nothing. `flex` never touches the display
manager, so this is not about anything it configures, it is about the session
it lands you in, and the script only works in one: it dies without
`gsettings`, warns unless `XDG_CURRENT_DESKTOP` is GNOME, and installs a
gnome-shell extension for the shelf, reading `gnome-shell --version` to pick
the build.

lightdm is the wrong choice here. Debian's greeter only lists
`/usr/share/xsessions`, so GNOME starts on Xorg rather than the Wayland
session everything below was measured on, and it doesn't take the handoff
from Plymouth cleanly, which is most of the point of `boot-splash.sh`. If a
machine somehow ends up with both, `sudo dpkg-reconfigure gdm3` chooses.

### Use

```sh
bash flex              # everything, dark mode
bash flex --light      # everything, light mode
bash flex -l           # list the stages
bash flex shelf webapps   # just those two
bash flex revert       # undo it
```

Every stage is idempotent, so re-running is how you repair one that failed,
and naming a stage is how you repair it without redoing the rest. `icons`
(a ~60MB icon theme) and `wallpaper` (~9s per render) are the slow ones.

Wayland cannot restart `gnome-shell` in place, so the shelf, the GTK theme
and the app grid only take effect after a full log out and back in; the
wallpaper and the keybindings are live immediately.

### Stages

- **`repos`** — turns on the `contrib` and `non-free` apt components, which is
  what puts the Microsoft fonts, `unrar` and the proprietary drivers within
  apt's reach. It adds a separate file,
  `/etc/apt/sources.list.d/chromeos-flex-nonfree.sources`, naming the Debian
  archives the machine already uses with only the extra components, rather
  than rewriting the distro's own sources — which are deb822 on a fresh trixie
  and one-line on one upgraded from bookworm, and awkward to undo either way.
  The archives are read back from `apt-get indextargets` and filtered on
  `Origin: Debian`, so third-party repos such as Chrome's and Docker's are
  left alone. `non-free-firmware` is not touched; the installer has enabled it
  since Debian 12. This is the one stage `bash flex revert` needs `sudo` for.
- **`pkgs`** — Roboto, gnome-tweaks, unzip, `gh`, and Chrome if no
  Chromium-family browser is already installed.
- **`theme`** — adw-gtk3, light and dark, from the upstream release tarball
  (trixie has no package for it), so GTK3 apps match the libadwaita GTK4 ones.
- **`icons`** — Papirus and Papirus-Dark, user-level.
- **`shelf`** — installs dash-to-panel in place of the packaged dash-to-dock:
  only dash-to-panel merges the taskbar and system tray into one bar, which is
  what the ChromeOS shelf is. Bottom, 56px, 75% opacity, Google-Blue
  running-app dots, Alt+1-9 launches the nth pinned app. App icons are
  centred on the monitor with the launcher hard left and the clock and tray
  hard right, as on ChromeOS. The per-monitor layout is resolved through
  Mutter's `DisplayConfig` at run time rather than a hardcoded panel ID, so it
  isn't tied to one laptop's monitor — but a monitor this stage has never seen
  falls back to dash-to-panel's own left-stacked default, so plug the second
  screen in first and re-run `bash flex shelf`.
- **`webapps`** — the eleven Google apps (Gemini, Gmail, Chat, Calendar, Drive,
  Docs, Sheets, Keep, Photos, Maps, YouTube) as windowless launchers with their own
  shelf icons, icons fetched from gstatic with a favicon-service fallback. All
  are pinned to the shelf except Keep.

  Two forms. If the site has been **installed as a PWA** the launcher uses
  `--app-id=<id>`, which is what ChromeOS itself does: the window carries the
  manifest's identity and Chrome names it `crx_<id>`, a name that survives
  Google reorganising the site's URLs. Otherwise it falls back to `--app=<url>`,
  a plain app-shortcut window with no manifest and no scope. The stage detects
  installed apps by looking for the launcher Chrome generates for them, so the
  upgrade path is: install from Chrome's ⋮ menu → *Cast, Save and Share* →
  *Install page as app*, then re-run `bash flex webapps`. Where both exist,
  Chrome's own launcher is hidden with `NoDisplay=true` and stripped of its
  `StartupWMClass` so it neither doubles up in the app grid nor competes for
  the window; `flex revert` restores both lines.

  **`--class` does nothing under Wayland.** Chrome names an `--app=` window
  after its URL — `chrome-<host>__<path>-Default`, every character outside
  `[A-Za-z0-9.-]` replaced by an underscore — and ignores the flag entirely.
  A `StartupWMClass` that doesn't match means GNOME never sees the app as
  running, so *every click on the shelf icon opens another window*, which is
  exactly what the hand-written `--class=chromeos-<id>` launchers used to do.
  The rule in `wmclass_for_url()` was measured rather than guessed, and
  reproduces all ten ids exactly:

  ```
  WAYLAND_DEBUG=1 google-chrome-stable --user-data-dir=$(mktemp -d) \
      --app=https://mail.google.com/mail/u/0/ 2>&1 | grep set_app_id
  ```

  That is the only way to read the id on this box: `xprop` cannot see Wayland
  windows, `org.gnome.Shell.Eval` is off without unsafe-mode, and
  `org.gnome.Shell.Introspect.GetWindows` returns `AccessDenied` to callers
  that are not allowlisted.
- **`appgrid`** — hides the apps ChromeOS doesn't have (LibreOffice, xterm,
  Disk Utility, and 30-odd others) by shadowing each system `.desktop` with a
  copy carrying `NoDisplay=true` — a copy, not a stub, so MIME associations
  and "Open with" still work. Nothing is uninstalled. GNOME Text Editor is
  renamed to "Text".
- **`look`** — Roboto as the UI/document/titlebar font, text scaled to 1.2×,
  blue accent, no hot corners, time-only clock, one workspace, shelf
  favourites. The text scale is what makes **Chrome** readable: Chrome turns
  GNOME's `text-scaling-factor` into `Xft.dpi` and uses it as its device scale
  factor, so it is the only setting that enlarges the browser UI — tabs,
  omnibox, menus — rather than just page text. Set `TEXT_SCALE=1.0` to leave
  the size alone, or higher on a denser panel.
- **`keys`** — Caps Lock becomes Super (the ChromeOS Launcher key); Alt for
  window minimise/maximise/tile; Alt+Tab cycles windows (not app groups, which
  move to Super+Tab); Super+[ / Super+] switch workspaces; Ctrl+F5 overview;
  Ctrl+Shift+F5 screenshot; Ctrl+Shift+Q sign out; Ctrl+Alt+T terminal.
- **`helpers`** — installs `set-mode.sh`, `gen_wallpaper.py` and
  `boot-splash.sh` under `~/.local/share/chromeos-flex/`.
- **`wallpaper`** — renders both wallpaper variants (pure-Python PNG encoder,
  no Pillow needed) and applies the requested mode.

### After it runs

```sh
~/.local/share/chromeos-flex/set-mode.sh light   # flip the whole look
~/.local/share/chromeos-flex/set-mode.sh         # report the current mode
```

Two things it can't do for you, both a couple of clicks in Settings:
mounting Drive in the Files app (Settings → Online Accounts → Google), and
Chrome reopening its tabs on launch (Chrome Settings → On startup). The
latter has a managed-policy route, deliberately not taken here — it stamps
"Managed by your organization" onto the Chrome menu permanently in exchange
for skipping one five-second click.

`boot-splash.sh`, also under `~/.local/share/chromeos-flex/`, is installed
but never run automatically: it edits `/etc/default/grub` to drop the GRUB
menu and enable the Plymouth splash that ships already installed. Needs
root; read it before running it.

`bash flex revert` resets every setting this script touched back to the
GNOME defaults (not to whatever they were before — this doesn't snapshot
prior values) and removes the launchers, icons, wallpapers and helper
scripts it created, plus the `contrib`/`non-free` sources file — the one
part that asks for a password. adw-gtk3, Papirus, dash-to-panel, Chrome's
apt repo and any apt packages are left in place, since removing them isn't
really an "undo" either. Anything already installed *from* `contrib` or
`non-free` stays installed, and stops getting updates, so uninstall it
first if you care.
