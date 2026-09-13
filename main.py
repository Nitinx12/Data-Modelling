"""
main.py (repo root)
==================
Thin shim that delegates to `scripts/python/main.py` — the real orchestrator.

Why a shim exists:
  - `pyproject.toml` exposes `pipeline = "main:main"` so `uv run pipeline`
    works from anywhere without remembering the script path.
  - `docs/scripts.md` and `Makefile:224` document the canonical entry as
    `uv run scripts/python/main.py`; this file just re-exports that.

Git workflow note: this file is intentionally tiny. Business logic lives
in `scripts/python/main.py` so git history / CodeQL / ruff only needs to
review one implementation.

Usage:
    uv run python main.py                          # staging -> models -> DQ --strict
    uv run pipeline                                # same via entry point
    uv run python main.py --skip-staging           # models + DQ only
    uv run python main.py --continue-on-error
"""

from __future__ import annotations

import sys
from pathlib import Path

# Ensure repo root is on sys.path so `scripts.python.main` is importable
# when executed as `python main.py` (not via `uv run scripts/python/main.py`).
ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

try:
    from scripts.python.main import main as _pipeline_main
except ImportError:  # pragma: no cover — fallback for edge cases
    import subprocess

    def _pipeline_main(*_: object) -> int:  # type: ignore[no-redef]
        script = ROOT / "scripts" / "python" / "main.py"
        result = subprocess.run(
            [sys.executable, str(script), *sys.argv[1:]],
            check=False,
        )
        return result.returncode


def main() -> int:
    """Entry point for `pipeline = \"main:main\"`."""
    return _pipeline_main()


if __name__ == "__main__":
    sys.exit(main())
