module

public import Eggshell.Paths

@[expose] public section

namespace Eggshell.MiniLM

def model : String :=
  "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"

def runtimeVersion : String := "fastembed-0.8.0"

def providerSource : String := r#"import argparse
import hashlib
import json
import math
import os
import re
import sqlite3
import sys
from collections import Counter

import numpy as np
from fastembed import TextEmbedding


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", required=True)
    parser.add_argument("--model-cache", required=True)
    parser.add_argument("--model", default="sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2")
    parser.add_argument("--top-k", type=int, default=8)
    parser.add_argument("--threshold", type=float, default=0.38)
    parser.add_argument("--mode", choices=["semantic", "lexical", "hybrid"], default="hybrid")
    parser.add_argument("--anchor-k", type=int, default=2)
    parser.add_argument("--trace")
    parser.add_argument("--preload", action="store_true")
    return parser.parse_args()


def normalized(vector):
    value = np.asarray(vector, dtype=np.float32)
    norm = np.linalg.norm(value)
    return value if norm == 0 else value / norm


def windows(text):
    # Bound encoder input, not the authoritative Outcome returned to the kernel.
    return [text[start:start + 512] for start in range(0, max(1, len(text)), 384)]


def terms(text):
    return re.findall(r"[a-z0-9_./:-]+|[\u3040-\u30ff\u3400-\u9fff]", text.casefold())


def lexical_ranking(query, candidates):
    wanted = set(terms(query))
    documents = [set(terms(item["text"])) for item in candidates]
    counts = Counter(term for document in documents for term in document)
    scores = [(sum(math.log1p(len(documents) / counts[term])
                   for term in wanted & document), index)
              for index, document in enumerate(documents)]
    return [index for score, index in sorted(scores, key=lambda pair: (-pair[0], pair[1])) if score > 0]


def lexical_anchor_ranking(query, candidates):
    # Preserve exact identifiers and paths in the final hybrid ranking.
    wanted = {term for term in terms(query)
              if "_" in term or "/" in term or ":" in term or "." in term
              or any(character.isdigit() for character in term)}
    documents = [set(terms(item["text"])) for item in candidates]
    counts = Counter(term for document in documents for term in document)
    scores = [(sum(math.log1p(len(documents) / counts[term])
                   for term in wanted & document), index)
              for index, document in enumerate(documents)]
    return [index for score, index in sorted(scores, key=lambda pair: (-pair[0], pair[1])) if score > 0]


def fuse(rankings, limit):
    scores = Counter()
    for ranking in rankings:
        for rank, index in enumerate(ranking):
            scores[index] += 1 / (60 + rank + 1)
    return sorted(scores, key=lambda index: (-scores[index], index))[:limit]


def anchor_first(anchors, ranking, limit):
    selected = []
    for index in anchors + ranking:
        if index not in selected:
            selected.append(index)
        if len(selected) == limit:
            break
    return selected


def main():
    options = arguments()
    os.makedirs(options.cache, exist_ok=True)
    os.makedirs(options.model_cache, exist_ok=True)
    database = sqlite3.connect(os.path.join(options.cache, "window-vectors-v2.sqlite"))
    database.execute("create table if not exists vectors (id text primary key, vector blob not null)")
    encoder = None if options.mode == "lexical" else TextEmbedding(
        model_name=options.model,
        cache_dir=options.model_cache,
        threads=max(1, min(4, os.cpu_count() or 1)),
    )
    def write_trace(record):
        if not options.trace:
            return
        try:
            parent = os.path.dirname(options.trace)
            if parent:
                os.makedirs(parent, exist_ok=True)
            with open(options.trace, "a", encoding="utf-8") as output:
                output.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
        except Exception as error:
            print("trace error: " + str(error), file=sys.stderr, flush=True)

    def key(text):
        return hashlib.sha256((options.model + "\0" + text).encode()).hexdigest()

    def lookup(identifier):
        row = database.execute("select vector from vectors where id = ?", (identifier,)).fetchone()
        return None if row is None else np.frombuffer(row[0], dtype=np.float32)

    def store(items):
        texts = list(dict.fromkeys(part for item in items for part in windows(item["text"])))
        missing = [text for text in texts if lookup(key(text)) is None]
        if not missing:
            return
        vectors = encoder.embed(missing, batch_size=32)
        database.executemany(
            "insert or replace into vectors(id, vector) values (?, ?)",
            ((key(text), normalized(vector).tobytes()) for text, vector in zip(missing, vectors)),
        )
        database.commit()

    if options.preload:
        if encoder is not None:
            next(encoder.embed(["eggshell"], batch_size=1))
        return

    for raw in sys.stdin:
        try:
            request = json.loads(raw)
            if "index" in request:
                if encoder is not None:
                    store(request["index"])
                continue
            candidates = request.get("candidates", [])
            lexical = lexical_ranking(request["query"]["text"], candidates)
            anchors = lexical_anchor_ranking(request["query"]["text"], candidates)
            scored = []
            if encoder is not None:
                store(candidates + [request["query"]])
                queries = [lookup(key(part)) for part in windows(request["query"]["text"])]
                for index, candidate in enumerate(candidates):
                    vectors = [lookup(key(part)) for part in windows(candidate["text"])]
                    score = max(float(np.dot(query, vector)) for query in queries for vector in vectors)
                    scored.append((score, index))
            semantic_all = [index for _, index in sorted(scored, key=lambda pair: (-pair[0], pair[1]))]
            semantic = [index for score, index in sorted(scored, key=lambda pair: (-pair[0], pair[1]))
                        if score >= options.threshold]
            hybrid_base = fuse([lexical, semantic], options.top_k)
            base = (hybrid_base if options.mode == "hybrid"
                    else (lexical if options.mode == "lexical" else semantic))
            ranking = anchor_first(anchors[:options.anchor_k], base, options.top_k)
            write_trace({
                "mode": options.mode,
                "candidate_count": len(candidates),
                "candidate_ids": [item.get("id", "") for item in candidates],
                "lexical_rank": lexical,
                "anchor_rank": anchors,
                "semantic_rank": semantic_all,
                "semantic_threshold_rank": semantic,
                "hybrid_rank": hybrid_base,
                "selected": ranking,
            })
            # Keep the provider wire response stable; diagnostics live in the trace sidecar.
            print(json.dumps({"related": ranking}), flush=True)
        except Exception as error:
            print(str(error), file=sys.stderr, flush=True)
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
  trace : System.FilePath

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
    trace := pluginData / "semantic" / "matcher-trace.jsonl"
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
    "--threshold", "0.38",
    "--trace", paths.trace.toString])

end Eggshell.MiniLM
