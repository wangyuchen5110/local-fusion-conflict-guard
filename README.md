# Local Fusion Conflict Guard

**English** · [简体中文](README.zh-CN.md)

Coordinate coding agents in one Windows project. Each agent claims a file before editing and releases it when done. PowerShell and MCP clients share the same claims and can watch for file changes.

## Try it in PowerShell

```powershell
git clone https://github.com/wangyuchen5110/local-fusion-conflict-guard.git
cd local-fusion-conflict-guard
$guard = '.\scripts\fusion-guard.ps1'
& $guard claim -Agent A -Path demo.txt
& $guard claim -Agent B -Path demo.txt   # Conflict: A holds the file
& $guard release -Agent A
```

The demo uses the cloned directory. For your own project, point every client at the same root (`-Project` in PowerShell, `--project` in MCP).

[MCP setup for Codex, Claude Code and Cursor](references/usage.en.md#setup) · [User guide](references/usage.en.md) · [Command reference](references/protocol.en.md)
