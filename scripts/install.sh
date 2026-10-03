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
#   scripts/install.sh --installer Rouvy_Installer.exe
#   scripts/install.sh --uninstall
set -Eeuo pipefail

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

LOGS="$ROUVY_HOME/logs"
STEP=0
STEPS=6
[[ $SKIP_BUILD -eq 1 ]] && STEPS=2
DRAWER=""
trap 'if [[ -n $DRAWER ]]; then kill "$DRAWER" 2>/dev/null; printf "\n"; fi' EXIT
trap 'fail "Unexpected error at line $LINENO: $BASH_COMMAND"' ERR
trap 'printf "\n"; warn "Stopped"; exit 130' INT TERM

tilde() { echo "${1/#$HOME/\~}"; }
step() { STEP=$((STEP + 1)); printf '\n\033[1m[%d/%d] %s\033[0m\n' "$STEP" "$STEPS" "$*"; }
note() { printf '      %s\n' "$*"; }
warn() { printf '      \033[33m%s\033[0m\n' "$*" >&2; }
fail() { printf '      \033[31m%s\033[0m\n' "$*" >&2; exit 1; }
clock() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }

if [[ $UNINSTALL -eq 1 ]]; then
    echo "This removes $(tilde "$ROUVY_HOME"), $(tilde "$LAUNCHER") and $(tilde "$DESKTOP")"
    read -r -p "Continue? [y/N] " ok
    [[ $ok == y || $ok == Y ]] || exit 1
    [[ -x "$WINE_DIR/bin/wineserver" ]] && WINEPREFIX="$PREFIX" "$WINE_DIR/bin/wineserver" -k || true
    rm -rf "$ROUVY_HOME" "$LAUNCHER" "$DESKTOP"
    echo "Removed"
    exit 0
fi

# Elapsed time while a step runs, and a bar when the step's LOG is expected to reach TOTAL lines.
draw() {
    trap - ERR INT TERM EXIT
    set +eo pipefail
    local total=$1 log=$2 start=$SECONDS n pct bar
    while :; do
        if [[ $total -gt 0 ]]; then
            n=$(wc -l <"$log" 2>/dev/null)
            pct=$((${n:-0} * 100 / total))
            [[ $pct -gt 99 ]] && pct=99
            printf -v bar '%*s' $((pct * 30 / 100)) ''
            printf '\r      [%-30s] %3d%%  %s ' "${bar// /#}" "$pct" "$(clock $((SECONDS - start)))"
        else
            printf '\r      %s ' "$(clock $((SECONDS - start)))"
        fi
        sleep 1
    done
}

# Run a command with its output in LOG, a progress line while it runs and the log's tail if it fails.
run() {
    local log=$1 total=$2 rc=0 start=$SECONDS
    shift 2
    if [[ -t 1 ]]; then
        draw "$total" "$log" &
        DRAWER=$!
    fi
    "$@" >"$log" 2>&1 || rc=$?
    if [[ -n $DRAWER ]]; then
        kill "$DRAWER" 2>/dev/null || true
        wait "$DRAWER" 2>/dev/null || true
        DRAWER=""
        printf '\r\033[K'
    fi
    if [[ $rc -ne 0 ]]; then
        tail -n 30 "$log" >&2
        fail "Failed, the full log is $(tilde "$log")"
    fi
    note "done in $(clock $((SECONDS - start)))"
}

