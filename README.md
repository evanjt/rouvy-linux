# rouvy-linux

**Ride Rouvy on Linux with Bluetooth LE sensors.**

Rouvy's Bluetooth plugin needs Windows APIs that Wine only partly
implements. This repository builds a [patched Wine](https://github.com/evanjt/wine)
into its own directory, installs Rouvy into its own prefix and launches
it. A system Wine is never used or touched.

A proof of concept. Not affiliated with Rouvy or the Wine project.

## Install

```bash
git clone https://github.com/evanjt/rouvy-linux.git
cd rouvy-linux/scripts
./install.sh
```

`install.sh` downloads a prebuilt patched Wine (x86_64, glibc 2.35 or
newer) and checks it runs. Without one it builds Wine from source, see
below. Then it runs the Rouvy installer silently. It uses the newest one
in its directory or in Downloads, by the version inside it, and downloads
one from Rouvy when there is none. `--installer FILE` picks one.
Everything goes under `~/.local/share/rouvy-linux`.

Start Rouvy and log in:

```bash
rouvy
```

The Rouvy entry in your application menu works too. Both run the patched
Wine.

If the installer download stops working, get it from your Rouvy account
with your browser's user agent set to Windows and pass it with
`--installer`.
`./install.sh --uninstall` lists everything the install added, shortcuts,
menu entries, link handlers and icons included, and removes it. Other Wine
prefixes keep theirs.

### Build Wine from source

The install builds Wine itself when the prebuilt one can't run, on an
older or non-x86_64 system for example. `--build` builds it anyway. Both
need the build dependencies first. Arch:

```bash
sudo pacman -S --needed base-devel git mingw-w64-gcc bluez bluez-utils \
    dbus gnutls freetype2 fontconfig libx11 libxext libxrandr libxi \
    libxcursor libxinerama libxcomposite libxrender libxfixes wayland \
    libxkbcommon mesa vulkan-icd-loader libpulse alsa-lib \
    gst-plugins-base-libs
```

Ubuntu 24.04 or newer, Debian 13 or newer:

```bash
sudo apt install build-essential git gcc-mingw-w64 g++-mingw-w64 bison \
    flex gettext pkg-config bluez libdbus-1-dev libgnutls28-dev \
    libfreetype-dev libfontconfig-dev libx11-dev libxext-dev \
    libxrandr-dev libxi-dev libxcursor-dev libxinerama-dev \
    libxcomposite-dev libxrender-dev libxfixes-dev libwayland-dev \
    libxkbcommon-dev libxkbregistry-dev libgl-dev libegl-dev \
    libvulkan-dev libpulse-dev libasound2-dev libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev
```

Then:

```bash
./install.sh --build
```

The build takes minutes on a fast machine, up to an hour on a slow one.

### Tested with

Needs BlueZ 5.48 or newer.

| Rouvy | rouvy-linux | Wine fork | BlueZ | Kernel |
|---|---|---|---|---|
| 4.7.2.541 | v0.1.3 | wine-11.18-rouvy-0.1.2 | 5.87 | 7.2 |

Rouvy updates itself, so the launcher warns when the installed version
is not the one above.

## Riding

- Leave the sensors unpaired in `bluetoothctl`. BlueZ hands a device to
  one client, and that has to be Rouvy.
- Don't scan from anything else on the same adapter. It cuts the
  advertisements Rouvy sees about sevenfold.
- Wake each sensor before selecting it. Pedals sleep after a few idle
  minutes, and a watch stops broadcasting heart rate once its previous
  link ends, so start the broadcast again before each ride.
- The first connect after a reboot takes a second or two. Later ones take
  three to six, at the interval the sensor itself asks for.

Sensors tested on an Intel AX200:

| Sensor | Status |
|---|---|
| Wahoo KICKR | Full rides |
| Garmin HRM600 | Full rides |
| Garmin Fenix 7 (heart rate broadcast) | Works |
| Garmin Rally | Pairs, then drops the link about once a minute. Use the trainer for cadence |

## Debugging

No sensors at all usually means the adapter is off:

```bash
bluetoothctl power on
rfkill unblock bluetooth
```

With two adapters, pick one with `ROUVY_BT_ADAPTER=hci1 rouvy`.

A sensor that Rouvy finds but leaves on "connecting" for good usually
means the kernel's Bluetooth stack is stuck. Reboot. A connect normally
takes a few seconds.

Don't switch windows while Rouvy connects. When its window regains focus,
it drops the sensor and starts over.

Each launch writes a Wine log to `~/.local/share/rouvy-linux/logs/`. Add
the Bluetooth driver's trace with:

```bash
WINEDEBUG=-all,+timestamp,+winebth rouvy
```

To record BlueZ and the HCI trace for a whole ride (asks for sudo once,
for `btmon`):

```bash
rouvy --capture
```

`ROUVY_CAPTURE=1` does the same from a desktop launcher. Without Rouvy
running, `scripts/diagnose.sh` records the adapter, BlueZ and a minute of
sensor traffic into a tarball. Keep pedalling while it runs:

```bash
scripts/diagnose.sh C0:FF:EE:00:00:01 C0:FF:EE:00:00:02
```

Both hold every address the adapter heard, neighbours included. Strip a
capture down to your own sensors before sharing it:

```bash
tools/capture-to-fixture.py --anonymise <capture dir> <sensor address>... > fixture.json
```

Attach that and the Wine log to an issue, with your Rouvy version.

## Development

The Wine changes live on the fork at tag `wine-11.18-rouvy-0.1.2`. Build
it beside this repository and never `make install` it:

```bash
git clone --branch wine-11.18-rouvy-0.1.2 https://github.com/evanjt/wine.git ../wine
mkdir ../wine-build2 && cd ../wine-build2
../wine/configure --enable-archs=x86_64,i386 --disable-tests
make -j"$(nproc)"
cd ../rouvy-linux
scripts/dev-wine.sh wine ~/Downloads/Rouvy_Installer.exe
scripts/dev-wine.sh winecfg -v win10
scripts/run-rouvy.sh
```

`run-rouvy.sh` runs Rouvy on that build with the prefix in `~/.wine` and
logs in `runs/`. `tests/run.sh --wine` replays a recorded ride through the
patched driver and Rouvy's own plugin, no sensors needed (see
`tests/README.md`). Run `git config core.hooksPath .githooks` once to
block commits of compiled binaries.

## Limitations

ANT+ over USB is untested, Wahoo direct connect over the network does
not work, and the fork targets Wine 11.18 only.

## Licence

MIT, see `LICENSE`. The Wine fork is LGPL 2.1 or later, like Wine. Rouvy
is proprietary and not included.
