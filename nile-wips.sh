#!/usr/bin/env bash
# ============================================================
# Nile WIPS demo Pi — single script, mode passed INLINE. No files to edit.
# Raspberry Pi OS Bookworm/Trixie, Pi 3B / 3B+ / 4 / 5, onboard Wi-Fi.
# NOTE: Pi 3B (BCM43438) is 2.4GHz-only — confirmed against Raspberry Pi's own
#       specs, not a guess. Pi 3B+/4/5 (BCM43455 / CYW43455, all brcmfmac) are
#       dual-band, but onboard AP mode does 5GHz ONLY on non-DFS channels
#       36/40/44/48 — that's a brcmfmac driver limit, same on every model.
#       Band is auto-picked from --channel (1-14 = 2.4GHz, >=32 = 5GHz).
#       On a plain 3B, any --channel >=32 will fail: no 5GHz radio.
#       Wi-Fi stays rfkill-blocked until a country is set. The script sets
#       COUNTRY (default US, override with --country) and unblocks rfkill
#       itself on every run — burn the image, run this script, done; no
#       separate raspi-config step required.
#
# IF YOU LOGGED IN OVER wlan0 (e.g. Wi-Fi creds set in Raspberry Pi Imager,
# no Ethernet yet): rogue/honeypot/suspected/reset all repurpose wlan0 itself,
# which drops that very SSH session partway through a plain run. To make that
# safe, the script re-launches its real work as a detached systemd unit
# (nile-wips-apply) that keeps running under PID 1 even if your session dies —
# so a run started over wlan0 always finishes cleanly. After it applies,
# manage the Pi over Ethernet (br0 gets a DHCP lease) — wlan0 is the AP now.
#
# INSTALL DEPENDENCIES FIRST (while the Pi still has network — the script later
# converts wlan0 to an AP and bridges eth0, which can drop that link):
#     sudo apt-get update && sudo apt-get install -y hostapd iw rfkill iproute2
# The script also does this automatically up front, and HARD-STOPS without
# touching the network if the install fails.
#
#   sudo ./nile-wips.sh rogue        # corp SSID, BRIDGED to LAN  -> ROGUE
#   sudo ./nile-wips.sh honeypot     # corp SSID, off-wire        -> HONEYPOT
#   sudo ./nile-wips.sh suspected    # unknown SSID, off-wire     -> SUSPECTED
#   sudo ./nile-wips.sh stop         # stop ONLY the AP beacon (bridge/MACs stay)
#   sudo ./nile-wips.sh reset        # full revert to stock networking
#   sudo ./nile-wips.sh status       # show what's running
#
# Re-run with a different mode to SWITCH. First run also installs deps.
# Optional overrides (flags OR env):
#   --ssid NAME  --channel N  --country US  --security open|wpa2  --pass PSK
#   --br0-mac AA:..  --wlan-mac AA:..   (wired MAC / AP BSSID)
# ============================================================
set -euo pipefail
SCRIPT_PATH="$(readlink -f "$0")"
ORIG_ARGS=("$@")
usage(){ awk '/^# =+$/{n++; next} n==1' "$0"; exit "${1:-0}"; }
# -h/--help works without sudo (someone exploring the script for the first
# time shouldn't have to already know it needs root just to read the usage).
case "${1:-}" in -h|--help) usage 0 ;; esac
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

# If this run is over wlan0 (Wi-Fi creds from Imager, no Ethernet yet), the
# work below can drop that SSH session mid-script, killing it via SIGHUP
# before the config finishes applying. So: re-launch as a detached systemd
# unit, which keeps running under PID 1 independent of this session, then
# wait for it here (best-effort — if THIS process gets SIGHUP, the detached
# unit keeps going regardless). NILE_WIPS_DETACHED marks the re-invocation so
# it doesn't try to detach again.
detach_and_wait(){
  # Unique per invocation: `--collect` garbage-collects the unit only after
  # it finishes, not instantly, so a fixed name can still be "already loaded"
  # if you re-run the script again quickly (e.g. switching modes/SSIDs
  # back-to-back) while the previous unit is mid-teardown.
  local unit="nile-wips-apply-$$"
  echo ">> Applying via a detached systemd unit ($unit) so this can't be"
  echo ">> half-applied if the connection you're running this over gets dropped by"
  echo ">> the change itself (e.g. SSH over $WLAN_IF, which is about to become the AP)."
  local rc=0
  systemd-run --unit="$unit" --collect --quiet --wait --pipe \
    --setenv=NILE_WIPS_DETACHED=1 \
    -- "$SCRIPT_PATH" "${ORIG_ARGS[@]}" || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo ">> Done. If you were connected over $WLAN_IF, that link is gone now —"
    echo ">> reconnect over Ethernet (br0 gets a DHCP lease) to keep managing this Pi."
  else
    echo ">> $unit failed (exit $rc). If your session just dropped, reconnect"
    echo ">> over Ethernet and check:  sudo journalctl -u $unit -n 60" >&2
  fi
  exit "$rc"
}

