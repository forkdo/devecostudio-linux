#!/usr/bin/env bash

#============================================================
# File: build.sh
# Description: 构建跨发行版、解压即用的 DevEco Studio 通用 tarball
# URL: https://fx4.cn/devecobuild
# Author: Jetsung Chan <i@jetsung.com>
# Version: 0.1.0
# CreatedAt: 2026-08-16
# UpdatedAt: 2026-08-16
#============================================================

# build.sh — 构建跨发行版、解压即用的 DevEco Studio 通用 tarball。
#
# 取代原 Arch PKGBUILD：不再产出 *.pkg.tar.zst，而是产出自包含的
# devecostudio-<ver>-linux-x86_64.tar.gz（解压到任意位置即可运行），或经
# --install DIR 直接安装到本地目录（免打包）。所有「魔法」适配逻辑与
# DETAILS.md 完全一致，只是用 bash 重写，直接调用 Linux 自带工具。
#
# 三个上游源：
#   1. Mac DMG 包（devecostudio-mac-<ver>.zip，内含 .dmg）——平台无关 Java/插件
#   2. CLI 工具包（commandline-tools-linux-x64-<ver>.zip）——Linux SDK 与工具
#   3. IntelliJ IDEA tarball（idea-<ideaver>.tar.gz）——Linux JBR/启动器/原生库
#
# 仅支持 Linux 运行。

if [[ -n "$DEBUG" ]]; then
  set -eux
else
  set -euo pipefail
fi

# --------------------------------------------------------------------------- #
# 配置
# --------------------------------------------------------------------------- #
DEFAULT_PKGVER="26.0.0.621"
DEFAULT_IDEAVER="2026.2.1"
IDEA_URL_TEMPLATE="https://download.jetbrains.com/idea/idea-%s.tar.gz"
HPREFIX_GENERIC_TOOLS=1 # 暴露 CLI 工具时 codelinter/Emulator 加 h 前缀

# --------------------------------------------------------------------------- #
# 目录布局（脚本同级 build/）
#   build/cache — 下载的源归档（跨次复用）
#   build/work  — 中间解压与组装树（跨次复用，避免重复解压）
#   build/out   — 最终产物（tarball / install-cli-tools.sh）
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$SCRIPT_DIR/build"
CACHE_DIR="$ROOT/cache"
WORK_DIR="$ROOT/work"
OUT_DIR="$ROOT/out"

