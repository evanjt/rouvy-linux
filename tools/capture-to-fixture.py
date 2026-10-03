#!/usr/bin/env python3
"""Convert a raw BlueZ capture into a replayable JSON fixture.

Input directory holds bluez-managed.json (busctl --json=short call of
GetManagedObjects) and dbus-signals.txt (dbus-monitor --system on org.bluez,
both directions), which scripts/diagnose.sh writes. Only sensors named on
the command line are kept, so neighbours' advertisements stay out of the
repository and a fixture is safe to commit while the raw capture is not.

    tools/capture-to-fixture.py --anonymise --seconds 30 --name kickr-2026-09-18.json \
        captures/diag-X C0:FF:EE:00:00:01 > tests/fixtures/kickr-2026-09-18.json

--anonymise maps the adapter to C0:FF:EE:00:00:00 and each named sensor
to :01, :02 and so on in command line order, rewrites every path and
blanks the adapter name. A Garmin sensor writes its serial after a colon
in the name, so the part after the colon becomes the fake address suffix,
HRM600:02. A Wahoo sensor ends its name with four hex digits of the
address, so that group and the vendor before it go the same way,
KICKR:01. Device Information carries the serial as well, so every value
from 2a23 to 2a29 is blanked, leaving the characteristic in place for the
replay. --seconds N keeps only the first N seconds of events, enough for
a replay test without shipping a whole ride. --name sets the source
field, which is the capture directory otherwise, a path off the machine
the fixture was made on. All are for fixtures that get committed, and
tests/test-fixtures-anonymised.sh refuses one that still carries a real
address or serial.

A fixture holds:

  adapter   the org.bluez.Adapter1 properties, including its address
  devices   each named sensor's Device1 properties and full GATT tree
            with the last read values
  events    every PropertiesChanged on those sensors, seconds since the
            first one
  connects  per sensor, each Connect the capture saw: seconds until BlueZ
            replied, its error text if it refused, seconds from the reply
            to ServicesResolved
  auth      per characteristic, hand-set: true puts it behind a bond, so
            reads, writes and StartNotify refuse with
            org.bluez.Error.NotPermitted "Not paired" until Pair is called
"""

import argparse
import json
import re
import sys
from pathlib import Path

FAKE_PREFIX = "C0:FF:EE:00:00:"

DEVICE_KEYS = ("Address", "Name", "Alias", "UUIDs", "ManufacturerData",
               "ServiceData", "RSSI", "Connected", "ServicesResolved", "Paired")
GATT_IFACES = ("org.bluez.Device1", "org.bluez.GattService1",
               "org.bluez.GattCharacteristic1", "org.bluez.GattDescriptor1")
DEVICE_INFORMATION = re.compile(r"^00002a2[3-9]-")
HEX_TAIL = re.compile(r"\s+[0-9A-Fa-f]{4,}$")


def addr_to_path(addr):
    return "/org/bluez/hci0/dev_" + addr.replace(":", "_")


def path_to_addr(path):
    return path.rsplit("dev_", 1)[1].replace("_", ":")


def under(path, roots):
    return any(path == r or path.startswith(r + "/") for r in roots)


def unwrap(v):
    """Flatten busctl --json typed values into plain Python."""
    t, d = v["type"], v["data"]
    if t == "ay":
        return bytes(d).hex()
    if t.startswith("a{") and isinstance(d, dict):
        return {k: unwrap(x) for k, x in d.items()}
    return d


def parse_objects(managed, roots):
    objects = {}
    for path, ifaces in managed["data"][0].items():
        if not under(path, roots):
            continue
        props = {}
        for iface in GATT_IFACES:
            for k, v in ifaces.get(iface, {}).items():
                props[k] = unwrap(v)
        objects[path] = props
    return objects


def children(objects, parent, kind):
    pattern = re.escape(parent) + "/" + kind + r"[0-9a-f]+"
    return [(p, o) for p, o in sorted(objects.items()) if re.fullmatch(pattern, p)]


