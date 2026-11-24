# Local Fusion Conflict Guard

[English](README.md) · **简体中文**

让同一 Windows 项目里的 agent 看见彼此在做什么。每个 agent 开工前说明改动目的和涉及的文件，其他 agent 加入或申请编辑时就能看到。如果两人要改同一文件，提示里会列出谁正在改、为什么改。

**把这句话发给你的 agent：**

> 下载 https://github.com/wangyuchen5110/local-fusion-conflict-guard 用于当前项目。开工前先看看其他 agent 在做什么，说明你要改哪里，有重叠就先协调。

agent 从项目根目录调用下载包里的 `start.ps1`。协作同一目标时使用同一个任务名，在共享看板里提问、更新进展和交接。只需 Windows PowerShell 5.1 或 7。[可选的 MCP 配置](references/usage.md#接入)

[给 agent 的操作指令](SKILL.md) · [使用手册](references/usage.md) · [命令参考](references/protocol.md)
