# Local Fusion Conflict Guard

[简体中文](SKILL.md) · **English**

Use this workflow when multiple local agents edit one Windows working tree. The skill entry point is [SKILL.md](SKILL.md). For installation and MCP client configuration, see the [README](README.md).

Use the project root specified for the task. With MCP, call `status` with `{}` and check its `project` field. With PowerShell, pass `-Project` explicitly. All participants need access to the same working directory on disk.

## Editing and handing off files

1. Pick a stable identity for the task. A dedicated MCP server process provides a default identity. When several tasks share a connection, supply a distinct `agent` label on every `claim` and `release`. PowerShell uses `-Agent`. Labels are case-insensitive.
2. List the paths you intend to write, including files to create or delete and both ends of a rename. Claim the batch together. Use `tree` when the task needs the entire subtree. If the task expands, claim the additional paths before writing them.
3. Proceed when the MCP claim returns `ok: true`, or when the CLI claim succeeds with exit code `0`. Read the latest contents under the lease before applying edits. A `claim-conflict` rejects the requested batch. Work on other paths or wait for a handoff and try again.
4. For long-running work, renew before `expiresAt` by claiming the same paths and mode with the same identity. If the lease expires, the MCP server restarts, or the result is uncertain, pause writes. Check `status`, acquire a fresh lease and read the current files again.
5. Wait for all writes, including subprocesses that may still write, to finish. Call `release` using the same identity. This releases all its claims in this project. The next task claims the paths under its own identity before reading the previous task's changes.

For example, an MCP task can call `claim` with `{"paths":["src/api.ts","tests/api.test.ts"],"ttl_seconds":600,"agent":"api-42"}`. At the end it calls `release` with `{"agent":"api-42"}` on the same connection. To make the equivalent CLI claim, start PowerShell in the **skill or tool repository directory** and substitute your project's path.

```powershell
$guard = (Resolve-Path -LiteralPath '.\scripts\fusion-guard.ps1').Path
$project = (Resolve-Path -LiteralPath 'D:\work\my-project').Path
& $guard claim -Project $project -Agent 'api-42' -Path 'src/api.ts','tests/api.test.ts'
```

## Monitoring and responding to conflicts

Use `status` for a snapshot of active claims, `watch_changes` for a short observation window or the CLI's `watch` for continuous monitoring. The `activeClaims` on an event identifies the claims covering the path when the event was processed. Identifying the writer requires information from the editor or host. If an unexpected write occurs, review the current file and diff with the claim holder before resuming the edit.

For worked examples and troubleshooting, see the [user guide](references/usage.en.md). For parameters, scope rules, event fields, timeouts and exit codes, see the [command and protocol reference](references/protocol.en.md).
