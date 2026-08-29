module

public import Std
public import Std.Data.HashMap.Basic

@[expose] public section

namespace Eggshell

/-- Stable first-occurrence deduplication; hashes nominate, lawful `BEq` decides. -/
def hashDistinct [BEq α] [Hashable α] (values : List α) : List α :=
  let (_, reversed) := values.foldl (fun (state : Std.HashMap α Unit × List α) value =>
    let (seen, result) := state
    if seen.contains value then (seen, result)
    else (seen.insert value (), value :: result)) ({}, [])
  reversed.reverse

/-- The complete semantic operator vocabulary. Roles are positions, never Atom kinds. -/
inductive Operator where
  | all
  | outcome
  | occurrence
  | inquiry
  | receipt
  deriving Repr, DecidableEq, BEq, Hashable

namespace Operator

def allValues : List Operator :=
  [.all, .outcome, .occurrence, .inquiry, .receipt]

theorem mem_allValues (operator : Operator) : operator ∈ allValues := by
  cases operator <;> simp [allValues]

theorem allValues_nodup : allValues.Nodup := by
  simp [allValues]

end Operator

/-- Semantic references may follow equality; Exact references never do. -/
inductive Authority where
  | semantic
  | exact
  deriving Repr, DecidableEq, BEq, Hashable

mutual

/--
A Value is its own exact structural content address. This removes the unprovable
assumption that a finite digest is globally injective. Hashes may still index or
display Values, but they never decide semantic identity.
-/
inductive Value where
  | atom (bytes : ByteArray)
  | apply (operator : Operator) (arguments : Refs)

/-- A finite sequence of authority-tagged references. -/
inductive Refs where
  | nil
  | semantic (value : Value) (tail : Refs)
  | exact (value : Value) (tail : Refs)

end

namespace Value

mutual

/--
The quotient follows only substitutable structure. Exact provenance is compared
literally by congruence and never becomes an equivalence-search lane.
-/
def semanticNodes : Value → List Value
  | value@(.atom _) => [value]
  | value@(.apply _ arguments) => value :: refsSemanticNodes arguments

def refsSemanticNodes : Refs → List Value
  | .nil => []
  | .semantic value tail => value.semanticNodes ++ refsSemanticNodes tail
  | .exact _ tail => refsSemanticNodes tail

end


mutual

/-- A semantics-independent extraction cost for one structural Value. -/
def structuralSize : Value → Nat
  | .atom bytes => bytes.size + 1
  | .apply _ arguments => refsStructuralSize arguments + 1

def refsStructuralSize : Refs → Nat
  | .nil => 0
  | .semantic value tail | .exact value tail =>
      value.structuralSize + refsStructuralSize tail + 1

end


theorem structuralSize_positive (value : Value) : 0 < value.structuralSize := by
  cases value <;> simp [structuralSize]

end Value

deriving instance DecidableEq for Value, Refs
deriving instance Hashable for Value, Refs

/-- A single reference view used at API boundaries. -/
abbrev Ref := Authority × Value

namespace Refs

def ofList : List Ref → Refs
  | [] => .nil
  | (.semantic, value) :: tail => .semantic value (ofList tail)
  | (.exact, value) :: tail => .exact value (ofList tail)

def toList : Refs → List Ref
  | .nil => []
  | .semantic value tail => (.semantic, value) :: tail.toList
  | .exact value tail => (.exact, value) :: tail.toList

@[simp]
theorem toList_ofList (references : List Ref) : (ofList references).toList = references := by
  induction references with
  | nil => rfl
  | cons head tail induction =>
      rcases head with ⟨authority, value⟩
      cases authority <;> simp [ofList, toList, induction]

@[simp]
theorem ofList_toList : ∀ references : Refs, ofList references.toList = references
  | .nil => rfl
  | .semantic value tail => by simp [toList, ofList, ofList_toList tail]
  | .exact value tail => by simp [toList, ofList, ofList_toList tail]

end Refs

namespace Value

def text (value : String) : Value :=
  .atom value.toUTF8

def applyList (operator : Operator) (arguments : List Ref) : Value :=
  .apply operator (.ofList arguments)

theorem atom_injective {left right : ByteArray} :
    Value.atom left = Value.atom right ↔ left = right := by
  simp

theorem apply_injective {leftOperator rightOperator : Operator} {leftArgs rightArgs : Refs} :
    Value.apply leftOperator leftArgs = Value.apply rightOperator rightArgs ↔
      leftOperator = rightOperator ∧ leftArgs = rightArgs := by
  simp

mutual

/-- Every Exact occurrence reachable from a Value, including nested authority. -/
def exactFootprint : Value → List Value
  | .atom _ => []
  | .apply _ arguments => refsExactFootprint arguments

def refsExactFootprint : Refs → List Value
  | .nil => []
  | .semantic value tail => value.exactFootprint ++ refsExactFootprint tail
  | .exact value tail => value :: value.exactFootprint ++ refsExactFootprint tail

end

mutual

/-- Every structurally contained Value, used to rebuild finite indexes. -/
def nodes : Value → List Value
  | value@(.atom _) => [value]
  | value@(.apply _ arguments) => value :: refsNodes arguments

def refsNodes : Refs → List Value
  | .nil => []
  | .semantic value tail | .exact value tail => value.nodes ++ refsNodes tail

end

def SameExactFootprint (left right : Value) : Prop :=
  ∀ exact, exact ∈ left.exactFootprint ↔ exact ∈ right.exactFootprint

def sameExactFootprint (left right : Value) : Bool :=
  left.exactFootprint.all right.exactFootprint.contains &&
    right.exactFootprint.all left.exactFootprint.contains

theorem sameExactFootprint_sound {left right}
    (accepted : sameExactFootprint left right) : SameExactFootprint left right := by
  intro exact
  simp only [sameExactFootprint, Bool.and_eq_true, List.all_eq_true] at accepted
  constructor
  · intro present
    exact List.contains_iff_mem.mp (accepted.1 exact present)
  · intro present
    exact List.contains_iff_mem.mp (accepted.2 exact present)

theorem sameExactFootprint_refl (value : Value) : SameExactFootprint value value := by
  intro exact
  rfl

theorem sameExactFootprint_symm {left right : Value}
    (same : SameExactFootprint left right) : SameExactFootprint right left := by
  intro exact
  exact (same exact).symm

theorem sameExactFootprint_trans {left middle right : Value}
    (leftMiddle : SameExactFootprint left middle)
    (middleRight : SameExactFootprint middle right) : SameExactFootprint left right := by
  intro exact
  exact (leftMiddle exact).trans (middleRight exact)

end Value

namespace Ref

def semantic (value : Value) : Ref :=
  (.semantic, value)

def exact (value : Value) : Ref :=
  (.exact, value)

def target (reference : Ref) : Value :=
  reference.2

def normalize (representative : Value → Value) : Ref → Ref
  | (.semantic, value) => semantic (representative value)
  | (.exact, value) => exact value

@[simp]
theorem normalize_exact (representative : Value → Value) (value : Value) :
    normalize representative (exact value) = exact value := by
  rfl

@[simp]
theorem normalize_semantic (representative : Value → Value) (value : Value) :
    normalize representative (semantic value) = semantic (representative value) := by
  rfl

end Ref

end Eggshell
