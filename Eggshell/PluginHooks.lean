module

public import Eggshell.Worker
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

def defaultState (config : Config.Config) : ThreadState :=
  { profile := config.defaultProfile }

def configFromHook (input : Json) (cwd : System.FilePath) : IO (Option Config.Config) := do
  let config? ← Config.loadWith cwd (optionalString input "_eggshell_config")
  config?.mapM fun config => do
    if config.semanticMatcherWasSet then pure config
    else
      pure { config with
        semanticMatcher := ← MiniLM.command (← Paths.installRoot)
          (← sessionFiles ((optionalString input "session_id").getD "cli")).directory }

def addDeliveredGraphs (state : ThreadState) (keys : List String) : ThreadState :=
  { state with deliveredGraphs := (state.deliveredGraphs ++ keys).eraseDups }

/-- Compaction forgets context delivery but retains evidence-specific checkpoints. -/
def compactState (state : ThreadState) : ThreadState := {
  state with
      epoch := state.epoch + 1
      offers := []
      deliveredGraphs := state.deliveredGraphs.filter (·.startsWith "d:")
      afterCompaction := true
      lastHandoff := ""
      lastReason := "compacted; graph may be resent without repeating a checkpoint" }

theorem compaction_preserves_checkpoint (state : ThreadState) (key : String)
    (present : key ∈ state.deliveredGraphs) (checkpoint : key.startsWith "d:" = true) :
    key ∈ (compactState state).deliveredGraphs := by
  simp [compactState, present, checkpoint]

def hookDeadline (input : Json) (budget : Nat := 20000) : IO Nat := do
  let now ← IO.monoMsNow
  pure <| min (now + budget)
    ((input.getObjValAs? Nat "_eggshell_deadline").toOption.getD (now + budget))

/-- Archive only metadata while holding the session lock. Receipts stay in place. -/
def deferPending (files : SessionFiles) (pending : PendingTurn) : IO Unit := do
  let key := SemanticMatcher.contentKey (.text pending.turnId)
  writeJson (files.directory / "deferred" / (key ++ ".json")) pending
  removeIfExists files.pending

/-- The journal is authoritative for observed events even if the native hook
    exits between recording a receipt and registering its save. This cursor is
    only an optimization: restarting a manager safely replays all receipts. -/
def reconcileToolReceipts (session : String) (files : SessionFiles)
    (cursor : IO.Ref (String × List String)) : IO Unit := do
  let pending ← withSession session fun files => do
    let some state ← readState? files | return none
    if !state.enabled then return none
    readPendingBase? files
  let some pending := pending | return
  let (turn, seen) ← cursor.get
  let mut seen := if turn == pending.turnId then seen else []
  let directory := toolDirectory files pending.turnId
  if ← directory.pathExists then
    for entry in ← directory.readDir do
      if !entry.fileName.endsWith ".json" || seen.contains entry.fileName then continue
      try
        if let some tool ← (readJson? entry.path : IO (Option ToolEvent)) then
          queueCheckpoint files {
            pending with tools := [tool], inFlight := [], finalMessage := none, closed := false }
          seen := entry.fileName :: seen
          cursor.set (pending.turnId, seen)
      catch error => IO.eprintln s!"Eggshell retained an unqueued tool receipt: {error}"

/-- Saving is isolated from search and never holds the session state lock. -/
def flushDeferred (session : String) (deadline : Nat)
    (cursor : Option (IO.Ref (String × List String)) := none) : IO Unit := do
  let files ← sessionFiles session
  try Persistence.withLockWithin (files.directory / "save") 0 do
    if let some cursor := cursor then reconcileToolReceipts session files cursor
    let mut entries := []
    for name in ["deferred", "checkpoints"] do
      let directory := files.directory / name
      if ← directory.pathExists then entries := entries ++ (← directory.readDir).toList
    for entry in entries.take 8 do
      if (← IO.monoMsNow) ≥ deadline then return
      if !entry.fileName.endsWith ".json" then continue
      let state ← withSession session fun files => readState? files
      if state.any (! ·.enabled) then return
      let epoch := state.map (·.epoch)
      let payload := Json.mkObj [("session", session), ("path", entry.path.toString)]
      let some result ← Worker.exchange session "save" payload deadline | return
      let .ok keys := (fromJson? result : Except String (List String)) |
        IO.eprintln s!"Eggshell retained uncommitted work: {result.compress}"
        continue
      -- A save can finish after compaction. Its graph remains valid on disk,
      -- but is not thereby evidence that the new native context contains it.
      withSession session fun files => do
        if let some state ← readState? files then
          if state.enabled && !state.afterCompaction && epoch == some state.epoch then
            writeJson files.state (addDeliveredGraphs state keys)
  catch error => IO.eprintln s!"Eggshell retained queued work: {error}"

