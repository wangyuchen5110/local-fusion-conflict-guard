# Working with multiple agents

[简体中文](usage.md) · **English**

The CLI walkthrough below uses Windows PowerShell 5.1 or PowerShell 7. For tool parameters and return values, see the [protocol reference](protocol.en.md).

## Setup

Have the agent download the repository (Git clone or ZIP) and run the downloaded `start.ps1` from the **root of the project it will edit**. Installation uses local files. Substitute the actual download location below.

```powershell
$task = & 'D:\downloads\local-fusion-conflict-guard\start.ps1' | ConvertFrom-Json
$guard = $task.guard
$task.peers
& $guard board -Project $task.project
```

Check `$task.project` and inspect `$task.peers` for live claims by other agents. `board` adds the shared task conversation. If a later command runs in a fresh shell, reuse the same literal `guard` path and `agent` ID. Use `-Project` to select the project when launching from another directory.

The project copy lives under `.agents/skills/local-fusion-conflict-guard`. Another task can rerun `start.ps1` to reuse a matching installation and get its own identity. A mismatch leaves the existing files in place. To use the existing installation, call its `scripts/fusion-guard.ps1 join`. Alternatively, from the target project, run `git clone https://github.com/wangyuchen5110/local-fusion-conflict-guard.git .agents/skills/local-fusion-conflict-guard` once and call `join` in that clone. Obtain one identity per task.

### Working in the Fusion window

Suppose A is checking the assembly while B prepares a drawing. B can edit its own files, run tests and read the board while A uses Fusion. Even if the drawing belongs to another project, B waits until it can acquire the UI before opening it in Fusion. A file claim alone gives no turn at the UI.

```powershell
$identity = @{ Project = $task.project; Agent = $task.agent }
$turn = & $guard fusion-ui-acquire @identity -Task assembly -Message 'Check joint limits' | ConvertFrom-Json
if ($turn.ok) {
    try {
        # Check the active document, then perform and finish the related Fusion steps here.
    } finally {
        & $guard fusion-ui-release @identity
    }
} else {
    $turn.holder | Select-Object project,agent,task,message,expiresAt
}
```

The same workflow uses `fusion_ui_acquire` and `fusion_ui_release` over MCP. Reuse the same agent label for both. Each agent or host that sends UI commands must honor the result, including for commands that implicitly open a document. During a handoff, leave the current tab in place. The next holder selects its target when its work needs it.

### Share the plan before touching a file

Run this exercise in one terminal after setup. A and B share a temporary project and the task name `status-api`. A takes the endpoint while B starts its contract test. The public claim tells B what A is doing before either agent touches a file.

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

At B's join, `peers` contains A's `api.ts` claim and its purpose. The first board read shows both the live lease in `activeWork` and the plan in `events`. In a real task A can implement the endpoint while B writes the test under its own lease. An unexpected conflict identifies the holder, path and available intent in `conflicts`. Contact the holder on the board and choose a free path; retry the contested path only after a handoff.

MCP clients use the same `board`, `claim` and `post` operations with snake_case arguments. Pass `{"task":"status-api"}` to `board`; to request the next messages, reuse the returned `nextAfter` as `after`. An addressed note remains visible to everyone reading this task. Agents see new messages when they check the board, so read it again before dependent work or after publishing a handoff.

For two small changes to **different passages of one existing UTF-8 file**, read the current file and agree on separate literals. Each participant can call `edit`, e.g. `{"path":"api.ts","old_text":"timeout: 5","new_text":"timeout: 10","agent":"api"}`, without taking an exclusive lease. The guard rereads the file under the shared lock. On `stale` or `ambiguous`, read it again and choose a unique literal that still matches the intended edit. Respect any `claimed` conflict. For direct writes through an editor, continue to claim paths first.

### Optional MCP setup

For an MCP host, configure Python 3.10+ in the full tool repository. Run these commands from the tool repository root and substitute the project the agents will edit. If you have the `python` launcher, use `python` in place of `py -3`.

```powershell
py -3 --version
py -3 -m venv .venv
$python = (Resolve-Path .\.venv\Scripts\python.exe).Path
& $python -m pip install -r .\requirements-mcp.txt
$server = (Resolve-Path .\scripts\mcp_server.py).Path
$project = (Resolve-Path -LiteralPath 'D:\work\my-project').Path
& $python $server --help
```

