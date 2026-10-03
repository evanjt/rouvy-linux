#!/usr/bin/env bash
# Launch Rouvy on the sibling patched Wine build through scripts/rouvy.sh,
# with the prefix in ~/.wine, logs in runs/ and captures in captures/.
#
# Usage:
#   scripts/run-rouvy.sh [--capture]
#
# --capture, or ROUVY_CAPTURE=1, records BlueZ and the HCI trace for the
# whole ride into captures/ride-<stamp>/, asking sudo once for btmon.
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
BUILD="${WINE_BUILD:-$ROOT/../wine-build2}"
PREFIX="${WINEPREFIX:-$HOME/.wine}"
WINE_BUILD="$BUILD" "$ROOT/scripts/dev-wine.sh" wine --version >/dev/null || exit 1
# A system Wine may hold the prefix, and its wineserver speaks another protocol.
WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null
export ROUVY_WINE_BUILD="$BUILD" ROUVY_PREFIX="$PREFIX"
export ROUVY_LOG="${ROUVY_LOG:-$ROOT/runs/rouvy-$(date +%Y%m%d-%H%M%S).log}"
export ROUVY_CAPTURE_ROOT="${ROUVY_CAPTURE_ROOT:-$ROOT/captures}"
exec "$ROOT/scripts/rouvy.sh" "$@"
