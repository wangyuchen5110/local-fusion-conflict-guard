# Coordination protocol

`fusion-guard.ps1` stores one JSON claim per `(agent, path, scope)` in `.codex/fusion-agent-guard/claims`. A claim has an expiry timestamp; expired files are disregarded and removed by each command that takes the registry lock.

## Scope and collisions

- `file` protects one exact normalized relative path. This is the default.
- `tree` protects the named path and every nested path.
- Two file claims collide only when their normalized paths are equal.
- A tree claim collides with a file or tree claim at the tree root or below it.
- The same agent can refresh its own claim. Claims from distinct agents conflict even when their TTLs differ.
- Agent labels are compared case-insensitively. Use distinct task names beyond capitalization when a host shares one MCP connection. A new server process gets a new identity. After a restart, earlier claims remain visible until their TTL expires.

All paths must remain under `-Project`. The guard rejects paths outside the project instead of creating an ambiguous claim.

## Commands and exit codes

| Command | Meaning | Exit codes |
| --- | --- | --- |
| `claim` | Checks the whole batch under one lock before writing any claims. A conflict rejects the entire batch. | `0` accepted; `2` overlapping active claim; `1` invalid request/error |
| `release` | Removes all active claims held by one agent. | `0` |
| `status` | Emits active claims and every overlap (normally none). | `0`, or `2` if conflicting records already exist |
| `cleanup` | Removes expired claims. | `0` |
| `watch` | Streams create, change, rename and delete events. Optional `-DurationSeconds` and `-MaxEvents` bound a call. | `0` on normal stop; `1` error |

Use claims as a cooperative lease, not a security boundary. An uncooperative process can still write files. The watcher reports observed changes and claims covering their paths; it cannot prove which operating-system process wrote them. Files below `.git` and the guard’s own state directory are ignored.

## Recovery

If an agent crashes, wait for its TTL, or have the task coordinator confirm that its work is stopped before manually deleting only the corresponding claim file. Prefer `status` and a short TTL to manual cleanup. Do not delete the whole `.codex` directory or use the guard to resolve Git merge markers: those require an ordinary code review and merge-resolution workflow.
