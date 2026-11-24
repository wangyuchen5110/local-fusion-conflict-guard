---
name: local-fusion-conflict-guard
description: Coordinate agents editing one Windows working tree through shared file and directory claims. Use the local Fusion Guard MCP tools or PowerShell CLI before overlapping edits.
---

# Local Fusion Conflict Guard

All participating agents must use the same project root. The MCP server and PowerShell CLI share the project's `.codex/fusion-agent-guard/` registry. When configuring a new client, follow the [setup instructions](README.md).

## Protocol

1. Use the configured `claim` MCP tool or the CLI below. An independent MCP process has a unique default identity. When several tasks share a connection, include a unique task name in the optional MCP `agent` argument for every claim and release. CLI users supply `-Agent`.
2. Claim exact file paths in one request before editing. Use `mode: "tree"` for exclusive edits to a subtree. Proceed only after MCP returns `ok: true` or the CLI exits with code `0`. On conflict or tool failure, pause writes to the requested paths. Read the current file after acquiring ownership.
3. Refresh claims with the same identity before expiry. `release` frees all claims for that identity, so call it once every edit covered by them is done. If the original lease has expired, acquire a fresh lease and reread the file.
4. Use `status` to inspect ownership. To observe file changes, use `watch_changes` for a short MCP observation window or `watch` for a continuous CLI stream. A matching claim identifies its holder. The watcher cannot attribute the write itself.

The helper script is at `scripts/fusion-guard.ps1`. Run it from PowerShell:

```powershell
$guard = Join-Path $HOME '.codex/skills/local-fusion-conflict-guard/scripts/fusion-guard.ps1'

# Claim two exact files for ten minutes.
& $guard claim -Project 'D:\repo' -Agent 'api-agent' -Path 'src/api.ts','src/routes.ts' -TtlSeconds 600

# Claim a subtree only when the agent owns all files beneath it.
& $guard claim -Project 'D:\repo' -Agent 'ui-agent' -Path 'src/components' -Mode tree

# Run one foreground monitor for the shared project (stop with Ctrl+C).
& $guard watch -Project 'D:\repo' -IntervalSeconds 2

# Inspect or release ownership.
& $guard status -Project 'D:\repo'
& $guard release -Project 'D:\repo' -Agent 'api-agent'
```

The script prints JSON records suitable for another agent to consume. For scope definitions, exit codes, and the watcher’s limits, read [the protocol reference](references/protocol.md).
