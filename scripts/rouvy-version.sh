#!/usr/bin/env bash
# Print the Rouvy version installed in a prefix, or the known-good one.
#
# Usage:
#   scripts/rouvy-version.sh [WINEPREFIX]   installed version, "unknown" and exit 1 if none
#   scripts/rouvy-version.sh --known        the version this repository last rode on
#
# Rouvy's own log names the running backend build. The Unity build file
# only carries the short version, so it is the fallback.

# Moves with the last row of the README compatibility table.
KNOWN_GOOD=4.7.2.541

if [[ ${1:-} == --known ]]; then
    echo "$KNOWN_GOOD"
    exit 0
fi

PREFIX=${1:-${WINEPREFIX:-$HOME/.wine}}
LOG=$(ls -1 "$PREFIX"/drive_c/users/*/AppData/LocalLow/VirtualTraining/ROUVY/rouvy.log 2>/dev/null | head -n1)
BUILD="$PREFIX/drive_c/Program Files/VirtualTraining/Rouvy/Rouvy_Data/globalgamemanagers"
ver=""
if [[ -f $LOG ]]; then
    ver=$(grep -o 'Configuring app backend - version: "[0-9.]*"\."[0-9]*"' "$LOG" | tail -n1 \
        | sed 's/.*version: "\([0-9.]*\)"\."\([0-9]*\)"/\1.\2/')
    [[ -z $ver ]] && ver=$(grep -o 'App version changed.* to "[0-9.]*"' "$LOG" | tail -n1 | sed 's/.*to "\([0-9.]*\)"/\1/')
fi
[[ -z $ver && -f $BUILD ]] && ver=$(strings "$BUILD" | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$')
[[ -n $ver ]] || { echo unknown; exit 1; }
echo "$ver"
