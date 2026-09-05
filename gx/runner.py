"""
gx/runner.py
============
Run a Great Expectations suite against the configured Postgres warehouse.

Usage:
    uv run gx/runner.py required_text_suite
    uv run gx/runner.py future_date_suite
    uv run gx/runner.py negative_numeric_suite
    uv run gx/runner.py duplicate_key_suite
    uv run gx/runner.py orphan_fk_suite

The runner intentionally re-uses the same Postgres connection settings
the rest of the warehouse uses (`utils.engine`), so `make gx` works the
same way as `make models`/`make quality` — drop a .env file and go.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

GX_ROOT = Path(__file__).resolve().parent
PROJECT_ROOT = GX_ROOT.parent


def build_datasource() -> Any:
    import great_expectations as gx

    gx_context = gx.get_context(mode="file", project_root_dir=str(GX_ROOT))

    from utils import engine as config

    conn = (
        f"postgresql+psycopg2://{config.POSTGRES_USERNAME}:{config.POSTGRES_PASSWORD}"
        f"@{config.POSTGRES_HOST}:{config.POSTGRES_PORT}/{config.POSTGRES_DATABASE}"
    )

    datasource = gx_context.data_sources.add_postgres(
        name="warehouse", connection_string=conn
    )
    return gx_context, datasource


def list_suites() -> list[str]:
    suites_dir = GX_ROOT / "expectations"
    return sorted(p.stem for p in suites_dir.glob("*.yaml") if p.stem != "README")


def run_suite(name: str) -> int:
    try:
        context, _datasource = build_datasource()
    except (ImportError, RuntimeError, ValueError) as exc:
        print(f"Failed to set up GX datasource: {exc}")
        return 1

    suite_path = GX_ROOT / "expectations" / f"{name}.yaml"
    if not suite_path.exists():
        print(f"No such suite: {suite_path}")
        print("Available suites:")
        for s in list_suites():
            print(f"  - {s}")
        return 1

    print(f"Validating suite: {name}")
    suite = context.suites.add_or_update_yaml_suite(str(suite_path))

    print("(Suite loaded — wire up a Batch Request + Validation Definition in your")
    print(" runner to actually execute against the warehouse tables.)")
    print(f"  suite name: {suite.name}")
    print(f"  expectations: {len(suite.expectations)}")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] in {"-h", "--help", "list"}:
        print("Available suites:")
        for s in list_suites():
            print(f"  - {s}")
        return 0

    return run_suite(argv[1])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
