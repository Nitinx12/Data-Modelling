"""
tests/helpers.py
================
Non-fixture helpers shared across all unit test modules.

These live here (not in conftest.py) because pytest treats tests/unit as
the import root when run via `pytest tests/unit`, so `conftest` is not a
regular importable module — it only exposes fixtures via pytest's injection.

Usage:
    from helpers import reload_engine, reload_connection
"""

from __future__ import annotations

import importlib


def reload_engine():
    """Re-import utils.engine against the current os.environ.

    Call after setting up env vars to ensure the re-import picks up the
    mocked environment rather than the real .env file.
    """
    import utils.engine

    return importlib.reload(utils.engine)


def reload_connection():
    """Re-import utils.connection against the current os.environ.

    Call after setting up env vars to ensure connection strings, etc.
    are built from the test's mocked environment.
    """
    import utils.connection

    return importlib.reload(utils.connection)
