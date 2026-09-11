"""Baseline tests for the sample client, using only the Python standard library."""

import unittest
from pathlib import Path

from retry_plan import build_plan, load_settings


SETTINGS = Path(__file__).with_name("settings.json")


class RetryPlanTests(unittest.TestCase):
    def test_defaults_without_a_config_file(self):
        self.assertEqual(load_settings(environ={}),
                         {"timeout_seconds": 10, "max_attempts": 3})

    def test_file_overrides_defaults(self):
        self.assertEqual(load_settings(SETTINGS, {}),
                         {"timeout_seconds": 8, "max_attempts": 2})

    def test_environment_overrides_file_timeout(self):
        settings = load_settings(SETTINGS, {"RETRY_TIMEOUT_SECONDS": "12"})
        self.assertEqual(settings["timeout_seconds"], 12)
        self.assertEqual(settings["max_attempts"], 2)

    def test_cli_overrides_environment_and_file(self):
        plan = build_plan(["--timeout", "5", "--attempts", "4"],
                          {"RETRY_TIMEOUT_SECONDS": "12"})
        self.assertEqual(plan, {"timeout_seconds": 5, "max_attempts": 4,
                               "maximum_wait_seconds": 20})

    def test_invalid_final_values_are_rejected(self):
        for flag in ["--timeout", "--attempts"]:
            with self.subTest(flag=flag):
                with self.assertRaises(ValueError):
                    build_plan([flag, "0"], {})


if __name__ == "__main__":
    unittest.main()
