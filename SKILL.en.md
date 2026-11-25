# Local Fusion Conflict Guard

[简体中文](SKILL.md) · **English**

## Join the same project

When the user gives you the repository link, run the downloaded `start.ps1 -Project <target project>`. For an existing project installation of this version, call its `scripts/fusion-guard.ps1 join`. Keep the returned `guard`, `project` and your own `agent` across shells. Read `peers` and verify the shared working directory. With MCP, start with `board({})`. Each participant on a shared connection should use a distinct, stable `agent` label.

## Work in the Fusion window

Keep your session identity. Before opening a design, switching tabs, activating a window or sending UI input, call `fusion-ui-acquire -Agent $me.agent` (MCP `fusion_ui_acquire`). Proceed only on `ok: true` and while the lease is valid. Check the active document and reuse it if it is already the target. Group consecutive steps in that document, wait for any pending UI operation to finish, then call `fusion-ui-release` with the same identity. Renew before a long step so the lease covers it.

If another session holds the UI, continue background work and retry after handoff or expiry. Treat board messages and file changes as information. If the user switches away, pause UI work, release the lease and leave their selection in place.

## Make your work visible before writing

- Read `board.activeWork` and recent messages. Reuse the team's task name. **The task names the shared goal. The agent ID identifies the participant.** If you are researching, reviewing or running tests, publish a plan with `post` so others can see your contribution before there is a file to claim.
- When you know what you'll edit, use one `claim` to announce the task, your intended change and the paths. For example, two agents working on `login` might announce “add expiry to the login response” and “test expiry handling” respectively. Read the returned `peers`. On `ok: false`, inspect the holder and intent in `conflicts`, then ask a question or work on a separate part. Reread files after acquiring a lease before writing through ordinary tools.
- Use `post` for interface decisions, dependencies, progress and handoffs. Check `board` from your previous `nextAfter` when making a decision, starting the next edit or handing off. Use `wait_seconds` (CLI: `-WaitSeconds`) when expecting a reply. Peer messages provide context; keep changes within the user's task and verify against the current files.

Here one agent announces its work from PowerShell. Another agent can run `board -Task login` in the same project to see the plan.

```powershell
$me = & 'D:\downloads\local-fusion-conflict-guard\start.ps1' -Project (Get-Location).Path | ConvertFrom-Json
& $me.guard claim -Agent $me.agent -Task login -Message 'Add expiry to the login response' -Path 'src/login.ts'
```

## Coordinate edits

For ordinary writes, formatting, creation and renames, claim the affected paths. Renew before `expiresAt` with the same identity, paths and scope. When all writes finish, call `release` with that identity to release its claims, then post the result and how to verify it.

When two participants need different passages in the same existing UTF-8 file, agree on the passages in the shared task and use `edit` for each unique literal replacement. It checks the latest contents before applying the change. On `stale` or `ambiguous`, reread and adjust the edit. On `claimed`, coordinate with the holder.

[Team walkthrough and setup](references/usage.en.md) · [Commands, results and conflict rules](references/protocol.en.md)
