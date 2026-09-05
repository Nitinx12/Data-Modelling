"""
main.py
========
One-shot pipeline orchestrator: runs the full ELT pipeline in sequence.

    uv run main.py                    # full pipeline: staging -> models -> data quality
    uv run main.py --skip-staging    # models + data quality only (staging already done)
    uv run main.py --skip-models     # staging + data quality only
    uv run main.py --continue-on-error   # keep going past model failures

Equivalent to:
    make staging && make models && make quality

Exit codes:
    0   all stages completed successfully
    1   at least one stage failed
    2   usage / argument error
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent / "scripts"


def run(script: Path, *args: str) -> subprocess.CompletedProcess[bytes]:
    cmd = ["uv", "run", str(script), *args]
    return subprocess.run(
        cmd,
        check=False,  # we handle errors ourselves
    )


def stage_header(name: str) -> None:
    sep = "=" * 60
    print(f"\n{sep}\n  {name}\n{sep}\n", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="main.py",
        description="Run the full warehouse pipeline (staging → models → data quality).",
    )
    parser.add_argument(
        "--skip-staging",
        action="store_true",
        help="Skip the staging load step.",
    )
    parser.add_argument(
        "--skip-models",
        action="store_true",
        help="Skip the warehouse model step.",
    )
    parser.add_argument(
        "--skip-quality",
        action="store_true",
        help="Skip the data quality checks step.",
    )
    parser.add_argument(
        "--continue-on-error",
        action="store_true",
        help="Continue past model failures instead of stopping.",
    )
    parser.add_argument(
        "--help-stages",
        action="store_true",
        help="Print stage descriptions and exit.",
    )
    args = parser.parse_args()

    if args.help_stages:
        print("Pipeline stages:")
        print("  1. pg_staging.py   — MongoDB -> Postgres staging (incremental)")
        print("  2. run_models.py   — dims + facts in core schema (ordered)")
        print("  3. run_data_quality_loops.py — read-only SQL audit checks")
        print("\nAll three stages are enabled by default. Use --skip-* to disable.")
        return 0

    total_start = time.monotonic()
    stages: list[tuple[str, Path, list[str]]] = []

    if not args.skip_staging:
        stages.append(("STAGING", SCRIPTS_DIR / "pg_staging.py", []))

    if not args.skip_models:
        model_args = ["--continue-on-error"] if args.continue_on_error else []
        stages.append(("MODELS", SCRIPTS_DIR / "run_models.py", model_args))

    if not args.skip_quality:
        stages.append(("DATA QUALITY", SCRIPTS_DIR / "run_data_quality_loops.py", []))

    if not stages:
        print("Error: all stages disabled. Nothing to do.", file=sys.stderr)
        return 2

    results: list[tuple[str, int]] = []

    for label, script, extra_args in stages:
        stage_header(label)
        t0 = time.monotonic()
        result = run(script, *extra_args)
        elapsed = time.monotonic() - t0
        results.append((label, result.returncode))
        status = "OK" if result.returncode == 0 else f"FAIL (exit {result.returncode})"
        print(f"\n  [{status}] {script.name} — {elapsed:.1f}s", flush=True)
        if result.returncode != 0 and not args.continue_on_error:
            print(
                f"\n✗ Pipeline stopped at '{label}' (--continue-on-error not set).",
                flush=True,
            )
            break

    total_elapsed = time.monotonic() - total_start
    print(f"\n{'=' * 60}")
    print(f"  Pipeline complete — {total_elapsed:.1f}s total")
    print(f"{'=' * 60}")

    failures = [(lbl, code) for lbl, code in results if code != 0]
    if failures:
        for lbl, code in failures:
            print(f"  ✗ {lbl}: exit {code}")
        print(f"\n✗ {len(failures)} stage(s) failed.")
        return 1
    else:
        print("\n✓ All stages completed successfully.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