def build_devices(objects, addrs):
    devices = {}
    for addr in addrs:
        root = addr_to_path(addr)
        dev = objects.get(root, {})
        entry = {k: dev[k] for k in DEVICE_KEYS if k in dev}
        entry["path"] = root
        entry["services"] = []
        for spath, sprops in children(objects, root, "service"):
            svc = {"path": spath, "uuid": sprops.get("UUID"), "handle": sprops.get("Handle"),
                   "primary": sprops.get("Primary"), "characteristics": []}
            for cpath, cprops in children(objects, spath, "char"):
                ch = {"path": cpath, "uuid": cprops.get("UUID"), "handle": cprops.get("Handle"),
                      "flags": cprops.get("Flags", []), "value": cprops.get("Value", ""),
                      "descriptors": [{"path": dpath, "uuid": dprops.get("UUID"),
                                       "handle": dprops.get("Handle")}
                                      for dpath, dprops in children(objects, cpath, "desc")]}
                svc["characteristics"].append(ch)
            entry["services"].append(svc)
        devices[addr] = entry
    return devices


MESSAGE = re.compile(r"^(?=(signal|method call|method return|error) )", re.M)


def parse_signals(text, roots):
    events = []
    header = re.compile(r"^signal time=([\d.]+) .* path=([^;]+); interface=[^;]+; member=(\w+)")
    t0 = None
    for block in MESSAGE.split(text):
        m = header.match(block)
        if not m or m.group(3) != "PropertiesChanged":
            continue
        t, path = float(m.group(1)), m.group(2)
        if not under(path, roots):
            continue
        body = block.splitlines()[1:]
        iface = body[0].strip().split('"')[1]
        props = parse_changed(body[1:])
        if not props:
            continue
        t0 = t if t0 is None else t0
        events.append({"t": round(t - t0, 6), "path": path, "interface": iface, "changed": props})
    return events


def parse_connects(text, roots):
    """Connect calls per device path, matched to their replies by sender and serial."""
    call = re.compile(r"^method call time=([\d.]+) sender=(\S+) -> destination=org\.bluez serial=(\d+) "
                      r"path=([^;]+); interface=org\.bluez\.Device1; member=Connect")
    reply = re.compile(r"^(method return|error) time=([\d.]+) \S+ -> destination=(\S+) (?:error_name=\S+ )?"
                       r"(?:serial=\d+ )?reply_serial=(\d+)")
    resolved = re.compile(r"^signal time=([\d.]+) .* path=([^;]+); interface=org\.freedesktop\.DBus\.Properties; "
                          r"member=PropertiesChanged\n   string \"org\.bluez\.Device1\"")
    pending, awaiting, connects = {}, {}, {}
    for block in MESSAGE.split(text):
        if m := call.match(block):
            if under(m.group(4), roots):
                pending[(m.group(2), m.group(3))] = (float(m.group(1)), m.group(4))
        elif m := reply.match(block):
            if (m.group(3), m.group(4)) not in pending:
                continue
            start, path = pending.pop((m.group(3), m.group(4)))
            step = {"after": round(float(m.group(2)) - start, 6)}
            if m.group(1) == "error":
                step["error"] = block.splitlines()[1].strip().split('"')[1]
            else:
                awaiting[path] = (step, float(m.group(2)))
            connects.setdefault(path, []).append(step)
        elif m := resolved.match(block):
            if m.group(2) in awaiting and parse_changed(block.splitlines()[2:]).get("ServicesResolved"):
                step, replied = awaiting.pop(m.group(2))
                step["resolved"] = round(float(m.group(1)) - replied, 6)
    return connects


