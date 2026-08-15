#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build a generic, relocatable Linux distribution of DevEco Studio,
comparable to JetBrains IntelliJ IDEA's official Linux tar.gz.

This is a pure-Python replacement for the original Arch Linux PKGBUILD.
It does NOT require makepkg, does not install to /opt or /usr/bin, and
produces a self-contained directory that can be extracted anywhere and
run from `bin/devecostudio.sh`.

Inputs (place in the same directory, or pass via CLI):
  devecostudio-mac.zip             - DevEco Studio for Mac (contains .dmg)
  commandline-tools-linux-x64.zip  - Command Line Tools for Linux (x86_64)
  idea-<ver>.tar.gz                - IntelliJ IDEA Linux (auto-downloadable)

Output:
  dist/devecostudio-<ver>-linux-x86_64/   (extractable anywhere)
  dist/devecostudio-<ver>-linux-x86_64.tar.gz
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import zipfile
import urllib.request

# ─────────────────────────────────────────────────────────────────────────────
# Config (mirrors the variables at the top of the original PKGBUILD)
# ─────────────────────────────────────────────────────────────────────────────
PKGVER = "26.0.0.621"
IDEA_VER = "2026.1.3"

# Optional: expose CLI tools as <install>/bin/* symlinks (like IDEA's own
# bundled tools). Unlike the PKGBUILD we never write to /usr/bin.
EXPOSE_CLI_TOOLS = True          # symlink into <install>/bin/
HPREFIX_GENERIC_TOOLS = True     # prefix codelinter/Emulator with 'h'

DMG_ROOT = "DevEco-Studio/DevEco-Studio.app/Contents"
DMG_EXCLUDES = {
    "sdk/default",
    "jbr",
    "tools/emulator",
    "tools/dumpParser",
    "tools/llvm",
    "tools/profiler",
    "tools/node",
}

VMOPTIONS_TRANSFORMS = [
    ("-Dsun.java2d.metal=true", "-Dsun.java2d.opengl=true"),
]
VMOPTIONS_DROP = [
    "-Djava.security.manager",
    "-Dwsl",
]
VMOPTIONS_APPEND = [
    "-Dawt.lock.fair=true",
    "-Dsun.tools.attach.tmp.only=true",
    "-Dglfw.im.module=fcitx",
]

# ─────────────────────────────────────────────────────────────────────────────
# Logging helpers
# ─────────────────────────────────────────────────────────────────────────────
def info(msg: str) -> None:
    print(f"[info] {msg}", flush=True)

def warn(msg: str) -> None:
    print(f"[warn] {msg}", flush=True)

def error(msg: str) -> None:
    print(f"[error] {msg}", file=sys.stderr, flush=True)

def die(msg: str) -> None:
    error(msg)
    sys.exit(1)


# ─────────────────────────────────────────────────────────────────────────────
# Filesystem helpers
# ─────────────────────────────────────────────────────────────────────────────
def run(cmd, **kwargs) -> subprocess.CompletedProcess:
    info("+ " + " ".join(cmd))
    return subprocess.run(cmd, check=True, **kwargs)

def run_quiet(cmd, **kwargs):
    return subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, **kwargs)

def find_file(root: str, names: set, *, kind: str = "file") -> str:
    """Find a file/dir by name under root (single-level glob)."""
    for entry in os.scandir(root):
        if entry.name in names:
            if kind == "dir" and entry.is_dir():
                return entry.path
            if kind == "file" and entry.is_file():
                return entry.path
    return ""

def find_first(root: str, pattern: re.Pattern, kind="file") -> str:
    for entry in os.scandir(root):
        if pattern.match(entry.name):
            if kind == "dir" and entry.is_dir():
                return entry.path
            if kind == "file" and entry.is_file():
                return entry.path
    return ""


# ─────────────────────────────────────────────────────────────────────────────
# Extraction
# ─────────────────────────────────────────────────────────────────────────────
def extract_zip(zpath: str, outdir: str) -> str:
    info(f"Extracting {os.path.basename(zpath)} -> {outdir}")
    os.makedirs(outdir, exist_ok=True)
    with zipfile.ZipFile(zpath) as zf:
        zf.extractall(outdir)
    return outdir

def extract_tar_gz(tpath: str, outdir: str) -> str:
    info(f"Extracting {os.path.basename(tpath)} -> {outdir}")
    os.makedirs(outdir, exist_ok=True)
    with tarfile.open(tpath, "r:gz") as tf:
        tf.extractall(outdir, filter="data")
    return outdir

