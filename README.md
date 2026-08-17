# DevEco Studio — 通用发行版构建脚本（build.sh）

> 跨发行版、解压即用的 DevEco Studio 通用 tarball 构建器。
> 基于华为 Mac DMG + Linux 命令行工具 + IntelliJ IDEA 的 Linux 组件重新组合。
>
> Arch Linux 专用打包（PKGBUILD）已移至 [`arch/`](arch/) 目录。本文件描述
> 全新的 `build.sh` 通用构建脚本。

`build.sh` 把三个上游源重新组合成一个**解压即用**的目录树（类似
`idea-*.tar.gz` / `android-studio-*.tar.gz`）：

- 解压到**任意位置**（如 `~/apps`、`/opt`）即可运行，**不绑定 `/opt`**；
- 启动入口为 `<解压目录>/bin/devecostudio.sh`，内部用 `readlink -f` 解析自身，
  因此放哪都能跑；
- **不再需要 `.desktop` 文件**（自包含目录自带图标与启动逻辑）。

所有平台相关的逆向/适配细节见 [`AGENTS.md`](AGENTS.md)。

## 三个上游源

| 源 | 内容 | 来源 |
|---|---|---|
| `devecostudio-mac-<ver>.zip`（内含 `.dmg`） | 平台无关的 Java 代码、插件、模块、`product-info.json`、`UxTestService` | 华为官网 Mac 版 |
| `commandline-tools-linux-x64-<ver>.zip` | 鸿蒙 SDK，`node`/`hvigor`/`ohpm`/`hstack`/`codelinter`/`emulator` 等 Linux 原生工具（**内含符号链接**，必须用 `bsdtar` 解压） | 华为官网 Linux 命令行工具 |
| `idea-<ideaver>.tar.gz` | Linux JBR、原生启动器 `fsnotifier`、`.so` 原生库 | JetBrains CDN（自动下载，或本地提供） |

> 华为两个链接是签名且会过期的，需你手动从
> <https://developer.huawei.com/consumer/cn/deveco-studio/> 下载，无需重命名
> （可直接把下载地址或文件路径传给脚本，见下文「用法」）。
> IDEA 源**默认由脚本从 Mac 的 `buildNumber` 自动解析**，一般无需手动处理；
> 如需手动下载，Linux 版下载页面为 <https://www.jetbrains.com/idea/download/?section=linux>。

## IDEA 版本自动解析（无需手填）

IDEA 基线**不再手填**。Mac DMG 的 `product-info.json` 带有 `buildNumber`
（如 `261.23567.138.36.2600621`），其前三段 `261.23567.138` 正好是某个
IntelliJ IDEA release 的 `build` 字段（→ `2026.1.1`）。脚本据此：

1. 读 `buildNumber`，取前三段；
2. 查 JetBrains releases feed，找到匹配的 IDEA 版本 → 得到分支 `2026.1`；
3. 取该分支**最新 patch**（如 `2026.1.5`，而非 `.1`），直接读其
   `downloads.linux.link` 下载。

下个月 `2026.1.6` 发布时会自动取用——**除非你用 `-a` 显式覆盖**：

```bash
./build.sh --mac ... --cli ... --ideaver 2026.1.5   # 可选覆盖，跳过自动探测
```

构建时脚本会回显 **组件版本对照表**（DevEco 版本 / IDEA 构建号 / JBR 版本
Mac vs IDEA 三列并排），破坏性差异（如 Mac 自带 JBR 21 而 IDEA 是 25）会
**整行标红**并告警，防止窜台；随后还会审核 Mac `build.txt` 与 IDEA tarball
`build.txt` 的构建号前缀一致性，不一致直接中止。

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
- 想强制重新解压/下载：`./build.sh --clear-all` 清除 `build/work/` 与
  `build/cache/` 后退出（最终产物 `build/out/` 保留）。
- 仅清除整合包（保留解压源与下载缓存）：`./build.sh --clear-build`。

## 用法

`-m` / `-c` / `-i` 既可传**本地路径**，也可传 **`http(s)://` 下载地址**，脚本自动判断：

- 以 `http://` 或 `https://` 开头 → 视为 URL，下载并缓存到 `build/cache/`；
- 否则视为本地路径，文件必须存在（不存在直接报错退出）。

### 1. 本地包传入（推荐用于反复测试）

```bash
./build.sh \
    --mac  devecostudio-mac.zip \
    --cli  commandline-tools-linux-x64.zip \
    --idea idea-2026.1.5.tar.gz
```

- 未传入的源才会从网络下载，且下载后缓存到 `build/cache/`，下一次直接复用。
- 只想本地测、**完全不下载**：加 `--no-download`，缺任何一个本地文件就报错退出。
- 版本号省略时，自动从 Mac 源文件名/地址中提取（如 `devecostudio-mac-26.0.0.621.zip`
  提取出 `26.0.0.621`）。
- 覆盖 IDEA 版本（可选）：`--ideaver 2026.1.5`，否则按上述规则自动解析。

### 2. 直接给下载地址（或混合）

`-m` / `-c` 直接传华为链接即可；`-i` 省略时按自动解析的 IDEA 版本从
JetBrains CDN 拼出下载地址：

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

