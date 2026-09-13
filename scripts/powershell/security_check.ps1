param (
    [switch]$ShellCheck
)

$ErrorActionPreference = 'Stop'

# Output helpers
$PassCount = 0
$FailCount = 0
$WarnCount = 0

function Write-Header ([string]$Text) {
    Write-Host "`n$($Text)" -ForegroundColor Cyan
}

function Write-Ok ([string]$Text) {
    Write-Host "  [ OK ]  $Text" -ForegroundColor Green
    $script:PassCount++
}

function Write-Fail ([string]$Text) {
    Write-Host "  [FAIL]  $Text" -ForegroundColor Red
    $script:FailCount++
}

function Write-Warn ([string]$Text) {
    Write-Host "  [WARN]  $Text" -ForegroundColor Yellow
    $script:WarnCount++
}

$ProjectRoot = (Get-Location).Path # Assuming run from root

# ------------------------------------------------------------------
# 1. .env not tracked or staged
# ------------------------------------------------------------------
Write-Header "1. .env file handling"

if (Test-Path ".env") {
    # Is .env tracked?
    $tracked = git ls-files --error-unmatch .env 2>$null
    if ($tracked) {
        Write-Fail ".env is tracked by git - remove it with 'git rm --cached .env'"
    } else {
        Write-Ok ".env is not tracked by git"
    }

    # Is .env staged?
    $staged = git diff --cached --name-only | Where-Object { $_ -eq '.env' }
    if ($staged) {
        Write-Fail ".env is staged in the current index"
    } else {
        Write-Ok ".env is not staged"
    }
} else {
    Write-Warn ".env not present (skipped)"
}

# .env.* (except .env.example)
$nonExampleEnv = git ls-files | Where-Object { $_ -match '^\.env\.[^e]' }
if ($nonExampleEnv) {
    Write-Fail "A non-example .env.* file is tracked: $nonExampleEnv"
} else {
    Write-Ok "No non-example .env.* file is tracked"
}

# ------------------------------------------------------------------
# 2. Hard-coded credentials in source
# ------------------------------------------------------------------
Write-Header "2. Hard-coded credentials in source"

# Search for common patterns: assignment to *PASSWORD*, *SECRET*, *TOKEN* with a quoted value.
$secretPattern = '(password|secret|api[_-]?key|access[_-]?key|token)\s*=\s*[''"][^''"$]{6,}'
$sourceFiles = Get-ChildItem -Include *.py, *.sql, *.sh -Recurse -Path models, scripts, sql, utils

$secretHits = foreach ($file in $sourceFiles) {
    Select-String -Path $file.FullName -Pattern $secretPattern | ForEach-Object {
        "$($file.FullName):$($_.LineNumber): $($_.Line.Trim())"
    }
}

if ($secretHits) {
    Write-Fail "Possible hard-coded credentials found:"
    $secretHits | ForEach-Object { Write-Host "      $_" }
} else {
    Write-Ok "No obvious hard-coded credentials in models/, scripts/, sql/, utils/"
}

# PostgreSQL DSN with embedded password
# - "$" is excluded in both character classes so placeholder DSNs built
#   from shell variables (postgresql://${POSTGRES_USERNAME}:${POSTGRES_PASSWORD}@...)
#   don't match — only literal credentials trip this check.
# - security_check scripts themselves are excluded from the results: the
#   pattern lines in them contain the literal text being searched for.
# - gitignored build dirs (.venv, node_modules) are excluded: their
#   site-packages docstring examples are not our credentials.
$dsnPattern = 'postgresql://[^:\s$]+:[^@\s$]+@'
$allFiles = Get-ChildItem -Include *.py, *.sql, *.sh, *.md -Recurse
$dsnHits = foreach ($file in $allFiles) {
    if ($file.FullName -match '(\.git|docs|README|\.env\.example|\.venv|node_modules|security_check)') { continue }
    Select-String -Path $file.FullName -Pattern $dsnPattern | ForEach-Object {
        "$($file.FullName):$($_.LineNumber): $($_.Line.Trim())"
    }
}

if ($dsnHits) {
    Write-Fail "PostgreSQL DSN with embedded password found:"
    $dsnHits | ForEach-Object { Write-Host "      $_" }
} else {
    Write-Ok "No PostgreSQL DSN with embedded password in source"
}

# ------------------------------------------------------------------
# 3. Private keys
# ------------------------------------------------------------------
Write-Header "3. Private keys"

# Private keys in the repo. Gitignored build dirs are excluded: certifi's
# cacert.pem inside .venv is a CA bundle we installed, not our key.
$keyPatterns = @('*.pem', '*.key', 'id_rsa', 'id_dsa', 'id_ed25519')
$privateKeys = Get-ChildItem -Recurse -Include $keyPatterns | Where-Object { $_.FullName -notmatch '\\(\.git|\.venv|node_modules|logs)\\' }

if ($privateKeys) {
    Write-Fail "Private key files found in repo:"
    $privateKeys | ForEach-Object { Write-Host "      $($_.FullName)" }
} else {
    Write-Ok "No private key files in repo"
}

# ------------------------------------------------------------------
# 4. Coverage artifacts
# ------------------------------------------------------------------
# Coverage artifacts are gitignored local artifacts; the security concern
# is committing them, so check the git index (like the .env check above)
# rather than the working tree.
Write-Header "4. Coverage artifacts"

$trackedArtifacts = git ls-files -- 'htmlcov/*' '.coverage' '.coverage.*'
if ($trackedArtifacts) {
    Write-Fail "Coverage artifacts tracked by git:"
    $trackedArtifacts | ForEach-Object { Write-Host "      $_" }
} else {
    Write-Ok "No coverage artifacts tracked by git"
}

# ------------------------------------------------------------------
# 5. .gitignore coverage
# ------------------------------------------------------------------
Write-Header "5. .gitignore coverage"

$requiredPatterns = @('^\.env$', '^\.coverage', 'htmlcov/', '__pycache__/', '\.venv/', 'logs/')
$missing = @()

if (Test-Path ".gitignore") {
    $gitignoreContent = Get-Content ".gitignore"
    foreach ($pat in $requiredPatterns) {
        if (-not ($gitignoreContent -match $pat)) {
            $missing += $pat
        }
    }
} else {
    $missing = $requiredPatterns
}

if ($missing.Count -gt 0) {
    Write-Fail ".gitignore is missing patterns: $($missing -join ', ')"
} else {
    Write-Ok ".gitignore covers .env, .coverage, htmlcov/, __pycache__/, .venv/, logs/"
}

# ------------------------------------------------------------------
# 6. Optional shellcheck
# ------------------------------------------------------------------
if ($ShellCheck) {
    Write-Header "6. shellcheck"
    try {
        $scCmd = Get-Command shellcheck -ErrorAction Stop
        $scFail = 0
        $shFiles = Get-ChildItem -Path scripts -Filter *.sh
        foreach ($file in $shFiles) {
            $result = shellcheck $file.FullName 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "shellcheck $($file.Name)"
                $scFail = 1
            }
        }
        if ($scFail -eq 0) {
            Write-Ok "shellcheck clean on all scripts/*.sh"
        }
    } catch {
        Write-Warn "shellcheck not on PATH - install it to use this check"
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
