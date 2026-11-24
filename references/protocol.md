# MCP 与 PowerShell 命令参考

**简体中文** · [English](protocol.en.md)

首次安装请看 [README](../README.zh-CN.md)。日常协作、双 agent 演练和故障排查见[使用指南](usage.md)。本文说明同一个工作目录里的两个客户端如何判断一次申请能否写入，以及如何解析返回值。

## 项目和身份

CLI 安装在 `<项目>/.agents/skills/local-fusion-conflict-guard` 时，在哪个目录调用都默认选择该项目。`$HOME/.agents/skills` 用户级安装和其他布局默认使用当前目录。显式传入的 `-Project` 优先。MCP 在启动时用必填的 `--project` 固定项目，工具调用中无需传项目。用 `status` 的 `project` 字段核对各端是否打开同一工作目录。两个 Git 工作树、同一仓库的两份克隆或分别选中的父子目录，都使用各自的占用记录。

| 使用方式 | 身份从哪里来 | 续租和释放时怎么填 |
| --- | --- | --- |
| PowerShell | `join` 或首次 `claim` 省略 `-Agent` 时会生成新 ID。也可传非空名称 | 保存返回的 `agent`，随后的申请、续租和 `release` 都显式传入该身份，包括在其他 shell 中执行时 |
| 一个任务独享一个 MCP 服务进程 | 进程启动时生成 `mcp-<随机 ID>` | 该连接上的 `claim` 和 `release` 都省略 `agent` |
| 多个任务共享一个 MCP 服务进程 | 完整身份为 `mcp-<随机 ID>/<任务名>` | 为每个并行任务选不同的 `agent`，同一任务的每次调用都传原名称 |

MCP 可选的 `agent` 标签为 1–120 个字符。身份比较忽略大小写，两个并行任务要使用有实质区别的名称。连接重启会生成新身份，旧记录保留到到期或由原持有者释放。任务名用来协调协作者，编辑权限仍由宿主控制。

## 路径与冲突判定

`claim` 接受项目根目录下的相对路径或指向项目内部的绝对路径。返回的路径相对于项目根目录，分隔符为 `/`。可预先申请尚未创建的文件。路径比较忽略大小写、末尾的分隔符和同批中的重复项。传具体路径，通配符不会展开。所有客户端应采用相同的目录拼写，尤其在使用符号链接、目录联接或硬链接时。

下表假定持有者与申请者为不同身份，且原租约仍有效。

| 已占用 | 新申请 | 结果 |
| --- | --- | --- |
| `file src/api.ts` | `file SRC/api.ts` | 冲突，精确路径相同 |
| `file src/api.ts` | `file src/ui.ts` | 可并行 |
| `tree src` | `file src/http/api.ts` 或 `tree src/http` | 冲突，子路径被覆盖 |
| `file src/api.ts` | `tree src` | 冲突，新范围覆盖已有文件 |
| `tree src/api` | `tree src/api-v2` | 可并行，两个目录互不包含 |
| `tree .` | 任意项目内路径 | 冲突，`.` 代表项目根目录 |

默认的 `file` 只匹配该路径本身，即使给它的是目录名，也要显式选择 `tree` 才会覆盖后代。同一身份可持有重叠范围。一次申请使用一个 `mode`，整批先在同一个登记锁内检查。只要其中一个路径与他人冲突，整批都被拒绝，原有租约保持原到期时间。

## MCP 工具

| 工具 | 参数 | 返回值 |
| --- | --- | --- |
| `claim` | 必填 `paths`，至少一个非空路径的字符串数组。可选 `mode` 为 `file`（默认）或 `tree`，`ttl_seconds` 为 15–86400 的整数，默认 600，`agent` 见上表 | 成功为 `claim-accepted`，冲突为 `claim-conflict` |
| `status` | `{}` | `kind: "status"`，列出当前的 `claims` 与已存在的重叠 `conflicts` |
| `release` | 可选 `agent` | `kind: "released"`，释放这个身份在当前项目持有的**全部**有效租约 |
| `watch_changes` | 可选整数 `seconds`，范围 1–15，默认 3 | `project`、`events`、`limit_reached`，每次最多 100 条 |

假设 CLI 任务 `api` 已占用 `src` 目录树，MCP 任务 `ui` 申请 `{"paths":["src/app.ts"],"agent":"ui"}`，会得到如下结构。示例中的项目、身份和到期时间仅供说明。

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

MCP 将这类竞争作为正常工具结果返回。宿主先判断调用是否失败，再检查业务结果的 `ok` 和 `kind`。只有 `claim-accepted` 且 `ok: true` 才开始这批编辑。无效参数、项目外路径、登记锁超时等会产生工具错误，不能按空冲突列表处理。SDK 客户端可从 `structuredContent` 取对象，或解析返回的 JSON 文本。

## PowerShell 命令

下表中的 `$guard` 是 `scripts/fusion-guard.ps1` 的路径，`$project` 是目标工作目录。示例都在 PowerShell 中运行。

