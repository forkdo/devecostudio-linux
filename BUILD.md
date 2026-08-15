# 通用发行版构建脚本（build.sh）

本目录原来的 `PKGBUILD` 只适用于 Arch Linux。为了让 Ubuntu / Fedora 等任意
发行版都能用，这里提供一个 **Bash 构建脚本**，产出**解压即用**的通用
tarball（类似 `idea-*.tar.gz` / `android-studio-*.tar.gz`）：

- 解压到**任意位置**（如 `~/apps`、`/opt`）即可运行，**不绑定 `/opt`**；
- 启动入口为 `<解压目录>/bin/devecostudio.sh`，内部用 `readlink -f` 解析自身，
  因此放哪都能跑；
- **不再需要 `.desktop` 文件**（自包含目录自带图标与启动逻辑）。

打包逻辑与 `DETAILS.md` 中记录的所有「魔法」完全一致，用 Bash 重写、
并支持把三个上游源以本地文件传入，便于反复测试、不重复下载大文件。

## 三个上游源

| 源 | 内容 | 来源 |
|---|---|---|
| `devecostudio-mac-<ver>.zip`（内含 `.dmg`） | 平台无关的 Java 代码、插件、模块、`product-info.json`、`UxTestService` | 华为官网 Mac 版 |
| `commandline-tools-linux-x64-<ver>.zip` | 鸿蒙 SDK，`node`/`hvigor`/`ohpm`/`hstack`/`codelinter`/`emulator` 等 Linux 原生工具（**内含符号链接**，必须用 `bsdtar` 解压） | 华为官网 Linux 命令行工具 |
| `idea-<ideaver>.tar.gz` | Linux JBR、原生启动器 `fsnotifier`、`.so` 原生库 | JetBrains CDN（自动下载） |

> 华为两个链接是签名且会过期的，需你手动从
> <https://developer.huawei.com/consumer/cn/devecostudio/> 下载后重命名。

## 目录布局

所有产物固定写在脚本同级的 **`build/`** 目录下：

```
build/
├── cache/   # 下载的源归档（devecostudio-mac.zip、commandline-tools-linux-x64.zip、idea-*.tar.gz），跨次复用
├── work/    # 中间解压产物（mac_dmg/、cli/、idea/、devecostudio-<ver>/），跨次复用，避免重复解压
└── out/     # 最终产物（tarball，可选 install-cli-tools.sh）
```

- 中间产物**默认保留**：第二次用本地包构建时直接复用 `build/work/` 与
  `build/cache/`，不再解压、不再下载，省时省资源。
- 想强制重新解压/下载：运行 `./build.sh --clean` 清除
  `build/work/` 与 `build/cache/` 后退出（最终产物 `build/out/` 保留）。

## 用法

`-m` / `-c` / `-i` 既可传**本地路径**，也可传 **`http(s)://` 下载地址**，脚本自动判断：

- 以 `http://` 或 `https://` 开头 → 视为 URL，下载并缓存到 `build/cache/`；
- 否则视为本地路径，文件必须存在（不存在直接报错退出）。

### 1. 本地包传入（推荐用于反复测试）

把三个文件准备好，用参数指给脚本即可。**未传入的源才会从网络下载**，
且下载后缓存到 `build/cache/`，下一次运行直接复用：

```bash
./build.sh \
    --mac  devecostudio-mac.zip \
    --cli  commandline-tools-linux-x64.zip \
    --idea idea-2026.1.3.tar.gz
```

- 只想本地测、**完全不下载**：加 `--no-download`，缺任何一个本地文件就报错退出。
- 改版本：用 `--pkgver 26.0.0.621 --ideaver 2026.1.3`（影响 IDEA 下载 URL 与产物名）。
- 版本号省略时，自动从 Mac 源文件名/地址中提取（如 `devecostudio-mac-6.1.1.300.zip`
  提取出 `6.1.1.300`）。
- 清除中间产物/缓存：加 `--clean`（详见上文「目录布局」）。

### 2. 直接给下载地址（或混合）

`-m` / `-c` 直接传华为链接即可（不再有独立的 `--mac-url` / `--cli-url`）；
`-i` 省略时按 `--ideaver` 从 JetBrains CDN 自动拼接下载地址：

```bash
./build.sh \
    --mac  "https://.../devecostudio-mac-26.0.0.621.zip" \
    --cli  "https://.../commandline-tools-linux-x64-26.0.0.621.zip"
```

本地路径与 URL 也可混用，例如本地 Mac 包 + 远程 CLI 工具。

### 3. 产出

```
build/out/devecostudio-<pkgver>-linux-x86_64.tar.gz
```

解压即用：

```bash
tar -xzf devecostudio-<pkgver>-linux-x86_64.tar.gz -C ~/apps
~/apps/devecostudio-<pkgver>/bin/devecostudio.sh
```

### 4. 构建、打包、安装分三步（可复用）

