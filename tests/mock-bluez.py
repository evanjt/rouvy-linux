#!/usr/bin/env python3
"""Fake org.bluez that replays a captured sensor session.

Serves the adapter, devices and GATT tree from a fixture produced by
tools/capture-to-fixture.py, and streams the recorded notifications to
whoever subscribes. The mock owns org.bluez on a private bus, so point
DBUS_SYSTEM_BUS_ADDRESS at that bus before the first Wine process and the
driver in the service host talks to the mock instead of BlueZ.

    dbus-run-session -- sh -c 'DBUS_SYSTEM_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS tests/mock-bluez.py --once tests/fixtures/ride-2026-09-18.json'

Connect follows the sensor's `connects` script, failing or delaying as
BlueZ did, and succeeds at once after it. The GATT tree appears on
ServicesResolved, ReadValue returns the captured value and StartNotify
streams the recorded changes at the recorded pace (--speed changes it).
--no-handles drops the Handle property the way BlueZ before 5.69 does, so
the driver's path fallback gets used. Method calls go to stderr one per
line, so a test asserts on what the driver did without a sensor in the
room.

A characteristic with `auth` true is behind a bond: ReadValue, WriteValue
and StartNotify refuse with org.bluez.Error.NotPermitted "Not paired",
BlueZ's rendering of ATT Insufficient Authentication, until the device is
paired. Pair sets Paired and the same calls then succeed. A device with a
`pairing` entry runs that ceremony first, as BlueZ would through the
registered agent: `method` is `confirm`, `passkey` or `display` and
`passkey` the six digit value. Pair then only sets Paired when the agent
agrees, and RemoveDevice drops the bond again. --just-works ignores the
`pairing` entries, so Pair bonds at once without asking the agent.

The committed fixtures, all from the 18 September 2026 ride:

  ride-2026-09-18.json
      KICKR :01, HRM600 :02, Rally :03, first 30 s of a 60 s capture,
      real heart rate and power.
  hrm600-connect-abort-2026-09-18.json
      The HRM600 with the connect script from the Wine log: BlueZ aborted
      the first Connect after 2.4 s, the retry took 2.2 s, services
      resolved 2.9 s later.
  hrm600-confirm-2026-09-18.json
      The HRM600 with heart rate measurement marked auth and a confirm
      pairing script, passkey 123456, so Pair goes through the agent. No
      Rouvy sensor needs a bond, so it is hand-made from the ride.
      Replayed through the driver and tools/pairprobe.c by
      tests/test-wine-pairing.sh.
"""

import argparse
import json
import os
import sys

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

BLUEZ = "org.bluez"
OM = "org.freedesktop.DBus.ObjectManager"
PROPS = "org.freedesktop.DBus.Properties"
ADAPTER = "org.bluez.Adapter1"
DEVICE = "org.bluez.Device1"
SERVICE = "org.bluez.GattService1"
CHAR = "org.bluez.GattCharacteristic1"
DESC = "org.bluez.GattDescriptor1"
AGENT_MANAGER = "org.bluez.AgentManager1"
AGENT = "org.bluez.Agent1"

SIGNATURES = {
    "Address": "s", "AddressType": "s", "Name": "s", "Alias": "s", "Class": "u",
    "Powered": "b", "PowerState": "s", "Discoverable": "b", "Pairable": "b",
    "Discovering": "b", "UUIDs": "as", "Roles": "as", "Manufacturer": "q", "Version": "y",
    "ManufacturerData": "a{qv}", "ServiceData": "a{sv}", "RSSI": "n", "Connected": "b",
    "ServicesResolved": "b", "Paired": "b", "Adapter": "o", "Trusted": "b", "Blocked": "b",
    "LegacyPairing": "b", "Bonded": "b",
    "UUID": "s", "Handle": "q", "Primary": "b", "Device": "o", "Service": "o",
    "Characteristic": "o", "Flags": "as", "Value": "ay", "Notifying": "b", "MTU": "q",
}


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def typed(name, value):
    sig = SIGNATURES[name]
    if sig == "ay":
        return dbus.ByteArray(bytes.fromhex(value or ""), variant_level=1)
    if sig == "a{qv}":
        return dbus.Dictionary({dbus.UInt16(int(k)): dbus.ByteArray(bytes.fromhex(v), variant_level=1)
                                for k, v in value.items()}, signature="qv", variant_level=1)
    if sig == "a{sv}":
        return dbus.Dictionary({k: dbus.ByteArray(bytes.fromhex(v), variant_level=1)
                                for k, v in value.items()}, signature="sv", variant_level=1)
    if sig == "as":
        return dbus.Array(value, signature="s", variant_level=1)
    ctor = {"s": dbus.String, "o": dbus.ObjectPath, "b": dbus.Boolean, "u": dbus.UInt32,
            "q": dbus.UInt16, "y": dbus.Byte, "n": dbus.Int16}[sig]
    return ctor(value, variant_level=1)


