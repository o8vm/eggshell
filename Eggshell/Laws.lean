module

public import Eggshell.Quotient
public meta import Eggshell.Quotient

@[expose] public section

namespace Eggshell.Laws

def review : Value := .atom (.mk #[1])
def reviewResult : Value := .atom (.mk #[2])

def reviewOutcome : OutcomeEdge :=
  .make review reviewResult [] (by simp) (by simp [maxOutcomeObservations])

def directOutcomeGraph : WorkGraph where
  outcomes := [reviewOutcome]

/-- An Outcome is prior work, never permission to omit the open agent handoff. -/
theorem direct_outcome_is_context_not_completion :
    let extraction := Extract.run directOutcomeGraph Equality.exact review
    extraction.priorOutcomes = [reviewResult] ∧ extraction.residual = [review] := by
  native_decide

def ship : Value := .atom (.mk #[3])
def test : Value := .atom (.mk #[4])

def shippingAll : AllEdge :=
  .make ship [review, test] (by simp) (by simp [ship, review, test])

def partialGraph : WorkGraph where
  all := [shippingAll]
  outcomes := [reviewOutcome]

/-- Positive decomposition erases only the covered child inside the handoff. -/
theorem all_erases_only_covered_work :
    let extraction := Extract.run partialGraph Equality.exact ship
    extraction.priorOutcomes = [reviewResult] ∧ extraction.residual = [test] := by
  native_decide

def cycleA : Value := .atom (.mk #[5])
def cycleB : Value := .atom (.mk #[6])

def cycleAB : AllEdge :=
  .make cycleA [cycleB] (by simp) (by simp [cycleA, cycleB])

def cycleBA : AllEdge :=
  .make cycleB [cycleA] (by simp) (by simp [cycleA, cycleB])

def cyclicGraph : WorkGraph where
  all := [cycleAB, cycleBA]

/-- A positive cycle cannot erase the one external continuation. -/
theorem cycle_cannot_close_the_handoff :
    (Extract.run cyclicGraph Equality.exact cycleA).residual.length = 1 :=
  Extract.run_always_hands_off _ _ _

def priorWork : Value := .atom (.mk #[7])
def currentWork : Value := .atom (.mk #[8])
def priorResult : Value := .atom (.mk #[9])

def priorWorkOutcome : OutcomeEdge :=
  .make priorWork priorResult [] (by simp) (by simp [maxOutcomeObservations])

def unionWorkGraph : WorkGraph where
  outcomes := [priorWorkOutcome]

def localIdentity : UnionEdge where
  left := priorWork
  right := currentWork
  scope := .run currentWork
  exactAuthority := by
    intro exact
    simp [priorWork, currentWork, Value.exactFootprint]

/-- Local Union must reopen the owning Outcome before the same run hands off. -/
theorem local_union_resaturates_into_prior_work :
    (RunView.make? unionWorkGraph [priorWork, currentWork, priorResult]
      [] [localIdentity]).map (fun view =>
        let extraction := view.extract currentWork
        (extraction.priorOutcomes, extraction.residual)) =
      some ([priorResult], [currentWork]) := by
  native_decide

def advisoryPolicy : OutcomePolicy := .admitted [{
  demand := currentWork
  relation := priorWorkOutcome.relation
  judgment := {
    direction := .overlapping
    reusableOutcome := true
  }
}]

/-- A partial Local Union is delivered, but cannot erase the demanded work. -/
theorem advisory_is_visible_without_erasure :
    (RunView.make? unionWorkGraph [priorWork, currentWork, priorResult]
      [] [localIdentity]).map (fun view =>
        let extraction := view.extractWith advisoryPolicy currentWork
        (extraction.priorOutcomes, extraction.advisoryOutcomes,
          extraction.residual)) =
      some ([], [priorResult], [currentWork]) := by
  native_decide

def semanticLeafA : Value := .atom (.mk #[10])
def semanticLeafB : Value := .atom (.mk #[11])
def semanticParentA : Value :=
  .applyList .receipt [.semantic semanticLeafA]
def semanticParentB : Value :=
  .applyList .receipt [.semantic semanticLeafB]
def exactParentA : Value :=
  .applyList .receipt [.exact semanticLeafA]
def exactParentB : Value :=
  .applyList .receipt [.exact semanticLeafB]

def leafIdentity : UnionEdge where
  left := semanticLeafA
  right := semanticLeafB
  scope := .run semanticLeafA
  exactAuthority := by
    intro exact
    simp [semanticLeafA, semanticLeafB, Value.exactFootprint]

/-- A child Union propagates through Semantic Apply structure. -/
theorem semantic_congruence_closes_after_union :
    (QuotientBuilder.build?
      [semanticParentA, semanticParentB] [] [leafIdentity]).map
      (fun quotient => quotient.toEquality.same semanticParentA semanticParentB) =
      some true := by
  native_decide

/-- The same child Union cannot propagate through Exact provenance. -/
theorem exact_arguments_never_follow_semantic_union :
    (QuotientBuilder.build?
      [exactParentA, exactParentB] [] [leafIdentity]).map
      (fun quotient => quotient.toEquality.same exactParentA exactParentB) =
      some false := by
  native_decide

def sharedRoot : Value := .atom (.mk #[20])
def sharedWorkA : Value := .atom (.mk #[21])
def sharedWorkB : Value := .atom (.mk #[22])
def sharedOpen : Value := .atom (.mk #[23])
def sharedResult : Value := .atom (.mk #[24])

def sharedIdentity : UnionEdge where
  left := sharedWorkA
  right := sharedWorkB
  scope := .run sharedRoot
  exactAuthority := by
    intro exact
    simp [sharedWorkA, sharedWorkB, Value.exactFootprint]

def sharedOutcome : OutcomeEdge :=
  .make sharedWorkA sharedResult [] (by simp) (by simp [maxOutcomeObservations])

def repeatedAll : AllEdge :=
  .make sharedRoot [sharedWorkA, sharedWorkB, sharedOpen]
    (by simp) (by simp [sharedRoot, sharedWorkA, sharedWorkB, sharedOpen])

def compactAll : AllEdge :=
  .make sharedRoot [sharedWorkA, sharedOpen]
    (by simp) (by simp [sharedRoot, sharedWorkA, sharedOpen])

def repeatedGraph : WorkGraph where
  all := [repeatedAll]
  outcomes := [sharedOutcome]

def alternativeGraph : WorkGraph where
  /- The larger equivalent derivation is deliberately first. -/
  all := [repeatedAll, compactAll]
  outcomes := [sharedOutcome]

/-- Unioned spellings occupy one Work node in the extracted explanation DAG. -/
theorem union_collapses_duplicate_subwork_in_extracted_dag :
    (RunView.make? repeatedGraph
      [sharedRoot, sharedWorkA, sharedWorkB, sharedOpen, sharedResult,
        repeatedAll.relation, sharedOutcome.relation]
      [] [sharedIdentity]).map (fun view =>
        let extraction := view.extract sharedRoot
        (WorkGraph.distinct view.quotient.toEquality
            extraction.selection.workValues |>.length,
          extraction.priorOutcomes, extraction.discovery)) =
      some (3, [sharedResult], [sharedOpen]) := by
  native_decide

/-- After saturation, extraction chooses the smallest equivalent All graph. -/
theorem extraction_chooses_smallest_saturated_graph :
    (RunView.make? alternativeGraph
      [sharedRoot, sharedWorkA, sharedWorkB, sharedOpen, sharedResult,
        repeatedAll.relation, compactAll.relation, sharedOutcome.relation]
      [] [sharedIdentity]).map (fun view =>
        let extraction := view.extract sharedRoot
        (extraction.selection.decompositionEdges.map (·.relation),
          extraction.priorOutcomes, extraction.discovery)) =
      some ([compactAll.relation], [sharedResult], [sharedOpen]) := by
  native_decide

end Eggshell.Laws
