#!/usr/bin/env bash
# Runs inside the container (pushed and started by host-setup.sh).
set -euo pipefail
source /etc/ha-kiosk.conf
VT=${KIOSK_VT:-7}
die(){ echo "ERROR: $*" >&2; exit 1; }
shopt -s nullglob

echo "== Device checks inside container"
cards=(/dev/dri/card*); [[ ${#cards[@]} -gt 0 ]] || die "/dev/dri not visible - check lxc.mount.entry lines."
[[ -e /dev/tty$VT ]] || die "/dev/tty$VT not visible."
ls /run/udev/data >/dev/null 2>&1 || die "/run/udev not mounted - libinput cannot classify devices."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  xserver-xorg-core xserver-xorg-legacy xserver-xorg-input-libinput xinit \
  libgl1-mesa-dri libegl1 chromium fonts-dejavu-core curl udev x11-xserver-utils xinput

# Host passes how many touchscreens it saw; fewer here means host udev data isn't reaching us.
expected=${1:-0}; found=0
for e in /dev/input/event*; do
  udevadm info -q property -n "$e" 2>/dev/null | grep -qx 'ID_INPUT_TOUCHSCREEN=1' && { echo "Touchscreen seen: $e"; found=$((found+1)); }
done
(( found >= expected )) || die "Host saw $expected touchscreen(s), container sees $found - /run/udev mount problem."

id kiosk >/dev/null 2>&1 || useradd -m -s /bin/bash kiosk
# Chromium needs GPU access; match the host's group IDs on the DRI nodes.
for f in /dev/dri/*; do
  [[ -c $f ]] || continue
  gid=$(stat -c %g "$f"); grp=$(getent group "$gid" | cut -d: -f1 || true)
  [[ -n $grp ]] || { grp="hostgid$gid"; groupadd -g "$gid" "$grp"; }
  usermod -aG "$grp" kiosk
done

# Let the service user start Xorg via the root wrapper (needed for VT + input access).
printf 'allowed_users=anybody\nneeds_root_rights=yes\n' > /etc/X11/Xwrapper.config

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-kiosk.conf <<'XORG'
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection
XORG

install -m 755 /root/ha-kiosk-files/ha-kiosk /root/ha-kiosk-files/ha-kiosk-rotate /usr/local/bin/
# Rotation state: kiosk user records what's on screen; root sets the mode via ha-kiosk-rotate.
install -d -o kiosk -g kiosk /var/lib/ha-kiosk

cat > /etc/systemd/system/ha-kiosk.service <<UNIT
[Unit]
Description=Home Assistant kiosk on host VT$VT
Wants=network-online.target
After=network-online.target

[Service]
User=kiosk
ExecStart=/usr/bin/xinit /usr/local/bin/ha-kiosk -- /usr/bin/Xorg :0 vt$VT -nolisten tcp -nocursor
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now ha-kiosk.service
echo "Kiosk started. Logs: journalctl -u ha-kiosk -f   Xorg log: ~kiosk/.local/share/xorg/Xorg.0.log"
