module

public import Eggshell.Paths

@[expose] public section

namespace Eggshell.MiniLM

def model : String :=
  "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"

def runtimeVersion : String := "fastembed-0.8.0"

def embeddingSource : String := include_str "../runtime/embedding.py"

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
    provider := support / "embedding.py"
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
  IO.FS.writeFile paths.provider embeddingSource
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
    process python.toString #["-c", embeddingSource, model, paths.models.toString, "4", "--preload"]
    IO.FS.writeFile ready model

def command (root pluginData : System.FilePath) : IO (Option (List String)) := do
  let paths := layout root pluginData
  let some _ ← runtimePython? paths | pure none
  pure (some [(← IO.appPath).toString, "search-provider",
    "--cache", paths.vectors.toString,
    "--model-cache", paths.models.toString,
    "--model", model,
    "--top-k", "8",
    "--threshold", "0.38",
    "--trace", paths.trace.toString])

end Eggshell.MiniLM
