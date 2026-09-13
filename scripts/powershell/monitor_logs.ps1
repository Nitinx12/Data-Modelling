param (
    [string]$Command = 'summary'
)

$ErrorActionPreference = 'Continue' # Do not stop on single file error, as per bash script

# ============================================================================
# LOG MONITOR & CLEANUP
# ============================================================================

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$LogDir = Join-Path $ProjectRoot "logs"
$MaxAgeDays = if ($env:MAX_AGE_DAYS) { [int]$env:MAX_AGE_DAYS } else { 7 }
$MaxSizeMb = if ($env:MAX_SIZE_MB) { [int]$env:MAX_SIZE_MB } else { 5 }

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------

function Write-Info ([string]$Text) { Write-Host "[INFO] $Text" }
function Write-Notify ([string]$Text) { Write-Host "[NOTIFICATION] $Text" }
function Write-Warn ([string]$Text) { Write-Host "[WARNING] $Text" -ForegroundColor Yellow }
function Write-Err ([string]$Text) { Write-Host "[ERROR] $Text" -ForegroundColor Red }

function Show-Usage {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Log Monitor & Cleanup")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Usage:")
    [void]$sb.AppendLine("  .\monitor_logs.ps1                 Show a summary report of all logs (default, read only)")
    [void]$sb.AppendLine("  .\monitor_logs.ps1 summary         Same as above")
    [void]$sb.AppendLine("  .\monitor_logs.ps1 clean           Delete logs older than $($MaxAgeDays)d or larger than $($MaxSizeMb)MB")
    [void]$sb.AppendLine("                                    (asks for confirmation; the newest log is always kept)")
    [void]$sb.AppendLine("  .\monitor_logs.ps1 clean --dry-run Preview what 'clean' would delete, deletes nothing")
    [void]$sb.AppendLine("  .\monitor_logs.ps1 clean -y        Skip the confirmation prompt")
    [void]$sb.AppendLine("  .\monitor_logs.ps1 -h | --help     Show this help")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Log directory : $LogDir")
    [void]$sb.AppendLine("Age limit     : $MaxAgeDays days")
    [void]$sb.AppendLine("Size limit    : $MaxSizeMb MB")
    Write-Host $sb.ToString()
}

# ----------------------------------------------------------------------------
# Logic
# ----------------------------------------------------------------------------

