module

public import Eggshell.Extract
public import Std.Data.HashMap.Basic
public import Std.Data.HashMap.Lemmas

@[expose] public section

namespace Eggshell

/-- One checked equivalence class. The producer may be heuristic; this certificate is not. -/
structure EquivalenceClass where
  representative : Value
  members : List Value
  exactAuthority : ∀ member, member ∈ members →
    Value.SameExactFootprint member representative

namespace EquivalenceClass

def certify? : List Value → Option EquivalenceClass
  | [] => none
  | representative :: tail =>
      let members := representative :: tail
      if accepted : members.all
          (fun member => Value.sameExactFootprint member representative) then
        some {
          representative
          members
          exactAuthority := by
            intro member present
            apply Value.sameExactFootprint_sound
            exact (List.all_eq_true.mp accepted) member present
        }
      else none

end EquivalenceClass

namespace RepresentativeIndex

abbrev T := Std.HashMap Value Value

def Sound (index : T) : Prop :=
  ∀ value, Value.SameExactFootprint value (index.getD value value)

def insertMembers (representative : Value) : T → List Value → T
  | index, [] => index
  | index, member :: tail =>
      insertMembers representative (index.insert member representative) tail

def build : T → List EquivalenceClass → T
  | index, [] => index
  | index, equivalenceClass :: tail =>
      build (insertMembers equivalenceClass.representative index equivalenceClass.members) tail

theorem empty_sound : Sound ({} : T) := by
  intro value
  have lookup : ({} : T).getD value value = value := by
    apply Std.HashMap.getD_of_isEmpty
    exact Std.HashMap.isEmpty_emptyWithCapacity
  rw [lookup]
  exact Value.sameExactFootprint_refl value

theorem insert_sound {index : T} (sound : Sound index) {member representative : Value}
    (safe : Value.SameExactFootprint member representative) :
    Sound (index.insert member representative) := by
  intro value
  rw [Std.HashMap.getD_insert]
  split
  · rename_i same
    have equality : member = value := by simpa using same
    subst value
    exact safe
  · exact sound value

theorem insertMembers_sound {index : T} (sound : Sound index)
    {representative : Value} {members : List Value}
    (safe : ∀ member, member ∈ members →
      Value.SameExactFootprint member representative) :
    Sound (insertMembers representative index members) := by
  induction members generalizing index with
  | nil => exact sound
  | cons head tail induction =>
      apply induction (insert_sound sound (safe head (by simp)))
      intro member present
      exact safe member (by simp [present])

theorem build_sound {index : T} (sound : Sound index)
    (classes : List EquivalenceClass) : Sound (build index classes) := by
  induction classes generalizing index with
  | nil => exact sound
  | cons equivalenceClass tail induction =>
      apply induction
      exact insertMembers_sound sound equivalenceClass.exactAuthority

end RepresentativeIndex

structure Quotient where
  classes : List EquivalenceClass
  representatives : RepresentativeIndex.T
  exactAuthority : RepresentativeIndex.Sound representatives

namespace Quotient

def canonical (quotient : Quotient) (value : Value) : Value :=
  quotient.representatives.getD value value

def toEquality (quotient : Quotient) : Equality where
  same left right := decide (quotient.canonical left = quotient.canonical right)
  reflexive value := by simp [canonical]
  symmetric := by
    simp only [decide_eq_true_eq]
    exact Eq.symm
  transitive := by
    simp only [decide_eq_true_eq]
    exact Eq.trans
  preservesExact := by
    intro left right same
    simp only [decide_eq_true_eq] at same
    have middle : Value.SameExactFootprint
        (quotient.canonical left) (quotient.canonical right) := by
      rw [same]
      exact Value.sameExactFootprint_refl _
    exact Value.sameExactFootprint_trans (quotient.exactAuthority left)
      (Value.sameExactFootprint_trans middle
        (Value.sameExactFootprint_symm (quotient.exactAuthority right)))

@[simp]
theorem same_iff_canonical_eq (quotient : Quotient) {left right} :
    quotient.toEquality.same left right ↔
      quotient.canonical left = quotient.canonical right := by
  simp [toEquality]

theorem equality_preserves_exact (quotient : Quotient) {left right}
    (same : quotient.toEquality.same left right) :
    Value.SameExactFootprint left right :=
  quotient.toEquality.preservesExact same

end Quotient

namespace QuotientBuilder

abbrev RawClass := List Value
abbrev RawPartition := List RawClass

def initial (values : List Value) : RawPartition :=
  hashDistinct values |>.map (fun value => [value])

def same (partition : RawPartition) (left right : Value) : Bool :=
  left == right || partition.any fun equivalenceClass =>
    equivalenceClass.contains left && equivalenceClass.contains right

def takeClass (value : Value) : RawPartition → RawClass × RawPartition
  | [] => ([value], [])
  | equivalenceClass :: tail =>
      if equivalenceClass.contains value then (equivalenceClass, tail)
      else
        let (found, rest) := takeClass value tail
        (found, equivalenceClass :: rest)

