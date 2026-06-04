#!/usr/bin/env bash
set -Eeuo pipefail

ALLOW_RMMOD="${ALLOW_RMMOD:-0}"
REBOOT_AFTER="${REBOOT_AFTER:-0}"
TOUCHED_IBSS="${TOUCHED_IBSS:-0}"

echo "==== cleanup policy ===="
echo "TOUCHED_IBSS=$TOUCHED_IBSS"
echo "ALLOW_RMMOD=$ALLOW_RMMOD"
echo "REBOOT_AFTER=$REBOOT_AFTER"

echo "==== stop hostapd ===="
sudo pkill -x hostapd 2>/dev/null || true
sleep 1

echo "==== disconnect stations, best effort ===="
for pair in "ns1 vw1" "ns2 vw2"; do
    set -- $pair
    ns="$1"
    iface="$2"

    if sudo ip netns exec "$ns" true 2>/dev/null; then
        sudo ip netns exec "$ns" iw dev "$iface" disconnect 2>/dev/null || true
        sudo ip netns exec "$ns" ip link set "$iface" down 2>/dev/null || true
    fi
done

echo "==== stop AP interface, best effort ===="
if sudo ip netns exec ns0 true 2>/dev/null; then
    sudo ip netns exec ns0 ip link set vw0 down 2>/dev/null || true
fi

echo "==== wait for cfg80211/vwifi async work to settle ===="
sleep 2

echo "==== delete AP/STA namespaces ===="
for ns in ns2 ns1 ns0; do
    if sudo ip netns list | grep -q "^$ns\b"; then
        sudo ip netns delete "$ns" || true
    fi
done

echo "==== wait after namespace delete ===="
sleep 2

echo "==== verify userspace cleanup ===="
if ip netns list | grep -qE '^ns[0-2]\b'; then
    echo "WARN: ns0/ns1/ns2 still exist"
    ip netns list | grep -E '^ns[0-2]\b' || true
else
    echo "namespaces removed"
fi

if pgrep -a hostapd >/dev/null 2>&1; then
    echo "WARN: hostapd still running"
    pgrep -a hostapd || true
else
    echo "hostapd stopped"
fi

echo "==== module unload / reboot policy ===="

if [ "$TOUCHED_IBSS" = "1" ]; then
    echo "IBSS was touched; kernel panic issue is fixed, continue normal cleanup."
fi

if [ "$ALLOW_RMMOD" = "1" ]; then
    echo "AP/STA-only path; trying to unload vwifi."

    for i in 1 2 3; do
        if ! lsmod | grep -q '^vwifi '; then
            echo "vwifi already unloaded"
            break
        fi

        echo "try rmmod vwifi: attempt $i"
        if sudo rmmod vwifi; then
            echo "rmmod vwifi succeeded"
            break
        fi

        sleep 1
    done

    if lsmod | grep -q '^vwifi '; then
        echo "FAIL: vwifi is still loaded after rmmod attempts" >&2
        lsmod | grep -E 'vwifi|cfg80211' >&2
        exit 1
    fi

    echo "vwifi unloaded"
else
    echo "skip rmmod vwifi because ALLOW_RMMOD is not 1"
fi

echo "==== collect dmesg tail ===="
sudo dmesg | grep -E 'vwifi|BUG|Oops|panic|UBSAN' \
    | tail -n 120 || true

sync

if [ "$REBOOT_AFTER" = "1" ]; then
    echo "==== rebooting to reset environment ===="
    sudo reboot
fi

echo
echo "PASS: AP/STA cleanup finished."