# ---------- defaults (override via flags/env) ----------
MODE=""
SSID="${SSID:-}"
CHANNEL="${CHANNEL:-6}"
COUNTRY="${COUNTRY:-US}"
SECURITY="${SECURITY:-open}"       # open | wpa2
PASSPHRASE="${PASSPHRASE:-ChangeMe123}"
BR0_MAC="${BR0_MAC:-02:1a:2b:3c:4d:00}"   # what the switch learns on the WIRE
WLAN_MAC="${WLAN_MAC:-02:1a:2b:3c:4d:01}" # AP BSSID (default = wired + 1)
ETH_IF="${ETH_IF:-eth0}"
WLAN_IF="${WLAN_IF:-wlan0}"

# ---------- parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    rogue|honeypot|suspected|stop|status|reset) MODE="$1"; shift ;;
    --ssid)     SSID="$2"; shift 2 ;;
    --channel)  CHANNEL="$2"; shift 2 ;;
    --country)  COUNTRY="$2"; shift 2 ;;
    --security) SECURITY="$2"; shift 2 ;;
    --pass)     PASSPHRASE="$2"; shift 2 ;;
    --br0-mac)  BR0_MAC="$2"; shift 2 ;;
    --wlan-mac) WLAN_MAC="$2"; shift 2 ;;
    -h|--help)  usage 0 ;;
    *) echo "Unknown arg: $1"; usage 1 ;;
  esac
done
[[ -n $MODE ]] || { echo "ERROR: specify a mode."; usage 1; }

# ---------- status / stop shortcuts ----------
if [[ $MODE == status ]]; then
  systemctl --no-pager --lines=0 status hostapd@nile 2>/dev/null || echo "hostapd@nile not running"
  echo "wlan MAC: $(cat /sys/class/net/$WLAN_IF/address 2>/dev/null || echo ?)   br0 MAC: $(cat /sys/class/net/br0/address 2>/dev/null || echo ?)"
  iw dev 2>/dev/null | grep -E 'Interface|ssid|channel' || true
  exit 0
fi
if [[ $MODE == stop ]]; then
  # Stops ONLY the AP beacon. The bridge, the pinned MACs, the NetworkManager
  # 'unmanaged' rule and the networkd config all REMAIN in place, and come back
  # on reboot. Ethernet keeps working (via br0). To fully revert to stock
  # networking, use 'reset' instead.
  systemctl stop hostapd@nile 2>/dev/null || true
  echo "AP beacon stopped. (bridge/MAC pin/networkd config still in place — use 'reset' to fully revert)"
  exit 0
fi
if [[ $MODE == reset ]]; then
  [[ -n "${NILE_WIPS_DETACHED:-}" ]] || detach_and_wait
  echo ">> Reverting to stock networking…"
  systemctl stop hostapd@nile 2>/dev/null || true
  systemctl disable hostapd@nile 2>/dev/null || true
  # remove everything this script installed
  rm -f /etc/hostapd/nile.conf
  rm -f /etc/systemd/network/00-wlan.link \
        /etc/systemd/network/10-br0.netdev \
        /etc/systemd/network/20-eth0.network \
        /etc/systemd/network/30-br0.network
  rm -f /etc/NetworkManager/conf.d/99-nile-wips.conf
  rm -f /etc/systemd/system/hostapd@.service
  systemctl daemon-reload
  # tear down the live bridge and restore the radio's burned-in MAC
  ip link set "$WLAN_IF" down 2>/dev/null || true
  if command -v ethtool >/dev/null 2>&1; then
    PERM=$(ethtool -P "$WLAN_IF" 2>/dev/null | awk '{print $3}')
    [[ $PERM =~ ^([0-9a-fA-F]{2}:){5} ]] && ip link set dev "$WLAN_IF" address "$PERM" 2>/dev/null || true
  fi
  ip link set br0 down 2>/dev/null || true
  ip link del br0 2>/dev/null || true
  systemctl restart systemd-networkd 2>/dev/null || true
  # hand the interfaces back to NetworkManager if it's the active stack.
  # `reload` (not `restart`) re-reads conf.d in place without tearing down
  # every other managed connection on the box — a full restart drops and
  # reconnects ALL of them, including ones with nothing to do with this
  # script (verified: it knocked an unrelated Wi-Fi client offline).
  systemctl reload NetworkManager 2>/dev/null || true
  echo "Reset done. A reboot guarantees a fully clean state (restores the"
  echo "burned-in wlan MAC even without ethtool):  sudo reboot"
  exit 0
fi

