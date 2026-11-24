# Local Fusion Conflict Guard

[English](README.md) · **简体中文**

让多个 agent 在同一个 Windows 项目里协作：编辑前申请文件，完成后释放。PowerShell 和 MCP 客户端共享占用记录，也能监听文件变更。

## 用 PowerShell 试一下

```powershell
git clone https://github.com/wangyuchen5110/local-fusion-conflict-guard.git
cd local-fusion-conflict-guard
$guard = '.\scripts\fusion-guard.ps1'
& $guard claim -Agent A -Path demo.txt
& $guard claim -Agent B -Path demo.txt   # 冲突：A 正占用这个文件
& $guard release -Agent A
```

示例使用刚克隆的目录。接入自己的项目时，所有客户端都指向同一个项目根目录（PowerShell 用 `-Project`，MCP 用 `--project`）。

[为 Codex、Claude Code 和 Cursor 配置 MCP](references/usage.md#接入) · [使用手册](references/usage.md) · [命令参考](references/protocol.md)