### MCP clients

Run the block for your client in the same PowerShell window. The `.cmd` or `.exe` entry point preserves `--` when an npm PowerShell wrapper is installed.

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

Codex registers the name in your user configuration. Use a distinct name for each project. Claude Code uses a local registration in the project directory.

In Cursor, merge the entry below into the project’s `.cursor/mcp.json`, replacing the three example paths. Other local stdio hosts use the same executable and ordered arguments. [Cursor MCP documentation](https://cursor.com/docs/mcp)

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

In a fresh client session, call `status` with `{}` and verify that `project` is your target directory. Try the handoff exercise below to verify cooperation.

After installing the MCP dependencies, run the integration suite from the tool repository.

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```

### Optional user-wide Codex skill

Codex can discover the project install. If you want one skill across multiple projects, use the location below. The CLI in a user-wide install defaults to the current working directory. Use `-Project` to override it. [Codex skill directories](https://learn.chatgpt.com/docs/build-skills)

```powershell
$skillDir = Join-Path $HOME '.agents\skills\local-fusion-conflict-guard'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skillDir) | Out-Null
git clone https://github.com/wangyuchen5110/local-fusion-conflict-guard.git "$skillDir"
Set-Location -LiteralPath $skillDir
```

## Hand a file from one agent to another in a single terminal

Open PowerShell at the **root of the tool repository**. Run these three blocks in sequence. `$guard` points to the PowerShell script and `$demo` is a fresh project directory. Every participant must pass the same project root to `-Project` or `--project`.

```powershell
$guard = (Resolve-Path -LiteralPath '.\scripts\fusion-guard.ps1').Path
$demo = (New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))) -ErrorAction Stop).FullName
$file = Join-Path $demo 'notes.txt'
$demo

