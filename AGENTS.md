# DevEco Studio Linux 通用构建脚本 — 开发者须知（build.sh）

本文件是 `build.sh` 的开发者视角文档，记录**为什么**脚本要这么做——每一处
「魔法」、它绕开的上游怪癖、以及维护/复刻时需要注意的细节。`README.md` 是
用户视角；Arch 专用打包（`PKGBUILD`）见 [`arch/`](arch/)。

## 维护铁律：不得修改 `arch/` 中的任何文件

> **`arch/` 目录下的 `PKGBUILD`、`README.md`、`README_CN.md`、`DETAILS.md`
> 均为 v26.0.0 分支的原版，属 Arch 专用打包，与 `build.sh` 通用构建体系相互独立。**
>
> **严禁修改 `arch/` 中任何文件的代码或内容。** 它们只随上游 v26.0.0 分支同步，
> 不在本仓库的 `develop` 工作流中维护。任何 Arch 相关调整都应在原分支进行，
> 切勿在 `develop` 里直接编辑 `arch/` 下的文件。

## 架构：三个来源，一份产物

`build.sh` 产出**跨发行版、解压即用**的 `devecostudio-<ver>-linux-x86_64.tar.gz`
（或经 `--install DIR` 直接装到本地目录），不绑定 `/opt`，不需要 `.desktop`。
三个上游源：

| 源 | 提供什么 | 为什么 |
|---|---|---|
| **Mac DMG**（`devecostudio-mac.zip` 内含 `.dmg`） | `lib/*.jar`、`plugins/`、`modules/`、`license/`、`build.txt`、`bin/*.svg`/`idea.properties`/`*.vmoptions`、`Resources/product-info.json`、`tools/UxTestService` | 华为给 Windows/macOS/Linux 都发版。Windows 是难解的 `.exe` 且版本滞后；Mac DMG 用 `7z x` 即可解，且列出的文件全是平台无关（Java 字节码、资源、模板）。 |
| **Command Line Tools for Linux**（`commandline-tools-linux-x64.zip`） | `sdk/`、`tool/node/`、`hvigor/`、`ohpm/`、`hstack/`、`codelinter/`、`emulator/`、`bin/` 包装脚本 | CLI zip 已含 Linux 原生版本，其 SDK 正是 IDE 所需。 |
| **IntelliJ IDEA tarball**（`idea-<ver>.tar.gz`） | `jbr/`、`bin/idea` 启动器、`bin/fsnotifier`、`lib/native/linux-x86_64/`、`lib/pty4j/linux/`、`lib/jna/amd64/`、`lib/skiko-awt-runtime-all/` | macOS 专属位（JBR、启动器、原生 `.so`）被 Linux 版替换。DevEco 的 build number 固定对应某个 IDEA 基线。 |

Mac DMG 中不在上表的内容，要么平台原生（Linux 不可用），要么被 CLI 覆盖：
`jbr`、`sdk/default`、`tools/emulator`、`tools/llvm`、`tools/profiler`、
`tools/node`、`tools/dumpParser` 在解 DMG 时即被排除（`extract_mac_dmg` 的
`-x!` 列表）。

两个华为 zip **用户自供**（链接签名且会过期），重命名为版本无关文件名
（`devecostudio-mac.zip`、`commandline-tools-linux-x64.zip`）。IDEA tarball 由
脚本**自动下载**，其版本在构建期解析得出，故不做 checksum 校验。

## IDEA 版本自动解析（核心改动）

IDEA 基线**不再手填**。Mac DMG 的 `product-info.json` 带 `buildNumber`
（如 `261.23567.138.36.2600621`），前三段 `261.23567.138` 正好等于某个 IDEA
release 的 `build` 字段（`2026.1.1`）。`resolve_idea_ver()` 只用 JetBrains
feed 作唯一真源：

1. 读 `buildNumber`，取前三段 `261.23567.138`；
2. 查 JetBrains release feed
   （`data.services.jetbrains.com/products/releases?code=IIU&type=release`），
   找 `build` 以该前缀开头的 IDEA 版本 → `2026.1.1`，从而得知分支 `2026.1`；
3. 同一 feed 取该分支**最新 patch** 的 `downloads.linux.link` → `2026.1.5`
   （`https://download.jetbrains.com/idea/idea-2026.1.5.tar.gz`）。
   取最新 patch 而非精确的 `.1`，因为 JBR/原生库只需匹配分支，新 patch 更安全；
   下月 `2026.1.6` 发布会自动取到，无需改脚本。

