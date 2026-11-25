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

## 当前分工与共享讨论

多名 agent 可使用同一个 `task` 合作交付一项功能，`agent` 则标识具体参与者。CLI 的 `join.peers` 列出其他参与者当前的有效占用。所有客户端均可通过 `board` 查看 `activeWork`（当前意图和路径）、`tasks`（任务讨论）和 `events`（消息）。工具展示参与者实际申报的工作，宿主通过读取看板获得更新。

- **申请时公开意图。** 指定 `task` 和 `message` 描述要改什么。带任务名的首次申请、新增占用路径或意图变化会自动发布带路径的 `plan` 通知。相同内容续租不会重复通知；省略的元数据会保留原值。冲突响应会展示持有人已声明的目的、任务和路径。
- **讨论记录。** 事件有 `seq`、`task`、`agent`、`kind`、`message`、`to`、`timestamp`。任务摘要列出任务名、参与者、最后序号和最后消息类型。带 `to` 的消息仍在公开任务讨论中可见；指向 MCP 参与者时用看板上的完整身份。`done` 表示通知进展，不会释放租约或关闭讨论。
- **翻页与等待。** 可选的 `task` 同时筛选当前占用和任务讨论。`events` 按序号升序返回 `after` 之后的匹配消息。下次用 `nextAfter` 作为 `after`，每个筛选条件单独保存游标。`hasMore` 为真时继续取下一页。没有积压消息时可等待新的匹配消息，超时返回空页。租约释放或到期后，相关消息仍然可读。

## Fusion 前台租约

| CLI | MCP | 返回结果 |
| --- | --- | --- |
| `fusion-ui-acquire -Agent ID` | `fusion_ui_acquire` | 空闲或原持有者续租时为 `fusion-ui-acquired`，他人占用时为 `fusion-ui-busy` |
| `fusion-ui-status` | `fusion_ui_status` | `fusion-ui-status`，其中 `holder` 为当前持有人，空闲时为 null |
| `fusion-ui-release -Agent ID` | `fusion_ui_release` | 释放成功或已经空闲时为 `fusion-ui-released`，他人占用时为 `fusion-ui-busy` |

同一台电脑、同一 Windows 账户下的所有项目共用一份前台租约。持有人由项目和 agent 身份共同确定。申请时可传 `-Task`、`-Message`、`-TtlSeconds`（MCP 为 `task`、`message`、`ttl_seconds`）。默认 600 秒，可设为 15–86400 秒。有效的 `holder` 含 `project`、`agent`、`task`、`message`、`acquiredAt` 和 `expiresAt`。申请、续租、释放时使用同一身份与入口。遇到占用返回 `ok: false`，CLI 退出码为 2。到期后下一次调用即可重新申请。项目内的文件与目录占用独立管理。

如果你持有前台期间工作目录被移动或删除，从仍可用的一份 CLI 运行 `fusion-ui-release -Project <原项目绝对路径> -Agent <自己的身份>`。沿用申请成功时的原路径和身份。释放后，下一位即可申请前台。

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
| `board` | 可选 `task`、非负整数 `after`（默认 0）、`limit`（1–200，默认 50）、`wait_seconds`（0–15，默认 0） | `kind: "board"`、`activeWork`、`tasks`、`events`、`nextAfter`、`hasMore` |
| `post` | 必填非空 `task`、`message`；可选 `agent`、`to`、`kind`（默认 `progress`，另有 `plan`、`question`、`handoff`、`done`） | `kind: "posted"`，含已登记的 `event` |
| `edit` | 必填单个 `path`、非空原文 `old_text`、替换文字 `new_text`（空串表示删去该段），可选 `agent` | 成功为 `edited` 并含 `changed`，冲突为 `edit-conflict` 并含 `reason` |
| `claim` | 必填 `paths`，至少一个非空路径的字符串数组。可选 `mode` 为 `file`（默认）或 `tree`，`ttl_seconds` 为 15–86400 的整数，默认 600，`agent` 见上表 可选 `task`、`message` 公开修改目的。 | 成功为 `claim-accepted`，冲突为 `claim-conflict` |
| `status` | `{}` | `kind: "status"`，列出当前的 `claims` 与已存在的重叠 `conflicts` |
| `release` | 可选 `agent` | `kind: "released"`，释放这个身份在当前项目持有的**全部文件和目录**租约 |
| `watch_changes` | 可选整数 `seconds`，范围 1–15，默认 3 | `project`、`events`、`limit_reached`，每次最多 100 条 |

假设 CLI 任务 `api` 已占用 `src` 目录树，MCP 任务 `ui` 申请 `{"paths":["src/app.ts"],"agent":"ui"}`，会得到如下结构。示例中的项目、身份和到期时间仅供说明。

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

占用冲突和片段编辑冲突都通过普通 MCP 工具响应返回，业务结果为 `ok: false`。宿主先判断调用是否失败，再检查业务结果的 `ok` 和 `kind`。外部编辑器直接写文件前，确认 `claim-accepted` 且 `ok: true`。受保护的片段修改则以 `edited` 且 `ok: true` 为准。无效参数、项目外路径、登记锁超时等会产生工具错误，不能按空冲突列表处理。SDK 客户端可从 `structuredContent` 取对象，或解析返回的 JSON 文本。

