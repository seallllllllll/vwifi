#!/usr/bin/env bash
set +e

mkdir -p logs

echo "==== save dmesg before cleanup ===="
sudo dmesg -T | tail -n 300 | tee logs/before_cleanup_dmesg.txt

echo "==== kill processes inside vwifi namespaces ===="
for ns in ns0 ns1 ns2 ns3 ns4 ns5; do
    if sudo ip netns list | grep -q "^${ns}"; then
        sudo ip netns pids "$ns" 2>/dev/null | xargs -r sudo kill -TERM
    fi
done

sleep 1

for ns in ns0 ns1 ns2 ns3 ns4 ns5; do
    if sudo ip netns list | grep -q "^${ns}"; then
        sudo ip netns pids "$ns" 2>/dev/null | xargs -r sudo kill -KILL
    fi
done

echo "==== unload vwifi before deleting namespaces ===="
sudo rmmod vwifi
ret=$?
echo "rmmod exit code: $ret"

echo "==== save dmesg after rmmod ===="
sudo dmesg -T | tail -n 300 | tee logs/after_rmmod_dmesg.txt

echo "==== delete namespaces ===="
for ns in ns0 ns1 ns2 ns3 ns4 ns5; do
    sudo ip netns del "$ns" 2>/dev/null || true
done

echo "==== status ===="
sudo ip netns list
lsmod | grep vwifi || echo "vwifi unloaded"
pgrep -a hostapd || echo "no hostapd"
pgrep -a wpa_supplicant || echo "no wpa_supplicant"