function Get-LatestLog {
    $files = Get-ChildItem -Path $LogDir -File -Recurse
    if (-not $files) { return $null }
    return $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Classify-File ([System.IO.FileInfo]$File, [System.IO.FileInfo]$Latest) {
    $sizeMb = [math]::Floor($File.Length / 1MB)
    $ageDays = [math]::Floor((Get-Date) - $File.LastWriteTime).Days

    if ($File.FullName -eq $Latest.FullName) {
        $status = "LATEST"
    } else {
        $isOld = $ageDays -gt $MaxAgeDays
        $isLarge = $sizeMb -gt $MaxSizeMb

        if ($isOld -and $isLarge) { $status = "OLD+LARGE" }
        elseif ($isOld) { $status = "OLD" }
        elseif ($isLarge) { $status = "LARGE" }
        else { $status = "OK" }
    }
    return [PSCustomObject]@{
        Size = $sizeMb
        Age = $ageDays
        Status = $status
    }
}

function Cmd-Summary {
    if (-not (Test-Path $LogDir)) {
        Write-Warn "Log directory does not exist: $LogDir"
        return
    }

    $latest = Get-LatestLog
    if (-not $latest) {
        Write-Info "No log files found in $LogDir"
        return
    }

    Write-Host ("{0,-40} {1,10} {2,10} {3,-12}" -f "FILE", "SIZE(MB)", "AGE(days)", "STATUS")
    Write-Host ("-" * 74)

    $filesCount = 0
    $totalMb = 0
    $nOld = 0
    $nLarge = 0
    $nOldLarge = 0

    $allFiles = Get-ChildItem -Path $LogDir -File -Recurse
    foreach ($f in $allFiles) {
        $info = Classify-File $f $latest
        Write-Host ("{0,-40} {1,10} {2,10} {3,-12}" -f $f.Name, $info.Size, $info.Age, $info.Status)
        $filesCount++
        $totalMb += $info.Size
        switch ($info.Status) {
            "OLD" { $nOld++ }
            "LARGE" { $nLarge++ }
            "OLD+LARGE" { $nOldLarge++ }
        }
    }

    $wouldDelete = $nOld + $nLarge + $nOldLarge

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "                    LOG SUMMARY"
    Write-Host "============================================================"
    Write-Host "Log directory        : $LogDir"
    Write-Host "Total log files      : $filesCount"
    Write-Host "Total size (approx)  : $totalMb MB"
    Write-Host "Latest (preserved)  : $($latest.Name)"
    Write-Host "Flagged - old only   : $nOld"
    Write-Host "Flagged - large only : $nLarge"
    Write-Host "Flagged - old+large  : $nOldLarge"
    Write-Host "Would be deleted     : $wouldDelete"
    Write-Host "============================================================"

    if ($wouldDelete -gt 0) {
        Write-Info "Run '.\monitor_logs.ps1 clean' to remove flagged logs, or 'clean --dry-run' to preview."
    } else {
        Write-Info "Nothing needs cleanup."
    }
}

function Cmd-Clean {
    param ([string[]]$ArgsList)

    if (-not (Test-Path $LogDir)) {
        Write-Warn "Log directory does not exist: $LogDir"
        return
    }

    $dryRun = $ArgsList -contains '--dry-run'
    $assumeYes = $ArgsList -contains '-y' -or $ArgsList -contains '--yes'

    $latest = Get-LatestLog
    if (-not $latest) {
        Write-Info "No log files found in $LogDir"
        return
    }

    Write-Info "Log directory : $LogDir"
    Write-Info "Age limit     : $MaxAgeDays days"
    Write-Info "Size limit    : $MaxSizeMb MB"
    Write-Info "Latest log (always kept): $($latest.Name)"

    $toDelete = @()
    $reasons = @()

    $allFiles = Get-ChildItem -Path $LogDir -File -Recurse
    foreach ($f in $allFiles) {
        if ($f.FullName -eq $latest.FullName) { continue }
        $info = Classify-File $f $latest

        if ($info.Status -eq "OLD") {
            $toDelete += $f
            $reasons += "older than $MaxAgeDays days"
        } elseif ($info.Status -eq "LARGE") {
            $toDelete += $f
            $reasons += "$($info.Size) MB"
        } elseif ($info.Status -eq "OLD+LARGE") {
            $toDelete += $f
            $reasons += "older than $MaxAgeDays days, $($info.Size) MB"
        }
    }

    if ($toDelete.Count -eq 0) {
        Write-Host ""
        Write-Info "Nothing to delete."
        return
    }

    Write-Host ""
    Write-Info "$($toDelete.Count) file(s) will be deleted:"
    for ($i=0; $i -lt $toDelete.Count; $i++) {
        Write-Host "  - $($toDelete[$i].Name) ($($reasons[$i]))"
    }

    if ($dryRun) {
        Write-Host ""
        Write-Info "Dry run - no files were deleted."
        return
    }

    if (-not $assumeYes) {
        $confirm = Read-Host "`nProceed with deletion? [y/N]"
        if ($confirm -notmatch '^[yY](es)?$') {
            Write-Info "Aborted. No files were deleted."
            return
        }
    }

    $deletedCount = 0
    $failedCount = 0
    foreach ($f in $toDelete) {
        try {
            Remove-Item $f.FullName -Force -ErrorAction Stop
            Write-Notify "Deleted: $($f.Name)"
            $deletedCount++
        } catch {
            Write-Warn "Could not delete: $($f.FullName)"
            $failedCount++
        }
    }

    # Clean up empty directories
    Get-ChildItem -Path $LogDir -Recurse -Directory | Sort-Object FullName -Descending | ForEach-Object {
        if ((Get-ChildItem $_.FullName).Count -eq 0) {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "                 LOG CLEANUP SUMMARY"
    Write-Host "============================================================"
    Write-Host "Log directory        : $LogDir"
    Write-Host "Files deleted        : $deletedCount"
    if ($failedCount -gt 0) {
        Write-Host "Failed to delete     : $failedCount"
    }
    Write-Host "Latest log preserved : $($latest.Name)"
    Write-Host "============================================================"
}

# Entry point
if ($Command -eq 'summary' -or -not $Command) {
    Cmd-Summary
} elseif ($Command -eq 'clean') {
    $remainingArgs = $args | Where-Object { $_ -ne 'clean' }
    Cmd-Clean -ArgsList $remainingArgs
} elseif ($Command -eq '-h' -or $Command -eq '--help' -or $Command -eq 'help') {
    Show-Usage
} else {
    Write-Err "Unknown command: $Command"
    Show-Usage
    exit 1
}