无硬编码版本映射表——feed 直接把 build 前缀映射到版本。

**`-a/--ideaver` 改为可选覆盖**：提供时直接跳过 feed 探测，原样使用。纯本地
模式（`--no-download`）下若未给 `-a` 会直接报错（无法联网解析）。

## 组件版本对照 + 破坏性差异告警（防窜台）

构建时 `echo_version_comparison()` 打印三列表（Mac DMG / IDEA 各组件并排）：

```
================ 组件版本对照（Mac DMG vs IDEA） ================
  组件               | Mac DMG                      | IDEA
  DevEco Studio        | 26.0.0.621                   | 2026.1.5
  IDEA 构建号       | 261.23567.138.36.2600621     | IU-261.23567.138
  JBR Java 版本      | 25.0.2                       | 25.0.3
  JBR 构建号        | JBR-25.0.2+10-329.117-nomod  | JBR-25.0.3+9-508.16-nomod
```

破坏性差异判定（Mac vs IDEA 不一致则整行**标红**并附 `[破坏性差异]`）：

- `JBR Java 版本`：主版本号不同（如 21 vs 25）或版本串不同 → 标红；
- `JBR 构建号`：同上判定 → 标红；
- `IDEA 构建号`：比大版本（第一段，如 `261`）；仅第一段不同 → 标红；后续段（`.23567.138` vs `.27258.48`）允许不同，不标红；
- `DevEco Studio` / `IDEA 版本`：本就不同，**永不标红**。

Mac 自带 JBR 在解 DMG 时被排除，故 `dump_mac_jbr_version()` 临时从
`build/work/mac_zip/*.dmg` 抽取 `jbr/Contents/Home/release` 读出。

随后 `audit_idea_consistency()` 审计 Mac `build.txt`（`DS-261...`）与 IDEA
tarball `build.txt`（`IU-261...`）的**大版本（第一段）**；仅第一段不同才 `die`，
杜绝把 Mac DMG 配错 IDEA 大版本（如 260 配 261）。后续段不同（同大版本下的不同
小构建号）属正常，放行。
DMG 配错 IDEA 快照（否则只有 JBR/原生库错位，产出坏包）。

## 魔法，按区域

### Emulator（`Emulator.exe` 软链）

华为代码（`LocalDeviceConnection.getEmulatorPathName`）只区分 **Mac vs 非 Mac**，
非 Mac 分支硬编码 `Emulator.exe`。Linux 上二进制叫 `Emulator`，无软链则 Device
Manager 每次操作失败（"get emulator status failed"）、调试报 "emulator file ...
is missing"。包内提供 `tools/emulator/Emulator.exe -> Emulator`。

软链带来的两个后果：
- cleanup 清理 `.exe` 时必须保留它：`find ... -name '*.exe' -not -name 'Emulator.exe' -delete`；
- emulator 二进制本身来自 **CLI** zip（Linux ELF），不是 Mac DMG（Mach-O）。

### Emulator 系统镜像

IDE 的「安装模拟器」向导仅在二进制缺失时出现，且会同时下二进制+系统镜像。我们
打包了二进制，向导永不触发——系统镜像是唯一缺的件，须手动取：
`Emulator -install -deviceType phone -osVersion "<ver>"`（匿名），或把别的平台
的装到 `~/.Huawei/Sdk/system-image/`。

### Emulator 路径（`~/Library/Huawei/Sdk`）

emulator 二进制硬编码 macOS 风格路径 `~/Library/Huawei/Sdk`。启动器包装脚本每
次启动桥接：`ln -sfn "$HOME/.Huawei/Sdk" "$HOME/Library/Huawei/Sdk"`。同样的桥
也写进 `tools/bin/Emulator` CLI 包装，使纯 CLI 用户不启动 IDE 也能用正确路径。
emulator 还需 `QT_QPA_PLATFORM=xcb`（只带 xcb 插件，无 wayland）。

> 移植到 Linux：`~/Library` 是 macOS 专属目录，可通过环境变量
> `DEVECO_LIBRARY_DIR` 重定向（默认 `$HOME/Library`）。桥接与清理都只针对其下的
> `Huawei` 子目录，**绝不误删整个 `~/Library`**。