def extract_dmg(dmg_path: str, outdir: str, excludes: set) -> str:
    """Extract the Mac .dmg via 7z, returning the Mac Contents dir."""
    info(f"Extracting DMG {os.path.basename(dmg_path)} with 7z")
    os.makedirs(outdir, exist_ok=True)
    dmg_root = f"{DMG_ROOT}"
    cmd = ["7z", "x", "-y", f"-o{outdir}", dmg_path, f"{dmg_root}"]
    for ex in sorted(excludes):
        cmd.append(f"-x!{dmg_root}/{ex}")
    run(cmd)
    return os.path.join(outdir, dmg_root)


# ─────────────────────────────────────────────────────────────────────────────
# The build itself
# ─────────────────────────────────────────────────────────────────────────────
class GenericBuilder:
    def __init__(self, mac_zip, cli_zip, idea_tar, workdir, distdir,
                 pkgver=PKGVER, ideaver=IDEA_VER):
        self.mac_zip = mac_zip
        self.cli_zip = cli_zip
        self.idea_tar = idea_tar
        self.workdir = workdir
        self.distdir = distdir
        self.pkgver = pkgver
        self.ideaver = ideaver

        self.src = os.path.join(workdir, "src")
        self.out = os.path.join(workdir, "out")
        # Final installable tree (no /opt prefix)
        self.dest = os.path.join(self.out, f"devecostudio-{pkgver}-linux-x86_64")

        self.mac = ""
        self.cli = ""
        self.idea = ""

    # ── setup ──
    def extract_sources(self):
        os.makedirs(self.src, exist_ok=True)
        os.makedirs(self.out, exist_ok=True)

        # Mac zip
        mac_dir = os.path.join(self.src, "mac_zip")
        extract_zip(self.mac_zip, mac_dir)
        # Find .dmg recursively
        dmg = ""
        for root, dirs, files in os.walk(mac_dir):
            for f in files:
                if f.endswith(".dmg"):
                    dmg = os.path.join(root, f)
                    break
            if dmg:
                break
        if not dmg:
            die("Could not find a .dmg inside the Mac zip")
        self.mac = extract_dmg(dmg, os.path.join(self.src, "mac_dmg"), DMG_EXCLUDES)
        if not os.path.isdir(os.path.join(self.mac, "plugins")) or \
           not os.path.isfile(os.path.join(self.mac, "Resources", "product-info.json")):
            die("Mac DMG extraction failed: missing Contents/plugins or product-info.json")

        # CLI zip
        cli_dir = os.path.join(self.src, "cli")
        extract_zip(self.cli_zip, cli_dir)
        cli_root = os.path.join(cli_dir, "command-line-tools")
        if not os.path.isdir(cli_root):
            # tolerate a single top-level folder containing the tools
            entries = [d for d in os.scandir(cli_dir) if d.is_dir()]
            if len(entries) == 1:
                cli_root = entries[0].path
            else:
                die(f"Could not locate command-line-tools directory under {cli_dir}")
        self.cli = cli_root

        # IDEA tar.gz
        idea_dir = os.path.join(self.src, "idea")
        extract_tar_gz(self.idea_tar, idea_dir)
        idea_root = find_first(idea_dir, re.compile(r"^idea-IU-"), kind="dir")
        if not idea_root:
            die(f"Could not locate idea-IU-* directory under {idea_dir}")
        self.idea = idea_root

    # ── helpers ──
    @staticmethod
    def _copy(src, dst):
        shutil.copytree(src, dst) if os.path.isdir(src) else shutil.copy2(src, dst)

    @staticmethod
    def _symlink(target, linkname):
        if os.path.lexists(linkname):
            os.remove(linkname)
        os.symlink(target, linkname)

    # ── package steps ──
    def build(self):
        info(f"Building generic DevEco Studio {self.pkgver} -> {self.dest}")
        if os.path.exists(self.dest):
            shutil.rmtree(self.dest)
        os.makedirs(self.dest)
        for sub in ("bin", "jbr", "lib", "plugins", "modules", "tools", "license", "sdk"):
            os.makedirs(os.path.join(self.dest, sub), exist_ok=True)

        self._copy_mac()
        self._copy_idea()
        self._copy_cli()
        self._transform_vmoptions()
        self._transform_product_info()
        self._write_launcher()
        self._fix_permissions()
        self._strip_binaries()
        self._cleanup()
        self._write_readme()
        info(f"Build complete: {self.dest}")

    # ── Mac cross-platform files ──
    def _copy_mac(self):
        mac, dst = self.mac, self.dest
        # lib/*.jar
        lib_dir = os.path.join(mac, "lib")
        for f in os.scandir(lib_dir):
            if f.name.endswith(".jar") and f.is_file():
                shutil.copy2(f.path, os.path.join(dst, "lib"))
        # plugins (minus ohos-trace)
        plugins_src = os.path.join(mac, "plugins")
        for entry in os.scandir(plugins_src):
            if entry.name == "ohos-trace":
                continue
            self._copy(entry.path, os.path.join(dst, "plugins", entry.name))
        # modules
        for entry in os.scandir(os.path.join(mac, "modules")):
            self._copy(entry.path, os.path.join(dst, "modules", entry.name))
        # license / build.txt / svg / idea.properties
        license_dst = os.path.join(dst, "license")
        shutil.rmtree(license_dst, ignore_errors=True)
        shutil.copytree(os.path.join(mac, "license"), license_dst)
        shutil.copy2(os.path.join(mac, "Resources", "build.txt"), dst)
        shutil.copy2(os.path.join(mac, "bin", "devecostudio.svg"), os.path.join(dst, "bin"))
        shutil.copy2(os.path.join(mac, "bin", "idea.properties"), os.path.join(dst, "bin"))
        # UxTestService (Mac-only, python cross-platform)
        ux = os.path.join(mac, "tools", "UxTestService")
        if os.path.isdir(ux):
            self._copy(ux, os.path.join(dst, "tools", "UxTestService"))

    # ── IDEA Linux components ──
    def _copy_idea(self):
        idea, dst = self.idea, self.dest
        # JBR
        jbr_dst = os.path.join(dst, "jbr")
        shutil.rmtree(jbr_dst)
        self._copy(os.path.join(idea, "jbr"), jbr_dst)
        # launcher
        shutil.copy2(os.path.join(idea, "bin", "idea"), os.path.join(dst, "bin", "devecostudio"))
        os.chmod(os.path.join(dst, "bin", "devecostudio"), 0o755)
        # fsnotifier
        shutil.copy2(os.path.join(idea, "bin", "fsnotifier"), os.path.join(dst, "bin"))
        # native libs
        for rel in ("lib/native/linux-x86_64", "lib/pty4j/linux", "lib/jna/amd64", "lib/skiko-awt-runtime-all"):
            self._copy(os.path.join(idea, rel), os.path.join(dst, rel))
        # mac-style jbr Contents/Home/bin symlink
        home_bin = os.path.join(dst, "jbr", "Contents", "Home", "bin")
        os.makedirs(os.path.dirname(home_bin), exist_ok=True)
        self._symlink("../../bin", home_bin)

    # ── CLI Linux tools ──
    def _copy_cli(self):
        cli, dst = self.cli, self.dest
        tools = os.path.join(dst, "tools")

        # hvigor / ohpm / hstack / codelinter
        for tool in ("hvigor", "ohpm", "hstack", "codelinter"):
            src = os.path.join(cli, tool)
            if os.path.isdir(src):
                self._copy(src, os.path.join(tools, tool))

        # emulator (not present in every CLI version)
        if os.path.isdir(os.path.join(cli, "emulator")):
            self._copy(os.path.join(cli, "emulator"), os.path.join(tools, "emulator"))
            # Huawei's non-Mac branch hardcodes "Emulator.exe"
            self._symlink("Emulator", os.path.join(tools, "emulator", "Emulator.exe"))

        # node
        node_src = os.path.join(cli, "tool", "node")
        if os.path.isdir(node_src):
            self._copy(node_src, os.path.join(tools, "node"))
            node = os.path.join(tools, "node")
            # top-level symlinks to bin/*
            for name in os.scandir(os.path.join(node, "bin")):
                self._symlink(f"bin/{name.name}", os.path.join(node, name.name))
            # IDE node version check fixes
            self._symlink("lib/node_modules", os.path.join(node, "node_modules"))
            os.makedirs(os.path.join(tools, "lib"), exist_ok=True)
            self._symlink("../node/lib/node_modules", os.path.join(tools, "lib", "node_modules"))

        # SDK
        sdk_src = os.path.join(cli, "sdk")
        if os.path.isdir(sdk_src):
            sdk_dst = os.path.join(dst, "sdk")
            shutil.rmtree(sdk_dst)
            self._copy(sdk_src, sdk_dst)

        # CLI wrappers -> tools/bin with path fixes
        if os.path.isdir(os.path.join(cli, "bin")):
            bin_dst = os.path.join(tools, "bin")
            os.makedirs(bin_dst, exist_ok=True)
            for f in os.scandir(os.path.join(cli, "bin")):
                if f.is_file():
                    dst_f = os.path.join(bin_dst, f.name)
                    shutil.copy2(f.path, dst_f)
                    os.chmod(dst_f, 0o755)
            self._patch_cli_wrappers(bin_dst)

        # optional exposure as <install>/bin/* symlinks
        if EXPOSE_CLI_TOOLS:
            self._expose_cli()

    def _patch_cli_wrappers(self, bin_dst):
        """Port the PKGBUILD's sed rewrites to Python."""
        for f in os.scandir(bin_dst):
            if not f.is_file():
                continue
            p = f.path
            try:
                with open(p, "r", encoding="utf-8", errors="surrogateescape") as fh:
                    text = fh.read()
            except OSError:
                continue
            orig = text
            text = text.replace('cd "$(dirname "$0")"',
                                'cd "$(dirname "$(readlink -f "$0")")"')
            text = text.replace('$all_tool_dir/tool/node', '$all_tool_dir/node')
            text = text.replace('$all_tool_dir/sdk', '$all_tool_dir/../sdk')
            if text != orig:
                with open(p, "w", encoding="utf-8", errors="surrogateescape") as fh:
                    fh.write(text)
            os.chmod(p, 0o755)

        # codelinter's inner launcher hardcoded paths
        codelinter_bin = os.path.join(bin_dst, "..", "codelinter", "bin", "codelinter")
        codelinter_bin = os.path.normpath(codelinter_bin)
        if os.path.isfile(codelinter_bin):
            os.chmod(codelinter_bin, 0o755)
            with open(codelinter_bin, "r", encoding="utf-8", errors="surrogateescape") as fh:
                text = fh.read()
            text = text.replace('$ROOT_PATH/tool/node', '$ROOT_PATH/node')
            text = text.replace('$ROOT_PATH/sdk', '$ROOT_PATH/../sdk')
            with open(codelinter_bin, "w", encoding="utf-8", errors="surrogateescape") as fh:
                fh.write(text)
            os.chmod(codelinter_bin, 0o755)

    def _expose_cli(self):
        """Symlink CLI tools into <install>/bin/ so users can add that to PATH."""
        bin_dst = os.path.join(self.dest, "bin")
        tools_bin = os.path.join(self.dest, "tools", "bin")
        for name in ("hvigorw", "ohpm", "hstack"):
            src = os.path.join(tools_bin, name)
            if os.path.exists(src):
                self._symlink(os.path.join("../tools/bin", name), os.path.join(bin_dst, name))
        if HPREFIX_GENERIC_TOOLS:
            if os.path.exists(os.path.join(tools_bin, "codelinter")):
                self._symlink("../tools/bin/codelinter", os.path.join(bin_dst, "hcodelinter"))
            if os.path.exists(os.path.join(tools_bin, "Emulator")):
                self._symlink("../tools/bin/Emulator", os.path.join(bin_dst, "hemulator"))
        else:
            if os.path.exists(os.path.join(tools_bin, "codelinter")):
                self._symlink("../tools/bin/codelinter", os.path.join(bin_dst, "codelinter"))
            if os.path.exists(os.path.join(tools_bin, "Emulator")):
                self._symlink("../tools/bin/Emulator", os.path.join(bin_dst, "Emulator"))

    # ── vmoptions ──
    def _transform_vmoptions(self):
        src = os.path.join(self.mac, "bin", "devecostudio.vmoptions")
        dst = os.path.join(self.dest, "bin", "devecostudio64-lin.vmoptions")
        with open(src, "r", encoding="utf-8") as fh:
            lines = fh.read().splitlines()
        out = []
        for line in lines:
            s = line
            for old, new in VMOPTIONS_TRANSFORMS:
                s = s.replace(old, new)
            if any(s.startswith(d) or s.strip() == d for d in VMOPTIONS_DROP):
                continue
            out.append(s)
        out.extend(VMOPTIONS_APPEND)
        with open(dst, "w", encoding="utf-8") as fh:
            fh.write("\n".join(out) + "\n")

    # ── product-info.json ──
    def _transform_product_info(self):
        src = os.path.join(self.mac, "Resources", "product-info.json")
        dst = os.path.join(self.dest, "product-info.json")
        with open(src, "r", encoding="utf-8") as fh:
            data = json.load(fh)

        data["svgIconPath"] = "bin/devecostudio.svg"
        launch = data["launch"][0]
        launch["os"] = "Linux"
        launch["arch"] = "amd64"
        launch["launcherPath"] = "bin/devecostudio"
        launch["javaExecutablePath"] = "jbr/bin/java"
        launch["vmOptionsFilePath"] = "bin/devecostudio64-lin.vmoptions"
        launch["startupWmClass"] = "deveco-studio"
        launch.pop("svgIconPath", None)

        addons = []
        for arg in launch.get("additionalJvmArguments", []):
            arg = arg.replace("$APP_PACKAGE/Contents/", "$IDE_HOME/")
            if re.search(r"com\.apple\.eawt|com\.apple\.laf|sun\.lwawt", arg):
                continue
            addons.append(arg)
        addons += [
            "--enable-native-access=ALL-UNNAMED",
            "-Dawt.lock.fair=true",
            "-Dsun.tools.attach.tmp.only=true",
            "-Dglfw.im.module=fcitx",
            "--add-opens=java.desktop/com.sun.java.swing.plaf.gtk=ALL-UNNAMED",
            "--add-opens=java.desktop/javax.swing.text.html.parser=ALL-UNNAMED",
            "--add-opens=java.desktop/sun.awt.X11=ALL-UNNAMED",
        ]
        launch["additionalJvmArguments"] = addons

        with open(dst, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, ensure_ascii=False)
            fh.write("\n")

    # ── launcher wrapper ──
    def _write_launcher(self):
        wrapper = os.path.join(self.dest, "bin", "devecostudio.sh")
        with open(wrapper, "w", encoding="utf-8") as fh:
            fh.write(LAUNCHER_TEMPLATE)
        os.chmod(wrapper, 0o755)

    # ── permissions / strip / cleanup ──
    def _fix_permissions(self):
        info("Fixing permissions (Mac DMG files ship 700)")
        for root, dirs, files in os.walk(self.dest):
            for d in dirs:
                os.chmod(os.path.join(root, d), 0o755)
            for f in files:
                p = os.path.join(root, f)
                try:
                    with open(p, "rb") as fh:
                        head = fh.read(256)
                    if head[:4] == b"\x7fELF" or b"#!" in head:
                        st = os.stat(p)
                        os.chmod(p, st.st_mode | 0o111)
                    else:
                        os.chmod(p, 0o644)
                except OSError:
                    pass

    def _strip_binaries(self):
        info("Stripping Linux binaries (JBR, launcher, native .so, fsnotifier)")
        jbr = os.path.join(self.dest, "jbr")
        for root, dirs, files in os.walk(jbr):
            for f in files:
                p = os.path.join(root, f)
                if os.access(p, os.X_OK):
                    run_quiet(["strip", "--strip-all", p])
        run_quiet(["strip", "--strip-all", os.path.join(self.dest, "bin", "devecostudio")])
        for root, dirs, files in os.walk(os.path.join(self.dest, "lib")):
            for f in files:
                if f.endswith(".so"):
                    run_quiet(["strip", "--strip-unneeded", os.path.join(root, f)])
        run_quiet(["strip", "--strip-all", os.path.join(self.dest, "bin", "fsnotifier")])

    def _cleanup(self):
        info("Cleaning Windows/macOS platform cruft")
        for root, dirs, files in os.walk(self.dest):
            for f in list(files):
                p = os.path.join(root, f)
                if f.endswith(".exe") and f != "Emulator.exe":
                    os.remove(p)
                elif f.endswith((".dll", ".dylib", ".jnilib", ".bat", ".ps1")):
                    os.remove(p)
                elif f.endswith(".sh"):
                    rel = os.path.relpath(p, self.dest)
                    # keep the IDE wrapper and real SDK build scripts
                    if rel == "bin/devecostudio.sh":
                        continue
                    if rel.startswith(("bin/", "tools/bin/", "plugins/")):
                        os.remove(p)

    # ── readme / desktop ──
    def _write_readme(self):
        readme = os.path.join(self.dest, "Install-Linux.txt")
        with open(readme, "w", encoding="utf-8") as fh:
            fh.write(INSTALL_README_TEMPLATE.format(version=self.pkgver))

    def package_tar(self):
        tar_name = f"devecostudio-{self.pkgver}-linux-x86_64.tar.gz"
        tar_path = os.path.join(self.distdir, tar_name)
        os.makedirs(self.distdir, exist_ok=True)
        info(f"Creating {tar_path}")
        with tarfile.open(tar_path, "w:gz") as tf:
            tf.add(self.dest, arcname=os.path.basename(self.dest))
        return tar_path


# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────
def clean(workdir: str, distdir: str, pkgver: str = PKGVER) -> None:
    """Remove intermediate build artifacts (workdir/src, workdir/out) and the
    produced tar.gz in distdir. Leaves user-provided sources untouched."""
    targets = []

    # Intermediate extraction/build tree under the workdir
    for name in ("src", "out"):
        p = os.path.join(workdir, name)
        if os.path.exists(p):
            targets.append(p)

    # Final tarball in distdir
    tar_name = f"devecostudio-{pkgver}-linux-x86_64.tar.gz"
    tar_path = os.path.join(distdir, tar_name)
    if os.path.exists(tar_path):
        targets.append(tar_path)

    if not targets:
        info("Nothing to clean.")
        return

    for p in targets:
        if os.path.isdir(p) and not os.path.islink(p):
            info(f"Removing directory {p}")
            shutil.rmtree(p, ignore_errors=True)
        else:
            info(f"Removing {p}")
            try:
                os.remove(p)
            except OSError as e:
                warn(f"Could not remove {p}: {e}")


LAUNCHER_TEMPLATE = r'''#!/bin/bash
# DevEco Studio generic Linux launcher.
# Relocatable: resolves its own directory, so it works from any install path.
export _JAVA_AWT_WM_NONREPARENTING=1
# Emulator uses the Qt xcb platform plugin (no wayland build shipped)
export QT_QPA_PLATFORM=xcb
# XWayland reports monitor scale 1.0 to JBR, so the IDE locks UI scale to
# 1.0 -- too small on HiDPI. Inject the compositor's real scale (wlr-randr,
# needs WAYLAND_DISPLAY so run it before unsetting it) as -Dide.ui.scale.
# DEVECO_UI_SCALE: number (override, as-is) or "off" (disable).
_hidpi_scale=""
case "${DEVECO_UI_SCALE:-auto}" in
  off) ;;
  auto)
    _cs=""
    command -v wlr-randr >/dev/null 2>&1 && \
      _cs=$(wlr-randr 2>/dev/null | awk '/Scale:/{print $2; exit}')
    if [[ "$_cs" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      _hidpi_scale=$(LC_ALL=C awk -v s="$_cs" 'BEGIN{ q=int(s*4+0.5)/4; if (q<1.0) q=1.0; printf "%.2f", q }')
    fi
    ;;
  *)
    if [[ "$DEVECO_UI_SCALE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      _hidpi_scale="$DEVECO_UI_SCALE"
    else
      printf 'Ignoring invalid DEVECO_UI_SCALE=%q (expected auto, off, or a number)\n' \
        "$DEVECO_UI_SCALE" >&2
    fi
    ;;
esac
if [[ -n "$_hidpi_scale" ]]; then
  _cfg="${XDG_CONFIG_HOME:-$HOME/.config}/Huawei/DevEcoStudio26.0"
  if mkdir -p "$_cfg"; then
    echo "-Dide.ui.scale=$_hidpi_scale" > "$_cfg/devecostudio-hidpi.vmoptions"
    export DEVECOSTUDIO_VM_OPTIONS="$_cfg/devecostudio-hidpi.vmoptions"
  else
    printf 'Unable to create the HiDPI vmoptions overlay in %s\n' "$_cfg" >&2
  fi
fi
# JCEF GPU process crashes under Wayland; use the X11 backend by default
# (DEVECO_DISABLE_X11_WORKAROUND=1 to keep Wayland).
if [[ "${DEVECO_DISABLE_X11_WORKAROUND:-0}" != "1" ]]; then
  unset WAYLAND_DISPLAY
  export GDK_BACKEND=x11
fi
# JCEF headless + out-of-process rendering fixes blank CEF pages in some
# environments (DEVECO_DISABLE_JCEF_HEADLESS=1 to opt out).
_JCEF_ARGS=()
if [[ "${DEVECO_DISABLE_JCEF_HEADLESS:-0}" != "1" ]]; then
  _JCEF_ARGS=("-Dide.browser.jcef.headless.enabled=true" "-Dide.browser.jcef.out-of-process.enabled=true")
fi
# Emulator hardcodes the macOS-style image path ~/Library/Huawei/Sdk
mkdir -p "$HOME/Library/Huawei"
ln -sfn "$HOME/.Huawei/Sdk" "$HOME/Library/Huawei/Sdk"
exec "$(dirname "$(readlink -f "$0")")/devecostudio" "${_JCEF_ARGS[@]}" "$@"
'''

