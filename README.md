# Local Fusion Conflict Guard

**English** · [简体中文](README.zh-CN.md)

Help local coding agents share a Windows project. Each agent claims a file before editing and releases it when done.

**Send this to your agent:**

> Download https://github.com/wangyuchen5110/local-fusion-conflict-guard and use it to coordinate edits in my current project.

From the project root, the agent runs the downloaded `start.ps1` to get its task ID and guard script path. Other tasks reuse the project copy with their own IDs. Requires Windows PowerShell 5.1 or PowerShell 7. [Optional MCP setup](references/usage.en.md#setup)

[Agent instructions](SKILL.en.md) · [User guide](references/usage.en.md) · [Command reference](references/protocol.en.md)
