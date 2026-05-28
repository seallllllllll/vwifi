#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p logs

RESULT_JSON="logs/packet_loss_result.json"
DMESG_LOG="logs/packet_loss_dmesg.txt"
STATS_LOG="logs/packet_loss_stats.txt"
KMSG_TAG="VWIFI_TEST_PACKET_LOSS"

write_json() {
    local status="$1"
    local message="$2"

    cat > "$RESULT_JSON" <<JSON
{
  "status": "$status",
  "message": "$message",
  "loss_0": "logs/packet_loss_0.txt",
  "loss_20": "logs/packet_loss_20.txt",
  "loss_100": "logs/packet_loss_100.txt",
  "stats": "logs/packet_loss_stats.txt",
  "dmesg": "logs/packet_loss_dmesg.txt"
}
JSON
}

fail() {
    echo "FAIL: $*" >&2
    write_json "FAIL" "$*"
    exit 1
}

log_step() {
    echo
    echo "==== $* ===="
    echo "$KMSG_TAG: $*" | sudo tee /dev/kmsg >/dev/null || true
    sync
}

set_loss() {
    local percent="$1"

    echo "$percent" | sudo tee /sys/module/vwifi/parameters/loss_percent >/dev/null
    cat /sys/module/vwifi/parameters/loss_percent
}

check_iface() {
    local ns="$1"
    local iface="$2"

    sudo ip netns exec "$ns" iw dev "$iface" info >/dev/null 2>&1 \
        || fail "missing interface $iface in namespace $ns"
}

collect_logs() {
    {
        echo "==== station dump ===="
        sudo ip netns exec ns0 iw dev vw0 station dump || true
        echo
        echo "==== vw1 stats ===="
        sudo ip netns exec ns1 ip -s link show vw1 || true
        echo
        echo "==== vw2 stats ===="
        sudo ip netns exec ns2 ip -s link show vw2 || true
    } | tee "$STATS_LOG"

    {
        sudo dmesg | grep -E 'vwifi: drop packet|VWIFI_TEST_PACKET_LOSS|BUG|Oops|panic|UBSAN' || true
    } | tail -n 120 | tee "$DMESG_LOG"
}

log_step "check AP/STA environment"
check_iface ns0 vw0
check_iface ns1 vw1
check_iface ns2 vw2

log_step "loss_percent=0 should pass"
set_loss 0

if ! sudo ip netns exec ns1 ping -c 5 -W 1 10.0.0.3 | tee logs/packet_loss_0.txt; then
    fail "ping failed when loss_percent=0"
fi

if grep -q "100% packet loss" logs/packet_loss_0.txt; then
    fail "loss_percent=0 produced 100% packet loss"
fi

log_step "loss_percent=100 should fail completely"
set_loss 100

sudo ip netns exec ns1 ping -c 5 -W 1 10.0.0.3 \
    | tee logs/packet_loss_100.txt || true

if ! grep -q "100% packet loss" logs/packet_loss_100.txt; then
    fail "loss_percent=100 did not produce 100% packet loss"
fi

log_step "warm up ARP before probabilistic loss"
set_loss 0
sudo ip netns exec ns1 ping -c 3 -W 1 10.0.0.3 || true
sudo ip netns exec ns2 ping -c 3 -W 1 10.0.0.2 || true

log_step "loss_percent=20 should run with probabilistic loss"
set_loss 20

sudo ip netns exec ns1 ping -c 30 -W 1 10.0.0.3 \
    | tee logs/packet_loss_20.txt || true

if grep -q "100% packet loss" logs/packet_loss_20.txt; then
    fail "loss_percent=20 produced 100% packet loss; probabilistic path may be wrong"
fi

if grep -q "0% packet loss" logs/packet_loss_20.txt; then
    echo "WARN: loss_percent=20 produced 0% loss in this short run; possible but check dmesg/stats"
fi

log_step "reset loss_percent to 0"
set_loss 0

log_step "collect stats and dmesg"
collect_logs

if ! grep -q "vwifi: drop packet" "$DMESG_LOG"; then
    fail "dmesg does not contain packet loss drop evidence"
fi

write_json "PASS" "packet loss parameter affects AP/STA data path"

echo
echo "PASS: packet loss test finished"
echo "Result JSON: $RESULT_JSON"
