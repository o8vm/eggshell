module

public import Eggshell.Sha256
public import Eggshell.Persistence
public import Lean

@[expose] public section

namespace Eggshell.Package
open Lean

def targets : List String := ["linux-aarch64", "linux-x86_64", "macos-aarch64", "macos-x86_64"]

def little (n bytes : Nat) : ByteArray := ByteArray.mk
  ((List.range bytes).map (fun i => ((n >>> (8*i)) % 256).toUInt8)).toArray

def crc32 (bytes : ByteArray) : UInt32 := Id.run do
  let mut crc : UInt32 := 0xffffffff
  for byte in bytes do
    crc := crc ^^^ byte.toUInt32
    for _ in [0:8] do crc := if crc &&& 1 == 1 then (crc >>> 1) ^^^ 0xedb88320 else crc >>> 1
  return crc ^^^ 0xffffffff

structure Entry where
  name : String
  bytes : ByteArray
  executable : Bool := false

/-- Stored ZIP entries avoid a second compression runtime. Archives use stable
    order, timestamps and Unix permissions; TAR runtime assets stay compressed. -/
def zip (entries : List Entry) : ByteArray := Id.run do
  let mut output := ByteArray.empty
  let mut directory := ByteArray.empty
  for entry in entries do
    let name := entry.name.toUTF8
    let size := entry.bytes.size
    let checksum := (crc32 entry.bytes).toNat
    let offset := output.size
    output := output ++ little 0x04034b50 4 ++ little 20 2 ++ little 0x800 2 ++
      little 0 2 ++ little 0 2 ++ little 23585 2 ++ little checksum 4 ++
      little size 4 ++ little size 4 ++ little name.size 2 ++ little 0 2 ++ name ++ entry.bytes
    directory := directory ++ little 0x02014b50 4 ++ little 0x314 2 ++ little 20 2 ++ little 0x800 2 ++
      little 0 2 ++ little 0 2 ++ little 23585 2 ++ little checksum 4 ++ little size 4 ++ little size 4 ++
      little name.size 2 ++ little 0 2 ++ little 0 2 ++ little 0 2 ++ little 0 2 ++
      little ((if entry.executable then 0o100755 else 0o100644) * 65536) 4 ++ little offset 4 ++ name
  let tail := little 0x06054b50 4 ++ little 0 2 ++ little 0 2 ++ little entries.length 2 ++
    little entries.length 2 ++ little directory.size 4 ++ little output.size 4 ++ little 0 2
  return output ++ directory ++ tail

partial def collect (root : System.FilePath) (relative := "") : IO (List Entry) := do
  let mut entries := []
  for entry in (← (root / relative).readDir).toList.mergeSort (fun a b => a.fileName ≤ b.fileName) do
    if entry.fileName == "__pycache__" || entry.fileName.endsWith ".pyc" then continue
    let path := if relative.isEmpty then entry.fileName else relative ++ "/" ++ entry.fileName
    let metadata ← entry.path.symlinkMetadata
    match metadata.type with
    | .dir => entries := entries ++ (← collect root path)
    | .file => entries := entries ++ [⟨path, ← IO.FS.readBinFile entry.path, relative == "bin"⟩]
    | _ => throw (IO.userError s!"non-regular package entry: {entry.path}")
  return entries

def safeName (name : String) : Bool := !name.isEmpty && name.toList.all fun c =>
  c.isAlphanum || "-_.".contains c

def build (root runtimeDir output : System.FilePath) (release : String) : IO Unit := do
  if !safeName release then throw (IO.userError "invalid release name")
  let manifest ← IO.ofExcept (Json.parse (← IO.FS.readFile (root / "plugins/eggshell/.codex-plugin/plugin.json")))
  let version ← IO.ofExcept (manifest.getObjValAs? String "version")
  if release != "v" ++ version then throw (IO.userError "release must match plugin version")
  IO.FS.createDirAll output
  let source := (← IO.Process.run { cmd := "git", args := #["rev-parse", "HEAD"], cwd := some root }).trimAscii.toString
  let mut runtimeTargets := []
  let mut pins : List Entry := []
  for target in targets do
    let archive := runtimeDir / ("eggshell-" ++ target ++ ".tar.gz")
    let bytes ← IO.FS.readBinFile archive
    let checksum := Sha256.hex bytes
    let file := "eggshell-runtime-" ++ target ++ "-" ++ String.ofList (checksum.toList.take 16) ++ ".tar.gz"
    IO.FS.writeBinFile (output / file) bytes
    runtimeTargets := runtimeTargets ++ [(target, Json.mkObj [("file", .str file), ("sha256", .str checksum)])]
    pins := pins ++ [⟨"runtime-pins/" ++ target, (release ++ "\n" ++ file ++ "\n" ++ checksum ++ "\n").toUTF8, false⟩]
  let runtime := Json.mkObj [("release", .str release), ("source_commit", .str source),
    ("targets", Json.mkObj runtimeTargets)]
  let mut interface ← IO.ofExcept (manifest.getObjVal? "interface")
  for (key, value) in [("logo", .str "./assets/icon.png"), ("composerIcon", .str "./assets/icon.png"),
      ("privacyPolicyURL", .str "https://github.com/momonpya/eggshell/blob/main/PRIVACY.md")] do
    interface := interface.setObjVal! key value
  let manifest := manifest.setObjVal! "skills" (.str "./skills") |>.setObjVal! "interface" interface
  let original ← collect (root / "plugins/eggshell")
  let entries := (original.filter fun e => e.name != ".codex-plugin/plugin.json" && e.name != "runtime.json" &&
      !(e.name.startsWith "runtime-pins/")) ++ pins ++ [
    ⟨".codex-plugin/plugin.json", (manifest.pretty ++ "\n").toUTF8, false⟩,
    ⟨"runtime.json", (runtime.pretty ++ "\n").toUTF8, false⟩,
    ⟨"assets/icon.png", ← IO.FS.readBinFile (root / "docs/assets/brand/eggshell-app-icon-dark-1024.png"), false⟩,
    ⟨"LICENSE", ← IO.FS.readBinFile (root / "LICENSE"), false⟩]
  let archive := zip (entries.mergeSort (fun a b => a.name ≤ b.name))
  if archive.size > 100000000 then throw (IO.userError "plugin ZIP exceeds 100 MB")
  IO.FS.writeBinFile (output / "eggshell-codex-plugin.zip") archive
  IO.FS.writeFile (output / "runtime.json") (runtime.pretty ++ "\n")
  IO.println s!"Packaged {entries.length} entries, {archive.size} bytes, four pinned runtime assets"

end Eggshell.Package

def main (args : List String) : IO UInt32 := do
  match args with
  | ["--runtime-dir", runtimes, "--output", output, "--release", release] =>
    Eggshell.Package.build (← IO.currentDir) (.mk runtimes) (.mk output) release
    pure 0
  | ["--version"] =>
    let json ← IO.ofExcept (Lean.Json.parse (← IO.FS.readFile "plugins/eggshell/.codex-plugin/plugin.json"))
    IO.println (← IO.ofExcept (json.getObjValAs? String "version"))
    pure 0
  | _ => throw (IO.userError "package --runtime-dir PATH --output PATH --release vVERSION")
