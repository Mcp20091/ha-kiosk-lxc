#!/usr/bin/env bash
# Run on the Proxmox host of the kiosk device. Checks hardware, shows the plan, asks before changing anything.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/ha-kiosk.conf"
VT=${KIOSK_VT:-7}

die(){ echo "ERROR: $*" >&2; exit 1; }
ask(){ local r; read -rp "$1 [$2]: " r; echo "${r:-$2}"; }
yes_no(){ local r; read -rp "$1 [y/N]: " r; [[ $r == [yY]* ]]; }
yes_default(){ local r; read -rp "$1 [Y/n]: " r; [[ $r != [nN]* ]]; }
# NAT bridge set up for Wi-Fi hosts (see wifi-setup.sh): prints "bridge address file" or nothing.
nat_bridge(){ awk '/^iface /{i=$2; a=""} /^[ \t]+address /{a=$2} /MASQUERADE/ && i ~ /^vmbr/ {print i, a, FILENAME; exit}' \
  /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null || true; }

command -v pct >/dev/null || die "Run this on the Proxmox host."
[[ $HA_DASHBOARD_PATH != CHANGE_ME ]] || die "Set HA_DASHBOARD_PATH in ha-kiosk.conf first."

echo "== Host"
pveversion; echo "Kernel: $(uname -r)"
lscpu | grep 'Model name'; echo "Model: $(cat /sys/class/dmi/id/product_name)"

