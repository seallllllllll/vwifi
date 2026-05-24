#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mkdir -p logs/regression

echo "==== setup AP/STA environment ===="
bash scripts/setup_ap_sta_env.sh 2>&1 | tee logs/regression/setup_ap_sta_env.txt

echo "==== run bitrate mask regression ===="
bash tests/test_bitrate_mask.sh 2>&1 | tee logs/regression/test_bitrate_mask.txt

echo "==== collect dmesg ===="
sudo dmesg | grep -E 'vwifi: .*set HT MCS|BUG|Oops|panic|UBSAN' \
    | tail -n 200 \
    | tee logs/regression/dmesg.txt

echo "==== cleanup AP/STA environment ===="
bash scripts/cleanup_ap_sta_env.sh 2>&1 | tee logs/regression/cleanup_ap_sta_env.txt

echo "==== cleanup AP/STA environment, allow rmmod ===="
TOUCHED_IBSS=0 ALLOW_RMMOD=1 REBOOT_AFTER=0 \
    bash scripts/cleanup_ap_sta_env.sh 2>&1 \
    | tee logs/regression/cleanup_ap_sta_env.txt

echo
echo "==== verify cleanup result ===="
lsmod | grep vwifi || echo "vwifi unloaded"
ip netns list
pgrep -a hostapd || echo "hostapd stopped"

echo
echo "Regression finished."
echo "AP/STA-only path should not reboot."
echo "If vwifi is still loaded, inspect logs/regression/cleanup_ap_sta_env.txt."
