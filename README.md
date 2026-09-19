# 额度挂件 QuotaWidget

[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)](#)
[![WPF](https://img.shields.io/badge/UI-WPF-512BD4)](#)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

贴在桌面右上角的悬浮小挂件，实时显示 **Command Code** 和 **ChatGPT (Codex)** 各账号的额度剩余情况。
鼠标移过去自动展开，移开自动收起成一条细标签，不挡视线。

界面用 WPF（XAML 由 PowerShell 动态拼装），数据由一个 Node.js 脚本拉取，
外层再包一个 82 KB 的 C# 启动器，双击时不会闪黑框。

---

## 特性

- **一份面板看两边**：Command Code 的积分额度 + ChatGPT/Codex 的 5 小时 / 每周窗口占用率。
- **多账号**：Command Code 读 `auth.json`，ChatGPT 读 Cockpit Tools 的加密账号库，逐账号一行。
- **自动收起**：贴右上角，鼠标进入热区才展开，带展开 / 收起动画。
- **深色 / 浅色主题**，透明度、边距、刷新间隔都可配。
- **代理自动探测**：依次探测本机常见的 10808 / 7890 / 7897 / 10809 / 1080 端口，哪个通用哪个。
- **缓存兜底**：开窗先用上次缓存渲染，避免白屏；拉取失败时界面显示错误而不是消失。
- **开机自启**：右键菜单一键写入启动目录快捷方式。
- **日志**：所有异常写进 `widget.log`，不会静默退出。

## 快速开始

### 依赖

| 依赖 | 是否必需 | 用途 |
| --- | --- | --- |
| Windows 10 / 11 | 必需 | 运行环境 |
| PowerShell 5.1 | 必需 | 界面宿主（系统自带） |
| [Node.js](https://nodejs.org/) 18+ | 必需 | 运行 `fetch-quota.mjs` 取数 |
| Command Code CLI 并已登录 | 可选 | 提供 `~/.commandcode/auth.json` |
| [Cockpit Tools](https://github.com/) 并已登录 | 可选 | 提供 `~/.antigravity_cockpit` 账号库 |

两个数据源至少要有一个可用，否则挂件只能显示错误信息。

### 运行

```bat
:: 方式一：启动器（推荐，双击无黑框）
QuotaWidget.exe

:: 方式二：直接跑界面脚本（调试用，保留控制台输出）
powershell -ExecutionPolicy Bypass -File resources\widget.ps1 -Console

:: 方式三：只取数据，打印 JSON
node resources\fetch-quota.mjs --pretty
```

启动器会把三个脚本释放到 `%LOCALAPPDATA%\QuotaWidget` 再拉起 `widget.ps1`：

| 文件 | 释放策略 |
| --- | --- |
| `widget.ps1` | 每次启动覆盖 |
| `fetch-quota.mjs` | 每次启动覆盖 |
| `config.json` | 仅当不存在时释放（不覆盖用户配置） |

### 右键菜单

| 菜单项 | 说明 |
| --- | --- |
| 立即刷新 | 手动触发一次拉取 |
| 窗口置顶 | 切换 Topmost |
| 自动收起（贴右上角） | 切换热区展开模式 |
| 恢复右上角位置 | 位置重置并回到默认角落 |
| 开机自动启动 | 写入 / 删除启动目录快捷方式 |
| 打开配置文件 | 用记事本打开 `config.json` |
| 退出 | 关闭挂件 |

## 配置

配置文件：`%LOCALAPPDATA%\QuotaWidget\config.json`（菜单里可直接打开）。
缺省值见 [`resources/config.example.json`](resources/config.example.json)。

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `refreshSeconds` | `60` | 自动刷新间隔（秒） |
| `theme` | `"dark"` | `dark` 或 `light` |
| `opacity` | `0.94` | 面板不透明度 |
| `margin` | `16` | 距屏幕边缘的像素 |
| `topmost` | `true` | 是否窗口置顶 |
| `position` | `null` | 记住的坐标 `{left, top}`；`null` 为右上角 |
| `proxy` | `"auto"` | `auto` 为自动探测，也可写死如 `http://127.0.0.1:7890` |
| `proxyCandidates` | 见下 | 自动探测的候选代理 |
| `timeoutMs` | `20000` | 单次请求超时 |
| `commandCodeAuth` | `"~/.commandcode/auth.json"` | Command Code 凭据路径 |
| `cockpitDir` | `"~/.antigravity_cockpit"` | Cockpit Tools 账号库目录 |
| `nodePath` | `null` | 手动指定 `node.exe`；`null` 为自动查找 |
| `autoHide` | `true` | 是否启用自动收起 |
| `tabWidth` / `tabHeight` | `112` / `12` | 收起后细标签的尺寸 |
| `hotZonePadX` / `hotZonePadY` | `30` / `14` | 展开热区外扩像素 |
| `collapseDelayMs` | `650` | 鼠标移开后延迟多久收起 |
| `expandAnimMs` / `collapseAnimMs` | `200` / `160` | 展开 / 收起动画时长 |
| `dockLeft` | `null` | 记住的停靠边 |

默认 `proxyCandidates`：

```json
["http://127.0.0.1:10808", "http://127.0.0.1:7890", "http://127.0.0.1:7897",
 "http://127.0.0.1:10809", "http://127.0.0.1:1080"]
```

## 数据来源

### Command Code

- 凭据：`~/.commandcode/auth.json` 里的 `apiKey`
- 接口：`GET https://api.commandcode.ai/alpha/billing/credits`
- 套餐月度总额度取自 CLI 内置计费表（`PLAN_TOTAL_CREDITS`）：
  `go` 10、`provider` 15、`pro` 30、`pro-v1` 80、`goat` 70、`max` 150、`ultra` 300、`teams-pro` 40

### ChatGPT / Codex

- 账号库：`~/.antigravity_cockpit/`
  - `secure-account-storage.key` —— 密钥（base64 明文存储）
  - `codex_accounts.json` —— 账号索引
  - `codex_accounts/<id>.json` —— 每账号密文
- 解密：`aes-256-gcm`，`nonce` 为 IV，密文末 16 字节为 auth tag
- 接口：`GET https://chatgpt.com/backend-api/wham/usage`（Bearer token 取自解出的 `access_token`）
- 归一化：把 `rate_limit` 的 5 小时 / 每周窗口压成 `pct`、`remainingPct`、`resetAt`

> ⚠️ **本挂件对上述数据只读**，不会写回 Cockpit / Command Code 的任何文件。

## 构建

```bat
:: 仅启动器（PE 部分）
dotnet build -c Release

:: 界面与数据脚本是纯文本，不需要编译
```

产物：`bin\Release\net48\QuotaWidget.exe`

原始程序集目标框架为 .NET Framework 4.0，仓库默认 `net48`（Win10/11 自带）。
若要还原成 4.0，把 `QuotaWidget.csproj` 里的 `<TargetFramework>` 改成 `net40`，
并用 classic MSBuild + .NET 4.0 Targeting Pack 构建。

## 项目结构

```text
quota-widget/
├─ README.md
├─ LICENSE
├─ QuotaWidget.csproj
├─ QuotaWidgetLauncher.cs        启动器：释放脚本 + 拉起 PowerShell
├─ Properties/AssemblyInfo.cs
├─ docs/
│  └─ DECOMPILATION.md           还原说明
└─ resources/
   ├─ widget.ps1                 挂件主体：WPF 界面 / 动画 / 托盘菜单（1028 行）
   ├─ fetch-quota.mjs            数据层：拉取与归一化额度（557 行）
   ├─ config.example.json        配置示例
   └─ app.ico                    图标
```

## 运行时文件

| 路径 | 说明 |
| --- | --- |
| `%LOCALAPPDATA%\QuotaWidget\widget.ps1` | 界面脚本 |
| `%LOCALAPPDATA%\QuotaWidget\fetch-quota.mjs` | 数据脚本 |
| `%LOCALAPPDATA%\QuotaWidget\config.json` | 配置（用户修改不会被覆盖） |
| `%LOCALAPPDATA%\QuotaWidget\quota-cache.json` | 上次成功拉取的缓存 |
| `%LOCALAPPDATA%\QuotaWidget\widget.log` | 运行日志 |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\额度挂件.lnk` | 开机自启快捷方式 |

## 故障排查

| 现象 | 排查方向 |
| --- | --- |
| 挂件一闪而过 | 看 `widget.log` 里的「未捕获异常」；确认 PowerShell 5.1 可用 |
| 一直显示「获取中」 | `node --version` 是否可用；`config.json` 里可写死 `nodePath` |
| 提示找不到 Cockpit 账号库 | 确认 Cockpit Tools 已安装并登录过，或改 `cockpitDir` |
| 请求超时 | 多半是代理问题；把 `proxy` 写死成实际在用的地址 |
| 开机自启没生效 | 看启动目录里有没有 `额度挂件.lnk`，或手动重新勾选一次 |

## 开源说明

本仓库的源代码由原始 `额度挂件.exe` 反编译还原而成（其中的 `widget.ps1`
与 `fetch-quota.mjs` 是嵌入资源，为**逐字节原样**提取，未做任何改动）。
详见 [docs/DECOMPILATION.md](docs/DECOMPILATION.md)。

## 许可证

[MIT](LICENSE)

## English

**QuotaWidget** is a always-on-top desktop widget that shows remaining quota for
Command Code and ChatGPT (Codex) accounts. The UI is WPF driven from PowerShell,
data comes from a Node.js fetcher, and a tiny C# launcher hides the console window.
It auto-collapses into a thin tab at the top-right corner and expands on hover.
See [docs/DECOMPILATION.md](docs/DECOMPILATION.md) for provenance details.
