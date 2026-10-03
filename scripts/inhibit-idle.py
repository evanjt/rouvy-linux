#!/usr/bin/env python3
"""Run a command while holding a desktop idle inhibit.

Uses the org.freedesktop.ScreenSaver D-Bus interface, which KDE, GNOME,
XFCE, Cinnamon, MATE and LXQt all implement, and falls back to the
xdg-desktop-portal Inhibit call. The inhibit lives as long as this
process's bus connection, so the command runs as a child.
"""
import subprocess
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

APP = "rouvy"
REASON = "Rouvy ride in progress"


def inhibit(bus):
    try:
        bus.call_sync(
            "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver",
            "org.freedesktop.ScreenSaver", "Inhibit",
            GLib.Variant("(ss)", (APP, REASON)), None,
            Gio.DBusCallFlags.NONE, 5000, None)
        return "org.freedesktop.ScreenSaver"
    except GLib.Error:
        pass
    try:
        # Flags: 4 = idle (screen blank), 1 = logout, 2 = user switch.
        bus.call_sync(
            "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.Inhibit", "Inhibit",
            GLib.Variant("(sua{sv})", ("", 4, {"reason": GLib.Variant("s", REASON)})),
            None, Gio.DBusCallFlags.NONE, 5000, None)
        return "org.freedesktop.portal.Inhibit"
    except GLib.Error:
        return None


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: inhibit-idle.py command [args...]")
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        backend = inhibit(bus)
    except GLib.Error:
        backend = None
    if backend is None:
        print("inhibit-idle: no idle inhibitor available, running anyway", file=sys.stderr)
    return subprocess.call(sys.argv[1:])


if __name__ == "__main__":
    sys.exit(main())
