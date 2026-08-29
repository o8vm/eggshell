module

public import Eggshell.Graph

@[expose] public section

namespace Eggshell

/-- A finite executable equality together with the laws the kernel relies on. -/
structure Equality where
  same : Value → Value → Bool
  reflexive : ∀ value, same value value
  symmetric : ∀ {left right}, same left right → same right left
  transitive : ∀ {left middle right}, same left middle → same middle right →
    same left right
  preservesExact : ∀ {left right}, same left right →
    Value.SameExactFootprint left right

namespace Equality

def exact : Equality where
  same left right := decide (left = right)
  reflexive value := by simp
  symmetric := by simp_all
  transitive := by simp_all
  preservesExact := by
    intro left right same
    simp only [decide_eq_true_eq] at same
    subst right
    exact Value.sameExactFootprint_refl left

@[simp]
theorem exact_same_iff {left right} : exact.same left right ↔ left = right := by
  simp [exact]

end Equality

/-- The two positive relations evaluated by the kernel. -/
structure WorkGraph where
  all : List AllEdge := []
  outcomes : List OutcomeEdge := []

namespace WorkGraph

/-- Stable quotient deduplication. Equality, not insertion identity, owns the lane. -/
def distinct (equality : Equality) : List Value → List Value
  | values => (values.foldl (fun kept value =>
      if kept.any (equality.same value) then kept else value :: kept) []).reverse

def fromValues (values : List Value) : WorkGraph where
  all := values.filterMap AllEdge.fromValue?
  outcomes := values.filterMap OutcomeEdge.fromValue?

def outcomesFor (graph : WorkGraph) (equality : Equality) (work : Value) :
    List OutcomeEdge :=
  graph.outcomes.filter fun edge => equality.same edge.work work

def decompositionsFor (graph : WorkGraph) (equality : Equality) (parent : Value) :
    List AllEdge :=
  graph.all.filter fun edge => equality.same edge.parent parent

/-- An `All` edge is an AND-set over e-classes, not a bag of spellings. -/
def childrenFor (_graph : WorkGraph) (equality : Equality) (edge : AllEdge) :
    List Value :=
  distinct equality edge.children

/--
Work is reusable completion only when it occupies a child position in the
positive graph. A root Outcome is useful history, but cannot erase a smaller
operation merely because its prose mentions the same words.
-/
def subworks (graph : WorkGraph) : List Value :=
  graph.all.flatMap (·.children) |>.eraseDups

def isSubwork (graph : WorkGraph) (equality : Equality) (work : Value) : Bool :=
  graph.subworks.any (equality.same work)

end WorkGraph

/-
An open handoff is ordinary natural-language data.  The shared constructor only
prevents the turn compiler and matcher from inventing two spellings for the same
continuation, and lets saturation leave an internal remainder open until that
remainder itself becomes the external Demand.
-/
namespace HandoffRemainder

def marker : String :=
  "Use the selected prior WORK→OUTCOME graph as completed or advisory history. " ++
  "Do not repeat prior native work merely to verify it; recheck only after changed " ++
  "inputs, missing required evidence, or a concrete contradiction. Perform every " ++
  "uncovered action needed to answer: "

def text (work : String) : String := marker ++ work

def value (work : String) : Value := .text (text work)

def isValue : Value → Bool
  | .atom bytes =>
      match String.fromUTF8? bytes with
      | some content => content.startsWith marker
      | none => false
  | .apply _ _ => false

end HandoffRemainder

/-- Runtime delivery judgment; it is never persisted as graph authority. -/
inductive Applicability where
  | completed
  | advisory
  | irrelevant
  deriving Repr, DecidableEq, BEq

inductive CoverageDirection where
  | pastWorkInsideCurrentDemand
  | currentDemandInsidePastWork
  | overlapping
  | ambiguous
  deriving Repr, DecidableEq, BEq

/--
The matcher may be permissive. Only forward containment plus a reusable
outcome may erase small work; every other match remains visible advice.
-/
structure ApplicabilityJudgment where
  direction : CoverageDirection
  reusableOutcome : Bool

