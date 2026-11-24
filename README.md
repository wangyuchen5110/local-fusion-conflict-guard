# Local Fusion Conflict Guard

**简体中文** · [English](README.en.md)

多个本地 agent 在同一份 Windows 工作目录里改代码时，先申请要改的路径。比如 A 已占用 `src/api.ts`，B 再申请同一文件会收到冲突和到期时间，但仍可单独申请 `src/ui.ts`。A 释放后，B 重新申请、读取最新文件，再接着改。监听器可以同时显示磁盘上实际发生的变化。

| 你的环境 | 接入方式 | 需要准备 |
| --- | --- | --- |
| 能运行本地命令的 agent 或编排器 | PowerShell CLI | Windows PowerShell 5.1 或 PowerShell 7 |
| 支持本地 stdio MCP 的客户端 | 客户端启动本仓库的 MCP Server | Windows、PowerShell、Python 3.10+ |
| Codex 需要自动找到协作指令 | 安装本仓库的 skill，搭配 CLI 或 MCP | 能读取该 skill 的 Codex 环境 |
| agent 本身只能生成编辑内容 | 由宿主在实际写文件前申请占用 | 宿主能调用上述任一入口，并控制写入 |

所有参与方都要指向**同一个已有的项目根目录**，并能读写其中的 `.codex/fusion-agent-guard/`。每份 checkout 或 Git worktree 各有自己的占用记录。绕过申请的程序仍然能写文件，监听事件也无法证明哪一个进程写了它。

## 下载与首次验证

在 PowerShell 中进入你希望存放工具的目录，执行以下命令。如果已有本仓库，直接进入它，从 `$toolRoot` 那一行开始。

```powershell
git clone https://github.com/wangyuchen5110/local-fusion-conflict-guard.git
Set-Location .\local-fusion-conflict-guard
$toolRoot = (Get-Location).Path
$guard = Join-Path $toolRoot 'scripts\fusion-guard.ps1'
```

先用临时目录做一次交接。这个例子只创建占用记录，`hello.txt` 可以是准备新建的文件。直接走 CLI 即可完成，无需安装 Python。

```powershell
$demo = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP ([guid]::NewGuid().ToString()))).FullName
& $guard claim -Project $demo -Agent 'writer-a' -Path 'hello.txt'
& $guard claim -Project $demo -Agent 'writer-b' -Path 'hello.txt'
$LASTEXITCODE   # 2，第二次申请冲突
& $guard release -Project $demo -Agent 'writer-a'
& $guard claim -Project $demo -Agent 'writer-b' -Path 'hello.txt'
$LASTEXITCODE   # 0，B 已接手
& $guard release -Project $demo -Agent 'writer-b'
& $guard status -Project $demo
```

最后一条命令应返回 `"claims":[]`。要看两个任务实际改文件、先后读到对方的内容，以及如何在另一个终端实时监听，请看[使用手册](references/usage.md)。

## 接入 MCP

工具目录存放 `mcp_server.py` 和解释器，项目目录是 agent 真正要编辑的代码。工具可以装一份供多个项目使用。以下命令接着在前面的 PowerShell 窗口执行，将 `$project` 一行的示例路径换成已有项目，也可先用 `$project = $demo` 验证。

```powershell
Set-Location -LiteralPath $toolRoot
py -3 --version
py -3 -m venv .venv
$python = (Resolve-Path .\.venv\Scripts\python.exe).Path
& $python -m pip install -r .\requirements-mcp.txt
$server = (Resolve-Path .\scripts\mcp_server.py).Path
$project = (Resolve-Path -LiteralPath 'D:\work\my-project').Path
& $python $server --help
```

确认 `py -3 --version` 为 3.10 或更高。只有 `python` 命令时，用它执行前两条 `py -3` 命令对应的 `--version` 和 `-m venv .venv`。安装完成后由客户端通过标准输入输出启动服务，无需监听端口、填写 URL 或配置 API 密钥。

### Codex CLI

Windows 的 npm 安装可能同时提供同名的 PowerShell 包装脚本和命令行程序。下面显式选用 `.cmd` 或 `.exe`，让分隔符 `--` 原样传给客户端。

```powershell
$codexCli = (Get-Command codex -CommandType Application | Select-Object -First 1).Source
& $codexCli mcp add fusion-guard -- "$python" "$server" --project "$project"
& $codexCli mcp get fusion-guard
```

