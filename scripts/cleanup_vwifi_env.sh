#!/usr/bin/env bash
set +e

echo "==== kill userspace Wi-Fi processes ===="
sudo killall hostapd 2>/dev/null || true
sudo killall wpa_supplicant 2>/dev/null || true
sudo killall dhclient 2>/dev/null || true

echo "==== delete namespaces ===="
for ns in ns0 ns1 ns2 ns3 ns4 ns5; do
    sudo ip netns pids "$ns" 2>/dev/null | xargs -r sudo kill -9
    sudo ip netns del "$ns" 2>/dev/null || true
done

echo "==== unload vwifi ===="
sudo rmmod vwifi 2>/dev/null || true

echo "==== status ===="
sudo ip netns list
lsmod | grep vwifi || echo "vwifi unloaded"
pgrep -a hostapd || echo "no hostapd"
pgrep -a wpa_supplicant || echo "no wpa_supplicant"