namespace ApplicabilityJudgment

def delivery (judgment : ApplicabilityJudgment) : Applicability :=
  if decide (judgment.direction = .pastWorkInsideCurrentDemand) &&
      judgment.reusableOutcome then
    .completed
  else
    .advisory

theorem completed_only_for_forward_reusable {judgment : ApplicabilityJudgment}
    (completed : judgment.delivery = .completed) :
    judgment.direction = .pastWorkInsideCurrentDemand ∧
      judgment.reusableOutcome = true := by
  simp only [delivery] at completed
  split at completed
  · rename_i accepted
    simp only [Bool.and_eq_true, decide_eq_true_eq] at accepted
    exact accepted
  · contradiction

end ApplicabilityJudgment

structure OutcomeAdmission where
  demand : Value
  relation : Value
  judgment : ApplicabilityJudgment

structure OutcomePolicy where
  classify : Value → OutcomeEdge → Applicability

namespace OutcomePolicy

def allCompleted : OutcomePolicy where
  classify _ _ := .completed

def admitted (admissions : List OutcomeAdmission) : OutcomePolicy where
  classify demand edge :=
    match admissions.find? (fun admission =>
        admission.demand == demand && admission.relation == edge.relation) with
    | some admission => admission.judgment.delivery
    | none => .irrelevant

theorem admitted_delivery_witness {admissions demand edge delivery}
    (classified : (admitted admissions).classify demand edge = delivery)
    (visible : delivery ≠ .irrelevant) :
    ∃ admission ∈ admissions,
      admission.demand = demand ∧ admission.relation = edge.relation ∧
        admission.judgment.delivery = delivery := by
  change (match admissions.find? (fun admission =>
      admission.demand == demand && admission.relation == edge.relation) with
    | some admission => admission.judgment.delivery
    | none => .irrelevant) = delivery at classified
  cases found : admissions.find? (fun admission =>
      admission.demand == demand && admission.relation == edge.relation) with
  | none =>
      simp only [found] at classified
      exact (visible classified.symm).elim
  | some admission =>
      have member := List.mem_of_find?_eq_some found
      have accepted := List.find?_some found
      simp only [Bool.and_eq_true, beq_iff_eq] at accepted
      simp only [found] at classified
      exact ⟨admission, member, accepted.1, accepted.2, classified⟩

end OutcomePolicy

inductive Selection where
  | residual (work : Value) (advisory : List OutcomeEdge)
  | outcomes (work : Value) (completed advisory : List OutcomeEdge)
  | decomposed (work : Value) (edge : AllEdge) (completed advisory : List OutcomeEdge)
      (children : List Selection)
  | handoff (work : Value) (prior : Selection)

namespace Selection

def outcomeUses : Selection → List (Applicability × Value × OutcomeEdge)
  | .residual work advisory =>
      advisory.map fun edge => (.advisory, work, edge)
  | .outcomes work completed advisory =>
      completed.map (fun edge => (.completed, work, edge)) ++
        advisory.map fun edge => (.advisory, work, edge)
  | .decomposed work _ completed advisory children =>
      completed.map (fun edge => (.completed, work, edge)) ++
        advisory.map (fun edge => (.advisory, work, edge)) ++
        children.flatMap outcomeUses
  | .handoff _ prior => prior.outcomeUses

def usesFor (delivery : Applicability) (selection : Selection) :
    List (Value × OutcomeEdge) :=
  selection.outcomeUses.filterMap fun use =>
    if use.1 == delivery then some (use.2.1, use.2.2) else none

def completedUses (selection : Selection) : List (Value × OutcomeEdge) :=
  usesFor .completed selection

def advisoryUses (selection : Selection) : List (Value × OutcomeEdge) :=
  usesFor .advisory selection

def priorOutcomes (selection : Selection) : List Value :=
  selection.completedUses.map (fun use => use.2.outcome)

def completedEdges (selection : Selection) : List OutcomeEdge :=
  selection.completedUses.map Prod.snd

