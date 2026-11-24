# Local Fusion Conflict Guard

[English](README.md) · **简体中文**

让多个本地 agent 在同一个 Windows 项目里协作。每个 agent 编辑前申请文件，完成后释放。

**把这句话发给你的 agent：**

> 下载 https://github.com/wangyuchen5110/local-fusion-conflict-guard ，用它协调当前项目的文件编辑。

agent 从项目根目录调用下载包里的 `start.ps1`，即可拿到自己的任务 ID 和脚本路径。后续任务复用同一份工具，各用自己的 ID。本地流程只需 Windows PowerShell 5.1 或 PowerShell 7。[可选的 MCP 配置](references/usage.md#接入)

[给 agent 的操作指令](SKILL.md) · [使用手册](references/usage.md) · [命令参考](references/protocol.md)