# --------------------------------------------------------------------------- #
# 日志
# --------------------------------------------------------------------------- #
log() { printf '==> %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# --------------------------------------------------------------------------- #
# 帮助
# --------------------------------------------------------------------------- #
usage() {
  cat <<EOF
构建跨发行版、解压即用的 DevEco Studio 通用 tarball。

必填项：构建时必须提供 Mac 源（通过 -m，可为本地路径或 http(s) 地址），且其文件名/地址中含版本号；
CLI 工具源（通过 -c，本地路径或地址）与 IDEA 源（通过 -i 本地路径/地址，或省略后按 -a 自动拼接）也须可解析。
未指定 -v/--pkgver 时，版本号自动从 Mac 源的文件名或地址中提取。

若只给 --install DIR（不提供任何源），且 build/work/devecostudio-<ver> 已存在，
则直接复用该已组装的目录树（跳过解压与组装），把应用装到 DIR。

最后一步可二选一（或都做）：默认打包成 tar.gz 到 build/out/；
用 --install DIR 则直接安装到指定文件夹（本地使用免打包，可加 --no-package 跳过 tar.gz）。

用法：
  build.sh -m MAC [-c CLI] [-i IDEA] [-v PKGVER] [-a IDEAVER]
                          [-x] [-n] [-I DIR] [-P] [--clean]

  -m, --mac MAC           Mac 源：本地路径（devecostudio-mac-<ver>.zip）或以 http(s):// 开头的下载地址
                         （构建时必填，文件名/地址须含版本号；纯 --install 复用已有树时可省略）
  -c, --cli CLI           CLI 工具源：本地路径（commandline-tools-linux-x64-<ver>.zip）或 http(s):// 下载地址
  -i, --idea IDEA         IDEA 源：本地路径（idea-<ideaver>.tar.gz）或 http(s):// 下载地址；省略则按 -a 自动拼接下载地址
  -v, --pkgver PKGVER     DevEco Studio 版本号；省略时从 Mac 源文件名/地址自动提取
  -a, --ideaver IDEAVER   IntelliJ IDEA 基线版本号（用于拼接 IDEA 源下载地址）
  -x, --expose-cli        额外生成 install-cli-tools.sh，将命令行工具链入 /usr/local/bin
  -n, --no-download       纯本地模式：三个源都必须本地提供，禁止联网下载
  -I, --install DIR        将组装好的应用树直接安装到指定文件夹（含 bin/、jbr/ 等），不再打包成 tar.gz
  -P, --no-package        跳过打包 tar.gz（通常与 --install 搭配，本地使用无需打包）
  --clean                  清除中间产物与下载缓存（build/work/ 与 build/cache/）后退出，不执行构建；最终产物 build/out/ 保留
  -h, --help               显示帮助信息并退出
EOF
}

# --------------------------------------------------------------------------- #
# 依赖检测
# --------------------------------------------------------------------------- #
require_tools() {
  local missing=()
  for t in 7z bsdtar jq tar strip; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  # 下载器：curl 或 wget 任一即可
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    missing+=("curl/wget")
  fi
  if ((${#missing[@]})); then
    die "缺少必需工具：${missing[*]}（CLI zip 解压需要 bsdtar；Arch 随 libarchive 提供，Fedora/RHEL 与 Debian/Ubuntu 需单独装 bsdtar 包）"
  fi
}

# --------------------------------------------------------------------------- #
# 工具函数
# --------------------------------------------------------------------------- #
is_url() {
  [[ "$1" == http://* || "$1" == https://* ]]
}

# 解析单个源：本地路径直接返回（须存在）；URL 下载进 cache 并复用。
# 参数：$1=缓存文件名 $2=ref（本地路径或 URL） $3=默认 URL（ref 为空时使用，可空）
resolve_source() {
  local name="$1" ref="$2" default_url="$3"
  if [[ -z "$ref" ]]; then
    if [[ -z "$default_url" ]]; then
      die "源 '$name' 未提供；请通过对应 -m/-c/-i 选项传入"
    fi
    ref="$default_url"
  fi
  if is_url "$ref"; then
    local cached="$CACHE_DIR/$name"
    if [[ -f "$cached" ]]; then
      log "复用已缓存的 $name"
      echo "$cached"
      return 0
    fi
    if ((NO_DOWNLOAD)); then
      die "源 '$name' 未提供本地文件且 --no-download 已设置"
    fi
    log "下载 $name ..."
    mkdir -p "$CACHE_DIR"
    if command -v curl >/dev/null 2>&1; then
      curl -fSL -o "$cached" "$ref" || die "下载失败：$ref"
    else
      wget -O "$cached" "$ref" || die "下载失败：$ref"
    fi
    echo "$cached"
  else
    local p
    p="$(readlink -f "$ref")"
    [[ -f "$p" ]] || die "本地源不存在：$ref"
    echo "$p"
  fi
}

# 保留符号链接的复制（cp -a）
cp_tree() {
  # $1=src $2=dst
  mkdir -p "$2"
  cp -a "$1" "$2"
}

# 把 src 下所有顶层条目复制到 dst（dst 下已存在的同名先删）。跳过 skip 集合里的名字。
copy_top_entries() {
  local src="$1" dst="$2"
  shift 2
  local skip=("$@")
  mkdir -p "$dst"
  local ent
  for ent in "$src"/* "$src"/.[!.]*; do
    [[ -e "$ent" || -L "$ent" ]] || continue
    local base
    base="$(basename "$ent")"
    local skipped=0
    local s
    for s in "${skip[@]:-}"; do
      [[ "$s" == "$base" ]] && {
        skipped=1
        break
      }
    done
    [[ $skipped -eq 1 ]] && continue
    local target="$dst/$base"
    if [[ -L "$target" || -e "$target" ]]; then
      rm -rf "$target"
    fi
    cp -a "$ent" "$target"
  done
}

# --------------------------------------------------------------------------- #
# 解压
# --------------------------------------------------------------------------- #
extract_mac_dmg() {
  # $1=mac zip 路径；输出 work/mac_dmg 下的 Contents；返回 Contents 路径
  local zip_path="$1"
  local out="$WORK_DIR/mac_dmg"
  local contents="$out/DevEco-Studio/DevEco-Studio.app/Contents"
  if [[ -d "$contents/plugins" && -f "$contents/Resources/product-info.json" ]]; then
    log "复用已解压的 Mac DMG（如需强制重解压请运行 --clean）"
    echo "$contents"
    return 0
  fi
  log "解压 Mac DMG ..."
  local stage="$WORK_DIR/mac_zip"
  rm -rf "$stage" "$out"
  mkdir -p "$stage" "$out"
  7z x -y "-o$stage" "$zip_path" >/dev/null || die "解压 Mac 外层 zip 失败"
  local dmg
  dmg="$(find "$stage" -name '*.dmg' | head -1)"
  [[ -n "$dmg" ]] || die "Mac zip 内未找到 .dmg"
  # 仅解 Contents，排除平台相关目录（后续由 IDEA/CLI 的 Linux 版本替换）
  7z x -y "-o$out" "$dmg" \
    DevEco-Studio/DevEco-Studio.app/Contents \
    -x!'DevEco-Studio/DevEco-Studio.app/Contents/sdk/default' \
    -x!'DevEco-Studio/DevEco-Studio.app/Contents/jbr' \
    -x!'DevEco-Studio/DevEco-Studio.app/Contents/tools/emulator' \
    -x!'DevEco-Studio/DevEco-Studio.app/Contents/tools/dumpParser' \
    -x!'DevEco-Studio/DevEco-Studio.app/Contents/tools/llvm' \
    -x!'DevEco-Studio/DevEco-Studio.app/Contents/tools/profiler' \
    -x!'DevEco-Studio/DevEco-Studio.app/Contents/tools/node' \
    >/dev/null || die "解压 Mac DMG 失败"
  [[ -d "$contents/plugins" && -f "$contents/Resources/product-info.json" ]] ||
    die "Mac DMG 解压失败（缺少 plugins/ 或 product-info.json）"
  echo "$contents"
}

extract_cli() {
  # $1=cli zip 路径；解压到 work/cli（保留符号链接），返回 command-line-tools 目录
  local zip_path="$1"
  local dest="$WORK_DIR/cli"
  local cli="$dest/command-line-tools"
  if [[ -d "$cli" && -n "$(ls -A "$cli" 2>/dev/null)" ]]; then
    log "复用已解压的 CLI 工具（如需强制重解压请运行 --clean）"
    echo "$cli"
    return 0
  fi
  log "解压 commandline-tools-linux-x64 ..."
  rm -rf "$dest"
  mkdir -p "$dest"
  # bsdtar 能正确保留符号链接（7z 会拒收、unzip 会损坏它们）
  bsdtar -xf "$zip_path" -C "$dest" || die "解压 CLI zip 失败（需要 bsdtar 才能保留符号链接）"
  [[ -d "$cli" ]] || cli="$dest" # 极少数扁平结构回退
  echo "$cli"
}

extract_idea() {
  # $1=idea tarball 路径；解压到 work/idea，返回 idea-IU-* 目录
  local tar_path="$1"
  local dest="$WORK_DIR/idea"
  local idea
  idea="$(find "$dest" -maxdepth 1 -type d -name 'idea-IU-*' 2>/dev/null | head -1)"
  if [[ -n "$idea" ]]; then
    log "复用已解压的 IntelliJ IDEA（如需强制重解压请运行 --clean）"
    echo "$idea"
    return 0
  fi
  log "解压 IntelliJ IDEA tarball ..."
  rm -rf "$dest"
  mkdir -p "$dest"
  tar -xzf "$tar_path" -C "$dest" || die "解压 IDEA tarball 失败"
  idea="$(find "$dest" -maxdepth 1 -type d -name 'idea-IU-*' 2>/dev/null | head -1)"
  [[ -n "$idea" ]] || die "IDEA 解压后未找到 idea-IU-* 目录"
  echo "$idea"
}

# --------------------------------------------------------------------------- #
# 权限修复（必须在 sed 改写之前）
# Mac DMG 文件 ship 700，先统一目录 755 / 文件 644，再扫描 ELF/shebang 补执行位。
# 用 head 读字节判断，不用 file（大树叶可能崩溃）。
# --------------------------------------------------------------------------- #
fix_permissions() {
  local root="$1"
  log "修复权限（Mac DMG 文件 ship 700）..."
  [[ -d "$root" ]] || return 0
  find "$root" -type d ! -type l -exec chmod 0755 {} +
  find "$root" -type f ! -type l -exec chmod 0644 {} +
  # 补执行位：ELF 魔法字节（\x7fELF）或含 #! 的脚本。
  # shebang 检测放宽到前 4KB（hstack 等脚本在 #! 前放了版权注释）。
  local f magic
  while IFS= read -r -d '' f; do
    # 用 od 取前 4 字节 hex，避免把含 NUL 的二进制读进变量触发警告
    magic="$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    if [[ "$magic" == "7f454c46" ]]; then
      chmod +x "$f"
    elif head -c 4096 "$f" 2>/dev/null | grep -q $'^#!'; then
      chmod +x "$f"
    fi
  done < <(find "$root" -type f ! -type l -print0)
  # 已知的 Linux 原生可执行二进制 / 入口脚本：head 字节扫描偶发漏判，
  # 这里显式补 +x，确保 Emulator / fsnotifier / hstack 等一定可执行。
  local exe
  for exe in \
    "$root/tools/emulator/Emulator" \
    "$root/bin/fsnotifier" \
    "$root/bin/devecostudio" \
    "$root/tools/hstack/bin/hstack" \
    "$root/tools/codelinter/bin/codelinter" \
    "$root/tools/ohpm/bin/ohpm" \
    "$root/tools/ohpm/bin/init" \
    "$root/tools/hvigor/bin/hvigorw"; do
    [[ -f "$exe" ]] && chmod +x "$exe"
  done
}

# --------------------------------------------------------------------------- #
# 转换
# --------------------------------------------------------------------------- #
transform_vmoptions() {
  local mac_contents="$1" pkg="$2"
  log "转换 vmoptions（macOS -> Linux）..."
  local src="$mac_contents/bin/devecostudio.vmoptions"
  local out="$pkg/bin/devecostudio64-lin.vmoptions"
  mkdir -p "$pkg/bin"
  {
    while IFS= read -r line; do
      case "$(echo "$line" | tr -d '[:space:]')" in
      -Dsun.java2d.metal=true) echo "-Dsun.java2d.opengl=true" ;;
      -Djava.security.manager) continue ;;
      -Dwsl*) continue ;;
      *) echo "$line" ;;
      esac
    done <"$src"
    echo "-Dawt.lock.fair=true"
    echo "-Dsun.tools.attach.tmp.only=true"
    echo "-Dglfw.im.module=fcitx"
  } >"$out"
}

transform_product_info() {
  local mac_contents="$1" pkg="$2"
  log "转换 product-info.json（macOS -> Linux，经 jq）..."
  local src="$mac_contents/Resources/product-info.json"
  local out="$pkg/product-info.json"
  local filter='
    .svgIconPath = $svg
    | .launch[0].os = $os
    | .launch[0].launcherPath = $launcher
    | .launch[0].javaExecutablePath = $java
    | .launch[0].arch = $arch
    | .launch[0].vmOptionsFilePath = $vmopts
    | .launch[0].startupWmClass = $wmclass
    | del(.launch[0].svgIconPath)
    | .launch[0].additionalJvmArguments |= (
        map(gsub("\\$APP_PACKAGE/Contents/"; "$IDE_HOME/"))
        | map(select(test("com\\.apple\\.eawt|com\\.apple\\.laf|sun\\.lwawt") | not))
        | . + [
            "--enable-native-access=ALL-UNNAMED",
            "-Dawt.lock.fair=true",
            "-Dsun.tools.attach.tmp.only=true",
            "-Dglfw.im.module=fcitx",
            "--add-opens=java.desktop/com.sun.java.swing.plaf.gtk=ALL-UNNAMED",
            "--add-opens=java.desktop/javax.swing.text.html.parser=ALL-UNNAMED",
            "--add-opens=java.desktop/sun.awt.X11=ALL-UNNAMED"
        ]
    )
    '
  jq --arg os Linux --arg arch amd64 \
    --arg launcher bin/devecostudio \
    --arg java jbr/bin/java \
    --arg vmopts bin/devecostudio64-lin.vmoptions \
    --arg wmclass deveco-studio \
    --arg svg bin/devecostudio.svg \
    "$filter" "$src" >"$out" ||
    die "product-info.json 转换失败"
}

# --------------------------------------------------------------------------- #
# 启动器包装脚本（bin/devecostudio.sh）
# --------------------------------------------------------------------------- #
WRAPPER_SCRIPT='#!/bin/bash
export _JAVA_AWT_WM_NONREPARENTING=1
# Emulator uses the Qt xcb platform plugin (no wayland build shipped)
export QT_QPA_PLATFORM=xcb
# XWayland reports monitor scale 1.0 to JBR, so the IDE locks UI scale to
# 1.0 — too small on HiDPI. Inject the compositor'"'"'s real scale (wlr-randr,
# needs WAYLAND_DISPLAY so run it before unsetting it) as -Dide.ui.scale.
# DEVECO_UI_SCALE: number (override, as-is) or "off" (disable).
_hidpi_scale=""
case "${DEVECO_UI_SCALE:-auto}" in
  off) ;;
  auto)
    _cs=""
    command -v wlr-randr >/dev/null 2>&1 && \
      _cs=$(wlr-randr 2>/dev/null | awk "/Scale:/{print \$2; exit}")
    if [[ "$_cs" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      _hidpi_scale=$(LC_ALL=C awk -v s="$_cs" "BEGIN{ q=int(s*4+0.5)/4; if (q<1.0) q=1.0; printf \"%.2f\", q }")
    fi
    ;;
  *)
    if [[ "$DEVECO_UI_SCALE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      _hidpi_scale="$DEVECO_UI_SCALE"
    else
      printf "Ignoring invalid DEVECO_UI_SCALE=%q (expected auto, off, or a number)\n" \
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
    printf "Unable to create the HiDPI vmoptions overlay in %s\n" "$_cfg" >&2
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
# 真实目录必须存在，否则软链悬空、Emulator 下载系统镜像会写失败
mkdir -p "$HOME/.Huawei/Sdk"
ln -sfn "$HOME/.Huawei/Sdk" "$HOME/Library/Huawei/Sdk"

# 解压即用布局：自带 plugins/ 在安装目录下。IntelliJ 平台默认会把
# idea.plugins.path 解析到 XDG 风格目录（~/.local/share/Huawei/...），
# 该目录不存在，启动时会刷一堆 "NoSuchFileException" 噪音。显式指向自带
# plugins 目录即可消除（IntelliJ 启动器读取 IDEA_PLUGINS_PATH 等价于
# -Didea.plugins.path）。
export IDEA_PLUGINS_PATH="$(dirname "$(readlink -f "$0")")/plugins"

exec "$(dirname "$(readlink -f "$0")")/devecostudio" "${_JCEF_ARGS[@]}" "$@"
'

# Emulator 包装补丁：在 emulator 调用前插入路径桥接 + 协议自动接受
EMULATOR_PATCH='
mkdir -p "$HOME/Library/Huawei"
ln -sfn "$HOME/.Huawei/Sdk" "$HOME/Library/Huawei/Sdk"
_emu_config="$HOME/Library/Caches/Huawei/Emulator26.0/.emu_config"
if [[ ! -f "$_emu_config" ]]; then
    echo "Emulator software agreements not yet accepted. Displaying and accepting them now..."
    "$all_tool_dir/emulator/Emulator" -license accept
    echo ""
    echo "Re-run your command to proceed."
    echo "To opt out: truncate $_emu_config."
    exit 0
fi

# 模拟器自带 libqxcb.so（xcb 平台插件），但不带 wayland 插件。
# 在 Wayland 会话里若不设此项，会默认找 wayland 插件而失败
# （qt.qpa.plugin: Could not find the Qt platform plugin "wayland"）。
export QT_QPA_PLATFORM=xcb
'

patch_emulator_wrapper() {
  local pkg="$1"
  local emu="$pkg/tools/bin/Emulator"
  [[ -f "$emu" ]] || return 0
  log "修补 Emulator 包装脚本..."
  # 在调用 "$all_tool_dir/emulator/Emulator" "$@" 前插入补丁
  local marker='$all_tool_dir/emulator/Emulator" "$@"'
  if grep -qF "$marker" "$emu"; then
    # 用 awk 在 marker 行前插入补丁块。
    # 注意：marker 含 '$'（正则里的行尾锚点），必须用 index() 做字面子串
    # 匹配，不能用 '$0 ~ marker' 正则，否则永远匹配不上、补丁被静默丢弃。
    awk -v patch="$EMULATOR_PATCH" -v marker="$marker" '
            index($0, marker) { print patch; print $0; next }
            { print }
        ' "$emu" >"$emu.tmp" && mv "$emu.tmp" "$emu"
  else
    printf '%s\n' "$EMULATOR_PATCH" >>"$emu"
  fi
  chmod +x "$emu"
}

# --------------------------------------------------------------------------- #
# CLI 包装脚本修复
# --------------------------------------------------------------------------- #
fix_cli_wrappers() {
  local pkg="$1"
  log "修复 CLI 工具包装脚本..."
  local bin_dir="$pkg/tools/bin"
  [[ -d "$bin_dir" ]] || return 0
  local f
  for f in "$bin_dir"/*; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    sed -i \
      -e 's#cd "$(dirname "$0")"#cd "$(dirname "$(readlink -f "$0")")"#' \
      -e 's#\$all_tool_dir/tool/node#$all_tool_dir/node#' \
      -e 's#\$all_tool_dir/sdk#$all_tool_dir/../sdk#' \
      "$f"
    chmod +x "$f"
  done
  # codelinter 内部启动器使用 $ROOT_PATH
  local codelinter="$pkg/tools/codelinter/bin/codelinter"
  if [[ -f "$codelinter" && ! -L "$codelinter" ]]; then
    sed -i \
      -e 's#\$ROOT_PATH/tool/node#$ROOT_PATH/node#' \
      -e 's#\$ROOT_PATH/sdk#$ROOT_PATH/../sdk#' \
      "$codelinter"
  fi
}

# --------------------------------------------------------------------------- #
# node / emulator 符号链接
# --------------------------------------------------------------------------- #
setup_tools_symlinks() {
  local pkg="$1"
  local tools="$pkg/tools"
  # Emulator.exe -> Emulator（仅当 emulator 二进制存在）
  if [[ -f "$tools/emulator/Emulator" ]]; then
    ln -sf Emulator "$tools/emulator/Emulator.exe"
  fi
  # node：顶层工具软链 node/npm/npx/corepack -> bin/*
  local node_dir="$tools/node"
  [[ -d "$node_dir/bin" ]] || return 0
  local e
  for e in "$node_dir/bin"/*; do
    [[ -e "$e" || -L "$e" ]] || continue
    local name
    name="$(basename "$e")"
    ln -sf "bin/$name" "$node_dir/$name"
  done
  # node/node_modules -> lib/node_modules
  ln -sfn lib/node_modules "$node_dir/node_modules"
  # tools/lib/node_modules -> ../node/lib/node_modules
  mkdir -p "$tools/lib"
  ln -sfn ../node/lib/node_modules "$tools/lib/node_modules"
}

# --------------------------------------------------------------------------- #
# strip / cleanup
# --------------------------------------------------------------------------- #
strip_binaries() {
  log "剥离 Linux 二进制（JBR、启动器、原生 .so、fsnotifier）..."
  [[ -d "$PKG/jbr" ]] && find "$PKG/jbr" -type f ! -type l -executable -exec strip --strip-all {} \; \; 2>/dev/null
  [[ -f "$PKG/bin/devecostudio" ]] && strip --strip-all "$PKG/bin/devecostudio" 2>/dev/null
  find "$PKG" -name '*.so' -type f ! -type l -exec strip --strip-unneeded {} \; 2>/dev/null
  [[ -f "$PKG/bin/fsnotifier" ]] && strip --strip-all "$PKG/bin/fsnotifier" 2>/dev/null
}

cleanup() {
  log "清理平台残留文件..."
  local root="$1"
  # 删 Windows/macOS 文件（保留我们创建的 Emulator.exe 软链）
  # 注意：find 的 -o 优先级低，必须把「后缀名」与「(文件或链接)」整体括起来，
  # 否则裸的 -type l 会匹配所有符号链接导致把 clang++/npm 等必要软链全删掉。
  find "$root" \( \
    \( -name '*.exe' -o -name '*.dll' -o -name '*.dylib' -o -name '*.jnilib' -o -name '*.bat' -o -name '*.ps1' \) \
    \( -type f -o -type l \) -a ! -name 'Emulator.exe' \
    \) -print0 2>/dev/null | while IFS= read -r -d '' p; do
    rm -f "$p"
  done
  # 删多余的 .sh（保留 devecostudio.sh）
  for d in "$root/bin" "$root/tools/bin"; do
    [[ -d "$d" ]] || continue
    find "$d" -name '*.sh' ! -name 'devecostudio.sh' -exec rm -f {} \; 2>/dev/null
  done
  if [[ -d "$root/plugins" ]]; then
    find "$root/plugins" -name '*.sh' -exec rm -f {} \; 2>/dev/null
  fi
}

# --------------------------------------------------------------------------- #
# 组装
# --------------------------------------------------------------------------- #
assemble() {
  local mac_contents="$1" idea="$2" cli="$3" pkg="$4"
  log "组装应用目录树..."

  # 骨架（先彻底清空各目标，避免上一次残留污染导致增量覆盖丢符号链接）
  local d
  for d in bin jbr lib plugins modules tools license sdk; do
    rm -rf "$pkg/$d"
    mkdir -p "$pkg/$d"
  done

  # 来自 Mac DMG 的平台无关文件
  cp_tree "$mac_contents/lib/." "$pkg/lib"
  cp_tree "$mac_contents/plugins/." "$pkg/plugins"
  rm -rf "$pkg/plugins/ohos-trace" # 该插件带退出挂死 bug
  cp_tree "$mac_contents/modules/." "$pkg/modules"
  cp_tree "$mac_contents/license/." "$pkg/license"
  cp -a "$mac_contents/Resources/build.txt" "$pkg/build.txt"
  cp -a "$mac_contents/bin/devecostudio.svg" "$pkg/bin/devecostudio.svg"
  cp -a "$mac_contents/bin/idea.properties" "$pkg/bin/idea.properties"
  # UxTestService 来自 Mac DMG（跨平台 Python）
  mkdir -p "$pkg/tools/UxTestService"
  cp_tree "$mac_contents/tools/UxTestService/." "$pkg/tools/UxTestService"

  # 来自 CLI 的 Linux 原生内容（顶层条目整体拷贝，跳过 tool）
  copy_top_entries "$cli" "$pkg/tools" tool
  cp_tree "$cli/tool/node/." "$pkg/tools/node"

  # IDEA 部分：JBR + 启动器 + 原生库
  rm -rf "$pkg/jbr"
  cp_tree "$idea/jbr/." "$pkg/jbr"
  cp -a "$idea/bin/idea" "$pkg/bin/devecostudio"
  chmod +x "$pkg/bin/devecostudio"
  cp -a "$idea/bin/fsnotifier" "$pkg/bin/fsnotifier"
  # JBR macOS 风格路径软链（部分华为插件硬编码）
  mkdir -p "$pkg/jbr/Contents/Home/bin"
  ln -sfn ../../bin "$pkg/jbr/Contents/Home/bin/bin"
  # 原生库目录（来自 IDEA）
  mkdir -p "$pkg/lib/native/linux-x86_64" "$pkg/lib/pty4j/linux" \
    "$pkg/lib/jna/amd64" "$pkg/lib/skiko-awt-runtime-all"
  cp_tree "$idea/lib/native/linux-x86_64/." "$pkg/lib/native/linux-x86_64"
  cp_tree "$idea/lib/pty4j/linux/." "$pkg/lib/pty4j/linux"
  cp -a "$idea/lib/jna/amd64/libjnidispatch.so" "$pkg/lib/jna/amd64/libjnidispatch.so"
  cp_tree "$idea/lib/skiko-awt-runtime-all/." "$pkg/lib/skiko-awt-runtime-all"

  # SDK 来自 CLI（必须在 fix_permissions 之前拷入，否则 SDK 内 ELF
  # 如 es2abc/ark_aot_compiler 会漏 +x，编译时报「权限不够」）。
  rm -rf "$pkg/sdk"
  cp_tree "$cli/sdk/." "$pkg/sdk"

  # 权限修复——必须在所有内容（含 JBR、原生库、SDK）拷入之后再做，
  # 否则这些 ELF 会因 fix_permissions 跑在拷贝前而漏掉 +x：
  #   - jbr/bin/java 缺失 → 启动器报 "Cannot find a runtime / Runtime not found"
  #   - sdk 内 es2abc 等缺失 → hvigor 编译 ArkTS 报「权限不够」
  fix_permissions "$pkg"

  # CLI 包装脚本 / Emulator 补丁
  fix_cli_wrappers "$pkg"
  patch_emulator_wrapper "$pkg"

  # node / emulator 符号链接
  setup_tools_symlinks "$pkg"

  # 启动器包装脚本
  printf '%s' "$WRAPPER_SCRIPT" >"$pkg/bin/devecostudio.sh"
  chmod +x "$pkg/bin/devecostudio.sh"

  # 转换
  transform_vmoptions "$mac_contents" "$pkg"
  transform_product_info "$mac_contents" "$pkg"

  strip_binaries
  cleanup "$pkg"
}

# --------------------------------------------------------------------------- #
# 安装（直接复制到目录，保留符号链接）
# --------------------------------------------------------------------------- #
install_tree() {
  local src="$1" dest="$2"
  log "安装到 $dest ..."
  mkdir -p "$dest"
  # 删除 dest 中不在 src 里的顶层条目（刷新旧安装残留）
  local item
  for item in "$dest"/* "$dest"/.[!.]*; do
    [[ -e "$item" || -L "$item" ]] || continue
    local b
    b="$(basename "$item")"
    [[ -e "$src/$b" || -L "$src/$b" ]] || rm -rf "$item"
  done
  # 复制（保留符号链接）
  local e
  for e in "$src"/* "$src"/.[!.]*; do
    [[ -e "$e" || -L "$e" ]] || continue
    local t="$dest/$(basename "$e")"
    rm -rf "$t"
    cp -a "$e" "$t"
  done
  log "已安装：运行 $dest/bin/devecostudio.sh"
}

# --------------------------------------------------------------------------- #
# install-cli-tools.sh 生成
# --------------------------------------------------------------------------- #
write_expose_helper() {
  local out_dir="$1" pkgver="$2"
  log "生成 install-cli-tools.sh ..."
  local helper="$out_dir/install-cli-tools.sh"
  {
    echo '#!/bin/bash'
    echo 'set -e'
    echo 'TOOLS_BIN="$(dirname "$(readlink -f "$0")")/tools/bin"'
    echo 'mkdir -p /usr/local/bin'
    echo 'for t in hvigorw ohpm hstack; do'
    echo '  ln -sf "$TOOLS_BIN/$t" /usr/local/bin/$t'
    echo 'done'
    if ((HPREFIX_GENERIC_TOOLS)); then
      echo 'ln -sf "$TOOLS_BIN/codelinter" /usr/local/bin/hcodelinter'
      echo 'ln -sf "$TOOLS_BIN/Emulator" /usr/local/bin/hemulator'
    else
      echo 'ln -sf "$TOOLS_BIN/codelinter" /usr/local/bin/codelinter'
      echo 'ln -sf "$TOOLS_BIN/Emulator" /usr/local/bin/Emulator'
    fi
    echo 'echo "CLI tools linked into /usr/local/bin."'
  } >"$helper"
  chmod +x "$helper"
}

# --------------------------------------------------------------------------- #
# --clean
# --------------------------------------------------------------------------- #
clean_intermediates() {
  local removed=()
  if [[ -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
    removed+=("$WORK_DIR")
  fi
  if [[ -d "$CACHE_DIR" ]]; then
    rm -rf "$CACHE_DIR"
    removed+=("$CACHE_DIR")
  fi
  if ((${#removed[@]})); then
    log "已清除中间产物：$(
      IFS=,
      echo "${removed[*]}"
    )"
  else
    log "无需清理（未找到 build/work/ 或 build/cache/）"
  fi
}

# --------------------------------------------------------------------------- #
# 参数解析
# --------------------------------------------------------------------------- #
MAC="" CLI="" IDEA="" PKGVER="" IDEAVER="$DEFAULT_IDEAVER"
EXPOSE_CLI=0 NO_DOWNLOAD=0 INSTALL_DIR="" NO_PACKAGE=0 CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
  -m | --mac)
    MAC="$2"
    shift 2
    ;;
  -c | --cli)
    CLI="$2"
    shift 2
    ;;
  -i | --idea)
    IDEA="$2"
    shift 2
    ;;
  -v | --pkgver)
    PKGVER="$2"
    shift 2
    ;;
  -a | --ideaver)
    IDEAVER="$2"
    shift 2
    ;;
  -x | --expose-cli)
    EXPOSE_CLI=1
    shift
    ;;
  -n | --no-download)
    NO_DOWNLOAD=1
    shift
    ;;
  -I | --install)
    INSTALL_DIR="$2"
    shift 2
    ;;
  -P | --no-package)
    NO_PACKAGE=1
    shift
    ;;
  --clean)
    CLEAN=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "未知参数：$1（用 -h 查看帮助）" ;;
  esac
done

# 无参数 -> 等同 -h（注意 IDEAVER 有默认值，不纳入“未指定”判断）
if [[ $# -eq 0 && -z "$MAC$CLI$IDEA$PKGVER" && $((EXPOSE_CLI + NO_DOWNLOAD + NO_PACKAGE + CLEAN)) -eq 0 && -z "$INSTALL_DIR" ]]; then
  usage
  exit 0
fi

# --clean 独立可用
if ((CLEAN)); then
  clean_intermediates
  exit 0
fi

# 解析版本号（构建模式下从 Mac 源提取；纯安装模式从已有树目录名提取）
if [[ -z "$PKGVER" ]]; then
  if [[ -n "$MAC" && "$MAC" =~ devecostudio-mac-([0-9]+(\.[0-9]+)*) ]]; then
    PKGVER="${BASH_REMATCH[1]}"
    log "从 Mac 源提取版本号：$PKGVER"
  else
    PKGVER="$DEFAULT_PKGVER"
  fi
fi

# 纯安装/打包模式：未提供任何源，但 build/work/ 已有组装树 -> 跳过构建直接复用
VERSIONED="$WORK_DIR/devecostudio-$PKGVER"
SKIP_BUILD=0
if [[ -z "$MAC$CLI$IDEA" && -d "$VERSIONED" ]]; then
  SKIP_BUILD=1
  log "复用已组装的目录树：$VERSIONED（未提供源，跳过解压与组装）"
fi

# 构建模式下 -m 必填
[[ $SKIP_BUILD -eq 1 || -n "$MAC" ]] || die "-m/--mac 构建时必填（传入本地路径或 http(s):// 地址）"

if ((SKIP_BUILD)); then
  : # 直接复用 $VERSIONED
else
  require_tools
  mkdir -p "$ROOT"

  # 解析三个源（缓存于 build/cache/）
  MAC_PATH="$(resolve_source devecostudio-mac.zip "$MAC" "")"
  CLI_PATH="$(resolve_source commandline-tools-linux-x64.zip "$CLI" "")"
  IDEA_URL="$(printf "$IDEA_URL_TEMPLATE" "$IDEAVER")"
  IDEA_PATH="$(resolve_source "idea-$IDEAVER.tar.gz" "$IDEA" "$IDEA_URL")"

  # 解压
  MAC_CONTENTS="$(extract_mac_dmg "$MAC_PATH")"
  CLI_DIR="$(extract_cli "$CLI_PATH")"
  IDEA_DIR="$(extract_idea "$IDEA_PATH")"

  # 组装
  PKG="$WORK_DIR/devecostudio"
  # 彻底清掉上一次可能残留的无版本号/带版本号组装树，避免增量覆盖污染
  rm -rf "$PKG" "$VERSIONED"
  mkdir -p "$PKG"
  assemble "$MAC_CONTENTS" "$IDEA_DIR" "$CLI_DIR" "$PKG"

  # 重命名为带版本号的目录
  rm -rf "$VERSIONED"
  mv "$PKG" "$VERSIONED"
fi

# 最后阶段：安装 和/或 打包
did_anything=0
if [[ -n "$INSTALL_DIR" ]]; then
  install_tree "$VERSIONED" "$INSTALL_DIR"
  did_anything=1
fi
if ((!NO_PACKAGE)); then
  mkdir -p "$OUT_DIR"
  TAR_NAME="devecostudio-$PKGVER-linux-x86_64.tar.gz"
  TAR_PATH="$OUT_DIR/$TAR_NAME"
  log "创建 tarball $TAR_NAME ..."
  tar -czf "$TAR_PATH" -C "$WORK_DIR" "devecostudio-$PKGVER"
  if ((EXPOSE_CLI)); then
    write_expose_helper "$OUT_DIR" "$PKGVER"
  fi
  log "完成：$TAR_PATH"
  did_anything=1
fi
if ((!did_anything)); then
  log "已组装目录树（未打包/安装）：$VERSIONED"
fi
log "中间产物保留在 $WORK_DIR（加 --clean 可清除）"
exit 0
