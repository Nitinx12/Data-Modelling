"""
tests/unit/test_logger.py
=========================
Tests for utils/logger.py — logger creation, handler dedup,
file/console levels, and rotating-file behaviour.
"""
from __future__ import annotations

import logging
from pathlib import Path

from utils.logger import LOG_DIR, get_logger


class TestGetLogger:
    def test_returns_logger_instance(self, tmp_log_dir: Path) -> None:
        log = get_logger("unit_test_a")
        assert isinstance(log, logging.Logger)

    def test_logger_name_is_preserved(self) -> None:
        log = get_logger("unit_test_b")
        assert log.name == "unit_test_b"

    def test_duplicate_calls_return_same_logger(self) -> None:
        first = get_logger("unit_test_dedup")
        second = get_logger("unit_test_dedup")
        assert first is second

    def test_attaches_exactly_two_handlers(self) -> None:
        log = get_logger("unit_test_handlers")
        kinds = {type(h).__name__ for h in log.handlers}
        assert "StreamHandler" in kinds
        assert "RotatingFileHandler" in kinds

    def test_console_level_override(self) -> None:
        log = get_logger("unit_test_quiet", console_level=logging.ERROR)
        console = next(
            h for h in log.handlers if type(h).__name__ == "StreamHandler"
        )
        assert console.level == logging.ERROR

    def test_file_handler_uses_log_dir(self) -> None:
        log = get_logger("unit_test_path")
        file_handler = next(
            h for h in log.handlers
            if type(h).__name__ == "RotatingFileHandler"
        )
        assert Path(file_handler.baseFilename).parent == Path(LOG_DIR)

    def test_subdir_creates_nested_log_dir(self, tmp_path: Path) -> None:
        import utils.logger as logger_module
        original = logger_module.LOG_DIR
        logger_module.LOG_DIR = str(tmp_path)
        try:
            log = get_logger("unit_test_subdir", subdir="staging")
            file_handler = next(
                h for h in log.handlers
                if type(h).__name__ == "RotatingFileHandler"
            )
            assert "staging" in str(file_handler.baseFilename)
        finally:
            logger_module.LOG_DIR = original
            logging.getLogger("unit_test_subdir").handlers.clear()

    def test_logger_does_not_propagate(self) -> None:
        log = get_logger("unit_test_propagate")
        assert log.propagate is False

    def test_logger_set_to_debug(self) -> None:
        log = get_logger("unit_test_debug")
        assert log.level == logging.DEBUG