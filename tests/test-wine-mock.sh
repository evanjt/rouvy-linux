#!/usr/bin/env bash
# The patched winebth.sys discovers, connects and subscribes through Rouvy's plugin, and
# wclprobe receives the mock's recorded heart rate. Settings are in tests/README.md.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
FIXTURE=${1:-$ROOT/tests/fixtures/ride-2026-09-18.json}
HRM=C0:FF:EE:00:00:02
SECONDS_STREAMED=10
MIN_PACKETS=15
ROUVY_PLUGINS=${ROUVY_PLUGINS:-$HOME/.wine/drive_c/Program Files/VirtualTraining/Rouvy/Rouvy_Data/Plugins/x86_64}
WINE_BUILD=${WINE_BUILD:-$ROOT/../wine-build2}

if pgrep -x Rouvy.exe >/dev/null; then
    echo "Rouvy is running, not starting a second Wine beside it" >&2
    exit 1
fi
if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} || ${DBUS_SYSTEM_BUS_ADDRESS:-} != "$DBUS_SESSION_BUS_ADDRESS" ]]; then
    exec dbus-run-session -- bash -c 'export DBUS_SYSTEM_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS; exec "$0" "$@"' "$0" "$@"
fi

if [[ -x $WINE_BUILD/loader/wine ]]; then
    run() { WINE_BUILD=$WINE_BUILD "$ROOT/scripts/dev-wine.sh" "$@"; }
else
    run() { "$@"; }
fi
CLIENT=${CLIENT:-}
if [[ -z $CLIENT ]]; then
    [[ -f "$ROUVY_PLUGINS/WclBlePluginCPP.dll" ]] || { echo "no Rouvy plugin in $ROUVY_PLUGINS, set ROUVY_PLUGINS or CLIENT" >&2; exit 1; }
    [[ -x $ROOT/tools/wclprobe.exe.so ]] || run winegcc -o "$ROOT/tools/wclprobe.exe" "$ROOT/tools/wclprobe.c"
    CLIENT=$ROOT/tools/wclprobe.exe.so
fi

TMP=$(mktemp -d)
export WINEPREFIX=$TMP/prefix
export WINEDLLOVERRIDES="mscoree,mshtml=d"
export WINEDEBUG=${WINEDEBUG:--all,+timestamp,+winebth}
cleanup() {
    run wineserver -k 2>/dev/null || true
    [[ -n ${MOCK:-} ]] && { kill "$MOCK" 2>/dev/null && wait "$MOCK" 2>/dev/null; } || true
    [[ ${KEEP:-0} == 1 ]] && echo "kept $TMP" || rm -rf "$TMP"
}
trap cleanup EXIT

python3 "$ROOT/tests/mock-bluez.py" "$FIXTURE" 2>"$TMP/mock.log" &
MOCK=$!
for _ in $(seq 50); do
    grep -q 'mock bluez ready' "$TMP/mock.log" && break
    sleep 0.1
done
grep -q 'mock bluez ready' "$TMP/mock.log" || { cat "$TMP/mock.log" >&2; exit 1; }

run wineboot -u >"$TMP/wineboot.log" 2>&1
run winecfg -v win10 >>"$TMP/wineboot.log" 2>&1
run wineserver -w
if [[ $CLIENT == *wclprobe* ]]; then
    dst="$WINEPREFIX/drive_c/Program Files/VirtualTraining/Rouvy/Rouvy_Data/Plugins/x86_64"
    mkdir -p "$dst"
    cp "$ROUVY_PLUGINS"/Wcl* "$dst/"
fi

address=${HRM//:/}
address=${address,,}
run wine "$CLIENT" "$address" "$SECONDS_STREAMED" 1 >"$TMP/client.out" 2>"$TMP/client.err" || {
    echo "client failed, see $TMP" >&2
    KEEP=1
    tail -n 20 "$TMP/client.out" "$TMP/client.err" >&2
    exit 1
}

fail() { echo "$1" >&2; KEEP=1; cat "$TMP/mock.log" >&2; exit 1; }
dev=/org/bluez/hci0/dev_${HRM//:/_}
calls=$(grep -oE '^(GetManagedObjects|SetDiscoveryFilter|StartDiscovery|Connect|StartNotify)' "$TMP/mock.log" | uniq | tr '\n' ' ')
[[ $calls == *"GetManagedObjects "*"SetDiscoveryFilter StartDiscovery "*"Connect StartNotify"* ]] \
    || fail "mock did not see discovery then connect then notify: $calls"
grep -q "SetDiscoveryFilter.*'le'" "$TMP/mock.log" || fail "discovery filter is not LE only"
grep -q "^Connect $dev$" "$TMP/mock.log" || fail "the client never connected $dev"
grep -q "^StartNotify $dev/" "$TMP/mock.log" || fail "the client never subscribed on $dev"
grep -q "advertisement: $address" "$TMP/client.out" || fail "the client never saw $address advertise"
packets=$(grep -oE 'uuid=2a37 .*packets=[0-9]+' "$TMP/client.out" | grep -oE '[0-9]+$' || echo 0)
echo "heart rate: $packets packets in $SECONDS_STREAMED s from the mock"
(( packets >= MIN_PACKETS )) || fail "expected at least $MIN_PACKETS heart rate packets"
echo ok
