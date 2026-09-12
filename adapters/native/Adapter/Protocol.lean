module

public import Adapter.Contracts
public import Eggshell.Sha256
public import Eggshell.PluginModel
public import Eggshell.PluginHooks

@[expose] public section

namespace Eggshell.Adapter
open Lean Eggshell.Plugin

def sessionKey (identity : Identity) : String :=
  identity.host.name ++ "-" ++ Sha256.hex identity.native.toUTF8

structure Receipt where
  stamp : String
  call : Call
  deriving Repr, ToJson, FromJson

structure Correlation where
  owner : Identity
  turn : Option String := none
  calls : List Call := []
  receipts : List Receipt := []
  deriving Repr, ToJson, FromJson

def requiredText (raw : Json) (key : String) : Except String String := do
  let value ← requiredString raw key
  if value.isEmpty then throw ("hook must provide nonempty " ++ key)
  pure value

def optionalText (raw : Json) (key : String) : Except String (Option String) := do
  if !(raw.getObjVal? key).isOk || raw.getObjValD key == .null then return none
  some <$> requiredText raw key

def identify (host : Host) (raw : Json) : Except String Identity := do
  pure ⟨host, ← requiredText raw (if host == .cursor then "conversation_id" else "session_id")⟩

def directory (raw : Json) : Except String String := do
  let cwd := optionalString raw "cwd" |>.filter (!·.isEmpty)
  let cwd ← match cwd with
    | some value => pure value
    | none => match raw.getObjValD "workspace_roots" with
      | .arr #[.str path] => pure path
      | _ => throw "hook must identify one project working directory"
  if !(System.FilePath.mk cwd).isAbsolute then throw "hook working directory must be absolute"
  pure cwd

def nativeEvent (host : Host) (raw : Json) : Option Event :=
  (events host).find? (fun pair => some pair.1 == optionalString raw "hook_event_name") |>.map (·.2)

def bindCall (state : Correlation) (id native turn : String) : Except String Correlation := do
  match state.calls.find? (·.id == id) with
  | some old =>
      if old.turn != turn then throw "native tool ID was reused across different turns"
      return state
  | none => return { state with calls := state.calls ++ [⟨id, native, turn, false, false⟩] }

