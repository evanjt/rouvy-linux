#!/usr/bin/env bash
# Collect what a sensor report needs, without Wine, into one tarball.
#
# Records BlueZ, kernel, adapters (Powered, rfkill, chipset) and known
# devices, then watches BlueZ passively for a while so the sensors' own
# traffic lands in the capture. Sensors named on the command line are
# converted into a replay fixture, neighbours stay out of it.
#
# Usage:
#   scripts/diagnose.sh [--seconds 60] [--out DIR] [ADDRESS ...]
#
# Wake the sensors first and keep pedalling for the whole capture.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
MIN_BLUEZ=5.48
SECONDS_TO_WATCH=60
OUT=""
ADDRS=()

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --seconds) SECONDS_TO_WATCH=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        -h|--help) usage ;;
        -*) echo "unknown option: $1" >&2; usage 1 ;;
        *) ADDRS+=("${1^^}"); shift ;;
    esac
done

STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${OUT:-$ROOT/captures/diag-$STAMP}
mkdir -p "$OUT"
say() { printf '\033[1m== %s\033[0m\n' "$*"; }
warn() { echo "WARNING: $*" | tee -a "$OUT/warnings.txt" >&2; }
have() { command -v "$1" >/dev/null; }

version_below() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" && "$1" != "$2" ]]
}

host_facts() {
    say "Host"
    {
        echo "date: $(date -Iseconds)"
        echo "kernel: $(uname -r)"
        echo "distro: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
        echo "bluez: $(bluetoothctl --version 2>/dev/null | awk '{print $NF}')"
        echo "bluetooth.service: $(systemctl is-active bluetooth 2>/dev/null)"
        for prefix in "${WINEPREFIX:-}" "${ROUVY_HOME:-$HOME/.local/share/rouvy-linux}/prefix" "$HOME/.wine"; do
            [[ -n $prefix && -d $prefix ]] || continue
            echo "rouvy: $("$ROOT/scripts/rouvy-version.sh" "$prefix" || true) in $prefix"
        done
        for pm in "pacman -Q bluez bluez-utils dbus" "dpkg-query -W bluez dbus" "rpm -q bluez dbus"; do
            $pm 2>/dev/null | sed 's/^/pkg: /' && break
        done
    } | tee "$OUT/host.txt"
    local bluez
    bluez=$(bluetoothctl --version 2>/dev/null | awk '{print $NF}')
    [[ -z $bluez ]] && warn "bluetoothctl not found, install bluez and bluez-utils"
    [[ -n $bluez ]] && version_below "$bluez" "$MIN_BLUEZ" && warn "BlueZ $bluez is below the $MIN_BLUEZ minimum"
    systemctl is-active --quiet bluetooth 2>/dev/null || warn "bluetooth.service is not running"
}

adapter_facts() {
    say "Adapters"
    {
        rfkill list bluetooth 2>/dev/null || echo "rfkill: not available"
        echo
        bluetoothctl list 2>/dev/null
        for hci in /sys/class/bluetooth/hci*; do
            [[ -e $hci ]] || continue
            echo
            echo "$(basename "$hci"): $(readlink -f "$hci/device")"
            cat "$hci/device/uevent" 2>/dev/null | sed 's/^/  /'
        done
        echo
        bluetoothctl show 2>/dev/null
        echo
        lsusb 2>/dev/null | grep -i -E 'bluetooth|wireless|wi-fi' | sed 's/^/usb: /'
        lspci 2>/dev/null | grep -i -E 'bluetooth|network|wireless' | sed 's/^/pci: /'
    } > "$OUT/adapters.txt"
    cat "$OUT/adapters.txt"
    grep -q '^Controller' "$OUT/adapters.txt" || warn "no Bluetooth adapter is registered with BlueZ"
    grep -qi 'Soft blocked: yes\|Hard blocked: yes' "$OUT/adapters.txt" && warn "an adapter is rfkill blocked"
    grep -q 'Powered: yes' "$OUT/adapters.txt" || warn "the adapter is not powered: bluetoothctl power on"
    grep -q 'Discovering: yes' "$OUT/adapters.txt" && warn "another client is already scanning, it can take the sensors before Rouvy"
}

device_facts() {
    say "Known devices"
    bluetoothctl devices 2>/dev/null | tee "$OUT/devices.txt"
    for a in "${ADDRS[@]}"; do
        bluetoothctl info "$a" 2>/dev/null > "$OUT/device-$a.txt"
        grep -q 'Connected: yes' "$OUT/device-$a.txt" && warn "$a is connected to another client, Rouvy cannot take it"
    done
}

capture() {
    say "Watching BlueZ for ${SECONDS_TO_WATCH}s, keep the sensors awake"
    "$ROOT/scripts/capture-bluez.sh" "$OUT" --seconds "$SECONDS_TO_WATCH" || return
    for a in "${ADDRS[@]}"; do
        grep -qx "$a" "$OUT/seen.txt" || warn "$a sent nothing during the capture, is it awake and advertising?"
    done
}

fixture() {
    [[ ${#ADDRS[@]} -gt 0 && -s "$OUT/bluez-managed.json" ]] || return
    say "Fixture for ${ADDRS[*]}"
    python3 "$ROOT/tools/capture-to-fixture.py" "$OUT" "${ADDRS[@]}" > "$OUT/fixture.json" \
        || warn "fixture conversion failed"
}

bundle() {
    local tar="$OUT.tar.gz"
    tar -C "$(dirname "$OUT")" -czf "$tar" "$(basename "$OUT")"
    say "Report: $tar"
    if [[ -s "$OUT/warnings.txt" ]]; then
        say "Warnings"
        cat "$OUT/warnings.txt"
    fi
    echo "Attach the tarball to an issue. Only the sensors named on the command line are in fixture.json,"
    echo "dbus-signals.txt and bluez-managed.json still hold every address the adapter heard."
}

host_facts
adapter_facts
device_facts
capture
fixture
bundle