## 精确片段编辑

对已有的普通 UTF-8 文件做局部修改时，`edit` 会在共用锁内读取最新内容，查找唯一一处原文并原子替换。大小写和换行符均须匹配。保留原文件的 UTF-8 BOM（若有）及匹配范围以外的内容。不同 agent 可以不申请整文件租约，分别修改同一文件的独立片段。原文与替换内容相同且匹配唯一时返回 `changed: false`。

若路径被他人占用，返回 `reason: "claimed"` 及 `conflicts`。原文消失返回 `stale`；匹配不唯一（包括重叠匹配）返回 `ambiguous`。这三种情况下文件保持原样，重新读取当前内容后再决定如何修改。二进制、非法 UTF-8、链接、缺失文件和 Git/guard 状态路径会产生错误。参与者需要共用同一登记表才能协调写入。

## PowerShell 命令

下表中的 `$guard` 是 `scripts/fusion-guard.ps1` 的路径，`$project` 是目标工作目录。示例都在 PowerShell 中运行。

| 命令示例 | 参数与行为 |
| --- | --- |
| `& $guard join -Project $project` | 返回 `kind: "joined"`、`ok`、`project`、绝对脚本路径 `guard` 和任务身份 `agent`。省略 `-Agent` 生成唯一 ID，也可传任务名。这一步不会占用文件。 `peers` 列出其他 agent 的有效占用和意图。 |
| `& $guard board -Project $project -Task status-api -After 0 -Limit 50 -WaitSeconds 0` | 读当前工作和消息，省略 `-Task` 读全项目，参数范围同 MCP。 |
| `& $guard post -Project $project -Agent api -Task status-api -Kind handoff -To tests -Message 'ready is boolean'` | 必填身份、任务和留言，`-Kind`、`-To` 可选。 |
| `& $guard edit -Project $project -Agent api -Path 'api.ts' -OldText 'timeout: 5' -NewText 'timeout: 10'` | 在一个文件中替换完全匹配的唯一片段。`edit-conflict` 的退出码为 2。 |
| `& $guard claim -Project $project -Agent api -Path 'src/a.ts','src/b.ts'` | 用 `-Task`、`-Message` 共享意图。`-Path` 至少一个非空路径。可加 `-Mode file` 或 `tree`，`-TtlSeconds` 默认 600，范围 15–86400 |
| `& $guard status -Project $project` | 清理到期记录后，返回整个项目的占用快照 |
| `& $guard release -Project $project -Agent api` | 释放 `api` 的全部有效占用。没有匹配记录时也成功，`released` 为 0 |
| `& $guard cleanup -Project $project` | 仅清理到期记录，返回 `expiredRemoved`。MCP 端调用 `status` 也会清理 |
| `& $guard watch -Project $project -IntervalSeconds 2` | 前台持续监听，Ctrl+C 停止。`-IntervalSeconds` 是检查已有占用冲突的周期，默认 2，范围 1–60 秒 |
| `& $guard watch -Project $project -DurationSeconds 5 -MaxEvents 10` | 可选 `-DurationSeconds` 为 1–15 秒，`-MaxEvents` 为 1–1000 条。两者同时指定时先达到的条件结束监听，启动记录不计数 |

每次省略 `-Agent` 的 `claim` 都会生成新身份，申请被拒也一样。成功和冲突响应的顶层都有 `agent`，请在重试、续租和释放时传回这个值。`release` 必须显式传入非空的 `-Agent`。 成功和被拒的申请都会返回 `peers`，列出其他人的当前租约。CLI 的 `post`、`edit` 和 `release` 均须使用明确的身份。

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

文件监听覆盖项目子目录，过滤项目根的 `.git` 和 guard 状态路径。一次保存可能产生多条事件。文件监听事件只在观察窗口可见，共享看板则保留可回读的任务讨论。

## 续租与故障恢复

路径租约保存在项目的 `.codex/fusion-agent-guard/claims/`，任务消息保存在同级的 `board/`。租约变更、消息发布和受保护的源文件编辑共用同一把登记锁。所有写入参与者都遵守协议时才能在写入前协调，其他进程仍可直接改动文件。

- **长任务**：到期前，以原身份、原路径和原模式再次 `claim`。需要续租哪些路径就传哪些。超过到期时间或连接重启后，重新申请成功，再读取文件当前内容并重做过时的修改。
- **任务结束或崩溃**：正常完成用 `release`。进程中断后，可等待 `expiresAt`，再调用 `status` 或 `cleanup` 清理。没有后台计时器持续清扫磁盘。单路径提前交接需要先协调该身份其余工作，因为 `release` 作用于全部租约。
- **调用超时或中途失败**：查询 `status` 核对实际登记状态。整批因冲突被拒时不会写入本批租约；进程或磁盘写入在更新中途失败时，应核对每个目标并成功重新申请后再继续。
- **登记锁超时或文件读取错误**：脚本获取登记锁最多等待约 10 秒。重试前确认项目路径、目录写权限和其他正在运行的操作。若错误给出无法读取的记录文件，先暂停相关写入并保留现场，确认持有者和到期时间后再修复记录。
