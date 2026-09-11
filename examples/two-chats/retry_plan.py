"""A tiny offline client configuration example for Eggshell's two-chat exercise.

The program prints a retry plan. It never sends requests or sleeps.
"""

import argparse
import json
import os
from pathlib import Path


DEFAULTS = {"timeout_seconds": 10, "max_attempts": 3}


def load_settings(path=None, environ=None):
    settings = dict(DEFAULTS)
    if path is not None:
        with open(path, encoding="utf-8") as source:
            settings.update(json.load(source))
    env = os.environ if environ is None else environ
    if "RETRY_TIMEOUT_SECONDS" in env:
        settings["timeout_seconds"] = int(env["RETRY_TIMEOUT_SECONDS"])
    return settings


def build_plan(argv=None, environ=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path,
                        default=Path(__file__).with_name("settings.json"))
    parser.add_argument("--timeout", type=int)
    parser.add_argument("--attempts", type=int)
    args = parser.parse_args(argv)
    settings = load_settings(args.config, environ)
    if args.timeout is not None:
        settings["timeout_seconds"] = args.timeout
    if args.attempts is not None:
        settings["max_attempts"] = args.attempts
    for key in DEFAULTS:
        value = settings[key]
        if type(value) is not int or value <= 0:
            raise ValueError(f"{key} must be a positive integer")
    return {
        "timeout_seconds": settings["timeout_seconds"],
        "max_attempts": settings["max_attempts"],
        "maximum_wait_seconds": settings["timeout_seconds"] * settings["max_attempts"],
    }


if __name__ == "__main__":
    print(json.dumps(build_plan(), sort_keys=True))
