#!/bin/bash
#
# Turn a stock Debian 13 (trixie) / GNOME 48 desktop into a ChromeOS Flex
# lookalike.
#
# Companion to `stage`.  `stage` gets a machine to where it can read the
# private bucket; `flex` makes the machine look like the thing it is imitating:
# a bottom shelf, the Google web apps as first-class icons, ChromeOS
# keybindings, a pruned app grid, and a matching pair of wallpapers.
#
# usage: bash flex [--light|--dark]        everything (dark unless told otherwise)
#        bash flex -l                      list the stages
#        bash flex <stage> [<stage>...]    run only those
#        bash flex revert                  undo it
#
# Every stage is idempotent, so re-running is how you repair one that failed,
# and naming a stage is how you repair it without redoing the rest.  The two
# slow ones are `icons` (a ~60MB icon theme) and `wallpaper` (~9s per render).
#
# Nothing here needs root except `pkgs`, which is apt and is non-fatal: a
# machine without sudo is customised all the same, minus the packages.  The
# boot splash does need root, so it is installed as a script under
# ~/.local/share/chromeos-flex and deliberately not run -- read it first.
#
# Everything else lives under $HOME and comes back out with `bash flex revert`.
# Note that revert *resets* the settings it touched rather than restoring what
# was there before: they go to the GNOME defaults, not to your old values.
#
# Wayland cannot restart gnome-shell in place, so the shelf, the themes and the
# app grid only appear after a full log out and back in.

mode=dark
want=""

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
step() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

STAGES="pkgs theme icons shelf webapps appgrid look keys helpers wallpaper"

# --- paths ----------------------------------------------------------------
APPS=$HOME/.local/share/applications
ICONS=$HOME/.local/share/icons
WEBICONS=$ICONS/chromeos-webapps
THEMES=$HOME/.local/share/themes
BG=$HOME/.local/share/backgrounds
HELPERS=$HOME/.local/share/chromeos-flex
D2P=dash-to-panel@jderose9.github.com
EXTDIR=$HOME/.local/share/gnome-shell/extensions/$D2P

# Pinned to what was actually installed and tested on the first machine.
# Override in the environment to move either one.
ADW_VERSION=${ADW_VERSION:-v6.5}
PAPIRUS_URL=${PAPIRUS_URL:-https://github.com/PapirusDevelopmentTeam/papirus-icon-theme/archive/refs/heads/master.tar.gz}

# How much to enlarge text desktop-wide.  1.0 is the GNOME default and is what
# a machine with a sane DPI wants; set TEXT_SCALE=1.0 to leave the size alone.
TEXT_SCALE=${TEXT_SCALE:-1.2}

# --- argument handling ----------------------------------------------------
for a in "$@" ; do
  case $a in
    -l|--list)  printf '%s\n' $STAGES; exit 0 ;;
    --light)    mode=light ;;
    --dark)     mode=dark ;;
    -h|--help)  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    revert)     want=revert ;;
    -*)         die "$a: unknown option (try -h)" ;;
    *)          case " $STAGES " in
                  *" $a "*) want="$want $a" ;;
                  *)        die "$a: unknown stage -- try \`bash flex -l\`" ;;
                esac ;;
  esac
done
[ -n "$want" ] || want=$STAGES

wants() { case " $want " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- preflight ------------------------------------------------------------
command -v gsettings >/dev/null 2>&1 || die "no gsettings -- this is a GNOME script"
command -v curl      >/dev/null 2>&1 || die "no curl"
command -v python3   >/dev/null 2>&1 || die "no python3 (the wallpaper generator needs it)"

case $XDG_CURRENT_DESKTOP in
  *GNOME*) ;;
  "")      warn "XDG_CURRENT_DESKTOP is empty -- run this from inside the GNOME session, not a tty" ;;
  *)       warn "desktop is '$XDG_CURRENT_DESKTOP', not GNOME -- most of this will not apply" ;;
esac

# The browser the web apps launch.  --app= is Chromium-family only; that
# windowless single-site mode is the whole point of a ChromeOS web app.
BROWSER=""
for b in google-chrome-stable google-chrome chromium chromium-browser ; do
  command -v "$b" >/dev/null 2>&1 && { BROWSER=$b; break; }
done

######################################################################## pkgs
# apt.  Non-fatal in every direction: no sudo, no network, no repo -- warn and
# carry on, the rest of the script is user-level and does not need any of it.
stage_pkgs() {
  log "pkgs: fonts, tweaks and a Chromium-family browser"
  if ! command -v sudo >/dev/null 2>&1 ; then
    warn "no sudo -- skipping apt.  Install by hand: fonts-roboto gnome-tweaks unzip"
    return
  fi

  sudo apt-get update -qq || { warn "apt update failed -- skipping packages"; return; }
  # Roboto is the ChromeOS UI font and the one thing here that is load-bearing;
  # gnome-tweaks is how you inspect what this script did.
  sudo apt-get install -y -qq \
      fonts-roboto fonts-roboto-unhinted gnome-tweaks unzip \
      apt-transport-https ca-certificates gnupg \
    || warn "some packages failed -- check the output above"

  if [ -n "$BROWSER" ] ; then
    step "browser: $BROWSER already installed"
    return
  fi
  log "pkgs: no Chromium-family browser -- adding Google's repo for Chrome"
  # --yes so a re-run overwrites the keyring instead of stopping on "File
  # exists", the same trap `stage` hits with the cloud-sdk keyring.
  if curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
       | sudo gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg \
     && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
       | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null \
     && sudo apt-get update -qq \
     && sudo apt-get install -y google-chrome-stable ; then
    BROWSER=google-chrome-stable
    step "browser: installed $BROWSER"
  else
    warn "Chrome install failed -- \`bash flex webapps\` again once a browser is present"
  fi
}