**真实数据不在 macOS 前缀下**：SDK / 模拟器的实际文件存放在 Linux 原生的
`~/.Huawei/Sdk`（由 CLI 工具与 IDE 直接读写），macOS 风格的 `~/Library/Huawei/Sdk`
只是一层**软链壳**（`→ ~/.Huawei/Sdk`），因 emulator 二进制硬编码该路径而存在，
本身不存储数据。故 `--clear-env` 只清 IDE 配置/缓存、不碰 `~/.Huawei`；SDK /
模拟器数据由 `--clear-sdk` 单独清理（含二次确认），且只删真实目录与其软链，不误删
`~/Library` 其它内容。

### Emulator 软件协议（自动接受）

IDE 直接拉起 emulator 二进制、绕过 CLI 包装；若从未接受协议，emulator 会静默等
stdin 的 `y`，IDE 看似卡死（经典"跑过一次 CLI 才能用"陷阱）。协议状态在
`~/Library/Caches/Huawei/Emulator26.0/.emu_config`（`Emulator -license accept`
写入）。`Emulator` 包装脚本因此：

```bash
_emu_config="$HOME/Library/Caches/Huawei/Emulator26.0/.emu_config"
if [[ ! -f "$_emu_config" ]]; then
    "$all_tool_dir/emulator/Emulator" -license accept
    exit 0   # 原命令不转发，重跑即可
fi
```

只检查**存在性**不检查内容，用户可 `> .emu_config` 截断以退出自动接受。

### Device Manager GUI（已知限制 + 破坏性陷阱）

DevEco Device Manager GUI 依赖华为云设备模板，Linux 构建不随包提供，故面板
「本地模拟器/我的设备」列表**空白**，无法在 GUI 创建/选择设备。改用 CLI：
`tools/bin/Emulator -create/-start/-stop/-list`。

**破坏性陷阱**：打开 IDE Device Manager（或触发其设备扫描）会**清空**
`~/.Huawei/Emulator/deployed/` 目录，丢弃 CLI 创建的设备（`myPhone/`、`myPhone.ini`、
`lists.json`），只留占位文件，CLI `-list` 随之报 `[Empty]`。要保留 CLI 设备
**勿开 IDE Device Manager**；被清则从备份恢复 `deployed/`，或重跑 `-create`。

### Previewer：Linux 不可用（如何得知）

预览器（on-device preview）是 Linux 上唯一无法工作的主功能。结论来自对 CLI 的
`Previewer` ELF 的反汇编，而非猜测：

1. `strings` 抓到铁证：`JsApp::Run ability start failed.Linux is not supported.`；
   `objdump -d` 显示失败是**编译进**的——`RunDebugAbility` 仅 45 字节桩，只调
   `PrintLog` 打那句；相邻的 `RunNormalAbility` 是完整 1302 字节实现。调试路径
   （IDE 总走、传 `-d`）在 Linux 构建里被 `#ifdef` 掉了。
2. 分支运行时才选：`RunJsApp` 读调试标志（`cmpb 0xaa(%r14)`），由命令行
   `CommandParser::IsSet("d")` → `JsApp::SetIsDebug(true)` 设置。
3. 去掉 `-d`（走 `RunNormalAbility`）反而崩：在 `RSUIContextManager` 构造里
   SIGSEGV，经 `Window::Create → RSUIDirector::Init`，那是 Rosen **渲染服务
   客户端**——只存在于鸿蒙设备，不在桌面 Linux。

故预览器被上游双重阻断：调试预览编译掉，非调试路径死在渲染服务客户端。两者都非
打包可修。（红鲱鱼：预览器还因缺 `libshared_libz.so`/`libhilog.so` 失败，但补上
只让它走到"Linux is not supported"。）

### Node.js 布局（三条软链，不拷真文件）

CLI 的 `tool/node/` 是上游 node tarball 布局：真二进制在 `bin/`，npm 在
`lib/node_modules/npm`。还需三层：

1. **顶层工具软链**：`node`/`npm`/`npx`/`corepack` → `bin/*`（IDE 的 File Watcher
   等调 `<nodeDir>/npm`）。
2. **`tools/node/node_modules -> lib/node_modules`**：满足 IDE npm 检查的 Windows 分支。
3. **`tools/lib/node_modules -> ../node/lib/node_modules`**：真正的 Linux 修复。IDE
   的 `getNpmVersionFast`（`NodeConfigUtil`）在 Linux 上**只**读
   `<nodeDir>/../lib/node_modules/npm/package.json`（即 `tools/lib/node_modules/...`），
   上游 node 布局永远不满足。缺它则每次同步报 *"Invalid project Node.js path ...
   Node.js 24.x is recommended"* 并中断同步（`SyncInterruptException`）。

