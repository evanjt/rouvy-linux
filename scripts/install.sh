#!/usr/bin/env bash
# Fresh install of Rouvy on a private patched Wine.
#
# Everything lands under one directory and nothing outside it is touched.
# A system Wine, if present, is neither used nor modified.
#
#   ROUVY_HOME/
#   ├── wine-src/    Wine checkout at the pinned fork tag
#   ├── wine-build/  out of tree build, safe to delete afterwards
#   ├── wine/        the installed patched Wine, bin/wine lives here
#   ├── prefix/      WINEPREFIX with Rouvy inside
#   └── logs/
#
# Usage:
#   scripts/install.sh --installer ~/Downloads/RouvySetup.exe
#   scripts/install.sh --uninstall
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
ROUVY_HOME="${ROUVY_HOME:-$HOME/.local/share/rouvy-linux}"
WINE_REPO="${WINE_REPO:-https://github.com/evanjt/wine.git}"
WINE_REF="${WINE_REF:-wine-11.18-rouvy-0.1.0}"
JOBS="${JOBS:-$(nproc)}"
INSTALLER=""
SKIP_BUILD=0
UNINSTALL=0

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --installer) INSTALLER=$(readlink -f "$2"); shift 2 ;;
        --home) ROUVY_HOME=$2; shift 2 ;;
        --jobs) JOBS=$2; shift 2 ;;
        --wine-repo) WINE_REPO=$2; shift 2 ;;
        --wine-ref) WINE_REF=$2; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

SRC="$ROUVY_HOME/wine-src"
BUILD="$ROUVY_HOME/wine-build"
WINE_DIR="$ROUVY_HOME/wine"
PREFIX="$ROUVY_HOME/prefix"
LAUNCHER="$HOME/.local/bin/rouvy"
DESKTOP="$HOME/.local/share/applications/rouvy-linux.desktop"

say() { printf '\033[1m== %s\033[0m\n' "$*"; }

if [[ $UNINSTALL -eq 1 ]]; then
    say "This removes $ROUVY_HOME, $LAUNCHER and $DESKTOP"
    read -r -p "Continue? [y/N] " ok
    [[ $ok == y || $ok == Y ]] || exit 1
    [[ -x "$WINE_DIR/bin/wineserver" ]] && WINEPREFIX="$PREFIX" "$WINE_DIR/bin/wineserver" -k || true
    rm -rf "$ROUVY_HOME" "$LAUNCHER" "$DESKTOP"
    say "Removed"
    exit 0
fi

# Build tools only. Wine's own library dependencies vary by distro, so the
# distro's own build-dependency helper is the reliable source for those.
check_deps() {
    local missing=()
    for tool in git gcc make bison flex pkg-config x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do
        command -v "$tool" >/dev/null || missing+=("$tool")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing build tools: ${missing[*]}" >&2
        echo "Install Wine's build dependencies first. Examples:" >&2
        echo "  Arch:          sudo pacman -S --needed base-devel git bison flex mingw-w64-gcc dbus bluez bluez-utils" >&2
        echo "  Debian/Ubuntu: sudo apt build-dep wine && sudo apt install git gcc-mingw-w64" >&2
        echo "  Fedora:        sudo dnf builddep wine && sudo dnf install git mingw64-gcc mingw32-gcc" >&2
        exit 1
    fi
    if ! systemctl is-active --quiet bluetooth 2>/dev/null; then
        echo "Warning: the bluetooth service is not running. Sensors need it: sudo systemctl enable --now bluetooth" >&2
    fi
}

fetch_source() {
    say "Wine source: $WINE_REPO @ $WINE_REF"
    if [[ -d "$SRC/.git" ]]; then
        git -C "$SRC" fetch --depth=1 origin "$WINE_REF"
        git -C "$SRC" checkout -q --detach FETCH_HEAD
    else
        git clone --depth=1 --branch "$WINE_REF" "$WINE_REPO" "$SRC"
    fi
    git -C "$SRC" log -1 --format='   %h %s'
}

build_wine() {
    say "Configure and build with $JOBS jobs, this takes a while"
    mkdir -p "$BUILD"
    if [[ ! -f "$BUILD/Makefile" ]]; then
        (cd "$BUILD" && "$SRC/configure" --prefix="$WINE_DIR" \
            --enable-archs=x86_64,i386 --disable-tests \
            ${CCACHE:+CC="ccache gcc" CROSSCC="ccache x86_64-w64-mingw32-gcc"} >"$ROUVY_HOME/logs/configure.log" 2>&1) \
            || { tail -n 20 "$ROUVY_HOME/logs/configure.log"; exit 1; }
    fi
    grep -q 'checking for DBUS.*yes' "$BUILD/config.log" \
        || echo "Warning: configure did not find D-Bus, Bluetooth will not work" >&2
    make -C "$BUILD" -j"$JOBS" >"$ROUVY_HOME/logs/build.log" 2>&1 \
        || { tail -n 30 "$ROUVY_HOME/logs/build.log"; exit 1; }
    say "Install into $WINE_DIR"
    make -C "$BUILD" install >"$ROUVY_HOME/logs/install.log" 2>&1
}

install_rouvy() {
    if [[ -z "$INSTALLER" ]]; then
        say "No --installer given, skipping Rouvy setup"
        echo "   Download RouvySetup.exe from Rouvy later and run:"
        echo "   $LAUNCHER --installer /path/to/RouvySetup.exe"
        return
    fi
    ROUVY_HOME="$ROUVY_HOME" ROUVY_LAUNCHER="$LAUNCHER" "$ROOT/scripts/rouvy.sh" --installer "$INSTALLER"
}

install_launcher() {
    say "Launcher: $LAUNCHER"
    mkdir -p "$(dirname "$LAUNCHER")" "$(dirname "$DESKTOP")"
    cat >"$LAUNCHER" <<EOF
#!/usr/bin/env bash
ROUVY_HOME="$ROUVY_HOME" ROUVY_LAUNCHER="$LAUNCHER" exec "$ROOT/scripts/rouvy.sh" "\$@"
EOF
    chmod +x "$LAUNCHER"
    sed "s|^Exec=.*|Exec=$LAUNCHER|" "$ROOT/packaging/rouvy-linux.desktop" >"$DESKTOP"
}

mkdir -p "$ROUVY_HOME/logs"
check_deps
if [[ $SKIP_BUILD -eq 0 ]]; then
    fetch_source
    build_wine
fi
[[ -x "$WINE_DIR/bin/wine" ]] || { echo "No Wine in $WINE_DIR, run without --skip-build" >&2; exit 1; }
install_launcher
install_rouvy
say "Done. Start Rouvy with: rouvy   (or from the application menu)"