####################################################################### theme
# adw-gtk3 makes GTK3 apps match the libadwaita GTK4 ones, which is what stops
# the desktop looking like two different operating systems.  Trixie has no
# package for it, so it comes from the upstream release tarball.
stage_theme() {
  log "theme: adw-gtk3 $ADW_VERSION into $THEMES"
  if [ -d "$THEMES/adw-gtk3-dark" ] && [ -d "$THEMES/adw-gtk3" ] ; then
    step "already installed -- skipping"
    return
  fi
  mkdir -p "$THEMES" || { warn "cannot create $THEMES"; return; }
  tmp=`mktemp -d` || { warn "cannot create temp dir"; return; }
  url=https://github.com/lassekongo83/adw-gtk3/releases/download/$ADW_VERSION/adw-gtk3$ADW_VERSION.tar.xz
  if curl -fsSL "$url" -o "$tmp/adw.tar.xz" && tar -xf "$tmp/adw.tar.xz" -C "$THEMES" ; then
    step "installed adw-gtk3 and adw-gtk3-dark"
  else
    warn "adw-gtk3 download failed ($url) -- GTK3 apps will not match"
  fi
  rm -rf "$tmp"
}

####################################################################### icons
# Papirus, both variants, user-level.  ~60MB and the slowest stage after the
# wallpapers, so it checks before it downloads.
stage_icons() {
  log "icons: Papirus into $ICONS"
  if [ -d "$ICONS/Papirus" ] && [ -d "$ICONS/Papirus-Dark" ] ; then
    step "already installed -- skipping"
    return
  fi
  mkdir -p "$ICONS" || { warn "cannot create $ICONS"; return; }
  tmp=`mktemp -d` || { warn "cannot create temp dir"; return; }
  step "downloading (~60MB, this is the slow one)"
  if curl -fsSL "$PAPIRUS_URL" -o "$tmp/papirus.tar.gz" && tar -xzf "$tmp/papirus.tar.gz" -C "$tmp" ; then
    for v in Papirus Papirus-Dark ; do
      src=`find "$tmp" -maxdepth 2 -type d -name "$v" -print -quit`
      if [ -n "$src" ] ; then
        cp -a "$src" "$ICONS/" && step "installed $v"
      else
        warn "$v not found in the archive -- upstream layout changed?"
      fi
    done
    command -v gtk-update-icon-cache >/dev/null 2>&1 &&
      gtk-update-icon-cache -qf "$ICONS/Papirus" "$ICONS/Papirus-Dark" 2>/dev/null
  else
    warn "Papirus download failed -- keeping the current icon theme"
  fi
  rm -rf "$tmp"
}