### CLI 工具包装脚本（三处 sed 改写）

CLI zip 的 `bin/` 包装（`hvigorw`/`ohpm`/`hstack`/`codelinter`/`Emulator`）用
`cd "$(dirname "$0")"` 解析自身再向上找工具。三修：

1. **`dirname "$0"` → `dirname "$(readlink -f "$0")"`**：经 `/usr/bin` 软链调用时
   `$0` 是 `/usr/bin/<tool>`，`dirname` 解析到 `/usr/bin` 而找错地方（与旧的
   `/usr/bin/devecostudio` 递归同类 bug）。
2. **`$all_tool_dir/tool/node` → `$all_tool_dir/node`**、**`$all_tool_dir/sdk` →
   `$all_tool_dir/../sdk`**：包装假设 `bin/` 与 `tool/`、`sdk/` 同级；我们拷到
   `tools/bin/` 后 node 是 `tools/node`、sdk 是 `tools/` 父级。
3. **codelinter 内部启动器**（`tools/codelinter/bin/codelinter`）硬编码
   `$ROOT_PATH/tool/node` 与 `$ROOT_PATH/sdk`（ROOT_PATH=`tools/`）。不建
   `tools/tool/node` 软链（像第二个 node 安装，会乱 IDE 的 node 发现），而是改写
   脚本本身为 `$ROOT_PATH/node` / `$ROOT_PATH/../sdk`。

### /usr/bin 暴露

`devecostudio` 总链到包装脚本。五个 CLI 工具仅在 `--expose-cli` 时生成
`install-cli-tools.sh` 链入 `/usr/local/bin`；`hvigorw`/`ohpm`/`hstack` 用原名，
`codelinter`/`Emulator` 加 `h` 前缀（`hcodelinter`/`hemulator`）。

### vmoptions 转换

`bin/devecostudio64.vmoptions` 由 Mac `devecostudio.vmoptions` sed 转换：
- `-Dsun.java2d.metal=true` → `-Dsun.java2d.opengl=true`
- 丢 `-Djava.security.manager` 与 `-Dwsl` 行
- 追加 `-Dawt.lock.fair=true`、`-Dsun.tools.attach.tmp.only=true`、
  `-Dglfw.im.module=fcitx`（JBR 25 的 GLFW IME 模块）

`product-info.json` 非静态文件——从 DMG 抽出后构建期用 `jq` 转换：OS/arch/
launcher/java/vmoptions 路径改写（`$APP_PACKAGE/Contents/` → `$IDE_HOME/`），
过滤 macOS 专属 `--add-opens`（com.apple.*、sun.lwawt），追加 Linux add-opens
（sun.awt.X11、com.sun.java.swing.plaf.gtk）与 native-access 标志，
`startupWmClass=deveco-studio`。202 项的 `bootClassPathJarNames` 直接来自 DMG，
jq 过滤器从不硬编码。

### JBR 与原生库

JBR 整体替换为 IDEA Linux JBR（`jbr/`）。原生库按目录替换：`lib/native/linux-x86_64`、
`lib/pty4j/linux`、`lib/jna/amd64/libjnidispatch.so`、`lib/skiko-awt-runtime-all`
（26.0.0 新增该目录；Mac DMG 是 `.dylib`，换成 Linux 版）。保留 mac 风格
`jbr/Contents/Home/bin` 软链，因部分华为插件硬编码该路径。

### JCEF / CEF UI 在 Wayland 下

CEF UI（项目结构对话框、markdown 预览）在 Wayland 下 GPU 进程崩：`eglCreateWindowSurface`
在 `jcef_helper` GPU 进程里段错误，被 IDE 判为 GPU 进程反复重启。包装默认强制 X11
后端（`unset WAYLAND_DISPLAY`、`GDK_BACKEND=x11`），走 XWayland/GLX 即正常。
用 `DEVECO_DISABLE_X11_WORKAROUND=1` 退出（CEF 页面会坏）。

### X11 / XWayland HiDPI

XWayland 给 JBR 报显示器 scale 1.0（缺逐显示器 RANDR 信息），JRE 管 HiDPI 时 IDE
把 UI scale 锁 1.0——HiDPI 屏上太小。两点关键：

