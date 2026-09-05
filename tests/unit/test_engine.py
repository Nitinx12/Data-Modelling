"""
tests/unit/test_engine.py
=========================
Tests for utils/engine.py — env var loading, type coercion, and
fail-fast validation.

Because the module reads env vars at import time, each test calls
`reload_engine()` (from conftest) after setting up its own environment.
"""

from __future__ import annotations

import pytest

from tests.helpers import reload_engine


class TestPostgresEnvLoading:
    def test_loads_postgres_vars(self, mock_env: dict[str, str]) -> None:
        config = reload_engine()
        assert config.POSTGRES_HOST == "localhost"
        assert config.POSTGRES_DATABASE == "test_warehouse"
        assert config.POSTGRES_USERNAME == "test_user"

    def test_postgres_port_coerced_to_int(self, mock_env: dict[str, str]) -> None:
        config = reload_engine()
        assert isinstance(config.POSTGRES_PORT, int)
        assert config.POSTGRES_PORT == 5432

    def test_postgres_port_invalid_raises(self, mock_env: dict[str, str]) -> None:
        import os

        os.environ["POSTGRES_PORT"] = "not-a-number"
        with pytest.raises(OSError, match="POSTGRES_PORT must be an integer"):
            reload_engine()

    def test_optional_postgres_schemas_default_none(
        self, mock_env: dict[str, str]
    ) -> None:
        config = reload_engine()
        assert config.POSTGRES_SCHEMA_BRONZE is None
        assert config.POSTGRES_SCHEMA_SILVER is None
        assert config.POSTGRES_SCHEMA_GOLD is None


class TestMongoEnvLoading:
    def test_loads_mongo_vars(self, mock_env: dict[str, str]) -> None:
        config = reload_engine()
        assert config.MONGO_URI == "mongodb://localhost:27017"
        assert config.MONGO_DB == "test_db"


class TestDatabricksEnvLoading:
    def test_databricks_vars_default_none(self, mock_env: dict[str, str]) -> None:
        config = reload_engine()
        assert config.DATABRICKS_HOST is None
        assert config.DATABRICKS_HTTP_PATH is None
        assert config.DATABRICKS_TOKEN is None
        assert config.DATABRICKS_CATALOG is None
        assert config.DATABRICKS_SCHEMA is None


class TestValidation:
    @pytest.mark.parametrize(
        "missing_var",
        [
            "POSTGRES_HOST",
            "POSTGRES_PORT",
            "POSTGRES_DATABASE",
            "POSTGRES_USERNAME",
            "POSTGRES_PASSWORD",
            "MONGO_URI",
            "MONGO_DB",
        ],
    )
    def test_missing_required_var_raises(
        self, clean_env: pytest.MonkeyPatch, missing_var: str
    ) -> None:
        all_required = {
            "POSTGRES_HOST": "h",
            "POSTGRES_PORT": "5432",
            "POSTGRES_DATABASE": "d",
            "POSTGRES_USERNAME": "u",
            "POSTGRES_PASSWORD": "p",
            "MONGO_URI": "mongodb://x",
            "MONGO_DB": "db",
        }
        del all_required[missing_var]
        for k, v in all_required.items():
            clean_env.setenv(k, v)
        with pytest.raises(OSError, match="Missing required environment variables"):
            reload_engine()

    def test_validation_passes_with_full_env(self, mock_env: dict[str, str]) -> None:
        reload_engine()  # should not raise
