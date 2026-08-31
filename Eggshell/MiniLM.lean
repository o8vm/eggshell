module

public import Eggshell.Paths

@[expose] public section

namespace Eggshell.MiniLM

def model : String :=
  "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"

def runtimeVersion : String := "fastembed-0.8.0"

def providerSource : String := r#"import argparse
import json
import os
import sqlite3
import sys

import numpy as np
from fastembed import TextEmbedding


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", required=True)
    parser.add_argument("--model-cache", required=True)
    parser.add_argument("--model", default="sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2")
    parser.add_argument("--top-k", type=int, default=8)
    parser.add_argument("--threshold", type=float, default=0.38)
    parser.add_argument("--preload", action="store_true")
    return parser.parse_args()


def normalized(vector):
    value = np.asarray(vector, dtype=np.float32)
    norm = np.linalg.norm(value)
    return value if norm == 0 else value / norm


def main():
    options = arguments()
    os.makedirs(options.cache, exist_ok=True)
    os.makedirs(options.model_cache, exist_ok=True)
    database = sqlite3.connect(os.path.join(options.cache, "vectors.sqlite"))
    database.execute("create table if not exists vectors (id text primary key, vector blob not null)")
    encoder = TextEmbedding(
        model_name=options.model,
        cache_dir=options.model_cache,
        threads=max(1, min(4, os.cpu_count() or 1)),
    )

    def lookup(identifier):
        row = database.execute("select vector from vectors where id = ?", (identifier,)).fetchone()
        return None if row is None else np.frombuffer(row[0], dtype=np.float32)

    def store(items):
        missing = [item for item in items if lookup(item["id"]) is None]
        if not missing:
            return
        vectors = encoder.embed([item["text"] for item in missing], batch_size=32)
        database.executemany(
            "insert or replace into vectors(id, vector) values (?, ?)",
            ((item["id"], normalized(vector).tobytes()) for item, vector in zip(missing, vectors)),
        )
        database.commit()

    if options.preload:
        next(encoder.embed(["eggshell"], batch_size=1))
        return

    for raw in sys.stdin:
        try:
            request = json.loads(raw)
            if "index" in request:
                store(request["index"])
                continue
            store(request.get("candidates", []))
            store([request["query"]])
            query = lookup(request["query"]["id"])
            scored = []
            for index, candidate in enumerate(request.get("candidates", [])):
                vector = lookup(candidate["id"])
                if vector is not None and vector.shape == query.shape:
                    score = float(np.dot(query, vector))
                    if score >= options.threshold:
                        scored.append((score, index))
            scored.sort(reverse=True)
            print(json.dumps({"related": [index for _, index in scored[:options.top_k]]}), flush=True)
        except Exception:
            print(json.dumps({"related": []}), flush=True)


if __name__ == "__main__":
    main()
"#

structure Layout where
  support : System.FilePath
  runtime : System.FilePath
  provider : System.FilePath
  models : System.FilePath
  vectors : System.FilePath

def supportRoot (root : System.FilePath) : System.FilePath :=
  root / "share" / "eggshell" / "minilm"

def layout (root pluginData : System.FilePath) : Layout :=
  let support := supportRoot root
  {
    support
    runtime := support / runtimeVersion
    provider := support / "provider.py"
    models := support / "models"
    vectors := pluginData / "semantic" / "minilm"
  }

def unixPython (layout : Layout) : System.FilePath :=
  layout.runtime / "bin" / "python"

def windowsPython (layout : Layout) : System.FilePath :=
  layout.runtime / "Scripts" / "python.exe"

def runtimePython? (layout : Layout) : IO (Option System.FilePath) := do
  let unix := unixPython layout
  if ← unix.pathExists then pure (some unix)
  else
    let windows := windowsPython layout
    if ← windows.pathExists then pure (some windows) else pure none

def process (command : String) (arguments : Array String) : IO Unit := do
  let output ← IO.Process.output { cmd := command, args := arguments }
  if output.exitCode != 0 then
    throw (IO.userError (if output.stderr.trimAscii.isEmpty then output.stdout
      else output.stderr))

def available (command : String) : IO Bool := do
  try
    let output ← IO.Process.output { cmd := command, args := #["--version"] }
    pure (output.exitCode == 0)
  catch _ => pure false

def systemPython : IO String := do
  if ← available "python3" then pure "python3"
  else if ← available "python" then pure "python"
  else throw (IO.userError
    "Python 3 is required once to install the default CPU MiniLM provider")

def install (root : System.FilePath) : IO Unit := do
  let support := supportRoot root
  let paths := layout root (support / "preload")
  IO.FS.createDirAll paths.support
  IO.FS.writeFile paths.provider providerSource
  let python ← match ← runtimePython? paths with
    | some python => pure python
    | none => do
        let host ← systemPython
        try
          process host #["-m", "venv", paths.runtime.toString]
          let some python ← runtimePython? paths |
            throw (IO.userError "Python venv did not create its interpreter")
          process python.toString #["-m", "pip", "install",
            "--disable-pip-version-check", "fastembed==0.8.0"]
          pure python
        catch error =>
          if ← paths.runtime.pathExists then IO.FS.removeDirAll paths.runtime
          throw error
  let ready := paths.support / s!"{runtimeVersion}.model-ready"
  if !(← ready.pathExists) then
    process python.toString #[paths.provider.toString,
      "--cache", paths.vectors.toString,
      "--model-cache", paths.models.toString,
      "--model", model,
      "--preload"]
    IO.FS.writeFile ready model

def command (root pluginData : System.FilePath) : IO (Option (List String)) := do
  let paths := layout root pluginData
  let some python ← runtimePython? paths | pure none
  if !(← paths.provider.pathExists) then pure none
  else pure (some [python.toString, paths.provider.toString,
    "--cache", paths.vectors.toString,
    "--model-cache", paths.models.toString,
    "--model", model,
    "--top-k", "8",
    "--threshold", "0.38"])

end Eggshell.MiniLM
