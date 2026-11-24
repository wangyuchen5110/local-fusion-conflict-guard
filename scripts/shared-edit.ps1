# Shared edits use the same short-lived registry lock as file claims.
function Get-SharedEditFile([string]$RelativePath) {
    if ($RelativePath -eq '.' -or
        $RelativePath -match '(^|/)\.git(/|$)' -or
        $RelativePath -match '^\.codex/fusion-agent-guard(/|$)') {
        throw 'Shared edits require a project file outside Git and guard state.'
    }
    $entry = [IO.DirectoryInfo]::new($projectRoot)
    foreach ($name in $RelativePath.Split('/')) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $entry -isnot [IO.DirectoryInfo]) {
            throw "Expected a regular project directory: $($entry.FullName)"
        }
        if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $name.EndsWith('.') -or $name.EndsWith(' ')) {
            throw "Invalid file name for a shared edit: $name"
        }
        # Require the actual name on disk: an 8.3 alias would evade path-based claims.
        $matchesOnDisk = @($entry.GetFileSystemInfos($name) | Where-Object {
            $_.Name.Equals($name, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($matchesOnDisk.Count -ne 1) { throw "Expected an existing project path: $RelativePath" }
        $entry = $matchesOnDisk[0]
    }
    if ($entry -isnot [IO.FileInfo] -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        (Get-Item -LiteralPath $entry.FullName -Force).LinkType -eq 'HardLink') {
        throw "Shared edits require a regular file without links: $RelativePath"
    }
    return $entry
}

function Invoke-SharedEdit {
    param(
        [Parameter(Mandatory)][string]$Agent,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OldText,
        [Parameter(Mandatory)][AllowEmptyString()][string]$NewText
    )

    if ([string]::IsNullOrWhiteSpace($Agent)) { throw 'edit requires an agent identity.' }
    if ($Path -match '^[\\/]{2}[?.][\\/]' -or $Path -match '^[a-z]:($|[^\\/])') {
        throw 'Use a project-relative path or a fully qualified regular file path.'
    }
    $relative = Get-RelativeProjectPath $Path
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $binaryControls = '[\x00-\x08\x0B\x0E-\x1F\x7F]'
    if ($NewText -match $binaryControls) { throw 'The replacement contains binary control characters.' }
    return Invoke-WithRegistryLock {
        $file = Get-SharedEditFile $relative
        Remove-ExpiredClaims | Out-Null
        $probe = @{ path = $relative; mode = 'file' }
        $blockers = @(Read-Claims | Where-Object {
            $_.agent -ne $Agent -and (Test-Overlap $probe $_)
        } | Select-Object agent, path, mode, expiresAt, task, message)
        $result = [ordered]@{ ok = $false; kind = 'edit-conflict'; project = $projectRoot; agent = $Agent; path = $relative }
        if ($blockers.Count) {
            $result.reason = 'claimed'
            $result.conflicts = $blockers
            return [pscustomobject]$result
        }

        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf
        $offset = if ($bom) { 3 } else { 0 }
        $contents = $utf8.GetString($bytes, $offset, $bytes.Length - $offset)
        if ($contents -match $binaryControls) { throw 'Shared edits require UTF-8 text.' }
        $at = $contents.IndexOf($OldText, [StringComparison]::Ordinal)
        if ($at -lt 0) {
            $result.reason = 'stale'
            return [pscustomobject]$result
        }
        if ($contents.IndexOf($OldText, $at + 1, [StringComparison]::Ordinal) -ge 0) {
            $result.reason = 'ambiguous'
            return [pscustomobject]$result
        }

        $changed = -not $OldText.Equals($NewText, [StringComparison]::Ordinal)
        if ($changed) {
            $updated = $contents.Remove($at, $OldText.Length).Insert($at, $NewText)
            $payload = $utf8.GetBytes($updated)
            $temp = Join-Path $file.DirectoryName ('.fusion-edit-' + [guid]::NewGuid().ToString('N') + '.tmp')
            $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                try {
                    if ($bom) { $stream.Write($bytes, 0, 3) }
                    $stream.Write($payload, 0, $payload.Length)
                    $stream.Flush($true)
                } finally { $stream.Dispose() }
                [IO.File]::Replace($temp, $file.FullName, [Management.Automation.Language.NullString]::Value)
            } finally {
                if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
            }
        }
        return [pscustomobject]@{ ok = $true; kind = 'edited'; project = $projectRoot; agent = $Agent; path = $relative; changed = $changed }
    }
}