# ---------- per-mode behavior ----------
case "$MODE" in
  rogue)     BRIDGE=yes; DEF_SSID=Nile-Corp ;;
  honeypot)  BRIDGE=no;  DEF_SSID=Nile-Corp ;;
  suspected) BRIDGE=no;  DEF_SSID=FreeWiFi-Guest ;;
esac
[[ -n $SSID ]] || SSID="$DEF_SSID"

echo ">> mode=$MODE ssid='$SSID' ch=$CHANNEL bridge=$BRIDGE sec=$SECURITY"
echo ">> wired(br0)=$BR0_MAC  bssid(wlan)=$WLAN_MAC"

# ---------- PREFLIGHT: packages FIRST, before any network/driver change ----------
# The script later turns wlan0 into an AP and bridges eth0, which can drop the
# very link apt needs. So we make sure every dependency is present up front, and
# HARD-STOP (touching nothing) if it can't be installed.
#
#   Required packages:  hostapd  iw  rfkill  iproute2
#   Install them yourself beforehand (while the Pi still has network) with:
#     sudo apt-get update && sudo apt-get install -y hostapd iw rfkill iproute2
#
# binary -> package it comes from
declare -A NEED=( [hostapd]=hostapd [iw]=iw [rfkill]=rfkill [ip]=iproute2 )
MISSING_PKGS=()
for bin in "${!NEED[@]}"; do
  command -v "$bin" >/dev/null 2>&1 || MISSING_PKGS+=("${NEED[$bin]}")
done
# de-dupe
if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
  mapfile -t MISSING_PKGS < <(printf '%s\n' "${MISSING_PKGS[@]}" | sort -u)
  INSTALL_CMD="sudo apt-get update && sudo apt-get install -y ${MISSING_PKGS[*]}"
  echo ">> Missing packages: ${MISSING_PKGS[*]}"
  echo ">> Installing now (network still up)…"
  if ! { apt-get update -qq && \
         DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING_PKGS[@]}"; }; then
    echo "" >&2
    echo "ERROR: package install FAILED — no network changes were made." >&2
    echo "Fix networking, then install the packages manually and re-run this script:" >&2
    echo "    $INSTALL_CMD" >&2
    exit 1
  fi
  # verify they really landed before we go on to touch the network
  for bin in "${!NEED[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "ERROR: '$bin' still missing after install — aborting before any network change." >&2
      echo "Run manually while the Pi has network:  $INSTALL_CMD" >&2
      exit 1
    fi
  done
  echo ">> All packages present."
else
  echo ">> All required packages already installed."
fi

# ---------- Wi-Fi regulatory: unattended, every run ----------
# A stock image has no country set, which leaves Wi-Fi rfkill soft-blocked —
# hostapd fails to bring wlan0 up with no obvious error otherwise. Do this
# here, unconditionally, so "burn image, run script" is the whole procedure —
# no separate raspi-config step to remember on a fresh unit.
if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_wifi_country "$COUNTRY" >/dev/null 2>&1 || true
fi
rfkill unblock wifi 2>/dev/null || true
rfkill unblock wlan 2>/dev/null || true

# Preflight (network-dependent) is done. Everything from here on can drop a
# wlan0-based session, so hand off to the detached unit now.
[[ -n "${NILE_WIPS_DETACHED:-}" ]] || detach_and_wait

# ---------- from here on it is safe to reconfigure the interfaces ----------
systemctl unmask hostapd 2>/dev/null || true
systemctl disable hostapd 2>/dev/null || true   # we use hostapd@nile

# NetworkManager: leave our interfaces alone
install -Dm644 /dev/stdin /etc/NetworkManager/conf.d/99-nile-wips.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:$ETH_IF;interface-name:br0;interface-name:$WLAN_IF
EOF
# Writing the conf.d file alone does nothing until NM re-reads it: without a
# reload, NM keeps "managing" eth0/wlan0/br0, races systemd-networkd for them
# (its own DHCP client fights the bridge on eth0, and it can reconnect wlan0 as
# a station), and can reset eth0 back to its burned-in MAC on the wire.
# `reload` (not `restart`) applies this in place without a full daemon
# restart, which would drop and reconnect EVERY managed connection on the
# box — including ones unrelated to this script, like another Wi-Fi adapter
# or a VPN link (verified: a full restart knocked an unrelated Wi-Fi client
# offline and it needed a manual `nmcli connection up` to recover).
systemctl reload NetworkManager 2>/dev/null || true
systemctl enable systemd-networkd >/dev/null 2>&1 || true

# per-instance hostapd unit
install -Dm644 /dev/stdin /etc/systemd/system/hostapd@.service <<'EOF'
[Unit]
Description=hostapd (Nile WIPS demo: %i)
After=network-online.target sys-subsystem-net-devices-br0.device
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/sbin/hostapd /etc/hostapd/%i.conf
Restart=always
RestartSec=5
StartLimitIntervalSec=0
[Install]
WantedBy=multi-user.target
EOF

