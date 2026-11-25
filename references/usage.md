# 多 agent 协作使用手册

**简体中文** · [English](usage.en.md)

下方的 CLI 演练适用于 Windows PowerShell 5.1 或 PowerShell 7。参数和返回值见[协议参考](protocol.md)。

## 接入

让 agent 下载仓库（Git 克隆或 ZIP 解压均可），在**要编辑的项目根目录**调用下载目录里的 `start.ps1`。安装使用本地文件。以下路径换成下载目录的实际位置。

```powershell
$task = & 'D:\downloads\local-fusion-conflict-guard\start.ps1' | ConvertFrom-Json
$guard = $task.guard
$task.peers
& $guard board -Project $task.project
```

核对 `$task.project`，用 `$task.peers` 查看其他 agent 的当前占用，用 `board` 读取共享任务和讨论。后续命令若在新的 shell 运行，请继续使用同一个 `guard` 绝对路径和 `agent` ID。从其他目录启动时用 `-Project` 指定项目。

项目副本位于 `.agents/skills/local-fusion-conflict-guard`。下一个任务可再次运行 `start.ps1`，复用内容相同的安装并获取新身份。若内容不同，启动器会保留原安装。要使用原安装，调用其中的 `scripts/fusion-guard.ps1 join`。另一种方式是在目标项目中运行一次 `git clone https://github.com/wangyuchen5110/local-fusion-conflict-guard.git .agents/skills/local-fusion-conflict-guard`，然后调用其中的 `join`。每个任务只需获取一次身份。

### 操作 Fusion 窗口

假设 A 正在 Fusion 里检查装配，B 在准备图纸。此时 B 仍可修改自己负责的文件、跑测试、读看板。即使图纸属于另一个项目，B 也要等到取得前台后再打开图纸。取得文件占用并不会同时取得前台。

```powershell
$identity = @{ Project = $task.project; Agent = $task.agent }
$turn = & $guard fusion-ui-acquire @identity -Task assembly -Message '检查关节行程' | ConvertFrom-Json
if ($turn.ok) {
    try {
        # 核对当前文档，在这里完成本次连续的 Fusion 操作。
    } finally {
        & $guard fusion-ui-release @identity
    }
} else {
    $turn.holder | Select-Object project,agent,task,message,expiresAt
}
```

MCP 对应的工具为 `fusion_ui_acquire` 和 `fusion_ui_release`，两次使用相同的 agent 标签。每个能向 Fusion 发送命令的 agent 或宿主都需要检查申请结果，包括那些会自动打开文档的命令。交接时保留当前标签，下一位按实际需要选择文档。

### 先看同伴负责什么，再动手

接入后可在同一个终端运行这个演练。A 和 B 共用临时项目和任务名 `status-api`。A 负责接口，B 负责契约测试。B 加入时就能看到 A 的路径和修改目的。

```powershell
$demo = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP ([guid]::NewGuid().ToString('N')))).FullName
$a = & $guard join -Project $demo -Agent api | ConvertFrom-Json
& $guard claim -Project $demo -Agent $a.agent -Task status-api -Message 'Implement GET /status; response field: ready' -Path 'api.ts'
if ($LASTEXITCODE -ne 0) { throw 'API claim failed' }

$b = & $guard join -Project $demo -Agent tests | ConvertFrom-Json
$b.peers | Select-Object agent,path,task,message
& $guard board -Project $demo -Task status-api
& $guard claim -Project $demo -Agent $b.agent -Task status-api -Message 'Test the ready field' -Path 'api.test.ts'
if ($LASTEXITCODE -ne 0) { throw 'Test claim failed' }
& $guard post -Project $demo -Agent tests -Task status-api -Kind question -To api -Message 'Is ready a boolean?'
& $guard post -Project $demo -Agent api -Task status-api -Kind handoff -To tests -Message 'Yes. Assert that ready is true.'
& $guard board -Project $demo -Task status-api
& $guard release -Project $demo -Agent tests
& $guard release -Project $demo -Agent api
```