class Node(dbus.service.Object):
    """One BlueZ object exposing a single interface plus Properties."""

    iface = None

    def __init__(self, bus, path, props):
        super().__init__(bus, path)
        self.path = path
        self.props = dict(props)

    def get_all(self):
        return dbus.Dictionary({k: typed(k, v) for k, v in self.props.items() if v is not None},
                               signature="sv")

    def set_prop(self, name, value):
        self.props[name] = value
        self.PropertiesChanged(self.iface, dbus.Dictionary({name: typed(name, value)}, signature="sv"),
                               dbus.Array([], signature="s"))

    @dbus.service.method(PROPS, in_signature="ss", out_signature="v")
    def Get(self, iface, name):
        return typed(name, self.props[name])

    @dbus.service.method(PROPS, in_signature="s", out_signature="a{sv}")
    def GetAll(self, iface):
        return self.get_all()

    @dbus.service.method(PROPS, in_signature="ssv")
    def Set(self, iface, name, value):
        log(f"Set {self.path} {name}={value}")
        self.props[name] = value

    @dbus.service.signal(PROPS, signature="sa{sv}as")
    def PropertiesChanged(self, iface, changed, invalidated):
        pass


class Root(dbus.service.Object):
    def __init__(self, bus, world):
        super().__init__(bus, "/")
        self.world = world

    @dbus.service.method(OM, out_signature="a{oa{sa{sv}}}")
    def GetManagedObjects(self):
        log("GetManagedObjects")
        return self.world.managed()

    @dbus.service.signal(OM, signature="oa{sa{sv}}")
    def InterfacesAdded(self, path, ifaces):
        pass

    @dbus.service.signal(OM, signature="oas")
    def InterfacesRemoved(self, path, ifaces):
        pass


class AgentManager(dbus.service.Object):
    def __init__(self, bus):
        super().__init__(bus, "/org/bluez")
        self.agent = None

    @dbus.service.method(AGENT_MANAGER, in_signature="os", sender_keyword="sender")
    def RegisterAgent(self, path, capability, sender=None):
        log(f"RegisterAgent {path} {capability}")
        self.agent = (sender, path)

    @dbus.service.method(AGENT_MANAGER, in_signature="o")
    def UnregisterAgent(self, path):
        log(f"UnregisterAgent {path}")
        self.agent = None

    @dbus.service.method(AGENT_MANAGER, in_signature="o")
    def RequestDefaultAgent(self, path):
        log(f"RequestDefaultAgent {path}")


class Adapter(Node):
    iface = ADAPTER

    def __init__(self, bus, props, world):
        super().__init__(bus, props["path"], {k: v for k, v in props.items() if k != "path"})
        self.props["Discovering"] = False
        self.world = world

    @dbus.service.method(ADAPTER, in_signature="a{sv}")
    def SetDiscoveryFilter(self, filt):
        log(f"SetDiscoveryFilter {dict(filt)}")

    @dbus.service.method(ADAPTER)
    def StartDiscovery(self):
        log("StartDiscovery")
        self.set_prop("Discovering", True)

    @dbus.service.method(ADAPTER)
    def StopDiscovery(self):
        log("StopDiscovery")
        self.set_prop("Discovering", False)

    @dbus.service.method(ADAPTER, in_signature="o")
    def RemoveDevice(self, path):
        log(f"RemoveDevice {path}")
        device = self.world.nodes.get(path)
        if device is not None:
            device.set_prop("Paired", False)
            device.set_prop("Bonded", False)


