$ErrorActionPreference = 'Stop'

param (
    [switch]$Deep,
    [string]$DatabaseUrl,
    [switch]$Quiet,
    [switch]$Help
)

if ($Help) {
    Write-Host "health_check.ps1 - verify project dependencies and external services"
    Write-Host "Checks (in order):"
    Write-Host "  1. Required CLIs on PATH: uv, psql, mongosh"
    Write-Host "  2. Python 3.13+ via uv"
    Write-Host "  3. .env file presence"
    Write-Host "  4. Postgres reachability"
    Write-Host "  5. MongoDB reachability"
    Write-Host "  6. Project disk space in logs/ + .venv/"
    Write-Host "  7. Optional: warehouse table counts (when -Deep)"
    Write-Host "`nUsage:"
    Write-Host "  .\health_check.ps1                # quick checks"
    Write-Host "  .\health_check.ps1 -Deep           # also count rows in core.* / staging.*"
    Write-Host "  .\health_check.ps1 -DatabaseUrl '...' # override DB connection"
    Write-Host "  .\health_check.ps1 -Quiet          # suppress colors/extra output"
    exit 0
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
# Scripts live in scripts/powershell/, two levels below the project root.
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

# Output helpers
$PassCount = 0
$FailCount = 0
$WarnCount = 0

function Write-Header ([string]$Text) {
    if (-not $Quiet) { Write-Host "`n$($Text)" -ForegroundColor Cyan -Style Bold }
}

function Write-Ok ([string]$Text) {
    if (-not $Quiet) { Write-Host "  [ OK ]  $Text" -ForegroundColor Green }
    $script:PassCount++
}

function Write-Fail ([string]$Text) {
    if (-not $Quiet) { Write-Host "  [FAIL]  $Text" -ForegroundColor Red }
    $script:FailCount++
}

function Write-Warn ([string]$Text) {
    if (-not $Quiet) { Write-Host "  [WARN]  $Text" -ForegroundColor Yellow }
    $script:WarnCount++
}

# ------------------------------------------------------------------
# 1. Required CLIs
# ------------------------------------------------------------------
Write-Header "1. Required command-line tools"
foreach ($tool in @('uv', 'psql', 'mongosh')) {
    try {
        $cmd = Get-Command $tool -ErrorAction Stop
        Write-Ok "$tool found: $($cmd.Source)"
    } catch {
        if ($tool -eq 'mongosh') {
            Write-Warn "$tool not found on PATH — MongoDB checks skipped"
        } else {
            Write-Fail "$tool not found on PATH"
        }
    }
}

# ------------------------------------------------------------------
# 2. Python via uv
# ------------------------------------------------------------------
Write-Header "2. Python environment (uv)"
try {
    $pyVersion = (uv python find 3.13 2>$null)
    if ($pyVersion) {
        $ver = (& $pyVersion --version 2>&1 | ForEach-Object { $_.Split(' ')[1] })
        Write-Ok "uv-managed Python 3.13+ found: $ver"
    } else {
        Write-Fail "uv cannot resolve a Python 3.13+ interpreter"
    }
} catch {
    Write-Fail "uv not on PATH or failed to find Python"
}

# ------------------------------------------------------------------
# 3. .env
# ------------------------------------------------------------------
Write-Header "3. Environment file"
$envFile = Join-Path $ProjectRoot ".env"
$envExample = Join-Path $ProjectRoot ".env.example"

if (Test-Path $envFile) {
    Write-Ok ".env present at project root"
} elseif (Test-Path $envExample) {
    Write-Warn ".env not found (copy .env.example and fill in credentials)"
} else {
    Write-Fail ".env and .env.example both missing"
}

# ------------------------------------------------------------------
# 4. Postgres
# ------------------------------------------------------------------
Write-Header "4. Postgres"
try {
    $psqlCmd = Get-Command psql -ErrorAction Stop

    if (-not $DatabaseUrl -and (Test-Path $envFile)) {
        # Load .env file
        Get-Content $envFile | Where-Object { $_ -match '=' -and $_ -notmatch '^#' } | ForEach-Object {
            $name, $value = $_.Split('=', 2)
            [System.Environment]::SetEnvironmentVariable($name.Trim(), $value.Trim())
        }

        if ($env:POSTGRES_HOST -and $env:POSTGRES_DATABASE -and $env:POSTGRES_USERNAME) {
            $port = if ($env:POSTGRES_PORT) { $env:POSTGRES_PORT } else { "5432" }
            $DatabaseUrl = "postgresql://$($env:POSTGRES_USERNAME):$($env:POSTGRES_PASSWORD)@$($env:POSTGRES_HOST):$port/$($env:POSTGRES_DATABASE)"
        }
    }

    if (-not $DatabaseUrl) {
        Write-Warn "DATABASE_URL not set - skipping Postgres ping"
    } else {
        $pgVersion = psql $DatabaseUrl -tAc 'SELECT version();' 2>$null
        if ($pgVersion -like 'PostgreSQL*') {
            Write-Ok "Postgres reachable: $($pgVersion.Split(',')[0])"
        } else {
            Write-Fail "Postgres unreachable: $pgVersion"
        }
    }
} catch {
    Write-Fail "psql not on PATH - cannot check Postgres"
}

# ------------------------------------------------------------------
# 5. MongoDB
# ------------------------------------------------------------------
Write-Header "5. MongoDB"
try {
    $mongoshCmd = Get-Command mongosh -ErrorAction Stop
    $mongoUri = if ($env:MONGO_URI) { $env:MONGO_URI } else { "mongodb://localhost:27017" }
    $mongoPing = mongosh --quiet --eval 'db.runCommand({ping:1}).ok' --uri $mongoUri 2>$null

    if ($mongoPing -eq "1") {
        Write-Ok "MongoDB ping ok at $mongoUri"
    } else {
        Write-Fail "MongoDB ping failed: $mongoPing"
    }
} catch {
    Write-Warn "mongosh not on PATH - skipping MongoDB ping"
}

# ------------------------------------------------------------------
# 6. Disk
# ------------------------------------------------------------------
Write-Header "6. Disk usage"
$logsDir = Join-Path $ProjectRoot "logs"
if (Test-Path $logsDir) {
    $logsSize = (Get-ChildItem $logsDir -Recurse | Measure-Object -Property Length -Sum).Sum
    $logsMb = [math]::Round($logsSize / 1MB, 1)
    Write-Ok "logs/ size: $logsMb MB"
} else {
    Write-Warn "logs/ directory does not exist"
}

$venvDir = Join-Path $ProjectRoot ".venv"
if (Test-Path $venvDir) {
    $venvSize = (Get-ChildItem $venvDir -Recurse | Measure-Object -Property Length -Sum).Sum
    $venvMb = [math]::Round($venvSize / 1MB, 1)
    Write-Ok ".venv/ size: $venvMb MB"
} else {
    Write-Warn ".venv/ does not exist (run 'uv sync')"
}

# ------------------------------------------------------------------
# 7. Deep: warehouse table counts
# ------------------------------------------------------------------
if ($Deep -and (Get-Command psql -ErrorAction SilentlyContinue) -and $DatabaseUrl) {
    Write-Header "7. Warehouse table counts (deep)"
    $query = "SELECT table_schema, table_name, n_live_tup FROM information_schema.tables t JOIN pg_stat_user_tables s USING (table_schema, table_name) WHERE table_schema IN ('staging','core') ORDER BY table_schema, table_name;"
    $results = psql $DatabaseUrl -tAc $query 2>$null
    foreach ($line in $results) {
        if ($line) {
            $parts = $line.Split('|')
            Write-Ok "$($parts[0]).$($parts[1]) - $($parts[2]) rows"
        }
    }
}

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
Write-Header "Summary"
Write-Host "  $PassCount passed, $WarnCount warned, $FailCount failed" -ForegroundColor White

if ($FailCount -gt 0) {
    exit 1
}
exit 0