### 4. 构建、打包、安装分两步（可复用）

脚本把「最后一步」拆成 **打包 tar.gz** 与 **安装到指定目录** 两个动作，二者
都基于同一个已组装好的应用树（`build/work/devecostudio-<pkgver>/`）：

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
> `--clear-all`。

## CLI 工具是否在 PATH 上

默认**不**把 `hvigorw`/`ohpm`/`hstack`/`codelinter`/`Emulator` 链入系统
`/usr/bin`（通用包不应擅自改动系统路径）。它们始终在
`<解压目录>/tools/bin/` 下，IDE 运行时会自己找到。

若你希望把它们暴露到 PATH，加 `--expose-cli`：

```bash
./build.sh --mac ... --cli ... --expose-cli
```

这会额外在 `build/out/` 生成一个 `install-cli-tools.sh`，运行（需 root）后把工具
链到 `/usr/local/bin`（其中 `codelinter`/`Emulator` 默认加 `h` 前缀：
`hcodelinter`/`hemulator`）。

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

## 与 arch/ 下 PKGBUILD 的关系

`arch/PKGBUILD` 仍保留给 Arch 用户使用，两者并存。`build.sh` 不产出
`*.pkg.tar.zst`，也不产出 `.desktop`。所有平台相关的逆向/适配细节见
[`AGENTS.md`](AGENTS.md)（原本在 `DETAILS.md`，已整理移至此处）。

## 已知限制

- **Previewer（预览器）在 Linux 上不可用**：华为未移植 Rosen 渲染引擎。
- 模拟器系统镜像需手动下载（见下）。
- 仅测试过默认值对应的版本；换版本请自行验证。

## 模拟器运行注意事项（Linux 特有问题，已打包层处理）

DevEco 的模拟器在 Linux 上有几个上游怪癖，`build.sh` 已在启动器
`bin/devecostudio.sh` 与权限修复中处理，这里记录以便维护时理解。

### 1. Emulator 二进制需要执行权限

`tools/emulator/Emulator` 是 360M+ 的 Linux 原生 ELF，但 CLI zip 解压后
可能不带执行位。权限修复除按 ELF 魔法字节扫描补 `+x` 外，还会对
已知原生二进制（`tools/emulator/Emulator`、`bin/fsnotifier`、`bin/devecostudio`）
**显式 `chmod +x`**，避免超大文件字节扫描偶发漏判导致模拟器无法启动。

> `tools/bin/Emulator` 与 `tools/emulator/Emulator` 不是重复文件：前者是
> CLI 工具链里的 **bash 包装脚本**（修复路径、补桥接与协议自动接受后转发），
> 后者才是**真实二进制**。

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

- IDE 启动器 `bin/devecostudio.sh`（`export QT_QPA_PLATFORM=xcb`）；
- `tools/bin/Emulator` 包装脚本（`patch_emulator_wrapper` 注入
  `export QT_QPA_PLATFORM=xcb`）。

**注意**：若你直接调用真实二进制 `tools/emulator/Emulator`（绕过包装脚本），
需自己 `export QT_QPA_PLATFORM=xcb`，否则会撞上面的 wayland 错误。

### 5. Device Manager 左侧列表在 Linux 上空白（含破坏性陷阱）

DevEco 的 Device Manager 图形界面依赖华为云下发的预设设备模板/规格，这部分在
Linux 构建里不随包提供，因此 IDE 内打开 Device Manager 时左侧「本地模拟器列表」
与「规格选择」为空、无法在 GUI 里创建模拟器。这是上游 Linux 构建的固有限制，
打包层无法补齐。

**破坏性陷阱（重要）**：在 Linux 上打开 Device Manager 图形界面，IDE 会
**重写** `~/.Huawei/Emulator/deployed/` 目录，把其中用 CLI 创建的本地模拟器
（如 `myPhone`）一并清空。现象是「我的设备」处没有可选项、CLI `-list` 返回
`[Empty]`。因此：

- **不要打开 IDE 的 Device Manager 来管理已存在的 CLI 模拟器**，否则设备会被静默删除；
- 若已被清空，从备份恢复 `deployed/` 下对应的 `<设备名>/`、`<设备名>.ini`、`lists.json` 即可。

绕过方式：用 CLI 创建/启动/停止模拟器（包装脚本已处理路径与 xcb）：

```bash
hemulator -create myPhone -deviceType phone -osVersion "HarmonyOS 6.1.1(24)"
hemulator -start   myPhone
hemulator -stop    myPhone
hemulator -list
```

模拟器窗口正常弹出后，IDE 的 Run/Debug 面板即可选它作为运行目标。

## License 说明

本项目与华为无隶属或背书关系。DevEco Studio 是华为的商业产品，使用前须同意
《HUAWEI DevEco Studio User Agreement》。打包脚本抽取 Mac DMG 中的平台无关文件，
并与来自 IntelliJ IDEA 的 Linux 原生组件（启动器、JBR、原生库）重新组合，
配置被转换——这可能构成协议下的"修改"与"合并"。

- 个人构建使用属项目初衷；
- 向他人分发构建产物很可能违反华为条款，请咨询官方授权与法务。

打包脚本文件本身以 BSD 2-Clause 许可提供，不受华为条款约束。