def parse_changed(lines):
    props = {}
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if not (s.startswith('string "') and i + 1 < len(lines) and "variant" in lines[i + 1]):
            i += 1
            continue
        key = s.split('"')[1]
        val = lines[i + 1].split("variant", 1)[1].strip()
        i += 2
        if val.startswith("array of bytes"):
            props[key] = lines[i].strip().replace(" ", "")
            i += 1
        elif val.startswith("boolean"):
            props[key] = val.split()[1] == "true"
        elif re.match(r"(u?int\d+|byte) ", val):
            props[key] = int(val.split()[1])
        elif val.startswith("string") or val.startswith("object path"):
            props[key] = val.split('"')[1]
    return props


ADAPTER_KEYS = ("Address", "AddressType", "Name", "Alias", "Class", "Powered",
                "PowerState", "Discoverable", "Pairable", "Discovering", "UUIDs",
                "Roles", "Manufacturer", "Version")


def build_adapter(managed):
    hci = managed["data"][0].get("/org/bluez/hci0", {}).get("org.bluez.Adapter1", {})
    adapter = {k: unwrap(v) for k, v in hci.items() if k in ADAPTER_KEYS}
    adapter["path"] = "/org/bluez/hci0"
    return adapter


def fake_addresses(adapter, addrs):
    """Adapter takes :00, named sensors :01 upwards in command line order."""
    mapping = {adapter: FAKE_PREFIX + "00"}
    for i, addr in enumerate(addrs, 1):
        mapping[addr] = FAKE_PREFIX + f"{i:02X}"
    return mapping


def anonymise(fixture, addrs):
    mapping = fake_addresses(fixture["adapter"]["Address"], addrs)
    for real, fake in list(mapping.items()):
        mapping[real.replace(":", "_")] = fake.replace(":", "_")

    def rewrite(node):
        if isinstance(node, str):
            for real, fake in mapping.items():
                node = node.replace(real, fake)
            return node
        if isinstance(node, list):
            return [rewrite(x) for x in node]
        if isinstance(node, dict):
            return {rewrite(k): rewrite(v) for k, v in node.items()}
        return node

    fixture = rewrite(fixture)
    for key in ("Name", "Alias"):
        if key in fixture["adapter"]:
            fixture["adapter"][key] = "adapter"
    for fake, dev in fixture["devices"].items():
        for key in ("Name", "Alias"):
            name = dev.get(key, "")
            if ":" in name:
                dev[key] = name.split(":", 1)[0] + ":" + fake[-2:]
            elif HEX_TAIL.search(name):
                dev[key] = HEX_TAIL.sub("", name).split()[-1] + ":" + fake[-2:]
        blank_device_information(dev)
    return fixture


def blank_device_information(dev):
    """Model, serial, revisions and maker all identify the sensor or its owner."""
    for service in dev.get("services", []):
        for char in service.get("characteristics", []):
            if DEVICE_INFORMATION.match(char.get("uuid") or ""):
                char["value"] = ""


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", type=Path)
    ap.add_argument("address", nargs="+")
    ap.add_argument("--anonymise", action="store_true",
                    help="replace adapter and sensor addresses with stable fakes")
    ap.add_argument("--seconds", type=float,
                    help="keep only the first N seconds of events")
    ap.add_argument("--name",
                    help="source field for the fixture, its own file name")
    args = ap.parse_args()
    addrs = [a.upper() for a in args.address]
    roots = [addr_to_path(a) for a in addrs]
    managed = json.loads((args.capture / "bluez-managed.json").read_text())
    objects = parse_objects(managed, roots)
    signals = (args.capture / "dbus-signals.txt").read_text()
    events = parse_signals(signals, roots)
    if args.seconds is not None:
        events = [e for e in events if e["t"] <= args.seconds]
    devices = build_devices(objects, addrs)
    for path, steps in parse_connects(signals, roots).items():
        devices[path_to_addr(path)]["connects"] = steps
    fixture = {"source": args.name or args.capture.name, "adapter": build_adapter(managed),
               "devices": devices, "events": events}
    if args.anonymise:
        fixture = anonymise(fixture, addrs)
    json.dump(fixture, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
