#!/usr/bin/env bash
# Launch Rouvy from a scripts/install.sh layout or a packaged Wine.
# Only this install's own wineserver is restarted, so other Wine prefixes
# and any system Wine keep running untouched.
#
# Usage:
#   rouvy.sh                                  start Rouvy
#   rouvy.sh --capture                        start Rouvy and record BlueZ and HCI for the ride
#   rouvy.sh --installer ~/Downloads/RouvySetup.exe   create the prefix and install Rouvy
#   rouvy.sh --open com.rouvy://...           hand a browser login link to the running Rouvy
#
#   ROUVY_HOME          prefix, logs and captures, default ~/.local/share/rouvy-linux
#   ROUVY_WINE          the patched Wine, default $ROUVY_HOME/wine
#   ROUVY_WINE_BUILD    a Wine build tree to run instead of ROUVY_WINE
#   ROUVY_PREFIX        the Wine prefix, default $ROUVY_HOME/prefix
#   ROUVY_LOG           the Wine log, default $ROUVY_HOME/logs/rouvy-<stamp>.log
#   ROUVY_CAPTURE_ROOT  where a capture goes, default $ROUVY_HOME/captures
#   ROUVY_CAPTURE       1 is the same as --capture, btmon asks sudo once
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
ROUVY_HOME="${ROUVY_HOME:-$HOME/.local/share/rouvy-linux}"
WINE_DIR="${ROUVY_WINE:-$ROUVY_HOME/wine}"
BUILD="${ROUVY_WINE_BUILD:-}"
export WINEPREFIX="${ROUVY_PREFIX:-$ROUVY_HOME/prefix}"
export WINEDEBUG="${WINEDEBUG:--all}"
APP="$WINEPREFIX/drive_c/Program Files/VirtualTraining/Rouvy"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="${ROUVY_LOG:-$ROUVY_HOME/logs/rouvy-$STAMP.log}"
CAPTURE="${ROUVY_CAPTURE:-0}"
CAPTURE_DIR="${ROUVY_CAPTURE_ROOT:-$ROUVY_HOME/captures}/ride-$STAMP"
INSTALLER=""
OPEN=""

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# winemenubuilder writes menu, desktop and com.rouvy:// handler entries for
# the prefix that run whatever wine is on PATH, usually a system Wine without
# the Bluetooth driver. rouvy-linux.desktop is the menu entry, so Wine's goes,
# and the others are pointed at this launcher. Rouvy rewrites its shortcuts
# on update, so this runs before every launch as well.
rewrite_wine_entries() {
    local apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    local desktop
    desktop=$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")
    local env="ROUVY_HOME=$ROUVY_HOME ROUVY_WINE=$WINE_DIR"
    [[ -n $BUILD ]] && env="ROUVY_HOME=$ROUVY_HOME ROUVY_WINE_BUILD=$BUILD"
    [[ -n ${ROUVY_PREFIX:-} ]] && env+=" ROUVY_PREFIX=$WINEPREFIX"
    [[ -n ${ROUVY_CAPTURE_ROOT:-} ]] && env+=" ROUVY_CAPTURE_ROOT=$ROUVY_CAPTURE_ROOT"
    local launcher="${ROUVY_LAUNCHER:-env $env $(readlink -f "$0")}"
    local f
    for f in "$apps"/wine/Programs/Rouvy/*.desktop; do
        [[ -f $f ]] && grep -qF "WINEPREFIX=$WINEPREFIX\"" "$f" && rm "$f"
    done
    rmdir "$apps/wine/Programs/Rouvy" 2>/dev/null
    for f in "$desktop/Rouvy.desktop" "$apps/wine-protocol-com.rouvy.desktop"; do
        [[ -f $f ]] || continue
        grep -qF "WINEPREFIX=$WINEPREFIX\"" "$f" || continue
        sed -i -e "s|^Exec=env \"WINEPREFIX=[^\"]*\" wine start %u$|Exec=$launcher --open %u|" \
               -e "s|^Exec=env \"WINEPREFIX=[^\"]*\" wine .*|Exec=$launcher|" \
               -e "s|^Name=Rouvy$|Name=Rouvy (Linux)|" "$f"
    done
}

# rouvy-linux.desktop is installed system wide by the package, so it names
# its icon and each user gets a copy of the one winemenubuilder extracted.
copy_rouvy_icon() {
    local f
    for f in "${XDG_DATA_HOME:-$HOME/.local/share}"/icons/hicolor/*/apps/769D_Rouvy.0.png; do
        [[ -f $f ]] && cp -u "$f" "$(dirname "$f")/rouvy.png"
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --capture) CAPTURE=1; shift ;;
        --installer) INSTALLER=$(readlink -f "$2"); shift 2 ;;
        --open) OPEN=$2; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