def advisoryOutcomes (selection : Selection) : List Value :=
  selection.advisoryUses.map (fun use => use.2.outcome)

def advisoryEdges (selection : Selection) : List OutcomeEdge :=
  selection.advisoryUses.map Prod.snd

def openWork : Selection → List Value
  | .residual work _ => [work]
  | .outcomes _ _ _ => []
  | .decomposed _ _ _ _ children => children.flatMap openWork
  | .handoff work _ => [work]

/-- Every selected Work node before quotient sharing is applied. -/
def workValues : Selection → List Value
  | .residual work _ | .outcomes work _ _ => [work]
  | .decomposed work _ _ _ children => work :: children.flatMap workValues
  | .handoff work prior => work :: prior.workValues

def decompositionEdges : Selection → List AllEdge
  | .residual _ _ | .outcomes _ _ _ => []
  | .decomposed _ edge _ _ children =>
      edge :: children.flatMap decompositionEdges
  | .handoff _ prior => prior.decompositionEdges

/-- The relation closure is derived from the two structural projections, never re-walked. -/
def relationValues (selection : Selection) : List Value :=
  selection.decompositionEdges.map (·.relation) ++
    selection.outcomeUses.map (·.2.2.relation)

/-- Every Outcome selected for either delivery class remains in the structural handoff. -/
theorem outcomeUse_relation_mem {selection : Selection} {delivery : Applicability}
    {demand : Value} {edge : OutcomeEdge}
    (used : (delivery, demand, edge) ∈ selection.outcomeUses) :
    edge.relation ∈ selection.relationValues := by
  apply List.mem_append_right
  exact List.mem_map.mpr ⟨(delivery, demand, edge), used, rfl⟩

theorem completedEdge_relation_mem {selection : Selection} {edge : OutcomeEdge}
    (used : edge ∈ selection.completedEdges) :
    edge.relation ∈ selection.relationValues := by
  simp only [completedEdges, List.mem_map] at used
  obtain ⟨entry, entryUsed, rfl⟩ := used
  simp only [completedUses, usesFor, List.mem_filterMap] at entryUsed
  obtain ⟨use, useUsed, accepted⟩ := entryUsed
  split at accepted
  · simp only [Option.some.injEq] at accepted
    subst entry
    exact outcomeUse_relation_mem useUsed
  · contradiction

theorem advisoryEdge_relation_mem {selection : Selection} {edge : OutcomeEdge}
    (used : edge ∈ selection.advisoryEdges) :
    edge.relation ∈ selection.relationValues := by
  simp only [advisoryEdges, List.mem_map] at used
  obtain ⟨entry, entryUsed, rfl⟩ := used
  simp only [advisoryUses, usesFor, List.mem_filterMap] at entryUsed
  obtain ⟨use, useUsed, accepted⟩ := entryUsed
  split at accepted
  · simp only [Option.some.injEq] at accepted
    subst entry
    exact outcomeUse_relation_mem useUsed
  · contradiction

/-- Completed Work is removed only while its Outcome remains in the handoff. -/
theorem completedUse_outcome_is_prior {selection : Selection} {demand : Value}
    {edge : OutcomeEdge}
    (used : (demand, edge) ∈ selection.completedUses) :
    edge.outcome ∈ selection.priorOutcomes := by
  exact List.mem_map.mpr ⟨(demand, edge), used, rfl⟩

def containsOutcome (graph : WorkGraph) (edge : OutcomeEdge) : Bool :=
  graph.outcomes.any (fun stored => stored.relation == edge.relation)

def containsAll (graph : WorkGraph) (edge : AllEdge) : Bool :=
  graph.all.any (fun stored => stored.relation == edge.relation)

mutual

/--
An executable proof boundary for Extract.  It checks graph provenance,
classification, and the exact child order of every selected decomposition.
Invalid solver output degrades to one open residual instead of escaping.
-/
def structurallyValidAt (graph : WorkGraph) (equality : Equality) :
    Value → Selection → Bool
  | work, .residual selected _ | work, .outcomes selected _ _ =>
      selected == work
  | work, .decomposed selected edge _ _ children =>
      selected == work && equality.same edge.parent work &&
        structurallyValidChildren graph equality
          (graph.childrenFor equality edge) children
  | work, .handoff selected prior =>
      selected == work && structurallyValidAt graph equality work prior

