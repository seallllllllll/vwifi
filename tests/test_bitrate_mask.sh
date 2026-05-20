#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p logs

RESULT_JSON="logs/bitrate_mask_result.json"
DMESG_LOG="logs/bitrate_mask_dmesg.txt"
KMSG_TAG="VWIFI_TEST_BITRATE_MASK"

write_json() {
    local status="$1"
    local message="$2"

    cat > "$RESULT_JSON" <<JSON
{
  "status": "$status",
  "message": "$message",
  "before": "logs/bitrate_mask_before.txt",
  "after_mcs7_lgi": "logs/bitrate_mask_after_mcs7_lgi.txt",
  "after_mcs7_sgi": "logs/bitrate_mask_after_mcs7_sgi.txt",
  "after_vw2_mcs3_lgi": "logs/bitrate_mask_after_vw2_mcs3_lgi.txt",
  "after_reset": "logs/bitrate_mask_after_reset.txt",
  "dmesg": "logs/bitrate_mask_dmesg.txt"
}
JSON
}

fail() {
    echo "FAIL: $*" >&2
    write_json "FAIL" "$*"
    exit 1
}

warn() {
    echo "WARN: $*" >&2
}

log_step() {
    echo
    echo "==== $* ===="
    echo "$KMSG_TAG: $*" | sudo tee /dev/kmsg >/dev/null || true
    sync
}

check_iface() {
    local ns="$1"
    local iface="$2"

    sudo ip netns exec "$ns" iw dev "$iface" info >/dev/null 2>&1 \
        || fail "missing interface $iface in namespace $ns"
}

station_dump() {
    local outfile="$1"

    sudo ip netns exec ns0 iw dev vw0 station dump | tee "$outfile"
}

set_mcs() {
    local ns="$1"
    local iface="$2"
    local mcs="$3"
    local gi="$4"

    local gi_opt="${gi}-2.4"

    echo "try: iw dev $iface set bitrates ht-mcs-2.4 $mcs $gi_opt"
    if sudo ip netns exec "$ns" iw dev "$iface" set bitrates ht-mcs-2.4 "$mcs" "$gi_opt"; then
        return 0
    fi

    echo "try: iw dev $iface set bitrates mcs-2.4 $mcs $gi_opt"
    if sudo ip netns exec "$ns" iw dev "$iface" set bitrates mcs-2.4 "$mcs" "$gi_opt"; then
        return 0
    fi

    echo "try: iw dev $iface set bitrates ht-mcs-2.4 $mcs"
    if sudo ip netns exec "$ns" iw dev "$iface" set bitrates ht-mcs-2.4 "$mcs"; then
        return 0
    fi

    echo "try: iw dev $iface set bitrates mcs-2.4 $mcs"
    if sudo ip netns exec "$ns" iw dev "$iface" set bitrates mcs-2.4 "$mcs"; then
        return 0
    fi

    return 1
}

reset_bitrate_mask() {
    local ns="$1"
    local iface="$2"

    echo "try: iw dev $iface set bitrates ht-mcs-2.4"
    if sudo ip netns exec "$ns" iw dev "$iface" set bitrates ht-mcs-2.4; then
        return 0
    fi

    echo "try: iw dev $iface set bitrates mcs-2.4"
    if sudo ip netns exec "$ns" iw dev "$iface" set bitrates mcs-2.4; then
        return 0
    fi

    echo "try: iw dev $iface set bitrates"
    if sudo ip netns exec "$ns" iw dev "$iface" set bitrates; then
        return 0
    fi

    return 1
}

collect_dmesg() {
    {
        sudo dmesg | grep -E 'vwifi: .*set HT MCS|vwifi: .*reset bitrate mask|VWIFI_TEST_BITRATE_MASK' || true
    } | tail -n 80 | tee "$DMESG_LOG"
}

log_step "check test environment"
check_iface ns0 vw0
check_iface ns1 vw1
check_iface ns2 vw2

log_step "baseline station dump before set bitrates"
station_dump logs/bitrate_mask_before.txt

grep -q "MCS" logs/bitrate_mask_before.txt \
    || fail "baseline station dump does not contain MCS information"

log_step "set vw1 to HT MCS 7 long GI"
set_mcs ns1 vw1 7 lgi \
    || fail "failed to set vw1 to MCS 7 long GI"

station_dump logs/bitrate_mask_after_mcs7_lgi.txt

grep -q "MCS 7" logs/bitrate_mask_after_mcs7_lgi.txt \
    || fail "station dump does not show MCS 7 after setting vw1"

grep -q "65.0 MBit/s" logs/bitrate_mask_after_mcs7_lgi.txt \
    || fail "station dump does not show 65.0 MBit/s for MCS 7 long GI"

log_step "set vw1 to HT MCS 7 short GI"
set_mcs ns1 vw1 7 sgi \
    || fail "failed to set vw1 to MCS 7 short GI"

station_dump logs/bitrate_mask_after_mcs7_sgi.txt

grep -q "MCS 7" logs/bitrate_mask_after_mcs7_sgi.txt \
    || fail "station dump does not show MCS 7 after setting short GI"

grep -q "short GI" logs/bitrate_mask_after_mcs7_sgi.txt \
    || fail "station dump does not show short GI"

grep -q "72.2 MBit/s" logs/bitrate_mask_after_mcs7_sgi.txt \
    || fail "station dump does not show 72.2 MBit/s for MCS 7 short GI"

log_step "set vw2 to HT MCS 3 long GI"
set_mcs ns2 vw2 3 lgi \
    || fail "failed to set vw2 to MCS 3 long GI"

station_dump logs/bitrate_mask_after_vw2_mcs3_lgi.txt

grep -q "MCS 7" logs/bitrate_mask_after_vw2_mcs3_lgi.txt \
    || fail "station dump lost vw1 MCS 7 state"

grep -q "MCS 3" logs/bitrate_mask_after_vw2_mcs3_lgi.txt \
    || fail "station dump does not show vw2 MCS 3"

grep -q "26.0 MBit/s" logs/bitrate_mask_after_vw2_mcs3_lgi.txt \
    || fail "station dump does not show 26.0 MBit/s for MCS 3 long GI"

log_step "reset vw1 bitrate mask to default"
reset_bitrate_mask ns1 vw1 \
    || fail "failed to reset vw1 bitrate mask"

station_dump logs/bitrate_mask_after_reset.txt

grep -q "MCS 31" logs/bitrate_mask_after_reset.txt \
    || fail "reset result does not show default MCS 31"

grep -q "260.0 MBit/s" logs/bitrate_mask_after_reset.txt \
    || fail "reset result does not show default 260.0 MBit/s"

log_step "collect dmesg evidence"
collect_dmesg

if ! grep -q "set HT MCS 7" "$DMESG_LOG"; then
    warn "dmesg does not contain 'set HT MCS 7'; station dump passed, but pr_info may be missing or string differs"
fi

if ! grep -q "set HT MCS 3" "$DMESG_LOG"; then
    warn "dmesg does not contain 'set HT MCS 3'; station dump passed, but pr_info may be missing or string differs"
fi

write_json "PASS" "bitrate mask updates station dump successfully"

echo
echo "PASS: bitrate mask updates station dump"
echo "Result JSON: $RESULT_JSON"
