---
name: local-fusion-conflict-guard
description: 在多个本地 agent 共用同一 Windows 工作目录时，通过 Fusion Guard MCP 或 PowerShell CLI 申请编辑路径、交接文件并观察实际变更。Use for coordinating concurrent edits in one shared working tree.
---

# Local Fusion Conflict Guard

**简体中文** · [English instructions](SKILL.en.md)

以用户指定的工作目录为项目根。接入 MCP 后先调用 `status({})` 核对 `project`；使用 CLI 时每次显式传 `-Project`。把所有 agent 指向磁盘上的同一份目录。首次接入见 [README](README.zh-CN.md)。

## 修改与交接

1. 为任务选定稳定身份。每个独立 MCP 服务进程自带默认身份；同一连接内有多个任务时，在每次 `claim` 和 `release` 中传各自的 `agent`。CLI 用 `-Agent`。名称应有别于其他任务，包括忽略大小写后仍有区别。
2. 列出即将写入的准确路径，包括新增、删除和重命名的源与目标。需要整个子树的独占权时用 `tree`。尽量一次申请整批路径；若任务中途扩大范围，先申请新增的路径。
3. 仅在 MCP 返回 `ok: true` 或 CLI 成功且退出码为 `0` 后写入。此时重新读取现有文件，基于最新内容合并自己的改动。`claim-conflict` 表示这批申请未获准，可以换其他文件工作，或等持有人释放后再试。
4. 长任务在 `expiresAt` 之前，用原身份、同一路径和 `mode` 再次 `claim` 来续租。若已到期、MCP 服务重启，或无法确认申请是否成功，暂停相关写入，核对 `status` 后重新申请并重读文件。
5. 所有占用路径的写入和会写文件的子进程均已结束，再以原身份 `release`。此操作释放该身份在当前项目的全部占用。接手方取得自己的占用后，再读取前一位留下的版本。

例如，同一 MCP 连接中的 `api-42` 调用 `claim` 时传 `{"paths":["src/api.ts","tests/api.test.ts"],"ttl_seconds":600,"agent":"api-42"}`，结束时给 `release` 传 `{"agent":"api-42"}`。通过 CLI 执行同样的申请时，在 **skill 或工具仓库所在目录**运行以下示例，替换目标项目路径。

```powershell
$guard = (Resolve-Path -LiteralPath '.\scripts\fusion-guard.ps1').Path
$project = (Resolve-Path -LiteralPath 'D:\work\my-project').Path
& $guard claim -Project $project -Agent 'api-42' -Path 'src/api.ts','tests/api.test.ts'
```

## 监测与处理冲突

`status` 显示当前占用。`watch_changes` 返回短时间窗口内的事件；连续观察使用 CLI 的 `watch`。事件中的 `activeClaims` 表示处理事件时覆盖该路径的占用，不足以判定写入者身份。发现意外写入时，先和持有人核对当前内容与差异，再决定如何继续编辑。

需要带预期结果的操作示例或排错步骤时，读[使用手册](references/usage.md)。需要参数、冲突范围、事件结构、超时和退出码时，读[命令与协议参考](references/protocol.md)。
