# rouvy-linux

**Ride Rouvy on Linux with Bluetooth LE sensors.**

Rouvy's Bluetooth plugin needs Windows APIs that Wine only partly
implements. This repository builds a [patched Wine](https://github.com/evanjt/wine)
into its own directory, installs Rouvy into its own prefix and launches
it. A system Wine is never used or touched.

A proof of concept. Not affiliated with Rouvy or the Wine project.

## Install

Download `RouvySetup.exe` from your Rouvy account, then:

```bash
git clone https://github.com/evanjt/rouvy-linux.git
cd rouvy-linux
scripts/install.sh --installer ~/Downloads/RouvySetup.exe
rouvy
```

The Wine build takes about an hour. To skip it, unpack the tarball from
the latest release and add `--skip-build`:

```bash
mkdir -p ~/.local/share/rouvy-linux/wine
tar -xJf wine-rouvy-v0.1.0-x86_64.tar.xz --strip-components=1 -C ~/.local/share/rouvy-linux/wine
scripts/install.sh --installer ~/Downloads/RouvySetup.exe --skip-build
```

`scripts/install.sh --uninstall` removes everything. On Arch,
`cd packaging && makepkg -si` installs the same Wine to `/opt/wine-rouvy`.

Needs BlueZ 5.48 or newer. Tested with:

| Rouvy | rouvy-linux | Wine fork | BlueZ | Kernel |
|---|---|---|---|---|
| 4.7.2.541 | v0.1.0 | wine-11.18-rouvy-0.1.0 | 5.87 | 7.2 |

Rouvy updates itself, so the launcher warns when the installed version
is not the one above.

## Riding

- Leave the sensors unpaired in `bluetoothctl`. BlueZ hands a device to
  one client, and that has to be Rouvy.
- Don't scan from anything else on the same adapter. It cuts the
  advertisements Rouvy sees about sevenfold.
- Wake each sensor before selecting it. Pedals sleep after a few idle
  minutes.

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

The Wine changes live on the fork at tag `wine-11.18-rouvy-0.1.0`. Build
it beside this repository and never `make install` it:

```bash
git clone --branch wine-11.18-rouvy-0.1.0 https://github.com/evanjt/wine.git ../wine
mkdir ../wine-build2 && cd ../wine-build2
../wine/configure --enable-archs=x86_64,i386 --disable-tests
make -j"$(nproc)"
cd ../rouvy-linux
scripts/dev-wine.sh wine ~/Downloads/RouvySetup.exe
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
