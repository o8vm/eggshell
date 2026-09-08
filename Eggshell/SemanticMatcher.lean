module

public import Eggshell.Blake3
public import Eggshell.Matcher
public import Lean.Data.Json.FromToJson
public import Std.Sync.Mutex

@[expose] public section

namespace Eggshell.SemanticMatcher

open Lean

structure Item where
  id : String
  text : String
  deriving ToJson, BEq

structure Request where
  query : Item
  candidates : List Item
  deriving ToJson

structure IndexRequest where
  index : List Item
  deriving ToJson

structure Response where
  related : List Nat
  deriving FromJson

/-- Prefer a completed turn's synthesis; retain searchable observations when
    interruption left its parent without an Outcome. Similarity stays advisory. -/
def eligibleCandidates (corpus : Matcher.Corpus) : List Matcher.Candidate :=
  corpus.candidates.filter fun candidate =>
    (Matcher.atomText? candidate.edge.work).isSome &&
      !(corpus.parents.any fun parent =>
        parent.children.contains candidate.edge.work &&
          corpus.candidates.any fun owner => owner.edge.work == parent.parent)

def relations (candidates : List Matcher.Candidate)
    (indices : List Nat) : List Value :=
  indices.eraseDups.filterMap fun index => do
    let candidate ← candidates[index]?
    pure candidate.edge.relation

/-- Invalid or invented indexes resolve to no relation. -/
theorem relations_subset_candidate_owners {candidates : List Matcher.Candidate}
    {indices : List Nat} {relation : Value}
    (member : relation ∈ relations candidates indices) :
    ∃ candidate ∈ candidates, candidate.edge.relation = relation := by
  simp only [relations, List.mem_filterMap] at member
  obtain ⟨index, _, resolved⟩ := member
  change candidates[index]?.bind (fun candidate =>
    some candidate.edge.relation) = some relation at resolved
  rw [Option.bind_eq_some_iff] at resolved
  obtain ⟨candidate, present, equal⟩ := resolved
  simp only [Option.some.injEq] at equal
  exact ⟨candidate, List.mem_of_getElem? present, equal⟩

def processStdio : IO.Process.StdioConfig := {
  stdin := .piped
  stdout := .piped
  stderr := .null
}

abbrev Child := IO.Process.Child processStdio

structure Running where
  command : List String
  child : Child

initialize process : Std.Mutex (Option Running) ← Std.Mutex.new none

def start : List String → IO Running
  | [] => throw (IO.userError "semantic_matcher must name an executable")
  | executable :: arguments => do
      let child : Child ← IO.Process.spawn {
        cmd := executable
        args := arguments.toArray
        stdin := .piped
        stdout := .piped
        stderr := .null
      }
      pure { command := executable :: arguments, child }

def stop (running : Running) : IO Unit := do
  try running.child.kill catch _ => pure ()

def runningFor (previous : Option Running) (command : List String) : IO Running :=
  match previous with
  | some running => do
      let exited ← running.child.tryWait
      if running.command = command && exited.isNone then pure running
      else
        stop running
        start command
  | none => start command

def readLine (running : Running) : IO String := do
  let response ← IO.asTask running.child.stdout.getLine .dedicated
  let timeout ← IO.asTask (do
    IO.sleep 15000
    throw (IO.userError "semantic matcher timed out")) .dedicated
  match ← IO.waitAny [response, timeout] with
  | .ok line => pure line
  | .error error => throw error

def exchange (running : Running) (request : Request) : IO Response := do
  running.child.stdin.putStr ((toJson request).compress ++ "\n")
  running.child.stdin.flush
  let line ← readLine running
  let json ← match Json.parse line with
    | .ok json => pure json
    | .error message => throw (IO.userError s!"semantic matcher: {message}")
  match (fromJson? json : Except String Response) with
  | .ok response => pure response
  | .error message => throw (IO.userError s!"semantic matcher: {message}")

def candidateText (candidate : Matcher.Candidate) : String :=
  (Matcher.atomText? candidate.edge.work |>.getD "") ++ "\n" ++
    (Matcher.atomText? candidate.edge.outcome |>.getD "")

/-- Stable cache key for rebuildable acceleration; it is never graph authority. -/
def contentKey (value : Value) : String :=
  Blake3.hex <| Blake3.digest "eggshell.semantic.embedding".toUTF8
    [Persistence.valueToJson value |>.compress |>.toUTF8]

def item (value : Value) (text : String) : Item :=
  { id := contentKey value, text }

def outcomeWorkItems (values : List Value) : List Item :=
  (eligibleCandidates (Matcher.Corpus.build LogicalText.logicalNormalizer
    (WorkGraph.fromValues values))).map fun candidate =>
      let text := candidateText candidate
      item (.text text) text

def nominations (candidates : List Matcher.Candidate)
    (response : Response) : Matcher.SemanticNominations := {
  related := relations candidates response.related
}

theorem nomination_has_corpus_owner {corpus : Matcher.Corpus}
    {response : Response} {relation : Value}
    (member : relation ∈
      (nominations (eligibleCandidates corpus) response).related) :
    ∃ candidate ∈ corpus.candidates, candidate.edge.relation = relation := by
  obtain ⟨candidate, eligible, equal⟩ := relations_subset_candidate_owners member
  exact ⟨candidate, (List.mem_filter.mp eligible).1, equal⟩

/--
Queues immutable text after a turn is sealed without fabricating a
staged Outcome. The cache may outlive a later
`drop`, but queries resolve IDs only against authoritative Outcome owners.
-/
def enqueueWork (command : List String) (work : Value) (text : String) : IO Unit := do
  process.atomically do
    let running ← runningFor (← get) command
    try
      let request : IndexRequest := { index := [item work text] }
      running.child.stdin.putStr ((toJson request).compress ++ "\n")
      running.child.stdin.flush
      set (some running)
    catch error =>
      stop running
      set (none : Option Running)
      IO.eprintln s!"eggshell: semantic matcher unavailable: {error}"

/--
Queries use only provider-ready vectors. One daemon-wide process is serialized
across concurrent hooks; a broken child is dropped and Codex continues.
-/
def nominate (command : List String) (query : Value) (queryText : String)
    (corpus : Matcher.Corpus) :
    IO Matcher.SemanticNominations :=
  let candidates := eligibleCandidates corpus
  if candidates.isEmpty then pure {} else process.atomically do
    let running ← runningFor (← get) command
    try
      let response ← exchange running {
        query := item query queryText
        candidates := candidates.map fun candidate =>
          let text := candidateText candidate
          item (.text text) text
      }
      set (some running)
      pure (nominations candidates response)
    catch error =>
      stop running
      set (none : Option Running)
      IO.eprintln s!"eggshell: semantic matcher unavailable: {error}"
      pure {}

end Eggshell.SemanticMatcher
