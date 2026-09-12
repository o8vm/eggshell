module

public import Eggshell.Daemon

@[expose] public section

open Lean Eggshell Eggshell.Plugin

def draftPath (files : SessionFiles) (turn : String) : System.FilePath :=
  files.directory / "adapter-drafts" /
    (Blake3.hex (Blake3.digest "eggshell.turn".toUTF8 [turn.toUTF8]) ++ ".json")

def turnPath (files : SessionFiles) (turn : String) : System.FilePath :=
  files.directory / "adapter-turns" /
    (Blake3.hex (Blake3.digest "eggshell.turn".toUTF8 [turn.toUTF8]) ++ ".json")

/-- Retain the engine's original write authorization for late terminal hooks.
    This is an immutable engine value, not a second graph or search policy. -/
def rememberTurn (input : Json) : IO Unit := do
  if optionalString input "hook_event_name" != some "UserPromptSubmit" then return
  let session ← IO.ofExcept (requiredString input "session_id")
  let turn ← IO.ofExcept (requiredString input "turn_id")
  withSession session fun files => do
    let some state ← readState? files | return
    let some pending ← readPendingBase? files | return
    if !state.enabled || pending.turnId != turn || pending.write.isNone then return
    writeJson (turnPath files turn) { pending with tools := [], inFlight := [] }

/-- A tool started under an earlier turn keeps that turn's write target even
    when its terminal hook arrives after the engine has sealed/deferred it. -/
def captureLateResult (input : Json) : IO Unit := do
  if optionalString input "hook_event_name" != some "PostToolUse" then return
  let session ← IO.ofExcept (requiredString input "session_id")
  let turn ← IO.ofExcept (requiredString input "turn_id")
  withSession session fun files => do
    let some state ← readState? files | return
    if !state.enabled then return
    let current ← readPendingBase? files
    if current.any (fun pending => pending.turnId == turn && !pending.closed && pending.finalMessage.isNone) then return
    let some original ← (readJson? (turnPath files turn) : IO (Option PendingTurn)) | return
    let tool ← IO.ofExcept (toolFromHook input true)
    queueCheckpoint files {
      original with tools := [tool], inFlight := [], finalMessage := none, closed := false }

/-- Some hosts report answer text before loop completion. A candidate is local
    adapter state, never a final engine outcome. Respect the selected turn's
    write profile, including a one-turn read-only override. -/
def draftAnswer : IO UInt32 := do
  try
    let input ← IO.ofExcept (Json.parse (← (← IO.getStdin).readToEnd))
    let session ← IO.ofExcept (requiredString input "session_id")
    let turn ← IO.ofExcept (requiredString input "turn_id")
    withSession session fun files => do
      let some state ← readState? files | return
      let some pending ← readPendingBase? files | return
      if !state.enabled || pending.turnId != turn || pending.closed || pending.write.isNone then return
      let text ← IO.ofExcept (requiredString input "text")
      writeJson (draftPath files turn) text
    IO.println "{}"
    pure 0
  catch error =>
    IO.eprintln s!"Eggshell adapter draft: {error}"
    IO.println "{}"
    pure 0

def attachDraft (input : Json) : IO Json := do
  if optionalString input "hook_event_name" != some "Stop" then return input
  let session ← IO.ofExcept (requiredString input "session_id")
  let some turn := optionalString input "turn_id" | return input
  withSession session fun files => do
    let path := draftPath files turn
    let state ← readState? files
    let pending ← readPendingBase? files
    let permitted := state.any (·.enabled) && pending.any fun pending =>
      pending.turnId == turn && pending.write.isSome && !pending.closed
    let text : Option String ← if permitted && input.getObjValD "_adapter_use_draft" == true then
        readJson? path
      else pure none
    removeIfExists path
    pure (text.map (fun text => input.setObjVal! "last_assistant_message" (toJson text)) |>.getD input)

/-- A separate companion executable. The memory engine and its Codex entrypoint
    are imported unchanged; host-specific schemas live outside this package. -/
def deliver : IO UInt32 := do
  try
    let raw ← IO.ofExcept (Json.parse (← (← IO.getStdin).readToEnd))
    let input ← attachDraft (Daemon.attachClientConfig raw (← IO.getEnv "EGGSHELL_CONFIG"))
    -- Use the engine's durable capture before any manager or search operation.
    captureTerminal input
    captureLateResult input
    let event := (optionalString input "hook_event_name").getD ""
    let fast := ["Stop", "Interrupt", "PostCompact", "SessionEnd"].contains event ||
      (event == "SessionStart" && optionalString input "source" == some "compact")
    let deadline := (← IO.monoMsNow) + (if fast then 2000 else 26000)
    let receipt := Blake3.hex (← IO.getRandomBytes 16)
    let input := input.setObjVal! "_eggshell_deadline" (toJson (deadline - 250))
      |>.setObjVal! "_eggshell_receipt" (toJson receipt)
    let result ← Daemon.boundedRpc "hook" input (deadline - 150)
    rememberTurn input
    let some result := result |
      throw (IO.userError "memory hook did not return before its delivery deadline; captured results remain queued")
    let reply ← IO.ofExcept (Json.parse result)
    if let some error := optionalString reply "error" then throw (IO.userError error)
    let output ← IO.ofExcept (Json.parse ((optionalString reply "output").getD "{}"))
    let session ← IO.ofExcept (requiredString input "session_id")
    let writable ← withSession session fun files => do
      let state ← readState? files
      let pending ← readPendingBase? files
      pure <| state.any (·.enabled) && pending.any fun pending =>
        optionalString input "turn_id" == some pending.turnId && pending.write.isSome
    IO.println (Json.mkObj [("ok", toJson true), ("output", output),
      ("writable", toJson writable),
      ("session_id", input.getObjValD "session_id"), ("receipt", toJson receipt)] |>.compress)
    -- The adapter acknowledges only after emitting a supported host response.
    pure 0
  catch error =>
    IO.eprintln s!"Eggshell adapter: {error}"
    IO.println (Json.mkObj [("ok", toJson false), ("output", Json.mkObj [])] |>.compress)
    pure 0

def acknowledgeDelivery : IO UInt32 := do
  try
    let input ← IO.ofExcept (Json.parse (← (← IO.getStdin).readToEnd))
    let _ ← Daemon.boundedRpc "ack" input ((← IO.monoMsNow) + 2000)
    pure 0
  catch error =>
    IO.eprintln s!"Eggshell adapter receipt: {error}"
    pure 1

def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["deliver"] => deliver
  | ["ack"] => acknowledgeDelivery
  | ["draft"] => draftAnswer
  | ["codex-daemon", session] => Daemon.run session
  | ["codex-worker", role] => Worker.run role
  | ["codex-rpc", kind] => Daemon.rpcClient kind
  | "egg" :: rest => eggControl rest
  | ["--help"] =>
      IO.println "Eggshell adapter bridge: deliver | ack | egg COMMAND"
      pure 0
  | _ => IO.eprintln "invalid adapter bridge command" *> pure 1