/-- Canonical JSON objects are sorted by Lean's JSON representation. -/
def signature (name : String) (args : Json) : String :=
  Sha256.hex (Json.arr #[.str name, args] |>.compress.toUTF8)

inductive Normalized where
  | event (input : Json) (state : Correlation)
  | unattributed (input : Json) (recordable : Bool)

def normalize (host : Host) (event : Event) (raw : Json) (state : Correlation)
    (fresh : String) : Except String Normalized := do
  let identity ← identify host raw
  if !ownerMatches state.owner identity then throw "adapter session identity mismatch"
  let cwd ← directory raw
  let mut result := Json.mkObj [("session_id", toJson (sessionKey identity)),
    ("cwd", toJson cwd), ("hook_event_name", toJson event.engineName)]
  for key in ["source", "prompt", "tool_name", "tool_input", "tool_response"] do
    if let .ok value := raw.getObjVal? key then result := result.setObjVal! key value
  let explicitTurn ← optionalText raw (if host == .cursor then "generation_id" else "turn_id")
  if event == .prompt then
    let _ ← requiredText raw "prompt"
    let turn := explicitTurn.getD fresh
    return .event (result.setObjVal! "turn_id" (toJson turn)) { state with turn := some turn }
  let turn := explicitTurn.or state.turn
  if let some turn := turn then result := result.setObjVal! "turn_id" (toJson turn)
  let mut state := state
  if event == .before || event == .after then
    let name ← requiredText raw "tool_name"
    let args ← raw.getObjVal? "tool_input"
    let explicitCall ← optionalText raw "tool_use_id"
    let native := explicitCall.getD (signature name args)
    let stamp := (optionalString raw "timestamp" |>.filter (!·.isEmpty)).map fun time =>
      Sha256.hex (Json.arr #[raw.getObjValD "hook_event_name", .str native, .str time] |>.compress.toUTF8)
    if event == .before then
      let some turn := turn | throw "tool arrived before a user turn"
      let id := explicitCall.or stamp |>.getD fresh
      state ← bindCall state id native turn
      result := result.setObjVal! "tool_use_id" (toJson id)
    else
      let failed := ["PostToolUseFailure", "postToolUseFailure"].contains
        ((optionalString raw "hook_event_name").getD "")
      let response ← if failed then pure (Json.mkObj [("error", raw.getObjValD "error"), ("is_error", .bool true)])
        else if host == .cursor then
          let response := raw.getObjValD "tool_output"
          pure <| match response with
            | .str text => (Json.parse text).toOption.getD response
            | _ => response
        else raw.getObjVal? "tool_response"
      result := result.setObjVal! "tool_response" response
      let previous := stamp.bind fun stamp => state.receipts.find? (·.stamp == stamp)
      let chosen ← match previous with
        | some receipt => pure (some receipt.call)
        | none =>
          let eligible := state.calls.filter fun c =>
            (match explicitCall with
             | some id => c.id == id
             | none => c.native == native && !c.finished) &&
            (explicitTurn.all (· == c.turn))
          if eligible.isEmpty && explicitCall.isSome && explicitTurn.isSome then
            let id := explicitCall.getD ""
            let origin := explicitTurn.getD ""
            state ← bindCall state id native origin
            pure (state.calls.find? (·.id == id))
          else pure ((chooseCall eligible).map (·.val))
      let some call := chosen |
        let candidates := state.calls.filter (·.native == native)
        let body := Json.mkObj ((result.getObj?.toOption.map (·.toList) |>.getD [])
          |>.filter (·.1 != "turn_id"))
        return .unattributed body (!candidates.isEmpty && candidates.all (·.writable))
      state := { state with calls := state.calls.map fun c =>
        if c.id == call.id then { c with finished := true } else c }
      if let some stamp := stamp then
        if !(state.receipts.any (·.stamp == stamp)) then
          state := { state with receipts := state.receipts ++ [⟨stamp, call⟩] }
      result := result.setObjVal! "tool_use_id" (toJson call.id)
        |>.setObjVal! "turn_id" (toJson call.turn)
  if event == .stop then
    if let some text := optionalString raw (if host == .gemini then "prompt_response" else "last_assistant_message") then
      result := result.setObjVal! "last_assistant_message" (toJson text)
  return .event result state

def proposal (host : Host) (event : Event) (output : Json) : Reply :=
  let fields := output.getObjValD "hookSpecificOutput"
  let context := optionalString fields "additionalContext" |>.filter (!·.isEmpty)
  let denial := if optionalString fields "permissionDecision" == some "deny" then
    optionalString fields "permissionDecisionReason" |>.filter (!·.isEmpty) else none
  projectReply host event context denial

def replyJson (host : Host) (event : Event) : Reply → Json
  | .quiet => Json.mkObj []
  | .deny reason =>
    match host with
    | .claude | .opencode => Json.mkObj [("hookSpecificOutput", Json.mkObj [
        ("hookEventName", .str "PreToolUse"), ("permissionDecision", .str "deny"),
        ("permissionDecisionReason", .str reason)])]
    | .gemini => Json.mkObj [("decision", .str "deny"), ("reason", .str reason)]
    | .cursor => Json.mkObj [("permission", .str "deny"), ("agent_message", .str reason)]
  | .context text =>
    if host == .cursor then Json.mkObj [("additional_context", .str text)]
    else Json.mkObj [("hookSpecificOutput", Json.mkObj [
      ("hookEventName", .str (if host == .gemini then
        if event == .prompt then "BeforeAgent" else "AfterTool" else event.engineName)),
      ("additionalContext", .str text)])]

theorem stop_wire_is_empty (host : Host) (output : Json) :
    replyJson host .stop (proposal host .stop output) = Json.mkObj [] := by
  simp [proposal, stop_is_quiet, replyJson]

end Eggshell.Adapter
