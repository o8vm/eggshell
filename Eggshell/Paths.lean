module

@[expose] public section

namespace Eggshell.Paths

def absoluteEnvironment (name : String) : IO (Option System.FilePath) := do
  let some raw ← IO.getEnv name | pure none
  if raw.trimAscii.isEmpty then pure none
  else
    let path := System.FilePath.mk raw
    if !path.isAbsolute then
      throw (IO.userError s!"{name} must be an absolute path")
    pure (some path.normalize)

def home : IO System.FilePath := do
  match ← absoluteEnvironment "HOME" with
  | some home => pure home
  | none => throw (IO.userError "EGGSHELL_PREFIX and HOME are unavailable")

/-- Root of the relocatable Eggshell installation, independent of `CODEX_HOME`. -/
def installRoot : IO System.FilePath := do
  match ← absoluteEnvironment "EGGSHELL_PREFIX" with
  | some root => pure root
  | none => pure ((← home) / ".local")

def dataRoot : IO System.FilePath := do
  match ← absoluteEnvironment "EGGSHELL_DATA_ROOT" with
  | some root => pure root
  | none => pure ((← installRoot) / "share" / "eggshell" / "plugin")

def globalConfig : IO System.FilePath := do
  pure ((← installRoot) / "config" / "eggshell" / "config.toml")

end Eggshell.Paths
