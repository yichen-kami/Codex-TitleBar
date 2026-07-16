<div align="center">

# Codex TitleBar

在 Codex Desktop 标题栏中显示剩余额度与重置时间的 Windows 轻量工具

[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows)](https://www.microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell)](https://learn.microsoft.com/powershell/)
[![No dependencies](https://img.shields.io/badge/dependencies-none-2ea44f)](#运行要求)

</div>

Codex TitleBar 是一个面向 Windows 版 Codex Desktop 的本地辅助工具。它会在 Codex 主窗口标题栏右侧显示当前可用额度百分比及重置时间，让你无需离开正在进行的任务即可查看额度状态。

工具使用 PowerShell、WPF 与系统 Win32 API 实现，不包含预编译的第三方程序，不修改 Codex 安装文件，也不收集聊天内容。

## 功能亮点

- **标题栏实时显示**：在 Codex Desktop 顶部显示剩余额度和重置时间。
- **兼容不同额度窗口**：支持当前一周窗口（`7d`），并兼容仍返回 5 小时窗口（`5h`）的账户。
- **自动跟随窗口**：随 Codex 移动、最小化、恢复和重建窗口。
- **后台异步刷新**：默认每 30 秒刷新，不阻塞界面；网络失败时自动缩短重试间隔。
- **异常跳变保护**：过滤偶发的错误额度快照，避免显示值无故向上跳变。
- **通知区域控制**：支持立即刷新和退出当前实例。
- **单实例运行**：重复启动不会产生多个额度条或监听器。
- **轻量且透明**：无需 SDK、npm 包或额外可执行文件。

## 显示格式

根据接口返回的额度类型，标题栏会显示以下一种布局：

```text
7d  82%  7/20 14:30
```

```text
5h  64%  18:20  |  7d  82%  7/20 14:30
```

- 百分比表示**剩余额度**，不是已使用额度。
- `5h` 显示当天重置时间。
- `7d` 显示重置日期和时间。
- API Key 按量计费模式没有订阅额度窗口，因此显示 `7d --`。

## 运行要求

- Windows 10 或 Windows 11
- Codex Desktop（Microsoft Store/MSIX 版本）
- Windows PowerShell 5.1
- 已在 Codex Desktop 中登录 ChatGPT 订阅账户

> [!NOTE]
> 当前窗口识别逻辑匹配 Codex Desktop 的 `OpenAI.Codex_*` 应用包路径。其他安装形式可能无法被自动识别。

## 快速开始

### 1. 下载项目

在 GitHub 页面选择 **Code → Download ZIP** 并解压，或者使用 Git：

```powershell
git clone https://github.com/yichen-kami/Codex-TitleBar.git
cd Codex-TitleBar
```

### 2. 启动额度条

双击：

```text
启动 Codex 额度条.cmd
```

也可以从 PowerShell 运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CodexQuotaTitlebar.ps1
```

如果 Codex 尚未启动，额度条会在后台等待；Codex 主窗口出现后会自动显示。

## 随 Codex 自动运行

`CodexQuotaWatcher.ps1` 会持续监听 Codex Desktop：

1. Codex 启动后自动运行额度条。
2. 额度条意外退出时自动恢复。
3. Codex 关闭后清理额度条并等待下一次启动。

双击 `CodexQuotaStartup.cmd` 可在当前会话中隐藏启动监听器。需要登录 Windows 后自动运行时，可在“任务计划程序”中创建当前用户登录触发器，程序填写：

```text
wscript.exe
```

参数填写 `CodexQuotaLauncher.vbs` 的完整路径。启动器会自动从自身所在目录查找监听脚本，因此项目可以放在任意路径。

## 数据来源与刷新规则

程序读取当前用户 `%USERPROFILE%\.codex\auth.json` 中已有的 Codex 登录状态，并请求 Codex/ChatGPT 使用的额度接口：

```text
GET https://chatgpt.com/backend-api/wham/usage
```

- 按 `limit_window_seconds` 识别 5 小时和一周额度窗口。
- 接口返回 `used_percent` 时，以 `100 - used_percent` 计算剩余百分比。
- UTC/Unix 重置时间会转换为 Windows 本地时间。
- 正常状态每 30 秒刷新一次；请求失败后每 10 秒重试。
- 临时网络故障会保留最后一次有效结果，直到已知额度窗口到达重置时间。
- 登录失效、尚无有效数据或响应格式无法识别时显示 `--`。

> [!WARNING]
> 该接口不是面向第三方工具承诺长期稳定的公开 API。Codex Desktop 或服务端接口变更后，本项目可能需要同步更新。

## 异常跳变保护

额度下降或保持时会立即更新。若接口在重置时间到达前突然返回更高额度，程序会等待连续两次完全相同的结果后再接受新值；已知窗口完成重置时，新额度会立即生效。

这可以过滤偶发的 `98%`、`99%` 临时快照，同时不影响真实消耗和正常重置。

## 代理设置

程序优先读取 `%USERPROFILE%\.codex\.env` 中的 `HTTPS_PROXY`，没有时再读取 `HTTP_PROXY`：

```dotenv
HTTPS_PROXY=http://127.0.0.1:7897
```

未配置代理时使用 Windows/.NET 的默认网络设置。

## 项目结构

| 文件 | 作用 |
| --- | --- |
| `CodexQuotaTitlebar.ps1` | 主程序：额度请求与解析、WPF 界面、Win32 窗口跟随和生命周期管理。 |
| `CodexQuotaWatcher.ps1` | 监听 Codex 进程并负责启动、等待和恢复额度条。 |
| `CodexQuotaLauncher.vbs` | 无终端窗口的隐藏启动器，适合任务计划程序调用。 |
| `CodexQuotaStartup.cmd` | 隐藏启动监听器的快捷入口。 |
| `启动 Codex 额度条.cmd` | 直接手动启动额度条。 |
| `README.md` | 项目说明文档。 |

## 隐私与安全

- 访问令牌只在当前 PowerShell 进程内存中用于请求 `chatgpt.com`。
- 不打印、保存或上传 access token、refresh token、Cookie 或完整账户 ID。
- 不收集聊天记录、任务内容、提示词或本地源码。
- 不包含遥测、统计或第三方跟踪。
- 不修改 Codex 的 `app.asar`、安装目录、配置或账户额度。

运行任何会读取登录令牌的第三方脚本前，都建议先审阅源码。本项目的全部运行代码均位于仓库中的 PowerShell、VBS 和 CMD 文本文件内。

## 常见问题

### 启动后没有显示

请确认：

1. Codex Desktop 已启动并完成登录。
2. 使用的是受支持的 Microsoft Store/MSIX 版本。
3. `CodexQuotaTitlebar.ps1` 没有被 Windows 安全策略阻止。
4. 通知区域中是否存在 `Codex Quota Titlebar` 图标。

### 显示 `7d --`

常见原因包括：使用 API Key 按量计费模式、登录状态失效、网络暂时不可用，或服务端返回了尚未支持的额度格式。

### 如何退出

在通知区域右键 `Codex Quota Titlebar`，选择 **Exit**。如果监听器仍在运行，它会自动重新启动额度条；要完全停止，请同时结束 `CodexQuotaWatcher.ps1` 对应的 PowerShell 进程。

## 停止自动启动与卸载

如果你曾自行创建计划任务，可在 PowerShell 中删除：

```powershell
Unregister-ScheduledTask -TaskName 'CodexQuotaTitlebarWatcher' -Confirm:$false
```

随后结束额度条和监听器进程，并删除项目文件夹即可。本项目不会修改或删除 Codex 的配置和登录状态。

## 免责声明

本项目是社区工具，与 OpenAI 无隶属或官方背书关系。Codex、ChatGPT 和 OpenAI 是其各自权利人的商标。
