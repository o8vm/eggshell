module

public import Eggshell.Handoff
public import Std.Sync.Mutex

@[expose] public section

namespace Eggshell.Plugin.Worker

open Lean

abbrev Child := IO.Process.Child { stdin := .piped, stdout := .piped, stderr := .null }

structure Slot where
  gate : Std.Mutex Unit
  child : Std.Mutex (Option Child)

initialize slots : Std.Mutex (List (String × Slot)) ← Std.Mutex.new []

def slotFor (session role : String) : IO Slot := slots.atomically do
  let key := session ++ ":" ++ role
  if let some (_, slot) := (← get).find? (·.1 == key) then return slot
  let slot := { gate := ← Std.Mutex.new (), child := ← Std.Mutex.new none }
  modify ((key, slot) :: ·)
  pure slot

/-- Only children created by this module with setsid are process-group leaders. -/
def killGroup (child : Child) : IO Unit := do
  let killer ← IO.Process.spawn {
    cmd := "/bin/kill", args := #["-KILL", "--", "-" ++ toString child.pid]
    stdin := .null, stdout := .null, stderr := .null }
  let _ ← killer.wait
  try child.kill catch _ => pure ()

def cancel (session role : String) : IO Unit := do
  let slot ← slotFor session role
  let idle ← slot.gate.tryAtomically (pure ())
  if idle.isSome then return
  slot.child.atomically do
    if let some child ← get then killGroup child

def retire (slot : Slot) (child : Child) : IO Unit := slot.child.atomically do
  if let some current ← get then
    if current.pid == child.pid then
      killGroup child
      let _ ← child.wait
      set (none : Option Child)

partial def awaitUntil (task : Task (Except IO.Error α)) (deadline : Nat) : IO (Option α) := do
  if ← IO.hasFinished task then
    match ← IO.wait task with
    | .ok value => return some value
    | .error error => throw error
  if (← IO.monoMsNow) ≥ deadline then return none
  IO.sleep 5
  awaitUntil task deadline

/-- No queue behind a busy search. The deadline covers pipe writes and reads. -/
def exchange (session role : String) (payload : Json) (deadline : Nat) : IO (Option Json) := do
  let slot ← slotFor session role
  let result ← slot.gate.tryAtomically do
    if (← IO.monoMsNow) ≥ deadline then return none
    let child ← slot.child.atomically do
      match ← get with
      | some child => pure child
      | none =>
          let child ← IO.Process.spawn {
            cmd := (← IO.appPath).toString, args := #["codex-worker", role]
            stdin := .piped, stdout := .piped, stderr := .null, setsid := true }
          set (some child)
          pure child
    try
      let task ← IO.asTask (do
        child.stdin.putStr (payload.compress ++ "\n")
        child.stdin.flush
        let line ← child.stdout.getLine
        IO.ofExcept (Json.parse line)) .dedicated
      let result ← if role == "save" then do
        match ← IO.wait task with
        | .ok json => pure (some json)
        | .error error => throw error
        else awaitUntil task deadline
      match result with
      | some json => return some json
      | none =>
          retire slot child
          let _ ← IO.wait task
          return none
    catch error =>
      retire slot child
      IO.eprintln s!"Eggshell {role} worker stopped: {error}"
      return none
  pure (result.bind id)

def shutdown : IO Unit := slots.atomically do
  for (_, slot) in ← get do
    let child ← slot.child.atomically get
    if let some child := child then retire slot child
  set ([] : List (String × Slot))

structure Search where
  pending : PendingTurn
  state : ThreadState
  work : String
  enforce : Bool
  evidence : Option String := none
  staged : Bool := false
  deriving ToJson, FromJson

def search (request : Search) : IO (Option Handoff) := do
  let selection := pendingSelection request.pending
  match request.pending.projection with
  | .none => pure none
  | .roots keys => manualHandoff selection request.work keys
  | .automatic =>
      let files ← sessionFiles request.pending.sessionId
      let mut staged := []
      -- Unsaved observations remain reusable even while a writer is busy or
      -- the authority is temporarily unavailable. Read them before the .egg
      -- snapshot, so a concurrent completed commit cannot create a gap.
      for name in ["deferred", "checkpoints"] do
        let directory := files.directory / name
        if ← directory.pathExists then
          for entry in ← directory.readDir do
            if entry.fileName.endsWith ".json" then
              try
                if let some base ← (readJson? entry.path pendingJsonDefaults : IO (Option PendingTurn)) then
                  if base.write.any request.pending.read.contains then
                    let pending ← loadToolReceipts files base
                    let values ← IO.ofExcept (stagedGraphValues pending)
                    staged := staged ++ values
              catch _ => pure ()
      if request.staged then
        let pending ← readPending? files
        let snapshot := pending.filter (·.turnId == request.pending.turnId)
        staged := staged ++ (← IO.ofExcept (stagedGraphValues (snapshot.getD request.pending)))
      staged := staged.eraseDups
      automaticHandoff selection request.work request.state.deliveredGraphs
        request.enforce request.evidence staged (!request.state.afterCompaction)
        request.pending.localUnion

def run (role : String) : IO UInt32 := do
  let input ← IO.getStdin
  let output ← IO.getStdout
  repeat
    let line ← input.getLine
    if line.isEmpty then break
    let result ← try
      let json ← IO.ofExcept (Json.parse line)
      if role == "search" then
        let request ← IO.ofExcept (fromJson? json : Except String Search)
        pure (toJson (← search request))
      else if role == "save" then
        let session ← IO.ofExcept (json.getObjValAs? String "session")
        let path := System.FilePath.mk (← IO.ofExcept (json.getObjValAs? String "path"))
        let files ← sessionFiles session
        let some base ← (readJson? path pendingJsonDefaults : IO (Option PendingTurn)) |
          throw (IO.userError "queued turn disappeared")
        let checkpoint := path.parent.bind (·.fileName) == some "checkpoints"
        let pending ← if checkpoint && base.finalMessage.isNone then pure base
          else loadToolReceipts files base
        let keys ← if let some target := pending.write then do
          if pending.finalMessage.isNone && pending.tools.isEmpty then pure []
          else
            let promotion ← if checkpoint && pending.finalMessage.isNone then
                promoteObservations pending (.mk target)
              else promote pending (.mk target)
            pure (promotion.outcomeRelations.map nativeHistoryKey)
          else pure []
        removeIfExists path

        pure (toJson keys)
      else throw (IO.userError "unknown worker role")
      catch error => pure (Json.mkObj [("error", error.toString)])
    output.putStr (result.compress ++ "\n")
    output.flush
  pure 0

end Eggshell.Plugin.Worker
