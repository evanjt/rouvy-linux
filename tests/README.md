# Tests

`tests/run.sh` runs the two guards: no real address or serial in a
fixture, and no compiled binary in the tree. `tests/run.sh --wine` adds
the `test-wine-*.sh` scripts, which run the patched driver against a
replayed fixture. Each of those takes an optional fixture path.

## Fixtures

Every fixture comes from the 18 September 2026 ride, anonymised with
`tools/capture-to-fixture.py --anonymise`.

| Fixture | What it holds |
|---|---|
| `ride-2026-09-18.json` | The passive BlueZ capture of the ride, three sensors, 2 Hz heart rate |
| `hrm600-connect-abort-2026-09-18.json` | The HRM600's first connect, aborted by BlueZ after 2.4 s, then the retry |
| `hrm600-confirm-2026-09-18.json` | The ride's HRM600 with heart rate measurement behind a bond and a numeric comparison ceremony, passkey 123456. The mock's `--just-works` skips the ceremony |

## The Wine tests

Both refuse to start beside a live Rouvy and run in a throwaway prefix
with its own wineserver.

| Variable | Used by | Default |
|---|---|---|
| `WINE_BUILD` | both | `../wine-build2`, the mock test falls back to `wine` on `PATH` |
| `WINE_SRC` | `test-wine-pairing.sh` | `../wine`, for the pairing IDL |
| `ROUVY_PLUGINS` | `test-wine-mock.sh` | the directory in `~/.wine` holding `WclBlePluginCPP.dll` |
| `CLIENT` | `test-wine-mock.sh` | `wclprobe`, run as `CLIENT <address> <seconds> 1` |