# ---------- render network config ----------
# bridge always exists; eth0 is a member; br0 gets a LAN DHCP lease (req #1)
install -Dm644 /dev/stdin /etc/systemd/network/10-br0.netdev <<EOF
[NetDev]
Name=br0
Kind=bridge
MACAddress=$BR0_MAC
[Bridge]
STP=false
ForwardDelaySec=0
EOF
install -Dm644 /dev/stdin /etc/systemd/network/20-eth0.network <<EOF
[Match]
Name=$ETH_IF
[Link]
# A bridge INHERITS its member port's MAC, so pinning br0 alone is not enough:
# the switch would learn eth0's burned-in MAC. Pin eth0's MAC to the wired
# value so the wire deterministically shows BR0_MAC (req #2).
MACAddress=$BR0_MAC
[Network]
Bridge=br0
LinkLocalAddressing=no
EOF
install -Dm644 /dev/stdin /etc/systemd/network/30-br0.network <<EOF
[Match]
Name=br0
[Network]
DHCP=yes
[DHCPv4]
Hostname=nile-wips-$MODE
EOF
# pin the AP BSSID MAC persistently (req #2)
install -Dm644 /dev/stdin /etc/systemd/network/00-wlan.link <<EOF
[Match]
Driver=brcmfmac
[Link]
Name=$WLAN_IF
MACAddress=$WLAN_MAC
EOF

# ---------- render hostapd config ----------
{
  echo "interface=$WLAN_IF"
  [[ $BRIDGE == yes ]] && echo "bridge=br0"   # req #3: client gets a LAN IP (rogue only)
  echo "driver=nl80211"
  echo "ctrl_interface=/var/run/hostapd"
  echo "ctrl_interface_group=0"
  echo "bssid=$WLAN_MAC"
  echo "ssid=$SSID"
  echo "country_code=$COUNTRY"
  # auto band: 2.4GHz (hw_mode=g) for ch 1-14, 5GHz (hw_mode=a) for ch >=32.
  # NOTE: onboard brcmfmac AP mode only does NON-DFS 5GHz -> ch 36/40/44/48.
  if [[ $CHANNEL -ge 32 ]]; then echo "hw_mode=a"; else echo "hw_mode=g"; fi
  echo "channel=$CHANNEL"
  echo "ieee80211n=1"
  echo "wmm_enabled=1"
  echo "macaddr_acl=0"
  echo "ignore_broadcast_ssid=0"
  echo "auth_algs=1"
  if [[ $SECURITY == wpa2 ]]; then
    echo "wpa=2"; echo "wpa_key_mgmt=WPA-PSK"; echo "rsn_pairwise=CCMP"
    echo "wpa_passphrase=$PASSPHRASE"
  fi
} >/etc/hostapd/nile.conf
chmod 600 /etc/hostapd/nile.conf

# ---------- apply live (no reboot) ----------
systemctl daemon-reload
systemctl enable hostapd@nile >/dev/null 2>&1 || true
systemctl stop hostapd@nile 2>/dev/null || true
systemctl restart systemd-networkd
# set MACs live so no reboot is needed:
# eth0 first (bridge inherits it), then br0 explicitly, then the radio BSSID.
ip link set "$ETH_IF" down 2>/dev/null || true
ip link set dev "$ETH_IF" address "$BR0_MAC" 2>/dev/null || true
ip link set "$ETH_IF" up 2>/dev/null || true
# br0 is (re)created asynchronously by the networkd restart above; wait for
# it to actually exist instead of racing it — otherwise this silently no-ops
# (masked by `|| true`) and br0 is left with whatever MAC it happened to get.
for _ in $(seq 1 40); do ip link show br0 &>/dev/null && break; sleep 0.25; done
ip link set dev br0 address "$BR0_MAC" 2>/dev/null || true
ip link set "$WLAN_IF" down 2>/dev/null || true
ip link set dev "$WLAN_IF" address "$WLAN_MAC" 2>/dev/null || true
systemctl restart hostapd@nile

sleep 2
echo "----------------------------------------------------------"
systemctl is-active hostapd@nile >/dev/null 2>&1 \
  && echo "OK: '$MODE' is live (SSID '$SSID')." \
  || { echo "hostapd failed; last log:"; journalctl -u hostapd@nile -n 15 --no-pager; exit 1; }
echo "wlan MAC: $(cat /sys/class/net/$WLAN_IF/address 2>/dev/null)   br0 MAC: $(cat /sys/class/net/br0/address 2>/dev/null)"
[[ $BRIDGE == yes ]] && echo "Bridged: a client joining '$SSID' will get a LAN IP." \
                     || echo "Not bridged: beacon only (off the wire)."
