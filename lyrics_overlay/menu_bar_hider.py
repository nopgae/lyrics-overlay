"""
MenuBarHider — hides/restores status-bar items via the Accessibility API.
Requires: System Settings → Privacy & Security → Accessibility → [app] ON

Uses ctypes to call HIServices C functions directly (no pyobjc-framework-ApplicationServices needed).
"""

import ctypes

from AppKit import NSWorkspace

# ---------------------------------------------------------------------------
# Load frameworks
# ---------------------------------------------------------------------------
_HI = ctypes.cdll.LoadLibrary(
    "/System/Library/Frameworks/ApplicationServices.framework/"
    "Frameworks/HIServices.framework/HIServices"
)
_CF = ctypes.cdll.LoadLibrary(
    "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
)

# ---------------------------------------------------------------------------
# Types / constants
# ---------------------------------------------------------------------------
_Ref = ctypes.c_void_p
_kAXErrorSuccess = 0
_kCFStringEncodingUTF8 = 0x08000100

# ---------------------------------------------------------------------------
# Function signatures
# ---------------------------------------------------------------------------
_HI.AXIsProcessTrusted.restype = ctypes.c_bool
_HI.AXIsProcessTrusted.argtypes = []

_HI.AXIsProcessTrustedWithOptions.restype = ctypes.c_bool
_HI.AXIsProcessTrustedWithOptions.argtypes = [_Ref]  # CFDictionaryRef

_HI.AXUIElementCreateApplication.restype = _Ref
_HI.AXUIElementCreateApplication.argtypes = [ctypes.c_int32]

_HI.AXUIElementCopyAttributeValue.restype = ctypes.c_int32
_HI.AXUIElementCopyAttributeValue.argtypes = [_Ref, _Ref, ctypes.POINTER(_Ref)]

_HI.AXUIElementSetAttributeValue.restype = ctypes.c_int32
_HI.AXUIElementSetAttributeValue.argtypes = [_Ref, _Ref, _Ref]

_CF.CFStringCreateWithCString.restype = _Ref
_CF.CFStringCreateWithCString.argtypes = [_Ref, ctypes.c_char_p, ctypes.c_uint32]

_CF.CFStringGetCString.restype = ctypes.c_bool
_CF.CFStringGetCString.argtypes = [_Ref, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]

_CF.CFArrayGetCount.restype = ctypes.c_long
_CF.CFArrayGetCount.argtypes = [_Ref]

_CF.CFArrayGetValueAtIndex.restype = _Ref
_CF.CFArrayGetValueAtIndex.argtypes = [_Ref, ctypes.c_long]

_CF.CFRetain.restype = _Ref
_CF.CFRetain.argtypes = [_Ref]

_CF.CFRelease.restype = None
_CF.CFRelease.argtypes = [_Ref]

_CF.CFDictionaryCreateMutable.restype = _Ref
_CF.CFDictionaryCreateMutable.argtypes = [_Ref, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]

_CF.CFDictionarySetValue.restype = None
_CF.CFDictionarySetValue.argtypes = [_Ref, _Ref, _Ref]

# Addresses of CFDictionary callback structs (needed as pointers to CFDictionaryCreate/Mutable)
_kCFTypeDictKeyCBs   = ctypes.addressof(ctypes.c_char.in_dll(_CF, "kCFTypeDictionaryKeyCallBacks"))
_kCFTypeDictValCBs   = ctypes.addressof(ctypes.c_char.in_dll(_CF, "kCFTypeDictionaryValueCallBacks"))

# kCFBooleanTrue / kCFBooleanFalse are CFBooleanRef globals (pointer-sized values)
_kCFBooleanTrue  = ctypes.c_void_p.in_dll(_CF, "kCFBooleanTrue").value
_kCFBooleanFalse = ctypes.c_void_p.in_dll(_CF, "kCFBooleanFalse").value

# Pre-interned attribute name CFStrings (never released — live for the process lifetime)
_ATTR_MENUBAR    = _CF.CFStringCreateWithCString(None, b"AXMenuBar",    _kCFStringEncodingUTF8)
_ATTR_CHILDREN   = _CF.CFStringCreateWithCString(None, b"AXChildren",   _kCFStringEncodingUTF8)
_ATTR_IDENTIFIER = _CF.CFStringCreateWithCString(None, b"AXIdentifier", _kCFStringEncodingUTF8)
_ATTR_HIDDEN     = _CF.CFStringCreateWithCString(None, b"AXHidden",     _kCFStringEncodingUTF8)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def ax_trusted() -> bool:
    return bool(_HI.AXIsProcessTrusted())


