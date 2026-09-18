# Nile WIPS Demo Pi

Turn a Raspberry Pi into a pre-canned, repeatable demo of three WIPS
(Wireless Intrusion Prevention System) detection scenarios — **rogue AP**,
**honeypot AP**, and **suspected rogue AP** — using only the Pi's onboard
Wi-Fi radio. One script, no files to hand-edit, safe to re-run and switch
scenarios on the fly.

> **Authorized use only.** This script turns the Pi into an access point
> that can clone a real SSID and bridge clients onto your wired LAN. Only
> run it on networks and in environments you own or are explicitly
> authorized to test. Don't point it at production networks or anyone
> else's infrastructure.

---

## What it actually does

| Mode | SSID (default) | Bridged to your wired LAN? | Simulates |
|---|---|---|---|
| `rogue` | `Nile-Corp` (real corp SSID) | **Yes** — clients get a real LAN IP | Someone plugging an unauthorized AP into your wired network and cloning your corp SSID |
| `honeypot` | `Nile-Corp` (real corp SSID) | No — beacon only, isolated | Same bait SSID, but a dead end — no LAN access for anyone who joins |
| `suspected` | `FreeWiFi-Guest` (unrelated SSID) | No — beacon only, isolated | An unknown/unauthorized AP nearby that isn't impersonating your identity |

