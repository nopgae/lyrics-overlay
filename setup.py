from setuptools import setup

APP = ["run.py"]
DATA_FILES = []
OPTIONS = {
    "argv_emulation": False,
    "packages": [
        "lyrics_overlay",
        "pygame",
        "requests",
        "mutagen",
        "certifi",
        "charset_normalizer",
        "idna",
        "urllib3",
    ],
    "frameworks": [],
    "plist": {
        "CFBundleName": "Lyrics Overlay",
        "CFBundleDisplayName": "Lyrics Overlay",
        "CFBundleIdentifier": "com.nopgae.lyrics-overlay",
        "CFBundleVersion": "0.1.0",
        "CFBundleShortVersionString": "0.1.0",
        "NSHighResolutionCapable": True,
        "LSUIElement": True,          # Hide from Dock (menu bar app)
        "NSMicrophoneUsageDescription": "",
        "NSAppleEventsUsageDescription":
            "Lyrics Overlay needs Apple Events access to detect YouTube Music playback.",
    },
    "excludes": ["tkinter", "unittest", "email", "xml", "pydoc"],
}

setup(
    app=APP,
    name="Lyrics Overlay",
    data_files=DATA_FILES,
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)
