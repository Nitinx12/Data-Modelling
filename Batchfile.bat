@echo off
rem =====================================================================
rem Batchfile.bat - Windows entry point mirroring the Makefile.
rem
rem For shells without make/WSL:
rem     Batchfile.bat pipeline        staging → models → quality → GX
rem     Batchfile.bat lint            ruff check .
rem     Batchfile.bat test            pytest unit tests
rem
rem Requires : uv on PATH (https://docs.astral.sh/uv/), .env for DB targets
rem Ops cmds : shell out to scripts\powershell\*.ps1
rem Extra args are passed through, e.g.
rem     Batchfile.bat gx --suite duplicate_key_suite --strict
rem =====================================================================

setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
set "PYTHONUTF8=1"
cd /d "%~dp0"

set "CMD=%~1"
if "%CMD%"=="" set "CMD=help"

rem Collect everything after the command so it can be passed through.
set "ARGS="
:collect_args
shift
if "%~1"=="" goto dispatch
set "ARGS=%ARGS% %~1"
goto collect_args

:dispatch
if /i "%CMD%"=="help" goto help
if /i "%CMD%"=="--help" goto help
if /i "%CMD%"=="-h" goto help
if /i "%CMD%"=="install" goto install
if /i "%CMD%"=="setup" goto setup
if /i "%CMD%"=="staging" goto staging
if /i "%CMD%"=="staging-one" goto staging_one
if /i "%CMD%"=="models" goto models
if /i "%CMD%"=="models-only" goto models_only
if /i "%CMD%"=="quality" goto quality
if /i "%CMD%"=="dq" goto quality
if /i "%CMD%"=="gx" goto gx
if /i "%CMD%"=="pipeline" goto pipeline
if /i "%CMD%"=="lint" goto lint
if /i "%CMD%"=="lint-fix" goto lint_fix
if /i "%CMD%"=="format" goto format
if /i "%CMD%"=="format-check" goto format_check
if /i "%CMD%"=="test" goto test
if /i "%CMD%"=="test-cov" goto test_cov
if /i "%CMD%"=="analytics" goto analytics
if /i "%CMD%"=="dashboard" goto dashboard
if /i "%CMD%"=="dagster" goto dagster
if /i "%CMD%"=="dagster-job" goto dagster_job
if /i "%CMD%"=="compose-up" goto compose_up
if /i "%CMD%"=="compose-down" goto compose_down
if /i "%CMD%"=="compose-logs" goto compose_logs
if /i "%CMD%"=="health-check" goto health_check
if /i "%CMD%"=="health-check-deep" goto health_check_deep
if /i "%CMD%"=="security-check" goto security_check
if /i "%CMD%"=="logs-summary" goto logs_summary
if /i "%CMD%"=="eda" goto eda
if /i "%CMD%"=="r-analysis" goto r_analysis
if /i "%CMD%"=="r-report" goto r_report
if /i "%CMD%"=="r-analysis-all" goto r_analysis_all
if /i "%CMD%"=="notebooks" goto notebooks
if /i "%CMD%"=="clean" goto clean

echo Unknown command "%CMD%".
echo.
goto help

rem =====================================================================
rem Pipeline
rem =====================================================================
:staging
call :check_uv
if errorlevel 1 exit /b 1
call :check_env
if errorlevel 1 exit /b 1
uv run python scripts\python\pg_staging.py %ARGS%
exit /b %ERRORLEVEL%

:staging_one
call :check_uv
if errorlevel 1 exit /b 1
call :check_env
if errorlevel 1 exit /b 1
if "%ARGS%"=="" (
    echo Usage: Batchfile.bat staging-one --collection ^<name^>
    exit /b 2
)
uv run python scripts\python\pg_staging.py %ARGS%
exit /b %ERRORLEVEL%

:models
call :check_uv
if errorlevel 1 exit /b 1
call :check_env
if errorlevel 1 exit /b 1
uv run python scripts\python\run_models.py %ARGS%
exit /b %ERRORLEVEL%

:models_only
call :check_uv
if errorlevel 1 exit /b 1
call :check_env
if errorlevel 1 exit /b 1
if "%ARGS%"=="" (
    echo Usage: Batchfile.bat models-only --only ^<model.sql ...^>
    exit /b 2
)
uv run python scripts\python\run_models.py %ARGS%
exit /b %ERRORLEVEL%

:quality
call :check_uv
if errorlevel 1 exit /b 1
call :check_env
if errorlevel 1 exit /b 1
uv run python scripts\python\run_data_quality_loops.py %ARGS%
exit /b %ERRORLEVEL%

:gx
call :check_uv
if errorlevel 1 exit /b 1
call :check_env
if errorlevel 1 exit /b 1
uv run python scripts\python\gx_run.py %ARGS%
exit /b %ERRORLEVEL%

:pipeline
call :check_uv
if errorlevel 1 exit /b 1
call :check_env
if errorlevel 1 exit /b 1
uv run python scripts\python\main.py %ARGS%
exit /b %ERRORLEVEL%

rem =====================================================================
rem Quality gates (lint / format / tests)
rem =====================================================================
:lint
call :check_uv
if errorlevel 1 exit /b 1
uv run ruff check .
exit /b %ERRORLEVEL%

:lint_fix
call :check_uv
if errorlevel 1 exit /b 1
uv run ruff check --fix .
exit /b %ERRORLEVEL%

:format
call :check_uv
if errorlevel 1 exit /b 1
uv run ruff format .
exit /b %ERRORLEVEL%

:format_check
call :check_uv
if errorlevel 1 exit /b 1
uv run ruff format --check .
exit /b %ERRORLEVEL%

:test
call :check_uv
if errorlevel 1 exit /b 1
uv run pytest
exit /b %ERRORLEVEL%

:test_cov
call :check_uv
if errorlevel 1 exit /b 1
uv run python -m pytest --cov=utils --cov-report=term-missing --cov-report=html:htmlcov tests\python\unit
exit /b %ERRORLEVEL%

rem =====================================================================
rem Analytics (psql, DATABASE_URL required)
rem =====================================================================
:analytics
call :check_env
if errorlevel 1 exit /b 1
if not defined DATABASE_URL (
    echo Set DATABASE_URL ^(or POSTGRES_* and use the make target^) before running analytics.
    exit /b 1
)
if not exist sql\analytics (
    echo No such dir: sql\analytics
    exit /b 1
)
for %%F in (sql\analytics\*.sql) do (
    set "NAME=%%~nF"
    if "!NAME:~0,3!"=="00_" (
        echo   bootstrap skipped: %%F
    ) else (
        echo.
        echo ==================== %%F ====================
        psql "%DATABASE_URL%" -v ON_ERROR_STOP=1 --pset border=2 --pset pager=off -f "%%F"
        if errorlevel 1 exit /b 1
    )
)
exit /b 0

rem =====================================================================
rem Orchestration / dashboard / Docker
rem =====================================================================
:dashboard
call :check_uv
if errorlevel 1 exit /b 1
uv run streamlit run dashboard\Home.py %ARGS%
exit /b %ERRORLEVEL%

:dagster
call :check_uv
if errorlevel 1 exit /b 1
uv run dagster dev -m orchestration.definitions --host 0.0.0.0 --port 3000 %ARGS%
exit /b %ERRORLEVEL%

:dagster_job
call :check_uv
if errorlevel 1 exit /b 1
uv run dagster job execute -m orchestration.definitions --job full_pipeline %ARGS%
exit /b %ERRORLEVEL%

:compose_up
docker compose up --build -d postgres mongo
exit /b %ERRORLEVEL%

:compose_down
docker compose down
exit /b %ERRORLEVEL%

:compose_logs
docker compose logs -f
exit /b %ERRORLEVEL%

rem =====================================================================
rem Setup, ops scripts, housekeeping
rem =====================================================================
:install
call :check_uv
if errorlevel 1 exit /b 1
uv sync --group dev
exit /b %ERRORLEVEL%

:setup
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\powershell\setup_dev.ps1 %ARGS%
exit /b %ERRORLEVEL%

:health_check
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\powershell\health_check.ps1 %ARGS%
exit /b %ERRORLEVEL%

:health_check_deep
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\powershell\health_check.ps1 -Deep %ARGS%
exit /b %ERRORLEVEL%

:security_check
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\powershell\security_check.ps1 %ARGS%
exit /b %ERRORLEVEL%

:logs_summary
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\powershell\monitor_logs.ps1 summary %ARGS%
exit /b %ERRORLEVEL%

rem =====================================================================
rem R Analysis targets
rem =====================================================================
:eda
call :check_env
if errorlevel 1 exit /b 1
quarto render notebooks\00_eda_overview.qmd %ARGS%
exit /b %ERRORLEVEL%

:r_analysis
call :check_env
if errorlevel 1 exit /b 1
Rscript r_analysis/run_r_script.R all %ARGS%
exit /b %ERRORLEVEL%

:r_report
Rscript -e "setwd('r_analysis/report'); tinytex::latexmk('main.tex')"
if errorlevel 1 exit /b 1
copy /Y r_analysis\report\main.pdf r_analysis\report\report.pdf
exit /b %ERRORLEVEL%

:r_analysis_all
call :check_env
if errorlevel 1 exit /b 1
quarto render notebooks\00_eda_overview.qmd
if errorlevel 1 exit /b 1
Rscript r_analysis/run_r_script.R all
if errorlevel 1 exit /b 1
Rscript -e "setwd('r_analysis/report'); tinytex::latexmk('main.tex')"
if errorlevel 1 exit /b 1
copy /Y r_analysis\report\main.pdf r_analysis\report\report.pdf
exit /b %ERRORLEVEL%

:notebooks
call :check_env
if errorlevel 1 exit /b 1
quarto render notebooks %ARGS%
exit /b 0

:clean
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Recurse -Directory -Include __pycache__,.pytest_cache -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\\.venv\\' } | Remove-Item -Recurse -Force"
exit /b %ERRORLEVEL%

rem =====================================================================
rem Guards
rem =====================================================================
:check_uv
where uv >nul 2>&1
if errorlevel 1 (
    echo uv not found on PATH - install it from https://docs.astral.sh/uv/
    exit /b 1
)
exit /b 0

:check_env
if exist .env exit /b 0
set "MISSING="
for %%V in (POSTGRES_HOST POSTGRES_PORT POSTGRES_DATABASE POSTGRES_USERNAME POSTGRES_PASSWORD MONGO_URI MONGO_DB) do (
    if not defined %%V set "MISSING=!MISSING! %%V"
)
if defined MISSING (
    echo Missing .env - copy .env.example and fill it in. Or export:!MISSING!
    exit /b 1
)
exit /b 0

rem =====================================================================
rem Help (default)
rem =====================================================================
:help
echo Warehouse pipeline - Windows entry point (mirrors the Makefile)
echo.
echo Usage: Batchfile.bat ^<command^> [extra args]
echo.
echo Pipeline
echo   pipeline        staging - models - quality - GX (scripts\python\main.py)
echo   staging         load every Mongo collection (incremental, validated)
echo   staging-one     one collection        Batchfile.bat staging-one --collection addres
echo   models          all models, dims before facts
echo   models-only     named models          Batchfile.bat models-only --only fact_orders.sql
echo   quality         5 SQL data-quality loops (add --strict)
echo   dq              alias for quality
echo   gx              Great Expectations suites (--suite NAME, --strict)
echo.
echo R analysis ^(read only against core^)
echo   eda             quarto render notebooks\00_eda_overview.qmd
echo   notebooks       quarto render notebooks
echo   r-analysis      Rscript r_analysis\run_r_script.R all ^(CSV + PNG^)
echo   r-report        compile r_analysis\report\main.tex to PDF
echo   r-analysis-all  eda + r-analysis + r-report in order
echo.
echo Quality gates
echo   lint            ruff check .
echo   lint-fix        ruff check --fix .
echo   format          ruff format .
echo   format-check    ruff format --check .
echo   test            pytest (no DB needed)
echo   test-cov        pytest with coverage
echo.
echo Analytics / ops
echo   analytics       apply sql\analytics\*.sql via psql (skips 00_ bootstrap)
echo   dashboard       streamlit on core      http://localhost:8501
echo   dagster         dagster UI             http://localhost:3000
echo   dagster-job     run the full_pipeline job headless
echo   health-check    scripts\powershell\health_check.ps1 (-Deep for row counts)
echo   security-check  scripts\powershell\security_check.ps1
echo   logs-summary    scripts\powershell\monitor_logs.ps1 summary
echo.
echo Setup / Docker
echo   install         uv sync --group dev
echo   setup           scripts\powershell\setup_dev.ps1
echo   compose-up      docker compose up (postgres:16 + mongo:7, seeded)
echo   compose-down    docker compose down
echo   compose-logs    docker compose logs -f
echo   clean           remove __pycache__ / .pytest_cache (keeps .venv)
echo.
echo Extra args pass through to the underlying script.
exit /b 0