- `-Dide.ui.scale`（IntelliJ 属性）强制 IDE scale；光 `sun.java2d.uiScale` 不行
  （逐显示器模式覆盖它）。
- JCEF 浏览器 scale 经 `JBCefApp.getForceDeviceScaleFactor()` 跟随 IDE scale：
  JRE HiDPI 开时返回 -1（Chromium 自测——好）；关时返回 `ScaleContext.PIX_SCALE`
  （IDE scale——仅当 IDE scale 正确才对）。故关 JRE HiDPI 修 Swing UI 却让 JCEF 巨大。

包装读合成器 scale（`wlr-randr`；需 `WAYLAND_DISPLAY`，故在 X11 绕行 unset 前跑），
舍入到最近 1/4 步，写入一行用户 vmoptions 覆盖，经 `DEVECOSTUDIO_VM_OPTIONS`
注入（原生启动器读它并与系统 vmoptions 合并）。`DEVECO_UI_SCALE` 覆盖（任意数原样；
`off` 跳过注入，交 JVM）。

### 权限与可执行性

Mac DMG 文件 ship 700，`cp -a` 保留，故包内先全局 `chmod 755` 目录、`644` 文件，
再补执行位。补位用 **head 读前字节**（ELF 魔法 `\x7fELF` 或 shebang
`#!` 在前 4KB 任意位置，如 `hstack` 版权注释在 `#!` 前）——`file` 曾在大树上
SIGSYS 崩溃，静默漏掉 `jspawnhelper`/`Emulator`/`node` 的 +x，导致子进程
`posix_spawn: EACCES`。

**关键顺序陷阱**：`fix_permissions` 必须在 IDEA JBR 树拷入 `$pkg` **之后**跑。
JBR 的 `jbr/bin/java`（及每枚 `jbr/` 下 ELF：`jspawnhelper`、`cef_server`）是原生
启动器 exec 起来 boot JVM 的——`java` 不可执行，IDE 启动报 *"Cannot find a
runtime / Runtime not found"*。IDEA tarball 解出的文件有时缺 +x，`cp -a` 保留之。
故 `fix_permissions` 须**最后**扫整树（在 `assemble()` 的 JBR 拷贝后），绝不早跑。

**同陷阱适用于 SDK 树**（`cp_tree "$cli/sdk/."`）：SDK 在 `ets/build-tools/.../bin/ark/build/bin/`
下的 Linux 原生 Ark 编译器（`es2abc`、`ark_aot_compiler`、`merge_abc`、`profdump`、
`panda_guard`、`js2abc`）是 hvigor `CompileArkTS` 时要 exec 的——缺 +x 则构建报
*"/bin/sh: ... es2abc: 权限不够"*（EACCES）。SDK 拷贝也须在 `fix_permissions` 前。
`assemble()` 中 JBR / 原生库 / SDK 先全拷，再 `fix_permissions` 扫一次整树。

### Strip

手动选择性 strip（JBR 二进制、启动器、原生 `.so`、fsnotifier）。SDK 刻意**不** strip
（含交叉编译 ARM 二进制）。

### Cleanup 清理

删 `*.exe`（除 `Emulator.exe`）、`*.dll`、`*.dylib`、`*.jnilib`、`*.bat`、`*.ps1`。
`*.sh` 清理限 `bin/`、`tools/bin/`、`plugins/`——一刀切曾删掉真 SDK 内容
（`llvm/bin/lldb.sh`、cmake `Squish*.sh`）。

### `ohos-trace` 插件删除

`plugins/ohos-trace` 删除；它带 "lemon" 插件 bug（退出挂死）。

### UxTestService

DMG 内跨平台 Python 工具，来自 DMG 非 CLI。

## 运行时布局（解压后）

```
<dir>/
├── bin/
│   ├── devecostudio            ← IDEA 原生启动器（已 strip）
│   ├── devecostudio.sh         ← 包装（环境设置 + 路径桥）
│   ├── devecostudio.svg
│   ├── devecostudio64.vmoptions
│   ├── idea.properties
│   └── fsnotifier
├── jbr/                        ← IDEA Linux JBR（+ Contents/Home/bin 软链）
├── lib/                        ← DMG jars + native/linux-x86_64 + pty4j + jna + skiko
├── modules/
├── plugins/
├── sdk/                        ← CLI SDK（hdc 在 sdk/default/openharmony/toolchains/hdc）
├── license/
├── build.txt
├── product-info.json           ← jq 转换自 DMG
└── tools/
    ├── bin/                    ← CLI 包装（readlink 修复）
    ├── node/ + lib/node_modules（上两条软链）
    └── hvigor/ ohpm/ hstack/ codelinter/ emulator/ UxTestService/
```

