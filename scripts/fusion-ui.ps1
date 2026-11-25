# A Fusion window can be shared by agents working from different project roots.
function Get-FusionUiLeaseDirectory {
    # GUI hosts may redirect LOCALAPPDATA for their workers while sharing the same Fusion window.
    $userDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($userDirectory)) { throw 'Cannot locate the local application data directory.' }
    return [IO.Path]::Combine($userDirectory, 'local-fusion-conflict-guard', 'fusion-ui')
}

function Invoke-FusionUiLease {
    param(
        [string]$Action, [string]$Project, [string]$Agent, [string]$Task,
        [string]$Message, [int]$TtlSeconds
    )
    if ($Action -ne 'fusion-ui-status' -and [string]::IsNullOrWhiteSpace($Agent)) {
        throw "$Action requires -Agent."
    }
    $directory = Get-FusionUiLeaseDirectory
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $leasePath = [IO.Path]::Combine($directory, 'lease.json')
    $registryLock = [IO.Path]::Combine($directory, '.registry.lock')

    Invoke-WithRegistryLock -RegistryLockPath $registryLock -Body {
        $now = [DateTimeOffset]::UtcNow
        $holder = $null
        if ([IO.File]::Exists($leasePath)) {
            $jsonOptions = @{}
            if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOptions.DateKind = 'String' }
            $record = [IO.File]::ReadAllText($leasePath) | ConvertFrom-Json @jsonOptions
            if ([DateTimeOffset]$record.expiresAt -gt $now) { $holder = $record }
        }
        if ($Action -eq 'fusion-ui-status') {
            return [pscustomobject]@{ ok = $true; kind = 'fusion-ui-status'; holder = $holder }
        }
        if ($holder -and (-not [string]::Equals($holder.project, $Project, [StringComparison]::OrdinalIgnoreCase) -or
                          -not [string]::Equals($holder.agent, $Agent, [StringComparison]::OrdinalIgnoreCase))) {
            return [pscustomobject]@{ ok = $false; kind = 'fusion-ui-busy'; holder = $holder }
        }
        if ($Action -eq 'fusion-ui-release') {
            if ($holder) { [IO.File]::Delete($leasePath) }
            return [pscustomobject]@{ ok = $true; kind = 'fusion-ui-released'; holder = $null }
        }
        if (-not $holder) {
            $holder = [pscustomobject]@{
                project = $Project; agent = $Agent; task = $null; message = $null
                acquiredAt = $now.ToString('o'); expiresAt = $null
            }
        }
        if ($Task) { $holder.task = $Task }
        if ($Message) { $holder.message = $Message }
        $holder.expiresAt = $now.AddSeconds($TtlSeconds).ToString('o')
        Write-Lease $leasePath $holder
        return [pscustomobject]@{ ok = $true; kind = 'fusion-ui-acquired'; holder = $holder }
    }
}
