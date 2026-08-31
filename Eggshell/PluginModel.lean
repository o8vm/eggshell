module

public import Eggshell.Config
public import Lean.Data.Json.FromToJson

@[expose] public section

namespace Eggshell.Plugin

open Lean

inductive Projection where
  | automatic
  | none
  | roots (values : List String)
  deriving Repr, DecidableEq, ToJson, FromJson

structure ThreadState where
  profile : String
  nextProfile : Option String := none
  nextProjection : Option Projection := none
  deliveredGraphs : List String := []
  /-- Native history may have discarded previously visible staged Outcomes. -/
  afterCompaction : Bool := false
  lastHandoff : String := ""
  lastReason : String := ""
  deriving Repr, ToJson, FromJson

structure ToolEvent where
  name : String
  useId : String
  input : String
  response : String
  deriving Repr, ToJson, FromJson

structure PendingTurn where
  sessionId : String
  turnId : String
  cwd : String
  prompt : String
  profile : String
  semanticMatcher : Option (List String)
  read : List String
  write : Option String
  handoffChars : Nat
  localUnion : Bool := true
  projection : Projection
  /--
  Native occurrences awaiting a possible PostToolUse result. Codex may omit the
  terminal hook, so this state is correlation only and never execution authority.
  -/
  inFlight : List ToolEvent := []
  tools : List ToolEvent := []
  finalMessage : Option String := none
  deriving Repr, ToJson, FromJson

structure Promotion where
  outcomeRelations : List Value

structure SessionFiles where
  directory : System.FilePath
  state : System.FilePath
  pending : System.FilePath
  lock : System.FilePath

def safeSession (session : String) : Except String String :=
  if session != "" && session.toList.all fun character =>
      character.isAlphanum || character == '-' || character == '_' then
    pure session
  else throw "Codex session ID contains a path-unsafe character"

/--
Shared control-plane state must be visible to both Codex hooks and `!egg`.
`PLUGIN_DATA` is hook-only on some hosts, so using it would split one session
across two directories. This root stores session state, daemon coordination,
and disposable matcher data; project-selected `.egg` authorities remain the
per-turn paths snapshotted in `PendingTurn`.
-/
def dataRoot : IO System.FilePath := do
  let root ← match ← IO.getEnv "EGGSHELL_DATA_ROOT" with
    | some root => pure (System.FilePath.mk root)
    | none =>
        match ← IO.getEnv "HOME" with
        | some home => pure (System.FilePath.mk home / ".local" / "share" /
            "eggshell" / "plugin")
        | none => throw (IO.userError "EGGSHELL_DATA_ROOT and HOME are unavailable")
  if !root.isAbsolute then
    throw (IO.userError "EGGSHELL_DATA_ROOT must be an absolute path")
  pure root.normalize

def sessionFiles (session : String) : IO SessionFiles := do
  let safe ← match safeSession session with
    | .ok safe => pure safe
    | .error message => throw (IO.userError message)
  let directory := (← dataRoot) / "sessions" / safe
  pure {
    directory
    state := directory / "state.json"
    pending := directory / "pending.json"
    lock := directory / "state"
  }

def readJson? [FromJson α] (path : System.FilePath) : IO (Option α) := do
  if !(← path.pathExists) then pure none
  else
    let text ← IO.FS.readFile path
    let parsed ← match Json.parse text with
      | .ok json => pure json
      | .error message => throw (IO.userError s!"{path}: {message}")
    match fromJson? parsed with
    | .ok value => pure (some value)
    | .error message => throw (IO.userError s!"{path}: {message}")

def writeJson [ToJson α] (path : System.FilePath) (value : α) : IO Unit := do
  if let some parent := path.parent then Persistence.privateDirectory parent
  let temporary := System.FilePath.mk (path.toString ++ ".tmp")
  IO.FS.writeFile temporary (toJson value |>.compress)
  Persistence.privateFile temporary
  IO.FS.rename temporary path
  Persistence.privateFile path

def removeIfExists (path : System.FilePath) : IO Unit := do
  if ← path.pathExists then IO.FS.removeFile path

def withSession (session : String) (action : SessionFiles → IO α) : IO α := do
  let files ← sessionFiles session
  Persistence.privateDirectory files.directory
  Persistence.withLock files.lock (action files)

def valueEncoding (value : Value) : String :=
  Persistence.valueToJson value |>.compress

def valueKey (value : Value) : String :=
  "v" ++ toString (hash (Persistence.valueToJson value))