& $guard claim -Project $demo -Agent 'writer-a' -Path 'notes.txt'
if ($LASTEXITCODE -ne 0) { throw 'writer-a could not claim the file' }
Set-Content -LiteralPath $file -Value 'A: first line' -Encoding UTF8
```

`writer-a` can claim the path before the file exists. While A holds that claim, have `writer-b` request the same path and inspect the registry.

```powershell
& $guard claim -Project $demo -Agent 'writer-b' -Path 'notes.txt'
if ($LASTEXITCODE -ne 2) { throw 'Expected a claim conflict' }
& $guard status -Project $demo
```

B's request should return `kind: "claim-conflict"` with `conflicts[0].agent` set to `writer-a`. The only claim listed by `status` should be A's. B pauses edits to `notes.txt` until the handoff.

```powershell
& $guard release -Project $demo -Agent 'writer-a'
& $guard claim -Project $demo -Agent 'writer-b' -Path 'notes.txt'
if ($LASTEXITCODE -ne 0) { throw 'writer-b could not claim the file' }
try {
    Get-Content -LiteralPath $file                  # B reads A's edit first
    Add-Content -LiteralPath $file -Value 'B: second line' -Encoding UTF8
} finally {
    & $guard release -Project $demo -Agent 'writer-b'
}
Get-Content -LiteralPath $file
& $guard status -Project $demo
```

The file should contain `A: first line` followed by `B: second line`, and the last `status` response should show `claims: []`. Keep this terminal and temporary directory open for the watcher exercise below.

## Hand off edits between MCP clients

Find the configured Fusion Guard tools in each client and call `status` with `{}`. Check that `project` is the same absolute path in both results. The example uses distinct task labels so it also works when both tasks share an MCP connection. Independent clients that launch their own stdio servers can follow the same sequence.

| Caller | Tool | JSON arguments | Expected result and next action |
| --- | --- | --- | --- |
| A | `claim` | `{"agent":"docs-a","paths":["notes.txt"],"ttl_seconds":600}` | On `ok: true`, read the current file and edit it. |
| B | `claim` | `{"agent":"docs-b","paths":["notes.txt","index.txt"]}` | `ok: false`. The conflict rejects both paths in this request. To work on `index.txt` now, request it separately. |
| A | `release` | `{"agent":"docs-a"}` | `released` gives the number of claims A released. |
| B | `claim` | `{"agent":"docs-b","paths":["notes.txt","index.txt"]}` | After success, read A's changes before editing. |
| B | `release` | `{"agent":"docs-b"}` | Release after all writes for this task have finished. |

The server returns a claim conflict as an ordinary MCP tool result. Check the result's `ok` field before allowing an edit. A task with a dedicated server process can omit `agent` and use that process's default identity. On a shared connection, send a distinct task label and retain it for each claim, renewal and release. CLI and MCP clients see the same claims and follow the same handoff sequence.

**Project instructions for agents.** Put the following in a project instructions file your host reads, or include it in each task sent by your orchestrator.

> Read the board before choosing work. Identify the shared task and include your intention and paths in your claim. Check the result before any direct write, then reread the files. Ask questions, report progress and hand off results in the same task. For small distinct passages of one file, use the guarded `edit` tool and inspect its result. Reconcile conflicts with the holder before retrying. Renew leases before they expire and release them after all writes finish.
>
> Before sending anything to the Fusion UI, call `fusion_ui_acquire`. On a tool error or a busy result, keep the current window and tab in place. Work in the background until handoff. Release the UI after your last related action finishes.

If an agent cannot call tools, its host can follow the same procedure when creating, overwriting, renaming or deleting files. Claim both the old and new paths for a rename. Include files that formatters or generators will change. Use `mode: "tree"` when a task needs exclusive access to a directory and its descendants. Editors and other processes can write directly to disk. To protect their writes, integrate the claim check into those entry points too.

**Local Fusion orchestrator integration.** A host that calls tools for all agents can assign a unique ID to each concurrent task and use it at the write entry point. Adapt this short-task example to the host's own APIs.

```text
Claim every path involved in the edit, using the current task ID as agent.
On a tool error or ok: false, report the error or conflict to the task and stop the edit.
After obtaining the claim, read the latest files and have the agent generate or review its changes.
Write while the lease is valid and wait for any subprocesses doing the work to finish.
In cleanup, release the claim with the same task ID, even if the task was cancelled.
```

In a Git-managed project, you can add `/.codex/fusion-agent-guard/` to the project's ignore rules. This keeps its local registry out of commits while the guard continues to use it.

## Observe a write from two terminals

**Terminal A.** Use the terminal from the handoff exercise. Copy the temporary project path it prints. Start the watcher and wait for `watch-started` before writing in terminal B.

```powershell
$demo
& $guard watch -Project $demo
```

**Terminal B.** Open another PowerShell at the root of the tool repository. When prompted, paste the path printed by terminal A.

```powershell
$guard = (Resolve-Path -LiteralPath '.\scripts\fusion-guard.ps1').Path
$demo = Read-Host 'Paste the absolute path of the temporary project from terminal A'
& $guard claim -Project $demo -Agent 'watch-demo' -Path 'notes.txt'
if ($LASTEXITCODE -ne 0) { throw 'watch-demo could not claim the file' }
Add-Content -LiteralPath (Join-Path $demo 'notes.txt') -Value 'watch demo' -Encoding UTF8
```

Look in terminal A for a record with `kind: "filesystem-event"` and `path: "notes.txt"`. `activeClaims` shows claims that cover the path when the watcher processes the event. The filesystem event itself does not identify the agent that wrote the file. A single save can produce several events. Once you see the record, release the claim in terminal B, then press `Ctrl+C` in terminal A to stop watching.

```powershell
& $guard release -Project $demo -Agent 'watch-demo'
```

For a bounded CLI run, use `& $guard watch -Project $demo -DurationSeconds 10 -MaxEvents 20`. Over MCP, call `watch_changes` with `{"seconds":10}` and make a change from another client during that window. The tool returns `events: []` for a quiet window and `limit_reached: true` if it hits the record limit. It observes only the current window. For continuous observation across writes, leave the CLI `watch` process running.

## Renew a lease or recover a task

- **Long-running edit.** Before `expiresAt`, call `claim` again with the same identity, paths and `mode`. Include every path that still needs protection. Only the requested paths are renewed. Use the new expiry in the successful response for your next renewal.
- **Expired lease or unknown outcome.** Pause writes, claim the paths again and check `ok`. Once successful, reread the on-disk version and reconcile pending edits. `status` shows a snapshot. Permission to proceed depends on your successful claim and its expiry.
- **Crashed or restarted client.** A new MCP process gets a new default identity and new prefixes for its named tasks. Check the old claim's `expiresAt` in `status`. Confirm the previous task has stopped writing, wait for expiry, and claim the paths for the new task. CLI `cleanup`, a fresh claim or a status check removes expired records.
- **Completion or cancellation.** Call `release` on the original connection with the same task label. Release frees all paths for that identity. Give independently running subtasks distinct names.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Fusion still switches tabs during another agent's turn | Read `fusion-ui-status` from both sessions. They should show the same holder. Check that each session has loaded the updated skill or reconnected to the updated MCP server, uses its own identity and checks `ok` before every batch of UI actions. A host that sends UI input directly must do this at its command entry point. |
| Clients cannot see each other's claims | Call `status` on each side, compare `project` and confirm both tasks use the same local working tree. Pass `-Project` to override the CLI default if needed. Give each task on a shared MCP connection a distinct label. |
| `claim` returns a conflict | Inspect `agent`, `path`, `mode` and `expiresAt` in each `conflicts` entry. A `tree` claim on a parent directory also covers the file. Wait for the handoff or request an unrelated path separately. |
| No MCP tools appear or the `mcp` module is missing | Check the absolute paths of the Python interpreter, `mcp_server.py` and the project in the client config. Run `-m pip show mcp` with that exact interpreter. Follow [Setup](#setup) to install into that environment if needed, then reconnect. |
| Registration reports `unknown option '--project'` | In Windows PowerShell, select the client's `.exe` or `.cmd` as shown in [Setup](#setup). Put `--` between the server name and the interpreter and check the saved launch arguments. |
| PowerShell blocks script execution | Run `Get-ExecutionPolicy -List` in the PowerShell used to run the script. Use a script execution method permitted by the machine's policy. The MCP server invokes the same PowerShell script. |
| Missing project, path outside the project or access denied | `--project` must point to an existing directory where the user can write registry data. `paths` are relative to this directory unless given as absolute paths inside it. Check `status.project`, the file location and access to the project's `.codex` directory. |
| `status` fails, the registry lock times out, or `Cannot read claim file` appears | Pause writes and keep the error, including the affected path. Check storage, permissions and other active clients, then retry `status`. If a record is damaged, stop every participant, back up and inspect the reported record, and reacquire claims once the registry is consistent. |
| A save produces no visible event | Start the watcher before saving and check the target directory and observation window. The root `.git` and guard's own state paths are filtered. If the watcher stops, restart it and inspect the actual files or Git diff for changes made in the gap. |

## Update, disconnect or uninstall

Finish or pause edits, release each task's claims, stop watchers and disconnect MCP sessions. At the **root of the tool repository**, check `git status --short` and handle local changes before pulling. If you use MCP, refresh the dependencies in the original virtual environment too.

```powershell
git pull --ff-only
# Run the next line for an MCP installation.
.\.venv\Scripts\python.exe -m pip install -r requirements-mcp.txt
```

For a ZIP download, unpack the new version to a new directory. To update a project copy installed with `start.ps1`, stop the participating tasks, review and move the old dedicated skill directory to a backup location, then run the new launcher against the project. After reconnecting, call `status` to verify the project path and repeat the handoff exercise.

To disconnect the guard, release active claims and stop the watcher. For Codex CLI, run `codex mcp remove fusion-guard`, substituting your registered name if it differs. For a JSON-configured client, remove the guard's entry from `mcpServers` and reconnect. Remove guard-specific instructions added to the target project. You can then remove the dedicated skill copy, tool checkout and its virtual environment. The project registry is confined to `.codex/fusion-agent-guard/`. Once all participants have stopped using it, you can keep it or verify and remove that specific subdirectory. Other `.codex` settings and business source files belong to the project.

If you registered the server with Claude Code using the project-local registration above, run `claude mcp remove --scope local fusion-guard` in the original target project to remove its local registration.