B 的加入回执中，`peers` 会列出 A 对 `api.ts` 的占用及其意图。第一次读看板，`activeWork` 可见当前占用，`events` 可见计划通知。实际开发时，A 可以实现接口，B 同时在自己的占用范围内编写测试。若意外申请了同一路径，先看 `conflicts` 中的持有人、范围和已说明的意图，向对方留言或另选可做的部分；交接后再重新申请争用路径。

MCP 客户端使用同名的 `board`、`claim`、`post` 工具。给 `board` 传入 `{"task":"status-api"}`，下一次把响应的 `nextAfter` 作为 `after` 继续读。带收件人的留言在这个任务的公共看板里可见。每个 agent 需要主动读取看板，尤其在开始依赖另一方的工作或发出交接消息时。

若两人要改**同一份已有 UTF-8 文件的不同片段**，先读取当前内容并约定各自改哪段。每人可直接调用 `edit`，例如 `{"path":"api.ts","old_text":"timeout: 5","new_text":"timeout: 10","agent":"api"}`。这条路径无需先独占文件，工具会在共用锁内重读最新内容。返回 `stale` 或 `ambiguous` 时，重新读取并选取仍符合修改意图的唯一片段；返回 `claimed` 时先与持有人协调。通过其他编辑器直接写文件仍需先申请路径。

### 可选 MCP 接入

需要 MCP 的宿主可以在完整工具仓库中配置 Python 3.10+。在工具仓库根目录运行以下命令，将示例项目路径换成所有 agent 的目标工作目录。只有 `python` 命令时，用它替换 `py -3`。

```powershell
py -3 --version
py -3 -m venv .venv
$python = (Resolve-Path .\.venv\Scripts\python.exe).Path
& $python -m pip install -r .\requirements-mcp.txt
$server = (Resolve-Path .\scripts\mcp_server.py).Path
$project = (Resolve-Path -LiteralPath 'D:\work\my-project').Path
& $python $server --help
```

### MCP 客户端

在同一 PowerShell 窗口执行与你的客户端对应的命令。使用 `.cmd` 或 `.exe` 入口可以在 npm 同时提供 PowerShell 包装脚本时正确传递 `--`。

**Codex CLI**

```powershell
$codexCli = (Get-Command codex -CommandType Application | Select-Object -First 1).Source
& $codexCli mcp add fusion-guard -- "$python" "$server" --project "$project"
& $codexCli mcp get fusion-guard
```

**Claude Code**

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

Codex 会将名称注册到用户配置，可为不同项目使用不同名称。Claude Code 示例会在目标项目目录创建本机注册。

Cursor 用户将下方条目合并到项目的 `.cursor/mcp.json`，并替换三个示例路径。其他本地 stdio 宿主使用相同的可执行文件和有序参数。 [Cursor MCP 文档](https://cursor.com/docs/mcp)

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

在新的客户端会话中调用 `status`，传 `{}`，确认返回的 `project` 指向目标项目，再用下方的交接演练验证多个任务能看到彼此的占用。

安装 MCP 依赖后，可在工具仓库根目录运行集成测试。

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```

### 可选的用户级 Codex skill

Codex 可以发现项目级安装。若想在多个项目共用一份用户级 skill，可以安装到以下位置。用户级 CLI 默认使用调用时的当前目录，也可显式传 `-Project`。[Codex skill 目录说明](https://learn.chatgpt.com/docs/build-skills)

```powershell
$skillDir = Join-Path $HOME '.agents\skills\local-fusion-conflict-guard'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skillDir) | Out-Null
git clone https://github.com/wangyuchen5110/local-fusion-conflict-guard.git "$skillDir"
Set-Location -LiteralPath $skillDir
```

## 在一个终端演练两名 agent 交接文件

在**工具仓库根目录**打开 PowerShell，按顺序执行下面三段。`$guard` 指向工具本身，`$demo` 是本次演练新建的项目目录。所有参与者都应把同一个项目根目录传给 `-Project` 或 `--project`。

```powershell
$guard = (Resolve-Path -LiteralPath '.\scripts\fusion-guard.ps1').Path
$demo = (New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))) -ErrorAction Stop).FullName
$file = Join-Path $demo 'notes.txt'
$demo