此命令在当前 Codex 用户配置中注册服务，服务绑定到 `$project`。若要同时配置多个项目，可分别命名为 `fusion-guard-api`、`fusion-guard-web`。在新的客户端会话里调用对应服务的 `status`，确认返回的 `project` 与当前工作目录指向同一项目。

### Claude Code

在目标项目下注册到本机的项目范围。以下命令复用上面的三个绝对路径变量。

```powershell
$claudeCli = (Get-Command claude -CommandType Application | Select-Object -First 1).Source
Push-Location -LiteralPath $project
try {
    & $claudeCli mcp add --scope local --transport stdio fusion-guard -- "$python" "$server" --project "$project"
    & $claudeCli mcp get fusion-guard
} finally {
    Pop-Location
}
```

### Cursor 和其他支持本地 stdio 的宿主

Cursor 可在目标项目的 `.cursor/mcp.json` 中加入以下配置。将三个示例路径换成实际值。如果文件里已有其他服务，只合并 `fusion-guard` 这一项。其他客户端可在自己的 MCP 设置中填写同一条 `command` 和相同顺序的 `args`。[Cursor 配置文档](https://cursor.com/docs/mcp)

```json
{
  "mcpServers": {
    "fusion-guard": {
      "type": "stdio",
      "command": "D:/tools/local-fusion-conflict-guard/.venv/Scripts/python.exe",
      "args": [
        "D:/tools/local-fusion-conflict-guard/scripts/mcp_server.py",
        "--project",
        "D:/work/my-project"
      ]
    }
  }
}
```

### 确认客户端已经连通

在客户端调用这些工具。表中的 JSON 是工具参数，可交给 agent 代为调用。

| 顺序 | 工具 | 参数 | 应看到的结果 |
| --- | --- | --- | --- |
| 1 | `status` | `{}` | `project` 指向预期目录 |
| 2 | `claim` | `{"paths":["guard-demo.txt"],"agent":"demo-a"}` | `ok: true`，返回到期时间 |
| 3 | `claim` | `{"paths":["guard-demo.txt"],"agent":"demo-b"}` | `ok: false`，`conflicts` 列出占用者 |
| 4 | `release` | `{"agent":"demo-a"}` | `released: 1` |
| 5 | `watch_changes` | `{"seconds":2}` | 调用窗口内的事件，无变更时 `events` 为空数组 |

请在空项目或无同名占用的演示目录里执行此表，五步使用同一 MCP 连接。每个服务进程有自己的默认身份；同一连接承载多个任务时，每个任务要在申请、续租和释放时始终使用自己的 `agent` 名称。

## 让 agent 在编辑前使用

把下面这段放进参与方实际读取的项目指令，例如 Codex 项目的 `AGENTS.md`，也可以作为任务指令交给编排器。

> 修改前，用 Fusion Guard 的 `claim` 一次申请本次要写的路径。申请成功后重读文件再修改；冲突、工具错误或租约已经过期时暂停对这些路径的写入。长任务在到期前用同一身份、路径和范围续租。所有相关写入结束后调用 `release`。共享连接的多个任务各自使用唯一的任务名。

如果 Codex 还需要通过 `$local-fusion-conflict-guard` 调用这份工作流程，可以把完整仓库安装在用户 skill 目录。在首次克隆时用以下命令**替代**“下载与首次验证”里的前两行，其余步骤相同。已有能在 skill 列表里找到的安装时，直接使用现有副本。[Codex skill 目录说明](https://learn.chatgpt.com/docs/build-skills)

```powershell
$skillDir = Join-Path $HOME '.agents\skills\local-fusion-conflict-guard'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skillDir) | Out-Null
git clone https://github.com/wangyuchen5110/local-fusion-conflict-guard.git "$skillDir"
Set-Location -LiteralPath $skillDir
```

可以在 Codex 中试用这句任务指令：“使用 `$local-fusion-conflict-guard`，在当前项目申请 `src/api.ts`，若有其他任务占用就告诉我持有人和到期时间。”skill 提供工作流程；MCP 工具通过上面的客户端注册步骤启用。

## 验证与查阅

在工具仓库根目录运行集成测试。测试会在临时项目中启动真实的 stdio MCP 客户端和 PowerShell 进程，覆盖并发争用、CLI 交接、共享连接身份和文件监听。

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```

- [使用手册](references/usage.md) — 双 agent 编辑演练、实时监听、故障排查、更新和撤销接入。
- [命令与协议参考](references/protocol.md) — 五个 CLI 命令、四个 MCP 工具、参数范围、返回字段、退出码和冲突判定。
- [给 agent 的操作指令](SKILL.md) — 可由 Codex 加载的工作流程。