包装（`devecostudio.sh`）职责，按序：
1. `_JAVA_AWT_WM_NONREPARENTING=1`
2. `QT_QPA_PLATFORM=xcb`（emulator Qt）
3. JCEF 的 X11 后端（除非 `DEVECO_DISABLE_X11_WORKAROUND=1`）
4. `~/Library/Huawei/Sdk` → `~/.Huawei/Sdk` 桥（emulator 镜像）
5. 经 `readlink -f` 于 `$0` exec 真启动器（经 `/usr/bin` 软链也能工作）

## build.sh 参数速查

```
  -m, --mac MAC           Mac 源：本地路径或 http(s):// 地址（构建必填，文件名/地址含版本号）
  -c, --cli CLI           CLI 工具源：本地路径或地址
  -i, --idea IDEA         IDEA 源：本地路径或地址；省略则自动解析下载
  -v, --pkgver PKGVER     DevEco Studio 版本；省略时从 Mac 源文件名/地址提取
  -a, --ideaver IDEAVER   IDEA 基线版本（可选覆盖；省略则按 Mac buildNumber 经 feed 取最新 patch）
  -x, --expose-cli        额外生成 install-cli-tools.sh，链 CLI 工具入 /usr/local/bin
  -n, --no-download       纯本地模式：三源皆须本地提供，禁联网
  -I, --install DIR        组装后直接装到指定目录（免打包）
  -P, --no-package        跳过打包 tar.gz（常配 --install）
  --clear-all              清 build/work/ 与 build/cache/ 后退出
  --clear-build            清整合包与 mac_fixed，保留解压源与下载缓存
  --clear-env              清 IDE 配置/缓存/状态与桌面项（不碰 SDK/模拟器）
  --clear-sdk              清 SDK 与模拟器（含二次确认）
  -h, --help               帮助
```

## 维护清单

### 新 DevEco Studio 发布

1. 从华为取新版 `devecostudio-mac-<v>.zip` + `commandline-tools-linux-x64-<v>.zip`
   （签名、会过期链接）。
2. **先分析实际布局**（规则：勿信从上一版继承的路径）：`7z l`/`7z x` DMG，diff
   `lib/`、`plugins/`、`tools/`，读新 `Resources/product-info.json`（`buildNumber`
   → 自动解析的 IDEA 基线）。上游跨版会挪东西（如 26.0.0 把 jars 全摊进 `lib/`、
   去 `lib/modules`+`lib/cds`、加 `lib/skiko-awt-runtime-all` 与 `tools/dumpParser`
   Mach-O 排除）。
3. （无需手改 IDEA 版本）构建脚本自动从 `buildNumber` 解析。
4. 跑测试清单。

### 测试清单（构建后）

- [ ] `devecostudio.sh --version` 打印正确 build
- [ ] 项目打开；hvigor **同步**成功（无 Node.js 路径告警）
- [ ] CEF UI 正常：项目结构对话框、markdown 预览
- [ ] Device Manager：emulator 列表加载；CLI 创建/启动/停止/编辑/删除
- [ ] Run 面板从 emulator 调试
- [ ] 五个 CLI 工具：`hvigorw --version`、`ohpm --version`、`hstack --version`、
      `hcodelinter --version`（若 `--expose-cli`）、`hemulator --version`
- [ ] `hdc list targets` 见到运行中的 emulator

## 已知上游怪癖 / 陷阱

- **华为 zip 内套 zip**：`devecostudio-mac-*.zip` 内含 `.dmg`。`extract_mac_dmg`
  用 `find` 找 `.dmg`。
- **`7z x` "Dangerous link path" 警告**：排除 `Contents/jbr` 后消失。
- **`file` 在大树 SIGSYS 崩溃**：用 head 字节扫描判执行位。
- **`ln -sf bin/*` 从错 cwd**：静默建坏 `bin/*` 软链——始终 `(cd dir && ln -sf ...)`。
- **`find ... -name '*.sh' -delete` 一刀切**是雷（伤 SDK 内容）——保持限定范围。
- Wayland：JCEF GPU 进程崩；用 X11 绕行。