echo "== GPU"
shopt -s nullglob
cards=(/sys/class/drm/card[0-9]); [[ ${#cards[@]} -gt 0 ]] || die "No /dev/dri/card* - GPU driver not loaded."
for c in "${cards[@]}"; do
  drv=$(basename "$(readlink -f "$c/device/driver")")
  echo "$(basename "$c"): driver $drv"
  [[ $drv == nvidia ]] && echo "  WARNING: proprietary nvidia driver; this setup expects a kernel modesetting driver (i915, xe, amdgpu, nouveau)."
done
ls /dev/dri/renderD* >/dev/null || die "No render node in /dev/dri."

echo "== Touchscreen"
touch=""
for e in /dev/input/event*; do
  if udevadm info -q property -n "$e" | grep -qx 'ID_INPUT_TOUCHSCREEN=1'; then
    touch+="$e: $(cat /sys/class/input/$(basename "$e")/device/name)"$'\n'
  fi
done
if [[ -n $touch ]]; then
  printf '%s' "$touch"
else
  echo "No touchscreen found by udev (check: dmesg | grep -Ei 'i2c_hid|multitouch|ipts|ithc')."
  echo "The kiosk can still run display-only with keyboard/mouse."
  yes_no "Continue without touch?" || exit 1
fi

echo "== Accelerometer"
accel=""
for d in /sys/bus/iio/devices/iio:device*; do
  [[ -r $d/in_accel_x_raw ]] || continue
  # No ACCEL_* udev properties is normal on many devices; grep finding nothing must not abort.
  props=$(udevadm info -q property -p "$d" | grep -E '^ACCEL_(LOCATION|MOUNT_MATRIX)=' | tr '\n' ' ' || true)
  accel+="$d: $(cat "$d/name") ${props:-(no udev orientation data)}"$'\n'
done
if [[ -n $accel ]]; then printf '%s' "$accel"; else echo "None found - auto-rotate will stay at normal; manual rotation still works."; fi

echo "== VT$VT"
systemctl is-active --quiet "getty@tty$VT" && die "A login prompt is running on tty$VT; pick another KIOSK_VT."
[[ -e /dev/tty$VT ]] || die "/dev/tty$VT missing."
echo "tty$VT is free."

echo "== Network"
WIFI=""
for i in /sys/class/net/*; do [[ -d $i/wireless ]] && { WIFI=$(basename "$i"); break; }; done
NAT=$(nat_bridge)
if [[ -n $NAT ]]; then
  echo "NAT bridge for Wi-Fi found: ${NAT%% *}"
elif [[ -n $WIFI ]]; then
  echo "This host has Wi-Fi ($WIFI). Containers can't be bridged onto Wi-Fi, so a Wi-Fi setup"
  echo "puts them on a private NAT network instead (details: docs/wifi.md)."
  if yes_no "Set up Wi-Fi on this host now? (shows its plan first; Ethernet keeps working)"; then
    "$HERE/wifi-setup.sh"
    NAT=$(nat_bridge)
  fi
else
  echo "Wired only."
fi
DEF_BRIDGE=vmbr0 DEF_IP=dhcp DEF_GW=""
if [[ -n $NAT ]] && yes_default "Put the kiosk on the Wi-Fi NAT bridge ${NAT%% *}?"; then
  read -r DEF_BRIDGE nat_addr _ <<<"$NAT"
  net=${nat_addr%.*}; DEF_GW=${nat_addr%/*}
  # first host number not already used by another container on this network
  for n in {2..254}; do grep -qs "ip=$net\.$n/" /etc/pve/lxc/*.conf || { DEF_IP=$net.$n/24; break; }; done
  [[ ${HA_LOCAL_URL:-} == *.local* ]] && echo "NOTE: HA_LOCAL_URL uses a .local name; those don't resolve through NAT. Use Home Assistant's IP in ha-kiosk.conf."
fi

echo; echo "== Container settings (Enter accepts default)"
CTID=$(ask "Container ID" "$(pvesh get /cluster/nextid)")
echo "Storages that can hold containers:"; pvesm status -content rootdir
STORAGE=$(ask "Root disk storage" "local-lvm")
BRIDGE=$(ask "Network bridge" "$DEF_BRIDGE")
IPCFG=$(ask "IP (dhcp or CIDR like 192.168.1.50/24)" "$DEF_IP")
GW=""; [[ $IPCFG != dhcp ]] && GW=",gw=$(ask "Gateway" "$DEF_GW")"
echo "Proxmox web UI > container > Console normally shows a login prompt, and this container has no root password."
CMODE=(); yes_default "Make Console open straight to a root shell? (only Proxmox admins can open it)" && CMODE=(--cmode shell)

pveam update >/dev/null
# Template must match the host CPU (the list has both amd64 and arm64 builds).
ARCH=$(dpkg --print-architecture)
TEMPLATE=$(pveam available --section system | awk -v a="_$ARCH.tar" '/debian-13-standard/ && index($2, a) {print $2}' | sort -V | tail -1)
[[ -n $TEMPLATE ]] || die "No Debian 13 $ARCH template listed by pveam."

LXC_LINES="lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 13:* rwm
lxc.cgroup2.devices.allow: c 4:$VT rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir
lxc.mount.entry: /dev/tty$VT dev/tty$VT none bind,optional,create=file
lxc.mount.entry: tmpfs run tmpfs rw,nosuid,nodev,mode=755,create=dir 0 0
lxc.mount.entry: /run/udev run/udev none bind,ro,optional,create=dir"

CREATE=(pct create "$CTID" "local:vztmpl/$TEMPLATE" --hostname "${KIOSK_HOSTNAME:-ha-kiosk}" --unprivileged 0 --features nesting=1
  --cores 2 --memory 2048 --swap 512 --rootfs "$STORAGE:8"
  --net0 "name=eth0,bridge=$BRIDGE,ip=$IPCFG$GW" --onboot 1 --ostype debian "${CMODE[@]}")

cat <<PLAN

================ PLAN ================
Template: $TEMPLATE (downloaded to 'local' if missing)
Command:  ${CREATE[*]}
Appended to /etc/pve/lxc/$CTID.conf:
$LXC_LINES

Then: copy ha-kiosk.conf + container-setup.sh into the container and run it.
======================================
PLAN
yes_no "Apply this plan?" || { echo "Nothing changed."; exit 0; }

pveam list local | grep -q "$TEMPLATE" || pveam download local "$TEMPLATE"
"${CREATE[@]}"
printf '%s\n' "$LXC_LINES" >> "/etc/pve/lxc/$CTID.conf"
pct start "$CTID"
echo "Waiting for container network..."
for i in {1..30}; do pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break; sleep 2; done
pct push "$CTID" "$HERE/ha-kiosk.conf" /etc/ha-kiosk.conf
pct push "$CTID" "$HERE/container-setup.sh" /root/container-setup.sh --perms 755
pct exec "$CTID" -- mkdir -p /root/ha-kiosk-files
for f in "$HERE"/files/*; do pct push "$CTID" "$f" "/root/ha-kiosk-files/$(basename "$f")"; done
pct exec "$CTID" -- /root/container-setup.sh "$(printf '%s' "$touch" | grep -c . || true)"

LID=/etc/systemd/logind.conf.d/ha-kiosk-lid.conf
cat <<LIDPLAN

Optional host change so closing/folding the lid never suspends the host:
$LID
  [Login]
  HandleLidSwitch=ignore
  HandleLidSwitchExternalPower=ignore
  HandleLidSwitchDocked=ignore
LIDPLAN
if yes_no "Write it? (takes effect after reboot)"; then
  mkdir -p "$(dirname "$LID")"
  printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n' > "$LID"
fi
cat <<DONE

Done. Reboot the host to confirm the kiosk comes up on its own.

Managing the kiosk: Proxmox web UI > $CTID > Console$([[ ${#CMODE[@]} -eq 0 ]] && echo " (login: set a password with 'pct exec $CTID -- passwd', or use 'pct enter $CTID' from the host Shell)")
  ha-kiosk-rotate status | left | right | normal | inverted | lock | unlock
  nano /etc/ha-kiosk.conf          then: systemctl restart ha-kiosk
  journalctl -u ha-kiosk -f        logs
From the host shell, prefix any of these with: pct exec $CTID --
DONE
