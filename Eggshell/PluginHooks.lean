module

public import Eggshell.Handoff
public import Eggshell.MiniLM

@[expose] public section

namespace Eggshell.Plugin

open Lean

def requiredString (json : Json) (name : String) : Except String String := do
  (json.getObjVal? name).bind Json.getStr?

def optionalString (json : Json) (name : String) : Option String :=
  (json.getObjVal? name).toOption.bind (Json.getStr? · |>.toOption)

def jsonField (json : Json) (name : String) : String :=
  json.getObjValD name |>.compress

def emptyHook : String := "{}"

def systemMessage (message : String) : String :=
  Json.mkObj [("systemMessage", message)] |>.compress

def blockPrompt (reason : String) : String :=
  Json.mkObj [("decision", "block"), ("reason", reason)] |>.compress

def defaultState (config : Config.Config) : ThreadState :=
  { profile := config.defaultProfile }

def configFromHook (input : Json) (cwd : System.FilePath) : IO (Option Config.Config) := do
  let config? ← Config.loadWith cwd (optionalString input "_eggshell_config")
  config?.mapM fun config => do
    if config.semanticMatcherWasSet then pure config
    else
      let some home ← IO.getEnv "HOME" | pure config
      pure { config with
        semanticMatcher := ← MiniLM.command (System.FilePath.mk home) (← dataRoot) }

def pendingSelection (pending : PendingTurn) : Config.Selection :=
  let eggs := pending.read.map fun raw => {
    name := raw
    path := System.FilePath.mk raw
  }
  {
    label := pending.profile
    semanticMatcher := pending.semanticMatcher
    read := eggs
    write := pending.write.map fun raw => {
      name := raw
      path := System.FilePath.mk raw
    }
    handoffChars := pending.handoffChars
    localUnion := pending.localUnion
  }

def addDeliveredGraphs (state : ThreadState) (keys : List String) : ThreadState :=
  { state with deliveredGraphs := (state.deliveredGraphs ++ keys).eraseDups }

def recordHandoff (state : ThreadState) (handoff : Handoff) : ThreadState :=
  { (addDeliveredGraphs state handoff.deliveredGraphs) with
    lastHandoff := handoff.text
    lastReason := handoff.reason }

/-- Every semi-naive delta has its own transport budget. -/
def recordHandoffWithin (limit : Nat) (state : ThreadState)
    (handoff : Handoff) : Option ThreadState :=
  if handoff.text.length ≤ limit then some (recordHandoff state handoff) else none

theorem recordHandoffWithin_is_per_delta (limit : Nat) (state : ThreadState)
    (handoff : Handoff) :
    (recordHandoffWithin limit state handoff).isSome =
      decide (handoff.text.length ≤ limit) := by
  unfold recordHandoffWithin
  split <;> simp_all

def resolveDefault (files : SessionFiles) (state : ThreadState)
    (pending : PendingTurn) : IO ThreadState := do
  match pending.finalMessage with
  | none => throw (IO.userError "unfinished staged turn; run !egg drop")
  | some _ =>
      let nextState ← match pending.write with
        | none => pure state
        | some target =>
            let promotion ← promote pending (System.FilePath.mk target)
            pure (addDeliveredGraphs state
              (promotion.outcomeRelations.map nativeHistoryKey))
      removeIfExists files.pending
      pure nextState

def sessionStart (input : Json) : IO String := do
  let session ← IO.ofExcept (requiredString input "session_id")
  if optionalString input "source" = some "compact" then
    withSession session fun files => do
      if let some state ← (readJson? files.state : IO (Option ThreadState)) then
        writeJson files.state {
          state with
          deliveredGraphs := []
          afterCompaction := true
          lastHandoff := ""
          lastReason := "compacted; graph may be resent"
        }
      pure emptyHook
  else withSession session fun files => do
    let cwd := System.FilePath.mk ((optionalString input "cwd").getD ".")
    let config ← configFromHook input cwd
    if let some config := config then
      if !(← files.state.pathExists) then
        writeJson files.state (defaultState config)
    let pending ← (readJson? files.pending : IO (Option PendingTurn))
    pure <| match pending with
      | some pending =>
          if pending.finalMessage.isSome then
            systemMessage "Eggshell recovered a sealed staged turn; use !egg keep or !egg drop."
          else systemMessage "Eggshell recovered an unfinished turn; use !egg drop."
      | none => emptyHook