Everything else (MAC pinning, channel, security, package installs,
NetworkManager handoff) is identical across modes — only the SSID and
whether `wlan0` gets bridged onto `eth0` changes. See
[How it works](#how-it-works) for the mechanics.

---

## Supported hardware

- Raspberry Pi 3B, 3B+, 4, or 5 — onboard Wi-Fi only (no USB Wi-Fi dongle needed or used)
- Raspberry Pi OS Bookworm or Trixie (Lite recommended — no desktop needed)

**One hardware caveat that matters:** the plain **Pi 3B (BCM43438) is
2.4GHz-only** — don't use `--channel 36/40/44/48` on it, those are 5GHz-only
and will fail to start. Pi 3B+/4/5 all use dual-band radios (2.4GHz +
5GHz, non-DFS channels 36/40/44/48 only) and will handle either.

---

## ⚠️ Before you start: you have exactly one radio

This guide assumes the Pi has **no second Wi-Fi adapter** — just the
onboard radio. That radio currently gets used for two different jobs at
different times:

1. **Before you run the script**: as a normal Wi-Fi *client* (`wlan0`),
   optionally used to get the Pi onto your network for the initial setup.
2. **After you run the script**: as the demo *access point* — `hostapd`
   takes it over completely. It stops being a client.

**This means:** if the only way you're connected to the Pi is Wi-Fi, your
SSH session drops the moment you run `rogue`/`honeypot`/`suspected`/`reset`
— by design, not by bug. The script is built to survive that (see
[How it works](#how-it-works)), but *you* still lose your remote session.

**Strong recommendation: plug in Ethernet before you run the script**, even
if you used Wi-Fi to do everything up to that point. As long as `eth0` is
connected to your LAN, the Pi will pick up a normal DHCP address on that
link (via the bridge, `br0`) and you can keep managing it — switch modes,
change the SSID, `stop`, `reset` — entirely over Ethernet afterward.

If you truly have no Ethernet available, you can still run the demo, but
after the AP comes up, the *only* way to send it another command is
physical console access (HDMI + keyboard) until you `reset` it back to a
station.

---

## Step-by-step: image to running demo

### 1. Flash the SD card with Raspberry Pi Imager

Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/) on
any computer, then:

1. **Choose OS** → Raspberry Pi OS (other) → **Raspberry Pi OS Lite (64-bit)**
   (Bookworm or Trixie — no desktop environment needed for this).
2. **Choose Storage** → your SD card.
3. Click the **gear icon** (or press `Ctrl+Shift+X`) to open **OS
   Customisation** before writing. This is the single most important step
   for a fully headless, no-monitor setup — set all of the following here:
   - **Hostname** — e.g. `nile-wips-demo`
   - **Username and password** — required; modern Raspberry Pi OS has no
     default `pi`/`raspberry` login anymore
   - **Configure wireless LAN** — SSID, password, and **Wireless LAN
     country** of the network you want the Pi to join *for internet access
     during setup* (this is **not** the demo SSID — see the warning below)
   - **Enable SSH** → "Use password authentication" (or paste a public key)
   - Locale/timezone/keyboard as you like
4. Click **Save**, then **Write**, and let it finish and verify.

> ⚠️ **Don't confuse the two SSIDs.** The Wi-Fi network you configure here
> in Imager is only so the Pi can reach the internet to download this
> script. The SSID the *demo* broadcasts (`Nile-Corp`, `FreeWiFi-Guest`,
> or whatever you pass with `--ssid`) is completely separate and is set
> later, when you run the script.

### 2. First boot

Insert the SD card into the Pi. If you can, **connect an Ethernet cable**
to your LAN now (see the warning above) — plug it in before powering on.
Then power on the Pi and wait ~60–90 seconds for first boot.

### 3. Find the Pi's IP address

- Easiest: check your router's DHCP client list for the hostname you set.
- Or, from another machine on the same network:
  ```bash
  ping nile-wips-demo.local
  ```
  (mDNS/Avahi is on by default on Raspberry Pi OS — replace with whatever
  hostname you set.)
- Or scan your LAN: `nmap -sn 192.168.1.0/24` (adjust to your subnet).

### 4. SSH in

```bash
ssh <username>@nile-wips-demo.local
```

If you connected both Ethernet and the pre-configured Wi-Fi, either
address will work at this point — they're two independent links into the
same Pi until the script runs.

---

## If you skipped something in Imager

### Didn't enable SSH?

**Headless fix (no monitor needed), if you already set a username/password
in Imager:** pull the SD card, mount its **boot** partition on another
computer, and create an empty file named exactly `ssh` (no extension) in
it. Re-insert and boot — SSH is enabled automatically on first boot.

**If you have a monitor + keyboard you can connect to the Pi once:** boot
it, log in at the local console (completing the first-boot setup wizard if
you never set a user via Imager), then run:

```bash
sudo raspi-config
```

Navigate: **Interface Options → SSH → Yes** → Finish (reboot if prompted).

Or skip the menus entirely with the non-interactive equivalent, once you
have *any* shell on the Pi:

```bash
sudo raspi-config nonint do_ssh 0   # 0 = enable, 1 = disable
```

### Didn't set Wi-Fi credentials in Imager?

You need the Pi to reach the internet once, to download this script and
install its dependencies. Two options:

**Option A — Ethernet (simplest, no commands needed):** plug the Pi into
any switch/router with a DHCP server and internet access. It'll just work.

**Option B — connect to Wi-Fi manually over SSH/console**, once you have a
shell (e.g. via Ethernet, or the SSH fixes above):

```bash
# Set your country first — Wi-Fi stays rfkill-blocked without one
sudo raspi-config nonint do_wifi_country US   # use your actual country code
sudo rfkill unblock wifi

# See what's around
sudo nmcli device wifi list

# Connect (omit `password ...` entirely for an open network)
sudo nmcli device wifi connect "YourNetworkSSID" password "YourWiFiPassword"

# Confirm you're online
ping -c 3 github.com
```

---

## 5. Get the script onto the Pi

Once you have SSH (or console) access and the Pi can reach the internet:

```bash
git clone https://github.com/soleng2018/wips.git
cd wips
chmod +x nile-wips.sh
```

(Or, without `git`: `curl -O https://raw.githubusercontent.com/soleng2018/wips/main/nile-wips.sh && chmod +x nile-wips.sh`.)

You do **not** need to install anything by hand first — the script installs
its own dependencies (`hostapd`, `iw`, `rfkill`, `iproute2`) automatically
the first time it runs, while the Pi still has whatever network got you
this far. See [What it installs](#what-it-installs) below.

---

## 6. Run it

```bash
sudo ./nile-wips.sh rogue
```

That's the whole procedure — package installs, Wi-Fi country/rfkill setup,
network bridging, MAC pinning, and the AP itself all happen in this one
command. No reboot required.

**If you're connected over Wi-Fi (`wlan0`) right now**, your SSH session
will drop partway through this command — that's `wlan0` becoming the AP,
as explained above. The script itself keeps running to completion
regardless (it detaches into a systemd unit specifically so a dropped
session can't leave the Pi half-configured) — you just won't see the final
"OK" message. Reconnect over Ethernet afterward to confirm it worked:

```bash
ssh <username>@nile-wips-demo.local   # now resolves via Ethernet/br0's DHCP lease
sudo ./nile-wips.sh status
```

---

## Command reference

```
sudo ./nile-wips.sh rogue        # corp SSID, BRIDGED to LAN   -> ROGUE
sudo ./nile-wips.sh honeypot     # corp SSID, off-wire         -> HONEYPOT
sudo ./nile-wips.sh suspected    # unknown SSID, off-wire      -> SUSPECTED
sudo ./nile-wips.sh stop         # stop ONLY the AP beacon (bridge/MACs stay)
sudo ./nile-wips.sh reset        # full revert to stock networking
sudo ./nile-wips.sh status       # show what's currently running
sudo ./nile-wips.sh --help       # usage (works without sudo)
```

### Flags (override via flag or environment variable)

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `--ssid NAME` | `SSID` | mode default (`Nile-Corp` / `FreeWiFi-Guest`) | Broadcast SSID |
| `--channel N` | `CHANNEL` | `6` | 1–14 = 2.4GHz, 36/40/44/48 = 5GHz (3B+/4/5 only) |
| `--country CC` | `COUNTRY` | `US` | Wi-Fi regulatory country code |
| `--security open\|wpa2` | `SECURITY` | `open` | Open or WPA2-PSK |
| `--pass PSK` | `PASSPHRASE` | `ChangeMe123` | WPA2 passphrase (only used with `--security wpa2`) |
| `--br0-mac AA:BB:..` | `BR0_MAC` | `02:1a:2b:3c:4d:00` | MAC seen on the wire (what your switch learns) |
| `--wlan-mac AA:BB:..` | `WLAN_MAC` | `02:1a:2b:3c:4d:01` | The AP's BSSID |

> **Always quote flag values**, e.g. `--ssid "Nile Corp"`. This is standard
> shell behavior, not anything specific to the script — without quotes,
> your shell splits on spaces and hands the script two separate arguments
> instead of one (`--ssid Nile Corp` fails with `Unknown arg: Corp`). It's
> easy to forget when your SSID happens to have no spaces today and gets
> one later, so quote it every time as a habit — same goes for `--pass` if
> your passphrase has spaces or shell-special characters (`$`, `!`, `*`, etc.).

### Examples

```bash
# Switch SSID or mode — just re-run, no reset needed
sudo ./nile-wips.sh rogue --ssid "Nile-Corp"
sudo ./nile-wips.sh honeypot --channel 44          # 5GHz, non-DFS (3B+/4/5 only)
sudo ./nile-wips.sh suspected --ssid "Random-Guest-AP"

# Secured demo AP instead of open
sudo ./nile-wips.sh rogue --security wpa2 --pass "SomePassphrase123"

# Stop the beacon but keep everything else configured
sudo ./nile-wips.sh stop

# Fully revert to stock networking (hands eth0/wlan0/br0 back to NetworkManager)
sudo ./nile-wips.sh reset
```

Any single flag change takes effect immediately on the next run — the
script always regenerates the full `hostapd` config and restarts it.
`reset` is only for tearing everything down, not for routine mode
switching.

---

## Verifying the AP is actually live

Since there's no second radio on the Pi to scan with, verify from a
**different device** — a phone or laptop:

1. Open its Wi-Fi network list and confirm the SSID appears
   (`Nile-Corp`, `FreeWiFi-Guest`, or whatever you set).
2. For `rogue` mode, join it and confirm you get a real IP address on your
   LAN's subnet (via DHCP) — that's the "bridged" behavior. For
   `honeypot`/`suspected`, joining should get you nothing useful — that's
   expected, they're intentionally isolated.

You can also confirm from the Pi itself, without another radio:

```bash
sudo ./nile-wips.sh status
sudo systemctl status hostapd@nile
```

---

## What it installs

The first time you run a mode that needs them, the script installs (via
`apt-get`) whatever's missing from:

- `hostapd` — runs the actual access point
- `iw` — Wi-Fi configuration
- `rfkill` — unblocking the radio
- `iproute2` — interface/bridge management (usually already present)

This step runs **before** any network reconfiguration, and hard-stops
without touching anything if the install fails — so a failed install never
leaves the Pi half-configured.

---

## How it works

- `hostapd` runs the AP on `wlan0`, using a config file this script
  generates fresh on every run (`/etc/hostapd/nile.conf`).
- A bridge (`br0`) always exists with `eth0` as a member; in `rogue` mode
  `wlan0` joins it too (via `hostapd`'s own `bridge=` option), giving
  connected clients real LAN access. In `honeypot`/`suspected`, `wlan0`
  stays off the bridge.
- `eth0` and `wlan0`'s MAC addresses are pinned (via `systemd-networkd`)
  so your switch and the AP's BSSID stay deterministic across reboots and
  mode switches.
- `NetworkManager` is told to leave `eth0`/`wlan0`/`br0` alone
  (`unmanaged-devices`) and the change is applied with a config **reload**,
  not a full restart — a full restart would drop and reconnect *every*
  NetworkManager-managed connection on the box, not just these three.
- Because reconfiguring `wlan0` can drop the very SSH session running the
  script (if you're connected over Wi-Fi), the actual work re-launches
  itself as a detached, uniquely-named `systemd-run` transient unit. That
  unit keeps running under PID 1 independent of your session, so a dropped
  connection mid-run can never leave the Pi half-configured.
- Everything the script writes is a real config file (`systemd-networkd`
  `.network`/`.netdev`/`.link` files, a `hostapd@.service` unit, an
  `hostapd` config, an `NetworkManager` conf.d snippet) — so the whole
  setup survives a reboot with no extra steps.

---

## Troubleshooting

**hostapd fails to start / AP doesn't come up.** Check the log:
```bash
sudo journalctl -u hostapd@nile -n 50
```
Most common cause on a very fresh image: Wi-Fi regulatory country wasn't
set yet. The script sets it automatically on every run, but if you're
still stuck, set it explicitly and re-run:
```bash
sudo raspi-config nonint do_wifi_country US
sudo ./nile-wips.sh rogue
```

**Lost SSH right after running the script.** Expected if you were
connected over `wlan0` — see the [one-radio warning](#️-before-you-start-you-have-exactly-one-radio)
above. Reconnect over Ethernet.

**Checking whether the detached apply step actually finished/succeeded:**
```bash
sudo journalctl -u 'nile-wips-apply-*' -n 60
```

**Want to inspect exactly what changed on disk before trusting it:**
```bash
cat /etc/hostapd/nile.conf
cat /etc/NetworkManager/conf.d/99-nile-wips.conf
ls /etc/systemd/network/
```

**Full revert to stock networking:**
```bash
sudo ./nile-wips.sh reset
sudo reboot   # optional, but guarantees a fully clean state
```

---

## Uninstall

`reset` removes every file this script created and hands the interfaces
back to `NetworkManager`. Nothing survives a subsequent `reboot` — the Pi
returns to exactly the networking behavior of a stock image.
