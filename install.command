#!/usr/bin/env python3
"""Install the latest shotit. Double-click this file in Finder, or run: python3 install.command

Steps: pull the latest main, build build/shotit.app, quit the running shotit, replace
/Applications/shotit.app (~/Applications when /Applications is not writable), and open it.
"""
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BUNDLE_ID = "com.canavjoh.shotit"


def run(*cmd: str) -> None:
    print("$", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def main() -> None:
    run("git", "-C", str(ROOT), "pull", "--ff-only")
    run(sys.executable, str(ROOT / "scripts" / "bundle.py"))

    if subprocess.run(["pgrep", "-x", "shotit"], capture_output=True).returncode == 0:
        print("Quitting the running shotit", flush=True)
        subprocess.run(["osascript", "-e", f'tell application id "{BUNDLE_ID}" to quit'], check=False)
        for _ in range(50):
            if subprocess.run(["pgrep", "-x", "shotit"], capture_output=True).returncode != 0:
                break
            time.sleep(0.1)
        else:
            sys.exit("shotit did not quit. Quit it from the menu bar and run this again.")

    apps = Path("/Applications")
    if not os.access(apps, os.W_OK):
        apps = Path.home() / "Applications"
        apps.mkdir(exist_ok=True)
    dest = apps / "shotit.app"
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(ROOT / "build" / "shotit.app", dest, symlinks=True)
    print(f"Installed {dest}", flush=True)
    run("open", str(dest))
    print("\nDone. If capture stops working, turn shotit on again in "
          "System Settings > Privacy & Security > Screen & System Audio Recording.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        sys.exit(f"\nInstall failed: {' '.join(e.cmd)} exited with {e.returncode}.")
