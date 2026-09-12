module

public import Adapter.Protocol

@[expose] public section

namespace Eggshell.Adapter.Install
open Lean Eggshell.Plugin

def owner : String := "momonpya/eggshell-adapters-v1\n"
def openCodeSource : String := include_str "../../opencode.mjs"

def shellQuote (text : String) : String := "'" ++ text.replace "'" "'\\''" ++ "'"

def configPath : Host → String
  | .claude => ".claude/settings.json"
  | .gemini => ".gemini/settings.json"
  | .cursor => ".cursor/hooks.json"
  | .opencode => ".opencode/plugins/eggshell.js"

def readDocument (path : System.FilePath) : IO Json := do
  if !(← path.pathExists) then return Json.mkObj []
  let json ← IO.ofExcept (Json.parse (← IO.FS.readFile path))
  let _ ← IO.ofExcept json.getObj?
  pure json

def fields (document : Json) (key : String) : Except String Json := do
  match document.getObjVal? key with
  | .error _ => pure (Json.mkObj [])
  | .ok json => let _ ← json.getObj?; pure json

def arrayField (document : Json) (key : String) : Except String (Array Json) :=
  match document.getObjVal? key with
  | .error _ => .ok #[]
  | .ok json => json.getArr?

def eraseField (document : Json) (key : String) : Except String Json := do
  pure (Json.mkObj ((← document.getObj?).toList.filter (·.1 != key)))

def removeEntries (document entries : Json) : Except String Json := do
  let mut hooks ← fields document "hooks"
  for (event, entry) in (← entries.getObj?).toList do
    let current ← arrayField hooks event
    let kept := removeOwned [entry.compress] (current.toList.map Json.compress)
    if kept.isEmpty then hooks ← eraseField hooks event
    else hooks := hooks.setObjVal! event (.arr ((← kept.mapM Json.parse).toArray))
  if (← hooks.getObj?).isEmpty then eraseField document "hooks"
  else pure (document.setObjVal! "hooks" hooks)