& $guard claim -Project $demo -Agent 'writer-a' -Path 'notes.txt'
if ($LASTEXITCODE -ne 0) { throw 'writer-a 未获得占用' }
Set-Content -LiteralPath $file -Value 'A: first line' -Encoding UTF8
```

`writer-a` 可以提前申请尚未创建的文件。保持其占用，让 `writer-b` 申请相同路径，然后检查登记表。

```powershell
& $guard claim -Project $demo -Agent 'writer-b' -Path 'notes.txt'
if ($LASTEXITCODE -ne 2) { throw '未观察到预期的占用冲突' }
& $guard status -Project $demo
```

第二次申请应返回 `kind: "claim-conflict"`，`conflicts[0].agent` 为 `writer-a`。`status` 应只有 A 的占用。B 暂停对 `notes.txt` 的写入，等待交接。

```powershell
& $guard release -Project $demo -Agent 'writer-a'
& $guard claim -Project $demo -Agent 'writer-b' -Path 'notes.txt'
if ($LASTEXITCODE -ne 0) { throw 'writer-b 未获得占用' }
try {
    Get-Content -LiteralPath $file                  # B 先读到 A 留下的内容
    Add-Content -LiteralPath $file -Value 'B: second line' -Encoding UTF8
} finally {
    & $guard release -Project $demo -Agent 'writer-b'
}
Get-Content -LiteralPath $file
& $guard status -Project $demo
```

验收时，文件应有 `A: first line` 和 `B: second line` 两行，最后一次 `status` 的 `claims` 应为 `[]`。保留这个终端和临时目录，可以继续做下方的监听演练。

## 两个 MCP 客户端怎样交接

在每个客户端的工具列表中找到配置好的 Fusion Guard，分别调用 `status`，传入 `{}`。确认两边返回的 `project` 都是同一个项目绝对路径。以下步骤假设两个任务共用一个服务进程，因此每次显式传入不同的任务名。两个客户端各自启动 stdio 服务进程时，也可以使用完全相同的调用顺序。

| 由谁调用 | 工具 | 传入的 JSON 参数 | 何时继续 |
| --- | --- | --- | --- |
| A | `claim` | `{"agent":"docs-a","paths":["notes.txt"],"ttl_seconds":600}` | `ok: true` 时读取最新文件并编辑。 |
| B | `claim` | `{"agent":"docs-b","paths":["notes.txt","index.txt"]}` | 返回 `ok: false`。这个批次两个路径都没有授予 B；若要先改 `index.txt`，把它单独申请。 |
| A | `release` | `{"agent":"docs-a"}` | `released` 给出释放的占用条数。 |
| B | `claim` | `{"agent":"docs-b","paths":["notes.txt","index.txt"]}` | 成功后重新读取 A 的结果，按最新内容编辑。 |
| B | `release` | `{"agent":"docs-b"}` | 完成这项任务的全部写入后释放。 |

`claim` 的占用冲突是一次正常的工具响应，宿主必须检查返回对象的 `ok`。只检查“工具调用成功”会漏掉冲突。一个独立 MCP 服务进程可以省略 `agent` 并使用默认身份；多个任务共用同一连接时，应在每次申请、续租、释放时沿用各自的任务名。CLI 和 MCP 互相可见，交接顺序相同。

**给 agent 的项目指令。** 把下面这段放入宿主实际会读取的项目说明，或由编排器随任务下发。

> 选择要做的部分前先看共享看板。约定同一个任务名，在申请路径时写明你的修改目的。直接写文件前先确认申请成功并重读文件。在同一任务中提问、报告进展和交接结果。同一文件中的独立小片段可用 `edit` 并检查结果。遇到冲突先与持有人协商，长任务及时续租，写入结束后释放。
>
> 在向 Fusion 界面发送任何操作前调用 `fusion_ui_acquire`。工具报错或前台已被占用时，保留当前窗口和标签，继续做后台工作。取得前台后，等连续的界面操作完成再释放。

若 agent 没有调用工具的能力，宿主可以在创建、覆盖、改名或删除文件的入口代为执行这一流程。改名同时申请原路径和目标路径；格式化或代码生成要把实际会改动的文件也算在内。任务需要独占整个目录时用 `mode: "tree"`。编辑器和外部程序仍能直接写文件，能否预防覆盖取决于它们的写入入口是否执行了同样的申请流程。

**在本地 Fusion 编排器中接入。** 如果一个宿主代表所有 agent 调工具，可以给每个并行任务分配一个独立的任务 ID，让写入入口使用这个 ID 申请和释放。下面是一次短任务的接入逻辑，方法名由宿主自己的 API 决定。

```text
申请这次编辑涉及的全部路径，agent = 当前任务 ID
如果调用报错或申请返回 ok: false，向该任务返回错误或冲突，结束此次编辑
取得占用后，从磁盘读取最新版本，让 agent 基于它生成或核对修改
在租约有效期内执行写入并等待相关子进程结束
在清理步骤中以同一任务 ID 释放占用，即使任务中途取消
```

对使用 Git 的业务项目，可在其忽略规则里加入 `/.codex/fusion-agent-guard/`，让本机的临时占用信息留在工作目录。此规则不影响工具协调。

## 在两个终端观察一次真实写入

**终端 A** 使用刚做完交接演练的终端。先记下下面打印的临时项目路径，再启动监听。看到 `watch-started` 后再到终端 B 写入。

```powershell
$demo
& $guard watch -Project $demo
```

**终端 B** 从工具仓库根目录打开另一个 PowerShell。提示输入目录时，粘贴终端 A 打印的路径。

```powershell
$guard = (Resolve-Path -LiteralPath '.\scripts\fusion-guard.ps1').Path
$demo = Read-Host '粘贴终端 A 的临时项目绝对路径'
& $guard claim -Project $demo -Agent 'watch-demo' -Path 'notes.txt'
if ($LASTEXITCODE -ne 0) { throw 'watch-demo 未获得占用' }
Add-Content -LiteralPath (Join-Path $demo 'notes.txt') -Value 'watch demo' -Encoding UTF8
```

终端 A 应出现 `kind: "filesystem-event"`、`path: "notes.txt"` 的记录。`activeClaims` 显示监听器处理该事件时覆盖这个路径的占用，操作系统事件本身没有提供写入者的 agent 身份。一次保存可能产生多条事件。看到记录后，在终端 B 执行释放，然后在终端 A 按 `Ctrl+C` 结束监听。

```powershell
& $guard release -Project $demo -Agent 'watch-demo'
```

需要有界观察时，用 `& $guard watch -Project $demo -DurationSeconds 10 -MaxEvents 20`。MCP 端可调用 `watch_changes` 并传入 `{"seconds":10}`，由另一个客户端在观察窗口内产生写入。它会返回该窗口的 `events`，安静时为 `[]`，达到返回条数上限时 `limit_reached` 为 `true`。两次调用之间的历史事件无法补读。持续观察用 CLI 的 `watch`。

## 长任务、崩溃和恢复

- **继续做同一项工作**：在 `expiresAt` 之前，用同一身份再次 `claim` 原路径和原 `mode`。只续期实际传入的路径，如持有多个文件需把仍在编辑的都列出。成功后按新返回的到期时间安排下一次续期。
- **已到期或结果不明**：暂停写入。重新申请路径并检查 `ok`，成功后重新读磁盘版本，将未完成的改动与最新内容核对。`status` 只提供当下的快照，能否继续写以最近一次申请和其有效期为准。
- **客户端崩溃或重启**：新 MCP 进程有新的默认身份，命名任务也带上了新的进程前缀。查看 `status` 中旧占用的 `expiresAt`，等待到期，并确认旧任务已停止写入，再由新任务申请。CLI 的 `cleanup` 可移除已到期记录，正常申请或查询也会清理过期记录。
- **完成或取消任务**：在原连接用原任务名 `release`。一次会释放该身份的全部路径，因此并行子任务应使用不同名称。

## 故障诊断

| 现象 | 检查方法与处理 |
| --- | --- |
| 一个 agent 操作期间 Fusion 仍跳到另一标签 | 两个会话分别调用 `fusion-ui-status`，应看到同一持有人。确认每个会话已读入新版 skill 或重连新版 MCP，使用各自的身份，并在每组界面操作前检查申请结果的 `ok`。直接发送界面输入的宿主也要在发送命令的入口做这项检查。 |
| 两个客户端看不到对方的占用 | 两边都调用 `status`，逐项核对 `project`，并确认任务在同一份本地工作树中。如需纠正目标，CLI 可传 `-Project`。同一 MCP 连接里的任务要分别命名。 |
| `claim` 返回冲突 | 核对 `conflicts[].agent`、`path`、`mode`、`expiresAt`。上层目录的 `tree` 占用也会覆盖当前文件。等待交接或先单独申请无关路径。 |
| MCP 未列出工具，或提示缺少 `mcp` 模块 | 核对客户端配置里的 Python、`mcp_server.py` 和项目三个绝对路径。用配置里的那个 Python 执行 `-m pip show mcp`；需要安装时按[接入](#接入)说明在同一环境执行安装命令，之后重新连接。 |
| 注册时报 `unknown option '--project'` | 在 Windows PowerShell 中按[接入](#接入)说明选用客户端的 `.exe` 或 `.cmd`，把 `--` 放在服务名与解释器之间，再检查保存的启动参数。 |
| PowerShell 提示禁止执行脚本 | 在运行脚本的 PowerShell 中用 `Get-ExecutionPolicy -List` 查看生效策略，按当前机器允许的脚本运行方式处理。MCP 也会调用同一份 PowerShell 脚本。 |
| 提示项目不存在、路径越界或拒绝访问 | `--project` 必须是已存在、可写入协调数据的目录，`paths` 相对于它。核对 `status.project` 和文件位置，确认当前用户能访问该项目的 `.codex` 目录。 |
| 状态读取失败、锁等待超时或出现 `Cannot read claim file` | 暂停写入，保留报错及其路径。先核对磁盘与访问权限、其他客户端是否仍在工作，再重试 `status`。记录损坏时先停止所有参与者、备份并核对报错指向的记录，恢复一致后重新申请。 |
| 文件已保存，但没有监听记录 | 先启动监听再保存，核对目录和时间窗口。项目根的 `.git` 和工具自身状态路径会被过滤。监听中断后，重新开启并检查实际文件或 Git 差异。 |

## 更新、停用和卸载

更新前完成或暂停写入，释放各任务占用并关闭监听、断开 MCP 连接。在**工具仓库根目录**确认 `git status --short`，处理好本地修改，再更新代码。使用 MCP 的安装还需在原虚拟环境刷新依赖。

```powershell
git pull --ff-only
# 使用 MCP 的安装执行下一行
.\.venv\Scripts\python.exe -m pip install -r requirements-mcp.txt
```

若使用 ZIP 下载，将新版解压到新目录。要更新 `start.ps1` 安装的项目副本，先停止参与任务，核对旧的专用 skill 目录，将它移至备份位置，再对该项目运行新版启动器。重连后运行 `status` 核对项目路径，并用上述双任务演练检查交接。

停用时，先释放占用并关闭监听。Codex CLI 里注册名为 `fusion-guard` 的服务可用 `codex mcp remove fusion-guard` 移除；若使用其他名称，换成实际注册名。JSON 客户端只需移除本工具的 `mcpServers` 条目并重新连接，同时移除为本工具添加的项目指令。按需移除专用的 skill 安装副本、工具克隆及其虚拟环境。项目中的 `.codex/fusion-agent-guard/` 仅保存协调数据，全部参与者停用后可保留，或核实这个专用子目录后手动清理。业务源码和其他 `.codex` 配置属于项目本身。

使用上述项目本地注册方式的 Claude Code 用户，可在原目标项目目录运行 `claude mcp remove --scope local fusion-guard` 移除该项目的本地注册。
