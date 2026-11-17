#!/usr/bin/env bash
# Put a Proxmox VE host on Wi-Fi and create a private NAT bridge for containers/VMs.
# Guests can't be bridged onto Wi-Fi (the access point drops frames from their MACs), so they share
# the host's connection via NAT. Shows every change and asks before applying. Safe to re-run.
# Background and manual steps: docs/wifi.md
set -euo pipefail
die(){ echo "ERROR: $*" >&2; exit 1; }
ask(){ local r; read -rp "$1 [$2]: " r; echo "${r:-$2}"; }
yes_no(){ local r; read -rp "$1 [y/N]: " r; [[ $r == [yY]* ]]; }
shopt -s nullglob

command -v pveversion >/dev/null || die "Run this on the Proxmox host."
CONF=/etc/network/interfaces.d/wifi
WPA=/etc/wpa_supplicant/wpa_supplicant.conf

WIFI=""
for i in /sys/class/net/*; do [[ -d $i/wireless ]] && { WIFI=$(basename "$i"); break; }; done
[[ -n $WIFI ]] || die "No Wi-Fi interface found. Check the driver: lspci -nnk | grep -iA3 network"
echo "Wi-Fi interface: $WIFI"

# Existing NAT bridge (ours or hand-made): a vmbr stanza with a MASQUERADE line.
# Prints "bridge address file".
existing=$(awk '/^iface /{i=$2; a=""} /^[ \t]+address /{a=$2} /MASQUERADE/ && i ~ /^vmbr/ {print i, a, FILENAME; exit}' \
  /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null || true)
read -r EX_BR EX_ADDR EX_FILE <<<"$existing" || true
if [[ -n $existing ]] && ip -4 -br addr show "$WIFI" | grep -q '[0-9]\.'; then
  echo "Already set up: $WIFI is connected and NAT bridge $EX_BR ($EX_ADDR) exists. Nothing to do."
  exit 0
fi

# The Wi-Fi interface must not already be configured outside our file (duplicate stanzas break ifupdown2).
other=$(grep -ls "iface $WIFI\b" /etc/network/interfaces /etc/network/interfaces.d/* | grep -vx "$CONF" || true)
[[ -z $other ]] || die "$WIFI is already configured in: $other. Remove that stanza first, or keep using it."

echo "== Packages (wpasupplicant, iw)"
if ! command -v wpa_passphrase >/dev/null || ! command -v iw >/dev/null; then
  if ! apt-get update; then
    # Fresh installs point at the paid enterprise repos, which return 401 without a subscription.
    ent=""
    for f in /etc/apt/sources.list.d/*.sources; do
      grep -q enterprise.proxmox.com "$f" && ! grep -q '^Enabled: no' "$f" && ent+="$f "
    done
    [[ -n $ent ]] || die "apt-get update failed (see above)."
    cat <<PLAN

apt failed because of the Proxmox enterprise repos (need a paid subscription). Proposed fix:
  - add 'Enabled: no' to: $ent
  - add /etc/apt/sources.list.d/proxmox.sources (free pve-no-subscription repo)
PLAN
    yes_no "Apply?" || die "Can't install wpasupplicant without a working apt."
    for f in $ent; do echo 'Enabled: no' >> "$f"; done
    grep -rqs pve-no-subscription /etc/apt/sources.list.d/ || cat > /etc/apt/sources.list.d/proxmox.sources <<'SRC'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
SRC
    apt-get update
  fi
  apt-get install -y wpasupplicant iw
fi
echo "OK"

echo "== Wi-Fi credentials"
if [[ -s $WPA ]] && ! yes_no "$WPA exists (network: $(sed -n 's/^\s*ssid="\(.*\)"/\1/p' "$WPA" | head -1)). Replace it?"; then
  echo "Keeping existing credentials."
else
  read -rp "Wi-Fi name (SSID): " SSID
  read -rsp "Wi-Fi password: " PSK; echo
  # Stores a hash, not the password; drop the plaintext comment wpa_passphrase adds.
  wpa_passphrase "$SSID" "$PSK" | sed '/#psk=/d' > "$WPA.new" || die "wpa_passphrase failed (password must be 8-63 characters)."
  unset PSK
  chmod 600 "$WPA.new"; mv "$WPA.new" "$WPA"
fi

if [[ -n $existing ]]; then
  BR=$EX_BR; NET=${EX_ADDR%.*}
  echo "Reusing existing NAT bridge $BR ($EX_ADDR)."
  # Defined in the file we're about to rewrite: write it again, otherwise leave it where it is.
  [[ $EX_FILE == "$CONF" ]] && existing=""
else
  BR=""
  for n in {1..9}; do grep -qs "iface vmbr$n\b" /etc/network/interfaces /etc/network/interfaces.d/* || { BR=vmbr$n; break; }; done
  [[ -n $BR ]] || die "No free vmbr1-9 name."
  NET=$(ask "Private network for containers (first three parts of a /24)" "10.10.10")
fi

new=$(mktemp)
cat > "$new" <<EOF
# Written by wifi-setup.sh (ha-kiosk-lxc). Host on Wi-Fi + NAT bridge for guests.
auto $WIFI
iface $WIFI inet dhcp
        wpa-conf $WPA
        # Wi-Fi power saving causes dropouts on many laptop chips
        post-up iw dev $WIFI set power_save off
EOF
if [[ -z $existing ]]; then cat >> "$new" <<EOF

# Containers use this bridge with IPs $NET.2-254, gateway $NET.1
auto $BR
iface $BR inet static
        address $NET.1/24
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
        post-up   iptables -t nat -A POSTROUTING -s '$NET.0/24' -o $WIFI -j MASQUERADE
        post-down iptables -t nat -D POSTROUTING -s '$NET.0/24' -o $WIFI -j MASQUERADE
EOF
fi

echo; echo "================ PLAN ================"
echo "Write $CONF:"; echo; cat "$new"
grep -q '^source /etc/network/interfaces.d/\*' /etc/network/interfaces \
  || echo "Append to /etc/network/interfaces: source /etc/network/interfaces.d/*"
echo "Then: ifreload -a  (Ethernet keeps working)"
echo "======================================"
if [[ -f $CONF ]]; then echo "Note: replaces existing $CONF:"; diff "$CONF" "$new" || true; fi
yes_no "Apply?" || { rm -f "$new"; echo "Nothing changed."; exit 0; }

mv "$new" "$CONF"; chmod 644 "$CONF"
grep -q '^source /etc/network/interfaces.d/\*' /etc/network/interfaces || echo 'source /etc/network/interfaces.d/*' >> /etc/network/interfaces
ifreload -a

echo "Waiting for $WIFI to get an address..."
for i in {1..20}; do ip -4 -br addr show "$WIFI" | grep -q '[0-9]\.' && break; sleep 2; done
ip -br addr show "$WIFI" "${BR}"
if ping -c2 -W3 -I "$WIFI" 1.1.1.1 >/dev/null 2>&1; then echo "Wi-Fi works."
else echo "WARNING: no internet over $WIFI yet. Check: journalctl -b | grep -i wpa ; see docs/wifi.md troubleshooting."; fi

cat <<NEXT

Containers: use bridge $BR, IP $NET.2/24 (or .3, .4 ...), gateway $NET.1.
Use Home Assistant's IP address, not homeassistant.local (.local names don't cross NAT).
Wi-Fi only from now on? Remove the 'gateway' line under vmbr0 in /etc/network/interfaces,
put the Wi-Fi IP for this host in /etc/hosts, run ifreload -a, then unplug Ethernet.
Do that from the local keyboard, not over SSH.
NEXT
