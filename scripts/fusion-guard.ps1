[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('claim', 'release', 'status', 'cleanup', 'watch')]
    [string]$Command,

    [string]$Project = (Get-Location).Path,
    [string]$Agent,
    [string[]]$Path,
    [ValidateSet('file', 'tree')]
    [string]$Mode = 'file',
    [ValidateRange(15, 86400)]
    [int]$TtlSeconds = 600,
    [ValidateRange(1, 60)]
    [int]$IntervalSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Json([object]$Value) {
    $Value | ConvertTo-Json -Depth 8 -Compress
}

function Get-ProjectRoot([string]$InputPath) {
    $resolved = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $resolved.Path -PathType Container)) {
        throw "Project must be an existing directory: $InputPath"
    }
    return [IO.Path]::GetFullPath($resolved.Path).TrimEnd('\')
}

$projectRoot = Get-ProjectRoot $Project
$stateRoot = Join-Path $projectRoot '.codex\fusion-agent-guard'
$claimsRoot = Join-Path $stateRoot 'claims'
$lockPath = Join-Path $stateRoot '.registry.lock'
New-Item -ItemType Directory -Force -Path $claimsRoot | Out-Null

function Get-RelativeProjectPath([string]$InputPath) {
    if ([IO.Path]::IsPathRooted($InputPath)) {
        $candidate = [IO.Path]::GetFullPath($InputPath)
    } else {
        $candidate = [IO.Path]::GetFullPath((Join-Path $projectRoot $InputPath))
    }

    $prefix = $projectRoot + '\'
    if ($candidate -ne $projectRoot -and -not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the project: $InputPath"
    }
    if ($candidate -eq $projectRoot) {
        return '.'
    }
    return $candidate.Substring($prefix.Length).Replace('\', '/')
}

function Get-ClaimFiles {
    @(Get-ChildItem -LiteralPath $claimsRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)
}

function Read-Claims {
    $claims = @()
    foreach ($file in Get-ClaimFiles) {
        try {
            $claim = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $claim | Add-Member -NotePropertyName claimFile -NotePropertyValue $file.FullName -Force
            $claims += $claim
        } catch {
            Write-Warning "Ignoring unreadable claim file: $($file.FullName)"
        }
    }
    return @($claims)
}

function Remove-ExpiredClaims {
    $now = [DateTimeOffset]::UtcNow
    $removed = 0
    foreach ($claim in Read-Claims) {
        try {
            if ([DateTimeOffset]::Parse([string]$claim.expiresAt).ToUniversalTime() -le $now) {
                Remove-Item -LiteralPath $claim.claimFile -Force
                $removed++
            }
        } catch {
            Write-Warning "Could not evaluate claim expiry: $($claim.claimFile)"
        }
    }
    return $removed
}

function Test-Overlap([object]$Left, [object]$Right) {
    $leftPath = [string]$Left.path
    $rightPath = [string]$Right.path
    if ($leftPath -eq $rightPath) { return $true }
    $leftTree = ([string]$Left.mode -eq 'tree')
    $rightTree = ([string]$Right.mode -eq 'tree')
    return ($leftTree -and $rightPath.StartsWith($leftPath.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)) -or
           ($rightTree -and $leftPath.StartsWith($rightPath.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase))
}

function Get-ClaimId([string]$Owner, [string]$RelativePath, [string]$Scope) {
    $bytes = [Text.Encoding]::UTF8.GetBytes("$Owner`n$RelativePath`n$Scope")
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Invoke-WithRegistryLock([scriptblock]$Body) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $stream = $null
    while ($null -eq $stream) {
        try {
            $stream = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Timed out waiting for the Fusion guard registry lock.' }
            Start-Sleep -Milliseconds 100
        }
    }
    try { & $Body } finally {
        $stream.Dispose()
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-Conflicts([object[]]$Claims) {
    $conflicts = @()
    for ($i = 0; $i -lt $Claims.Count; $i++) {
        for ($j = $i + 1; $j -lt $Claims.Count; $j++) {
            if ($Claims[$i].agent -ne $Claims[$j].agent -and (Test-Overlap $Claims[$i] $Claims[$j])) {
                $conflicts += [pscustomobject]@{ first = $Claims[$i]; second = $Claims[$j] }
            }
        }
    }
    return @($conflicts)
}

function Test-IgnoredPath([string]$RelativePath) {
    return $RelativePath -eq '.git' -or $RelativePath.StartsWith('.git/', [StringComparison]::OrdinalIgnoreCase) -or
           $RelativePath -eq '.codex' -or $RelativePath -eq '.codex/fusion-agent-guard' -or $RelativePath.StartsWith('.codex/fusion-agent-guard/', [StringComparison]::OrdinalIgnoreCase)
}

switch ($Command) {
    'claim' {
        if ([string]::IsNullOrWhiteSpace($Agent)) { throw 'claim requires -Agent.' }
        if ($null -eq $Path -or $Path.Count -eq 0) { throw 'claim requires one or more -Path values.' }
        $requested = @($Path | ForEach-Object { [pscustomobject]@{ agent = $Agent; path = Get-RelativeProjectPath $_; mode = $Mode } })
        $result = Invoke-WithRegistryLock {
            $expired = Remove-ExpiredClaims
            $existing = @(Read-Claims)
            $blockers = @()
            foreach ($request in $requested) {
                foreach ($claim in $existing) {
                    if ($claim.agent -ne $Agent -and (Test-Overlap $request $claim)) { $blockers += $claim }
                }
            }
            if ($blockers.Count -gt 0) {
                return [pscustomobject]@{ ok = $false; kind = 'claim-conflict'; project = $projectRoot; requested = $requested; conflicts = @($blockers | Select-Object agent, path, mode, expiresAt) }
            }

            $expiresAt = [DateTimeOffset]::UtcNow.AddSeconds($TtlSeconds).ToString('o')
            $created = @()
            foreach ($request in $requested) {
                $id = Get-ClaimId $Agent $request.path $request.mode
                $claimPath = Join-Path $claimsRoot "$id.json"
                $claim = [pscustomobject]@{ agent = $Agent; path = $request.path; mode = $request.mode; createdAt = [DateTimeOffset]::UtcNow.ToString('o'); expiresAt = $expiresAt }
                $claim | ConvertTo-Json -Compress | Set-Content -LiteralPath $claimPath -Encoding UTF8 -NoNewline
                $created += $claim
            }
            return [pscustomobject]@{ ok = $true; kind = 'claim-accepted'; project = $projectRoot; expiredRemoved = $expired; claims = $created }
        }
        Write-Json $result
        if (-not $result.ok) { exit 2 }
    }
    'release' {
        if ([string]::IsNullOrWhiteSpace($Agent)) { throw 'release requires -Agent.' }
        $result = Invoke-WithRegistryLock {
            $expired = Remove-ExpiredClaims
            $removed = 0
            foreach ($claim in Read-Claims) {
                if ($claim.agent -eq $Agent) { Remove-Item -LiteralPath $claim.claimFile -Force; $removed++ }
            }
            return [pscustomobject]@{ ok = $true; kind = 'released'; project = $projectRoot; agent = $Agent; released = $removed; expiredRemoved = $expired }
        }
        Write-Json $result
    }
    'cleanup' {
        $result = Invoke-WithRegistryLock { [pscustomobject]@{ ok = $true; kind = 'cleanup'; project = $projectRoot; expiredRemoved = Remove-ExpiredClaims } }
        Write-Json $result
    }
    'status' {
        $result = Invoke-WithRegistryLock {
            $expired = Remove-ExpiredClaims
            $claims = @(Read-Claims)
            $detectedConflicts = @(Get-Conflicts $claims)
            return [pscustomobject]@{ ok = $true; kind = 'status'; project = $projectRoot; expiredRemoved = $expired; claims = @($claims | Select-Object agent, path, mode, createdAt, expiresAt); conflicts = $detectedConflicts }
        }
        Write-Json $result
        if (@($result.conflicts).Count -gt 0) { exit 2 }
    }
    'watch' {
        $watcher = [IO.FileSystemWatcher]::new($projectRoot, '*')
        $watcher.IncludeSubdirectories = $true
        $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size'
        $sourceId = 'fusion-guard-' + [Guid]::NewGuid().ToString('N')
        $subscription = Register-ObjectEvent -InputObject $watcher -EventName Changed -SourceIdentifier $sourceId
        $watcher.EnableRaisingEvents = $true
        Write-Json ([pscustomobject]@{ ok = $true; kind = 'watch-started'; project = $projectRoot; intervalSeconds = $IntervalSeconds })
        try {
            while ($true) {
                $event = Wait-Event -SourceIdentifier $sourceId -Timeout $IntervalSeconds
                if ($null -ne $event) {
                    $args = $event.SourceEventArgs
                    $relative = Get-RelativeProjectPath $args.FullPath
                    Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
                    if (-not (Test-IgnoredPath $relative)) {
                        $claims = @(Invoke-WithRegistryLock { Remove-ExpiredClaims | Out-Null; Read-Claims })
                        $covers = @($claims | Where-Object {
                            $probe = [pscustomobject]@{ path = $relative; mode = 'file' }
                            Test-Overlap $probe $_
                        } | Select-Object agent, path, mode, expiresAt)
                        Write-Json ([pscustomobject]@{ ok = $true; kind = 'filesystem-event'; changeType = [string]$args.ChangeType; path = $relative; timestamp = [DateTimeOffset]::UtcNow.ToString('o'); activeClaims = $covers })
                    }
                } else {
                    $snapshot = Invoke-WithRegistryLock { Remove-ExpiredClaims | Out-Null; $claims = @(Read-Claims); $detectedConflicts = @(Get-Conflicts $claims); [pscustomobject]@{ activeClaims = $claims.Count; conflicts = $detectedConflicts } }
                    if (@($snapshot.conflicts).Count -gt 0) { Write-Json ([pscustomobject]@{ ok = $false; kind = 'active-claim-conflict'; project = $projectRoot; conflicts = $snapshot.conflicts }) }
                }
            }
        } finally {
            Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
            $watcher.Dispose()
        }
    }
}

exit 0
