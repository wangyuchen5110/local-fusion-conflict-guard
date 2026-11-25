<#
.SYNOPSIS
Install the downloaded skill in a Windows project and join with a new task ID.
.EXAMPLE
$task = & 'D:\downloads\local-fusion-conflict-guard\start.ps1' -Project 'D:\work\app' | ConvertFrom-Json
& $task.guard board
#>
[CmdletBinding()]
param([string]$Project)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$skillName = 'local-fusion-conflict-guard'
$sourceGuard = Join-Path $PSScriptRoot 'scripts\fusion-guard.ps1'
if (-not [IO.File]::Exists($sourceGuard)) {
    throw 'Download or extract the full repository, then run start.ps1 beside the scripts directory.'
}
$joinOptions = @{}
if ($PSBoundParameters.ContainsKey('Project')) { $joinOptions.Project = $Project }
$task = & $sourceGuard join @joinOptions | ConvertFrom-Json
$projectRoot = $task.project
if (-not $PSBoundParameters.ContainsKey('Project') -and $projectRoot -eq $PSScriptRoot) {
    throw 'Run start.ps1 from the working project, or pass -Project with its path.'
}
$skillsDir = Join-Path $projectRoot '.agents\skills'
$destination = Join-Path $skillsDir $skillName
$runtime = @(
    'start.ps1', 'SKILL.md', 'SKILL.en.md', 'agents/openai.yaml',
    'README.md', 'README.zh-CN.md', 'README.en.md', 'requirements-mcp.txt',
    'scripts/fusion-guard.ps1', 'scripts/fusion-ui.ps1', 'scripts/mcp_server.py', 'scripts/team-board.ps1', 'scripts/shared-edit.ps1',
    'references/usage.md', 'references/usage.en.md',
    'references/protocol.md', 'references/protocol.en.md'
)

function Assert-MatchingInstall {
    foreach ($name in $runtime) {
        $source = Join-Path $PSScriptRoot $name
        $copy = Join-Path $destination $name
        # Git for Windows and ZIP archives can use different line endings.
        if (-not [IO.File]::Exists($copy) -or
            -not [string]::Equals(
                [IO.File]::ReadAllText($source).Replace("`r`n", "`n"),
                [IO.File]::ReadAllText($copy).Replace("`r`n", "`n"),
                [StringComparison]::Ordinal)) {
            throw "The installed '$name' differs or is missing at '$destination'. Review the existing installation before updating it."
        }
    }
}

if (-not [IO.Directory]::Exists($destination)) {
    foreach ($parent in (Join-Path $projectRoot '.agents'), $skillsDir) {
        if ([IO.Directory]::Exists($parent) -and
            ([IO.File]::GetAttributes($parent) -band [IO.FileAttributes]::ReparsePoint)) {
            throw "The skill installation directory is redirected: '$parent'. Choose a local project directory."
        }
    }
    [IO.Directory]::CreateDirectory($skillsDir) | Out-Null
    # Build a complete copy before any other agent can discover its SKILL.md.
    $stage = Join-Path $projectRoot ('.fusion-install-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    try {
        foreach ($name in $runtime) {
            $copy = Join-Path $stage $name
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($copy)) | Out-Null
            [IO.File]::Copy((Join-Path $PSScriptRoot $name), $copy)
        }
        try {
            [IO.Directory]::Move($stage, $destination)
        } catch [IO.IOException] {
            # Another task may have finished installing while we were copying.
            if (-not [IO.Directory]::Exists($destination)) { throw }
        }
    } finally {
        if ([IO.Directory]::Exists($stage)) {
            # Remove only the known files and empty directories from this attempt.
            foreach ($name in $runtime) {
                $copy = Join-Path $stage $name
                if ([IO.File]::Exists($copy)) { [IO.File]::Delete($copy) }
            }
            foreach ($dir in 'agents', 'scripts', 'references') {
                $subdir = Join-Path $stage $dir
                if ([IO.Directory]::Exists($subdir)) { [IO.Directory]::Delete($subdir) }
            }
            [IO.Directory]::Delete($stage)
        }
    }
}
Assert-MatchingInstall
$task.guard = Join-Path $destination 'scripts\fusion-guard.ps1'
$task | ConvertTo-Json -Compress
exit 0
