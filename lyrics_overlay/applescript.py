"""
Shared in-process AppleScript runner.

NSAppleScript is not thread-safe, but the watchers run on background poll
threads. Every execution goes through one lock so two scripts never run
concurrently, and compiled scripts are cached so the same source isn't
recompiled on every poll.
"""

import threading

import objc
from Foundation import NSAppleScript

_lock = threading.Lock()
_compiled: dict[str, NSAppleScript] = {}


def run_applescript(source: str) -> str:
    """Execute *source* and return its string result, or "" on any error."""
    with _lock, objc.autorelease_pool():
        try:
            script = _compiled.get(source)
            if script is None:
                script = NSAppleScript.alloc().initWithSource_(source)
                ok, err = script.compileAndReturnError_(None)
                if not ok:
                    return ""
                _compiled[source] = script
            desc, err = script.executeAndReturnError_(None)
            if err or desc is None:
                return ""
            v = desc.stringValue()
            return str(v) if v else ""
        except Exception:
            return ""


def app_is_running(bundle_id: str) -> bool:
    """Cheap check (no Apple Event) so we never script — and thereby launch — a closed app."""
    from AppKit import NSRunningApplication
    return len(NSRunningApplication.runningApplicationsWithBundleIdentifier_(bundle_id)) > 0