####################################################################### shelf
# The ChromeOS shelf.  dash-to-panel rather than the packaged dash-to-dock,
# because only dash-to-panel merges the taskbar and the system tray into one
# bar -- a dock plus a top panel is two bars, and ChromeOS has one.
stage_shelf() {
  log "shelf: dash-to-panel"
  if [ -f "$EXTDIR/metadata.json" ] ; then
    step "already installed at $EXTDIR"
  else
    command -v unzip >/dev/null 2>&1 || { warn "no unzip -- skipping the shelf"; return; }
    sv=`gnome-shell --version 2>/dev/null | sed 's/[^0-9.]*//; s/\..*//'`
    [ -n "$sv" ] || sv=48
    step "resolving a build for GNOME Shell $sv"
    dl=`curl -fsSL "https://extensions.gnome.org/extension-info/?uuid=$D2P&shell_version=$sv" 2>/dev/null \
        | python3 -c 'import json,sys;print(json.load(sys.stdin).get("download_url",""))' 2>/dev/null`
    [ -n "$dl" ] || { warn "extensions.gnome.org has no build for shell $sv -- skipping the shelf"; return; }
    tmp=`mktemp -d` || { warn "cannot create temp dir"; return; }
    if curl -fsSL "https://extensions.gnome.org$dl" -o "$tmp/d2p.zip" ; then
      mkdir -p "$EXTDIR"
      unzip -qo "$tmp/d2p.zip" -d "$EXTDIR" || warn "unzip failed"
      # The SweetTooth zip ships gschemas.compiled, but recompile anyway: a
      # stale one is silently ignored and then every d2p setting below fails.
      command -v glib-compile-schemas >/dev/null 2>&1 && [ -d "$EXTDIR/schemas" ] &&
        glib-compile-schemas "$EXTDIR/schemas" 2>/dev/null
      step "installed dash-to-panel"
    else
      warn "dash-to-panel download failed -- skipping the shelf"
    fi
    rm -rf "$tmp"
  fi
  [ -d "$EXTDIR/schemas" ] || { warn "no schemas in $EXTDIR -- not configuring the shelf"; return; }

  # Enable by writing the list directly.  On Wayland the running shell has not
  # seen the extension yet, and `gnome-extensions enable` refuses a uuid it
  # does not know about; the list is read fresh at the next login either way.
  # dash-to-dock is dropped rather than uninstalled -- it is a Debian package
  # and it is what `revert` puts back.
  gsettings set org.gnome.shell enabled-extensions "['$D2P']"
  gsettings set org.gnome.shell disabled-extensions "[]"
  gnome-extensions enable "$D2P" >/dev/null 2>&1
  step "enabled $D2P (dash-to-dock dropped)"

  d2p() { gsettings --schemadir "$EXTDIR/schemas" set org.gnome.shell.extensions.dash-to-panel "$@"; }

  # Geometry.  These two are the global fallback; the per-monitor JSON below
  # overrides them when the monitor can be identified, and the global values
  # are what a monitor this script has never seen falls back to.
  d2p panel-position "'BOTTOM'"
  d2p panel-size 56
  d2p stockgs-keep-top-panel false      # one bar, not two
  d2p hide-overview-on-startup true     # ChromeOS boots to the desktop
  d2p intellihide false                 # the shelf does not autohide
  d2p group-apps true
  d2p show-favorites true
  d2p show-running-apps true
  d2p show-apps-icon-side-padding 10
  d2p appicon-margin 4
  d2p appicon-padding 6
  d2p animate-appicon-hover true

  # Alt+1..9 launches the nth shelf app, as on ChromeOS.
  d2p hot-keys true
  d2p shortcut-num-keys "'NUM_ROW'"
  d2p hotkeys-overlay-combo "'TEMPORARILY'"
  for n in 1 2 3 4 5 6 7 8 9 ; do d2p app-hotkey-$n "['<Alt>$n']" ; done

  # Running-app indicators: small dots under the icon, in Google Blue.  The
  # colours themselves are set per mode by set-mode.sh.
  d2p dot-position "'BOTTOM'"
  d2p dot-style-focused "'DOTS'"
  d2p dot-style-unfocused "'DOTS'"
  d2p dot-size 3
  d2p dot-color-override true
  d2p focus-highlight-opacity 12
  d2p trans-use-custom-bg true
  d2p trans-use-custom-opacity true
  d2p trans-use-dynamic-opacity false
  d2p trans-panel-opacity 0.75

  # Layout: launcher hard left, clock and tray hard right, and the app icons
  # centred between them -- which is what ChromeOS does.  "centerMonitor" is
  # the monitor's true midpoint; plain "centered" would centre in the gap
  # left by the two stacked groups, and the tray is wider than the launcher,
  # so that sits visibly right of centre.
  # These three keys are JSON maps keyed by *monitor*, not plain values, and
  # the key is the monitor's EDID vendor and serial (eg "BOE-0x00000000") --
  # machine-specific, so ask Mutter what this machine has rather than baking
  # in the laptop it was written on.
  ids=`gdbus call --session -d org.gnome.Mutter.DisplayConfig \
          -o /org/gnome/Mutter/DisplayConfig \
          -m org.gnome.Mutter.DisplayConfig.GetCurrentState 2>/dev/null \
       | python3 -c '
import re,sys
out=sys.stdin.read()
# a monitor spec is four quoted strings in a row: connector, vendor, product, serial
for c,v,p,s in re.findall(r"\(\(\x27([^\x27]*)\x27, \x27([^\x27]*)\x27, \x27([^\x27]*)\x27, \x27([^\x27]*)\x27\)", out):
    print(v + "-" + s)
' 2>/dev/null`

  if [ -n "$ids" ] ; then
    json=`printf '%s\n' "$ids" | python3 -c '
import json,sys
ids=[l.strip() for l in sys.stdin if l.strip()]
elements=[("showAppsButton",True,"stackedTL"),("activitiesButton",False,"stackedTL"),
          ("leftBox",False,"stackedTL"),("taskbar",True,"centerMonitor"),
          ("centerBox",False,"stackedBR"),("rightBox",True,"stackedBR"),
          ("dateMenu",True,"stackedBR"),("systemMenu",True,"stackedBR"),
          ("desktopButton",False,"stackedBR")]
layout=[{"element":e,"visible":v,"position":p} for e,v,p in elements]
enc=lambda d: json.dumps(d,separators=(",",":"))
print(enc({i:"BOTTOM" for i in ids}))
print(enc({i:56 for i in ids}))
print(enc({i:layout for i in ids}))
' 2>/dev/null`
    set -- $json
    if [ $# -eq 3 ] ; then
      d2p panel-positions "$1"
      d2p panel-sizes "$2"
      d2p panel-element-positions "$3"
      step "shelf pinned bottom, 56px, icons centred, on: `printf '%s' "$ids" | tr '\n' ' '`"
    else
      warn "could not build the per-monitor layout -- the global 56px bottom panel still applies"
    fi
  else
    warn "could not identify the monitor -- the global 56px bottom panel still applies"
  fi
}

##################################################################### webapps
# The ten Google web apps, as launchers that open a Chrome app window with no
# tab strip and no omnibox -- which is what a ChromeOS "app" actually is.
# --class is what gives each one its own shelf icon instead of all of them
# stacking under Chrome; StartupWMClass is how GNOME matches the window back.
WEBAPPS="gmail|Gmail|https://mail.google.com/mail/u/0/|gmail_2020q4_512dp
chat|Chat|https://mail.google.com/chat/u/0/|chat_2020q4_512dp
calendar|Calendar|https://calendar.google.com/calendar/r|calendar_2020q4_512dp
drive|Drive|https://drive.google.com/drive/my-drive|drive_2020q4_512dp
docs|Docs|https://docs.google.com/document/u/0/|docs_2020q4_512dp
sheets|Sheets|https://docs.google.com/spreadsheets/u/0/|sheets_2020q4_512dp
keep|Keep|https://keep.google.com/|keep_2020q4_512dp
photos|Photos|https://photos.google.com/|photos_512dp
maps|Maps|https://www.google.com/maps|maps_512dp
youtube|YouTube|https://www.youtube.com/|youtube_512dp"

stage_webapps() {
  log "webapps: ten Google apps as launchers"
  if [ -z "$BROWSER" ] ; then
    warn "no Chromium-family browser -- skipping.  \`bash flex pkgs webapps\` once one is installed"
    return
  fi
  step "browser: $BROWSER"
  mkdir -p "$WEBICONS" "$APPS" || { warn "cannot create $WEBICONS"; return; }
  # 2x of a 512dp asset is a 1024px PNG, which is enough for any shelf size.
  gs=https://ssl.gstatic.com/images/branding/product/2x
  printf '%s\n' "$WEBAPPS" | while IFS='|' read -r id name url icon ; do
    [ -n "$id" ] || continue
    if [ ! -s "$WEBICONS/$id.png" ] ; then
      curl -fsSL -m 20 -o "$WEBICONS/$id.png" "$gs/$icon.png" || {
        # gstatic renames these assets from time to time; the favicon service
        # is smaller but always answers.
        host=`printf '%s' "$url" | sed 's|https\{0,1\}://||; s|/.*||'`
        curl -fsSL -m 20 -o "$WEBICONS/$id.png" "https://www.google.com/s2/favicons?domain=$host&sz=128" || {
          warn "no icon for $name -- the launcher will use a generic one"
          rm -f "$WEBICONS/$id.png"
        }
      }
    fi
    cat > "$APPS/chromeos-$id.desktop" <<DESK
[Desktop Entry]
Version=1.0
Type=Application
Name=$name
Comment=$name web app
Exec=$BROWSER --app=$url --class=chromeos-$id
Icon=$WEBICONS/$id.png
StartupWMClass=chromeos-$id
StartupNotify=true
Terminal=false
Categories=Network;
DESK
    printf '    %s\n' "$name"
  done
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" 2>/dev/null
}

##################################################################### appgrid
# ChromeOS has no LibreOffice, no xterm and no Disk Utility in its launcher.
# Hide them by shadowing each system .desktop with a *copy* carrying
# NoDisplay=true -- a copy rather than a two-line stub, so the file still
# declares its MIME types and "Open with" keeps working.  Nothing is
# uninstalled; every one of these apps still runs from the command line.
HIDE="debian-uxterm.desktop debian-xterm.desktop firefox-esr.desktop
im-config.desktop libreoffice-calc.desktop libreoffice-draw.desktop
libreoffice-impress.desktop libreoffice-math.desktop
libreoffice-startcenter.desktop libreoffice-writer.desktop
nm-connection-editor.desktop org.freedesktop.IBus.Setup.desktop
org.freedesktop.MalcontentControl.desktop org.gnome.baobab.desktop
org.gnome.Calendar.desktop org.gnome.Characters.desktop org.gnome.clocks.desktop
org.gnome.Connections.desktop org.gnome.Contacts.desktop
org.gnome.DiskUtility.desktop org.gnome.Evince.desktop org.gnome.Evolution.desktop
org.gnome.FileRoller.desktop org.gnome.font-viewer.desktop org.gnome.Logs.desktop
org.gnome.Maps.desktop org.gnome.Music.desktop org.gnome.seahorse.Application.desktop
org.gnome.Shotwell.desktop org.gnome.SoundRecorder.desktop
org.gnome.SystemMonitor.desktop org.gnome.Totem.desktop org.gnome.Tour.desktop
org.gnome.Weather.desktop simple-scan.desktop vim.desktop yelp.desktop
claude-code-url-handler.desktop"

stage_appgrid() {
  log "appgrid: hiding the apps ChromeOS does not have"
  mkdir -p "$APPS" || { warn "cannot create $APPS"; return; }
  n=0; miss=0
  for f in $HIDE ; do
    if grep -qs '^NoDisplay=true' "$APPS/$f" ; then n=$((n+1)); continue; fi
    if [ -f "/usr/share/applications/$f" ] ; then
      cp -f "/usr/share/applications/$f" "$APPS/$f" || continue
      printf 'NoDisplay=true\n' >> "$APPS/$f"
      n=$((n+1))
    elif [ -f "$APPS/$f" ] ; then
      # No system copy to shadow (a url handler dropped in by an installer):
      # edit it where it lives.
      printf 'NoDisplay=true\n' >> "$APPS/$f"
      n=$((n+1))
    else
      miss=$((miss+1))
    fi
  done
  step "$n hidden, $miss not installed here"

  # ChromeOS calls it "Text", not "Text Editor".  Rewrite Name= only in the
  # first section: the same key appears under [Desktop Action], where it
  # labels "New Window", and a blanket s/^Name=/ renames that too.
  src=/usr/share/applications/org.gnome.TextEditor.desktop
  if [ -f "$src" ] ; then
    awk 'BEGIN{s=0} /^\[/{s++} {if (s==1 && $0 ~ /^Name=/) print "Name=Text"; else print}' \
      "$src" > "$APPS/org.gnome.TextEditor.desktop" &&
      step "GNOME Text Editor renamed to Text"
  fi
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" 2>/dev/null
}

######################################################################## look
# The look that is not the shelf and not the wallpaper.  Colours, themes and
# the wallpaper itself belong to set-mode.sh, which the wallpaper stage runs --
# they are the half that has to flip together when you switch light and dark.
stage_look() {
  log "look: fonts, chrome, favourites"

  if fc-list : family 2>/dev/null | tr ',' '\n' | grep -qix 'Roboto' ; then
    gsettings set org.gnome.desktop.interface font-name 'Roboto 12'
    gsettings set org.gnome.desktop.interface document-font-name 'Roboto 12'
    gsettings set org.gnome.desktop.wm.preferences titlebar-font 'Roboto Medium 12'
    step "Roboto as the UI, document and titlebar font"
  else
    warn "Roboto not installed -- \`sudo apt install fonts-roboto\`, then \`bash flex look\`"
  fi

  # 1080p on a 15" panel is ~143 DPI, but GNOME drives it as though it were 96,
  # so everything lands at about two thirds of its intended physical size.  This
  # is also the only knob that enlarges Chrome's own UI -- tabs, omnibox, menus:
  # Chrome turns it into Xft.dpi and uses that as its device scale factor.  Its
  # built-in font-size setting reaches page text and nothing else.
  gsettings set org.gnome.desktop.interface text-scaling-factor "$TEXT_SCALE"
  step "text scaled to ${TEXT_SCALE}x (Chrome's UI follows this, not its own font setting)"

  gsettings set org.gnome.desktop.interface accent-color 'blue'
  gsettings set org.gnome.desktop.interface enable-hot-corners false   # ChromeOS has none
  gsettings set org.gnome.desktop.interface clock-show-date false      # the shelf shows time only
  gsettings set org.gnome.desktop.wm.preferences button-layout ':minimize,maximize,close'
  step "no hot corners, time-only clock, right-hand window buttons"

  # ChromeOS desks: one to start with, more on demand, primary display only.
  gsettings set org.gnome.desktop.wm.preferences num-workspaces 1
  gsettings set org.gnome.mutter dynamic-workspaces true
  gsettings set org.gnome.mutter workspaces-only-on-primary true

  gsettings set org.gnome.nautilus.preferences default-folder-viewer 'list-view'

  # The shelf, left to right.  Keep is installed but not pinned -- the shelf is
  # already full, and Alt+1..9 only reaches the first nine.
  bdesk=google-chrome.desktop
  [ -f /usr/share/applications/$bdesk ] || bdesk=$BROWSER.desktop
  term=org.gnome.Terminal.desktop
  [ -f /usr/share/applications/$term ] || term=""
  favs="'$bdesk', 'chromeos-gmail.desktop', 'chromeos-chat.desktop'"
  favs="$favs, 'chromeos-calendar.desktop'"
  [ -n "$term" ] && favs="$favs, '$term'"
  favs="$favs, 'chromeos-drive.desktop', 'chromeos-docs.desktop', 'chromeos-sheets.desktop'"
  favs="$favs, 'chromeos-photos.desktop', 'chromeos-maps.desktop', 'chromeos-youtube.desktop'"
  favs="$favs, 'org.gnome.Nautilus.desktop', 'org.gnome.Settings.desktop'"
  gsettings set org.gnome.shell favorite-apps "[$favs]"
  step "shelf favourites pinned"
}

######################################################################## keys
# ChromeOS keyboard.  The one that matters most is Caps Lock: on a Chromebook
# that key is the Launcher, and every shortcut below is built around it being
# Super.
stage_keys() {
  log "keys: ChromeOS keyboard"

  opts=`gsettings get org.gnome.desktop.input-sources xkb-options`
  case $opts in
    *caps:super*) step "Caps Lock is already Super" ;;
    *)            gsettings set org.gnome.desktop.input-sources xkb-options "['caps:super']"
                  step "Caps Lock -> Super (the Launcher key)" ;;
  esac

  # Window management, all on Alt as on ChromeOS.
  gsettings set org.gnome.desktop.wm.keybindings minimize "['<Alt>minus']"
  gsettings set org.gnome.desktop.wm.keybindings toggle-maximized "['<Alt>equal']"
  gsettings set org.gnome.mutter.keybindings toggle-tiled-left "['<Alt>bracketleft']"
  gsettings set org.gnome.mutter.keybindings toggle-tiled-right "['<Alt>bracketright']"

  # Alt+Tab cycles windows, not app groups -- that is the ChromeOS behaviour,
  # and it is the one GNOME default that consistently feels wrong afterwards.
  # App-group switching is still there, moved to Super+Tab.
  gsettings set org.gnome.desktop.wm.keybindings switch-windows "['<Alt>Tab']"
  gsettings set org.gnome.desktop.wm.keybindings switch-windows-backward "['<Shift><Alt>Tab']"
  gsettings set org.gnome.desktop.wm.keybindings switch-applications "['<Super>Tab']"
  gsettings set org.gnome.desktop.wm.keybindings switch-applications-backward "['<Shift><Super>Tab']"

  # Launcher+[ / ] switches desks; the GNOME defaults are kept alongside.
  gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-left \
    "['<Super>bracketleft', '<Super>Page_Up', '<Control><Alt>Left']"
  gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-right \
    "['<Super>bracketright', '<Super>Page_Down', '<Control><Alt>Right']"

  # The Chromebook top row: F5 is overview, Ctrl+Shift+F5 is screenshot.
  gsettings set org.gnome.shell.keybindings toggle-overview "['<Control>F5']"
  gsettings set org.gnome.shell.keybindings show-screenshot-ui "['<Control><Shift>F5', 'Print']"
  gsettings set org.gnome.settings-daemon.plugins.media-keys logout "['<Control><Shift>q']"
  step "Alt+- / Alt+= / Alt+[ / Alt+], Alt+Tab by window, Ctrl+F5 overview, Ctrl+Shift+Q sign out"

  # Ctrl+Alt+T for a terminal, as in Chrome.  Appended to whatever custom
  # bindings already exist rather than replacing the list.
  if command -v gnome-terminal >/dev/null 2>&1 ; then
    ck=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/
    cur=`gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings`
    new=`python3 -c '
import ast,sys
raw=sys.argv[1].strip()
cur=[] if raw in ("@as []","[]") else ast.literal_eval(raw)
p=sys.argv[2]
if p not in cur: cur.append(p)
print("[" + ", ".join(repr(x) for x in cur) + "]")
' "$cur" "$ck" 2>/dev/null`
    if [ -n "$new" ] ; then
      gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$new"
      s=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$ck
      gsettings set "$s" name 'Terminal'
      gsettings set "$s" command 'gnome-terminal'
      gsettings set "$s" binding '<Control><Alt>t'
      step "Ctrl+Alt+T opens a terminal"
    fi
  fi
}

