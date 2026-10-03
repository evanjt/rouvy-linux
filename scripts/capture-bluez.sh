#!/usr/bin/env bash
# Passive BlueZ capture into one directory: dbus-monitor on org.bluez,
# btmon for the HCI trace, and GetManagedObjects at the end. The layout
# is what tools/capture-to-fixture.py reads and tests/mock-bluez.py
# replays.
#
# Usage:
#   scripts/capture-bluez.sh DIR --seconds N    capture for N seconds
#   scripts/capture-bluez.sh DIR --while PID    capture until PID exits
#
# btmon needs CAP_NET_RAW, so it asks sudo once unless setcap granted it.
# Without it the capture goes on and warnings.txt says so.
set -uo pipefail

OUT=""
SECONDS_TO_WATCH=""
WHILE_PID=""
STOPPED=0

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --seconds) SECONDS_TO_WATCH=$2; shift 2 ;;
        --while) WHILE_PID=$2; shift 2 ;;
        -h|--help) usage ;;
        -*) echo "unknown option: $1" >&2; usage 1 ;;
        *) OUT=$1; shift ;;
    esac
done
[[ -n $OUT && ( -n $SECONDS_TO_WATCH || -n $WHILE_PID ) ]] || usage 1

mkdir -p "$OUT" || exit 1
warn() { echo "WARNING: $*" | tee -a "$OUT/warnings.txt" >&2; }
have() { command -v "$1" >/dev/null; }

# A root btmon cannot be signalled from here, so the shell that started
# it watches for the stop file and ends it itself.
hci_trace() {
    have btmon || { warn "btmon not found, no HCI trace, install bluez-utils"; return; }
    local runner=()
    timeout 1 btmon -w /dev/null > /dev/null 2>&1
    if [[ $? -ne 124 ]]; then
        sudo -n -v 2>/dev/null || echo "btmon needs root for the HCI trace, asking sudo once"
        sudo -v 2>/dev/null || { warn "btmon cannot open the HCI monitor and sudo was refused, no HCI trace"; return; }
        runner=(sudo)
    fi
    : > "$OUT/hci.btsnoop"
    : > "$OUT/btmon.err"
    rm -f "$OUT/stop"
    "${runner[@]}" sh -c 'btmon -w "$1" > /dev/null 2> "$2" & until [ -e "$3" ]; do sleep 1; done; kill $! 2>/dev/null; wait $!' \
        sh "$OUT/hci.btsnoop" "$OUT/btmon.err" "$OUT/stop" &
    HCI_PID=$!
}

watch() {
    if [[ -n $SECONDS_TO_WATCH ]]; then
        sleep "$SECONDS_TO_WATCH"
        return
    fi
    while [[ $STOPPED -eq 0 ]] && kill -0 "$WHILE_PID" 2>/dev/null; do
        sleep 1
    done
}

have dbus-monitor || { warn "dbus-monitor not found, no capture"; exit 1; }
trap 'STOPPED=1' INT TERM
HCI_PID=""
hci_trace
dbus-monitor --system "sender=org.bluez" "destination=org.bluez" > "$OUT/dbus-signals.txt" 2> "$OUT/dbus-monitor.err" &
MON_PID=$!
watch
kill "$MON_PID" 2>/dev/null
wait "$MON_PID" 2>/dev/null
if [[ -n $HCI_PID ]]; then
    touch "$OUT/stop"
    wait "$HCI_PID" 2>/dev/null
    rm -f "$OUT/stop"
fi
busctl --system --json=short call org.bluez / org.freedesktop.DBus.ObjectManager GetManagedObjects \
    > "$OUT/bluez-managed.json" 2>> "$OUT/warnings.txt" || warn "GetManagedObjects failed"
grep -o 'dev_[0-9A-F_]*' "$OUT/dbus-signals.txt" | sort -u | tr '_' ':' | sed 's/^dev://' > "$OUT/seen.txt"
