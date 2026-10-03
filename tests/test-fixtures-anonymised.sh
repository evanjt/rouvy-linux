#!/usr/bin/env bash
# Every committed fixture carries C0:FF:EE:00:00:xx addresses and a blank
# adapter name, with no serial in a Name, an Alias or Device Information.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
if [ $# -eq 0 ]; then
    set -- "$ROOT"/tests/fixtures/*.json
fi
exec python3 - "$@" <<'PY'
import json
import re
import sys

FAKE = re.compile(r"C0[:_]FF[:_]EE[:_]00[:_]00[:_][0-9A-F]{2}")
ADDRESS = re.compile(r"(?<![0-9A-Fa-f])([0-9A-Fa-f]{2}[:_]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f])")
SERIAL = re.compile(r":[0-9]{5,}$")
HEX_TAIL = re.compile(r"\s[0-9A-Fa-f]{4,}$")
DEVICE_INFORMATION = re.compile(r"^00002a2[3-9]-")

failed = False
for path in sys.argv[1:]:
    text = open(path).read()
    fixture = json.loads(text)
    real = sorted({m.group(0) for m in ADDRESS.finditer(text) if not FAKE.fullmatch(m.group(0))})
    problems = [f"real address {a}" for a in real]
    if fixture["adapter"].get("Name") != "adapter":
        problems.append(f"adapter Name is {fixture['adapter'].get('Name')!r}")
    if fixture["adapter"].get("Alias") != "adapter":
        problems.append(f"adapter Alias is {fixture['adapter'].get('Alias')!r}")
    for addr, dev in fixture.get("devices", {}).items():
        for key in ("Name", "Alias"):
            if SERIAL.search(dev.get(key, "")):
                problems.append(f"device {addr} {key} carries a serial: {dev[key]!r}")
            if HEX_TAIL.search(dev.get(key, "")):
                problems.append(f"device {addr} {key} carries an address tail: {dev[key]!r}")
        for service in dev.get("services", []):
            for char in service.get("characteristics", []):
                if DEVICE_INFORMATION.match(char.get("uuid") or "") and char.get("value"):
                    value = bytes.fromhex(char["value"]).decode("utf-8", "replace")
                    problems.append(f"device {addr} {char['uuid']} reads {value!r}")
    for problem in problems:
        print(f"{path}: {problem}")
    failed = failed or bool(problems)
sys.exit(1 if failed else 0)
PY