def userPromptSubmit (input : Json) : IO String := do
  let session ← IO.ofExcept (requiredString input "session_id")
  let turn ← IO.ofExcept (requiredString input "turn_id")
  let cwd := System.FilePath.mk (← IO.ofExcept (requiredString input "cwd"))
  let prompt ← IO.ofExcept (requiredString input "prompt")
  withSession session fun files => do
    let config? ← configFromHook input cwd
    let some config := config? | pure emptyHook
    let mut state := (← (readJson? files.state : IO (Option ThreadState))).getD
      (defaultState config)
    if let some pending ← (readJson? files.pending : IO (Option PendingTurn)) then
      if pending.finalMessage.isNone then
        return blockPrompt "Eggshell recovered an unfinished staged turn. Run !egg drop."
      state ← resolveDefault files state pending
    let profileName := state.nextProfile.getD state.profile
    let selection ← match Config.resolve config profileName with
      | .ok selection => pure selection
      | .error message => throw (IO.userError message)
    let projection := state.nextProjection.getD .automatic
    let handoff ← match projection with
      | .automatic =>
          automaticHandoff selection prompt state.deliveredGraphs false
            (enableLocalUnion := selection.localUnion)
      | .none => pure none
      | .roots keys => manualHandoff selection prompt keys
    let handoff := handoff.bind fun candidate =>
      (recordHandoffWithin selection.handoffChars state candidate).map fun next =>
        (candidate, next)
    let context := handoff.map (·.1.text) |>.getD ""
    if let some (_, next) := handoff then state := next
    state := {
      state with
      nextProfile := none
      nextProjection := none
      afterCompaction := false
      lastReason := handoff.map (·.1.reason) |>.getD "no graph matched"
    }
    let pending : PendingTurn := {
      sessionId := session
      turnId := turn
      cwd := cwd.toString
      prompt
      profile := selection.label
      semanticMatcher := selection.semanticMatcher
      read := selection.read.map (·.path.toString)
      write := selection.write.map (·.path.toString)
      handoffChars := selection.handoffChars
      localUnion := selection.localUnion
      projection
    }
    writeJson files.state state
    writeJson files.pending pending
    pure <| if context = "" then emptyHook
      else hookContext "UserPromptSubmit" context

def toolFromHook (input : Json) (withResponse : Bool) : Except String ToolEvent := do
  pure {
    name := ← requiredString input "tool_name"
    useId := ← requiredString input "tool_use_id"
    input := jsonField input "tool_input"
    response := if withResponse then jsonField input "tool_response" else ""
  }

def deliverForWork (session : String) (pending : PendingTurn)
    (work : String) (enforce : Bool)
    (evidenceText : Option String := none) (staged : List Value := []) :
    IO (Option Handoff) :=
  /-
  Matching may be expensive, but the lock is per Codex session. This makes
  graph novelty, byte-budget admission, and state publication one atomic
  semi-naive step while unrelated sessions remain fully parallel.
  -/
  withSession session fun files => do
    let some initial ← (readJson? files.state : IO (Option ThreadState)) |
      pure none
    if pending.projection != .automatic || pending.read.isEmpty then pure none
    else
      let handoff ← automaticHandoff (pendingSelection pending) work
        initial.deliveredGraphs enforce evidenceText staged (!initial.afterCompaction)
        pending.localUnion
      match handoff with
      | none => pure none
      | some handoff =>
          match recordHandoffWithin pending.handoffChars initial handoff with
          | none => pure none
          | some next =>
              writeJson files.state next
              pure (some handoff)

inductive PreToolState where
  | ignore
  | reserved (pending : PendingTurn)

inductive PostToolState where
  | ignore
  | completed (pending : PendingTurn)

def preToolUse (input : Json) : IO String := do
  let session ← IO.ofExcept (requiredString input "session_id")
  let turn ← IO.ofExcept (requiredString input "turn_id")
  let tool ← IO.ofExcept (toolFromHook input false)
  let preflight ← withSession session fun files => do
    let some pending ← (readJson? files.pending : IO (Option PendingTurn)) |
      pure PreToolState.ignore
    if pending.turnId != turn || pending.finalMessage.isSome then
      pure PreToolState.ignore
    else
      let reserved := reserveTool pending tool
      writeJson files.pending reserved
      pure (.reserved reserved)
  match preflight with
  | .ignore => pure emptyHook
  | .reserved pending =>
      try
        let staged ← IO.ofExcept (stagedGraphValues pending)
        let handoff ← deliverForWork session pending
          (canonicalToolWork tool) true none staged
        if handoff.any (·.blocksCurrent) then
          withSession session fun files => do
            if let some current ← (readJson? files.pending : IO (Option PendingTurn)) then
              if current.turnId = turn then
                writeJson files.pending (cancelTool current tool.useId)
          let text := handoff.map (·.text) |>.getD ""
          let fragments := handoff.map (fun candidate =>
            candidate.coveredFragments)
            |>.getD [] |>.map fun fragment =>
            "- " ++ treeWork (.text fragment)
          let matched := if fragments.isEmpty then "" else
            "\n\nREMOVE ONLY THESE COMPLETED FRAGMENTS:\n" ++
              "\n".intercalate fragments ++
              "\nEVERY OTHER SUBCOMMAND, PATH, SYMBOL, RANGE, AND REQUESTED FACT REMAINS OPEN."
          let instruction :=
            "Eggshell found completed prior native Work before this operation ran. Replan " ++
            "the call to omit only the covered Work and issue any genuinely uncovered " ++
            "remainder. Do not repeat covered Work merely to verify, cite, narrow, " ++
            "reformat, or reconstruct it."
          pure <| hookDeny (instruction ++ matched ++ "\n\n" ++
            (if text = "" then
              "The Outcome is already present in this native context; Eggshell did not resend it."
            else "Newly connected prior graph:\n\n" ++ text))
        else
          let text := handoff.map (·.text) |>.getD ""
          pure <| if text = "" then emptyHook else hookContext "PreToolUse" text
      catch error =>
        withSession session fun files => do
          if let some current ← (readJson? files.pending : IO (Option PendingTurn)) then
            if current.turnId = turn then
              writeJson files.pending (cancelTool current tool.useId)
        throw error

