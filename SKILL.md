---
name: local-fusion-conflict-guard
description: Coordinate concurrent local edits by multiple Fusion or Codex agents using project-scoped path claims and a filesystem watcher. Use when agents share one working tree and must avoid overlapping writes; not for resolving an existing Git merge conflict.
---

# Local Fusion Conflict Guard

Use this skill to prevent a local multi-agent editing collision before files are changed. It creates only ephemeral coordination data under the target project's `.codex/fusion-agent-guard/` directory; it does not alter source files, Git state, or remote services.

## Protocol

1. Pick a stable, human-readable agent identity for the task. Before reading a file with the intention to edit it, claim the exact file. Claim a directory tree only when the entire subtree is genuinely owned by that agent.
2. If `claim` returns exit code `2`, do not write any of the requested paths. Inspect the reported owner and scope, then divide work differently, wait, or ask the coordinating user/agent to resolve ownership.
3. Start one `watch` process at the project root while concurrent work is active. Treat a write inside another agent's active claim as a coordination incident. The watcher reports it; it never overwrites, reverts, or auto-merges changes.
4. Refresh a long-running claim before its TTL expires. Release every claim when the edit is complete, abandoned, or handed off. Expired claims are automatically ignored.
5. Before a cross-cutting refactor, use `status` to discover overlapping ownership. Keep edits scoped to claimed paths and use ordinary Git diff/review for integration after all claims are released.

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