##################################################################### helpers
# Three scripts that outlive this one.  set-mode.sh is the important one: this
# script is a one-shot, and flipping light/dark afterwards is ~15 gsettings
# calls that have to move together.
stage_helpers() {
  log "helpers: $HELPERS"
  mkdir -p "$HELPERS" || { warn "cannot create $HELPERS"; return; }

  cat > "$HELPERS/gen_wallpaper.py" <<'PYEOF'
#!/usr/bin/env python3
"""Generate ChromeOS-Flex-'Element'-style wallpapers, light or dark.

No PIL and no numpy on a stock Debian desktop, so this is a hand-rolled PNG
encoder: a diagonal base gradient, four soft Google-palette blobs with a
quadratic falloff, and an ordered dither, which is the part that matters --
without it a 2560px gradient bands visibly.

Usage: gen_wallpaper.py [light|dark]
"""
import zlib, struct, sys, os

W, H = 2560, 1440
VARIANT = (sys.argv[1] if len(sys.argv) > 1 else "light").lower()

# base = (top-left, bottom-right) diagonal gradient endpoints
# blobs = (cx_frac, cy_frac, radius_frac_of_W, (r,g,b), peak alpha)
PRESETS = {
    "light": dict(
        out="chromeos-element-light.png",
        base=((0xF2, 0xF6, 0xFC), (0xCF, 0xDF, 0xF2)),
        blobs=[(0.78, 0.22, 0.62, (0x42, 0x85, 0xF4), 0.30),   # blue,   upper right
               (0.16, 0.86, 0.55, (0x34, 0xA8, 0x53), 0.20),   # green,  lower left
               (0.88, 0.92, 0.48, (0xFB, 0xBC, 0x04), 0.17),   # yellow, lower right
               (0.08, 0.10, 0.40, (0xEA, 0x43, 0x35), 0.10)],  # red,    upper left
    ),
    "dark": dict(
        out="chromeos-element-dark.png",
        base=((0x0E, 0x12, 0x1B), (0x1A, 0x26, 0x3A)),
        blobs=[(0.78, 0.22, 0.62, (0x1A, 0x73, 0xE8), 0.62),
               (0.16, 0.86, 0.55, (0x0F, 0x9D, 0x58), 0.20),
               (0.88, 0.92, 0.48, (0xF2, 0x9D, 0x12), 0.10),
               (0.08, 0.10, 0.40, (0xD9, 0x30, 0x25), 0.07)],
    ),
}
if VARIANT not in PRESETS:
    sys.exit(f"unknown variant {VARIANT!r}; expected light or dark")
P = PRESETS[VARIANT]
DEST = os.path.expanduser("~/.local/share/backgrounds")
os.makedirs(DEST, exist_ok=True)
OUT = os.path.join(DEST, P["out"])
TL, BR = P["base"]
BLOBS = [(cx * W, cy * H, r * W, rgb, a) for cx, cy, r, rgb, a in P["blobs"]]

# 4x4 ordered dither, +/- 0.5 LSB, to kill banding across 2560px.
BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
DITHER = [[(v / 16.0) - 0.5 for v in row] for row in BAYER]

xfrac = [x / (W - 1) for x in range(W)]
blob_dx2 = [[(x - b[0]) * (x - b[0]) for x in range(W)] for b in BLOBS]
blob_r2 = [b[2] * b[2] for b in BLOBS]
dRGB = [BR[i] - TL[i] for i in range(3)]
NB = len(BLOBS)

raw = bytearray()
for y in range(H):
    yf = y / (H - 1)
    raw.append(0)                            # filter type 0 (None)
    row = bytearray(W * 3)
    dy2 = [(y - BLOBS[k][1]) ** 2 for k in range(NB)]
    dith = DITHER[y & 3]
    for x in range(W):
        g = (xfrac[x] + yf) * 0.5
        r = TL[0] + dRGB[0] * g
        gg = TL[1] + dRGB[1] * g
        b = TL[2] + dRGB[2] * g
        for k in range(NB):
            d2 = blob_dx2[k][x] + dy2[k]
            r2 = blob_r2[k]
            if d2 < r2:
                t = 1.0 - d2 / r2
                w = t * t * BLOBS[k][4]      # smooth quadratic falloff, no sqrt
                cr, cg, cb = BLOBS[k][3]
                r += (cr - r) * w
                gg += (cg - gg) * w
                b += (cb - b) * w
        dv = dith[x & 3]
        i = x * 3
        v = int(r + dv + 0.5);  row[i]     = 0 if v < 0 else (255 if v > 255 else v)
        v = int(gg + dv + 0.5); row[i + 1] = 0 if v < 0 else (255 if v > 255 else v)
        v = int(b + dv + 0.5);  row[i + 2] = 0 if v < 0 else (255 if v > 255 else v)
    raw += row

def chunk(typ, data):
    return (struct.pack('>I', len(data)) + typ + data
            + struct.pack('>I', zlib.crc32(typ + data) & 0xFFFFFFFF))

png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
       + chunk(b'IEND', b''))