def postToolUse (input : Json) : IO String := do
  let session ← IO.ofExcept (requiredString input "session_id")
  let turn ← IO.ofExcept (requiredString input "turn_id")
  let tool ← IO.ofExcept (toolFromHook input true)
  let postflight ← withSession session fun files => do
    let some pending ← (readJson? files.pending : IO (Option PendingTurn)) |
      pure PostToolState.ignore
    if pending.turnId != turn || pending.finalMessage.isSome then
      pure PostToolState.ignore
    else
      let pending := finishTool pending tool
      writeJson files.pending pending
      pure (.completed pending)
  match postflight with
  | .ignore => pure emptyHook
  | .completed pending =>
      try
        let handoff ← deliverForWork session pending
          (canonicalToolWork tool) false
          (if tool.response.trimAscii.isEmpty then none else some (canonicalJson tool.response))
        let text := handoff.map (·.text) |>.getD ""
        pure <| if text = "" then emptyHook else hookContext "PostToolUse" text
      catch error =>
        IO.eprintln s!"Eggshell recorded the native result but omitted its handoff: {error}"
        pure emptyHook

def postCompact (input : Json) : IO String := do
  let session ← IO.ofExcept (requiredString input "session_id")
  withSession session fun files => do
    if let some state ← (readJson? files.state : IO (Option ThreadState)) then
      writeJson files.state {
        state with
        deliveredGraphs := []
        afterCompaction := true
        lastHandoff := ""
        lastReason := "compacted; graph may be resent"
      }
    pure emptyHook

def stop (input : Json) : IO String := do
  let session ← IO.ofExcept (requiredString input "session_id")
  let turn := optionalString input "turn_id"
  let finalMessage ← IO.ofExcept (requiredString input "last_assistant_message")
  let sealed ← withSession session fun files => do
    if let some pending ← (readJson? files.pending : IO (Option PendingTurn)) then
      if matchesHookTurn pending turn then
        let pending := {
          pending with
          finalMessage := some finalMessage
          /-
          PreToolUse is only a transient duplicate-execution reservation.
          A missing PostToolUse has no observed result and therefore contributes
          no Outcome, but it cannot invalidate completed siblings or the parent
          turn.  Stop discards precisely those unresolved reservations.
          -/
          inFlight := []
        }
        writeJson files.pending pending
        return some pending
    pure none
  if let some pending := sealed then
    if let some command := pending.semanticMatcher then
      SemanticMatcher.enqueueWork command (.text pending.prompt) pending.prompt
  pure emptyHook

def sessionEnd (input : Json) : IO String := do
  let session ← IO.ofExcept (requiredString input "session_id")
  withSession session fun files => do
    let some state ← (readJson? files.state : IO (Option ThreadState)) | pure emptyHook
    let some pending ← (readJson? files.pending : IO (Option PendingTurn)) | pure emptyHook
    if pending.finalMessage.isSome then
      let state ← resolveDefault files state pending
      writeJson files.state state
    else if pending.finalMessage.isNone then
      removeIfExists files.pending
    pure emptyHook

def dispatchHook (input : Json) : IO String := do
  let event ← IO.ofExcept (requiredString input "hook_event_name")
  match event with
  | "SessionStart" => sessionStart input
  | "UserPromptSubmit" => userPromptSubmit input
  | "PreToolUse" => preToolUse input
  | "PostToolUse" => postToolUse input
  | "PostCompact" => postCompact input
  | "Stop" => stop input
  | "SessionEnd" => sessionEnd input
  | other => throw (IO.userError s!"unsupported Codex hook {other}")

def codexHook : IO UInt32 := do
  let inputText ← (← IO.getStdin).readToEnd
  match Json.parse inputText with
  | .error message =>
      IO.eprintln s!"Eggshell ignored malformed hook input: {message}"
      IO.println emptyHook
      pure 0
  | .ok input =>
      try
        IO.println (← dispatchHook input)
        pure 0
      catch error =>
        IO.eprintln s!"Eggshell hook failed open: {error}"
        IO.println emptyHook
        pure 0

end Eggshell.Plugin
