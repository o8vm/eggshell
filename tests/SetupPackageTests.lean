module

public import Eggshell.Setup
public import Eggshell.Sha256

@[expose] public section

open Lean Eggshell

def ensure (value : Bool) (message : String) : IO Unit := unless value do throw (IO.userError message)

def bootstrapTests (repository temporary : System.FilePath) : IO Unit := do
  let fixture := temporary / "bootstrap"
  let runtime := fixture / "prefix"
  let bin := fixture / "bin"
  let archive := fixture / "source.tar.gz"
  IO.FS.createDirAll (fixture / "scripts")
  IO.FS.createDirAll (fixture / "runtime-pins")
  IO.FS.createDirAll bin
  IO.FS.writeFile (fixture / "scripts/setup.sh") (← IO.FS.readFile (repository / "plugins/eggshell/scripts/setup.sh"))
  -- This native test executable stands in for curl; the bootstrap still runs
  -- its real checksum, archive inspection and installation path, offline.
  IO.FS.writeBinFile (bin / "curl") (← IO.FS.readBinFile (← IO.appPath))
  IO.setAccessRights (bin / "curl") { user := { read := true, write := true, execution := true } }
  let platform := if System.Platform.isOSX then "macos" else "linux"
  let machine := (← IO.Process.run { cmd := "uname", args := #["-m"] }).trimAscii.toString
  let arch := if machine == "arm64" || machine == "aarch64" then "aarch64" else "x86_64"
  let pin := fixture / "runtime-pins" / (platform ++ "-" ++ arch)
  let env := #[("PATH", some (bin.toString ++ ":" ++ (← IO.getEnv "PATH").getD "")),
    ("EGGSHELL_TEST_ARCHIVE", some archive.toString), ("EGGSHELL_PREFIX", some runtime.toString),
    ("EGGSHELL_DATA_ROOT", some (fixture / "data").toString), ("PLUGIN_ROOT", none),
    ("EGGSHELL_CONFIG", none), ("CODEX_THREAD_ID", none)]
  let run := IO.Process.output { cmd := "sh", args := #[(fixture / "scripts/setup.sh").toString,
    "--project", fixture.toString], env }
  let stage := fixture / "stage"
  IO.FS.createDirAll stage
  IO.FS.writeFile (stage / "eggshell") "must never execute"
  let _ ← IO.Process.run { cmd := "tar", args := #["-czf", archive.toString, "-C", stage.toString, "eggshell"] }
  IO.FS.writeFile pin ("v0.1.0\neggshell.tar.gz\n" ++ String.ofList (List.replicate 64 '0') ++ "\n")
  let rejected ← run
  ensure (rejected.exitCode != 0 && rejected.stderr.contains "checksum mismatch" && !(← runtime.pathExists))
    "bootstrap installed a checksum-mismatched archive"
  IO.FS.removeFile (stage / "eggshell")
  let _ ← IO.Process.run { cmd := "ln", args := #["-s", "/unrelated-eggshell", (stage / "eggshell").toString] }
  let _ ← IO.Process.run { cmd := "tar", args := #["-czf", archive.toString, "-C", stage.toString, "eggshell"] }
  IO.FS.writeFile pin ("v0.1.0\neggshell.tar.gz\n" ++ Sha256.hex (← IO.FS.readBinFile archive) ++ "\n")
  let rejected ← run
  ensure (rejected.exitCode != 0 && rejected.stderr.contains "regular file" && !(← runtime.pathExists))
    "bootstrap accepted a symlink runtime"
  IO.println "Bootstrap: checksum and non-regular archive rejection passed without a network request"

def installationTests (executable temporary : System.FilePath) : IO Unit := do
  let installRoot := temporary / "runtime prefix's"
  let support := MiniLM.supportRoot installRoot
  let numerical := support / MiniLM.runtimeVersion / "bin/python"
  IO.FS.createDirAll numerical.parent.get!
  IO.FS.writeFile numerical "unused numerical fixture"
  IO.FS.writeFile (support / (MiniLM.runtimeVersion ++ ".model-ready")) MiniLM.model
  let plugin := installRoot / "plugins/eggshell"
  IO.FS.createDirAll plugin
  IO.FS.writeFile (plugin / ".eggshell-owner") "o8vm/eggshell\n"
  IO.FS.writeFile (plugin / "sentinel") "existing plugin"
  IO.FS.writeFile (installRoot / "work.egg") "user-owned work"
  let marketplace := installRoot / ".agents/plugins/marketplace.json"
  IO.FS.createDirAll marketplace.parent.get!
  IO.FS.writeFile marketplace "{\"keep\":\"unchanged\"}\n"
  let env := #[("EGGSHELL_PREFIX", some installRoot.toString), ("EGGSHELL_DATA_ROOT", some (installRoot / "data").toString),
    ("PLUGIN_ROOT", none), ("CODEX_THREAD_ID", none), ("EGGSHELL_CONFIG", none)]
  let result ← IO.Process.output { cmd := executable.toString, args := #["install", "runtime"], env }
  ensure (result.exitCode == 0) result.stderr
  ensure ((← IO.FS.readFile (plugin / "sentinel")) == "existing plugin" &&
    (← IO.FS.readFile (installRoot / "work.egg")) == "user-owned work" &&
    (← IO.FS.readFile marketplace) == "{\"keep\":\"unchanged\"}\n") "runtime install changed plugin or memory"
  let project := installRoot / "project"
  IO.FS.createDirAll project
  let initialized ← IO.Process.output { cmd := (installRoot / "bin/egg").toString, args := #["init"], env, cwd := some project }
  ensure (initialized.exitCode == 0 && (← (project / ".eggshell.toml").pathExists)) "installed launcher failed"
  IO.println "Runtime installation: plugin, marketplace and memory preserved; installed launcher passed"

def runTests : IO UInt32 := do
  let repository ← IO.currentDir
  let executable ← IO.FS.realPath ".lake/build/bin/eggshell"
  let package ← IO.FS.realPath ".lake/build/bin/eggshell_package"
  let temporary ← IO.FS.createTempDir
  let temporary ← IO.FS.realPath temporary
  let environment := #[("EGGSHELL_PREFIX", some (temporary / "runtime").toString),
    ("EGGSHELL_DATA_ROOT", some (temporary / "data").toString), ("EGGSHELL_CONFIG", none),
    ("CODEX_THREAD_ID", none), ("PLUGIN_ROOT", none)]
  try
    bootstrapTests repository temporary
    installationTests executable temporary
    let project := temporary / "project"
    IO.FS.createDirAll project
    let run (checkOnly : Bool) := IO.Process.output {
      cmd := executable.toString
      args := #["setup", "--project", project.toString] ++ if checkOnly then #["--check"] else #[]
      env := environment }
    let missing ← run true
    ensure (missing.exitCode == 1) "missing configuration not reported"
    ensure (!(← (project / ".eggshell.toml").pathExists)) "check initialized a project"
    let ready ← run false
    ensure (ready.exitCode == 0) ready.stderr
    let original ← IO.FS.readFile (project / ".eggshell.toml")
    let again ← run false
    ensure (again.exitCode == 0 && (← IO.FS.readFile (project / ".eggshell.toml")) == original) "existing config overwritten"
    IO.FS.writeFile (project / ".eggshell.toml") "invalid configuration retained"
    let invalid ← run false
    ensure (invalid.exitCode != 0 && (← IO.FS.readFile (project / ".eggshell.toml")) == "invalid configuration retained") "invalid config replaced"
    IO.FS.removeFile (project / ".eggshell.toml")
    IO.FS.writeFile (temporary / ".eggshell.toml") original
    let inherited ← run false
    ensure (inherited.exitCode == 0 && !(← (project / ".eggshell.toml").pathExists)) "parent config shadowed"
    let shell ← IO.Process.output {
      cmd := "sh"
      args := #[(repository / "plugins/eggshell/scripts/setup.sh").toString, "--check", "--project", project.toString]
      env := environment }
    ensure (shell.exitCode == 1 && !(← (temporary / "runtime").pathExists)) "bootstrap check modified installation"
    IO.println "Native setup: missing, existing, invalid and parent configuration checks passed"
    let runtimes := temporary / "runtimes"
    let staged := temporary / "staged"
    let output := temporary / "package"
    IO.FS.createDirAll runtimes
    IO.FS.createDirAll staged
    IO.FS.writeFile (staged / "eggshell") "fixture-executable"
    for target in ["linux-aarch64", "linux-x86_64", "macos-aarch64", "macos-x86_64"] do
      let _ ← IO.Process.run { cmd := "tar", args := #["-czf", (runtimes / ("eggshell-" ++ target ++ ".tar.gz")).toString,
        "-C", staged.toString, "eggshell"] }
    let result ← IO.Process.output {
      cmd := package.toString
      args := #["--runtime-dir", runtimes.toString, "--output", output.toString, "--release", "v0.1.0"] }
    ensure (result.exitCode == 0) result.stderr
    let archive := output / "eggshell-codex-plugin.zip"
    let checked ← IO.Process.output { cmd := "unzip", args := #["-t", archive.toString] }
    ensure (checked.exitCode == 0) checked.stdout
    let names ← IO.Process.run { cmd := "unzip", args := #["-Z1", archive.toString] }
    ensure ((names.splitOn "runtime-pins/").length == 5) "missing pinned runtime bootstrap inputs"
    let pin ← IO.Process.run { cmd := "unzip", args := #["-p", archive.toString, "runtime-pins/macos-aarch64"] }
    let checksum := Sha256.hex (← IO.FS.readBinFile (runtimes / "eggshell-macos-aarch64.tar.gz"))
    ensure ((pin.splitOn checksum).length > 1) "incorrect runtime checksum"
    let first ← IO.FS.readBinFile archive
    let repeated ← IO.Process.output {
      cmd := package.toString
      args := #["--runtime-dir", runtimes.toString, "--output", output.toString, "--release", "v0.1.0"] }
    ensure (repeated.exitCode == 0 && (← IO.FS.readBinFile archive) == first) "package is not reproducible"
    IO.println "Native package: independent ZIP reader, four runtime checksums and reproducibility passed"
  finally IO.FS.removeDirAll temporary
  pure 0

def main (args : List String) : IO UInt32 := do
  if args.head? == some "--proto" then
    let rec destination : List String → Option String
      | "--output" :: path :: _ => some path
      | _ :: rest => destination rest
      | [] => none
    let some output := destination args | throw (IO.userError "test curl missing output")
    let some source ← IO.getEnv "EGGSHELL_TEST_ARCHIVE" | throw (IO.userError "test curl missing archive")
    IO.FS.writeBinFile (.mk output) (← IO.FS.readBinFile (.mk source))
    pure 0
  else runTests
