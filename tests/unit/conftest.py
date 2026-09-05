"""
tests/unit/conftest.py
======================
pytest fixtures shared across all unit tests.

Isolation strategy:
  - All tests get DATA_MODELLING_NO_DOTENV=1 so utils.engine skips
    load_dotenv() entirely — no real .env interference.
  - _reset_utils drops cached utils.* modules between tests so reimports
    re-run module-level env loading against the current os.environ.
"""

from __future__ import annotations

import importlib
import os
import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest

# Ensure the project root is on the path so `utils` resolves as a module.
_PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))


# ---------------------------------------------------------------------------
# Per-test isolation
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _reset_utils() -> None:
    """Drop cached utils.* modules between tests so reimports re-run
    module-level env loading against the current os.environ."""
    for name in list(sys.modules):
        if name == "utils" or name.startswith("utils."):
            del sys.modules[name]
    yield
    for name in list(sys.modules):
        if name == "utils" or name.startswith("utils."):
            del sys.modules[name]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def reload_engine() -> object:
    """Re-import utils.engine against the current os.environ."""
    import utils.engine

    return importlib.reload(utils.engine)


def reload_connection() -> object:
    """Re-import utils.connection against the current os.environ."""
    import utils.connection

    return importlib.reload(utils.connection)


# ---------------------------------------------------------------------------
# Environment fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def clean_env(monkeypatch: pytest.MonkeyPatch) -> pytest.MonkeyPatch:
    """Remove relevant env vars and set DATA_MODELLING_NO_DOTENV so utils.engine
    skips load_dotenv during tests."""
    # Tell utils.engine to skip loading real .env
    monkeypatch.setenv("DATA_MODELLING_NO_DOTENV", "1")
    # Wipe any pre-existing values
    for k in list(os.environ):
        if k not in ("DATA_MODELLING_NO_DOTENV",) and any(
            k.startswith(p) for p in ("POSTGRES_", "MONGO_", "DATABRICKS_", "PYSPARK_")
        ):
            monkeypatch.delenv(k)
    return monkeypatch


@pytest.fixture
def mock_env(clean_env: pytest.MonkeyPatch) -> dict[str, str]:
    """Set minimal env vars needed by utils/engine.py validation."""
    env = {
        "POSTGRES_HOST": "localhost",
        "POSTGRES_PORT": "5432",
        "POSTGRES_DATABASE": "test_warehouse",
        "POSTGRES_USERNAME": "test_user",
        "POSTGRES_PASSWORD": "test_pass",
        "MONGO_URI": "mongodb://localhost:27017",
        "MONGO_DB": "test_db",
    }
    for k, v in env.items():
        clean_env.setenv(k, v)
    return env


@pytest.fixture
def mock_logger() -> MagicMock:
    """No-op mock logger so tests that call get_logger() don't touch the filesystem."""
    import logging

    mock = MagicMock(spec=logging.Logger)
    mock.info = MagicMock()
    mock.warning = MagicMock()
    mock.error = MagicMock()
    mock.exception = MagicMock()
    mock.debug = MagicMock()
    return mock


@pytest.fixture
def tmp_log_dir(tmp_path: Path) -> Path:
    """Temp log directory that won't pollute the real logs/ folder."""
    return tmp_path / "logs"