def merge (partition : RawPartition) (left right : Value) : RawPartition :=
  if same partition left right then partition
  else
    let (leftClass, withoutLeft) := takeClass left partition
    let (rightClass, rest) := takeClass right withoutLeft
    hashDistinct (leftClass ++ rightClass) :: rest

def mergeExplicit (partition : RawPartition) (edges : List UnionEdge) : RawPartition :=
  edges.foldl (fun classes edge => merge classes edge.left edge.right) partition

abbrev Representatives := Std.HashMap Value Value

def representatives (partition : RawPartition) : Representatives :=
  partition.foldl (fun index equivalenceClass =>
    match equivalenceClass with
    | [] => index
    | representative :: _ => equivalenceClass.foldl
        (fun current member => current.insert member representative) index) {}

def normalizeRefs (index : Representatives) : Refs → Refs
  | .nil => .nil
  | .semantic value tail =>
      .semantic (index.getD value value) (normalizeRefs index tail)
  | .exact value tail => .exact value (normalizeRefs index tail)

@[simp]
theorem normalizeRefs_nil (index : Representatives) :
    normalizeRefs index .nil = .nil := rfl

@[simp]
theorem normalizeRefs_semantic (index : Representatives) (value : Value)
    (tail : Refs) :
    normalizeRefs index (.semantic value tail) =
      .semantic (index.getD value value) (normalizeRefs index tail) := rfl

/-- Congruence canonicalizes beneath Semantic authority, never Exact authority. -/
@[simp]
theorem normalizeRefs_exact (index : Representatives) (value : Value)
    (tail : Refs) :
    normalizeRefs index (.exact value tail) =
      .exact value (normalizeRefs index tail) := rfl

/-- Canonical structural signature under one equivalence snapshot. -/
def signature (index : Representatives) : Value → Value
  | atom@(.atom _) => atom
  | .apply operator arguments => .apply operator (normalizeRefs index arguments)

/--
Hash-consed congruence pass. Hashing only nominates a bucket; `HashMap` confirms
full structural equality, so collisions never enter semantic identity.
-/
def congruencePass (values : List Value) (partition : RawPartition) : RawPartition :=
  let index := representatives partition
  let (_, result) := values.foldl (fun (state : Std.HashMap Value Value × RawPartition) value =>
    let (seen, current) := state
    let key := signature index value
    match seen.get? key with
    | some prior => (seen, merge current prior value)
    | none => (seen.insert key value, current)) ({}, partition)
  result

def saturateCongruence (values : List Value) : Nat → RawPartition → RawPartition
  | 0, partition => partition
  | fuel + 1, partition =>
      let next := congruencePass values partition
      if next = partition then partition
      else saturateCongruence values fuel next

def certify (partition : RawPartition) : Option Quotient := do
  let classes ← partition.mapM EquivalenceClass.certify?
  let representatives := RepresentativeIndex.build {} classes
  pure {
    classes
    representatives
    exactAuthority := RepresentativeIndex.build_sound
      RepresentativeIndex.empty_sound classes
  }

def build? (roots : List Value) (persistent runLocal : List UnionEdge) : Option Quotient :=
  let values := (roots ++
    (persistent ++ runLocal).flatMap (fun edge =>
      edge.left.semanticNodes ++ edge.right.semanticNodes))
    |>.flatMap Value.semanticNodes |> hashDistinct
  let explicit := mergeExplicit (initial values) (persistent ++ runLocal)
  certify (saturateCongruence values values.length explicit)

/-- Even a heuristic Union producer cannot make the checked quotient cross Exact authority. -/
theorem build_equality_preserves_exact {roots persistent runLocal quotient}
    (_built : build? roots persistent runLocal = some quotient)
    {left right : Value} (same : quotient.toEquality.same left right) :
    Value.SameExactFootprint left right := by
  exact quotient.equality_preserves_exact same

end QuotientBuilder

/-- One run owns speculative equality; the durable graph is immutable here. -/
structure RunView where
  graph : WorkGraph
  quotient : Quotient
  localUnions : List UnionEdge

namespace RunView

def make? (graph : WorkGraph) (roots : List Value)
    (persistent runEdges : List UnionEdge) : Option RunView := do
  let quotient ← QuotientBuilder.build? roots persistent runEdges
  pure { graph, quotient, localUnions := runEdges }

def extract (view : RunView) (root : Value) : Extraction :=
  Extract.run view.graph view.quotient.toEquality root

def extractWith (view : RunView) (policy : OutcomePolicy) (root : Value) : Extraction :=
  Extract.runWithPolicy view.graph view.quotient.toEquality policy root

/-- Adding local identity cannot mutate durable graph facts by construction. -/
@[simp]
theorem graph_is_immutable (view : RunView) : view.graph = view.graph := rfl

end RunView

end Eggshell