脚本内部把「最后一步」拆成了 **打包 tar.gz** 与 **安装到指定目录** 两个动作，
二者都基于同一个已组装好的应用树（`build/work/devecostudio-<pkgver>/`），
因此你可以只做其中一个：

| 目标 | 参数 | 说明 |
|---|---|---|
| 打包成 tar.gz（默认） | _(不加任何开关)_ | 产出 `build/out/devecostudio-<pkgver>-linux-x86_64.tar.gz` |
| 直接安装到目录 | `--install DIR` | 把应用树复制到 `DIR`（成为应用根目录，含 `bin/`、`jbr/` 等），本地使用免打包 |
| 安装的同时跳过打包 | `--install DIR --no-package` | 本地调试最省时：只组装 + 复制，不生成 tar.gz |
| 两者都做 | `--install DIR` | 既安装又打包 |

典型用法：

```bash
# 只想本地用，不打包（最快）：组装后直接装到 ~/apps/devecostudio
./build.sh --mac devecostudio-mac.zip \
    --cli commandline-tools-linux-x64.zip \
    --install ~/apps/devecostudio --no-package

# 运行
~/apps/devecostudio/bin/devecostudio.sh
```

> 组装树（`build/work/devecostudio-<pkgver>/`）跨次复用：第一次用本地包
> 构建后，后续 `--install` / 打包直接复用，无需重新解压。要强制重来用
> `--clean`。

## CLI 工具是否在 PATH 上

默认**不**把 `hvigorw`/`ohpm`/`hstack`/`codelinter`/`Emulator` 链入系统
`/usr/bin`（通用包不应擅自改动系统路径）。它们始终在
`<解压目录>/tools/bin/` 下，IDE 运行时会自己找到。

若你希望像原 Arch 包那样把它们也暴露到 PATH，加 `--expose-cli`：

```bash
./build.sh --mac ... --cli ... --expose-cli
```

这会额外在 `build/out/` 生成一个 `install-cli-tools.sh`，运行（需 root）后把工具链到
`/usr/local/bin`（其中 `codelinter`/`Emulator` 默认加 `h` 前缀：`hcodelinter`/`hemulator`，
与原 PKGBUILD 的 `_hprefix_generic_tools` 行为一致）。

## 依赖

- `bash`（构建脚本本身，仅 Linux）
- 外部工具：`7z`（p7zip，解 Mac DMG）、**`bsdtar`（解 CLI zip，必须能保留符号链接）**、
  `jq`、`tar`、`strip`、`curl` 或 `wget`（下载）

  > `bsdtar` 来自 libarchive 项目。发行版打包不同：Arch 上随 `libarchive` 包提供，
  > 而 **Fedora / RHEL 上是独立包 `bsdtar`**（仅靠 `libarchive` 库包不会装到该命令），
  > 需用 `sudo dnf install bsdtar` 安装。Debian/Ubuntu 上同样有独立包 `bsdtar`。
- 运行时系统库（解压后运行需要）：`libxss` `libxtst` `nss` `alsa-lib`
  `libxcrypt-compat` `freetype2` `libpulse`；中文输入法需 `fcitx5`

> 为什么 CLI zip 必须用 `bsdtar`：`7z` 会因 zip 内含的「危险链接」直接拒绝解压
> （exit 2），`unzip` 则会把符号链接（如 `node/bin/npm -> ../lib/node_modules/npm/bin/npm-cli.js`、
> `llvm/bin/clang++ -> clang`）损坏成普通文本文件，导致 IDE 同步失败。只有
> `bsdtar`（libarchive）能正确保留符号链接。

## 与 PKGBUILD 的关系

`PKGBUILD` 仍保留给 Arch 用户使用，两者并存。通用构建脚本不产出
`*.pkg.tar.zst`，也不产出 `.desktop`。所有平台相关的逆向/适配细节见
`DETAILS.md`。

## 已知限制（同 PKGBUILD）

- **Previewer（预览器）在 Linux 上不可用**：华为未移植 Rosen 渲染引擎。
- 模拟器系统镜像需手动下载（见主 `README.md` 的 Emulator 章节）。
- 仅测试过 `pkgver`/`_ideaver` 默认值对应的版本；换版本请自行验证。

## 模拟器运行注意事项（Linux 特有问题，已打包层处理）

DevEco 的模拟器在 Linux 上有几个上游怪癖，本脚本已在启动器
`bin/devecostudio.sh` 与 `fix_permissions` 中处理，这里记录以便维护时理解。

### 1. Emulator 二进制需要执行权限

`tools/emulator/Emulator` 是 360M+ 的 Linux 原生 ELF，但 CLI zip 解压后
可能不带执行位。`fix_permissions` 除按 ELF 魔法字节扫描补 `+x` 外，还会对
已知原生二进制（`tools/emulator/Emulator`、`bin/fsnotifier`、`bin/devecostudio`）
**显式 `chmod +x`**，避免超大文件字节扫描偶发漏判导致模拟器无法启动。

