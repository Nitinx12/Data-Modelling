"""
tests/unit/test_connection.py
===========================
Tests for utils/connection.py — connection factory functions and
caching behaviour.  All external clients are mocked at their source modules
(sqlalchemy, pymongo, databricks_sql) so no live connections are required.
"""
from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from tests.helpers import reload_connection


class TestGetPostgresEngine:
    def test_creates_sqlalchemy_engine_on_first_call(
        self, mock_env: dict[str, str]
    ) -> None:
        with patch("sqlalchemy.create_engine") as mock_engine, \
             patch("utils.connection.get_logger", return_value=MagicMock()):
            mock_engine.return_value = MagicMock()
            cm = reload_connection()
            engine = cm.get_postgres_engine()
            assert engine is mock_engine.return_value
            mock_engine.assert_called_once()

    def test_returns_cached_engine_on_subsequent_calls(
        self, mock_env: dict[str, str]
    ) -> None:
        with patch("sqlalchemy.create_engine") as mock_engine, \
             patch("utils.connection.get_logger", return_value=MagicMock()):
            mock_engine.return_value = MagicMock()
            cm = reload_connection()
            first = cm.get_postgres_engine()
            second = cm.get_postgres_engine()
            assert first is second
            assert mock_engine.call_count == 1

    def test_builds_correct_url(self, mock_env: dict[str, str]) -> None:
        with patch("sqlalchemy.create_engine") as mock_engine, \
             patch("utils.connection.get_logger", return_value=MagicMock()):
            mock_engine.return_value = MagicMock()
            cm = reload_connection()
            cm.get_postgres_engine()
            url = mock_engine.call_args.args[0]
            assert "postgresql+psycopg2" in str(url)
            assert url.username == "test_user"
            assert url.database == "test_warehouse"

    def test_connection_validated_with_test_query(
        self, mock_env: dict[str, str]
    ) -> None:
        mock_conn = MagicMock()
        mock_ctx = MagicMock()
        mock_ctx.__enter__ = MagicMock(return_value=mock_conn)
        mock_ctx.__exit__ = MagicMock(return_value=False)
        mock_engine = MagicMock()
        mock_engine.connect.return_value = mock_ctx
        with patch("sqlalchemy.create_engine", return_value=mock_engine), \
             patch("utils.connection.get_logger", return_value=MagicMock()):
            cm = reload_connection()
            cm.get_postgres_engine()
        mock_ctx.__enter__.assert_called_once()
        mock_ctx.__exit__.assert_called_once()


class TestGetMongoDb:
    def test_creates_mongo_client_on_first_call(
        self, mock_env: dict[str, str]
    ) -> None:
        with patch("pymongo.MongoClient") as mock_client, \
             patch("utils.connection.get_logger", return_value=MagicMock()):
            mock_client.return_value.admin.command.return_value = {"ok": 1}
            cm = reload_connection()
            db = cm.get_mongo_db()
            assert db is mock_client.return_value[mock_env["MONGO_DB"]]
            mock_client.assert_called_once_with(mock_env["MONGO_URI"])

    def test_returns_cached_mongo_client_on_subsequent_calls(
        self, mock_env: dict[str, str]
    ) -> None:
        with patch("pymongo.MongoClient") as mock_client, \
             patch("utils.connection.get_logger", return_value=MagicMock()):
            mock_client.return_value.admin.command.return_value = {"ok": 1}
            cm = reload_connection()
            first = cm.get_mongo_db()
            second = cm.get_mongo_db()
            assert first is second
            assert mock_client.call_count == 1

    def test_connection_ping_on_open(self, mock_env: dict[str, str]) -> None:
        with patch("pymongo.MongoClient") as mock_client, \
             patch("utils.connection.get_logger", return_value=MagicMock()):
            mock_client.return_value.admin.command.return_value = {"ok": 1}
            cm = reload_connection()
            cm.get_mongo_db()
            mock_client.return_value.admin.command.assert_called_with("ping")


class TestGetDatabricksConnection:
    @pytest.fixture
    def dbx_env(self, mock_env: dict[str, str], clean_env: pytest.MonkeyPatch) -> dict[str, str]:
        for k, v in {
            "DATABRICKS_HOST": "https://dbc-12345.cloud.databricks.com",
            "DATABRICKS_HTTP_PATH": "/sql/1.0/endpoints/abc123",
            "DATABRICKS_TOKEN": "dapixxx",
        }.items():
            clean_env.setenv(k, v)
            mock_env[k] = v
        return mock_env

    def test_creates_databricks_connection_on_first_call(
        self, dbx_env: dict[str, str]
    ) -> None:
        with patch("databricks.sql.connect") as mock_connect, \
             patch("utils.connection.get_logger", return_value=MagicMock()):
            mock_conn = MagicMock()
            mock_connect.return_value = mock_conn
            cm = reload_connection()
            conn = cm.get_databricks_connection()
            assert conn is mock_conn
            mock_connect.assert_called_once()

    def test_returns_cached_databricks_connection_on_subsequent_calls(
        self, dbx_env: dict[str, str]
    ) -> None:
        with patch("databricks.sql.connect") as mock_connect, \
             patch("utils.connection.get_logger", return_value=MagicMock()):
            mock_conn = MagicMock()
            mock_connect.return_value = mock_conn
            cm = reload_connection()
            first = cm.get_databricks_connection()
            second = cm.get_databricks_connection()
            assert first is second
            assert mock_connect.call_count == 1

    def test_missing_databricks_vars_raises_oserror(
        self, mock_env: dict[str, str]
    ) -> None:
        with patch("utils.connection.get_logger", return_value=MagicMock()):
            cm = reload_connection()
            with pytest.raises(
                OSError, match="Missing required environment variables"
            ):
                cm.get_databricks_connection()

    def test_includes_catalog_and_schema_when_set(
        self, dbx_env: dict[str, str], clean_env: pytest.MonkeyPatch
    ) -> None:
        for k, v in {
            "DATABRICKS_CATALOG": "main",
            "DATABRICKS_SCHEMA": "prod",
        }.items():
            clean_env.setenv(k, v)
        with patch("databricks.sql.connect") as mock_connect, \
             patch("utils.connection.get_logger", return_value=MagicMock()):
            mock_conn = MagicMock()
            mock_connect.return_value = mock_conn
            cm = reload_connection()
            cm.get_databricks_connection()
            connect_kwargs = mock_connect.call_args.kwargs
            assert connect_kwargs["catalog"] == "main"
            assert connect_kwargs["schema"] == "prod"
