# Local Fusion Conflict Guard

[English](README.md) · **简体中文**

让同一 Windows 项目里的 agent 看见彼此在做什么。每个 agent 开工前说明改动目的和涉及的文件，其他 agent 加入或申请编辑时就能看到。如果两人要改同一文件，提示里会列出谁正在改、为什么改。

多个 agent 操作同一个 Fusion 窗口时，由一个 agent 连贯完成当前步骤，其他 agent 继续做后台工作。同一 Windows 账户下的不同项目也能这样交接。[Fusion 窗口如何交接](references/usage.md#操作-fusion-窗口)

**把这句话发给你的 agent：**

> 下载 https://github.com/wangyuchen5110/local-fusion-conflict-guard 用于当前项目。跟其他 agent 协调文件改动。需要操作 Fusion 窗口时先申请，做完这一步再交接。

agent 从项目根目录调用下载包里的 `start.ps1`。协作同一目标时使用同一个任务名，在共享看板里提问、更新进展和交接。只需 Windows PowerShell 5.1 或 7。[可选的 MCP 配置](references/usage.md#接入)

项目已经装过旧版时，先升级，再让多个会话共同操作 Fusion 窗口。[升级已有安装](references/usage.md#更新停用和卸载)

[给 agent 的操作指令](SKILL.md) · [使用手册](references/usage.md) · [命令参考](references/protocol.md)