> `tools/bin/Emulator` 与 `tools/emulator/Emulator` 不是重复文件：前者是
> CLI 工具链里的 **bash 包装脚本**（经 `fix_cli_wrappers` + `patch_emulator_wrapper`
> 修复路径、补桥接与协议自动接受后转发），后者才是**真实二进制**。
> 包装脚本本身已 `export QT_QPA_PLATFORM=xcb`，直接调二进制或经 wrapper 调用
> 都应能正常弹出模拟器窗口。

### 2. 系统镜像目录必须真实存在（`~/Library/Huawei/Sdk` 软链桥）

Emulator 二进制**硬编码** macOS 风格路径 `$HOME/Library/Huawei/Sdk` 作为系统
镜像目录（上游闭源，无法改）。启动器在建立软链前会先
`mkdir -p "$HOME/.Huawei/Sdk"`，再 `ln -sfn` 把它桥到 `~/Library/Huawei/Sdk`，
从而：Emulator 按硬编码路径读写，真实数据落在 Linux 习惯的 `~/.Huawei/Sdk`。

**注意**：`$HOME/.Huawei/Sdk` 真实目录必须先存在，否则软链悬空，Emulator
下载镜像时会报 `can not open or write file`。启动器已自动建好；若你**绕过
启动器直接跑 `Emulator`**，需自行 `mkdir -p ~/.Huawei/Sdk`。

### 3. 系统镜像需手动下载

模拟器二进制只随 CLI 提供，系统镜像不会自动带。下载（匿名、挑 phone 设备）：

```bash
~/.local/devecostudio/tools/emulator/Emulator -install -deviceType phone -osVersion "HarmonyOS 6.1.1(24)"
```

镜像落到 `~/.Huawei/Sdk/system-image/`（经软链即 `~/Library/Huawei/Sdk/system-image/`）。
可用版本用 `-imageList` 查询。

### 4. Qt 平台插件必须是 xcb（不是 wayland）

模拟器只自带 `libqxcb.so`（X11/xcb 平台插件），**没有** wayland 插件。
在 Wayland 会话里环境变量通常带 `WAYLAND_DISPLAY`，Qt 会默认去找 wayland
插件，于是启动即报：

```
qt.qpa.plugin: Could not find the Qt platform plugin "wayland" in ""
```

修复：强制 Qt 用 xcb，`QT_QPA_PLATFORM=xcb`。本脚本在两处都设好了：

- IDE 启动器 `bin/devecostudio.sh`（`export QT_QPA_PLATFORM=xcb`），
  因此从 IDE 内点「运行」启动的模拟器正常；
- `tools/bin/Emulator` 包装脚本（`patch_emulator_wrapper` 注入
  `export QT_QPA_PLATFORM=xcb`），因此命令行 `hemulator -start xxx` 也正常。

**注意**：若你直接调用真实二进制 `tools/emulator/Emulator`（绕过包装脚本），
需自己 `export QT_QPA_PLATFORM=xcb`，否则会撞上面的 wayland 错误。

另：Fedora 等较新 glib 上会打印
`Failed to load plugin: '/lib64/libgobject-2.0.so.0: undefined symbol: g_dir_unref'`
并 `No plugins found, falling back on no decorations` —— 这是模拟器自带 Qt
与系统 glib 版本错配导致的窗口装饰插件加载失败，**回退到无标题栏模式，
不影响启动与运行**，属非致命噪音。

### 5. Device Manager 左侧列表/规格选择在 Linux 上空白

DevEco 的 Device Manager 图形界面依赖华为云下发的预设设备模板/规格，
这部分在 Linux 构建里不随包提供，因此 IDE 内打开 Device Manager 时
左侧「本地模拟器列表」与「规格选择」为空、无法在 GUI 里创建模拟器。
这是上游 Linux 构建的固有限制，打包层无法补齐。

**破坏性陷阱（重要）**：在 Linux 上打开 Device Manager 图形界面，IDE 会
**重写** `~/.Huawei/Emulator/deployed/` 目录，把其中用 CLI 创建的本地
模拟器（如 `myPhone`）一并清空。现象是「我的设备」处没有可选项、CLI
`-list` 返回 `[Empty]`。因此：

- **不要打开 IDE 的 Device Manager 来管理已存在的 CLI 模拟器**，否则设备
  会被静默删除；
- 若已被清空，从备份恢复 `deployed/` 下对应的 `<设备名>/`、`<设备名>.ini`、
  `lists.json` 即可（CLI `-list` 立即恢复显示）。

绕过方式：用 CLI 创建/启动/停止模拟器（包装脚本已处理路径与 xcb）：

```bash
# 创建（首次会提示接受软件协议，接受后重跑即可）
hemulator -create myPhone -deviceType phone -osVersion "HarmonyOS 6.1.1(24)"
# 启动 / 停止 / 列表
hemulator -start   myPhone
hemulator -stop    myPhone
hemulator -list
```

模拟器窗口正常弹出后，IDE 的 Run/Debug 面板即可选它作为运行目标。