def request_ax_permission() -> None:
    """Prompt macOS to grant Accessibility permission for the current process."""
    key = _CF.CFStringCreateWithCString(None, b"AXTrustedCheckOptionPrompt", _kCFStringEncodingUTF8)
    opts = _CF.CFDictionaryCreateMutable(None, 1, _kCFTypeDictKeyCBs, _kCFTypeDictValCBs)
    _CF.CFDictionarySetValue(opts, key, _kCFBooleanTrue)
    _HI.AXIsProcessTrustedWithOptions(opts)
    _CF.CFRelease(opts)
    _CF.CFRelease(key)


def _cfstr_to_py(ref: int) -> str | None:
    if not ref:
        return None
    buf = ctypes.create_string_buffer(4096)
    ok = _CF.CFStringGetCString(ref, buf, len(buf), _kCFStringEncodingUTF8)
    return buf.value.decode("utf-8") if ok else None


# ---------------------------------------------------------------------------
# MenuBarHider
# ---------------------------------------------------------------------------

class MenuBarHider:
    """
    Hides all SystemUIServer status items except those in skip_ids,
    then restores them on demand.
    """

    def __init__(self, skip_ids: set[str]) -> None:
        self._skip_ids = skip_ids
        self._hidden: list[int] = []  # retained AXUIElementRef values

    # ------------------------------------------------------------------ #
    # Public API                                                           #
    # ------------------------------------------------------------------ #

    def hide_others(self) -> bool:
        """
        Hide all status items except skip_ids.
        Returns False (and opens permission pane) if not AX-trusted.
        """
        if not ax_trusted():
            request_ax_permission()
            return False

        pid = self._systemuiserver_pid()
        if pid is None:
            return False

        app_el = _HI.AXUIElementCreateApplication(pid)
        if not app_el:
            return False

        try:
            menubar = _Ref(0)
            if _HI.AXUIElementCopyAttributeValue(app_el, _ATTR_MENUBAR, ctypes.byref(menubar)) != _kAXErrorSuccess:
                return False

            try:
                children = _Ref(0)
                if _HI.AXUIElementCopyAttributeValue(menubar, _ATTR_CHILDREN, ctypes.byref(children)) != _kAXErrorSuccess:
                    return False

                try:
                    count = _CF.CFArrayGetCount(children)
                    self._hidden = []

                    for i in range(count):
                        item = _CF.CFArrayGetValueAtIndex(children, i)
                        if not item:
                            continue

                        # Skip items in skip_ids
                        id_ref = _Ref(0)
                        err = _HI.AXUIElementCopyAttributeValue(item, _ATTR_IDENTIFIER, ctypes.byref(id_ref))
                        if err == _kAXErrorSuccess and id_ref.value:
                            identifier = _cfstr_to_py(id_ref.value)
                            _CF.CFRelease(id_ref)
                            if identifier in self._skip_ids:
                                continue

                        err_h = _HI.AXUIElementSetAttributeValue(item, _ATTR_HIDDEN, _kCFBooleanTrue)
                        if err_h == _kAXErrorSuccess:
                            _CF.CFRetain(item)  # keep alive past array release
                            self._hidden.append(item)
                finally:
                    if children.value:
                        _CF.CFRelease(children)
            finally:
                if menubar.value:
                    _CF.CFRelease(menubar)
        finally:
            _CF.CFRelease(app_el)

        return True

    def restore(self) -> None:
        """Restore all elements hidden in the last hide_others() call."""
        for item in self._hidden:
            _HI.AXUIElementSetAttributeValue(item, _ATTR_HIDDEN, _kCFBooleanFalse)
            _CF.CFRelease(item)
        self._hidden = []

    # ------------------------------------------------------------------ #
    # Helpers                                                              #
    # ------------------------------------------------------------------ #

    @staticmethod
    def _systemuiserver_pid() -> int | None:
        for app in NSWorkspace.sharedWorkspace().runningApplications():
            if app.bundleIdentifier() == "com.apple.systemuiserver":
                return app.processIdentifier()
        return None
