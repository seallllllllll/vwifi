#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p logs/regression

echo "==== setup AP/STA environment ===="
bash scripts/setup_ap_sta_env.sh 2>&1 | tee logs/regression/setup_ap_sta_env.txt

echo "==== run bitrate mask regression ===="
bash tests/test_bitrate_mask.sh 2>&1 | tee logs/regression/test_bitrate_mask.txt

echo "==== collect dmesg ===="
sudo dmesg | grep -E 'vwifi: .*set HT MCS|BUG|Oops|panic|UBSAN' \
    | tail -n 200 \
    | tee logs/regression/dmesg.txt

echo
echo "Regression finished."
echo "Do not run scripts/cleanup_vwifi_env.sh."
echo "Use sudo reboot to reset the environment."
