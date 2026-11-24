# Each published file is one immutable event. Its numeric name is also the
# cursor. The writer's registry lock and same-directory rename keep IDs gapless.
function Get-TeamHead([string]$BoardRoot) {
    [long]$low = 0
    [long]$high = 1
    while ([IO.File]::Exists([IO.Path]::Combine($BoardRoot, "$high.json"))) {
        $low = $high
        $high *= 2
    }
    while ($high - $low -gt 1) {
        $mid = $low + (($high - $low) -shr 1)
        if ([IO.File]::Exists([IO.Path]::Combine($BoardRoot, "$mid.json"))) {
            $low = $mid
        } else {
            $high = $mid
        }
    }
    return $low
}

# Writers must hold the registry lock for sequence allocation and publication.
function Write-TeamEvent([object]$Event) {
    $boardRoot = Join-Path $stateRoot 'board'
    [IO.Directory]::CreateDirectory($boardRoot) | Out-Null
    $pending = [IO.Path]::Combine($boardRoot, [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($pending, ($Event | ConvertTo-Json -Depth 6 -Compress))
        [IO.File]::Move($pending, [IO.Path]::Combine($boardRoot, "$($Event.seq).json"))
    } finally {
        if ([IO.File]::Exists($pending)) { [IO.File]::Delete($pending) }
    }
}

function Test-PublishedPlan([object]$Claim) {
    if (-not $Claim.planId -or -not $Claim.planSeq) { return $false }
    $file = [IO.Path]::Combine($stateRoot, 'board', "$([long]$Claim.planSeq).json")
    if (-not [IO.File]::Exists($file)) { return $false }
    $event = [IO.File]::ReadAllText($file) | ConvertFrom-Json
    return $null -ne $event.PSObject.Properties['planId'] -and $event.planId -eq $Claim.planId
}

function Invoke-TeamPost {
    param(
        [string]$Agent, [string]$Task, [string]$Message,
        [ValidateSet('plan','progress','question','handoff','done')][string]$Kind = 'progress',
        [string]$To
    )
    if ([string]::IsNullOrWhiteSpace($Agent)) { throw 'post requires -Agent.' }
    if ([string]::IsNullOrWhiteSpace($Task)) { throw 'post requires -Task.' }
    if ([string]::IsNullOrWhiteSpace($Message)) { throw 'post requires -Message.' }
    $recipient = if (-not [string]::IsNullOrWhiteSpace($To)) { $To }
    $boardRoot = Join-Path $stateRoot 'board'
    Invoke-WithRegistryLock {
        $seq = (Get-TeamHead $boardRoot) + 1
        $event = [pscustomobject]@{
            seq = $seq; task = $Task; agent = $Agent; kind = $Kind.ToLowerInvariant()
            message = $Message; to = $recipient; timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        }
        Write-TeamEvent $event
        [pscustomobject]@{ ok = $true; kind = 'posted'; project = $projectRoot; event = $event }
    }
}

function Invoke-TeamBoard {
    param(
        [string]$Task,
        [ValidateRange(0, [long]::MaxValue)][long]$After = 0,
        [ValidateRange(1, 200)][int]$Limit = 50,
        [ValidateRange(0, 15)][int]$WaitSeconds = 0
    )
    $boardRoot = Join-Path $stateRoot 'board'
    $events = [Collections.Generic.List[object]]::new()
    # Keep summaries in first-post order; each contributor appears once per task.
    $tasks = [ordered]@{}
    $hasMore = $false
    [long]$scanned = 0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $jsonOptions = @{}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $jsonOptions.DateKind = 'String'
    }
    while ($true) {
        $head = Get-TeamHead $boardRoot
        while ($scanned -lt $head) {
            $scanned++
            $file = [IO.Path]::Combine($boardRoot, "$scanned.json")
            $event = [IO.File]::ReadAllText($file) | ConvertFrom-Json @jsonOptions
            if ($Task -and $event.task -ne $Task) { continue }
            if (-not $tasks.Contains($event.task)) {
                $tasks[$event.task] = [pscustomobject]@{
                    task = $event.task
                    participants = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    lastSeq = 0; lastKind = ''
                }
            }
            $summary = $tasks[$event.task]
            [void]$summary.participants.Add($event.agent)
            $summary.lastSeq = $scanned
            $summary.lastKind = $event.kind

            if ($scanned -gt $After) {
                if ($events.Count -lt $Limit) { $events.Add($event) } else { $hasMore = $true }
            }
        }
        if ($events.Count -or $clock.Elapsed.TotalSeconds -ge $WaitSeconds) { break }
        Start-Sleep -Milliseconds 150
    }
    $cursor = if ($hasMore) { $events[$events.Count - 1].seq } else { [Math]::Max($After, $scanned) }
    $activeWork = @(Invoke-WithRegistryLock { Get-ActiveWork -Claims @(Read-Claims) -TaskFilter $Task })
    [pscustomobject]@{
        ok = $true; kind = 'board'; project = $projectRoot; tasks = @($tasks.psbase.Values)
        events = $events.ToArray(); nextAfter = $cursor; hasMore = $hasMore; activeWork = $activeWork
    }
}
