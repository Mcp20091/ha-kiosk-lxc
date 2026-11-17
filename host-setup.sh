#!/usr/bin/env bash
# Run on the Proxmox host of the kiosk device. Checks hardware, shows the plan, asks before changing anything.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/ha-kiosk.conf"
VT=${KIOSK_VT:-7}

die(){ echo "ERROR: $*" >&2; exit 1; }
ask(){ local r; read -rp "$1 [$2]: " r; echo "${r:-$2}"; }
yes_no(){ local r; read -rp "$1 [y/N]: " r; [[ $r == [yY]* ]]; }

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

echo "== VT$VT"
systemctl is-active --quiet "getty@tty$VT" && die "A login prompt is running on tty$VT; pick another KIOSK_VT."
[[ -e /dev/tty$VT ]] || die "/dev/tty$VT missing."
echo "tty$VT is free."

echo; echo "== Container settings (Enter accepts default)"
CTID=$(ask "Container ID" "$(pvesh get /cluster/nextid)")
echo "Storages that can hold containers:"; pvesm status -content rootdir
STORAGE=$(ask "Root disk storage" "local-lvm")
BRIDGE=$(ask "Network bridge" "vmbr0")
IPCFG=$(ask "IP (dhcp or CIDR like 192.168.1.50/24)" "dhcp")
GW=""; [[ $IPCFG != dhcp ]] && GW=",gw=$(ask "Gateway" "")"

pveam update >/dev/null
TEMPLATE=$(pveam available --section system | awk '/debian-13-standard/{print $2}' | sort -V | tail -1)
[[ -n $TEMPLATE ]] || die "No Debian 13 template listed by pveam."

LXC_LINES="lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 13:* rwm
lxc.cgroup2.devices.allow: c 4:$VT rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir
lxc.mount.entry: /dev/tty$VT dev/tty$VT none bind,optional,create=file
lxc.mount.entry: tmpfs run tmpfs rw,nosuid,nodev,mode=755,create=dir 0 0
lxc.mount.entry: /run/udev run/udev none bind,ro,optional,create=dir"

CREATE=(pct create "$CTID" "local:vztmpl/$TEMPLATE" --hostname "${KIOSK_HOSTNAME:-ha-kiosk}" --unprivileged 0
  --cores 2 --memory 2048 --swap 512 --rootfs "$STORAGE:8"
  --net0 "name=eth0,bridge=$BRIDGE,ip=$IPCFG$GW" --onboot 1 --ostype debian)

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
echo; echo "Done. Reboot the host to confirm the kiosk comes up on its own."
