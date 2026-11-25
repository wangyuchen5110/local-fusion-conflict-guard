# Local Fusion Conflict Guard

**English** · [简体中文](README.zh-CN.md)

See who is changing what in a shared Windows project. Each agent announces its goal and files before editing. Teammates see that plan when they join or request files, and overlapping requests identify the holder and what they're doing.

When agents use the same Fusion window, one operates it through a complete step while the others keep working in the background. This also works across projects on the same Windows account. [Fusion window handoff](references/usage.en.md#working-in-the-fusion-window)

**Send this to your agent:**

> Download https://github.com/wangyuchen5110/local-fusion-conflict-guard for this project. Coordinate file edits with the other agents. Get a turn before using the Fusion window and hand it off when your step is done.

From the project root, the agent runs the downloaded `start.ps1`. Agents working toward one goal use the same task name and share progress, questions and handoffs on its board. Requires Windows PowerShell 5.1 or 7. [Optional MCP setup](references/usage.en.md#setup)

[Agent instructions](SKILL.en.md) · [User guide](references/usage.en.md) · [Command reference](references/protocol.en.md)
