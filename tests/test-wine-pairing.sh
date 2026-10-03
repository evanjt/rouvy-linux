#!/usr/bin/env bash
# pairprobe is refused a subscription with ProtocolError before pairing, pairs through a ConfirmPinMatch
# request carrying the mock's passkey, and then subscribes. Settings are in tests/README.md.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
FIXTURE=${1:-$ROOT/tests/fixtures/hrm600-confirm-2026-09-18.json}
HRM=C0:FF:EE:00:00:02
PASSKEY=123456
WINE_BUILD=${WINE_BUILD:-$ROOT/../wine-build2}
WINE_SRC=${WINE_SRC:-$ROOT/../wine}
PROTOCOL_ERROR=2
CONFIRM_PIN_MATCH=8

if pgrep -x Rouvy.exe >/dev/null; then
    echo "Rouvy is running, not starting a second Wine beside it" >&2
    exit 1
fi
if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} || ${DBUS_SYSTEM_BUS_ADDRESS:-} != "$DBUS_SESSION_BUS_ADDRESS" ]]; then
    exec dbus-run-session -- bash -c 'export DBUS_SYSTEM_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS; exec "$0" "$@"' "$0" "$@"
fi
[[ -x $WINE_BUILD/loader/wine ]] || { echo "no Wine build at $WINE_BUILD, set WINE_BUILD" >&2; exit 1; }
run() { WINE_BUILD=$WINE_BUILD "$ROOT/scripts/dev-wine.sh" "$@"; }

# The generated WinRT headers live in the build tree, the IDL in the source tree.
[[ -x $ROOT/tools/pairprobe.exe.so ]] || run winegcc -fshort-wchar -I"$WINE_BUILD/include" -I"$WINE_SRC/include" \
    -o "$ROOT/tools/pairprobe.exe" "$ROOT/tools/pairprobe.c" -lcombase -luuid

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

address=${HRM//:/}
address=${address,,}
run wine "$ROOT/tools/pairprobe.exe.so" "$address" >"$TMP/client.out" 2>"$TMP/client.err" || {
    echo "pairprobe failed, see $TMP" >&2
    KEEP=1
    tail -n 20 "$TMP/client.out" "$TMP/client.err" >&2
    exit 1
}

fail() { echo "$1" >&2; KEEP=1; cat "$TMP/client.out" "$TMP/mock.log" >&2; exit 1; }
dev=/org/bluez/hci0/dev_${HRM//:/_}
grep -q "^notify before: $PROTOCOL_ERROR$" "$TMP/client.out" || fail "subscribing before pairing was not refused with a protocol error"
grep -q "^kind: 5 paired: 0$" "$TMP/client.out" || fail "DeviceInformation did not report an unpaired association endpoint"
grep -q "^pairing requested: kind=$CONFIRM_PIN_MATCH pin=$PASSKEY$" "$TMP/client.out" \
    || fail "no ConfirmPinMatch PairingRequested event with passkey $PASSKEY"
grep -q "^pair status: 0 requests: 1 paired: 1$" "$TMP/client.out" || fail "pairing did not end Paired after one request"
grep -q "^notify after: 0$" "$TMP/client.out" || fail "subscribing after pairing did not succeed"
grep -q "^Pair $dev$" "$TMP/mock.log" || fail "the driver never called Pair on $dev"
grep -q "^RequestConfirmation $dev$" "$TMP/mock.log" || fail "the mock never asked the driver's agent"
grep -q "^StartNotify $dev/.* refused, not paired$" "$TMP/mock.log" || fail "the mock never refused the unpaired subscription"
echo "paired $HRM through DeviceInformation.Pairing.Custom, heart rate refused before and allowed after"
echo ok
