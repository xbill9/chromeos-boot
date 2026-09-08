# Baseline captured 2026-09-08, boot of 2026-09-07 18:57

Machine: Lenovo Yoga 9i (yoga9i), Debian 13 trixie, GNOME 48,
kernel 7.1.8+deb13-amd64 (backports), GTK 4.18.6, libadwaita 1.7.6,
NVIDIA GTX 1650 Ti Mobile + Intel UHD (CometLake-H).

## Boot (before any tuning)
Startup finished in 16.064s (firmware) + 8.014s (loader)
  + 4.617s (kernel) + 10.626s (userspace) = 39.324s
graphical.target reached after 10.626s in userspace.

Critical chain:
  graphical.target @10.626s
  -> docker.service @9.507s +1.037s
    -> network-online.target @9.505s
      -> NetworkManager-wait-online.service @1.730s +7.774s

GRUB_TIMEOUT=5, GRUB_CMDLINE_LINUX_DEFAULT="quiet"

## Theme (before the pin fix)
ADW_VERSION=v6.5 installed; 159 @media in gtk-4.0/libadwaita.css
All 8 files under gtk-4.0/ byte-identical between adw-gtk3 and adw-gtk3-dark
window_bg_color outside @media: #fafafb  (light) in BOTH variants
46 of 154 @define-color rules inside @media -> discarded by GTK 4.18

Journal, this boot:
  2093  total "Theme parser error: libadwaita*" lines
   161  per GTK4 process (159 libadwaita.css + 2 libadwaita-tweaks.css)
     5  processes: gnome-control-center(x2), gnome-software,
        xdg-desktop-portal-gtk, mutter-x11-frames, chrome
  1288  misattributed to _COMM=cat (webapp launchers pipe stderr)

## Journal totals, this boot
err+: 17     warning+: 1032

## Changes applied 2026-09-08 12:31, NOT YET MEASURED
1. flex: ADW_VERSION v6.5 -> v5.7, version-aware idempotence guard
   (committed 980e972); theme re-extracted, verified 0 @media,
   window_bg_color now #fafafb light / #222226 dark
2. systemctl disable NetworkManager-wait-online.service
3. boot-splash.sh: GRUB_TIMEOUT 5->0, TIMEOUT_STYLE=hidden, +splash
   backup at /etc/default/grub.bak-20260908-123123

## AFTER a reboot, re-run:
  systemd-analyze
  systemd-analyze critical-chain
  sudo journalctl -b -o cat -q | grep -c "Theme parser error: libadwaita"
  sudo journalctl -b -p err --no-pager -q | wc -l
  sudo journalctl -b -p warning --no-pager -q | wc -l

## Article shape (decided 2026-09-08, before reboot)
ONE argument, not four sections.

Thesis: the desktop had no way to tell you, and the journal had been saying
it 2093 times a boot since the day the script was written.

Spine = the adw-gtk3 v6.5 pin: a setting that reported success, looked
right, and was discarded at parse time. Drivers / packages / tuning are the
corroborating loops around it, not co-equal sections:
  - drivers: iwlwifi debug-yoyo = an error the loop must REJECT
            (false positive, device works two lines later)
  - drivers: nvidia DKMS built for both kernels incl. backports 7.1.8;
            taint 0/12/13, Secure Boot disabled
  - packages: 6 third-party repos, backports pinned 100, one rc-state
            orphan kernel -- what apt declares vs what it will serve
  - tuning:  NM-wait-online 7.774s on the critical chain; GRUB_TIMEOUT=5
            inside an 8.014s loader phase, fixed by a script the repo
            already shipped and never ran
  - meta:    _COMM says 'cat', payload says '(chrome:11097)' -- the
            attribution trap lives in the log tooling itself

Voice: Claude as co-subject (the loop is the story), per xbill.
Destinations: dev.to (org gde) + Medium + LinkedIn.
Redact before publishing: MAC <redacted> (iwlwifi base HW address,
in 08-driver-detail.txt).
