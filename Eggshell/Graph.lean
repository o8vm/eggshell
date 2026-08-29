module

public import Eggshell.Relation

@[expose] public section

namespace Eggshell

/-- A durable Union always names the single authority that owns it. -/
structure PersistentUnion (authority : Value) where
  edge : UnionEdge
  scope_eq : edge.scope = .workspace authority

namespace PersistentUnion

def make (authority left right : Value)
    (exactAuthority : Value.SameExactFootprint left right) :
    PersistentUnion authority where
  edge := {
    left
    right
    scope := .workspace authority
    exactAuthority
  }
  scope_eq := rfl

end PersistentUnion

/--
The authoritative graph. Values and observed relations grow monotonically;
only an explicitly named persistent equality may be corrected in place.
`revision` is concurrency metadata, not semantic identity.
-/
structure Graph where
  authority : Value
  revision : Nat
  values : List Value
  unions : List (PersistentUnion authority)
  values_wellFormed : ∀ value, value ∈ values → Relation.wellFormed value

namespace Graph

def empty (authority : Value) : Graph where
  authority
  revision := 0
  values := []
  unions := []
  values_wellFormed := by simp

/-- Human correction removes exactly one undirected equality pair, never data. -/
def removeUnionPair (graph : Graph) (left right : Value) : Graph :=
  { graph with
    revision := graph.revision + 1
    unions := graph.unions.filter fun persistent =>
      !persistent.edge.samePair left right }

@[simp]
theorem removeUnionPair_authority (graph : Graph) (left right : Value) :
    (graph.removeUnionPair left right).authority = graph.authority := rfl

@[simp]
theorem removeUnionPair_values (graph : Graph) (left right : Value) :
    (graph.removeUnionPair left right).values = graph.values := rfl

@[simp]
theorem removeUnionPair_revision (graph : Graph) (left right : Value) :
    (graph.removeUnionPair left right).revision = graph.revision + 1 := rfl

end Graph

/-- A private, uncommitted append-only suffix over one exact graph revision. -/
structure Transaction where
  authority : Value
  baseRevision : Nat
  stagedValues : List Value := []
  stagedUnions : List (PersistentUnion authority) := []
  stagedValues_wellFormed : ∀ value, value ∈ stagedValues →
    Relation.wellFormed value := by simp

namespace Transaction

def begin (graph : Graph) : Transaction where
  authority := graph.authority
  baseRevision := graph.revision

def stageValue (transaction : Transaction) (value : Value)
    (wellFormed : Relation.wellFormed value) : Transaction :=
  {
    transaction with
    stagedValues := transaction.stagedValues ++ [value]
    stagedValues_wellFormed := by
      intro candidate present
      simp only [List.mem_append, List.mem_singleton] at present
      cases present with
      | inl old => exact transaction.stagedValues_wellFormed candidate old
      | inr added => simpa [added] using wellFormed
  }

def stageValues? (transaction : Transaction) (values : List Value) :
    Option Transaction :=
  if valid : values.all Relation.wellFormed then
    some {
      transaction with
      stagedValues := transaction.stagedValues ++ values
      stagedValues_wellFormed := by
        intro candidate present
        simp only [List.mem_append] at present
        cases present with
        | inl old => exact transaction.stagedValues_wellFormed candidate old
        | inr added => exact (List.all_eq_true.mp valid) candidate added
    }
  else none

theorem stageValues?_preserves_source {transaction staged values}
    (accepted : stageValues? transaction values = some staged) :
    staged.authority = transaction.authority ∧
      staged.baseRevision = transaction.baseRevision := by
  unfold stageValues? at accepted
  split at accepted
  case isTrue =>
    simp only [Option.some.injEq] at accepted
    subst staged
    simp
  case isFalse => simp at accepted

def stageAll (transaction : Transaction) (edge : AllEdge)
    (wellFormed : Relation.wellFormed edge.relation) : Transaction :=
  transaction.stageValue edge.relation wellFormed

def stageOutcome (transaction : Transaction) (edge : OutcomeEdge)
    (wellFormed : Relation.wellFormed edge.relation) : Transaction :=
  transaction.stageValue edge.relation wellFormed

def stageUnion (transaction : Transaction) (left right : Value)
    (exactAuthority : Value.SameExactFootprint left right) : Transaction :=
  { transaction with stagedUnions := transaction.stagedUnions ++
      [PersistentUnion.make transaction.authority left right exactAuthority] }

/-- Identity and already-owned equality are facts, not new append-only events. -/
def stageUnionIfNew (graph : Graph) (transaction : Transaction) (left right : Value)
    (exactAuthority : Value.SameExactFootprint left right) : Transaction :=
  let existing := graph.unions.map (·.edge) ++ transaction.stagedUnions.map (·.edge)
  if UnionEdge.newPair existing left right then
    transaction.stageUnion left right exactAuthority
  else transaction

def appliesTo (transaction : Transaction) (graph : Graph) : Bool :=
  transaction.authority == graph.authority &&
    transaction.baseRevision == graph.revision

def isEmpty (transaction : Transaction) : Bool :=
  transaction.stagedValues.isEmpty && transaction.stagedUnions.isEmpty

def commit (graph : Graph) (transaction : Transaction)
    (sameAuthority : transaction.authority = graph.authority) : Graph :=
  {
    authority := graph.authority
    revision := graph.revision + 1
    values := (graph.values ++ transaction.stagedValues).eraseDups
    unions := graph.unions ++ sameAuthority ▸ transaction.stagedUnions
    values_wellFormed := by
      intro value present
      have original : value ∈ graph.values ++ transaction.stagedValues := by
        simpa using present
      simp only [List.mem_append] at original
      cases original with
      | inl old => exact graph.values_wellFormed value old
      | inr staged => exact transaction.stagedValues_wellFormed value staged
  }

def commitIfCurrent (graph : Graph) (transaction : Transaction) : Option Graph :=
  if authority : transaction.authority = graph.authority then
    if _revision : transaction.baseRevision = graph.revision then
      some (commit graph transaction authority)
    else none
  else none

def rollback (graph : Graph) (_transaction : Transaction) : Graph := graph

@[simp]
theorem rollback_exact (graph : Graph) (transaction : Transaction) :
    rollback graph transaction = graph := rfl

theorem commit_preserves_value {graph transaction sameAuthority value}
    (present : value ∈ graph.values) :
    value ∈ (commit graph transaction sameAuthority).values := by
  simp [commit, present]

theorem commit_contains_staged_value {graph transaction sameAuthority value}
    (present : value ∈ transaction.stagedValues) :
    value ∈ (commit graph transaction sameAuthority).values := by
  simp [commit, present]

theorem commit_advances_revision (graph transaction sameAuthority) :
    (commit graph transaction sameAuthority).revision = graph.revision + 1 := rfl

theorem commitIfCurrent_sound {graph transaction committed}
    (accepted : commitIfCurrent graph transaction = some committed) :
    transaction.authority = graph.authority ∧
      transaction.baseRevision = graph.revision := by
  unfold commitIfCurrent at accepted
  by_cases authority : transaction.authority = graph.authority
  · by_cases revision : transaction.baseRevision = graph.revision
    · exact ⟨authority, revision⟩
    · simp [authority, revision] at accepted
  · simp [authority] at accepted

theorem stale_transaction_rejected {graph transaction}
    (stale : transaction.baseRevision ≠ graph.revision) :
    commitIfCurrent graph transaction = none := by
  unfold commitIfCurrent
  by_cases authority : transaction.authority = graph.authority
  · simp [authority, stale]
  · simp [authority]

end Transaction

end Eggshell
