#!/usr/bin/env bash
# Run a command under the sibling Wine build. Usage: scripts/dev-wine.sh wine foo.exe
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
BUILD="${WINE_BUILD:-$ROOT/../wine-build2}"
if [[ ! -x "$BUILD/loader/wine" || ! -x "$BUILD/tools/wine/wine" || ! -x "$BUILD/server/wineserver" ]]; then
    echo "Wine build is missing or incomplete: $BUILD" >&2
    exit 1
fi
BUILD=$(cd "$BUILD" && pwd -P)
export WINELOADER="$BUILD/loader/wine"
export WINESERVER="$BUILD/server/wineserver"
export PATH="$BUILD/tools/wine:$BUILD/server:$PATH"
exec "$@"