| 命令示例 | 参数与行为 |
| --- | --- |
| `& $guard join -Project $project` | 返回 `kind: "joined"`、`ok`、`project`、绝对脚本路径 `guard` 和任务身份 `agent`。省略 `-Agent` 生成唯一 ID，也可传任务名。这一步不会占用文件。 |
| `& $guard claim -Project $project -Agent api -Path 'src/a.ts','src/b.ts'` | `-Path` 至少一个非空路径。可加 `-Mode file` 或 `tree`，`-TtlSeconds` 默认 600，范围 15–86400 |
| `& $guard status -Project $project` | 清理到期记录后，返回整个项目的占用快照 |
| `& $guard release -Project $project -Agent api` | 释放 `api` 的全部有效占用。没有匹配记录时也成功，`released` 为 0 |
| `& $guard cleanup -Project $project` | 仅清理到期记录，返回 `expiredRemoved`。MCP 端调用 `status` 也会清理 |
| `& $guard watch -Project $project -IntervalSeconds 2` | 前台持续监听，Ctrl+C 停止。`-IntervalSeconds` 是检查已有占用冲突的周期，默认 2，范围 1–60 秒 |
| `& $guard watch -Project $project -DurationSeconds 5 -MaxEvents 10` | 可选 `-DurationSeconds` 为 1–15 秒，`-MaxEvents` 为 1–1000 条。两者同时指定时先达到的条件结束监听，启动记录不计数 |

每次省略 `-Agent` 的 `claim` 都会生成新身份，申请被拒也一样。成功和冲突响应的顶层都有 `agent`，请在重试、续租和释放时传回这个值。`release` 必须显式传入非空的 `-Agent`。

单次命令把一个 JSON 对象输出到标准输出，`watch` 则每行输出一个 JSON 对象。正常完成退出码为 `0`。申请发生冲突时 `claim` 返回 `2`，而 `status` 返回 `2` 表示它发现已经存在的冲突对。脚本执行失败时，独立的 PowerShell 进程通常返回 `1` 并写入错误流。在已有 PowerShell 会话中用 `&` 调用时，还应捕获终止错误；成功与冲突的退出码在调用后立即读取 `$LASTEXITCODE`。

## 返回字段

| 记录 | 需要读取的字段 |
| --- | --- |
| `claim-accepted` | `claims[]` 给出每项的 `agent`、`path`、`mode`、`createdAt` 和 `expiresAt`。续租会改写记录时间，调度时以最新 `expiresAt` 为准 |
| `claim-conflict` | `requested[]` 是本批请求，`conflicts[]` 是阻挡本批请求的现有租约。用 `agent`、`path`、`mode` 与 `expiresAt` 决定如何交接 |
| `status` | `claims[]` 为有效租约，`conflicts[]` 中每个元素含一对 `first`、`second`。普通的被拒申请不会留下冲突对。即使有冲突对，`status.ok` 仍为 `true` |
| `released` | `agent` 与实际移除的有效记录数 `released` |
| `cleanup` | `expiredRemoved` 是本次清除的到期记录数。正常的 `claim-accepted`、`status`、`released` 也含有该字段 |

## 监听事件

`watch` 启动后先输出 `kind: "watch-started"`，其中含 `project` 和 `intervalSeconds`。MCP 的 `watch_changes` 返回从本次调用启动监听起观察到的记录，省去启动行。安静的窗口返回空 `events`。达到 100 条时 `limit_reached: true`；连续两次调用之间可能有间隙，需连续观察时使用前台 CLI。

| 事件 | 字段与含义 |
| --- | --- |
| `filesystem-event` | `changeType` 为 `Created`、`Changed`、`Renamed` 或 `Deleted`。`path` 为项目相对路径，`timestamp` 为事件 UTC 时间。重命名另有 `oldPath` |
| `activeClaims` | 每次文件事件处理时查询到的有效覆盖租约，包含 `agent`、`path`、`mode`、`expiresAt`。重命名检查新旧两个路径，实际写入者的身份须由编辑器或宿主提供 |
| `active-claim-conflict` | 周期检查发现重叠记录时输出，`ok: false`，`conflicts[]` 包含冲突对。这种事件也计入条数上限 |

监听范围包含项目的子目录，过滤项目根的 `.git` 和 Guard 自身的 `.codex/fusion-agent-guard/`。同一次保存可能产生多条文件事件。事件仅在观察窗口内可见，Guard 不保存文件内容、变更历史或可回放的事件队列。

## 续租与故障恢复

登记记录位于项目的 `.codex/fusion-agent-guard/claims/`。登记锁只在检查和变更租约时短时持有。占用信息由各个写入工具主动遵守，普通进程仍能直接写入源码。

- **长任务**：到期前，以原身份、原路径和原模式再次 `claim`。需要续租哪些路径就传哪些。超过到期时间或连接重启后，重新申请成功，再读取文件当前内容并重做过时的修改。
- **任务结束或崩溃**：正常完成用 `release`。进程中断后，可等待 `expiresAt`，再调用 `status` 或 `cleanup` 清理。没有后台计时器持续清扫磁盘。单路径提前交接需要先协调该身份其余工作，因为 `release` 作用于全部租约。
- **调用超时或中途失败**：查询 `status` 核对实际登记状态。整批因冲突被拒时不会写入本批租约；进程或磁盘写入在更新中途失败时，应核对每个目标并成功重新申请后再继续。
- **登记锁超时或文件读取错误**：脚本获取登记锁最多等待约 10 秒。重试前确认项目路径、目录写权限和其他正在运行的操作。若错误给出无法读取的记录文件，先暂停相关写入并保留现场，确认持有者和到期时间后再修复记录。
