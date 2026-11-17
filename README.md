# ha-kiosk-lxc

Turn a Proxmox VE laptop or tablet (touchscreen optional) into a Home Assistant wall dashboard.
The host keeps the GPU and input devices; a privileged Debian 13 LXC runs Xorg + Chromium in
kiosk mode on a spare host VT (tty7 by default), with touch passed through.

Built against Proxmox VE 9.x. **Hardware status: not yet tested on real devices.**

## Install (on the Proxmox host, as root)

```bash
curl -L https://github.com/Mcp20091/ha-kiosk-lxc/archive/refs/heads/main.tar.gz | tar xz
cd ha-kiosk-lxc-main
nano ha-kiosk.conf      # set URLs, dashboard path, hostname, rotation, scale
./host-setup.sh
```

`host-setup.sh` checks the GPU, touchscreen and VT, asks for container ID / storage / bridge / IP,
prints the full plan (the `pct create` command and the LXC config lines), and changes nothing
until you answer `y`. It then creates the container and runs `container-setup.sh` inside it.

## Configuration (`ha-kiosk.conf`)

| Setting | Meaning |
|---|---|
| `HA_LOCAL_URL` / `HA_REMOTE_URL` | Base URLs. Local is used when Home Assistant answers there, otherwise remote. |
| `HA_DASHBOARD_PATH` | Path only, e.g. `dashboard-wall/0` |
| `KIOSK_VT` | Host VT for the kiosk (default 7) |
| `KIOSK_HOSTNAME` | Container hostname |
| `KIOSK_ROTATION` | `auto` (accelerometer, default), `normal`, `left`, `right`, `inverted`; touch follows |
| `KIOSK_SCALE` | UI zoom for high-DPI panels, e.g. `1.5` |
| `KIOSK_OUTPUT` | Display output; empty = built-in panel |

To change settings later: edit `/etc/ha-kiosk.conf` inside the container, then `systemctl restart ha-kiosk`.

## Rotation

`auto` reads the screen's accelerometer straight from the kernel (`/sys/bus/iio`), applies the
device's axis correction from udev's sensor database, and uses the same 35° tilt rule as
iio-sensor-proxy (what GNOME/KDE use). Lying flat keeps the current orientation; a turn must
hold for ~2 s before the screen rotates. No accelerometer = stays `normal`, manual still works.

From the Proxmox host (replace `<id>` with the container ID):

```bash
pct exec <id> -- ha-kiosk-rotate status     # mode, on-screen orientation, live sensor reading
pct exec <id> -- ha-kiosk-rotate lock       # freeze at current orientation
pct exec <id> -- ha-kiosk-rotate unlock     # back to auto
pct exec <id> -- ha-kiosk-rotate left       # manual: normal | left | right | inverted
pct exec <id> -- ha-kiosk-rotate reset      # back to KIOSK_ROTATION from the config
```

The chosen mode is saved in `/var/lib/ha-kiosk/rotation` and survives reboots.
If auto-rotate turns the wrong way, run `status` while holding the device upright and open an issue
with the output (the axis-correction data for that model is wrong or missing).

## What gets added to `/etc/pve/lxc/<id>.conf`

```
lxc.cgroup2.devices.allow: c 226:* rwm      # GPU (/dev/dri)
lxc.cgroup2.devices.allow: c 13:* rwm       # input (/dev/input)
lxc.cgroup2.devices.allow: c 4:7 rwm        # kiosk VT
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir
lxc.mount.entry: /dev/tty7 dev/tty7 none bind,optional,create=file
lxc.mount.entry: tmpfs run tmpfs rw,nosuid,nodev,mode=755,create=dir 0 0
lxc.mount.entry: /run/udev run/udev none bind,ro,optional,create=dir
```

The `tmpfs run` entry stops the container's systemd from mounting a fresh `/run` over the
host's `/run/udev` bind mount; without udev data, libinput can't recognise the touchscreen.

## Notes and limits

- First start: log in to Home Assistant on the kiosk with a keyboard and tick "Keep me logged in".
  Local and remote URLs are separate logins.
- Proprietary NVIDIA drivers are not supported (needs a kernel modesetting driver: i915, xe, amdgpu, nouveau).
- Microsoft Surface Pro 4+ / Laptop touchscreens need linux-surface drivers that the Proxmox kernel
  doesn't include; those devices run display-only.
- Optional host change offered at the end: ignore lid close so the host never suspends.

## No Ethernet? Running the host on Wi-Fi

See [docs/wifi.md](docs/wifi.md): guests can't be bridged onto Wi-Fi, so the kiosk container sits on a
private NAT network behind the host. That's fine for a kiosk, which only connects out to Home Assistant.

## Troubleshooting (inside the container)

```bash
journalctl -u ha-kiosk -f
cat ~kiosk/.local/share/xorg/Xorg.0.log
udevadm info -q property -n /dev/input/eventN | grep ID_INPUT
```