def structurallyValidChildren (graph : WorkGraph) (equality : Equality) :
    List Value → List Selection → Bool
  | work :: works, child :: children =>
      structurallyValidAt graph equality work child &&
        structurallyValidChildren graph equality works children
  | [], [] => true
  | _, _ => false

end

def validFor (graph : WorkGraph) (equality : Equality)
    (policy : OutcomePolicy) (work : Value) (selection : Selection) : Bool :=
  (selection.structurallyValidAt graph equality work &&
    selection.decompositionEdges.all (containsAll graph)) &&
    (selection.completedUses.all fun use =>
      containsOutcome graph use.2 && equality.same use.2.work use.1 &&
        decide (policy.classify use.1 use.2 = .completed)) &&
    (selection.advisoryUses.all fun use =>
      containsOutcome graph use.2 && equality.same use.2.work use.1 &&
        decide (policy.classify use.1 use.2 = .advisory))

theorem completedUse_sound {graph equality policy work selection demand edge}
    (valid : validFor graph equality policy work selection)
    (used : (demand, edge) ∈ selection.completedUses) :
    containsOutcome graph edge = true ∧ equality.same edge.work demand = true ∧
      policy.classify demand edge = .completed := by
  simp only [validFor, Bool.and_eq_true, List.all_eq_true] at valid
  obtain ⟨⟨present, same⟩, classified⟩ := valid.1.2 (demand, edge) used
  exact ⟨present, same, of_decide_eq_true classified⟩

theorem advisoryUse_sound {graph equality policy work selection demand edge}
    (valid : validFor graph equality policy work selection)
    (used : (demand, edge) ∈ selection.advisoryUses) :
    containsOutcome graph edge = true ∧ equality.same edge.work demand = true ∧
      policy.classify demand edge = .advisory := by
  simp only [validFor, Bool.and_eq_true, List.all_eq_true] at valid
  obtain ⟨⟨present, same⟩, classified⟩ := valid.2 (demand, edge) used
  exact ⟨present, same, of_decide_eq_true classified⟩

theorem decompositionEdge_sound {graph equality policy work selection edge}
    (valid : validFor graph equality policy work selection)
    (used : edge ∈ selection.decompositionEdges) :
    containsAll graph edge = true := by
  simp only [validFor, Bool.and_eq_true, List.all_eq_true] at valid
  exact valid.1.1.2 edge used

theorem residual_valid (graph equality policy work) :
    validFor graph equality policy work (.residual work []) := by
  simp [validFor, structurallyValidAt, decompositionEdges,
    completedUses, advisoryUses, usesFor, outcomeUses]

theorem handoff_valid {graph equality policy work selection}
    (valid : validFor graph equality policy work selection) :
    validFor graph equality policy work (.handoff work selection) := by
  simpa [validFor, structurallyValidAt, decompositionEdges,
    completedUses, advisoryUses, usesFor, outcomeUses]
    using valid

end Selection

structure Extraction where
  priorOutcomes : List Value
  advisoryOutcomes : List Value
  residual : List Value
  /-- Open semantic leaves before they are collapsed into one external handoff. -/
  discovery : List Value
  support : List Value
  selection : Selection
  prior_visible : ∀ outcome, outcome ∈ selection.priorOutcomes →
    outcome ∈ priorOutcomes
  one_open_handoff : ∃ work, residual = [work]

namespace Extraction

def finalize (root : Value) (selection : Selection) : Selection :=
  match selection.openWork with
  | [_] => selection
  | _ => .handoff root selection

theorem finalize_valid {graph equality policy root selection}
    (valid : selection.validFor graph equality policy root) :
    (finalize root selection).validFor graph equality policy root := by
  unfold finalize
  cases selection.openWork with
  | nil => exact Selection.handoff_valid valid
  | cons head tail =>
      cases tail with
      | nil => exact valid
      | cons next rest => exact Selection.handoff_valid valid