class Device(Node):
    iface = DEVICE

    def __init__(self, bus, entry, world):
        props = {k: v for k, v in entry.items() if k not in ("path", "services", "connects", "pairing")}
        props.update({"Connected": False, "ServicesResolved": False, "Paired": False, "Bonded": False,
                      "Adapter": world.adapter.path})
        super().__init__(bus, entry["path"], props)
        self.world = world
        self.services = entry["services"]
        self.connects = list(entry.get("connects", []))
        self.pairing = entry.get("pairing")
        self.gatt = []

    @dbus.service.method(DEVICE, async_callbacks=("reply", "error"))
    def Connect(self, reply, error):
        log(f"Connect {self.path}")
        if self.props["Connected"]:
            reply()
            return
        step = self.connects.pop(0) if self.connects else {}
        GLib.timeout_add(self.world.ms(step.get("after", 0)), self.connect_reply, step, reply, error)

    def connect_reply(self, step, reply, error):
        if "error" in step:
            log(f"Connect {self.path} failed {step['error']}")
            error(dbus.exceptions.DBusException(step["error"], name="org.bluez.Error.Failed"))
            return False
        self.set_prop("Connected", True)
        reply()
        GLib.timeout_add(self.world.ms(step.get("resolved", 0.2)), self.resolve)
        return False

    def resolve(self):
        for svc in self.services:
            self.gatt.append(self.world.add(Service(self.world.bus, svc, self.path)))
            for ch in svc["characteristics"]:
                self.gatt.append(self.world.add(Characteristic(self.world.bus, ch, svc["path"], self)))
                for d in ch["descriptors"]:
                    self.gatt.append(self.world.add(Descriptor(self.world.bus, d, ch["path"])))
        self.set_prop("ServicesResolved", True)
        return False

    @dbus.service.method(DEVICE)
    def Disconnect(self):
        log(f"Disconnect {self.path}")
        for node in reversed(self.gatt):
            self.world.remove(node)
        self.gatt = []
        self.set_prop("ServicesResolved", False)
        self.set_prop("Connected", False)

    @dbus.service.method(DEVICE, async_callbacks=("reply", "error"))
    def Pair(self, reply, error):
        log(f"Pair {self.path}")
        if self.props["Paired"]:
            error(dbus.exceptions.DBusException("Already Paired", name="org.bluez.Error.AlreadyExists"))
            return
        if not self.pairing:
            self.paired(reply)
            return
        agent = self.world.agents.agent
        if agent is None:
            error(dbus.exceptions.DBusException("No agent", name="org.bluez.Error.AuthenticationFailed"))
            return
        method = self.pairing["method"]
        passkey = dbus.UInt32(self.pairing.get("passkey", 0))
        name, signature, args = {
            "confirm": ("RequestConfirmation", "ou", (self.path, passkey)),
            "passkey": ("RequestPasskey", "o", (self.path,)),
            "display": ("DisplayPasskey", "ouq", (self.path, passkey, dbus.UInt16(0))),
        }[method]
        log(f"{name} {self.path}")
        self.world.bus.call_async(agent[0], agent[1], AGENT, name, signature, args,
                                  lambda *answer: self.agent_replied(method, answer, reply, error),
                                  lambda e: self.agent_refused(e, error))

    def agent_replied(self, method, answer, reply, error):
        if method == "passkey" and int(answer[0]) != self.pairing.get("passkey", 0):
            log(f"Pair {self.path} failed wrong passkey {int(answer[0])}")
            error(dbus.exceptions.DBusException("Authentication Failed", name="org.bluez.Error.AuthenticationFailed"))
            return
        self.paired(reply)

    def agent_refused(self, e, error):
        log(f"Pair {self.path} failed agent {e.get_dbus_name()}")
        error(dbus.exceptions.DBusException("Authentication Rejected", name="org.bluez.Error.AuthenticationRejected"))

    def paired(self, reply):
        self.set_prop("Paired", True)
        self.set_prop("Bonded", True)
        reply()

    @dbus.service.method(DEVICE)
    def CancelPairing(self):
        log(f"CancelPairing {self.path}")


class Service(Node):
    iface = SERVICE

    def __init__(self, bus, svc, device):
        super().__init__(bus, svc["path"], {"UUID": svc["uuid"], "Handle": svc["handle"],
                                            "Primary": svc["primary"], "Device": device})


class Characteristic(Node):
    iface = CHAR

    def __init__(self, bus, ch, service, device):
        super().__init__(bus, ch["path"], {"UUID": ch["uuid"], "Handle": ch["handle"], "Flags": ch["flags"],
                                           "Value": ch["value"], "Notifying": False, "Service": service})
        self.device = device
        self.world = device.world
        self.auth = ch.get("auth", False)

    def guard(self, what):
        if self.auth and not self.device.props["Paired"]:
            log(f"{what} {self.path} refused, not paired")
            raise dbus.exceptions.DBusException("Not paired", name="org.bluez.Error.NotPermitted")

    @dbus.service.method(CHAR, in_signature="a{sv}", out_signature="ay")
    def ReadValue(self, options):
        log(f"ReadValue {self.path}")
        self.guard("ReadValue")
        return dbus.ByteArray(bytes.fromhex(self.props["Value"] or ""))

    @dbus.service.method(CHAR, in_signature="aya{sv}")
    def WriteValue(self, value, options):
        log(f"WriteValue {self.path} {bytes(value).hex()}")
        self.guard("WriteValue")
        self.props["Value"] = bytes(value).hex()

    @dbus.service.method(CHAR)
    def StartNotify(self):
        log(f"StartNotify {self.path}")
        self.guard("StartNotify")
        self.set_prop("Notifying", True)
        self.world.subscribed(self.path)

    @dbus.service.method(CHAR)
    def StopNotify(self):
        log(f"StopNotify {self.path}")
        self.set_prop("Notifying", False)