def allNodes (composite : Persistence.Composite) : List Value :=
  composite.values.flatMap Value.nodes |>.eraseDups

def resolveKey (composite : Persistence.Composite) (key : String) : Except String Value :=
  match (allNodes composite).filter (valueKey · == key) with
  | [value] => pure value
  | [] => throw s!"unknown Value {key}"
  | _ => throw s!"ambiguous display key {key}; inspect the full graph"

/-
Native JSON is identity-bearing data, not display framing. Lean's JSON object is
an ordered map, so parse-and-compress preserves keys, types, containers, array
order, and null while making object-key order irrelevant.
-/
def canonicalJson (encoded : String) : String :=
  match Json.parse encoded with
  | .ok json => json.compress
  | .error _ => encoded

/--
The whole native invocation remains the reservation identity. Object-key order
is normalized, while every semantic distinction in the native input is retained.
-/
def canonicalToolWork (tool : ToolEvent) : String :=
  tool.name ++ "\n" ++ canonicalJson tool.input

/--
Remember an admitted native occurrence for later PostToolUse correlation.
Reservations never control execution because Codex does not emit a terminal
hook for every failed or externally blocked tool.
-/
def reserveTool (pending : PendingTurn) (tool : ToolEvent) : PendingTurn :=
  { pending with
    inFlight := pending.inFlight.filter (·.useId != tool.useId) ++ [tool] }

/-- Close exactly one native occurrence and retain one completed tool record. -/
def finishTool (pending : PendingTurn) (tool : ToolEvent) : PendingTurn :=
  { pending with
    inFlight := pending.inFlight.filter (fun current => current.useId != tool.useId)
    tools := pending.tools.filter (fun current => current.useId != tool.useId) ++ [tool] }

/-- A denied or failed PreToolUse releases only its own transient reservation. -/
def cancelTool (pending : PendingTurn) (useId : String) : PendingTurn :=
  { pending with inFlight := pending.inFlight.filter (·.useId != useId) }

/-- A session owns one pending turn; an omitted hook turn ID denotes that turn. -/
def matchesHookTurn (pending : PendingTurn) : Option String → Bool
  | none => true
  | some turn => turn == pending.turnId

@[simp] theorem matchesHookTurn_omitted (pending : PendingTurn) :
    matchesHookTurn pending none = true := rfl

theorem cancelTool_removes_useId (pending : PendingTurn) (useId : String) :
    (cancelTool pending useId).inFlight.all (·.useId != useId) := by
  simp [cancelTool]

def relation? (operator : Operator) (arguments : List Ref) : Except String Value :=
  match Relation.apply? operator arguments with
  | some relation => pure relation
  | none => throw s!"invalid {Persistence.operatorName operator} relation"

/-- One native invocation owns exactly one observed Work→Outcome edge. -/
def observedWorkOutcome (work observed occurrence : Value) : Value × Value :=
  let edge := OutcomeEdge.make work observed [occurrence]
    (by simp) (by simp [maxOutcomeObservations])
  (work, edge.relation)

@[simp]
theorem observedWorkOutcome_work (work observed occurrence : Value) :
    (observedWorkOutcome work observed occurrence).1 = work := rfl

/--
One native occurrence cites its Work and Outcome once. Session, turn, and the
native tool-use ID are the exact occurrence identity; repeating the raw input
and response here would retain the same payload twice without adding authority.
-/
def nativeOccurrenceArguments (session turn : Value) (tool : ToolEvent) : List Ref :=
  [
    .semantic (.text (canonicalJson tool.response)),
    .semantic (.text (canonicalToolWork tool)),
    .exact session,
    .exact turn,
    .exact (.text tool.useId)]

def nativeOccurrence (session turn : Value) (tool : ToolEvent) : Value :=
  .applyList .occurrence (nativeOccurrenceArguments session turn tool)

theorem nativeOccurrence_valid (session turn : Value) (tool : ToolEvent) :
    Relation.validArguments .occurrence
      (nativeOccurrenceArguments session turn tool) := by
  have semantic : (Authority.semantic == Authority.semantic) = true := by decide
  have exact : (Authority.exact == Authority.semantic) = false := by decide
  simp [nativeOccurrenceArguments, Relation.validArguments,
    Relation.splitOccurrence, Relation.semanticValues, Relation.exactValues,
    Ref.semantic, Ref.exact, List.takeWhile, semantic, exact]