def sessionStart (input : Json) : IO String := do
  let session ← IO.ofExcept (requiredString input "session_id")
  if optionalString input "source" = some "compact" then
    Worker.cancel session "search"
    withSession session fun files => do
      if let some state ← readState? files then
        if state.enabled then writeJson files.state (compactState state)
    return emptyHook
  else
    let cwd := System.FilePath.mk ((optionalString input "cwd").getD ".")
    let config ← configFromHook input cwd
    let state ← withSession session fun files => do
      let state ← readState? files
      if state.isNone then
        if let some config := config then
          let state := defaultState config
          writeJson files.state state
          return some state
      pure state
    let some config := config |
      return systemMessage "Eggshell memory is not configured for this project. Ask Codex: Set up Eggshell for this project."
    let some state := state | return emptyHook
    if !state.enabled then
      return systemMessage "Eggshell memory is off for this chat. Use !egg on only if you want to enable it."
    let selection ← IO.ofExcept (Config.resolve config state.profile)
    let mode := if selection.read.isEmpty && selection.write.isNone then "off"
      else if selection.write.isNone then "read-only" else "read/write"
    return systemMessage (s!"Eggshell session hook connected: memory {mode}, profile {state.profile}. " ++
      "Use !egg doctor to check setup; !egg graph shows context actually delivered.")

def acceptOffer (state : ThreadState) (turn : String) (now : Nat)
    (offer : DeliveryOffer) : ThreadState :=
  if state.enabled && offer.stamp.accepts turn state.epoch now then
    { (addDeliveredGraphs state offer.graphs) with
      lastHandoff := offer.text, lastReason := offer.reason }
  else state

theorem rejected_offer_changes_nothing (state : ThreadState) (turn : String)
    (now : Nat) (offer : DeliveryOffer)
    (rejected : offer.stamp.accepts turn state.epoch now = false) :
    acceptOffer state turn now offer = state := by
  simp [acceptOffer, rejected]

theorem disabled_memory_rejects_delivery (state : ThreadState) (turn : String)
    (now : Nat) (offer : DeliveryOffer) (disabled : state.enabled = false) :
    acceptOffer state turn now offer = state := by
  simp [acceptOffer, disabled]

def acknowledge (session id : String) : IO Unit := withSession session fun files => do
  let some state ← readState? files | return
  let some pending ← readPendingBase? files | return
  let now ← IO.monoMsNow
  let some offer := state.offers.find? (·.id == id) | return
  let state := { state with offers := state.offers.filter (·.id != id) }
  writeJson files.state (acceptOffer state pending.turnId now offer)

