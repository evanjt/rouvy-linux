#!/usr/bin/env bash
# Fresh install of Rouvy on a private patched Wine.
#
# Everything lands under one directory and nothing outside it is touched.
# A system Wine, if present, is neither used nor modified.
#
#   ROUVY_HOME/
#   ├── wine/        the patched Wine, bin/wine lives here
#   ├── prefix/      WINEPREFIX with Rouvy inside
#   ├── downloads/   the release tarball
#   ├── wine-src/    when building, Wine checkout at the pinned fork tag
#   ├── wine-build/  when building, out of tree build, safe to delete afterwards
#   └── logs/
#
# Usage:
#   scripts/install.sh                                            prebuilt Wine, or a build when there is none
#   scripts/install.sh --build                                    build Wine from source
#   scripts/install.sh --installer Rouvy_Installer.exe            this installer, not the newest one found
#   scripts/install.sh --uninstall
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
ROUVY_HOME="${ROUVY_HOME:-$HOME/.local/share/rouvy-linux}"
RELEASE="${ROUVY_RELEASE:-v0.1.1}"
RELEASE_URL="https://github.com/evanjt/rouvy-linux/releases/download/$RELEASE"
MIN_GLIBC=2.35
WINE_REPO="${WINE_REPO:-https://github.com/evanjt/wine.git}"
WINE_REF="${WINE_REF:-wine-11.18-rouvy-0.1.0}"
JOBS="${JOBS:-$(nproc)}"
# The Wine Mono the fork expects, from dlls/appwiz.cpl/addons.c.
MONO_VERSION=11.3.0
MONO_SHA=df2dfc1665c2511882e7cabd56eafd0c0a3d94e5a7e86f969277f6c189d418d3
INSTALLER=""
INSTALLER_VERSION=""
TARBALL=""
MODE=tarball
UNINSTALL=0
NO_PREBUILT=""

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --installer) INSTALLER=$(readlink -f "$2"); shift 2 ;;
        --home) ROUVY_HOME=$2; shift 2 ;;
        --build) MODE=build; shift ;;
        --tarball) TARBALL=$(readlink -f "$2"); shift 2 ;;
        --skip-build) MODE=existing; shift ;;
        --jobs) JOBS=$2; shift 2 ;;
        --wine-repo) WINE_REPO=$2; shift 2 ;;
        --wine-ref) WINE_REF=$2; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

SRC="$ROUVY_HOME/wine-src"
BUILD="$ROUVY_HOME/wine-build"
WINE_DIR="$ROUVY_HOME/wine"
PREFIX="$ROUVY_HOME/prefix"
DOWNLOADS="$ROUVY_HOME/downloads"
LAUNCHER="$HOME/.local/bin/rouvy"
DESKTOP="$HOME/.local/share/applications/rouvy-linux.desktop"
TARBALL_NAME="wine-rouvy-$RELEASE-x86_64.tar.xz"

LOGS="$ROUVY_HOME/logs"
STEP=0
case $MODE in
    tarball) STEPS=3 ;;
    build) STEPS=6 ;;
    existing) STEPS=2 ;;
esac
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

