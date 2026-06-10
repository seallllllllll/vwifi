make clean && make
sudo bash scripts/setup_ap_sta_env.sh

echo 0 | sudo tee /sys/module/vwifi/parameters/loss_percent
echo 10 | sudo tee /sys/module/vwifi/parameters/tx_delay_scale

sudo ip netns exec ns1 iw dev vw1 set bitrates ht-mcs-2.4 31 lgi-2.4
sudo ip netns exec ns2 iw dev vw2 set bitrates ht-mcs-2.4 31 lgi-2.4
sudo ip netns exec ns1 ping -s 1400 -c 10 -W 2 10.0.0.3 | tee logs/tx_delay_mcs31.txt

sudo ip netns exec ns1 iw dev vw1 set bitrates ht-mcs-2.4 0 lgi-2.4
sudo ip netns exec ns2 iw dev vw2 set bitrates ht-mcs-2.4 0 lgi-2.4
sudo ip netns exec ns1 ping -s 1400 -c 10 -W 2 10.0.0.3 | tee logs/tx_delay_mcs0.txt

sudo dmesg | grep 'vwifi: tx delay' | tail -n 80 | tee logs/tx_delay_dmesg.txt

echo 1 | sudo tee /sys/module/vwifi/parameters/tx_delay_scale
sudo bash scripts/cleanup_ap_sta_env.sh
