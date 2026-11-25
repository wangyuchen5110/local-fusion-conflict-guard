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

## Shared work and task conversations

The same `task` groups one feature's contributions from multiple agents. The `agent` identifies the participant. CLI `join.peers` lists other participants' current leases. Any client can call `board` to see `activeWork` (current intent and paths), `tasks` (named conversations) and `events` (messages). The guard reports the work that participants declare. Hosts read the board to learn of changes.

- **Intent on claims.** Supply `task` and `message` to describe your purpose. The first claim for a named task, extra paths or a change of intent automatically posts a `plan` with the paths. A renewal with the same intent stays quiet. Omitting metadata on renewal keeps it. Blockers show the holder's declared task, message and paths.
- **History.** A posted event records `seq`, `task`, `agent`, `kind`, `message`, `to` and `timestamp`. Each summary in `tasks` names the task, participants, last sequence and last kind. A `to` value addresses a note on the public board. Use the full visible identity for an MCP recipient. A `done` note leaves leases and the conversation open until participants take further action.
- **Cursors.** The optional `task` filters current claims and conversations. `events` contains matching messages with sequence numbers higher than `after`, oldest first. Pass the returned `nextAfter` as the next `after`; keep one cursor per filter. If `hasMore` is true, fetch the next page straight away. With no backlog, optionally wait for a matching message. Timeout returns an empty page. Messages remain readable after related claims expire or are released.

## Fusion UI lease

| CLI | MCP | Result |
| --- | --- | --- |
| `fusion-ui-acquire -Agent ID` | `fusion_ui_acquire` | `fusion-ui-acquired` if free or renewed by the same owner, otherwise `fusion-ui-busy` |
| `fusion-ui-status` | `fusion_ui_status` | `fusion-ui-status` with the current `holder`, or null when available |
| `fusion-ui-release -Agent ID` | `fusion_ui_release` | `fusion-ui-released` when released or already free, otherwise `fusion-ui-busy` |

These calls share one lease per local Windows account across project roots. The owner is the project and agent together. Acquire accepts optional `-Task`, `-Message` and `-TtlSeconds` (MCP `task`, `message`, `ttl_seconds`). The default is 600 seconds, range 15–86400. An active `holder` includes `project`, `agent`, `task`, `message`, `acquiredAt` and `expiresAt`. Use the same identity and interface for acquisition, renewal and release. A busy result has `ok: false` and CLI exit code 2. Expiry makes the lease available on the next call. Project file claims are independent.

If your worktree is moved or deleted while you hold the UI, run `fusion-ui-release -Project <original-absolute-path> -Agent <your-id>` from an available copy of the CLI. Reuse the project path and identity from your successful acquisition. The next participant can then acquire the UI immediately.

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
| `board` | Optional `task`, nonnegative integer `after` (default 0), `limit` (1–200, default 50), `wait_seconds` (0–15, default 0) | `kind: "board"`, `activeWork`, `tasks`, `events`, `nextAfter`, `hasMore` |
| `post` | Nonblank `task` and `message`. Optional `agent`, `to`, `kind` (default `progress`; also `plan`, `question`, `handoff`, `done`) | `kind: "posted"` with the stored `event` |
| `edit` | One `path`, a nonempty literal `old_text`, literal `new_text` (empty deletes the passage); optional `agent` | `edited` with `changed`, or `edit-conflict` with `reason` |
| `claim` | Required `paths` is a string array containing at least one path. Each path must be nonblank. Optional `mode` accepts `file` (default) or `tree`. Optional integer `ttl_seconds` accepts 15–86400 and defaults to 600. Optional `agent` identifies a task on a shared connection. Optional `task` and `message` share the intention. | `claim-accepted` on success or `claim-conflict` on contention |
| `status` | `{}` | `kind: "status"`, active `claims` and any overlapping records in `conflicts` |
| `release` | Optional `agent` | `kind: "released"`. Releases **all file and directory claims** for this owner in this project |
| `watch_changes` | Optional integer `seconds` accepts 1–15 and defaults to 3 | `project`, `events` and `limit_reached`, with up to 100 events per call |

Suppose the CLI task `api` holds a tree claim on `src`. When the MCP task `ui` calls `claim` with `{"paths":["src/app.ts"],"agent":"ui"}`, it receives a result like the following. The project path, identity and expiration time are illustrative.

```json
{
  "ok": false,
  "kind": "claim-conflict",
  "project": "D:\\work\\demo",
  "agent": "mcp-demo/ui",
  "requested": [{"agent":"mcp-demo/ui","path":"src/app.ts","mode":"file"}],
  "conflicts": [{"agent":"api","path":"src","mode":"tree","task":"status-api","message":"Implement GET /status","expiresAt":"2026-11-24T08:10:00+00:00"}]
}
```