def entries (host : Host) (command : String) : Json :=
  Json.mkObj ((events host).map fun (event, _) =>
    let handler := Json.mkObj ([("type", .str "command"), ("command", .str command),
      ("timeout", toJson (if host == .gemini then 35000 else 35 : Nat))] ++
      if host == .gemini then [("name", .str ("eggshell-" ++ event))] else [])
    (event, if host == .cursor then handler else Json.mkObj [("hooks", .arr #[handler])]))

def addEntries (document selected : Json) : Except String Json := do
  let mut hooks ← fields document "hooks"
  for (event, entry) in (← selected.getObj?).toList do
    let current ← arrayField hooks event
    hooks := hooks.setObjVal! event (.arr (current.push entry))
  pure (document.setObjVal! "hooks" hooks)

/-- A write-ahead receipt retains both versions until the project config is
    replaced. A crash between files cannot orphan the previous owned hooks. -/
def receiptHistory (receipt : Json) (fuel : Nat := 1024) : Except String (List Json) := do
  match fuel with
  | 0 => throw "adapter receipt nesting is excessive"
  | n + 1 =>
    match receipt.getObjVal? "previous" with
    | .error _ => pure [receipt]
    | .ok previous => pure (receipt :: (← receiptHistory previous n))

def atomicBytes (path : System.FilePath) (bytes : ByteArray) (executable := false) : IO Unit := do
  Persistence.rejectSymlinkAncestors path
  if let some parent := path.parent then IO.FS.createDirAll parent
  let temporary := System.FilePath.mk (path.toString ++ ".tmp-" ++ Blake3.hex (← IO.getRandomBytes 16))
  try
    IO.FS.writeBinFile temporary bytes
    IO.setAccessRights temporary { user := { read := true, write := true, execution := executable } }
    IO.FS.rename temporary path
  finally removeIfExists temporary

def writeDocument (path : System.FilePath) (value : Json) : IO Unit :=
  atomicBytes path (value.pretty ++ "\n").toUTF8

def fileUrl (path : System.FilePath) : String :=
  "file://" ++ String.ofList (path.toString.toUTF8.data.toList.flatMap fun byte =>
    if byte.toNat == 47 || byte.toNat == 45 || byte.toNat == 46 || byte.toNat == 95 ||
        (byte.toNat ≥ 48 && byte.toNat ≤ 57) || (byte.toNat ≥ 65 && byte.toNat ≤ 90) ||
        (byte.toNat ≥ 97 && byte.toNat ≤ 122) then [Char.ofNat byte.toNat]
    else ('%' :: (Blake3.hex (ByteArray.mk #[byte])).toList))

def run (host : Host) (project runtimeRoot : System.FilePath) (uninstall : Bool) : IO Json := do
  if !(← project.isDir) then throw (IO.userError "project directory does not exist")
  let project ← IO.FS.realPath project
  let support := runtimeRoot / "share" / "eggshell-adapters"
  let marker := support / ".owner"
  Persistence.rejectSymlinkAncestors support
  if ← support.pathExists then
    if !(← marker.pathExists) || (← IO.FS.readFile marker) != owner then
      throw (IO.userError "refusing to replace an unowned adapter directory")
  let config := project / configPath host
  Persistence.rejectSymlinkAncestors config
  let key := Sha256.hex (host.name ++ "\n" ++ config.toString).toUTF8
  let receiptPath := support / "receipts" / (key ++ ".json")
  let previous ← readDocument receiptPath
  let history ← IO.ofExcept (receiptHistory previous)
  let old ← if ← config.pathExists then some <$> IO.FS.readFile config else pure none
  let document ← if host == .opencode then
      if old.isSome && !(history.any (fun receipt => old == optionalString receipt "contents")) then
        throw (IO.userError "refusing to replace an unowned OpenCode plugin")
      pure (Json.mkObj [])
    else
      let document ← readDocument config
      if host == .cursor && (document.getObjVal? "version").isOk && document.getObjValD "version" != toJson (1 : Nat) then
        throw (IO.userError "unsupported Cursor hooks schema version")
      history.foldlM (fun current receipt => do
        IO.ofExcept (removeEntries current (← IO.ofExcept (fields receipt "entries")))) document
  if uninstall then
    if !(← receiptPath.pathExists) then return Json.mkObj [("status", .str "not-installed")]
    if host == .opencode then removeIfExists config else writeDocument config document
    removeIfExists receiptPath
    return Json.mkObj [("status", .str "removed"), ("memory", .str "preserved"), ("runtime", .str "preserved")]
  let installed := support / "eggshell-bridge"
  let command := String.intercalate " " (["env", "EGGSHELL_PREFIX=" ++ runtimeRoot.toString,
    installed.toString, "hook", host.name].map shellQuote)
  let selected := entries host command
  let final ← IO.ofExcept (addEntries document selected)
  Persistence.privateDirectory support
  atomicBytes marker owner.toUTF8
  let executable ← IO.appPath
  if executable != installed then atomicBytes installed (← IO.FS.readBinFile executable) true
  atomicBytes (support / "opencode.mjs") openCodeSource.toUTF8
  if host == .opencode then
    let contents := "// Eggshell project adapter.\nexport { Eggshell } from " ++
      (Json.str (fileUrl (support / "opencode.mjs"))).compress ++ ";\n"
    let receipt := Json.mkObj [("contents", .str contents)]
    writeDocument receiptPath (receipt.setObjVal! "previous" previous)
    atomicBytes config contents.toUTF8
    writeDocument receiptPath receipt
  else
    let final := if host == .cursor then final.setObjVal! "version" (toJson (1 : Nat)) else final
    let receipt := Json.mkObj [("entries", selected)]
    writeDocument receiptPath (receipt.setObjVal! "previous" previous)
    writeDocument config final
    writeDocument receiptPath receipt
  return Json.mkObj [("status", .str "configured"), ("client", .str host.name), ("config", .str config.toString)]

def command (host : Host) (args : List String) : IO UInt32 := do
  let rec options (project runtimeRoot : System.FilePath) (remove : Bool) : List String → Except String _
    | [] => .ok (project, runtimeRoot, remove)
    | "--project" :: path :: rest => options (.mk path) runtimeRoot remove rest
    | "--prefix" :: path :: rest => options project (.mk path) remove rest
    | "--uninstall" :: rest => options project runtimeRoot true rest
    | _ => .error "expected --project PATH, --prefix PATH, or --uninstall"
  let (project, runtimeRoot, remove) ← IO.ofExcept (options (← IO.currentDir) (← Paths.installRoot) false args)
  if !project.isAbsolute || !runtimeRoot.isAbsolute then throw (IO.userError "project and runtimeRoot must be absolute")
  Persistence.privateDirectory runtimeRoot
  let lock ← IO.FS.Handle.mk (runtimeRoot / ".eggshell-adapter-install.lock") .append
  lock.lock
  try
    IO.println (← run host project runtimeRoot remove).pretty
    pure 0
  finally lock.unlock

end Eggshell.Adapter.Install
