# MCP and PowerShell command reference

[简体中文](protocol.md) · **English**

Use this reference to decide when an agent can edit a path and how to interpret a response. For installation, see the [README](../README.md). For a two-agent walkthrough and troubleshooting, see the [usage guide](usage.en.md).

## Project and agent identity

For a CLI installed at `<project>/.agents/skills/local-fusion-conflict-guard`, the enclosing project is the default even from another working directory. A user-wide `$HOME/.agents/skills` install and other layouts use the current directory. An explicit `-Project` overrides the default. The MCP server requires `--project` at startup. Every call to that server uses the configured directory. Compare the `project` field returned by `status` on each client. Separate Git worktrees, separate clones and a parent directory and its subdirectory each have their own claim registry when selected as project roots.

| Client setup | Source of identity | How to renew or release |
| --- | --- | --- |
| PowerShell CLI | `join` or the first `claim` generates a new ID if `-Agent` is omitted. Both commands also accept a nonblank name. | Retain the returned `agent` and pass it explicitly to subsequent claims, renewals and `release`, even in another shell |
| One task per MCP server process | The server generates `mcp-<random ID>` when it starts | Omit `agent` on both `claim` and `release` |
| Multiple tasks using the same MCP server process | The owner is `mcp-<random ID>/<task name>` | Give each concurrent task a distinct `agent` label and reuse that label on each call for the task |

The optional MCP `agent` label accepts 1–120 characters. Identity comparisons are case-insensitive, so choose task names that differ by more than capitalization. Starting a new server process creates a new identity. Claims that belonged to a stopped process remain until expiry. The host controls write access, and participating writers use these identities to coordinate their edits.

## Paths and conflicts

`claim` accepts paths relative to the project root and absolute paths within it. Results use project-relative paths with `/` separators. A task can claim a file before creating it. Comparisons ignore case and trailing separators. A batch coalesces duplicate paths. Use literal paths, since the guard does not expand wildcard patterns. Agree on one spelling for each path across clients, particularly when the workspace contains symbolic links, junctions or hard links.

The examples assume distinct owners and an existing lease that has yet to expire.

| Active claim | Requested claim | Outcome |
| --- | --- | --- |
| `file src/api.ts` | `file SRC/api.ts` | Conflict on the same path |
| `file src/api.ts` | `file src/ui.ts` | Both can proceed |
| `tree src` | `file src/http/api.ts` or `tree src/http` | Conflict with a descendant of the claimed tree |
| `file src/api.ts` | `tree src` | The requested tree includes an active file claim |
| `tree src/api` | `tree src/api-v2` | Both can proceed in separate directory trees |
| `tree .` | Any path in the project | Conflict with the project-wide claim |

The default `file` mode covers the exact path. To include the children of a directory, select `tree`. One owner may hold overlapping claims. Each batch takes a single mode and the guard checks every path under one registry lock. If any requested path conflicts with another owner, it rejects the entire batch. Existing leases retain their previous expiration times.

## MCP tools

| Tool | Parameters | Result |
| --- | --- | --- |
| `claim` | Required `paths` is a string array containing at least one path. Each path must be nonblank. Optional `mode` accepts `file` (default) or `tree`. Optional integer `ttl_seconds` accepts 15–86400 and defaults to 600. Optional `agent` identifies a task on a shared connection. | `claim-accepted` on success or `claim-conflict` on contention |
| `status` | `{}` | `kind: "status"`, active `claims` and any overlapping records in `conflicts` |
| `release` | Optional `agent` | `kind: "released"`. Releases **all** active claims for this owner in this project |
| `watch_changes` | Optional integer `seconds` accepts 1–15 and defaults to 3 | `project`, `events` and `limit_reached`, with up to 100 events per call |

Suppose the CLI task `api` holds a tree claim on `src`. When the MCP task `ui` calls `claim` with `{"paths":["src/app.ts"],"agent":"ui"}`, it receives a result like the following. The project path, identity and expiration time are illustrative.

```json
{
  "ok": false,
  "kind": "claim-conflict",
  "project": "D:\\work\\demo",
  "agent": "mcp-demo/ui",
  "requested": [{"agent":"mcp-demo/ui","path":"src/app.ts","mode":"file"}],
  "conflicts": [{"agent":"api","path":"src","mode":"tree","expiresAt":"2026-11-24T08:10:00+00:00"}]
}
```

A conflict is a successful MCP tool call with a negative claim result. Check for tool errors first, then inspect `ok` and `kind`. Begin editing only on `ok: true` and `kind: "claim-accepted"`. Invalid parameters, paths outside the project or a registry lock timeout produce tool errors and leave the caller without confirmation. An SDK client can read the object from `structuredContent` or parse the JSON text in the tool response.

## PowerShell commands

In these examples `$guard` holds the path to `scripts/fusion-guard.ps1` and `$project` holds the target working directory. Run the commands in PowerShell.

