module

public import Eggshell.SearchProvider

@[expose] public section

open Lean Eggshell

def main : IO UInt32 := do
  let root ← IO.FS.createTempDir
  let cases := (← IO.FS.readFile "tests/fixtures/search-golden.jsonl").splitOn "\n" |>.filter (!·.isEmpty)
  let binary ← IO.FS.realPath ".lake/build/bin/eggshell"
  let models := (MiniLM.layout (← Paths.installRoot) root).models
  try
    for mode in ["lexical", "semantic", "hybrid"] do
      let selected ← cases.filterMapM fun line => do
        let json ← IO.ofExcept (Json.parse line)
        pure (if json.getObjValD "mode" == .str mode then some json else none)
      let input := String.intercalate "\n" (selected.map (fun j => (j.getObjValD "request").compress)) ++ "\n"
      let result ← IO.Process.output {
        cmd := binary.toString
        args := #["search-provider", "--mode", mode, "--cache", (root / mode).toString,
          "--model-cache", models.toString]
        env := #[("HF_HUB_OFFLINE", some "1")] } (some input)
      if result.exitCode != 0 then throw (IO.userError result.stderr)
      let outputs := result.stdout.splitOn "\n" |>.filter (!·.isEmpty)
      if outputs.length != selected.length then throw (IO.userError "provider response count mismatch")
      for (output, test) in outputs.zip selected do
        let json ← IO.ofExcept (Json.parse output)
        if json != test.getObjValD "expected" then throw (IO.userError s!"{mode}: changed selected candidates: {output}")
      IO.println s!"{mode}: {selected.length} legacy-provider comparisons passed"
  finally IO.FS.removeDirAll root
  pure 0