class Descriptor(Node):
    iface = DESC

    def __init__(self, bus, d, characteristic):
        super().__init__(bus, d["path"], {"UUID": d["uuid"], "Handle": d["handle"],
                                          "Characteristic": characteristic})


class World:
    """Owns every object and drives the replay."""

    def __init__(self, bus, fixture, speed, loop):
        self.bus = bus
        self.nodes = {}
        self.root = Root(bus, self)
        self.agents = AgentManager(bus)
        self.adapter = self.add(Adapter(bus, fixture["adapter"], self))
        for entry in fixture["devices"].values():
            self.add(Device(bus, entry, self))
        self.events = fixture["events"]
        self.speed = speed
        self.loop = loop
        self.started = False

    def add(self, node):
        self.nodes[node.path] = node
        self.root.InterfacesAdded(node.path, dbus.Dictionary({node.iface: node.get_all()}, signature="sa{sv}"))
        return node

    def remove(self, node):
        del self.nodes[node.path]
        node.remove_from_connection()
        self.root.InterfacesRemoved(node.path, dbus.Array([node.iface], signature="s"))

    def managed(self):
        return dbus.Dictionary({dbus.ObjectPath(p): dbus.Dictionary({n.iface: n.get_all()}, signature="sa{sv}")
                                for p, n in self.nodes.items()}, signature="oa{sa{sv}}")

    def ms(self, seconds):
        return int(seconds / self.speed * 1000)

    def subscribed(self, path):
        if not self.started and self.events:
            self.started = True
            self.schedule(0)

    def schedule(self, index):
        if index >= len(self.events):
            if not self.loop:
                log("replay finished")
                return
            index = 0
        ev = self.events[index]
        prev = self.events[index - 1]["t"] if index else 0
        GLib.timeout_add(self.ms(max(0, ev["t"] - prev)), self.fire, index)

    def fire(self, index):
        ev = self.events[index]
        node = self.nodes.get(ev["path"])
        if node is not None:
            if ev["interface"] == DEVICE and not self.adapter.props["Discovering"]:
                pass
            elif ev["interface"] == CHAR and not node.props.get("Notifying"):
                pass
            else:
                for k, v in ev["changed"].items():
                    node.set_prop(k, v)
        self.schedule(index + 1)
        return False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("fixture")
    ap.add_argument("--speed", type=float, default=1.0, help="replay rate multiplier")
    ap.add_argument("--once", action="store_true", help="stop after one pass instead of looping")
    ap.add_argument("--no-handles", action="store_true", help="omit the Handle property, like BlueZ before 5.69")
    ap.add_argument("--just-works", action="store_true", help="ignore pairing entries, Pair bonds without the agent")
    args = ap.parse_args()

    DBusGMainLoop(set_as_default=True)
    address = os.environ.get("DBUS_SYSTEM_BUS_ADDRESS")
    if not address:
        sys.exit("refusing to run on the real system bus, set DBUS_SYSTEM_BUS_ADDRESS to a private bus")
    bus = dbus.bus.BusConnection(address)
    name = dbus.service.BusName(BLUEZ, bus, do_not_queue=True)

    with open(args.fixture) as f:
        fixture = json.load(f)
    if args.no_handles:
        for dev in fixture["devices"].values():
            for svc in dev["services"]:
                svc["handle"] = None
                for ch in svc["characteristics"]:
                    ch["handle"] = None
                    for d in ch["descriptors"]:
                        d["handle"] = None
    if args.just_works:
        for dev in fixture["devices"].values():
            dev.pop("pairing", None)
    world = World(bus, fixture, args.speed, not args.once)
    log(f"mock bluez ready on {address}, {len(world.nodes)} objects, {len(world.events)} events")
    GLib.MainLoop().run()
    del name


if __name__ == "__main__":
    main()