| Command | Parameters and behavior |
| --- | --- |
| `& $guard join -Project $project` | Returns `kind: "joined"`, `ok`, the `project`, absolute `guard` script path and task `agent`. Omit `-Agent` for a new unique ID, or supply your task name. No path is claimed. |
| `& $guard claim -Project $project -Agent api -Path 'src/a.ts','src/b.ts'` | `-Path` requires one or more nonblank paths. `-Mode` accepts `file` (default) or `tree`. `-TtlSeconds` defaults to 600 and accepts 15–86400 |
| `& $guard status -Project $project` | Clears expired records and returns a snapshot of claims across the project |
| `& $guard release -Project $project -Agent api` | Releases every active claim held by `api`. If none match, the command succeeds with `released: 0` |
| `& $guard cleanup -Project $project` | Removes expired records and returns the count in `expiredRemoved`. MCP clients can trigger the same cleanup through `status` |
| `& $guard watch -Project $project -IntervalSeconds 2` | Watches continuously in the foreground until Ctrl+C. `-IntervalSeconds` controls how often the guard checks for overlapping claim records. It defaults to 2 and accepts 1–60 seconds |
| `& $guard watch -Project $project -DurationSeconds 5 -MaxEvents 10` | Optional limits are 1–15 seconds for `-DurationSeconds` and 1–1000 records for `-MaxEvents`. The first limit reached ends the watch. The initial startup record is excluded from the count |

Each `claim` made without `-Agent` creates a fresh identity, including a rejected request. Read its top-level `agent` on success or conflict and reuse it on retry, renewal and release. `release` requires an explicit nonblank `-Agent`.

Single-result commands emit one JSON object to standard output. The watcher emits one JSON object per line. Normal completion returns exit code `0`. A `claim` conflict returns `2`. For `status`, exit code `2` means that existing active records overlap. When launched as a separate PowerShell process, a script failure typically returns `1` and writes to the error stream. When calling with `&` in an existing PowerShell session, catch terminating errors and read `$LASTEXITCODE` immediately after a successful or conflicting call.

## Response fields

| Record kind | Fields to use |
| --- | --- |
| `claim-accepted` | Each item in `claims[]` has an `agent`, `path`, `mode`, `createdAt` and `expiresAt`. Renewal rewrites the timestamps. Schedule the next renewal using the latest `expiresAt` |
| `claim-conflict` | `requested[]` contains the requested batch. `conflicts[]` lists active leases blocking the batch, including the `agent`, `path`, `mode` and `expiresAt` needed to arrange a handoff |
| `status` | `claims[]` contains active leases. Each entry in `conflicts[]` is a pair of overlapping records named `first` and `second`. A rejected claim leaves no conflicting pair behind. `status.ok` is `true` even when the list contains a pair |
| `released` | `agent` and `released`, the number of active claims actually removed |
| `cleanup` | `expiredRemoved` gives the number of expired claims removed by this call. Successful `claim-accepted`, `status` and `released` records also include this field |

## Watch events

CLI `watch` first emits `kind: "watch-started"` with `project` and `intervalSeconds`. MCP `watch_changes` returns records observed during the window opened by that call, omitting the startup record. On a quiet project, `events` is an empty array. At 100 events, `limit_reached` becomes `true`. Successive calls can have gaps. Use the foreground CLI watcher to observe continuously.

| Record or field | Meaning |
| --- | --- |
| `filesystem-event` | `changeType` is `Created`, `Changed`, `Renamed` or `Deleted`. `path` is relative to the project and `timestamp` is the event time in UTC. A rename also includes `oldPath` |
| `activeClaims` | On a filesystem event, this array lists covering leases found when the event is **processed**. Each entry contains `agent`, `path`, `mode` and `expiresAt`. A rename checks both paths. Identifying the actual writer requires information from the host or editor |
| `active-claim-conflict` | A periodic registry check found records that overlap. `ok` is `false` and `conflicts[]` contains the overlapping pairs. This record also counts toward the event limit |

The watcher includes project subdirectories and filters the project's root `.git` directory and the guard's own `.codex/fusion-agent-guard/` state. A single save can produce multiple events. Observation is live. The guard does not retain file contents, change history or a queue of events to replay.

## Renewal and recovery

Each record lives in the project's `.codex/fusion-agent-guard/claims/` directory. The guard holds the registry lock while inspecting or updating leases. All writers must participate to get pre-edit conflict checks. Other processes can write directly to the source files.

- For a **long-running edit**, claim the paths you still need before they expire, using the same identity and mode. After expiry or a server restart, reacquire ownership, reread the current file, and adjust any pending edits to that version.
- When **finishing a task**, call `release`. If a process stops unexpectedly, wait until `expiresAt`, then call `status` or `cleanup` to remove its expired records. Cleanup is triggered by commands. Since `release` affects every claim for the owner, coordinate remaining work before handing off a single path.
- If **a call times out or fails partway through**, use `status` to check what was recorded. An ordinary conflict rejects the batch before writing claims. A process interruption or storage failure during a batch update requires checking each intended path and claiming it successfully before editing.
- On **a registry lock timeout or an unreadable claim file**, check the project path, write permissions and concurrent operations before retrying. The guard waits about 10 seconds for the registry lock. If an error names a damaged record, pause affected writers and preserve the record until you can identify the owner and expiry and arrange a repair.
