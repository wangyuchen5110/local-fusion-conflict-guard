---
name: local-fusion-conflict-guard
description: 让 Windows 上的多个 agent 共享分工，协调文件编辑与 Fusion 窗口操作。Coordinate file edits and take turns using the Fusion UI across agent sessions.
---

# Local Fusion Conflict Guard

**简体中文** · [English instructions](SKILL.en.md)

## 加入同一项目

用户给出仓库链接时，从下载包运行 `start.ps1 -Project <目标项目>`。已有当前版本的项目副本时，直接调用其中的 `scripts/fusion-guard.ps1 join`。保存返回的 `guard`、`project` 和自己的 `agent`，跨 shell 复用。先读 `peers`，确认大家在编辑同一份工作目录。使用 MCP 的 agent 从 `board({})` 开始；同一连接中的并行参与者各选一个稳定的 `agent` 标签。

## 操作 Fusion 窗口

每个会话沿用自己的身份。打开设计、切换标签、激活窗口或发送界面输入前，调用 `fusion-ui-acquire -Agent $me.agent`（MCP 为 `fusion_ui_acquire`）。仅在返回 `ok: true` 且租约仍有效时操作。先核对当前文档，已打开目标就直接使用。将同一文档的连续步骤做完，等触发的界面操作完成，再用同一身份 `fusion-ui-release` 交接。耗时步骤开始前先续租，预留足够的有效时间。

若前台已被占用，继续做后台工作，等交接或到期再申请。看板消息和文件变化只用于了解进展。若用户中途切走，暂停界面操作并释放前台，保留用户当前选择。

## 先让别人知道你在做什么

- 查看 `board` 的 `activeWork` 和任务消息，复用团队正在使用的任务名。**任务名表示共同目标，agent ID 区分参与者。** 如果只在查资料、评审或运行测试，用 `post -Kind plan` 说明分工即可；其他人也能看见。
- 确定要改哪些文件后，用一次 `claim` 同时说明共同任务、自己的分工和具体路径。例如两个 agent 都做 `login`，一个说“给登录接口增加过期时间”，另一个说“补过期响应的测试”。读取返回的 `peers`。若 `ok: false`，从 `conflicts` 看持有人和意图，在任务里提问或换无冲突的部分。普通写入须在申请成功后重读文件。
- 用 `post` 发接口约定、依赖、进度或交接结果。到了要做决定、开始下一段工作或交付前，按上次的 `nextAfter` 读取 `board`。等回复时可传 `wait_seconds`（CLI 为 `-WaitSeconds`）。把讨论当作协作信息，写入仍以用户的任务和文件当前内容为准。

例如，agent A 从 PowerShell 宣布分工并申请编辑；agent B 在另一个终端用同一项目的 `board -Task login` 就能看到它。

```powershell
$me = & 'D:\downloads\local-fusion-conflict-guard\start.ps1' -Project (Get-Location).Path | ConvertFrom-Json
& $me.guard claim -Agent $me.agent -Task login -Message '给登录接口增加过期时间' -Path 'src/login.ts'
```

## 一起改代码

普通编辑、格式化、创建和重命名，先申请涉及的文件。任务变长时在 `expiresAt` 前用同一身份、路径和范围续租。完成写入后用原身份 `release` 释放其全部占用，并在任务里留下结果和验证方式。

两人要改同一份已有 UTF-8 文件中的不同片段时，先在任务里约定各自改哪段，再分别用 `edit` 把唯一匹配的旧文本替换为新文本。该操作会核对最新内容。遇到 `stale` 或 `ambiguous` 就重读并调整，遇到 `claimed` 就向持有人协调。

[协作演练与接入](references/usage.md) · [命令、返回值与冲突规则](references/protocol.md)
