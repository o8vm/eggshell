"""Run the shipped provider, including real local MiniLM (no generative calls).

Use the installed MiniLM Python environment to run this file.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class SearchProviderTest(unittest.TestCase):
    def test_exact_symbols_and_long_outcomes_survive_indexing(self):
        source = (Path(__file__).resolve().parents[1] / "Eggshell/MiniLM.lean").read_text()
        code = source.split('def providerSource : String := r#"', 1)[1].split('"#', 1)[0]
        models = os.environ.get("EGGSHELL_TEST_MODELS", str(
            Path.home() / ".local/share/eggshell/minilm/models"))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            provider = root / "provider.py"
            provider.write_text(code)
            candidates = [
                {"id": "first", "text": "Network driver documentation and packet routing."},
                {"id": "second", "text": "Historical notes. " * 100 +
                 "\nCONFIG_ARCHIVE_SENTINEL_7E29 requires CONFIG_STORAGE_BRIDGE."},
            ]
            query = {"id": "query", "text": "CONFIG_ARCHIVE_SENTINEL_7E29"}
            request = {"query": query, "candidates": candidates}
            modes = ["lexical", "semantic", "hybrid"]
            for mode in modes:
                trace = root / (mode + ".jsonl")
                command = [
                    sys.executable, str(provider), "--cache", str(root / "cache"),
                    "--model-cache", models, "--mode", mode, "--top-k", "1",
                    "--threshold", "0", "--trace", str(trace), "--anchor-k", "1",
                ]
                result = subprocess.run(command, input=json.dumps(request) + "\n", text=True, capture_output=True,
                    check=True, timeout=60, env={**os.environ, "HF_HUB_OFFLINE": "1"})
                self.assertEqual(json.loads(result.stdout)["related"], [1], result.stderr)
                records = [json.loads(line) for line in trace.read_text().splitlines()]
                self.assertEqual(len(records), 1)
                self.assertEqual(records[0]["candidate_count"], 2)
                self.assertEqual(records[0]["selected"], [1])
                self.assertEqual(records[0]["anchor_rank"], [1])
                self.assertEqual(records[0]["mode"], mode)

            # Caller IDs are not cache authority: changed bytes must be reindexed.
            changed = {"query": query, "candidates": [
                {"id": "first", "text": candidates[1]["text"]},
                {"id": "second", "text": candidates[0]["text"]},
            ]}
            result = subprocess.run([
                sys.executable, str(provider), "--cache", str(root / "cache"),
                "--model-cache", models, "--mode", "semantic", "--top-k", "1",
                "--threshold", "0",
            ], input=json.dumps(changed) + "\n", text=True, capture_output=True,
                check=True, timeout=60, env={**os.environ, "HF_HUB_OFFLINE": "1"})
            self.assertEqual(json.loads(result.stdout)["related"], [0], result.stderr)


if __name__ == "__main__":
    unittest.main()
