# DSH Flick

**macOS 菜单栏里的 DeepSeek Harness 快捷入口。** 支持两种运行方式：

- **独立版**：点击菜单栏图标弹出 460×660 面板，内嵌已认证的 DeepSeek Harness Web 界面；
- **DSH 插件模式**：由 DSH 插件托管，使用轻量原生小面板（打开主窗口 / 新建会话 / 最近会话 / 待审批权限），DSH 打开时出现，退出时自动消失。

![DSH Flick 菜单栏图标](Resources/MenuIcon@2x.png)

> 非官方个人项目，与 DeepSeek 官方无关。本项目图标为原创，不包含 DeepSeek 官方图形资产；详见[商标与致谢](#商标与致谢)。

---

## 功能特性

- **菜单栏常驻图标**：原创单色模板图标，自动适配浅色 / 深色菜单栏；离线时图标变暗。
- **两种界面**：独立版是 460×660 的 WebView 面板；插件模式是轻量原生小面板，可显示连接状态、最近会话和快捷动作。
- **插件托管生命周期**：插件启动 `/插件目录/resources/DSH Flick.app --managed --native-menu`，退出 DSH 或禁用插件时通过 stdin EOF / 父进程检测自动结束，不会留下后台进程或登录项。
- **最近会话**：插件 Host 通过 `ctx.sessionQuery` 读取最近 5 个顶层会话，点击直接跳转。
- **菜单栏审批**：DSH 主窗口最小化、切到别的 Space 或被别的应用全屏遮挡时，新权限请求会显示在菜单栏面板中；每条注明来源会话、权限说明，并可直接「拒绝 / 允许一次」或「查看详情」跳回该会话。多个审批纵向堆叠、面板增高并支持滚动；插件设置可关闭自动弹出，只保留红色数量角标。
- **快捷动作桥接**：菜单栏 app 通过回环 `/dsh-flick/api/*` 让 DSH 页面执行 `uiWorkspace.startSession()` / `openSession()`，不需要辅助功能权限。
- **右键菜单**：显示面板、打开 DeepSeek Harness 主窗口、重新连接、重新加载界面、开机自启开关、关于、退出。
- **新建对话**：面板头部「新建对话」按钮（以及菜单项）会自动在 Web UI 中点击「新建 / 新对话」入口。
- **打开主窗口**：一键激活或启动 DeepSeek Harness 桌面应用。
- **重新连接**：DeepSeek Harness 重启、换端口或登录态刷新后，重新发现服务并恢复内嵌会话。
- **全局热键 `⌥⌘D`**（Option + Command + D）：在任何应用中显示 / 收起 DSH Flick 面板，无需辅助功能（Accessibility）权限。
- **开机自启**：菜单中的「开机自启」开关，通过 `~/Library/LaunchAgents/com.rigelmansid.dshflick.plist` 实现，可随时关闭。
- **离线启动 DSH**：DeepSeek Harness 未运行时不会只显示错误状态，而是给出「启动 DeepSeek Harness」按钮，点击后自动拉起桌面端并等待连接（最长约 45 秒）。

## 工作原理

DSH Flick 不修改 DeepSeek Harness 的任何文件，也不实现自己的聊天协议。它是一个**本机登录态复用器**：

1. **发现服务**：DeepSeek Harness 桌面端（Electron）启动后在 `127.0.0.1` 的随机端口上运行 Web 服务。DSH Flick 枚举本机回环 TCP 监听端口（`lsof`，必要时回退 `netstat`），对每个端口做一次**不带 cookie** 的 `GET /`，通过 DSH 特有的 `401 dsh web authentication required` 响应确认哪个端口属于 DSH，并按 DSH 进程名优先排序。
2. **生成登录态**：DSH `0.2.2-rc.3` 起不再把 `dsh-auth-*` cookie 写入 Chromium cookie 库（改由桌面端进程内存持有），但会把浏览器会话的签名密钥持久化在 `~/.dsh/.credentials.yaml` 的 `client-connection/browser-session` 记录中。DSH Flick 以**只读**方式读取该密钥，按 DSH 自己的格式在本机生成一个绑定 `127.0.0.1:<port>` 的合法签名 cookie（HMAC-SHA256；默认 29 天，短于服务端的 30 天上限）。
3. **兼容旧版**：DSH `0.2.2-rc.2` 及更早版本仍把 cookie 存在 Electron 的 Cookies SQLite 中（名字形如 `dsh-auth-<hash>`）。DSH Flick 会回退到只读读取该库、用 `base64url(sha256("127.0.0.1:<port>"))` 反推端口的方式，两边都失败才报错。
4. **验证服务**：带 cookie 对 `http://127.0.0.1:<port>/` 发起一次本机请求，只有返回 `200` 且页面中包含 `__DSH_BOOT__` 才认为连接有效，避免误连到其他本地服务。
5. **注入会话**：把该 cookie 写入 `WKWebView` 的 `WKWebsiteDataStore` 后加载本机页面；若 WebKit 拒绝 cookie store 注入，则回退为在页面内执行 `document.cookie = "..."` 后重载。
6. **状态驱动**：`AppController` 负责发现 / 重连状态机，`DSHFlickController` 负责菜单栏、弹窗、WebView 与热键，二者通过 `DSHFlickUI` 协议解耦。

### 为什么登录态通常能一直用

DSH 服务端接受最长 **30 天**的签名 cookie；DSH Flick 每次发现时都会用持久化密钥**重新生成**新 cookie，因此不受旧 cookie 过期影响（只要 `~/.dsh/.credentials.yaml` 仍在且 DSH 没有重置该密钥）。DeepSeek Harness 重启后端口会变化，DSH Flick 会重新枚举端口并生成对应 authority 的 cookie，**自动重新发现新端口**，无需手工配置。

## 安全与隐私

- **仅本机通信**：DSH Flick 只访问 `127.0.0.1` 回环地址，不连接任何外部服务器，也不上传任何数据。
- **只读登录态**：`~/.dsh/.credentials.yaml` 与（旧版兼容路径下的）Electron Cookies SQLite 都只以只读方式打开；DSH Flick 绝不写入、修改或删除 DSH 的登录态或凭证文件。
- **不修改 DSH 安装**：不注入、不 patch、不改配置，卸载 DSH Flick 不会影响 DeepSeek Harness。
- **不打印敏感信息**：日志与 `--discover` 输出只包含端口、cookie 名称与过期时间，**从不输出密钥或 cookie 值**。
- **cookie 用途单一**：生成的 cookie 仅注入到本机 DSH Web UI 的 `WKWebView` 会话，只发往 `127.0.0.1:<端口>`，不会用于任何其他站点。
- **无额外系统权限**：全局热键使用 Carbon `RegisterEventHotKey`，**不需要辅助功能 / 输入监控 / 屏幕录制权限**；应用为 `LSUIElement`，不显示 Dock 图标。
- **ad-hoc 签名**：本地构建产物使用 ad-hoc 签名（`codesign --sign -`），仅适合本机自用，非 App Store / 公证分发。

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | macOS 14 Sonoma 或更高版本 |
| 架构 | Apple Silicon（arm64）或 Intel（x86_64），按本机架构构建 |
| 构建工具 | Xcode Command Line Tools（提供 `swiftc`；`xcode-select --install`） |
| 运行依赖 | 已安装并登录过 DeepSeek Harness 桌面版（`/Applications/DeepSeek Harness.app`） |
| 图标生成（可选） | Python 3.9+ 与 Pillow（仅在重新生成菜单栏图标或手动指定时用到） |

DSH Flick 本身**没有第三方依赖**，只使用系统 AppKit / WebKit / Carbon 框架。

## 构建

```bash
cd dsh-flick

./scripts/build.sh             # Release 构建 -> dist/DSH Flick.app（推荐）
./scripts/build.sh --debug     # 调试构建，编译更快
./scripts/build.sh --universal # arm64 + x86_64 universal 二进制
./scripts/build.sh --run       # 构建完成后立即打开应用
./scripts/build-plugin.sh      # 构建并复制到 plugin/resources/（DSH 插件包）
./scripts/build-plugin.sh --universal  # 发行用 universal 插件包
```

构建脚本会依次执行：

1. 用 `swiftc` 直接编译 `Sources/**/*.swift`（不使用 SwiftPM，无需 `Package.swift`）；
2. 校验 `Resources/MenuIcon*.png` 尺寸并组装 `dist/DSH Flick.app`（写入 `Info.plist`、复制图标）；
3. 使用 `/usr/bin/codesign --force --deep --sign -` 做 ad-hoc 签名并校验。

脚本可重复执行（幂等），结束时打印 `.app` 的完整路径。构建产物结构：

```text
dist/DSH Flick.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/DSHFlick
    └── Resources/
        ├── AppIcon.icns
        ├── MenuIcon.png      # 18×18
        ├── MenuIcon@2x.png   # 36×36
        └── MenuIcon@3x.png   # 54×54
```

等价的手动编译命令：

```bash
swiftc -O -swift-version 5 \
  -module-cache-path .build/modulecache \
  -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI -framework Combine -framework WebKit -framework Carbon \
  -o .build/DSHFlick \
  $(find Sources -name '*.swift' | sort)
```

### 运行构建产物

```bash
open "dist/DSH Flick.app"          # 以正常 .app 方式启动（菜单栏出现图标）
./dist/DSH\ Bar.app/Contents/MacOS/DSHFlick   # 直接运行可执行文件
```

### 命令行诊断

同一个可执行文件还内置了用于排障 / 验收的 CLI 模式：

```bash
# 发现当前的 DSH 服务端口并生成本机登录 cookie（不输出密钥 / cookie 值）
"./dist/DSH Flick.app/Contents/MacOS/DSHFlick" --discover

# 无头加载已认证 Web UI，导出 DOM 摘要并截图
"./dist/DSH Flick.app/Contents/MacOS/DSHFlick" --probe /tmp/dsh-probe.png

# 检查 DSH 插件桥接状态（需要已安装并启用插件）
"./dist/DSH Flick.app/Contents/MacOS/DSHFlick" --bridge-check

# 列出最近会话（JSON，供验收/排障）
"./dist/DSH Flick.app/Contents/MacOS/DSHFlick" --bridge-recent

# 模拟菜单栏动作：new-session / open-session <sessionId>
"./dist/DSH Flick.app/Contents/MacOS/DSHFlick" --bridge-action new-session

# 查看当前待审批（JSON）
"./dist/DSH Flick.app/Contents/MacOS/DSHFlick" --bridge-approvals

# 回传一次审批决定（排障 / 验收）
"./dist/DSH Flick.app/Contents/MacOS/DSHFlick" --bridge-answer <key> rejected <clientId>
```

`--discover` 成功时输出形如 `{"ok":true,"port":62697,...}`；`--probe` 会额外生成 PNG 快照，便于确认内嵌会话是否已认证。

## 安装与卸载

### 安装

```bash
./scripts/build.sh              # 先构建
./scripts/install.sh            # 安装到 ~/Applications/DSH Flick.app
./scripts/install.sh --launch   # 安装并立即启动
```

安装脚本**无需 sudo**，只写入当前用户目录：

- 应用：`~/Applications/DSH Flick.app`
- 开机自启（仅当在菜单里勾选时）：`~/Library/LaunchAgents/com.rigelmansid.dshflick.plist`

脚本会在安装 / 删除前校验所有目标路径都位于 `$HOME` 之下，并拒绝以 root 身份运行。

### 从 GitHub 安装

```bash
dsh plugin --profile desktop add "git+https://github.com/rigelmansid/dsh-flick.git"
```

安装后在 DSH 左侧栏 **插件** 页面启用 `DSH Flick`。GitHub Release 也提供
`dsh-flick-0.2.0.tgz`，可下载后作为本地包安装。

### 作为本地源码插件安装

```bash
./scripts/build-plugin.sh
```

然后在 DSH 主窗口左侧栏的 **插件**（Plugins）页面安装本地目录 `dsh-flick/plugin`
（或让 agent 用 `plugin_manager install_bundle` 安装）。安装后重启一次 DSH，菜单栏会出现
轻量原生面板；禁用插件或退出 DSH 时图标消失。

> **启停入口是左侧栏的「插件」页面**，不是「设置 → 内置插件」；后者只是只读的内置插件清单，
> 只显示配置状态和运行状态，不能开关。

插件包通过本地目录安装时，DSH 会把它链接到源码目录；不要删除或移动 `dsh-flick/`。
发行用包可以用 `./scripts/build-plugin.sh --universal` 构建，再用 npm/pnpm 打包分发。

### 卸载

```bash
./scripts/install.sh --uninstall
```

卸载会：退出正在运行的 DSH Flick → 移除开机自启项（`~/Library/LaunchAgents/com.rigelmansid.dshflick.plist`）
→ 删除 `~/Applications/DSH Flick.app`。**不会触碰 DeepSeek Harness 本体。**

### 开发调试

```bash
./scripts/run-dev.sh   # 调试构建 + 启动 dist 中的 app，适合反复迭代
```

## 菜单与热键

### 独立版（完整 WebView 面板）

| 操作 | 入口 | 说明 |
| --- | --- | --- |
| 打开 / 收起面板 | 左键点击菜单栏图标、`⌥⌘D` | 弹出或收起内嵌 DSH 面板 |
| 右键菜单 | 右键 / `Control` + 点击菜单栏图标 | 打开下方各项所在的菜单 |
| 新建对话 | 面板头部「新建对话」按钮、右键菜单「新建对话」（`⌘N`） | 自动在 Web UI 中点击新建入口 |
| 重新加载界面 | 面板头部刷新按钮、右键菜单「重新加载界面」 | 重新加载 WebView 内容 |
| 在桌面打开 | 面板头部按钮「在桌面打开 DeepSeek Harness」 | 打开 DeepSeek Harness 主窗口 |
| 打开主窗口 | 右键菜单「打开 DeepSeek Harness 主窗口」 | 激活或启动桌面端 |
| 重新连接 | 右键菜单「重新连接」 | 重新发现服务与登录态，并显示面板 |
| 开机自启 | 右键菜单「开机自启」开关 | 写入 / 移除 LaunchAgent（仅以 .app 形式运行时显示） |
| 关于 | 右键菜单「关于 DSH Flick」 | 版本与说明 |
| 退出 | 右键菜单「退出 DSH Flick」（`⌘Q`） | 结束菜单栏进程 |

> `⌘N` / `⌘Q` 是右键菜单展开时的菜单快捷键；`⌥⌘D` 是任意应用中都可用的全局热键。
> 面板为 `NSPopover` 临时窗口：点击面板外部或按 `Esc` 会自动收起。

### 插件模式（轻量原生面板）

| 操作 | 说明 |
| --- | --- |
| 左键点击图标 / `⌥⌘D` | 显示或收起原生小面板 |
| 打开 DeepSeek Harness | 激活主窗口 |
| 新建会话 | 让 DSH 页面在当前/最近工作区新建会话并打开 |
| 最近会话 | 显示最近 5 个顶层会话，点击跳转 |
| 待审批 | 显示每个会话当前的权限请求；拒绝 / 允许一次 / 查看详情；面板最多增高到 760pt，超出内部滚动 |
| 重新连接 | 重新发现服务并刷新桥接数据 |
| 隐藏图标 | 结束本次运行的菜单栏进程；插件不会自动重拉，DSH 重启后恢复 |
| 右键 | 打开/新建/最近会话/重新连接/关于/隐藏 |
| 红色角标 | 有等待处理的审批时显示数量；可在 DSH 插件设置中关闭自动弹出 |

> 插件模式下，退出 DSH、禁用插件或插件崩溃都会让图标消失；DSH 重新启动后恢复。

## 重新生成菜单栏图标

本项目使用**原创图标**：应用图标是蓝色圆角方块 + 三条白色横线 + 绿色状态点；菜单栏图标是同形状的黑色模板图（透明背景），由系统自动着色适配浅色 / 深色菜单栏。

```bash
./scripts/make-icons.sh     # 重新生成 Resources/MenuIcon*.png 与 AppIcon.icns
```

脚本会自动寻找带 Pillow 的 Python：优先 `$PYTHON`，其次 DeepSeek Harness 自带的运行时 Python，最后是 Homebrew / 系统 `python3`。也可以直接调用：

```bash
PYTHON=/path/to/python3 python3 scripts/make-icons.py
```

生成脚本不读取、不复制 DeepSeek Harness 的任何图形资产。

## 目录结构

```text
dsh-flick/
├── Sources/
│   └── DSHFlick/
│       ├── main.swift              # 入口：--discover / --probe / --bridge-* / 菜单栏应用
│       ├── App/                    # 菜单栏 UI 与状态机
│       │   ├── AppController.swift # 发现 / 重连 / 拉起桌面端的状态机
│       │   ├── DSHFlickUI.swift      # UI 协议
│       │   ├── DSHFlickController.swift  # 独立版：状态项、弹窗、右键菜单、全局热键
│       │   ├── NativeMenuController.swift # 插件模式：原生小面板、桥接动作、隐藏
│       │   ├── NativePanelModel.swift # 原生面板状态模型
│       │   ├── NativePanelView.swift  # SwiftUI 原生面板
│       │   ├── BridgeAPI.swift     # /dsh-flick/api 客户端
│       │   ├── ManagedLifecycle.swift # 插件托管的 stdin/父进程退出
│       │   ├── PanelViewController.swift # 独立版面板布局、状态渲染、toast
│       │   ├── PanelChrome.swift   # 头部 / 空状态等原生控件与图标加载
│       │   ├── WebPane.swift       # WKWebView、cookie 注入、新建对话 JS
│       │   ├── GlobalHotKey.swift  # Carbon 全局热键 ⌥⌘D
│       │   └── LaunchAtLogin.swift # 开机自启 LaunchAgent 管理
│       └── Core/                   # 发现层
│           ├── Models.swift        # DSHConnection / 错误 / 应用状态
│           ├── DSHDiscovery.swift  # 端口枚举 + 签名 cookie 生成（兼容旧版 cookie 回放）
│           ├── DSHDesktop.swift    # 定位 / 启动 / 激活桌面端
│           ├── InstanceLock.swift  # 单实例 flock
│           └── Probe.swift         # 无头探针（截图 + DOM 摘要）
├── plugin/                         # DSH 插件包（Host + Client + 内置 app）
│   ├── package.json
│   ├── cordis.patch.yml
│   ├── index.js / client.js
│   ├── resources/DSH Flick.app       # build-plugin.sh 生成
│   ├── locale/ / docs/ / icon.svg
│   └── README.md
├── Resources/                      # 随 app 打包的资源
│   ├── AppIcon.icns                # 原创应用图标
│   └── MenuIcon{,@2x,@3x}.png      # 原创菜单栏模板图标 18/36/54 px
├── scripts/
│   ├── build.sh                    # swiftc 编译 + 组装 dist/DSH Flick.app + ad-hoc 签名
│   ├── build-plugin.sh             # 构建并复制到 plugin/resources
│   ├── install.sh                  # 安装 / 卸载到 ~/Applications
│   ├── run-dev.sh                  # 调试构建并启动
│   ├── make-icons.py               # 图标生成（Pillow，当前图标已生成）
│   └── make-icons.sh               # 图标生成包装脚本
├── verify/                         # 端到端验收产物（截图 / 日志，可选）
├── dist/                           # 构建输出（git 忽略）
├── .build/                         # 编译中间产物（git 忽略）
└── README.md
```

## 打包细节

`dist/DSH Flick.app/Contents/Info.plist` 中的关键字段：

| Key | 值 | 作用 |
| --- | --- | --- |
| `CFBundleIdentifier` | `com.rigelmansid.dshflick` | Bundle ID（也用于开机自启 Label） |
| `CFBundleExecutable` | `DSHFlick` | 可执行文件名 |
| `LSUIElement` | `true` | 仅菜单栏应用，不显示 Dock 图标 |
| `LSMinimumSystemVersion` | `14.0` | 最低系统版本 |
| `NSHighResolutionCapable` | `true` | 支持 Retina |
| `CFBundleIconFile` | `AppIcon` | Finder / 关于窗口图标 |
| `NSAppTransportSecurity.NSAllowsLocalNetworking` | `true` | 允许加载本机 `http://127.0.0.1` 页面 |

## 故障排查

| 现象 | 可能原因 | 解决办法 |
| --- | --- | --- |
| 菜单栏看不到图标 | app 未启动；或启动后被系统结束 | 确认进程：`pgrep -fl DSHFlick`；重新执行 `open "dist/DSH Flick.app"`；打开控制台看崩溃日志 |
| 面板提示「DeepSeek Harness 未运行」 | 桌面端未启动 | 点击面板里的「启动 DeepSeek Harness」，或直接打开桌面端，连接会自动恢复（最长等 45 秒） |
| 面板提示「未找到登录态」 | 找不到 `~/.dsh/.credentials.yaml` 中的浏览器会话密钥，且旧版 cookie 也不可用 | 打开一次 DeepSeek Harness 主窗口并完成登录，然后在面板/菜单点「重新连接」 |
| 提示「未找到 DeepSeek Harness 本地服务」 | 桌面端进程在运行，但 Web 服务尚未监听 / 已被关闭 | 稍等片刻点「重新连接」；或打开一次 DeepSeek Harness 主窗口，让本机 Web 服务启动 |
| 提示「无法读取 DSH 登录态」 | 旧版兼容路径下 Cookies 数据库读取失败（权限 / 文件被占用 / 格式变化） | 确认 DSH 桌面版仍在运行；重启 DeepSeek Harness 后再试；必要时在 DeepSeek Harness 中重新登录 |
| 面板白屏或一直显示 connecting | DSH 服务已重启 / 端口变化 / 登录态过期 | 点右键菜单「重新连接」，或面板头部的刷新按钮；若仍失败，重开 DeepSeek Harness 主窗口 |
| `⌥⌘D` 没有反应 | 热键与其他应用冲突（少数全局热键工具会占用） | 改用左键点击菜单栏图标；退出占用该组合键的应用后重试 |
| 勾选「开机自启」无效 | 登录项被系统设置禁用，或 app 未安装在 .app bundle 中 | 检查 `~/Library/LaunchAgents/com.rigelmansid.dshflick.plist` 是否存在；在「系统设置 › 通用 › 登录项与扩展」中确认允许；用 `./scripts/install.sh` 安装到 `~/Applications` |
| 构建报 `swiftc not found` | 未安装 Xcode Command Line Tools | `xcode-select --install` 后重试 |
| 构建报图标缺失 / 尺寸不符 | `Resources/` 被清理或图标被替换 | `./scripts/make-icons.sh` 重新生成原创图标 |
| 图标生成失败（Pillow） | 默认 Python 没有 Pillow | `PYTHON=/path/to/python3 ./scripts/make-icons.sh`，或 `pip3 install Pillow` |
| 首次启动提示「无法验证开发者」 | 从网络传输过的 app 被加上了 quarantine 标记 | 本机构建通常无此问题；如遇到可执行 `xattr -dr com.apple.quarantine "DSH Flick.app"`（自行确认来源可信） |
| `codesign` 校验失败 | 修改了 app 内容导致签名失效 | 重新运行 `./scripts/build.sh`（会重新签名） |

## 已知限制

- **独立版内嵌 Web UI**：完整面板展示的是 DSH 官方 Web UI，交互与外观跟随 DSH 版本；插件模式则是轻量原生面板，不提供完整聊天界面。
- **仅支持 DeepSeek Harness 桌面版**：依赖 Electron 桌面端的本机 Web 服务与登录凭证；不适用于纯 CLI / 远程部署的 DSH。
- **登录态依赖 DSH 内部存储结构**：当前读取 `~/.dsh/.credentials.yaml` 的浏览器会话密钥并据此生成 cookie；DSH 如果再次大幅调整登录态机制，DSH Flick 可能需要同步更新。
- **密钥轮换后需重连**：若在 DSH 中重置了本机凭证（密钥变化），旧 cookie 会立即失效；DSH Flick 下次发现时会用新密钥重新生成。
- **全局热键固定**：目前固定为 `⌥⌘D`，不支持自定义（与系统或其他工具冲突时只能改用鼠标操作）。
- **本地 ad-hoc 签名，非 App Store 应用**：不提供公证、自动更新，也不适合对外分发。
- **插件本地安装是软链**：通过本地目录安装时，DSH 链接到 `dsh-flick/plugin`，删除或移动源码目录会让插件失效；发行版应打包成 npm tarball。
- **插件桥接依赖桌面端行为**：`/dsh-flick/api/*` 依赖 DSH 桌面页的 fetch 转发、客户端 `uiWorkspace` 服务，以及 `ctx.uiSession.sessionStatus` 的待审批投影；DSH 大版本升级后可能需要适配。桥接不可用时，面板自动退化为“打开 + 状态”。
- **审批能力要求 DSH >= 0.2.2-rc.5**：页面内插件通过 `uiSession.sessionStatus` 读取 `PendingApproval` 并调用其 `answer()`；旧版本没有该投影时审批区自动隐藏，其余功能不受影响。审批是一次性授权，且同一会话同时只显示一条。

## 商标与致谢

- **DSH Flick** 是一个非官方的个人辅助工具，与 DeepSeek 官方无任何关联。
- 本项目的应用图标与菜单栏图标均为原创（蓝色圆角方块 + 三条白色横线 + 绿色状态点），不包含 DeepSeek 官方图形资产。**DeepSeek、DeepSeek Harness 名称及相关商标归 DeepSeek 所有**；本项目为独立第三方工具，与 DeepSeek 官方无关联。
- 感谢 DeepSeek Harness 提供优秀的本地 Web UI 与本机服务架构；感谢 macOS AppKit / WebKit / Carbon 框架。
- 本项目不包含任何第三方依赖；请遵守你所在地区及 DeepSeek 的服务条款使用。