def fromSelection (root : Value) (selection : Selection) : Extraction :=
  let pending := selection.openWork
  let finalSelection := finalize root selection
  {
    priorOutcomes := finalSelection.priorOutcomes.eraseDups
    advisoryOutcomes := finalSelection.advisoryOutcomes.eraseDups
    residual := finalSelection.openWork
    discovery := if pending.isEmpty then [root] else pending.eraseDups
    support := finalSelection.relationValues.eraseDups
    selection := finalSelection
    prior_visible := fun _ member => List.mem_eraseDups.mpr member
    one_open_handoff := by
      cases pendingEq : selection.openWork with
      | nil =>
          exact ⟨root, by simp [finalSelection, finalize, pendingEq, Selection.openWork]⟩
      | cons head tail =>
          cases tail with
          | nil => exact ⟨head, by simp [finalSelection, finalize, pendingEq]⟩
          | cons next rest =>
              exact ⟨root, by simp [finalSelection, finalize, pendingEq, Selection.openWork]⟩
  }

theorem residual_nonempty (extraction : Extraction) : extraction.residual ≠ [] := by
  rcases extraction.one_open_handoff with ⟨work, equals⟩
  simp [equals]

theorem residual_length (extraction : Extraction) : extraction.residual.length = 1 := by
  rcases extraction.one_open_handoff with ⟨work, equals⟩
  simp [equals]

theorem fromSelection_valid {graph equality policy root selection}
    (valid : selection.validFor graph equality policy root) :
    (fromSelection root selection).selection.validFor graph equality policy root := by
  change (finalize root selection).validFor graph equality policy root
  exact finalize_valid valid

end Extraction

namespace Extract

/-- Open Work dominates; equal frontiers choose the smaller transport surface. -/
structure Cost where
  openCount : Nat
  byteCount : Nat
  nodeCount : Nat
  deriving Repr, DecidableEq

namespace Cost

def LE (left right : Cost) : Prop :=
  left.openCount < right.openCount ∨
    left.openCount = right.openCount ∧
      (left.byteCount < right.byteCount ∨
        left.byteCount = right.byteCount ∧ left.nodeCount ≤ right.nodeCount)

instance : DecidableRel LE := fun _ _ => by
  unfold LE
  infer_instance

theorem le_refl (cost : Cost) : cost.LE cost := by
  simp [LE]

theorem le_total (left right : Cost) : left.LE right ∨ right.LE left := by
  unfold LE
  omega

theorem le_trans {left middle right : Cost}
    (leftMiddle : left.LE middle) (middleRight : middle.LE right) :
    left.LE right := by
  unfold LE at *
  omega

end Cost

structure Solution where
  selection : Selection

namespace Solution

def residual (work : Value) (advisory : List OutcomeEdge := []) : Solution :=
  ⟨.residual work advisory⟩

def outcomes (work : Value) (completed advisory : List OutcomeEdge) : Solution :=
  ⟨.outcomes work completed advisory⟩

def cost (solution : Solution) : Cost :=
  let graph := solution.selection.workValues ++ solution.selection.relationValues
  {
    openCount := solution.selection.openWork.length
    byteCount := graph.foldl (fun total value => total + value.structuralSize) 0
    nodeCount := graph.length
  }

def combine (work : Value) (edge : AllEdge) (completed advisory : List OutcomeEdge)
    (children : List Solution) : Solution :=
  ⟨.decomposed work edge completed advisory
    (children.map (fun child => child.selection))⟩

end Solution

def chooseBetter (left right : Solution) : Solution :=
  if left.cost.LE right.cost then left else right

theorem chooseBetter_le_left (left right : Solution) :
    (chooseBetter left right).cost.LE left.cost := by
  unfold chooseBetter
  split
  · exact Cost.le_refl _
  · rename_i notLeft
    exact (Cost.le_total left.cost right.cost).resolve_left notLeft

