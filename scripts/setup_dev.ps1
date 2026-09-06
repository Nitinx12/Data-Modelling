$ErrorActionPreference = 'Stop'

param (
    [switch]$SkipHealth,
    [switch]$NoSync,
    [switch]$Help
)

if ($Help) {
    Write-Host "setup_dev.ps1 - one-shot local environment setup for new contributors"
    Write-Host "Steps (in order):"
    Write-Host "  1. Verify uv is installed"
    Write-Host "  2. Sync project dependencies (uv sync)"
    Write-Host "  3. Copy .env.example -> .env if .env missing"
    Write-Host "  4. Verify .env has no placeholder values"
    Write-Host "  5. Run health_check.ps1 if present"
    Write-Host "`nUsage:"
    Write-Host "  .\setup_dev.ps1                    # full setup"
    Write-Host "  .\setup_dev.ps1 -SkipHealth      # skip health_check.ps1"
    Write-Host "  .\setup_dev.ps1 -NoSync          # don't run uv sync"
    Write-Host "  .\setup_dev.ps1 -Help            # this help"
    exit 0
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProjectRoot = Split-Path -Parent $ScriptDir
Set-Location $ProjectRoot

# Output helpers
$C_OK = "Green"
$C_FAIL = "Red"
$C_WARN = "Yellow"

function Write-Ok ([string]$Text) { Write-Host "  [ OK ]  $Text" -ForegroundColor Green }
function Write-Fail ([string]$Text) { Write-Host "  [FAIL]  $Text" -ForegroundColor Red; exit 1 }
function Write-Warn ([string]$Text) { Write-Host "  [WARN]  $Text" -ForegroundColor Yellow }
function Write-Header ([string]$Text) { Write-Host "`n$($Text)" -ForegroundColor Cyan -Style Bold }

# ------------------------------------------------------------------
# 1. uv
# ------------------------------------------------------------------
Write-Header "1. Verifying uv"

try {
    $uvCmd = Get-Command uv -ErrorAction Stop
    Write-Ok "uv found: $($uvCmd.Source)"
} catch {
    Write-Fail "uv not found. Install from https://github.com/astral-sh/uv"
}

# ------------------------------------------------------------------
# 2. Sync dependencies
# ------------------------------------------------------------------
if (-not $NoSync) {
    Write-Header "2. Syncing dependencies (uv sync)"
    uv sync
    Write-Ok "uv sync complete"
} else {
    Write-Warn "Skipped uv sync (-NoSync)"
}

# ------------------------------------------------------------------
# 3. .env
# ------------------------------------------------------------------
Write-Header "3. .env file"

if (-not (Test-Path ".env")) {
    if (Test-Path ".env.example") {
        Copy-Item ".env.example" ".env"
        Write-Ok "Created .env from .env.example (fill in real values before running the pipeline)"
    } else {
        Write-Fail ".env.example missing - cannot scaffold .env"
    }
} else {
    Write-Ok ".env already present"
}

# ------------------------------------------------------------------
# 4. .env placeholder check
# ------------------------------------------------------------------
Write-Header "4. .env placeholder check"

if (Test-Path ".env") {
    $placeholderHits = Get-Content ".env" | Where-Object {
        $_ -match '^(POSTGRES_(PASSWORD|HOST|username|database))|MONGO_URI' -and
        $_ -match '(<|TODO|CHANGE_ME|REPLACE_ME|xxxxxxxx)'
    }

    if ($placeholderHits) {
        Write-Warn "Placeholder values detected in .env - update them before running the pipeline:"
        $placeholderHits | ForEach-Object { Write-Host "      $_" }
    } else {
        Write-Ok "No obvious placeholders in .env"
    }
}

# ------------------------------------------------------------------
# 5. Health check
# ------------------------------------------------------------------
if (-not $SkipHealth) {
    Write-Header "5. Health check"
    $healthScript = Join-Path "scripts" "health_check.ps1"
    if (Test-Path $healthScript) {
        try {
            & $healthScript
        } catch {
            Write-Warn "health_check.ps1 reported issues (see above)"
        }
    } else {
        Write-Warn "scripts/health_check.ps1 not found"
    }
}

Write-Header "Done"
Write-Host "  Setup complete." -ForegroundColor Green
Write-Host "  Next steps:"
Write-Host "    1. Edit .env with your real credentials"
Write-Host "    2. Run 'make pipeline' to test end-to-end"
Write-Host "    3. Run 'make test' for unit tests"
