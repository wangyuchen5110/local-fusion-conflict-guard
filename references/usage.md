# 多 agent 协作使用手册

**简体中文** · [English](usage.en.md)

第一次使用，先做下面的文件交接演练。它只需要 Windows PowerShell 5.1 或 PowerShell 7，使用临时项目，无须安装 Python。要让实际客户端调用工具，参见[安装与客户端配置](../README.zh-CN.md)。查默认值、返回字段或路径匹配规则，见[协议参考](protocol.md)。

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

> 在准备编辑某个文件时，先向 Fusion Guard 一次申请本次需要写入的路径。申请成功后读取文件当前版本。遇到占用冲突、工具错误或租约到期时暂停这些路径的写入；重新取得占用后再读取并继续。长任务在到期前续租。任务结束时释放该身份持有的全部占用。

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
| 两个客户端看不到对方的占用 | 两边都调用 `status`，逐项核对 `project`，并确认任务在同一份本地工作树中。CLI 总是显式传 `-Project`。同一 MCP 连接里的任务要分别命名。 |
| `claim` 返回冲突 | 核对 `conflicts[].agent`、`path`、`mode`、`expiresAt`。上层目录的 `tree` 占用也会覆盖当前文件。等待交接或先单独申请无关路径。 |
| MCP 未列出工具，或提示缺少 `mcp` 模块 | 核对客户端配置里的 Python、`mcp_server.py` 和项目三个绝对路径。用配置里的那个 Python 执行 `-m pip show mcp`；需要安装时按 README 在同一环境执行安装命令，之后重新连接。 |
| 注册时报 `unknown option '--project'` | 在 Windows PowerShell 中按 README 选用客户端的 `.exe` 或 `.cmd`，把 `--` 放在服务名与解释器之间，再检查保存的启动参数。 |
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

若 skill 是从仓库复制出来的，按原安装方式同步副本。重连后运行 `status` 核对项目路径，并用上述双任务演练检查交接。

停用时，先释放占用并关闭监听。Codex CLI 里注册名为 `fusion-guard` 的服务可用 `codex mcp remove fusion-guard` 移除；若使用其他名称，换成实际注册名。JSON 客户端只需移除本工具的 `mcpServers` 条目并重新连接，同时移除为本工具添加的项目指令。按需移除专用的 skill 安装副本、工具克隆及其虚拟环境。项目中的 `.codex/fusion-agent-guard/` 仅保存协调数据，全部参与者停用后可保留，或核实这个专用子目录后手动清理。业务源码和其他 `.codex` 配置属于项目本身。

按 README 在 Claude Code 注册过的用户，可在原目标项目目录运行 `claude mcp remove --scope local fusion-guard` 移除该项目的本地注册。