open(OUT, 'wb').write(png)
print(f"wrote {OUT} ({len(png)} bytes, {W}x{H}, variant={VARIANT})")
PYEOF

  cat > "$HELPERS/set-mode.sh" <<'SMEOF'
#!/usr/bin/env bash
# Switch the ChromeOS-Flex lookalike between light and dark.
# Usage: set-mode.sh [light|dark]   (no arg = report current mode)
#
# One command because the look is ~15 settings that only make sense together:
# the colour scheme, the GTK and icon themes, both wallpaper keys, the lock
# screen and the eight dash-to-panel colours.
set -uo pipefail

BG=~/.local/share/backgrounds
SD=~/.local/share/gnome-shell/extensions/dash-to-panel@jderose9.github.com/schemas/
d2p() {
  [ -d "$SD" ] || return 0
  gsettings --schemadir "$SD" set org.gnome.shell.extensions.dash-to-panel "$@"
}

case "${1:-}" in
  light)
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-light'
    gsettings set org.gnome.desktop.interface gtk-theme   'adw-gtk3'
    gsettings set org.gnome.desktop.interface icon-theme  'Papirus'
    gsettings set org.gnome.desktop.background picture-uri      "file://$BG/chromeos-element-light.png"
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$BG/chromeos-element-dark.png"
    gsettings set org.gnome.desktop.screensaver picture-uri     "file://$BG/chromeos-element-light.png"
    gsettings set org.gnome.desktop.background primary-color   '#dfe8f5'
    gsettings set org.gnome.desktop.background secondary-color '#ffffff'
    d2p trans-bg-color '#f1f3f4'
    d2p group-apps-label-font-color '#3c4043'
    d2p group-apps-label-font-color-minimized '#5f6368'
    d2p window-preview-title-font-color '#3c4043'
    d2p highlight-appicon-hover-background-color   'rgba(60,64,67,0.08)'
    d2p highlight-appicon-pressed-background-color 'rgba(60,64,67,0.16)'
    d2p focus-highlight-color '#3c4043'
    # Google Blue 600 on light; ChromeOS uses the lighter Blue 300 on dark.
    for n in 1 2 3 4; do d2p dot-color-$n '#1a73e8'; d2p dot-color-unfocused-$n '#1a73e8'; done
    echo "switched to light"
    ;;
  dark)
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
    gsettings set org.gnome.desktop.interface gtk-theme   'adw-gtk3-dark'
    gsettings set org.gnome.desktop.interface icon-theme  'Papirus-Dark'
    gsettings set org.gnome.desktop.background picture-uri      "file://$BG/chromeos-element-dark.png"
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$BG/chromeos-element-dark.png"
    gsettings set org.gnome.desktop.screensaver picture-uri     "file://$BG/chromeos-element-dark.png"
    gsettings set org.gnome.desktop.background primary-color   '#0e121b'
    gsettings set org.gnome.desktop.background secondary-color '#1a263a'
    d2p trans-bg-color '#202124'
    d2p group-apps-label-font-color '#e8eaed'
    d2p group-apps-label-font-color-minimized '#9aa0a6'
    d2p window-preview-title-font-color '#e8eaed'
    d2p highlight-appicon-hover-background-color   'rgba(232,234,237,0.08)'
    d2p highlight-appicon-pressed-background-color 'rgba(232,234,237,0.16)'
    d2p focus-highlight-color '#e8eaed'
    for n in 1 2 3 4; do d2p dot-color-$n '#8ab4f8'; d2p dot-color-unfocused-$n '#8ab4f8'; done
    echo "switched to dark"
    ;;
  "")
    echo "current: $(gsettings get org.gnome.desktop.interface color-scheme)"
    echo "  gtk-theme  $(gsettings get org.gnome.desktop.interface gtk-theme)"
    echo "  icon-theme $(gsettings get org.gnome.desktop.interface icon-theme)"
    echo "  wallpaper  $(gsettings get org.gnome.desktop.background picture-uri)"
    echo "usage: $0 [light|dark]"
    ;;
  *)
    echo "usage: $0 [light|dark]" >&2; exit 2 ;;
