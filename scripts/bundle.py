#!/usr/bin/env python3
"""Build build/shotit.app: release build, bundle layout, Info.plist, ad-hoc signature.

Needs only Command Line Tools. Usage: python3 scripts/bundle.py
"""
import plistlib
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build" / "shotit.app"


def main() -> None:
    for product in ["shotit", "shotit-icon"]:
        subprocess.run(["swift", "build", "-c", "release", "--product", product, "--package-path", str(ROOT)], check=True)
    bin_dir = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path", "--package-path", str(ROOT)],
                             check=True, capture_output=True, text=True).stdout.strip()

    if APP.exists():
        shutil.rmtree(APP)
    (APP / "Contents" / "MacOS").mkdir(parents=True)
    (APP / "Contents" / "Resources").mkdir()
    shutil.copy2(Path(bin_dir) / "shotit", APP / "Contents" / "MacOS" / "shotit")

    # The Dock, the Cmd-Tab switcher, and Finder show this icon.
    iconset = ROOT / "build" / "AppIcon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    subprocess.run([str(Path(bin_dir) / "shotit-icon"), str(iconset)], check=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(APP / "Contents" / "Resources" / "AppIcon.icns")],
                   check=True)
    shutil.rmtree(iconset)

    info = {
        "CFBundleName": "shotit",
        "CFBundleDisplayName": "shotit",
        "CFBundleIdentifier": "com.canavjoh.shotit",
        "CFBundleExecutable": "shotit",
        "CFBundleIconFile": "AppIcon",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        # Menu bar app: no Dock icon.
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "CFBundleDocumentTypes": [{
            "CFBundleTypeName": "Image",
            "CFBundleTypeRole": "Editor",
            "LSHandlerRank": "Alternate",
            "LSItemContentTypes": ["public.image"],
        }],
    }
    with open(APP / "Contents" / "Info.plist", "wb") as f:
        plistlib.dump(info, f)

    subprocess.run(["codesign", "--force", "--sign", "-", str(APP)], check=True)
    size = sum(p.stat().st_size for p in APP.rglob("*") if p.is_file())
    print(f"{APP}  ({size / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
