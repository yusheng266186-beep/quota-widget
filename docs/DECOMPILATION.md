# 源代码还原说明

本目录下的代码从已编译的 `额度挂件.exe` 还原而来。其中 `.ps1` / `.mjs` 两份脚本
是程序集里的**嵌入资源**，提取即原始文本；只有外层启动器是 C# 反编译产物。

## 原始文件

| 项 | 值 |
| --- | --- |
| 文件名 | `额度挂件.exe` |
| 大小 | 81,920 字节 |
| SHA-256 | `82F726336D92BD84E4242F3B4736B38A21D9FA59CD506C22B06BE22F84742535` |
| 最后修改 | 2026-09-19 16:33:17 |
| 程序集 | `QuotaWidget, Version=0.0.0.0, Culture=neutral, PublicKeyToken=null` |
| PE 架构 | x86（32 位），Subsystem = Windows GUI |
| 运行时 | .NET Framework 4.0（SDK 风格 WindowsDesktop 项目） |

> 哈希值请在本地用 `Get-FileHash .\额度挂件.exe -Algorithm SHA256` 重新计算核对。

## 嵌入资源

程序集通过 `GetManifestResourceNames()` 报告了 3 个嵌入资源，全部已提取到 `resources/`：

| 逻辑名称 | 释放到 | 字节数 | SHA-256（前 16 位） |
| --- | --- | --- | --- |
| `QuotaWidget.widget.ps1` | `resources/widget.ps1` | 44,748 | `F9190256A2D7AFD5` |
| `QuotaWidget.fetch-quota.mjs` | `resources/fetch-quota.mjs` | 20,055 | `A4926472E473D0AE` |
| `QuotaWidget.config.json` | `resources/config.example.json` | 872 | `6DC6699180562DA0` |

启动器会在首次运行时把它们释放到 `%LOCALAPPDATA%\QuotaWidget`。
注意资源逻辑名与释放后的文件名并不一致：

- `QuotaWidget.config.json` → 释放为 **`config.json`**
- 另外两份去掉 `QuotaWidget.` 前缀即可

因此 `resources/config.example.json` 是资源 `QuotaWidget.config.json` 的原样副本，
只是改了扩展名以便和用户实际使用的 `config.json` 区分。

### 嵌入资源是原样提取的

这一点做过独立验证：原程序在这台机器上已经运行过，脚本已释放到
`%LOCALAPPDATA%\QuotaWidget\`。把提取结果与释放后的实际文件做 SHA-256 比对：

```text
widget.ps1:       live=F9190256A2D7AFD5  extracted=F9190256A2D7AFD5  MATCH=True
fetch-quota.mjs:  live=A4926472E473D0AE  extracted=A4926472E473D0AE  MATCH=True
```

即 **字节完全一致，没有任何编码损失或改动**。另外验证：

- `widget.ps1` 用 `[System.Management.Automation.Language.Parser]::ParseFile()` 解析，
  0 个语法错误，识别出 37 个函数。
- `fetch-quota.mjs` 通过 `node --check` 语法校验（exit 0）。

两份脚本内的中文注释均为正确 UTF-8，未出现乱码。

## 反编译出的 C# 部分

程序集只包含 1 个类型：

| 类型 | 文件 | 说明 |
| --- | --- | --- |
| `QuotaWidgetLauncher` | `QuotaWidgetLauncher.cs` | 释放嵌入资源并拉起 PowerShell |

整理时做的改动：

1. **补回标识符名称**：`text`、`text2` 等改为 `dir`、`script`、`psi`。
2. **补 `AssemblyInfo`**：原程序集的 `AssemblyVersion` 为 `0.0.0.0` 且只有这一个特性，
   已补齐 `AssemblyTitle` / `AssemblyProduct` 等便于识别。
3. **补注释**：说明「为什么要有这层 EXE」（避免双击闪控制台）、
   两类资源的覆盖策略差异等。

行为上保持完全一致：资源名拼接方式（`"QuotaWidget." + resourceName`）、
覆盖策略、`QUOTA_WIDGET_LAUNCHER` 环境变量传递、错误弹窗文案均未改动。

## 使用的工具

| 工具 | 版本 | 用途 |
| --- | --- | --- |
| [ILSpy / ilspycmd](https://github.com/icsharpcode/ILSpy) | 9.1.0.7988 | C# 反编译 + 嵌入资源提取 |
| .NET Runtime | 8.0.31 | 运行 ilspycmd |
| PowerShell 5.1 | — | 资源校验、语法解析 |
| Node.js | 26.7.0 | `fetch-quota.mjs` 语法校验 |
| MSBuild | 17.14 | 编译验证 |

反编译命令：

```bat
ilspycmd --project --outputdir .\out 额度挂件.exe
```

## 数据流

```text
QuotaWidget.exe (C#)
   └─ 释放 widget.ps1 / fetch-quota.mjs / config.json 到 %LOCALAPPDATA%\QuotaWidget
   └─ powershell.exe -File widget.ps1
         ├─ 用 WPF 拼出挂件界面（纯代码构建，无 XAML 文件）
         └─ 定时 spawn node.exe fetch-quota.mjs --out quota-cache.json
               ├─ 读 ~/.commandcode/auth.json         → api.commandcode.ai
               └─ 读 ~/.antigravity_cockpit (AES-GCM) → chatgpt.com/backend-api
```

## 免责声明

本仓库仅用于学习与备份目的恢复原作者自己的程序源码。脚本会读取本机的
Command Code / ChatGPT 凭据，请自行审阅后再运行。代码按原样提供。
