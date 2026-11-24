# Local Fusion Conflict Guard

[简体中文](README.md) · **English**

Coordinate local agents editing the same Windows working tree. If agent A claims `src/api.ts`, agent B's request for that file returns a conflict with the holder and expiration time. B can still claim `src/ui.ts`. When A releases its claim, B can claim `src/api.ts`, read A's latest changes and carry on. A watcher lets either agent observe changes on disk during the handoff.

| If you use… | Connect through | Requirements |
| --- | --- | --- |
| An agent or orchestrator that runs local commands | PowerShell CLI | Windows PowerShell 5.1 or PowerShell 7 |
| A client that supports local stdio MCP servers | The MCP server included here | Windows, PowerShell and Python 3.10+ |
| Codex with discoverable task instructions | The optional skill, together with the CLI or MCP server | A Codex environment that can load the skill |
| An agent that produces edits for another process to apply | A host that claims paths before applying those edits | The host controls the write and can call the CLI or MCP server |

Point every participant at **the same existing project root**. Each needs read and write access to `.codex/fusion-agent-guard/` inside it. Each checkout or Git worktree has its own registry. Claims depend on cooperation. A program can still write directly to disk, and a filesystem event alone cannot identify the writer.

## Download and try a handoff

Open PowerShell in the directory where you want to keep the tool. If you already have a clone, open it and start at the `$toolRoot` line.

```powershell
git clone https://github.com/wangyuchen5110/local-fusion-conflict-guard.git
Set-Location .\local-fusion-conflict-guard
$toolRoot = (Get-Location).Path
$guard = Join-Path $toolRoot 'scripts\fusion-guard.ps1'
```

Try two agents against a fresh temporary project. The CLI demo works with PowerShell alone. A claim can cover a file an agent plans to create, so `hello.txt` need not exist.

```powershell
$demo = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP ([guid]::NewGuid().ToString()))).FullName
& $guard claim -Project $demo -Agent 'writer-a' -Path 'hello.txt'
& $guard claim -Project $demo -Agent 'writer-b' -Path 'hello.txt'
$LASTEXITCODE   # 2: B's claim conflicts with A's
& $guard release -Project $demo -Agent 'writer-a'
& $guard claim -Project $demo -Agent 'writer-b' -Path 'hello.txt'
$LASTEXITCODE   # 0: B now holds the claim
& $guard release -Project $demo -Agent 'writer-b'
& $guard status -Project $demo
```

The final result should include `"claims":[]`. For a walkthrough in which two agents actually edit the file and a second terminal shows the changes, see the [usage guide](references/usage.en.md).

## Connect through MCP

The **tool directory** contains the server script and its virtual environment. The **project directory** is the working tree the agents will edit. One tool installation can serve several projects. Continue in the same PowerShell window, replacing `D:\work\my-project` with an existing project. For a first test, use `$project = $demo` instead.

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

Check that the version is 3.10 or newer. If you have `python` instead of the Windows `py` launcher, use `python --version` and `python -m venv .venv`. The client starts the server and communicates over standard input and output. The launch configuration only needs a command and its arguments.

### Codex CLI

An npm installation on Windows may provide both a PowerShell wrapper and a command-line executable named `codex`. Select the `.cmd` or `.exe` entry point so PowerShell passes the `--` separator to the client.

```powershell
$codexCli = (Get-Command codex -CommandType Application | Select-Object -First 1).Source
& $codexCli mcp add fusion-guard -- "$python" "$server" --project "$project"
& $codexCli mcp get fusion-guard
```

This registers the server in your Codex user configuration and binds it to `$project`. To use several projects, give each registration a distinct name such as `fusion-guard-api` or `fusion-guard-web`. In a new client session, call that server’s `status` tool and confirm that `project` identifies the working tree you intend to edit.

### Claude Code

Register the server for your local user in the target project. These commands use the absolute paths from the MCP setup above.

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

### Cursor and other local stdio clients

In Cursor, add the following entry to the target project's `.cursor/mcp.json`. Replace the three example paths with your own. If the file already lists servers, add only the `fusion-guard` entry under `mcpServers`. Other stdio clients can use the same command and ordered arguments in their MCP settings. [Cursor MCP documentation](https://cursor.com/docs/mcp)

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

### Check the connection

In the client, run these five calls on the **same MCP connection** in a demo project where `guard-demo.txt` is available. You can ask the agent to make the calls with the listed JSON arguments.

| Step | Tool | Arguments | Expected result |
| --- | --- | --- | --- |
| 1 | `status` | `{}` | `project` points to the expected directory. |
| 2 | `claim` | `{"paths":["guard-demo.txt"],"agent":"demo-a"}` | `ok: true` and an expiration time. |
| 3 | `claim` | `{"paths":["guard-demo.txt"],"agent":"demo-b"}` | `ok: false` and a `conflicts` entry naming the holder. |
| 4 | `release` | `{"agent":"demo-a"}` | `released: 1`. |
| 5 | `watch_changes` | `{"seconds":2}` | Events observed in the two-second window. In a quiet project, `events` is an empty array. |

Each server process has a unique default identity. When several tasks share one connection, give each a unique `agent` name and use it consistently for claims, renewals and releases.

## Have agents claim paths before editing

Add this instruction to a project file your agents read, such as `AGENTS.md` for Codex. An orchestrator can also pass it to each task.

> Before editing, call Fusion Guard’s `claim` with all the paths you plan to write. Once the claim succeeds, reread the files and edit the latest versions. Pause writes to those paths on a conflict, tool error or expired lease. For long tasks, renew before expiry with the same identity, paths and scope. Call `release` after all writes finish. Give each task on a shared connection its own name.

To invoke this workflow as `$local-fusion-conflict-guard` in Codex, clone the repository into your user skill directory. On first installation, the following commands replace the first two lines in [Download and try a handoff](#download-and-try-a-handoff). Continue at the `$toolRoot` line. If the skill already appears in Codex, use the existing installation. [Codex skill directories](https://learn.chatgpt.com/docs/build-skills)

```powershell
$skillDir = Join-Path $HOME '.agents\skills\local-fusion-conflict-guard'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skillDir) | Out-Null
git clone https://github.com/wangyuchen5110/local-fusion-conflict-guard.git "$skillDir"
Set-Location -LiteralPath $skillDir
```

Try this prompt in Codex: “Use `$local-fusion-conflict-guard` to claim `src/api.ts` in the current project. If another task holds it, tell me the holder and the expiration time.” The skill supplies the workflow. Register the server in your client to enable its MCP tools.

## Tests and reference

Run the integration tests from the **tool repository root** after installing the MCP dependencies. They launch real stdio clients and PowerShell processes against temporary projects to exercise concurrent claims, handoffs with the CLI, identities on a shared connection and file watching.

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```

- [Usage guide](references/usage.en.md) — two-agent editing walkthrough, live monitoring, troubleshooting, updates and disconnecting.
- [Command and protocol reference](references/protocol.en.md) — all five CLI commands and four MCP tools, parameter ranges, output, exit codes and overlap rules.
- [Instructions for agents](SKILL.en.md) — English companion to the workflow that Codex loads from `SKILL.md`.