# The newest Rouvy installer in this directory, beside this script or in Downloads, as "version path".
# Windows version info sits near the start of the file in UTF-16, so dropping the NULs makes it greppable.
find_installer() {
    local dir f info ver best="" best_ver=""
    for dir in "$PWD" "$ROOT/scripts" "$(xdg-user-dir DOWNLOAD 2>/dev/null || echo "$HOME/Downloads")"; do
        for f in "$dir"/*.exe; do
            [[ -f $f ]] || continue
            info=$(head -c 4M "$f" | tr -d '\0' | grep -aoE 'ProductNameRouvy|ProductVersion[0-9.]+' || true)
            [[ $info == *ProductNameRouvy* ]] || continue
            ver=$(sed -n 's/^ProductVersion//p' <<<"$info" | head -n1)
            [[ -n $ver ]] || continue
            if [[ -z $best || $(printf '%s\n%s\n' "$best_ver" "$ver" | sort -V | tail -n1) != "$best_ver" ]]; then
                best=$f best_ver=$ver
            fi
        done
    done
    [[ -n $best ]] && echo "$best_ver $best"
    return 0
}

# Every file this install left outside ROUVY_HOME: ours, Wine's for our prefix, and Rouvy's shortcut,
# icon and menu files once nothing else uses them. Other Wine prefixes keep theirs.
owned_files() {
    local apps="$HOME/.local/share/applications" icons="$HOME/.local/share/icons/hicolor"
    local desktop_dir f others=0 icon_used=0
    desktop_dir=$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")
    [[ -e $LAUNCHER ]] && echo "$LAUNCHER"
    for f in "$apps"/*.desktop "$apps"/wine/Programs/Rouvy/*.desktop "$desktop_dir"/*.desktop; do
        [[ -f $f ]] || continue
        if grep -qsF -e "$PREFIX\"" -e "$LAUNCHER" "$f"; then
            echo "$f"
        else
            [[ $f == "$apps"/wine/Programs/Rouvy/* ]] && others=1
            grep -qsx 'Icon=769D_Rouvy.0' "$f" && icon_used=1
        fi
    done
    if [[ $others -eq 0 ]]; then
        for f in "$apps/wine/Programs/Rouvy" "$HOME/.local/share/desktop-directories/wine-Programs-Rouvy.directory" \
                 "$HOME/.config/menus/applications-merged/wine-Programs-Rouvy-Rouvy.menu"; do
            [[ -e $f ]] && echo "$f"
        done
    fi
    for f in "$icons"/*/apps/rouvy.png; do
        [[ -e $f ]] && echo "$f"
    done
    if [[ $icon_used -eq 0 ]]; then
        for f in "$icons"/*/apps/769D_Rouvy.0.png; do
            [[ -e $f ]] && echo "$f"
        done
    fi
    return 0
}

if [[ $UNINSTALL -eq 1 ]]; then
    mapfile -t files < <(owned_files)
    echo "This removes $(tilde "$ROUVY_HOME") and these files:"
    for f in "${files[@]}"; do
        echo "  $(tilde "$f")"
    done
    read -r -p "Continue? [y/N] " ok
    [[ $ok == y || $ok == Y ]] || exit 1
    [[ -x "$WINE_DIR/bin/wineserver" ]] && WINEPREFIX="$PREFIX" "$WINE_DIR/bin/wineserver" -k || true
    rm -rf "$ROUVY_HOME" "${files[@]}"
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    gtk-update-icon-cache -q "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
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

check_bluetooth() {
    if systemctl is-active --quiet bluetooth 2>/dev/null; then
        note "bluetooth service running"
    else
        warn "The bluetooth service is not running. Sensors need it: sudo systemctl enable --now bluetooth"
    fi
}

# A tarball given with --tarball has to work. Without one, the install builds Wine instead.
no_prebuilt() {
    [[ -n $TARBALL ]] && fail "$1"
    NO_PREBUILT=$1
}

# The tarball is built on Ubuntu 22.04, and Wine loads the desktop libraries it needs at run time.
check_system() {
    step "Check system"
    [[ $(uname -m) == x86_64 ]] || { no_prebuilt "The prebuilt Wine is x86_64 only."; return; }
    local glibc
    glibc=$(ldd --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+$' || true)
    if [[ -z $glibc || $(printf '%s\n%s\n' "$MIN_GLIBC" "$glibc" | sort -V | head -n1) != "$MIN_GLIBC" ]]; then
        no_prebuilt "The prebuilt Wine needs glibc $MIN_GLIBC or newer, this system has ${glibc:-an unknown version}."
        return
    fi
    note "x86_64, glibc $glibc"
    if [[ -z $TARBALL ]] && ! command -v curl >/dev/null && ! command -v wget >/dev/null; then
        no_prebuilt "Needs curl or wget to download Wine."
        return
    fi
    command -v xz >/dev/null || { no_prebuilt "Needs xz to unpack Wine."; return; }
    local libs missing=()
    libs=$( (ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null) || true)
    for lib in libdbus-1.so.3 libgnutls.so.30 libfreetype.so.6; do
        grep -q "$lib" <<<"$libs" || missing+=("$lib")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing libraries: ${missing[*]}. Bluetooth needs D-Bus, Rouvy's login needs GnuTLS and its text FreeType."
    else
        note "D-Bus, GnuTLS and FreeType libraries found"
    fi
    check_bluetooth
}

# Build tools only. Wine's own library dependencies vary by distro, so the
# distro's own build-dependency helper is the reliable source for those.
check_build_tools() {
    step "Check build tools and Bluetooth"
    local missing=()
    for tool in git gcc make bison flex pkg-config x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do
        command -v "$tool" >/dev/null || missing+=("$tool")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing: ${missing[*]}"
        note "Install the build dependencies, then run this again. Arch:"
        note "  sudo pacman -S --needed base-devel git mingw-w64-gcc bluez bluez-utils dbus gnutls freetype2 fontconfig libx11 libxext libxrandr libxi libxcursor libxinerama libxcomposite libxrender libxfixes wayland libxkbcommon mesa vulkan-icd-loader libpulse alsa-lib gst-plugins-base-libs"
        note "Ubuntu 24.04 or newer, Debian 13 or newer:"
        note "  sudo apt install build-essential git gcc-mingw-w64 g++-mingw-w64 bison flex gettext pkg-config bluez libdbus-1-dev libgnutls28-dev libfreetype-dev libfontconfig-dev libx11-dev libxext-dev libxrandr-dev libxi-dev libxcursor-dev libxinerama-dev libxcomposite-dev libxrender-dev libxfixes-dev libwayland-dev libxkbcommon-dev libxkbregistry-dev libgl-dev libegl-dev libvulkan-dev libpulse-dev libasound2-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev"
        note "Other distros: Wine's own build dependencies, plus git and the MinGW C and C++ cross compilers."
        exit 1
    fi
    note "build tools found"
    check_bluetooth
}

fetch() {
    if command -v curl >/dev/null; then
        curl -fL --progress-bar -o "$2" "$1"
    else
        wget -q --show-progress -O "$2" "$1"
    fi
}

download_wine() {
    step "Download Wine"
    if [[ -z $TARBALL ]] && grep -qx "rouvy-linux: $RELEASE" "$WINE_DIR/VERSION" 2>/dev/null; then
        note "Wine for $RELEASE already in $(tilde "$WINE_DIR")"
        return
    fi
    local tarball=$TARBALL
    if [[ -z $tarball ]]; then
        mkdir -p "$DOWNLOADS"
        tarball="$DOWNLOADS/$TARBALL_NAME"
        note "$RELEASE_URL/$TARBALL_NAME"
        fetch "$RELEASE_URL/$TARBALL_NAME" "$tarball" || { no_prebuilt "No prebuilt Wine for $RELEASE."; return; }
        fetch "$RELEASE_URL/$TARBALL_NAME.sha256" "$tarball.sha256" || { no_prebuilt "No checksum for the prebuilt Wine."; return; }
        if ! (cd "$DOWNLOADS" && sha256sum --quiet -c "$TARBALL_NAME.sha256"); then
            rm -f "$tarball"
            no_prebuilt "The prebuilt Wine does not match its checksum."
            return
        fi
        note "checksum matches"
    else
        [[ -f $tarball ]] || fail "No tarball at $tarball"
        note "from $(tilde "$tarball")"
    fi
    local fresh="$ROUVY_HOME/wine.new"
    rm -rf "$fresh"
    mkdir -p "$fresh"
    note "unpacking into $(tilde "$WINE_DIR")"
    run "$LOGS/unpack.log" 0 tar -xJf "$tarball" --strip-components=1 -C "$fresh"
    rm -rf "$WINE_DIR"
    mv "$fresh" "$WINE_DIR"
    if ! "$WINE_DIR/bin/wine" --version >/dev/null 2>&1; then
        rm -rf "$WINE_DIR"
        no_prebuilt "The prebuilt Wine does not run here."
        return
    fi
    note "$("$WINE_DIR/bin/wine" --version)"
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
    sed "s|^Exec=rouvy|Exec=$LAUNCHER|" "$ROOT/packaging/rouvy-linux.desktop" >"$DESKTOP"
    # The menu entry also takes the com.rouvy:// login link from the browser.
    update-desktop-database "$(dirname "$DESKTOP")" 2>/dev/null || true
    note "launcher $(tilde "$LAUNCHER"), menu entry $(tilde "$DESKTOP")"
}

# Wine looks for Mono in its own data directory first, so the prefix gets it without asking.
add_mono() {
    local dir="$WINE_DIR/share/wine/mono" msi="wine-mono-$MONO_VERSION-x86.msi"
    [[ -f $dir/$msi ]] && return
    mkdir -p "$dir"
    if [[ -f $HOME/.cache/wine/$msi ]]; then
        cp "$HOME/.cache/wine/$msi" "$dir/$msi.part"
    else
        note "downloading Wine Mono $MONO_VERSION"
        fetch "https://dl.winehq.org/wine/wine-mono/$MONO_VERSION/$msi" "$dir/$msi.part" || true
    fi
    if [[ $(sha256sum "$dir/$msi.part" 2>/dev/null | cut -d' ' -f1) == "$MONO_SHA" ]]; then
        mv "$dir/$msi.part" "$dir/$msi"
        note "Wine Mono $MONO_VERSION"
    else
        rm -f "$dir/$msi.part"
        warn "No Wine Mono, Wine will offer to download it when it makes the prefix"
    fi
}

install_rouvy() {
    step "Install Rouvy"
    install_launcher
    add_mono
    if [[ -z "$INSTALLER" ]]; then
        note "No Rouvy installer found here or in Downloads. Download it and run this again, or later:"
        note "  rouvy --installer /path/to/Rouvy_Installer.exe"
        return
    fi
    ROUVY_HOME="$ROUVY_HOME" ROUVY_LAUNCHER="$LAUNCHER" "$ROOT/scripts/rouvy.sh" --installer "$INSTALLER" | sed 's/^/      /'
}

if [[ -z $INSTALLER ]]; then
    read -r INSTALLER_VERSION INSTALLER < <(find_installer) || true
fi

mkdir -p "$LOGS"
printf '\033[1mrouvy-linux installer\033[0m\n'
case $MODE in
    tarball) note "Wine from    $(tilde "${TARBALL:-$RELEASE_URL/$TARBALL_NAME}")" ;;
    build)
        note "Wine source  $WINE_REPO @ $WINE_REF"
        note "checkout     $(tilde "$SRC")"
        note "build        $(tilde "$BUILD")"
        ;;
esac
note "Wine         $(tilde "$WINE_DIR")"
note "prefix       $(tilde "$PREFIX")"
note "logs         $(tilde "$LOGS")"
note "launcher     $(tilde "$LAUNCHER")"
note "installer    $(tilde "${INSTALLER:-none found, Rouvy is not installed this run}")${INSTALLER_VERSION:+, Rouvy $INSTALLER_VERSION}"
if [[ $MODE == tarball ]]; then
    check_system
    if [[ -z $NO_PREBUILT ]]; then download_wine; fi
    if [[ -n $NO_PREBUILT ]]; then
        warn "$NO_PREBUILT Building Wine from source instead."
        MODE=build
        STEPS=$((STEP + 6))
    fi
fi
case $MODE in
    build)
        check_build_tools
        fetch_source
        build_wine
        ;;
    existing)
        step "Check Bluetooth"
        check_bluetooth
        ;;
esac
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
