"""Dagster Definitions — asset DAG + job + daily schedule.

Usage:
    dagster dev -m orchestration.definitions          # local UI at http://localhost:3000
    dagster job execute -m orchestration.definitions --job full_pipeline
"""

from __future__ import annotations

from dagster import (
    Definitions,
    ScheduleDefinition,
    define_asset_job,
    load_assets_from_modules,
)

from orchestration.assets import core, quality, staging

all_assets = load_assets_from_modules([staging, core, quality])

pipeline_job = define_asset_job("full_pipeline", selection="*")

daily_schedule = ScheduleDefinition(
    job=pipeline_job,
    cron_schedule="0 6 * * *",  # 06:00 daily — run the full ELT
)

defs = Definitions(
    assets=all_assets,
    jobs=[pipeline_job],
    schedules=[daily_schedule],
)
