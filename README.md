# Local Fusion Conflict Guard

让多个本地 agent 在修改同一份 Windows 工作目录之前，先确认谁在编辑哪些文件。支持 stdio MCP 的 agent 可直接调用工具，能运行 PowerShell 的 agent 可走命令行。两种入口都使用项目里的 `.codex/fusion-agent-guard/`，所以 MCP 和 CLI 客户端之间也能发现冲突。

## 接入 MCP

需要 Windows、PowerShell 和 Python 3.10 或更高版本。下面在 PowerShell 中克隆并安装到独立虚拟环境，示例用 Python 3.12。

```powershell
git clone https://github.com/wangyuchen5110/local-fusion-conflict-guard.git
Set-Location local-fusion-conflict-guard
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-mcp.txt
```

给编辑**同一工作目录**的所有客户端填写同一个 `--project` 绝对路径。支持 `mcpServers` 配置的客户端可以使用下面的 JSON。将前两个路径替换为刚克隆的工具位置，最后一个替换为要编辑的项目位置。

```json
{
  "mcpServers": {
    "fusion-guard": {
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

Codex CLI 用户也可以在刚克隆的工具目录里注册同一个服务。将 `D:\work\my-project` 换成已存在的项目目录。

```powershell
$python = (Resolve-Path .\.venv\Scripts\python.exe).Path
$server = (Resolve-Path .\scripts\mcp_server.py).Path
$project = (Resolve-Path 'D:\work\my-project').Path
codex mcp add fusion-guard -- "$python" "$server" --project "$project"
```

接入后调用 `status` 检查返回的项目根目录。每个独立的 MCP 服务进程都有自己的默认身份。如果宿主将多个 agent 路由到同一个 MCP 连接，为每个任务分配唯一的 `agent` 名称，并在该任务每次 `claim` 和 `release` 时传入同一个名称。

| MCP 工具 | 用法 |
| --- | --- |
| `claim` | 编辑前调用，例如 `{"paths":["src/api.ts"],"mode":"file","ttl_seconds":600,"agent":"api-task-42"}`。返回 `ok: true` 后再编辑。占用目录及其子文件时使用 `tree`。 |
| `status` | 查看当前占用者、路径和到期时间。 |
| `release` | 例如 `{"agent":"api-task-42"}`，释放该身份的全部占用。 |
| `watch_changes` | 例如 `{"seconds":3}`，取得接下来三秒内观察到的变更。每次可观察 1–15 秒，最多返回 100 条事件。需要持续观察时启动下方的前台 CLI 监听。 |

## 通过 PowerShell 接入

只有 shell 工具的 agent 可以直接运行仓库里的脚本。下面两个身份代表独立任务，第二次申请会返回冲突以及退出码 `2`。

```powershell
$guard = (Resolve-Path .\scripts\fusion-guard.ps1).Path
$project = 'D:\work\my-project'
& $guard claim -Project $project -Agent 'task-a' -Path 'src/api.ts'
& $guard claim -Project $project -Agent 'task-b' -Path 'src/api.ts'
& $guard release -Project $project -Agent 'task-a'
```

持续监听可在另一个 PowerShell 窗口运行 `& $guard watch -Project $project`（先设置同样的变量）。文件事件显示变更路径和覆盖它的声明。占用者由 agent 声明，实际写入者的身份需要由宿主提供。

## 让每个 agent 都实际使用

把这段约定放进各 agent 会读取的项目指令，或由编排器在每个任务开始时传入：

> 编辑前用 Fusion Guard 的 `claim` 一次申请本次要改的路径。拿到占用后重新读取文件再修改。遇到冲突或工具错误就暂停这些路径的写入。长任务在到期前用同一身份重新申请，完成后调用 `release`。

对既不能调用 MCP 也不能执行命令的 agent，可以在宿主的写文件入口代为申请，成功后再执行编辑。只有实际接入该流程的写入操作才能得到编辑前的冲突保护。[完整协议](references/protocol.md)
