[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('join', 'board', 'post', 'edit', 'claim', 'release', 'status', 'cleanup', 'watch',
                 'fusion-ui-status', 'fusion-ui-acquire', 'fusion-ui-release')]
    [string]$Command,

    [string]$Project = (Get-Location).Path,
    [string]$Agent,
    [string[]]$Path,
    [ValidateSet('file', 'tree')]
    [string]$Mode = 'file',
    [ValidateRange(15, 86400)]
    [int]$TtlSeconds = 600,
    [ValidateRange(1, 60)]
    [int]$IntervalSeconds = 2,
    [ValidateRange(1, 15)]
    [int]$DurationSeconds,
    [ValidateRange(1, 1000)]
    [int]$MaxEvents,
    [string]$Task,
    [string]$Message,
    [ValidateSet('plan', 'progress', 'question', 'handoff', 'done')]
    [string]$Kind = 'progress',
    [string]$To,
    [ValidateRange(0, [long]::MaxValue)]
    [long]$After = 0,
    [ValidateRange(1, 200)]
    [int]$Limit = 50,
    [ValidateRange(0, 15)]
    [int]$WaitSeconds = 0,
    [string]$OldText,
    [AllowEmptyString()]
    [string]$NewText
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
    $fullPath = [IO.Path]::GetFullPath($resolved.ProviderPath)
    $volumeRoot = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.TrimEnd('\') -eq $volumeRoot.TrimEnd('\')) { return $volumeRoot }
    return $fullPath.TrimEnd('\')
}

if (-not $PSBoundParameters.ContainsKey('Project')) {
    $localInstall = '\.agents\skills\local-fusion-conflict-guard\scripts\fusion-guard.ps1'
    if ($PSCommandPath.EndsWith($localInstall, [StringComparison]::OrdinalIgnoreCase)) {
        $scripts = [IO.DirectoryInfo]::new($PSScriptRoot)
        $workspace = $scripts.Parent.Parent.Parent.Parent.FullName
        # A personal skill installation serves the caller's working directory.
        if (-not $workspace.Equals((Get-ProjectRoot $HOME), [StringComparison]::OrdinalIgnoreCase)) {
            $Project = $workspace
        }
    }
}
$projectRoot = Get-ProjectRoot $Project
if ($Command -in 'join', 'claim') {
    if (-not $PSBoundParameters.ContainsKey('Agent')) {
        $Agent = [Guid]::NewGuid().ToString('N')
    } elseif ([string]::IsNullOrWhiteSpace($Agent)) {
        throw '-Agent must be nonempty when supplied.'
    }
}
$stateRoot = Join-Path $projectRoot '.codex\fusion-agent-guard'
$claimsRoot = Join-Path $stateRoot 'claims'
$lockPath = Join-Path $stateRoot '.registry.lock'
$isFusionUi = $Command -like 'fusion-ui-*'
if ($Command -ne 'join' -and -not $isFusionUi) { [IO.Directory]::CreateDirectory($claimsRoot) | Out-Null }

function Get-RelativeProjectPath([string]$InputPath) {
    if ([string]::IsNullOrWhiteSpace($InputPath)) { throw 'Claim paths must be nonempty.' }
    if ([IO.Path]::IsPathRooted($InputPath)) {
        $candidate = [IO.Path]::GetFullPath($InputPath)
    } else {
        $candidate = [IO.Path]::GetFullPath((Join-Path $projectRoot $InputPath))
    }

    $candidate = $candidate.TrimEnd('\')
    $base = $projectRoot.TrimEnd('\')
    if ($candidate.Equals($base, [StringComparison]::OrdinalIgnoreCase)) { return '.' }
    $prefix = $base + '\'
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the project: $InputPath"
    }
    return $candidate.Substring($prefix.Length).Replace('\', '/')
}

function Get-ClaimFiles {
    @(Get-ChildItem -LiteralPath $claimsRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)
}

function Read-Claims {
    $claims = @()
    $jsonOptions = @{}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOptions.DateKind = 'String' }
    foreach ($file in Get-ClaimFiles) {
        try {
            $claim = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json @jsonOptions
            # Older clients wrote leases before task descriptions and announcements existed.
            foreach ($name in 'task','message','planId','planSeq') {
                if ($null -eq $claim.PSObject.Properties[$name]) {
                    $claim | Add-Member -NotePropertyName $name -NotePropertyValue $null
                }
            }
            $claim | Add-Member -NotePropertyName claimFile -NotePropertyValue $file.FullName -Force
            $claims += $claim
        } catch {
            throw "Cannot read claim file: $($file.FullName)"
        }
    }
    return @($claims)
}

function Get-ActiveWork([object[]]$Claims, [string]$ExceptAgent, [string]$TaskFilter) {
    $now = [DateTimeOffset]::UtcNow
    $Claims | Where-Object {
        $null -ne $_ -and ([DateTimeOffset]$_.expiresAt) -gt $now -and
        (-not $ExceptAgent -or $_.agent -ne $ExceptAgent) -and
        (-not $TaskFilter -or $_.task -eq $TaskFilter)
    } | Select-Object agent, path, mode, expiresAt, task, message
}

function Remove-ExpiredClaims {
    $now = [DateTimeOffset]::UtcNow
    $removed = 0
    foreach ($claim in Read-Claims) {
        # ConvertFrom-Json materializes ISO timestamps as DateTime on some PowerShell versions.
        $expiry = [DateTimeOffset]$claim.expiresAt
        if ($expiry -le $now) {
            Remove-Item -LiteralPath $claim.claimFile -Force
            $removed++
        }
    }
    return $removed
}

function Test-Overlap([object]$Left, [object]$Right) {
    $leftPath = ([string]$Left.path).TrimEnd('/')
    $rightPath = ([string]$Right.path).TrimEnd('/')
    if ($leftPath.Equals($rightPath, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $leftTree = ([string]$Left.mode -eq 'tree')
    $rightTree = ([string]$Right.mode -eq 'tree')
    return ($leftTree -and ($leftPath -eq '.' -or $rightPath.StartsWith($leftPath + '/', [StringComparison]::OrdinalIgnoreCase))) -or
           ($rightTree -and ($rightPath -eq '.' -or $leftPath.StartsWith($rightPath + '/', [StringComparison]::OrdinalIgnoreCase)))
}

function Get-ClaimId([string]$Owner, [string]$RelativePath, [string]$Scope) {
    $bytes = [Text.Encoding]::UTF8.GetBytes("$Owner`n$RelativePath`n$Scope")
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Write-Lease([string]$LeasePath, [object]$Lease) {
    # Publish complete JSON even if a process is terminated during a renewal.
    $pending = [IO.Path]::Combine([IO.Path]::GetDirectoryName($LeasePath), [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($pending, ($Lease | ConvertTo-Json -Compress))
        if ([IO.File]::Exists($LeasePath)) {
            [IO.File]::Replace($pending, $LeasePath, [Management.Automation.Language.NullString]::Value)
        } else {
            [IO.File]::Move($pending, $LeasePath)
        }
    } finally {
        if ([IO.File]::Exists($pending)) { [IO.File]::Delete($pending) }
    }
}

function Invoke-WithRegistryLock([scriptblock]$Body, [string]$RegistryLockPath = $lockPath) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $stream = $null
    while ($null -eq $stream) {
        try {
            # The operating system releases the exclusive handle even if its owner is killed.
            $stream = [IO.FileStream]::new($RegistryLockPath, [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Timed out waiting for the Fusion guard registry lock.' }
            Start-Sleep -Milliseconds 100
        }
    }
    try { & $Body } finally {
        $stream.Dispose()
    }
}

function Get-Conflicts([object[]]$Claims) {
    $conflicts = @()
    for ($i = 0; $i -lt $Claims.Count; $i++) {
        for ($j = $i + 1; $j -lt $Claims.Count; $j++) {
            if ($Claims[$i].agent -ne $Claims[$j].agent -and (Test-Overlap $Claims[$i] $Claims[$j])) {
                $conflicts += [pscustomobject]@{
                    first = $Claims[$i] | Select-Object agent,path,mode,createdAt,expiresAt,task,message
                    second = $Claims[$j] | Select-Object agent,path,mode,createdAt,expiresAt,task,message
                }
            }
        }
    }
    return @($conflicts)
}

function Test-IgnoredPath([string]$RelativePath) {
    return $RelativePath -eq '.git' -or $RelativePath.StartsWith('.git/', [StringComparison]::OrdinalIgnoreCase) -or
           $RelativePath -eq '.codex' -or $RelativePath -eq '.codex/fusion-agent-guard' -or $RelativePath.StartsWith('.codex/fusion-agent-guard/', [StringComparison]::OrdinalIgnoreCase)
}

if ($isFusionUi) {
    . (Join-Path $PSScriptRoot 'fusion-ui.ps1')
    $result = Invoke-FusionUiLease -Action $Command -Project $projectRoot -Agent $Agent -Task $Task -Message $Message -TtlSeconds $TtlSeconds
    Write-Json $result
    if (-not $result.ok) { exit 2 }
    exit 0
}

switch ($Command) {
    'join' {
        $peers = @(
            if ([IO.Directory]::Exists($claimsRoot)) {
                Invoke-WithRegistryLock { Get-ActiveWork -Claims @(Read-Claims) -ExceptAgent $Agent }
            }
        )
        Write-Json ([pscustomobject]@{ ok = $true; kind = 'joined'; project = $projectRoot; agent = $Agent; guard = $PSCommandPath; peers = $peers })
    }
    'board' {
        . (Join-Path $PSScriptRoot 'team-board.ps1')
        Write-Json (Invoke-TeamBoard -Task $Task -After $After -Limit $Limit -WaitSeconds $WaitSeconds)
    }
    'post' {
        . (Join-Path $PSScriptRoot 'team-board.ps1')
        Write-Json (Invoke-TeamPost -Agent $Agent -Task $Task -Message $Message -Kind $Kind -To $To)
    }
    'edit' {
        if ($null -eq $Path -or $Path.Count -ne 1) { throw 'edit requires one -Path.' }
        if (-not $PSBoundParameters.ContainsKey('NewText')) { throw 'edit requires -NewText (use an empty string to remove a passage).' }
        . (Join-Path $PSScriptRoot 'shared-edit.ps1')
        $result = Invoke-SharedEdit -Agent $Agent -Path $Path[0] -OldText $OldText -NewText $NewText
        Write-Json $result
        if (-not $result.ok) { exit 2 }
    }
    'claim' {
        if ($null -eq $Path -or $Path.Count -eq 0) { throw 'claim requires one or more -Path values.' }
        $taskGiven = $PSBoundParameters.ContainsKey('Task')
        $messageGiven = $PSBoundParameters.ContainsKey('Message')
        if ($taskGiven -and [string]::IsNullOrWhiteSpace($Task)) { throw '-Task must be nonempty when supplied.' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $paths = @($Path | ForEach-Object { Get-RelativeProjectPath $_ } | Where-Object { $seen.Add($_) })
        $requested = @($paths | ForEach-Object { [pscustomobject]@{ agent = $Agent; path = $_; mode = $Mode } })
        $result = Invoke-WithRegistryLock {
            $expired = Remove-ExpiredClaims
            $existing = @(Read-Claims)
            $peers = @(Get-ActiveWork -Claims $existing -ExceptAgent $Agent)
            $blockers = @()
            foreach ($request in $requested) {
                foreach ($claim in $existing) {
                    if ($claim.agent -ne $Agent -and (Test-Overlap $request $claim)) { $blockers += $claim }
                }
            }
            if ($blockers.Count -gt 0) {
                return [pscustomobject]@{ ok = $false; kind = 'claim-conflict'; project = $projectRoot; agent = $Agent; peers = $peers; requested = $requested; conflicts = @($blockers | Select-Object agent, path, mode, expiresAt, task, message) }
            }

            $expiresAt = [DateTimeOffset]::UtcNow.AddSeconds($TtlSeconds).ToString('o')
            $created = @()
            $plans = [ordered]@{}
            $boardLoaded = $false
            foreach ($request in $requested) {
                $id = Get-ClaimId $Agent $request.path $request.mode
                $claimPath = Join-Path $claimsRoot "$id.json"
                $previous = $existing | Where-Object {
                    $_.agent -eq $Agent -and $_.mode -eq $request.mode -and $_.path.TrimEnd('/') -eq $request.path
                } | Select-Object -First 1
                if ($previous) { $claimPath = $previous.claimFile }
                $claim = [pscustomobject]@{
                    agent = $Agent; path = $request.path; mode = $request.mode
                    createdAt = [DateTimeOffset]::UtcNow.ToString('o'); expiresAt = $expiresAt
                    task = $null; message = $null; planId = $null; planSeq = $null
                }
                if ($previous) {
                    $claim.task = $previous.task
                    $claim.message = $previous.message
                    $claim.planId = $previous.planId
                    $claim.planSeq = $previous.planSeq
                }
                if ($taskGiven) { $claim.task = $Task }
                if ($messageGiven) { $claim.message = $Message }
                if ($claim.task) {
                    if (-not $boardLoaded) {
                        . (Join-Path $PSScriptRoot 'team-board.ps1')
                        $boardLoaded = $true
                    }
                    if (-not $previous -or $previous.task -ne $claim.task -or
                        $previous.message -cne $claim.message -or -not (Test-PublishedPlan $previous)) {
                        if (-not $plans.Contains($claim.task)) {
                            if (-not $plans.psbase.Count) { $head = Get-TeamHead (Join-Path $stateRoot 'board') }
                            $plans[$claim.task] = [pscustomobject]@{
                                id = [guid]::NewGuid().ToString('N'); seq = $head + $plans.psbase.Count + 1
                                task = $claim.task; claims = [Collections.Generic.List[object]]::new()
                            }
                        }
                        $plan = $plans[$claim.task]
                        $claim.planId = $plan.id
                        $claim.planSeq = $plan.seq
                        $plan.claims.Add($claim)
                    }
                }
                Write-Lease $claimPath $claim
                $created += $claim | Select-Object agent,path,mode,createdAt,expiresAt,task,message
            }
            foreach ($plan in $plans.psbase.Values) {
                # The announcement becomes visible after all leases have been published.
                # The ID/sequence in each lease lets a retry recover an interrupted publish.
                $planPaths = @($plan.claims | ForEach-Object { $_.path })
                $descriptions = @($plan.claims | ForEach-Object { $_.message } | Where-Object { $_ } | Select-Object -Unique)
                $text = if ($descriptions.Count) { $descriptions -join ' / ' } else { 'Editing' }
                $planEvent = [pscustomobject]@{
                    seq = $plan.seq; task = $plan.task; agent = $Agent; kind = 'plan'; to = $null
                    message = "$text [$($planPaths -join ', ')]"; timestamp = [DateTimeOffset]::UtcNow.ToString('o')
                    paths = $planPaths; planId = $plan.id; source = 'claim'
                }
                Write-TeamEvent $planEvent
            }
            return [pscustomobject]@{ ok = $true; kind = 'claim-accepted'; project = $projectRoot; agent = $Agent; peers = $peers; expiredRemoved = $expired; claims = $created }
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
            return [pscustomobject]@{ ok = $true; kind = 'status'; project = $projectRoot; expiredRemoved = $expired; claims = @($claims | Select-Object agent, path, mode, createdAt, expiresAt, task, message); conflicts = $detectedConflicts }
        }
        Write-Json $result
        if (@($result.conflicts).Count -gt 0) { exit 2 }
    }
    'watch' {
        $watcher = [IO.FileSystemWatcher]::new($projectRoot, '*')
        $watcher.IncludeSubdirectories = $true
        $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size'
        $sourceId = 'fusion-guard-' + [Guid]::NewGuid().ToString('N')
        $ids = "$sourceId.*"
        $emitted = 0
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $nextStatus = $IntervalSeconds
        $waitSeconds = $IntervalSeconds
        if ($DurationSeconds) { $waitSeconds = 1 }
        try {
            foreach ($type in 'Created', 'Changed', 'Deleted', 'Renamed', 'Error') {
                Register-ObjectEvent -InputObject $watcher -EventName $type -SourceIdentifier "$sourceId.$type"
            }
            $watcher.EnableRaisingEvents = $true
            $clock.Restart()
            Write-Json ([pscustomobject]@{ ok = $true; kind = 'watch-started'; project = $projectRoot; intervalSeconds = $IntervalSeconds })
            while (-not $DurationSeconds -or $clock.Elapsed.TotalSeconds -lt $DurationSeconds) {
                $event = Wait-Event -SourceIdentifier $ids -Timeout $waitSeconds
                if ($null -ne $event) {
                    $change = $event.SourceEventArgs
                    Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
                    if ($event.SourceIdentifier -eq "$sourceId.Error") { throw $change.GetException() }
                    $relative = Get-RelativeProjectPath $change.FullPath
                    $oldPath = $null
                    if ($change.ChangeType -eq 'Renamed') { $oldPath = Get-RelativeProjectPath $change.OldFullPath }
                    $visible = -not (Test-IgnoredPath $relative)
                    if ($visible -or ($oldPath -and -not (Test-IgnoredPath $oldPath))) {
                        $claims = @(Invoke-WithRegistryLock { Remove-ExpiredClaims | Out-Null; Read-Claims })
                        $covers = @($claims | Where-Object {
                            (Test-Overlap @{ path = $relative; mode = 'file' } $_) -or
                            ($oldPath -and (Test-Overlap @{ path = $oldPath; mode = 'file' } $_))
                        } | Select-Object agent, path, mode, expiresAt, task, message)
                        $record = @{ ok = $true; kind = 'filesystem-event'; changeType = [string]$change.ChangeType; path = $relative; timestamp = $event.TimeGenerated.ToUniversalTime().ToString('o'); activeClaims = $covers }
                        if ($oldPath) { $record.oldPath = $oldPath }
                        Write-Json $record
                        $emitted++
                    }
                }
                if ($MaxEvents -and $emitted -ge $MaxEvents) { break }
                if ($clock.Elapsed.TotalSeconds -ge $nextStatus -and (-not $DurationSeconds -or $clock.Elapsed.TotalSeconds -lt $DurationSeconds)) {
                    $snapshot = Invoke-WithRegistryLock { Remove-ExpiredClaims | Out-Null; $claims = @(Read-Claims); $detectedConflicts = @(Get-Conflicts $claims); [pscustomobject]@{ activeClaims = $claims.Count; conflicts = $detectedConflicts } }
                    $nextStatus = $clock.Elapsed.TotalSeconds + $IntervalSeconds
                    if (@($snapshot.conflicts).Count -gt 0) {
                        Write-Json ([pscustomobject]@{ ok = $false; kind = 'active-claim-conflict'; project = $projectRoot; conflicts = $snapshot.conflicts })
                        $emitted++
                    }
                }
                if ($MaxEvents -and $emitted -ge $MaxEvents) { break }
            }
        } finally {
            $watcher.Dispose()
            Unregister-Event -SourceIdentifier $ids -ErrorAction SilentlyContinue
            Remove-Event -SourceIdentifier $ids -ErrorAction SilentlyContinue
        }
    }
}

exit 0