/-- Search results become offers only after checking the current turn and epoch. -/
def deliverForWork (input : Json) (pending : PendingTurn) (work : String)
    (enforce : Bool) (evidenceText : Option String := none) (staged : Bool := false) :
    IO (Option Handoff) := do
  let session := pending.sessionId
  let deadline ← hookDeadline input
  let snapshot ← withSession session fun files => do
    let some state ← readState? files | return none
    let some current ← readPendingBase? files | return none
    if !state.enabled || current.turnId != pending.turnId || (current.closed || current.finalMessage.isSome) then
      return none
    pure (some state)
  let some initial := snapshot | return none
  if pending.projection == .none || pending.read.isEmpty then return none
  let stamp : RequestStamp := { turn := pending.turnId, epoch := initial.epoch, deadline }
  let query : Worker.Search := {
    pending, state := initial, work, enforce, evidence := evidenceText, staged }
  let some result ← Worker.exchange session "search" (toJson query) deadline | return none
  let .ok (some handoff) := (fromJson? result : Except String (Option Handoff)) | return none
  if handoff.text.length > pending.handoffChars then return none
  withSession session fun files => do
    let some state ← readState? files | return none
    let some current ← readPendingBase? files | return none
    let now ← IO.monoMsNow
    if !state.enabled || (current.closed || current.finalMessage.isSome) ||
        !stamp.accepts current.turnId state.epoch now then return none
    -- Reserve only newly grounded evidence, rechecking under the state lock
    -- in case another hook used it during this search. Context delivery itself
    -- still requires the client's receipt.
    let checkpoints := handoff.deliveredGraphs.filter (·.startsWith "d:")
    let blocks := handoff.blocksCurrent &&
      checkpoints.any (!state.deliveredGraphs.contains ·)
    let handoff := { handoff with
      blocksCurrent := blocks
      reason := handoff.reason.replace "blocks-current=true" s!"blocks-current={blocks}" }
    let id := (optionalString input "_eggshell_receipt").getD "direct"
    let offer : DeliveryOffer := {
      id, stamp, graphs := handoff.deliveredGraphs, text := handoff.text, reason := handoff.reason }
    writeJson files.state {
      (addDeliveredGraphs state checkpoints) with
      offers := offer :: (state.offers.filter fun (offer : DeliveryOffer) =>
        offer.id != id && offer.stamp.accepts current.turnId state.epoch now).take 15 }
    pure (some handoff)

def userPromptSubmit (input : Json) : IO String := do
  let session ← IO.ofExcept (requiredString input "session_id")
  let turn ← IO.ofExcept (requiredString input "turn_id")
  let cwd := System.FilePath.mk (← IO.ofExcept (requiredString input "cwd"))
  let prompt ← IO.ofExcept (requiredString input "prompt")
  let some config ← configFromHook input cwd | return emptyHook
  let prepared ← withSession session fun files => do
    let mut state := (← readState? files).getD (defaultState config)
    if !state.enabled then return none
    if let some pending ← readPendingBase? files then
      if pending.turnId == turn then return none
      deferPending files pending
    let selection ← IO.ofExcept (Config.resolve config (state.nextProfile.getD state.profile))
    let pending : PendingTurn := {
      sessionId := session, turnId := turn, cwd := cwd.toString, prompt,
      profile := selection.label, semanticMatcher := selection.semanticMatcher,
      read := selection.read.map (·.path.toString), write := selection.write.map (·.path.toString),
      handoffChars := selection.handoffChars, localUnion := selection.localUnion,
      projection := state.nextProjection.getD .automatic }
    state := { state with
      epoch := state.epoch + 1
      offers := []
      deliveredGraphs := state.deliveredGraphs.filter (fun key => !key.startsWith "d:"),
      nextProfile := none, nextProjection := none }
    writeJson files.state state
    writeJson files.pending pending
    pure (some pending)
  let some pending := prepared | return emptyHook
  Worker.cancel session "search"
  let handoff ← deliverForWork input pending prompt false
  let context := handoff.map (·.text) |>.getD ""
  pure <| if context == "" then emptyHook else hookContext "UserPromptSubmit" context

def toolFromHook (input : Json) (withResponse : Bool) : Except String ToolEvent := do
  pure {
    name := ← requiredString input "tool_name"
    useId := ← requiredString input "tool_use_id"
    input := jsonField input "tool_input"
    response := if withResponse then jsonField input "tool_response" else ""
  }

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
    let some state ← readState? files |
      pure PreToolState.ignore
    if !state.enabled then
      do
        removeIfExists files.pending
        pure PreToolState.ignore
    else
      let some pending ← readPendingBase? files |
        pure PreToolState.ignore
      if pending.turnId != turn || (pending.closed || pending.finalMessage.isSome) then
        pure PreToolState.ignore
      else
        let reserved := reserveTool pending tool
        writeJson files.pending reserved
        pure (.reserved reserved)
  match preflight with
  | .ignore => pure emptyHook
  | .reserved pending =>
      try
        let handoff ← deliverForWork input pending
          (canonicalToolWork tool) true none true
        if handoff.any (·.blocksCurrent) then
          withSession session fun files => do
            if let some current ← readPendingBase? files then
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
          if let some current ← readPendingBase? files then
            if current.turnId = turn then
              writeJson files.pending (cancelTool current tool.useId)
        throw error

