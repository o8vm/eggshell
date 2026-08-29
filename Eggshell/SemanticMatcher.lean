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

def eligibleCandidates (corpus : Matcher.Corpus) : List Matcher.Candidate :=
  corpus.candidates.filter fun candidate =>
    (Matcher.atomText? candidate.edge.work).isSome &&
      !corpus.subworks.contains candidate.edge.work

theorem eligibleCandidate_is_parent {corpus : Matcher.Corpus}
    {candidate : Matcher.Candidate}
    (eligible : candidate ∈ eligibleCandidates corpus) :
    corpus.subworks.contains candidate.edge.work = false := by
  have accepted := (List.mem_filter.mp eligible).2
  simp only [Bool.and_eq_true] at accepted
  simpa using accepted.2

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
  Matcher.atomText? candidate.edge.work |>.getD ""

/-- Stable cache key for rebuildable acceleration; it is never graph authority. -/
def contentKey (value : Value) : String :=
  Blake3.hex <| Blake3.digest "eggshell.semantic.embedding".toUTF8
    [Persistence.valueToJson value |>.compress |>.toUTF8]

def item (value : Value) (text : String) : Item :=
  { id := contentKey value, text }

def parentOutcomes (graph : WorkGraph) : List OutcomeEdge :=
  graph.outcomes.filter fun edge => !graph.subworks.contains edge.work

theorem parentOutcome_is_not_subwork {graph : WorkGraph} {edge : OutcomeEdge}
    (member : edge ∈ parentOutcomes graph) :
    graph.subworks.contains edge.work = false := by
  simpa [parentOutcomes] using (List.mem_filter.mp member).2

def outcomeWorkItems (values : List Value) : List Item :=
  let graph := WorkGraph.fromValues values
  (parentOutcomes graph).filterMap (fun edge => do
    let text ← Matcher.atomText? edge.work
    pure (item edge.work text)) |>.eraseDups

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
Queues immutable parent Work after a turn is sealed without fabricating a
staged Outcome. Native children remain in the kernel graph and are reached by
positive resaturation after a parent nomination. The cache may outlive a later
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
          item candidate.edge.work (candidateText candidate)
      }
      set (some running)
      pure (nominations candidates response)
    catch error =>
      stop running
      set (none : Option Running)
      IO.eprintln s!"eggshell: semantic matcher unavailable: {error}"
      pure {}

end Eggshell.SemanticMatcher