INSTALL_README_TEMPLATE = """\
DevEco Studio {version}

GENERIC LINUX INSTALLATION
===============================================================================

  1. Unpack this archive where you wish to install the program. We will refer
     to this location as your {{installation home}}.

  2. To start the application, open a console, cd into
     "{{installation home}}/bin" and type:

       ./devecostudio.sh

     This will initialize various configuration files in the configuration
     directory:
     ~/.config/Huawei/DevEcoStudio26.0

  3. [OPTIONAL] Add "{{installation home}}/bin" to your PATH environment
     variable so that you can start DevEco Studio and the bundled CLI tools
     (hvigorw, ohpm, hstack, hcodelinter, hemulator) from any directory.

  4. [OPTIONAL] Install the desktop entry by copying devecostudio.desktop to
     ~/.local/share/applications/ and updating the Exec/Icon paths.

Runtime dependencies (package names vary by distro):
  libxss, libxtst, nss, alsa-lib, libxcrypt-compat, freetype2, libpulse.
Chinese input support needs fcitx5.

The previewer (on-device preview) is not available on Linux: Huawei has not
ported the Rosen rendering engine to desktop Linux.

Enjoy!
"""


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(
        description="Build a generic Linux distribution of DevEco Studio "
                    "(like IntelliJ IDEA's official tar.gz).")
    ap.add_argument("--mac-zip", default="devecostudio-mac.zip",
                    help="Path to devecostudio-mac.zip (default: devecostudio-mac.zip)")
    ap.add_argument("--cli-zip", default="commandline-tools-linux-x64.zip",
                    help="Path to commandline-tools-linux-x64.zip")
    ap.add_argument("--idea-tar", default=None,
                    help="Path to idea-*.tar.gz (default: auto-download idea-%s.tar.gz)" % IDEA_VER)
    ap.add_argument("--pkgver", default=PKGVER, help="DevEco Studio version")
    ap.add_argument("--ideaver", default=IDEA_VER, help="IntelliJ IDEA baseline version")
    ap.add_argument("--workdir", default="build", help="Working directory for extraction "
                                                       "(default: build)")
    ap.add_argument("--distdir", default="build", help="Output directory for the tar.gz "
                                                       "(default: build)")
    ap.add_argument("--no-tar", action="store_true", help="Only build the directory, no tar.gz")
    ap.add_argument("--clean", action="store_true",
                    help="Remove intermediate build artifacts (workdir/src, "
                         "workdir/out) and the produced tar.gz in distdir, "
                         "then exit")
    args = ap.parse_args()

    if args.clean:
        clean(args.workdir, args.distdir, args.pkgver)
        return

    if not os.path.isfile(args.mac_zip):
        die(f"Mac zip not found: {args.mac_zip}")
    if not os.path.isfile(args.cli_zip):
        die(f"CLI zip not found: {args.cli_zip}")

    idea_tar = args.idea_tar
    if not idea_tar:
        idea_tar = f"idea-{args.ideaver}.tar.gz"
    if not os.path.isfile(idea_tar):
        url = f"https://download.jetbrains.com/idea/{idea_tar}"
        info(f"Downloading {url}")
        urllib.request.urlretrieve(url, idea_tar)

    builder = GenericBuilder(args.mac_zip, args.cli_zip, idea_tar,
                             args.workdir, args.distdir,
                             pkgver=args.pkgver, ideaver=args.ideaver)
    builder.extract_sources()
    builder.build()
    if not args.no_tar:
        tarpath = builder.package_tar()
        info(f"Created {tarpath}")


if __name__ == "__main__":
    main()