esac
SMEOF

  cat > "$HELPERS/boot-splash.sh" <<'BSEOF'
#!/usr/bin/env bash
# ChromeOS-style boot: no GRUB menu, graphical Plymouth splash.
#
# NOT run by `flex` -- it is the only piece that touches the boot chain, so
# read it before you run it.  On a stock Debian desktop Plymouth is already
# installed and already in the initramfs; the splash never shows only because
# the kernel cmdline says "quiet" without "splash".  So this edits one file.
#
# Worth knowing before you bother: on the machine this was measured on, boot
# was 44s, of which ~30s was firmware and loader.  Killing the GRUB timeout
# saved ~5s.  This buys visual continuity, not speed.
#
# Run:  sudo bash ~/.local/share/chromeos-flex/boot-splash.sh
# Undo: sudo cp /etc/default/grub.bak-<timestamp> /etc/default/grub && sudo update-grub
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "needs root: sudo bash $0" >&2; exit 1; }
command -v plymouth-set-default-theme >/dev/null 2>&1 ||
  echo "note: plymouth does not look installed -- apt install plymouth plymouth-themes" >&2

F=/etc/default/grub
B="$F.bak-$(date +%Y%m%d-%H%M%S)"
cp -a "$F" "$B"
echo "backed up -> $B"