theorem chooseBetter_le_right (left right : Solution) :
    (chooseBetter left right).cost.LE right.cost := by
  unfold chooseBetter
  split
  · assumption
  · exact Cost.le_refl _

def chooseBest : List Solution → Option Solution
  | [] => none
  | head :: tail =>
      match chooseBest tail with
      | none => some head
      | some best => some (chooseBetter head best)

@[simp]
theorem chooseBest_eq_none_iff (solutions : List Solution) :
    chooseBest solutions = none ↔ solutions = [] := by
  cases solutions with
  | nil => simp [chooseBest]
  | cons head tail =>
      simp only [chooseBest]
      cases chooseBest tail <;> simp

/-- The chosen explanation is minimum among the supplied candidate derivations. -/
theorem chooseBest_minimal {solutions : List Solution} {best candidate : Solution}
    (found : chooseBest solutions = some best)
    (present : candidate ∈ solutions) :
    best.cost.LE candidate.cost := by
  induction solutions generalizing best candidate with
  | nil => simp at present
  | cons head tail induction =>
      simp only [chooseBest] at found
      cases tailFound : chooseBest tail with
      | none =>
          rw [tailFound] at found
          have empty : tail = [] := (chooseBest_eq_none_iff tail).mp tailFound
          subst tail
          simp only [List.mem_singleton] at present
          subst candidate
          injection found with found
          subst best
          exact Cost.le_refl _
      | some tailBest =>
          rw [tailFound] at found
          injection found with found
          subst best
          cases present with
          | head => exact chooseBetter_le_left head tailBest
          | tail _ inTail =>
              exact Cost.le_trans (chooseBetter_le_right head tailBest)
                (induction tailFound inTail)

/--
Fuel is a totality witness only. Cycles are cut by `active`; quotient-equivalent
children are visited once before the existing recursive extractor is reused.
-/
def solve (graph : WorkGraph) (equality : Equality) (policy : OutcomePolicy) :
    Nat → List Value → Value → Option Solution
  | 0, _, work => some (Solution.residual work)
  | fuel + 1, active, work =>
      if active.contains work then none
      else
        let outcomes := graph.outcomesFor equality work
        let completed := outcomes.filter fun edge => policy.classify work edge == .completed
        let advisory := outcomes.filter fun edge => policy.classify work edge == .advisory
        let candidates := (graph.decompositionsFor equality work).filterMap fun edge =>
          match (graph.childrenFor equality edge).mapM
              (solve graph equality policy fuel (work :: active)) with
          | some children => some (Solution.combine work edge completed advisory children)
          | none => none
        match chooseBest candidates with
        | some best => some best
        | none =>
            if completed.isEmpty then some (Solution.residual work advisory)
            else some (Solution.outcomes work completed advisory)

def runWithPolicy (graph : WorkGraph) (equality : Equality)
    (policy : OutcomePolicy) (root : Value) : Extraction :=
  let fuel := graph.all.length + graph.outcomes.length + 1
  let solution := (solve graph equality policy fuel [] root).getD (Solution.residual root)
  let checked := if solution.selection.validFor graph equality policy root then
    solution.selection else .residual root []
  .fromSelection root checked

def run (graph : WorkGraph) (equality : Equality) (root : Value) : Extraction :=
  runWithPolicy graph equality .allCompleted root

theorem run_always_hands_off (graph equality root) :
    (run graph equality root).residual.length = 1 :=
  Extraction.residual_length _

theorem run_never_finishes_the_inquiry (graph equality root) :
    (run graph equality root).residual ≠ [] :=
  Extraction.residual_nonempty _

/-- Every edge returned by Extract has passed the general graph/policy checker. -/
theorem runWithPolicy_sound (graph equality policy root) :
    (runWithPolicy graph equality policy root).selection.validFor
      graph equality policy root := by
  simp only [runWithPolicy]
  split
  · exact Extraction.fromSelection_valid (by assumption)
  · apply Extraction.fromSelection_valid
    exact Selection.residual_valid graph equality policy root

end Extract

end Eggshell
