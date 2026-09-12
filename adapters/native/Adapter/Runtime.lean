module

public import Adapter.Protocol
public import Adapter.Bridge

@[expose] public section

namespace Eggshell.Adapter
open Lean Eggshell.Plugin

def correlationRoot : IO System.FilePath := do
  pure ((← Paths.dataRoot) / "adapters")

def freshId : IO String := do
  pure (Blake3.hex (← IO.getRandomBytes 16))

/-- The reducer is pure. Authorized terminal receipts are journaled before
    committing consumed call IDs. No RPC, model, or search runs under this lock. -/
def transaction (identity : Identity)
    (reduce : Correlation → Except String (α × Correlation))
    (journal : α → Option Json := fun _ => none) : IO α := do
  let root ← correlationRoot
  Persistence.privateDirectory root
  let file := root / (sessionKey identity ++ ".json")
  Persistence.rejectSymlinkAncestors file
  let lockPath := Persistence.lockPath file
  let guard ← IO.FS.Handle.mk lockPath .append
  Persistence.privateFile lockPath
  guard.lock
  try
    if !(← file.pathExists) && (← (root / (sessionKey identity ++ ".sqlite3")).pathExists) then
      throw (IO.userError "this chat has legacy adapter correlation state; start a new chat after upgrading (saved eggs are preserved)")
    let state := (← readJson? file : Option Correlation).getD { owner := identity }
    if !ownerMatches state.owner identity then throw (IO.userError "adapter session identity mismatch")
    let (result, next) ← IO.ofExcept (reduce state)
    if !ownerMatches next.owner identity then throw (IO.userError "adapter reducer changed session identity")
    let terminal := journal result
    for step in commitPlan terminal.isSome do
      match step with
      | .journal =>
        if let some input := terminal then
          captureTerminal input
          Bridge.captureLateResult input
      | .consume => writeJson file next
    pure result
  finally guard.unlock

def emit (value : Json) : IO Unit := do
  let stdout ← IO.getStdout
  stdout.putStrLn value.compress
  stdout.flush

/-- The returned capability is created after write+flush, never before them. -/
def publish (value : Json) (receipt : String) : IO Published := do
  emit value
  pure ⟨receipt⟩

def writableNow (input : Json) : IO Bool := do
  let session ← IO.ofExcept (requiredText input "session_id")
  withSession session fun files => do
    let state ← readState? files
    let pending ← readPendingBase? files
    pure (state.any (·.enabled) && pending.any (·.write.isSome))

def retainUnattributed (input : Json) (permitted : Bool) : IO Unit := do
  if !permitted || !(← writableNow input) then return
  let session ← IO.ofExcept (requiredText input "session_id")
  let root ← correlationRoot
  writeJson (root / "unattributed" / session / ((← freshId) ++ ".json")) input

def runHook (host : Host) (raw : Json) : IO Unit := do
  let some event := nativeEvent host raw | emit (Json.mkObj [])
  let identity ← IO.ofExcept (identify host raw)
  let fresh ← freshId
  let normalized ← transaction identity (journal := fun result =>
      match result with
      | .event input _ => if event == .after then some input else none
      | .unattributed .. => none) fun state => do
    let result ← normalize host event raw state fresh
    pure (result, match result with | .event _ next => next | .unattributed .. => state)
  let input ← match normalized with
    | .event input _ => pure input
    | .unattributed input recordable =>
      retainUnattributed input recordable
      IO.eprintln "Eggshell: ambiguous result retained only when authorized; no task was invented"
      emit (Json.mkObj [])
      return
  if host == .cursor && event == .answer then
    if let some text := optionalString raw "text" then
      Bridge.draftAnswer (input.setObjVal! "text" (toJson text))
    return ← emit (Json.mkObj [])
  let input := if host == .cursor && event == .stop then
    input.setObjVal! "_adapter_use_draft" (toJson (optionalString raw "status" == some "completed"))
    else input
  let receipt ← Bridge.deliver input
  let reply := proposal host event (receipt.getObjValD "output")
  if event == .before then
    let id := optionalString input "tool_use_id" |>.getD ""
    let denied := match reply with | .deny _ => true | _ => false
    let writable := receipt.getObjValD "writable" == true
    transaction identity fun state => pure ((), { state with calls := state.calls.map fun call =>
      if call.id == id then { call with finished := denied, writable } else call })
  let wire := replyJson host event reply
  let id ← IO.ofExcept (requiredText receipt "receipt")
  if host == .opencode then
    emit (Json.mkObj [("output", wire), ("receipt", .str id),
      ("session_id", .str (sessionKey identity))])
  else
    let published ← publish wire id
    if let some acknowledged := receiptToAck reply published then
      -- Output has already been written. A receipt error must never write a
      -- second JSON object into the host response.
      try Bridge.acknowledgeDelivery (Json.mkObj [
        ("session_id", .str (sessionKey identity)), ("receipt", .str acknowledged)])
      catch error => IO.eprintln s!"Eggshell delivery receipt: {error}"

def hook (host : Host) : IO UInt32 := do
  try
    runHook host (← IO.ofExcept (Json.parse (← (← IO.getStdin).readToEnd)))
  catch error =>
    IO.eprintln s!"Eggshell adapter: {error}"
    emit (Json.mkObj [])
  pure 0

def acknowledge (host : Host) : IO UInt32 := do
  let input ← IO.ofExcept (Json.parse (← (← IO.getStdin).readToEnd))
  let session ← IO.ofExcept (requiredText input "session_id")
  if !(session.startsWith (host.name ++ "-")) then throw (IO.userError "receipt belongs to another harness")
  Bridge.acknowledgeDelivery input
  pure 0

/-- Controls execute in a fresh native process with the explicit adapter chat.
    Inherited Codex plugin discovery cannot select a different manager binary. -/
def control (host : Host) (session : String) (args : List String) : IO UInt32 := do
  if args == ["doctor"] then
    let output ← IO.Process.output {
      cmd := (← IO.appPath).toString
      args := #["egg", "doctor"]
      env := #[("CODEX_THREAD_ID", some (sessionKey ⟨host, session⟩)), ("PLUGIN_ROOT", none)] }
    if output.exitCode != 0 then throw (IO.userError output.stderr)
    let report ← IO.ofExcept (Json.parse output.stdout)
    emit (report.setObjVal! "hook_trust" (.str ("Review hooks in " ++ host.name))
      |>.setObjVal! "next_step" (.str "Restart the agent and verify saving and delivery with the two-chat example."))
    return 0
  let child ← IO.Process.spawn {
    cmd := (← IO.appPath).toString, args := ("egg" :: args).toArray
    env := #[("CODEX_THREAD_ID", some (sessionKey ⟨host, session⟩)), ("PLUGIN_ROOT", none)] }
  child.wait

end Eggshell.Adapter