A claim or edit conflict is a normal MCP tool response with `ok: false`. Check for tool errors first, then inspect `ok` and `kind`. For direct writes through another editor, require `ok: true` and `kind: "claim-accepted"`. A guarded fragment edit instead confirms `kind: "edited"` and `ok: true`. Invalid parameters, paths outside the project or a registry lock timeout produce tool errors and leave the caller without confirmation. An SDK client can read the object from `structuredContent` or parse the JSON text in the tool response.

## Exact text edits

For a small change to an existing UTF-8 file, `edit` reads the latest contents under the registry lock and atomically replaces one exact occurrence of the old text. Case and line endings are significant. It preserves a UTF-8 BOM and all content outside the match. Participants can change separate passages of one file without long-lived file leases. An identical replacement with a unique match returns `changed: false`.

Another owner's covering lease returns `reason: "claimed"` with `conflicts`. A missing old passage returns `stale`; multiple matches, including overlaps, return `ambiguous`. The file is unchanged in all three cases. Reread it before preparing a revised edit. Binary or invalid UTF-8 data, links, missing files, and Git/guard state paths are errors. Coordination requires participating writers to use the same registry.

## PowerShell commands

In these examples `$guard` holds the path to `scripts/fusion-guard.ps1` and `$project` holds the target working directory. Run the commands in PowerShell.

| Command | Parameters and behavior |
| --- | --- |
| `& $guard join -Project $project` | Returns `kind: "joined"`, `ok`, the `project`, absolute `guard` script path and task `agent`. Omit `-Agent` for a new unique ID, or supply your task name. No path is claimed. The `peers` array contains other agents’ active leases and intent. |
| `& $guard board -Project $project -Task status-api -After 0 -Limit 50 -WaitSeconds 0` | Read current work and messages. Omit `-Task` for a project-wide view. Limits match MCP. |
| `& $guard post -Project $project -Agent api -Task status-api -Kind handoff -To tests -Message 'ready is boolean'` | Agent, task and message are required. `-Kind` and `-To` are optional. |
| `& $guard edit -Project $project -Agent api -Path 'api.ts' -OldText 'timeout: 5' -NewText 'timeout: 10'` | Replace one literal in one file. `edit-conflict` returns exit code 2. |
| `& $guard claim -Project $project -Agent api -Path 'src/a.ts','src/b.ts'` | Specify `-Task` and `-Message` to share intent. `-Path` requires one or more nonblank paths. `-Mode` accepts `file` (default) or `tree`. `-TtlSeconds` defaults to 600 and accepts 15–86400 |
| `& $guard status -Project $project` | Clears expired records and returns a snapshot of claims across the project |
| `& $guard release -Project $project -Agent api` | Releases every active claim held by `api`. If none match, the command succeeds with `released: 0` |
| `& $guard cleanup -Project $project` | Removes expired records and returns the count in `expiredRemoved`. MCP clients can trigger the same cleanup through `status` |
| `& $guard watch -Project $project -IntervalSeconds 2` | Watches continuously in the foreground until Ctrl+C. `-IntervalSeconds` controls how often the guard checks for overlapping claim records. It defaults to 2 and accepts 1–60 seconds |
| `& $guard watch -Project $project -DurationSeconds 5 -MaxEvents 10` | Optional limits are 1–15 seconds for `-DurationSeconds` and 1–1000 records for `-MaxEvents`. The first limit reached ends the watch. The initial startup record is excluded from the count |

Each `claim` made without `-Agent` creates a fresh identity, including a rejected request. Read its top-level `agent` on success or conflict and reuse it on retry, renewal and release. `release` requires an explicit nonblank `-Agent`. Both successful and conflicting claims include a `peers` snapshot of others' active leases. Use `post`, `edit` and `release` with an explicit agent ID on the CLI.

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

Filesystem watching covers project subdirectories and filters the root `.git` directory and guard state. One save may produce several events. Filesystem observations are live. Only the task board retains a replayable conversation.

## Renewal and recovery

Leases are stored in `.codex/fusion-agent-guard/claims/` and public task messages in the sibling `board/` directory. Lease changes, message publication and guarded source edits share the registry lock. Each writer must participate to get conflict checks. Other processes can still write directly to the source files.

- For a **long-running edit**, claim the paths you still need before they expire, using the same identity and mode. After expiry or a server restart, reacquire ownership, reread the current file, and adjust any pending edits to that version.
- When **finishing a task**, call `release`. If a process stops unexpectedly, wait until `expiresAt`, then call `status` or `cleanup` to remove its expired records. Cleanup is triggered by commands. Since `release` affects every claim for the owner, coordinate remaining work before handing off a single path.
- If **a call times out or fails partway through**, use `status` to check what was recorded. An ordinary conflict rejects the batch before writing claims. A process interruption or storage failure during a batch update requires checking each intended path and claiming it successfully before editing.
- On **a registry lock timeout or an unreadable claim file**, check the project path, write permissions and concurrent operations before retrying. The guard waits about 10 seconds for the registry lock. If an error names a damaged record, pause affected writers and preserve the record until you can identify the owner and expiry and arrange a repair.