# 1. no menu wait
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' "$F"

# 2. hide the menu, but keep it reachable by holding SHIFT / tapping ESC
if grep -q '^GRUB_TIMEOUT_STYLE=' "$F"; then
  sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' "$F"
else
  sed -i '/^GRUB_TIMEOUT=0$/a GRUB_TIMEOUT_STYLE=hidden' "$F"
fi

# 3. hand boot over to Plymouth (idempotent: only adds splash if missing)
if ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=.*splash' "$F"; then
  sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 splash"/' "$F"
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=" /GRUB_CMDLINE_LINUX_DEFAULT="/' "$F"
fi

echo "--- changes ---"
diff -u "$B" "$F" || true
echo "--- regenerating grub.cfg ---"
update-grub
echo
echo "Done. Reboot to see it."
echo "Menu is still reachable: hold SHIFT (or tap ESC) during boot."
BSEOF

  chmod 755 "$HELPERS"/*.sh "$HELPERS"/*.py
  step "set-mode.sh, gen_wallpaper.py, boot-splash.sh (the last one is not run)"
}

################################################################### wallpaper
stage_wallpaper() {
  log "wallpaper: rendering the pair (~9s each)"
  [ -x "$HELPERS/gen_wallpaper.py" ] || { warn "helpers missing -- run \`bash flex helpers wallpaper\`"; return; }
  mkdir -p "$BG"
  for v in light dark ; do
    if [ -s "$BG/chromeos-element-$v.png" ] ; then
      step "chromeos-element-$v.png already rendered"
    else
      python3 "$HELPERS/gen_wallpaper.py" "$v" | sed 's/^/    /' ||
        warn "$v wallpaper failed"
    fi
  done
  # Both are rendered whichever mode you asked for: picture-uri-dark always
  # points at the dark one so GNOME's automatic day/night switch has something
  # to switch to.
  log "mode: $mode"
  bash "$HELPERS/set-mode.sh" "$mode" | sed 's/^/    /'
}

###################################################################### revert
do_revert() {
  log "revert: resetting settings"
  # Reset, not restore: these go back to the GNOME defaults, which is not
  # necessarily what you had before running this.
  for s in \
    "org.gnome.desktop.interface color-scheme gtk-theme icon-theme font-name document-font-name text-scaling-factor accent-color clock-show-date enable-hot-corners" \
    "org.gnome.desktop.wm.preferences button-layout titlebar-font num-workspaces" \
    "org.gnome.desktop.wm.keybindings minimize toggle-maximized switch-windows switch-windows-backward switch-applications switch-applications-backward switch-to-workspace-left switch-to-workspace-right" \
    "org.gnome.mutter dynamic-workspaces workspaces-only-on-primary" \
    "org.gnome.mutter.keybindings toggle-tiled-left toggle-tiled-right" \
    "org.gnome.shell.keybindings toggle-overview show-screenshot-ui" \
    "org.gnome.settings-daemon.plugins.media-keys logout custom-keybindings" \
    "org.gnome.desktop.input-sources xkb-options" \
    "org.gnome.desktop.background picture-uri picture-uri-dark picture-options primary-color secondary-color color-shading-type" \
    "org.gnome.desktop.screensaver picture-uri picture-options primary-color secondary-color color-shading-type" \
    "org.gnome.nautilus.preferences default-folder-viewer" \
    "org.gnome.shell favorite-apps" ; do
    set -- $s
    schema=$1; shift
    for k in "$@" ; do gsettings reset "$schema" "$k" 2>/dev/null; done
  done
  [ -d "$EXTDIR/schemas" ] &&
    gsettings --schemadir "$EXTDIR/schemas" reset-recursively org.gnome.shell.extensions.dash-to-panel 2>/dev/null
  step "gsettings reset"

  # dash-to-dock is the Debian package and the thing that was there before.
  if [ -d /usr/share/gnome-shell/extensions/dash-to-dock@micxgx.gmail.com ] ; then
    gsettings set org.gnome.shell enabled-extensions "['dash-to-dock@micxgx.gmail.com']"
    step "shelf back to dash-to-dock"
  else
    gsettings reset org.gnome.shell enabled-extensions 2>/dev/null
  fi

  log "revert: removing files"
  rm -f "$APPS"/chromeos-*.desktop
  rm -rf "$WEBICONS"
  for f in $HIDE org.gnome.TextEditor.desktop ; do
    # Only remove the shadow copy; a file with no system original was edited
    # in place, so strip the line back out instead of deleting the launcher.
    if [ -f "/usr/share/applications/$f" ] ; then
      rm -f "$APPS/$f"
    elif [ -f "$APPS/$f" ] ; then
      sed -i '/^NoDisplay=true$/d' "$APPS/$f"
    fi
  done
  rm -f "$BG/chromeos-element-light.png" "$BG/chromeos-element-dark.png"
  rm -rf "$HELPERS"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" 2>/dev/null
  step "launchers, icons, wallpapers and helpers removed"

  cat <<'REVDONE'

  Reverted.  Log out and back in.

  Left alone on purpose, because removing them is not an undo:
    ~/.local/share/themes/adw-gtk3*        the GTK theme
    ~/.local/share/icons/Papirus*          the icon theme
    ~/.local/share/gnome-shell/extensions/dash-to-panel@jderose9.github.com
    fonts-roboto, gnome-tweaks, google-chrome-stable   (apt)

REVDONE
}

######################################################################## main
if [ "$want" = revert ] ; then
  do_revert
  exit 0
fi

for s in $STAGES ; do
  wants "$s" && "stage_$s"
done

cat <<DONE

  Log out and back in.

  Wayland cannot restart gnome-shell in place, so the shelf, the GTK theme and
  the app grid are all still the old ones until the session restarts.  The
  wallpaper and the keybindings are already live.

  Afterwards:

      ~/.local/share/chromeos-flex/set-mode.sh light    flip the whole look
      ~/.local/share/chromeos-flex/set-mode.sh          report the current one
      bash flex -l                                      the stages, to repair one
      bash flex revert                                  undo it

  Two things this cannot do for you:

    - Drive in the Files app.  Settings -> Online Accounts -> Google.
    - Chrome reopening your tabs.  Chrome Settings -> On startup -> Continue
      where you left off.  There is a managed-policy way to set this, but it
      stamps "Managed by your organization" on the Chrome menu permanently and
      greys the setting out, which is a bad trade for one click.

DONE
