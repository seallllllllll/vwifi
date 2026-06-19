#!/usr/bin/env bash
set +e

mkdir -p logs

echo "==== save dmesg before cleanup ===="
sudo dmesg -T | tail -n 300 | tee logs/before_cleanup_dmesg.txt

echo "==== ask AP/STA wireless state to quiesce ===="

# Only disconnect STA interfaces.
# Do NOT manually run "ibss leave" for vw3/vw4/vw5 here.
sudo ip netns exec ns1 iw dev vw1 disconnect 2>/dev/null || true
sudo ip netns exec ns2 iw dev vw2 disconnect 2>/dev/null || true

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

echo "==== bring only AP/STA links down ===="

# Only bring down vw0/vw1/vw2.
# Do NOT manually bring down IBSS interfaces vw3/vw4/vw5 yet.
sudo ip netns exec ns0 ip link set vw0 down 2>/dev/null || true
sudo ip netns exec ns1 ip link set vw1 down 2>/dev/null || true
sudo ip netns exec ns2 ip link set vw2 down 2>/dev/null || true

sleep 1

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

exit "$ret"
