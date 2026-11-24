# Working with multiple agents

[简体中文](usage.md) · **English**

Try the file handoff below first. It uses a temporary project and runs in Windows PowerShell 5.1 or PowerShell 7. Python is optional for this exercise. To connect a client, see [installation and configuration](../README.en.md). For parameter defaults, response fields and path matching, see the [protocol reference](protocol.en.md).

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

> Before editing, use Fusion Guard to claim the paths you intend to change in a single request. Read the current file after the claim succeeds. Pause writes to those paths on a conflict, tool error or lease expiry. After reacquiring them, reread the file before continuing. Renew long-running claims before expiry. At the end of the task, release all claims held by its identity.

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
| Clients cannot see each other's claims | Call `status` on each side, compare `project` and confirm both tasks use the same local working tree. Pass `-Project` explicitly to the CLI. Give each task on a shared MCP connection a distinct label. |
| `claim` returns a conflict | Inspect `agent`, `path`, `mode` and `expiresAt` in each `conflicts` entry. A `tree` claim on a parent directory also covers the file. Wait for the handoff or request an unrelated path separately. |
| No MCP tools appear or the `mcp` module is missing | Check the absolute paths of the Python interpreter, `mcp_server.py` and the project in the client config. Run `-m pip show mcp` with that exact interpreter. Follow the README to install into that environment if needed, then reconnect. |
| Registration reports `unknown option '--project'` | In Windows PowerShell, select the client's `.exe` or `.cmd` as shown in the README. Put `--` between the server name and the interpreter and check the saved launch arguments. |
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

If you copied the skill from the repository, refresh the copy using the same installation method. After reconnecting, call `status` to verify the project path and repeat the handoff exercise to check coordination.

To disconnect the guard, release active claims and stop the watcher. For Codex CLI, run `codex mcp remove fusion-guard`, substituting your registered name if it differs. For a JSON-configured client, remove the guard's entry from `mcpServers` and reconnect. Remove guard-specific instructions added to the target project. You can then remove the dedicated skill copy, tool checkout and its virtual environment. The project registry is confined to `.codex/fusion-agent-guard/`. Once all participants have stopped using it, you can keep it or verify and remove that specific subdirectory. Other `.codex` settings and business source files belong to the project.

If you registered the server with Claude Code using the README, run `claude mcp remove --scope local fusion-guard` in the original target project to remove its local registration.