theorem nativeOccurrence_exactFootprint (session turn : Value) (tool : ToolEvent) :
    (nativeOccurrence session turn tool).exactFootprint =
      session :: session.exactFootprint ++
      turn :: turn.exactFootprint ++ [.text tool.useId] := by
  simp [nativeOccurrence, nativeOccurrenceArguments, Value.applyList,
    Refs.ofList, Value.exactFootprint, Value.refsExactFootprint,
    Ref.semantic, Ref.exact, Value.text]

/-
Native tool facts have one compiler regardless of whether they are still
staged or are being promoted.  The active turn can therefore join the same
run-local WorkGraph as committed `.egg` authorities without inventing a
second trace format or granting the stage persistent authority.
-/
def compileOperationOutcomes (session turn : Value) (tool : ToolEvent) :
    Value × Value :=
  let work := Value.text (canonicalToolWork tool)
  let observed := Value.text (canonicalJson tool.response)
  observedWorkOutcome work observed (nativeOccurrence session turn tool)

def compileOperationGraph (pending : PendingTurn) : Except String (List Value × Value) := do
  let session := Value.text pending.sessionId
  let turn := Value.text pending.turnId
  let facts := pending.tools.map (compileOperationOutcomes session turn)
  let task := Value.text pending.prompt
  let remainder := HandoffRemainder.value pending.prompt
  let works := facts.map (·.1) |>.eraseDups
  let all ← relation? .all
    (.semantic task :: (works ++ [remainder]).map Ref.semantic)
  pure (facts.map (·.2), all)

/-- The active turn joins the same positive graph shape later promoted to `.egg`. -/
def stagedGraphValues (pending : PendingTurn) : Except String (List Value) := do
  let (outcomes, all) ← compileOperationGraph pending
  pure (outcomes ++ [all])

structure CompiledTurn (source : Graph) where
  transaction : Transaction
  promotion : Promotion
  transaction_authority : transaction.authority = source.authority
  transaction_revision : transaction.baseRevision = source.revision

def compile (graph : Graph) (pending : PendingTurn) (target : String) :
    Except String (CompiledTurn graph) := do
  let finalMessage ← match pending.finalMessage with
    | some message => pure message
    | none => throw "cannot promote an unsealed turn"
  let session := Value.text pending.sessionId
  let turn := Value.text pending.turnId
  let cwd := Value.text pending.cwd
  let task := Value.text pending.prompt
  let result := Value.text finalMessage
  let (outcomeRelations, all) ← compileOperationGraph pending
  let turnOccurrence ← relation? .occurrence [
    .semantic task, .semantic result, .exact session, .exact turn, .exact cwd]
  let parentOutcome ← relation? .outcome [
    .semantic task, .semantic result, .exact turnOccurrence]
  let targetValue := Value.text target
  let receipt ← relation? .receipt [
    .exact session, .exact turn, .exact task, .exact result,
    .exact parentOutcome, .exact all, .exact targetValue]
  /-
  Only authoritative relation roots are stored. Their structural Values contain
  every Atom and occurrence, so duplicating that closure as top-level records
  changes no semantics and only inflates `.egg`.
  -/
  let values := (outcomeRelations ++ [all, parentOutcome, receipt]).eraseDups
  match accepted : (Transaction.begin graph).stageValues? values with
  | none => throw "turn compiler produced an invalid Value"
  | some transaction =>
      have source := Transaction.stageValues?_preserves_source accepted
      pure {
        transaction
        promotion := {
          outcomeRelations := outcomeRelations ++ [parentOutcome]
        }
        transaction_authority := source.1
        transaction_revision := source.2
      }

theorem compiled_transaction_belongs_to_source {graph pending target compiled}
    (_accepted : compile graph pending target = .ok compiled) :
    compiled.transaction.authority = graph.authority ∧
      compiled.transaction.baseRevision = graph.revision :=
  ⟨compiled.transaction_authority, compiled.transaction_revision⟩

theorem compiled_values_are_well_formed {graph : Graph}
    (compiled : CompiledTurn graph) :
    ∀ value, value ∈ compiled.transaction.stagedValues →
      Relation.wellFormed value :=
  compiled.transaction.stagedValues_wellFormed

def promote (pending : PendingTurn) (target : System.FilePath) : IO Promotion := do
  let (_, promotion) ← Persistence.update target fun graph => do
    let compiled ← compile graph pending target.toString
    pure (compiled.transaction, compiled.promotion)
  pure promotion

end Eggshell.Plugin