# Build tools only. Wine's own library dependencies vary by distro, so the
# distro's own build-dependency helper is the reliable source for those.
check_deps() {
    step "Check build tools and Bluetooth"
    if [[ $SKIP_BUILD -eq 0 ]]; then
        local missing=()
        for tool in git gcc make bison flex pkg-config x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do
            command -v "$tool" >/dev/null || missing+=("$tool")
        done
        if [[ ${#missing[@]} -gt 0 ]]; then
            warn "Missing: ${missing[*]}"
            note "Install Wine's build dependencies, then run this again:"
            note "  Arch:          sudo pacman -S --needed base-devel git bison flex mingw-w64-gcc dbus bluez bluez-utils"
            note "  Debian/Ubuntu: sudo apt build-dep wine && sudo apt install git gcc-mingw-w64"
            note "  Fedora:        sudo dnf builddep wine && sudo dnf install git mingw64-gcc mingw32-gcc"
            exit 1
        fi
        note "build tools found"
    fi
    if systemctl is-active --quiet bluetooth 2>/dev/null; then
        note "bluetooth service running"
    else
        warn "The bluetooth service is not running. Sensors need it: sudo systemctl enable --now bluetooth"
    fi
}

fetch_source() {
    step "Download Wine source"
    note "$WINE_REPO @ $WINE_REF"
    if [[ -d "$SRC/.git" ]]; then
        run "$LOGS/git.log" 0 sh -c 'git -C "$1" fetch --depth=1 origin "$2" && git -C "$1" checkout -q --detach FETCH_HEAD' _ "$SRC" "$WINE_REF"
    else
        run "$LOGS/git.log" 0 git -c advice.detachedHead=false clone --depth=1 --branch "$WINE_REF" "$WINE_REPO" "$SRC"
    fi
    note "$(git -C "$SRC" --no-pager log -1 --format='%h %s')"
}

configure_wine() (
    cd "$BUILD" && "$SRC/configure" --prefix="$WINE_DIR" --enable-archs=x86_64,i386 --disable-tests \
        ${CCACHE:+CC="ccache gcc" CROSSCC="ccache x86_64-w64-mingw32-gcc"}
)

build_wine() {
    mkdir -p "$BUILD"
    step "Configure Wine"
    if [[ -f "$BUILD/Makefile" ]]; then
        note "already configured"
    else
        note "log: $(tilde "$LOGS/configure.log")"
        run "$LOGS/configure.log" 0 configure_wine
    fi
    if grep -q 'define SONAME_LIBDBUS_1' "$BUILD/include/config.h"; then
        note "D-Bus found, Bluetooth will work"
    else
        warn "configure did not find D-Bus, Bluetooth will not work"
    fi

    step "Build Wine"
    local total
    total=$(make -C "$BUILD" -n 2>/dev/null | wc -l) || total=0
    note "$JOBS jobs, minutes on a fast machine, up to an hour on a slow one"
    note "log: $(tilde "$LOGS/build.log")"
    run "$LOGS/build.log" "$total" make -C "$BUILD" -j"$JOBS"

    step "Install Wine"
    note "into $(tilde "$WINE_DIR")"
    run "$LOGS/install.log" 0 make -C "$BUILD" install
}

install_launcher() {
    mkdir -p "$(dirname "$LAUNCHER")" "$(dirname "$DESKTOP")"
    cat >"$LAUNCHER" <<EOF
#!/usr/bin/env bash
ROUVY_HOME="$ROUVY_HOME" ROUVY_LAUNCHER="$LAUNCHER" exec "$ROOT/scripts/rouvy.sh" "\$@"
EOF
    chmod +x "$LAUNCHER"
    sed "s|^Exec=.*|Exec=$LAUNCHER|" "$ROOT/packaging/rouvy-linux.desktop" >"$DESKTOP"
    note "launcher $(tilde "$LAUNCHER"), menu entry $(tilde "$DESKTOP")"
}

install_rouvy() {
    step "Install Rouvy"
    install_launcher
    if [[ -z "$INSTALLER" ]]; then
        note "No --installer given. Download the Rouvy installer later and run:"
        note "  rouvy --installer /path/to/Rouvy_Installer.exe"
        return
    fi
    ROUVY_HOME="$ROUVY_HOME" ROUVY_LAUNCHER="$LAUNCHER" "$ROOT/scripts/rouvy.sh" --installer "$INSTALLER" | sed 's/^/      /'
}

mkdir -p "$LOGS"
printf '\033[1mrouvy-linux installer\033[0m\n'
if [[ $SKIP_BUILD -eq 0 ]]; then
    note "Wine source  $WINE_REPO @ $WINE_REF"
    note "checkout     $(tilde "$SRC")"
    note "build        $(tilde "$BUILD")"
fi
note "Wine         $(tilde "$WINE_DIR")"
note "prefix       $(tilde "$PREFIX")"
note "logs         $(tilde "$LOGS")"
note "launcher     $(tilde "$LAUNCHER")"
note "installer    $(tilde "${INSTALLER:-none, Rouvy is not installed this run}")"
check_deps
if [[ $SKIP_BUILD -eq 0 ]]; then
    fetch_source
    build_wine
fi
[[ -x "$WINE_DIR/bin/wine" ]] || fail "No Wine in $(tilde "$WINE_DIR"), run without --skip-build"
install_rouvy
echo
if [[ $(command -v rouvy || true) == "$LAUNCHER" ]]; then
    printf '\033[1mDone.\033[0m Start Rouvy with: rouvy\n'
else
    printf '\033[1mDone.\033[0m Start Rouvy with: %s\n' "$(tilde "$LAUNCHER")"
    note "($(tilde "$(dirname "$LAUNCHER")") is not on your PATH, add it to type just rouvy)"
fi
shortcut="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")/Rouvy.desktop"
if [[ -f $shortcut ]]; then
    note "or from the application menu (Rouvy) or the desktop shortcut (Rouvy (Linux))."
else
    note "or from the application menu (Rouvy)."
fi
note "Each runs the patched Wine. Rouvy rewrites its shortcuts when it updates, so every start re-points them."