if [[ -n $BUILD ]]; then
    # A build tree runs the way scripts/dev-wine.sh runs it, and its
    # programs are builtins rather than scripts in bin/.
    [[ -x $BUILD/loader/wine && -x $BUILD/tools/wine/wine && -x $BUILD/server/wineserver ]] \
        || { echo "Wine build is missing or incomplete: $BUILD" >&2; exit 1; }
    BUILD=$(cd "$BUILD" && pwd -P)
    export WINELOADER="$BUILD/loader/wine" WINESERVER="$BUILD/server/wineserver"
    export PATH="$BUILD/tools/wine:$BUILD/server:$PATH"
    wineboot() { wine wineboot "$@"; }
    winecfg() { wine winecfg "$@"; }
else
    [[ -x "$WINE_DIR/bin/wine" ]] || { echo "No patched Wine in $WINE_DIR, run scripts/install.sh or set ROUVY_WINE" >&2; exit 1; }
    export PATH="$WINE_DIR/bin:$PATH"
fi

# A click on the menu entry has no terminal to print the missing-Rouvy
# message to, so ask for the downloaded installer instead.
if [[ -z $INSTALLER && ! -f "$APP/Rouvy.exe" && ! -t 0 ]]; then
    chosen=""
    if command -v zenity >/dev/null; then
        chosen=$(zenity --file-selection --title="Choose the downloaded RouvySetup.exe" --file-filter='*.exe') || exit 0
    elif command -v kdialog >/dev/null; then
        chosen=$(kdialog --getopenfilename ~ '*.exe') || exit 0
    elif command -v notify-send >/dev/null; then
        notify-send "Rouvy is not installed" "Download RouvySetup.exe, then run: $(basename "$0") --installer /path/to/RouvySetup.exe"
    fi
    [[ -n $chosen ]] && INSTALLER=$(readlink -f "$chosen")
fi

if [[ -n $INSTALLER ]]; then
    if [[ -f "$APP/Rouvy.exe" ]]; then
        echo "Rouvy already installed in $WINEPREFIX"
        exit 0
    fi
    [[ -f $INSTALLER ]] || { echo "No installer at $INSTALLER" >&2; exit 1; }
    mkdir -p "$WINEPREFIX" "$ROUVY_HOME/logs"
    INSTALL_LOG="$ROUVY_HOME/logs/installer.log"
    echo "Prefix: $WINEPREFIX"
    wineboot -u >"$INSTALL_LOG" 2>&1
    # The Rouvy BLE plugin only enables its WinRT path on Windows 10.
    winecfg -v win10 >>"$INSTALL_LOG" 2>&1
    wineserver -w
    echo "Running the Rouvy installer. When it finishes and starts Rouvy, close Rouvy."
    echo "Wine output: $INSTALL_LOG"
    wine "$INSTALLER" >>"$INSTALL_LOG" 2>&1
    wineserver -w
    rewrite_wine_entries
    copy_rouvy_icon
    exit 0
fi

[[ -f "$APP/Rouvy.exe" ]] || { echo "Rouvy is not installed in $WINEPREFIX, run: $(basename "$0") --installer /path/to/RouvySetup.exe" >&2; exit 1; }
rewrite_wine_entries
copy_rouvy_icon
# A login link joins the wineserver Rouvy is already running in.
[[ -n $OPEN ]] && exec wine start "$OPEN"
mkdir -p "$(dirname "$LOG")"
LOG="$(cd "$(dirname "$LOG")" && pwd -P)/$(basename "$LOG")"
[[ -n "${ROUVY_BT_ADAPTER:-}" ]] && echo "Bluetooth adapter: $ROUVY_BT_ADAPTER"
VERSION=$("$ROOT/scripts/rouvy-version.sh" "$WINEPREFIX" || true)
KNOWN=$("$ROOT/scripts/rouvy-version.sh" --known)
echo "Rouvy $VERSION, known good $KNOWN"
[[ $VERSION == "$KNOWN" ]] || echo "Rouvy $VERSION has not been verified with this build, $KNOWN has" >&2

# The patched Bluetooth driver only loads into a fresh wineserver.
wineserver -k 2>/dev/null
sleep 1

INHIBIT=()
if python3 -c 'import gi' 2>/dev/null; then
    INHIBIT=(python3 "$ROOT/scripts/inhibit-idle.py")
elif command -v systemd-inhibit >/dev/null; then
    INHIBIT=(systemd-inhibit --what=idle:sleep --who=Rouvy --why='Rouvy ride in progress')
fi

cd "$APP" || exit 1
[[ $CAPTURE == 1 ]] || exec "${INHIBIT[@]}" wine Rouvy.exe >"$LOG" 2>&1
"${INHIBIT[@]}" wine Rouvy.exe >"$LOG" 2>&1 &
ROUVY_PID=$!
"$ROOT/scripts/capture-bluez.sh" "$CAPTURE_DIR" --while "$ROUVY_PID" &
CAPTURE_PID=$!
trap 'kill "$ROUVY_PID" 2>/dev/null' INT TERM
wait "$ROUVY_PID"
wait "$CAPTURE_PID"
echo "Capture: $CAPTURE_DIR"
echo "It holds every address the adapter heard. tools/capture-to-fixture.py keeps only the sensors you name."
