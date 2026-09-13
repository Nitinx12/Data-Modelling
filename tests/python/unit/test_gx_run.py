"""
tests/unit/test_gx_run.py
=========================
Tests for the pure helpers in scripts/python/gx_run.py — suite grouping,
runtime token resolution, fk_to parsing, and expectation preparation.  The
Great Expectations machinery itself is not imported here (it is lazy in the
script and slow to load); a fake expectation module stands in for it.
"""

from __future__ import annotations

import importlib.util
import sys
from datetime import date, datetime
from pathlib import Path
from types import SimpleNamespace
from typing import ClassVar
from unittest.mock import MagicMock

import pytest

_SCRIPT_PATH = Path(__file__).resolve().parents[3] / "scripts" / "python" / "gx_run.py"


def import_gx_run():
    """Import scripts/python/gx_run.py by path, under the mocked env."""
    spec = importlib.util.spec_from_file_location("gx_run", _SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["gx_run"] = module
    spec.loader.exec_module(module)
    return module


class FakeExpectation:
    """Stands in for a gxe expectation class — kwargs in, kwargs out.

    Mirrors the pydantic v1 style compat layer the real classes use: the
    accepted field names live in __fields__, not model_fields.
    """

    __fields__: ClassVar[dict[str, object]] = {
        "column": None,
        "mostly": None,
        "value_set": None,
        "value": None,
        "min_value": None,
        "max_value": None,
    }

    def __init__(self, **kwargs):
        self.kwargs = kwargs


@pytest.fixture
def fake_gxe():
    return SimpleNamespace(ExpectColumnValuesToNotBeNull=FakeExpectation)


class TestGroupExpectationsByTable:
    def test_groups_by_meta_schema(self, mock_env) -> None:
        gx_run = import_gx_run()
        expectations = [
            {
                "expectation_type": "expect_column_values_to_not_be_null",
                "kwargs": {"column": "a"},
                "meta": {"schema": "core.dim_campaign"},
            },
            {
                "expectation_type": "expect_column_values_to_not_be_null",
                "kwargs": {"column": "b"},
                "meta": {"schema": "core.fact_orders"},
            },
            {
                "expectation_type": "expect_column_values_to_not_be_null",
                "kwargs": {"column": "c"},
                "meta": {"schema": "core.fact_orders"},
            },
        ]
        groups, skipped = gx_run.group_expectations_by_table(expectations)
        assert groups == {
            ("core", "dim_campaign"): [expectations[0]],
            ("core", "fact_orders"): [expectations[1], expectations[2]],
        }
        assert skipped == []

    def test_expectation_without_meta_schema_is_skipped(self, mock_env) -> None:
        gx_run = import_gx_run()
        expectations = [
            {
                "expectation_type": "expect_column_values_to_not_be_null",
                "kwargs": {"column": "a"},
            },
        ]
        groups, skipped = gx_run.group_expectations_by_table(expectations)
        assert groups == {}
        assert len(skipped) == 1
        assert "no meta.schema" in skipped[0]


class TestResolveRuntimeTokens:
    def test_resolves_tokens_everywhere(self, mock_env) -> None:
        gx_run = import_gx_run()
        resolved = gx_run.resolve_runtime_tokens(
            {"value": "$today", "min_value": "$now", "other": "$today"}
        )
        assert isinstance(resolved["value"], date)
        assert isinstance(resolved["min_value"], datetime)
        assert resolved["other"] == resolved["value"]

    def test_leaves_plain_values_alone(self, mock_env) -> None:
        gx_run = import_gx_run()
        kwargs = {"column": "spend", "min_value": 0, "value_set": [1, 2]}
        assert gx_run.resolve_runtime_tokens(kwargs) == kwargs


class TestParseFkRef:
    def test_parses_schema_table_column(self, mock_env) -> None:
        gx_run = import_gx_run()
        assert gx_run.parse_fk_ref("core.dim_campaign(campaign_key)") == (
            "core",
            "dim_campaign",
            "campaign_key",
        )

    def test_rejects_malformed_reference(self, mock_env) -> None:
        gx_run = import_gx_run()
        with pytest.raises(gx_run.UnresolvableExpectation):
            gx_run.parse_fk_ref("core.dim_campaign")


class TestFetchFkValueSet:
    def _mock_engine(self, rows):
        engine = MagicMock()
        connection = MagicMock()
        connection.execute.return_value.fetchall.return_value = rows
        engine.connect.return_value.__enter__.return_value = connection
        return engine

    def test_fetches_distinct_keys(self, mock_env) -> None:
        gx_run = import_gx_run()
        engine = self._mock_engine([(1,), (2,), (3,)])
        values = gx_run.fetch_fk_value_set(engine, "core.dim_geo(geo_key)")
        assert values == [1, 2, 3]


class TestPrepareExpectation:
    def _entry(self, **kwargs_overrides):
        entry = {
            "expectation_type": "expect_column_values_to_not_be_null",
            "kwargs": {"column": "order_id", "mostly": 1.0},
            "meta": {"schema": "core.fact_orders"},
        }
        entry["kwargs"].update(kwargs_overrides)
        return entry

    def test_builds_expectation_and_drops_unknown_kwargs(
        self, mock_env, fake_gxe
    ) -> None:
        gx_run = import_gx_run()
        entry = self._entry(allow_null=True)
        expectation = gx_run.prepare_expectation(
            fake_gxe, entry, fetch_fk=lambda ref: pytest.fail("should not resolve")
        )
        assert expectation.kwargs == {"column": "order_id", "mostly": 1.0}

    def test_resolves_empty_value_set_from_fk_to(self, mock_env, fake_gxe) -> None:
        gx_run = import_gx_run()
        entry = self._entry(value_set=[])
        entry["meta"]["fk_to"] = "core.dim_geo(geo_key)"
        expectation = gx_run.prepare_expectation(
            fake_gxe, entry, fetch_fk=lambda ref: [7, 8]
        )
        assert expectation.kwargs["value_set"] == [7, 8]

    def test_empty_value_set_without_fk_to_is_unresolvable(
        self, mock_env, fake_gxe
    ) -> None:
        gx_run = import_gx_run()
        entry = self._entry(value_set=[])
        with pytest.raises(gx_run.UnresolvableExpectation):
            gx_run.prepare_expectation(fake_gxe, entry, fetch_fk=lambda ref: [])

    def test_unknown_expectation_type_is_unresolvable(self, mock_env, fake_gxe) -> None:
        gx_run = import_gx_run()
        entry = self._entry()
        entry["expectation_type"] = "expect_something_that_does_not_exist"
        with pytest.raises(gx_run.UnresolvableExpectation):
            gx_run.prepare_expectation(fake_gxe, entry, fetch_fk=lambda ref: [])


class TestLoadSuite:
    def test_reads_expectations_list(self, mock_env, tmp_path) -> None:
        gx_run = import_gx_run()
        suite_file = tmp_path / "demo_suite.yaml"
        suite_file.write_text(
            "expectations:\n"
            "  - expectation_type: expect_column_values_to_not_be_null\n"
            "    kwargs:\n"
            "      column: order_id\n"
            "    meta: { schema: core.fact_orders }\n",
            encoding="utf-8",
        )
        expectations = gx_run.load_suite(suite_file)
        assert expectations[0]["kwargs"]["column"] == "order_id"

    def test_empty_file_yields_empty_list(self, mock_env, tmp_path) -> None:
        gx_run = import_gx_run()
        suite_file = tmp_path / "empty_suite.yaml"
        suite_file.write_text("", encoding="utf-8")
        assert gx_run.load_suite(suite_file) == []
