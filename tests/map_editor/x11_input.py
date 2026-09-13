"""Small ctypes XTest client. Every injected press is guarded by owned PID/focus.

Only our Godot window is raised/focused. An override-redirect test-owned focus
sink exercises OS focus loss; no desktop preferences or other windows are edited.
"""
import ctypes as C
import json
import shutil
import subprocess
import time

from run_tests import GateFailure


class XTest:
    def __init__(self):
        self.x = C.CDLL("libX11.so.6")
        self.xt = C.CDLL("libXtst.so.6")
        ptr, ulong, integer = C.c_void_p, C.c_ulong, C.c_int
        self.bind(self.x, "XOpenDisplay", ptr, [C.c_char_p])
        self.bind(self.x, "XDefaultRootWindow", ulong, [ptr])
        self.bind(self.x, "XInternAtom", ulong, [ptr, C.c_char_p, integer])
        self.bind(self.x, "XGetWindowProperty", integer, [ptr, ulong, ulong, C.c_long, C.c_long, integer, ulong, C.POINTER(ulong), C.POINTER(integer), C.POINTER(ulong), C.POINTER(ulong), C.POINTER(ptr)])
        self.bind(self.x, "XQueryTree", integer, [ptr, ulong, C.POINTER(ulong), C.POINTER(ulong), C.POINTER(C.POINTER(ulong)), C.POINTER(C.c_uint)])
        self.bind(self.x, "XFree", integer, [ptr])
        self.bind(self.x, "XGetInputFocus", integer, [ptr, C.POINTER(ulong), C.POINTER(integer)])
        self.bind(self.x, "XSetInputFocus", integer, [ptr, ulong, integer, ulong])
        self.bind(self.x, "XRaiseWindow", integer, [ptr, ulong])
        self.bind(self.x, "XSync", integer, [ptr, integer])
        self.bind(self.x, "XStringToKeysym", ulong, [C.c_char_p])
        self.bind(self.x, "XKeysymToKeycode", C.c_ubyte, [ptr, ulong])
        self.bind(self.x, "XQueryPointer", integer, [ptr, ulong, C.POINTER(ulong), C.POINTER(ulong), C.POINTER(integer), C.POINTER(integer), C.POINTER(integer), C.POINTER(integer), C.POINTER(C.c_uint)])
        self.bind(self.x, "XTranslateCoordinates", integer, [ptr, ulong, ulong, integer, integer, C.POINTER(integer), C.POINTER(integer), C.POINTER(ulong)])
        self.bind(self.x, "XCreateSimpleWindow", ulong, [ptr, ulong, integer, integer, C.c_uint, C.c_uint, C.c_uint, ulong, ulong])
        self.bind(self.x, "XChangeWindowAttributes", integer, [ptr, ulong, ulong, ptr])
        self.bind(self.x, "XMapWindow", integer, [ptr, ulong])
        self.bind(self.x, "XDestroyWindow", integer, [ptr, ulong])
        self.bind(self.x, "XCloseDisplay", integer, [ptr])
        self.bind(self.xt, "XTestQueryExtension", integer, [ptr] + [C.POINTER(integer)] * 4)
        self.bind(self.xt, "XTestFakeKeyEvent", integer, [ptr, C.c_uint, integer, ulong])
        self.bind(self.xt, "XTestFakeButtonEvent", integer, [ptr, C.c_uint, integer, ulong])
        self.bind(self.xt, "XTestFakeMotionEvent", integer, [ptr, integer, integer, integer, ulong])
        self.d = self.x.XOpenDisplay(None)
        if not self.d:
            raise GateFailure("XOpenDisplay failed; DISPLAY/Xauthority unavailable")
        values = [integer() for _ in range(4)]
        if not self.xt.XTestQueryExtension(self.d, *(C.byref(v) for v in values)):
            raise GateFailure("Live X server does not support XTEST")
        self.version = [values[2].value, values[3].value]
        self.root = self.x.XDefaultRootWindow(self.d)
        self.original_focus = self.focus()
        self.original_pointer = self.pointer(self.root)[1:3]
        self.pid = None
        self.window = None
        self.sink = None
        self.keys = set()
        self.buttons = set()
        self.events = []
        self.desktop = None
        if shutil.which("hyprctl"):
            active = subprocess.run(["hyprctl", "-j", "activewindow"], capture_output=True, text=True)
            cursor = subprocess.run(["hyprctl", "-j", "cursorpos"], capture_output=True, text=True)
            if active.returncode == cursor.returncode == 0:
                self.desktop = {"active": json.loads(active.stdout), "cursor": json.loads(cursor.stdout)}

    @staticmethod
    def bind(lib, name, result, args):
        fn = getattr(lib, name)
        fn.restype, fn.argtypes = result, args

    def property(self, window, name):
        atom = self.x.XInternAtom(self.d, name.encode(), 0)
        kind, count, remain = C.c_ulong(), C.c_ulong(), C.c_ulong()
        fmt, data = C.c_int(), C.c_void_p()
        code = self.x.XGetWindowProperty(self.d, window, atom, 0, 1024, 0, 0, C.byref(kind), C.byref(fmt), C.byref(count), C.byref(remain), C.byref(data))
        if code or not data.value:
            return None
        try:
            if fmt.value == 32:
                return list(C.cast(data, C.POINTER(C.c_ulong))[:count.value])
            return C.string_at(data, count.value).decode(errors="replace")
        finally:
            self.x.XFree(data)

    def children(self, window):
        root, parent, count = C.c_ulong(), C.c_ulong(), C.c_uint()
        data = C.POINTER(C.c_ulong)()
        self.x.XQueryTree(self.d, window, C.byref(root), C.byref(parent), C.byref(data), C.byref(count))
        result = list(data[:count.value]) if data else []
        if data:
            self.x.XFree(data)
        return result

    def owned(self, window):
        # Godot focuses an InputOnly XIM child for real LineEdit text input.
        # Walk ancestry, never accept a different client's PID or a bare XID prefix.
        while window not in (0, 1, self.root):
            pid = self.property(window, "_NET_WM_PID")
            if pid:
                return pid == [self.pid]
            root, parent, count = C.c_ulong(), C.c_ulong(), C.c_uint()
            data = C.POINTER(C.c_ulong)()
            self.x.XQueryTree(self.d, window, C.byref(root), C.byref(parent), C.byref(data), C.byref(count))
            if data:
                self.x.XFree(data)
            window = parent.value
        return False

    def locate(self, pid):
        self.pid = pid
        pending = self.children(self.root)
        while pending:
            window = pending.pop()
            if self.owned(window):
                self.window = window
                return window
            pending.extend(self.children(window))
        raise GateFailure(f"No X11 window with staged editor PID {pid}")

    def focus(self):
        window, revert = C.c_ulong(), C.c_int()
        self.x.XGetInputFocus(self.d, C.byref(window), C.byref(revert))
        return window.value

    def activate(self):
        if not self.owned(self.window):
            raise GateFailure("Staged window PID identity changed")
        self.x.XRaiseWindow(self.d, self.window)
        self.x.XSetInputFocus(self.d, self.window, 2, 0)
        self.sync()
        time.sleep(0.15)
        self.guard()

    def origin(self):
        x, y, child = C.c_int(), C.c_int(), C.c_ulong()
        self.x.XTranslateCoordinates(self.d, self.window, self.root, 0, 0, C.byref(x), C.byref(y), C.byref(child))
        return [x.value, y.value]

    def guard(self):
        if not self.owned(self.focus()):
            raise GateFailure(f"Refusing input: focus {self.focus():x} is not staged PID {self.pid}")

    def sync(self):
        self.x.XSync(self.d, 0)

    def pointer(self, window):
        root, child = C.c_ulong(), C.c_ulong()
        rx, ry, wx, wy, mask = C.c_int(), C.c_int(), C.c_int(), C.c_int(), C.c_uint()
        self.x.XQueryPointer(self.d, window, C.byref(root), C.byref(child), C.byref(rx), C.byref(ry), C.byref(wx), C.byref(wy), C.byref(mask))
        return child.value, rx.value, ry.value, mask.value

    def log(self, kind, **values):
        self.events.append({"monotonic_ns": time.monotonic_ns(), "kind": kind, **values})

    def move(self, point):
        self.guard()
        x, y = (round(v) for v in point)
        self.log("motion", x=x, y=y)
        self.xt.XTestFakeMotionEvent(self.d, -1, x, y, 0)
        self.sync()
        self.log("pointer_after_motion", pointer=self.pointer(self.root), focus=self.focus(), window=self.window)

    def button(self, button, down, captured=False):
        self.guard()
        if down and not captured:
            child = self.pointer(self.root)[0]
            while child and not self.owned(child):
                child = self.pointer(child)[0]
            if not child:
                raise GateFailure(f"Refusing button: pointer is outside staged editor; root pointer={self.pointer(self.root)}, window={self.window}")
        self.log("button", button=button, down=down)
        self.xt.XTestFakeButtonEvent(self.d, button, down, 0)
        (self.buttons.add if down else self.buttons.discard)(button)
        self.sync()

    def key(self, name, down):
        self.guard()
        code = self.x.XKeysymToKeycode(self.d, self.x.XStringToKeysym(name.encode()))
        if not code:
            raise GateFailure(f"No X keycode for {name}")
        self.log("key", key=name, code=code, down=down)
        self.xt.XTestFakeKeyEvent(self.d, code, down, 0)
        (self.keys.add if down else self.keys.discard)(code)
        self.sync()

    def chord(self, key, *modifiers):
        for modifier in modifiers:
            self.key(modifier, True)
        self.key(key, True)
        time.sleep(0.025)
        self.key(key, False)
        for modifier in reversed(modifiers):
            self.key(modifier, False)

    def type(self, text):
        symbols = {" ": "space", "/": "slash", ".": "period", "_": "underscore", "-": "minus", ":": "colon"}
        for char in text:
            if char.isupper() or char in "_:":
                self.chord({"_": "minus", ":": "semicolon"}.get(char, char.lower()), "Shift_L")
            else:
                self.chord(symbols.get(char, char))

    def lose_focus(self):
        # Override redirect avoids tiling/rearranging any existing desktop windows.
        if not self.sink:
            self.sink = self.x.XCreateSimpleWindow(self.d, self.root, 0, 0, 1, 1, 0, 0, 0)
            class Attributes(C.Structure):
                _fields_ = [("background_pixmap", C.c_ulong), ("background_pixel", C.c_ulong), ("border_pixmap", C.c_ulong), ("border_pixel", C.c_ulong), ("bit_gravity", C.c_int), ("win_gravity", C.c_int), ("backing_store", C.c_int), ("backing_planes", C.c_ulong), ("backing_pixel", C.c_ulong), ("save_under", C.c_int), ("event_mask", C.c_long), ("do_not_propagate_mask", C.c_long), ("override_redirect", C.c_int), ("colormap", C.c_ulong), ("cursor", C.c_ulong)]
            attrs = Attributes()
            attrs.override_redirect = 1
            self.x.XChangeWindowAttributes(self.d, self.sink, 1 << 9, C.byref(attrs))
            self.x.XMapWindow(self.d, self.sink)
        self.x.XSetInputFocus(self.d, self.sink, 2, 0)
        self.sync()
        self.log("focus_sink", window=self.sink)
        if self.focus() != self.sink:
            raise GateFailure("X focus sink did not acquire focus")

    def release_owned(self):
        # On focus loss the only permissible release target is our own sink.
        if self.focus() != self.sink and not self.owned(self.focus()):
            self.lose_focus()
        for code in self.keys:
            self.xt.XTestFakeKeyEvent(self.d, code, False, 0)
        for button in self.buttons:
            self.xt.XTestFakeButtonEvent(self.d, button, False, 0)
        self.keys.clear()
        self.buttons.clear()
        self.sync()

    def close(self):
        if self.keys or self.buttons:
            self.release_owned()
        self.xt.XTestFakeMotionEvent(self.d, -1, *self.original_pointer, 0)
        existing = set()
        pending = self.children(self.root)
        while pending:
            window = pending.pop()
            existing.add(window)
            pending.extend(self.children(window))
        if self.original_focus in (0, 1, self.root) or self.original_focus in existing:
            self.x.XSetInputFocus(self.d, self.original_focus, 2, 0)
        if self.sink:
            self.x.XDestroyWindow(self.d, self.sink)
        self.sync()
        self.x.XCloseDisplay(self.d)
        if self.desktop:
            # XGetInputFocus cannot identify a previously active native Wayland
            # window. Restore that exact compositor address (no config changes).
            active = self.desktop["active"]
            clients = subprocess.run(["hyprctl", "-j", "clients"], capture_output=True, text=True, check=True)
            if any(c["address"] == active.get("address") and c["pid"] == active.get("pid") for c in json.loads(clients.stdout)):
                subprocess.run(["hyprctl", "dispatch", "focuswindow", "address:" + active["address"]], capture_output=True, check=True)
            cursor = self.desktop["cursor"]
            subprocess.run(["hyprctl", "dispatch", "movecursor", str(cursor["x"]), str(cursor["y"])], capture_output=True, check=True)
            current = json.loads(subprocess.check_output(["hyprctl", "-j", "activewindow"], text=True))
            self.log("desktop_restored", expected=active.get("address"), actual=current.get("address"), cursor=cursor)
            if current.get("address") != active.get("address") and active.get("mapped"):
                raise OSError("Compositor focus restoration did not match original window")