/-- Journal native results before contacting the manager or doing any search. -/
def captureTerminal (input : Json) : IO Unit := do
  if optionalString input "hook_event_name" != some "PostToolUse" then return
  let session ← IO.ofExcept (requiredString input "session_id")
  let turn ← IO.ofExcept (requiredString input "turn_id")
  let tool ← IO.ofExcept (toolFromHook input true)
  let files ← sessionFiles session
  -- These reads observe atomic metadata snapshots; no parser repair is done
  -- outside the state lock. Failure leaves the native receipt available.
  if let some state ← (readJson? files.state stateJsonDefaults : IO (Option ThreadState)) then
    if !state.enabled then return
  recordTool files turn tool
  if let some pending ← (readJson? files.pending pendingJsonDefaults : IO (Option PendingTurn)) then
    if pending.turnId == turn && !pending.closed && pending.finalMessage.isNone then
      queueCheckpoint files { pending with tools := [tool], inFlight := [] }

def postToolUse (input : Json) : IO String := do
  let session ← IO.ofExcept (requiredString input "session_id")
  let turn ← IO.ofExcept (requiredString input "turn_id")
  let tool ← IO.ofExcept (toolFromHook input true)
  let postflight ← withSession session fun files => do
    let some state ← readState? files |
      pure PostToolState.ignore
    if !state.enabled then
      do
        removeIfExists files.pending
        pure PostToolState.ignore
    else
      let some pending ← readPendingBase? files |
        pure PostToolState.ignore
      if pending.turnId != turn || (pending.closed || pending.finalMessage.isSome) then
        pure PostToolState.ignore
      else
        recordTool files turn tool
        queueCheckpoint files { pending with tools := [tool], inFlight := [] }
        let pending := cancelTool pending tool.useId
        writeJson files.pending pending
        let roots := observedRoots { pending with tools := [tool] }
        writeJson files.state (addDeliveredGraphs state (roots.map nativeHistoryKey))
        pure (.completed pending)
  match postflight with
  | .ignore => pure emptyHook
  | .completed pending =>
      try
        let handoff ← deliverForWork input pending
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
    if let some state ← readState? files then
      if state.enabled then writeJson files.state (compactState state)
  Worker.cancel session "search"
  pure emptyHook

def stop (input : Json) : IO String := do
  let session ← IO.ofExcept (requiredString input "session_id")
  let turn := optionalString input "turn_id"
  let finalMessage := optionalString input "last_assistant_message"
  withSession session fun files => do
    let some state ← readState? files | return
    if !state.enabled then return
    if let some pending ← readPendingBase? files then
      if matchesHookTurn pending turn then
        let sealed := { pending with finalMessage, closed := true, inFlight := [] }
        writeJson files.pending sealed
        queueCheckpoint files sealed
        writeJson files.state { state with epoch := state.epoch + 1, offers := [] }
  Worker.cancel session "search"
  pure emptyHook

def interrupt (input : Json) : IO String := do
  let session ← IO.ofExcept (requiredString input "session_id")
  withSession session fun files => do
    if let some state ← readState? files then
      writeJson files.state { state with epoch := state.epoch + 1, offers := [] }
  Worker.cancel session "search"
  pure emptyHook

def sessionEnd (input : Json) : IO String := do
  let session ← IO.ofExcept (requiredString input "session_id")
  withSession session fun files => do
    if let some pending ← readPendingBase? files then deferPending files pending
    if let some state ← readState? files then
      writeJson files.state { state with epoch := state.epoch + 1, offers := [] }
  Worker.cancel session "search"
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
  | "Interrupt" => interrupt input
  | "SessionEnd" => sessionEnd input
  | other => throw (IO.userError s!"unsupported Codex hook {other}")

end Eggshell.Plugin
