# Running the Proxmox host on Wi-Fi

Old laptops and mini PCs repurposed as kiosks often have no convenient Ethernet. Proxmox VE can run
on Wi-Fi, with limits. **Status: not yet tested on our devices** — this is Proxmox's documented NAT
setup plus the Wi-Fi pattern Proxmox forum users report working.

**Automated:** `./wifi-setup.sh` on the Proxmox host does steps 1–3 below (and `host-setup.sh` offers
to run it and then puts the kiosk on the NAT bridge). The manual steps are here for reference and
for troubleshooting.

## What you need to know first

- Proxmox says ["Avoid using WLAN if possible"](https://pve.proxmox.com/wiki/WLAN): expect more
  latency spikes and less reliability than Ethernet.
- **Guests can't be bridged onto Wi-Fi.** The access point only accepts frames from the host's own MAC
  address and drops traffic from container/VM MACs. So guests sit on a private internal bridge and
  share the host's connection through NAT (masquerading).
- **For a kiosk that's fine**: it only makes outgoing connections (to Home Assistant). The trade-off is
  that other machines on your LAN can't reach the container directly; manage it from the host
  (`pct enter <id>`) or the Proxmox web UI at the host's Wi-Fi IP.
- Don't install NetworkManager on the host (Proxmox advises against it); use `wpa_supplicant` with
  `/etc/network/interfaces`, which Proxmox's `ifupdown2` reads.

## 1. While still on Ethernet: install the tools

`wpasupplicant` isn't installed on Proxmox by default, so do this before unplugging:

```bash
apt update && apt install -y wpasupplicant iw
ip -br link           # note your Wi-Fi interface name, e.g. wlp58s0
```

If the interface doesn't appear, the Wi-Fi chip's driver/firmware isn't loading:
`lspci -nnk | grep -iA3 network` and `dmesg | grep -iE 'iwlwifi|ath|firmware'`.

## 2. Store the Wi-Fi credentials

`wpa_passphrase` stores a hash instead of your plain password:

```bash
wpa_passphrase 'YourNetworkName' 'YourPassword' > /etc/wpa_supplicant/wpa_supplicant.conf
sed -i '/#psk=/d' /etc/wpa_supplicant/wpa_supplicant.conf   # drop the plaintext comment line
chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
```

## 3. Network config

Put this in its own file so the Proxmox GUI doesn't rewrite it. Replace `wlp58s0` with your
interface name. Check that `/etc/network/interfaces` contains `source /etc/network/interfaces.d/*`
(add it at the end if not).

`/etc/network/interfaces.d/wifi`:

```
# Host on Wi-Fi (DHCP from your router)
auto wlp58s0
iface wlp58s0 inet dhcp
        wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
        # Wi-Fi power saving causes dropouts on many laptop chips
        post-up iw dev wlp58s0 set power_save off

# Private network for containers, NAT out through Wi-Fi
# (masquerade lines from https://pve.proxmox.com/wiki/Network_Configuration)
auto vmbr1
iface vmbr1 inet static
        address 10.10.10.1/24
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
        post-up   iptables -t nat -A POSTROUTING -s '10.10.10.0/24' -o wlp58s0 -j MASQUERADE
        post-down iptables -t nat -D POSTROUTING -s '10.10.10.0/24' -o wlp58s0 -j MASQUERADE
        # Only needed if the Proxmox firewall is enabled:
        # post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
        # post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
```

**Only one default gateway.** If `vmbr0` (the Ethernet bridge) in `/etc/network/interfaces` has a
`gateway` line and you're going Wi-Fi-only, remove that line so the Wi-Fi DHCP route is used.
Also update the host's IP in `/etc/hosts` to the Wi-Fi address (Proxmox expects its hostname to
resolve to a reachable IP).

Apply without rebooting, then check:

```bash
ifreload -a
ip -br addr show wlp58s0      # should have an IP from your router
ping -c3 1.1.1.1
```

Tip: give the host a DHCP reservation on your router so the web UI address doesn't move.

## 4. Put the container on the private network

For a new kiosk, answer `host-setup.sh`'s prompts with bridge `vmbr1`, IP `10.10.10.2/24`,
gateway `10.10.10.1`. For an existing container:

```bash
pct set <id> --net0 name=eth0,bridge=vmbr1,ip=10.10.10.2/24,gw=10.10.10.1
pct reboot <id>
pct exec <id> -- curl -sI http://<home-assistant-ip>:8123 | head -1   # should print an HTTP status
```

DNS: by default the container uses the host's DNS settings. If names don't resolve, set one
explicitly: `pct set <id> --nameserver <your router IP>`.

Use `HA_LOCAL_URL` with Home Assistant's **IP address** if `homeassistant.local` doesn't resolve —
mDNS (`.local` names) doesn't cross NAT.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `wpa_supplicant` pre-up script fails | Wrong interface name in the config, or `wpasupplicant` not installed |
| Host connected, container has no internet | `ip_forward` not 1 (`cat /proc/sys/net/ipv4/ip_forward`) or MASQUERADE rule missing (`iptables -t nat -S`) |
| Works, then drops after a while | Power saving: `iw dev <if> get power_save` should say `off` |
| Container works but Home Assistant URL fails | `.local` name over NAT; use the IP |
