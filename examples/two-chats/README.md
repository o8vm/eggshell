# Two-chat sample

An offline Python client that prints a retry plan. No network access, API key,
or extra Python package is needed to run the sample itself. Eggshell and your
normal Codex setup are required for the memory exercise.

**[Follow the two-chat exercise](../../docs/try-it.md)** for setup, the two task
prompts, and how to check whether relevant prior work actually reached chat 2.

Run the sample and its baseline tests from this directory:

```sh
python3 retry_plan.py
python3 -m unittest -v
```

Expected initial output:

```json
{"max_attempts": 2, "maximum_wait_seconds": 16, "timeout_seconds": 8}
```

Chat 1 investigates configuration and runs the baseline tests. Chat 2 adds a
small related feature. The second task is intentionally left for the person
trying Eggshell; the starting sample does not include its solution.

This sample checks the cross-chat workflow. Its size and token counts are not
a substitute for the separate published LLVM experiment.
