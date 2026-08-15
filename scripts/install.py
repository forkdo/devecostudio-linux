#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Optional helper to "install" a previously-built generic DevEco Studio
distribution for the current user (no root, no /opt, no /usr/bin).

It creates:
  - ~/.local/bin symlinks for the IDE launcher and the bundled CLI tools
    (add ~/.local/bin to PATH if not already there)
  - a user desktop entry at ~/.local/share/applications/devecostudio.desktop

Usage:
  python3 scripts/install.py <path-to-devecostudio-<ver>-linux-x86_64>
  python3 scripts/install.py dist/devecostudio-6.1.1.300-linux-x86_64
  python3 scripts/install.py --uninstall
"""

import argparse
import os
import shutil
import sys

APP_NAME = "DevEco Studio"
APP_ID = "devecostudio"

# Bundled CLI tools (relative to <install>/bin)
CLI_TOOLS = ["hvigorw", "ohpm", "hstack", "hcodelinter", "hemulator"]


def home() -> str:
    return os.path.expanduser("~")


def ensure_dir(p: str) -> None:
    os.makedirs(p, exist_ok=True)


def symlink(target: str, linkname: str) -> None:
    if os.path.lexists(linkname):
        os.remove(linkname)
    os.symlink(target, linkname)


def install(inst_root: str) -> None:
    inst_root = os.path.abspath(inst_root)
    if not os.path.isfile(os.path.join(inst_root, "bin", "devecostudio.sh")):
        sys.exit(f"error: {inst_root} is not a DevEco Studio install tree "
                 f"(missing bin/devecostudio.sh)")

    bin_local = os.path.join(home(), ".local", "bin")
    apps_dir = os.path.join(home(), ".local", "share", "applications")
    ensure_dir(bin_local)
    ensure_dir(apps_dir)

    # Launcher
    launcher_link = os.path.join(bin_local, "devecostudio")
    symlink(os.path.join(inst_root, "bin", "devecostudio.sh"), launcher_link)
    print(f"linked {launcher_link}")

    # CLI tools (only those present in this build)
    for tool in CLI_TOOLS:
        src = os.path.join(inst_root, "bin", tool)
        if os.path.lexists(src):
            link = os.path.join(bin_local, tool)
            symlink(src, link)
            print(f"linked {link}")

    # Desktop entry
    desktop = os.path.join(apps_dir, "devecostudio.desktop")
    with open(desktop, "w", encoding="utf-8") as f:
        f.write(
            "[Desktop Entry]\n"
            f"Name={APP_NAME}\n"
            "Comment=HarmonyOS Development IDE\n"
            f"Exec={launcher_link} %f\n"
            f"Icon={os.path.join(inst_root, 'bin', 'devecostudio.svg')}\n"
            "Terminal=false\n"
            "Type=Application\n"
            "Categories=Development;IDE;\n"
            "StartupWMClass=deveco-studio\n"
        )
    print(f"wrote {desktop}")

    print("\nDone. Add ~/.local/bin to PATH if you haven't already:")
    print("  export PATH=\"$HOME/.local/bin:$PATH\"")


def uninstall() -> None:
    bin_local = os.path.join(home(), ".local", "bin")
    for name in ["devecostudio"] + CLI_TOOLS:
        p = os.path.join(bin_local, name)
        if os.path.lexists(p):
            os.remove(p)
            print(f"removed {p}")
    desktop = os.path.join(home(), ".local", "share", "applications",
                           "devecostudio.desktop")
    if os.path.lexists(desktop):
        os.remove(desktop)
        print(f"removed {desktop}")


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Install a generic DevEco Studio distribution for the "
                    "current user (no root).")
    ap.add_argument("install_dir", nargs="?", default=None,
                    help="Path to the extracted devecostudio-<ver>-linux-x86_64 tree")
    ap.add_argument("--uninstall", action="store_true",
                    help="Remove user-level launcher, CLI links and desktop entry")
    args = ap.parse_args()

    if args.uninstall:
        uninstall()
        return
    if not args.install_dir:
        sys.exit("error: provide the install directory or use --uninstall")
    install(args.install_dir)


if __name__ == "__main__":
    main()
