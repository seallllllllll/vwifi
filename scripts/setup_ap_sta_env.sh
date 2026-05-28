#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOG_DIR="logs/ap_sta_setup"
mkdir -p "$LOG_DIR"

VWIFI_KO="${VWIFI_KO:-./vwifi.ko}"
STATION_COUNT="${STATION_COUNT:-3}"
HOSTAPD_CONF="${HOSTAPD_CONF:-scripts/hostapd.conf}"

log() {
    echo
    echo "==== $* ===="
}

fail() {
    echo "FAIL: $*" >&2
    echo "Environment may be partially initialized. Reboot before retrying." >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

get_wiphy_name() {
    local iface="$1"
    local idx=""

    idx="$(sudo iw dev "$iface" info | awk '/wiphy/ {print $2; exit}')"
    [ -n "$idx" ] || fail "cannot get wiphy index for $iface"

    sudo iw list | awk -v idx="$idx" '
        /^Wiphy / {
            name = $2
        }
        /wiphy index:/ {
            if ($3 == idx) {
                print name
                exit
            }
        }
    '
}

wait_for_link() {
    local ns="$1"
    local iface="$2"
    local tries="${3:-10}"

    for _ in $(seq 1 "$tries"); do
        if sudo ip netns exec "$ns" iw dev "$iface" link | grep -q '^Connected to '; then
            return 0
        fi
        sleep 1
    done

    sudo ip netns exec "$ns" iw dev "$iface" link || true
    return 1
}

connect_sta() {
    local ns="$1"
    local iface="$2"
    local ssid="${3:-test}"

    log "scan from $ns/$iface"
    for _ in $(seq 1 5); do
        if sudo ip netns exec "$ns" iw dev "$iface" scan \
            | tee "$LOG_DIR/${iface}_scan.txt" \
            | grep -q "SSID: $ssid"; then
            break
        fi
        sleep 1
    done

    grep -q "SSID: $ssid" "$LOG_DIR/${iface}_scan.txt" \
        || fail "$iface cannot see SSID '$ssid'"

    log "connect $ns/$iface to SSID '$ssid'"
    sudo ip netns exec "$ns" iw dev "$iface" connect "$ssid" \
        | tee "$LOG_DIR/${iface}_connect.txt"

    wait_for_link "$ns" "$iface" 10 \
        || fail "$iface failed to connect to SSID '$ssid'"

    sudo ip netns exec "$ns" iw dev "$iface" link \
        | tee "$LOG_DIR/${iface}_link.txt"
}

log "preflight checks"
need_cmd sudo
need_cmd make
need_cmd ip
need_cmd iw
need_cmd hostapd
need_cmd lsmod

sudo -v

if lsmod | grep -q '^vwifi '; then
    fail "vwifi is already loaded. Reboot first; this setup script will not rmmod."
fi

if ip netns list | grep -qE '^ns[0-2]\b'; then
    fail "ns0/ns1/ns2 already exist. Reboot first; this setup script will not delete namespaces."
fi

if pgrep -a hostapd >/dev/null 2>&1; then
    fail "hostapd is already running. Stop it manually or reboot first."
fi

[ -f "$HOSTAPD_CONF" ] || fail "missing $HOSTAPD_CONF"

log "build vwifi"
make 2>&1 | tee "$LOG_DIR/build.txt"

[ -f "$VWIFI_KO" ] || fail "missing kernel module: $VWIFI_KO"

log "load cfg80211 and vwifi"
sudo modprobe cfg80211
sudo insmod "$VWIFI_KO" "station=$STATION_COUNT"

sleep 1

sudo iw dev | tee "$LOG_DIR/iw_dev_after_insmod.txt"

for iface in vw0 vw1 vw2; do
    sudo iw dev "$iface" info >/dev/null 2>&1 \
        || fail "missing interface $iface after insmod"
done

log "set txpower, best effort"
sudo iw dev vw0 set txpower auto 2>&1 | tee "$LOG_DIR/vw0_txpower.txt" || true
sudo iw dev vw1 set txpower fixed 1200 2>&1 | tee "$LOG_DIR/vw1_txpower.txt" || true
sudo iw dev vw2 set txpower fixed 1300 2>&1 | tee "$LOG_DIR/vw2_txpower.txt" || true

log "resolve wiphy names before moving namespaces"
vw0_phy="$(get_wiphy_name vw0)"
vw1_phy="$(get_wiphy_name vw1)"
vw2_phy="$(get_wiphy_name vw2)"

{
    echo "vw0_phy=$vw0_phy"
    echo "vw1_phy=$vw1_phy"
    echo "vw2_phy=$vw2_phy"
} | tee "$LOG_DIR/wiphy_names.txt"

[ -n "$vw0_phy" ] || fail "empty wiphy for vw0"
[ -n "$vw1_phy" ] || fail "empty wiphy for vw1"
[ -n "$vw2_phy" ] || fail "empty wiphy for vw2"

log "create namespaces"
sudo ip netns add ns0
sudo ip netns add ns1
sudo ip netns add ns2

log "move phys into namespaces"
sudo iw phy "$vw0_phy" set netns name ns0
sudo iw phy "$vw1_phy" set netns name ns1
sudo iw phy "$vw2_phy" set netns name ns2

log "bring loopback and vwifi interfaces up"
for i in 0 1 2; do
    sudo ip netns exec "ns$i" ip link set lo up
    sudo ip netns exec "ns$i" ip link set "vw$i" up
    sudo ip netns exec "ns$i" iw dev "vw$i" info \
        | tee "$LOG_DIR/ns${i}_vw${i}_info.txt"
done

log "assign IP addresses"
sudo ip netns exec ns0 ip addr add 10.0.0.1/24 dev vw0
sudo ip netns exec ns1 ip addr add 10.0.0.2/24 dev vw1
sudo ip netns exec ns2 ip addr add 10.0.0.3/24 dev vw2

for i in 0 1 2; do
    sudo ip netns exec "ns$i" ip addr show "vw$i" \
        | tee "$LOG_DIR/ns${i}_vw${i}_addr.txt"
done

log "start AP on ns0/vw0"
sudo ip netns exec ns0 hostapd -B "$HOSTAPD_CONF" \
    | tee "$LOG_DIR/hostapd_start.txt"

sleep 2

pgrep -a hostapd | tee "$LOG_DIR/hostapd_pid.txt" >/dev/null \
    || fail "hostapd did not start"

log "connect STA vw1 and vw2"
connect_sta ns1 vw1 test
connect_sta ns2 vw2 test

log "sanity ping: vw1 to vw2 through AP"
sudo ip netns exec ns1 ping -c 4 -W 2 10.0.0.3 \
    | tee "$LOG_DIR/ping_vw1_to_vw2.txt"

log "sanity ping: vw2 to AP"
sudo ip netns exec ns2 ping -c 4 -W 2 10.0.0.1 \
    | tee "$LOG_DIR/ping_vw2_to_ap.txt"

log "station dump from AP"
sudo ip netns exec ns0 iw dev vw0 station dump \
    | tee "$LOG_DIR/station_dump_after_setup.txt"

log "collect vwifi dmesg tail"
sudo dmesg | grep -E 'vwifi|hostapd|BUG|Oops|panic|UBSAN' \
    | tail -n 200 \
    | tee "$LOG_DIR/dmesg_tail.txt" || true

cat > "$LOG_DIR/result.json" <<JSON
{
  "status": "PASS",
  "mode": "AP_STA_ONLY",
  "ap": {
    "namespace": "ns0",
    "interface": "vw0",
    "ip": "10.0.0.1/24"
  },
  "sta": [
    {
      "namespace": "ns1",
      "interface": "vw1",
      "ip": "10.0.0.2/24"
    },
    {
      "namespace": "ns2",
      "interface": "vw2",
      "ip": "10.0.0.3/24"
    }
  ],
  "logs": "$LOG_DIR"
}
JSON

echo
echo "PASS: AP/STA-only environment is ready."
echo
echo "Next:"
echo "  bash tests/test_bitrate_mask.sh"
echo
echo "Logs:"
echo "  $LOG_DIR"
