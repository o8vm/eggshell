module

public import Eggshell.Matcher
public meta import Eggshell.Matcher

@[expose] public section

namespace Eggshell.MatcherLaws

open LogicalText

/-- Match-only shell segmentation respects actual top-level execution boundaries. -/
theorem top_level_shell_clauses_are_independent :
    Matcher.shellClauses
      "sed -n '1,20p' a.c; sed -n '30,40p' b.c && rg 'a;b' src" =
      ["sed -n '1,20p' a.c", "sed -n '30,40p' b.c", "rg 'a;b' src"] := by
  native_decide

/-- A separator inside a quoted substitution cannot become a different Work view. -/
theorem quoted_substitution_stays_atomic :
    Matcher.shellClauses "echo $(printf 'a;b'); rg symbol src" =
      ["echo $(printf 'a;b')", "rg symbol src"] := by
  native_decide

/-- Stateful shell control programs remain one match unit. -/
theorem shell_control_program_stays_atomic :
    Matcher.shellClauses "for f in a b; do sed -n '1,20p' $f; done" =
      ["for f in a b; do sed -n '1,20p' $f; done"] := by
  native_decide

/-- Structural views are never persistent Values and are always nonempty. -/
theorem canonical_native_work_has_a_match_view :
    Matcher.nativeWorkSurfaces
      "Bash\nsed -n '1,20p' a.c; rg clocksource_select kernel/time" =
      ["Bash\nsed -n '1,20p' a.c", "Bash\nrg clocksource_select kernel/time"] := by
  native_decide

/-- Regex punctuation does not invent another persistent Work. -/
theorem regex_dot_preserves_work_units :
    (LogicalText.logical "timekeeping.*update").units.map (·.text) =
      ["timekeeping", "update"] := by
  native_decide

/-- Prose punctuation cannot silently manufacture completed child Work. -/
theorem prose_dot_preserves_one_work_value :
    (LogicalText.logical "inspect source. trace result").units.map (·.text) =
      ["inspect", "source", "trace", "result"] := by
  native_decide

/-- Regex alternation keeps its content in one ordinary Work surface. -/
theorem quoted_regex_does_not_invent_subwork :
    (LogicalText.logical "rg -n \"clocksource|noinstr|u64\" arch/x86/kernel/tsc.c").units.map
      (·.text) = ["rg", "n", "clocksource", "noinstr", "u64",
        "arch/x86/kernel/tsc.c"] := by
  native_decide

/-- A pipeline is one observed native Work, not adapter-invented child tasks. -/
theorem unquoted_pipe_stays_inside_native_work :
    (LogicalText.logical "rg clocksource|sed tsc.c").units.map (·.text) =
      ["rg", "clocksource", "sed", "tsc.c"] := by
  native_decide

def pastWork : Value := .text "rg update_vsyscall kernel/time"
def currentWork : Value := .text "kernel/time update_vsyscall rg"
def observedResult : Value := .text "kernel/time/vsyscall.c: update_vsyscall"

def observed : OutcomeEdge :=
  .make pastWork observedResult [] (by simp) (by simp [maxOutcomeObservations])

def operationFrame (edge : OutcomeEdge) : Value :=
  .applyList .all [
    .semantic (.text "matcher-law turn"),
    .semantic edge.work,
    .semantic (.text "matcher-law open remainder")]

def framedValues (values : List Value) : List Value :=
  values ++ (values.filterMap OutcomeEdge.fromValue?).map operationFrame

def discoverRaw (current : Value) (values : List Value) (text : String) :
    Option Matcher.Discovery :=
  Matcher.discover? logicalNormalizer current values [] text

def discover (current : Value) (values : List Value) (text : String) :
    Option Matcher.Discovery :=
  let framed := framedValues values
  Matcher.discover? logicalNormalizer current framed [] text

def discoverWithEvidence (current : Value) (values : List Value)
    (work evidence : String) : Option Matcher.Discovery :=
  let framed := framedValues values
  let graph := WorkGraph.fromValues framed
  Matcher.discoverIn? logicalNormalizer current framed [] graph
    (Matcher.Corpus.build logicalNormalizer graph) work (some evidence)

def discoverNominated (current : Value) (values : List Value)
    (work : String) (related : List Value) : Option Matcher.Discovery :=
  let framed := framedValues values
  let graph := WorkGraph.fromValues framed
  Matcher.discoverIn? logicalNormalizer current framed [] graph
    (Matcher.Corpus.build logicalNormalizer graph) work none
      { related }

def quotedRegexPast : Value :=
  .text "rg -n \"noinstr|pvclock_clocksource_read\" arch/x86/kernel/pvclock.c"
def quotedRegexCurrent : Value :=
  .text "rg -n \"noinstr|tsc_clocksource\" arch/x86/kernel/tsc.c"
def quotedRegexOutcome : OutcomeEdge :=
  .make quotedRegexPast (.text "pvclock.c: noinstr u64 pvclock_clocksource_read_nowd") []
    (by simp) (by simp [maxOutcomeObservations])

/-- A shared regex alternative remains advice and cannot complete the surrounding operation. -/
theorem quoted_regex_alternative_stays_advisory :
    (discover quotedRegexCurrent [quotedRegexOutcome.relation]
      "rg -n \"noinstr|tsc_clocksource\" arch/x86/kernel/tsc.c").map
      (fun discovery =>
        let extraction := Matcher.extraction discovery
        (discovery.view.localUnions.length, extraction.priorOutcomes,
          extraction.advisoryOutcomes.contains quotedRegexOutcome.outcome)) =
      some (0, [], true) := by
  native_decide

/-- Orderless surface evidence reconnects the exact prior Outcome in one run. -/
theorem local_union_changes_the_selected_work_graph :
    (discover currentWork [observed.relation]
      "kernel/time update_vsyscall rg").map (fun discovery =>
        let extraction := Matcher.extraction discovery
        (discovery.view.localUnions.length,
          extraction.priorOutcomes,
          extraction.residual)) =
      some (1, [observedResult], [currentWork]) := by
  native_decide

def multilingualPast : Value :=
  .text "shell trace the vDSO clock_gettime realtime path"
def multilingualCurrent : Value :=
  .text "shell 利用者空間から現在時刻を高速取得する経路を調査"
def multilingualResult : Value :=
  .text "時刻保持層から利用者APIへ接続した"
def multilingualOutcome : OutcomeEdge :=
  .make multilingualPast multilingualResult []
    (by simp) (by simp [maxOutcomeObservations])

/-- Relatedness alone is useful advisory retrieval, never equality or completion. -/
theorem semantic_retrieval_does_not_union_or_complete :
    (discoverNominated multilingualCurrent [multilingualOutcome.relation]
      "shell 利用者空間から現在時刻を高速取得する経路を調査"
      [multilingualOutcome.relation]).map (fun discovery =>
        let extraction := Matcher.extraction discovery
        (discovery.view.localUnions.length, discovery.passes,
          extraction.priorOutcomes.contains multilingualResult,
          extraction.advisoryOutcomes.contains multilingualResult,
          extraction.residual.length)) =
      some (0, 0, false, true, 1) := by
  native_decide

/-- Matching keeps the durable Outcome owner instead of assigning it to a substring. -/
theorem local_union_preserves_outcome_ownership :
    (discover currentWork [observed.relation]
      "kernel/time update_vsyscall rg").bind (fun discovery =>
        discovery.hits.head?.map fun matched => matched.edge.relation) =
      some observed.relation := by
  native_decide

def evidenceWork : Value := .text "inspect a previous calibration"
def evidenceResult : Value := .text "shared_result_symbol was observed"
def evidenceOutcome : OutcomeEdge :=
  .make evidenceWork evidenceResult [] (by simp) (by simp [maxOutcomeObservations])
def unrelatedCurrent : Value := .text "read a new ACPI table"

/-- Native result text alone cannot enter Demand or become Work identity. -/
theorem native_result_is_advisory_not_a_local_union :
    (discoverWithEvidence unrelatedCurrent [evidenceOutcome.relation]
      "read a new ACPI table" "shared_result_symbol appeared").map (fun discovery =>
        let extraction := Matcher.extraction discovery
        (discovery.view.localUnions.length,
          extraction.priorOutcomes,
          extraction.advisoryOutcomes.contains evidenceResult)) =
      some (0, [], false) := by
  native_decide

def secondObserved : OutcomeEdge :=
  .make pastWork (.text "second observed result") []
    (by simp) (by simp [maxOutcomeObservations])

/-- Multiple Outcomes owned by one Work create one equivalence merge. -/
theorem one_local_union_per_value_pair :
    (discover currentWork [observed.relation, secondObserved.relation]
      "kernel/time update_vsyscall rg").map
      (fun discovery => discovery.view.localUnions.length) = some 1 := by
  native_decide

def largerCurrent : Value :=
  .text "rg update_vsyscall kernel/time; investigate native tsc calibration"

/-- A completed fragment is reusable without closing its larger Inquiry. -/
theorem contained_work_is_reusable_but_the_inquiry_stays_open :
    (discover largerCurrent [observed.relation]
      "rg update_vsyscall kernel/time; investigate native tsc calibration").bind
      (fun discovery => discovery.hits.head?.map fun matched =>
        let extraction := Matcher.extraction discovery
        (matched.judgment.delivery, extraction.residual.length)) =
      some (.completed, 1) := by
  native_decide

def forwardPast : Value := .text "Bash rg n vdso timekeeping"
def forwardCurrent : Value :=
  .text "Bash rg n vdso timekeeping tsc clocksource"
def forwardResult : Value := .text "vdso timekeeping symbols were observed"
def forwardOutcome : OutcomeEdge :=
  .make forwardPast forwardResult [] (by simp) (by simp [maxOutcomeObservations])

/--
Applicability is directional: a complete historical operation contained in a
larger current operation is completed support, while the added current work
remains in the open handoff.
-/
theorem forward_containment_erases_only_the_historical_work :
    (discover forwardCurrent [forwardOutcome.relation]
      "Bash rg n vdso timekeeping tsc clocksource").bind
      (fun discovery => discovery.hits.head?.map fun matched =>
        let extraction := Matcher.extraction discovery
        (matched.work.priorInDemand.complete,
          matched.work.demandInPrior.complete,
          matched.applicability,
          extraction.priorOutcomes.contains forwardResult,
          extraction.residual.length)) =
      some (true, false, .completed, true, 1) := by
  native_decide

def opaqueForwardResult : Value := .text "opaque native result bytes"
def opaqueForwardOutcome : OutcomeEdge :=
  .make forwardPast opaqueForwardResult [] (by simp) (by simp [maxOutcomeObservations])

/--
Outcome ownership is structural. A complete historical All-child remains
reusable inside a larger current Work even when its result does not repeat the
matched command text; the projected edge cites its durable owner exactly.
-/
theorem forward_containment_uses_structural_outcome_ownership :
    (discover forwardCurrent [opaqueForwardOutcome.relation]
      "Bash rg n vdso timekeeping tsc clocksource").bind
      (fun discovery => discovery.hits.head?.map fun matched =>
        let extraction := Matcher.extraction discovery
        (matched.work.priorInDemand.complete,
          matched.applicability,
          extraction.priorOutcomes.contains opaqueForwardResult,
          extraction.residual.length)) =
      some (true, .completed, true, 1) := by
  native_decide

def reversePast : Value := forwardCurrent
def reverseResult : Value :=
  .text "Bash rg n vdso timekeeping tsc clocksource was observed"
def reverseOutcome : OutcomeEdge :=
  .make reversePast reverseResult [] (by simp) (by simp [maxOutcomeObservations])

/-- A larger historical operation cannot erase a smaller current operation. -/
theorem reverse_containment_stays_advisory_even_when_result_text_is_grounded :
    (discover forwardPast [reverseOutcome.relation]
      "Bash rg n vdso timekeeping").bind
      (fun discovery => discovery.hits.head?.map fun matched =>
        let extraction := Matcher.extraction discovery
        (matched.work.priorInDemand.complete,
          matched.work.demandInPrior.complete,
          matched.applicability,
          extraction.priorOutcomes.contains reverseResult,
          extraction.advisoryOutcomes.contains reverseResult)) =
      some (false, true, .advisory, false, true) := by
  native_decide

/-- Candidate restriction is structural rather than an approximate index filter. -/
theorem candidate_universe_is_exactly_outcome_owners (graph : WorkGraph) :
    Matcher.outcomeCandidates graph = graph.outcomes := rfl

def priorParent : Value := .text "alpha beta gamma"
def currentParent : Value := .text "gamma beta alpha"
def demandedChild : Value := .text "delta epsilon zeta"
def priorChild : Value := .text "zeta epsilon delta"
def parentResult : Value := .text "parent outcome"
def childResult : Value := .text "child outcome"
def parentOutcome : OutcomeEdge :=
  .make priorParent parentResult [] (by simp) (by simp [maxOutcomeObservations])

def childOutcome : OutcomeEdge :=
  .make priorChild childResult [] (by simp) (by simp [maxOutcomeObservations])

def nestedWork : AllEdge :=
  .make priorParent [demandedChild] (by simp) (by native_decide)

/--
The first Local Union exposes an existing All child. That newly demanded child
is probed in the next semi-naive pass, creates a second Local Union, and only
then reaches its Outcome owner. A one-shot retrieval implementation cannot
produce this result.
-/
theorem local_union_resaturates_newly_demanded_subwork :
    let values := [parentOutcome.relation, nestedWork.relation,
      childOutcome.relation]
    (discoverRaw currentParent values "gamma beta alpha").map (fun discovery =>
      let extraction := Matcher.extraction discovery
      (discovery.passes, discovery.view.localUnions.length,
        extraction.priorOutcomes.contains parentResult,
        extraction.priorOutcomes.contains childResult,
        extraction.advisoryOutcomes.contains parentResult)) =
      some (2, 2, false, true, false) := by
  native_decide

def historicalTurn : Value :=
  .text "Trace pvclock and mention TSC only where pvclock depends on it"
def historicalTurnResult : Value := .text "guest pvclock TSC-delta read"
def historicalTurnOutcome : OutcomeEdge :=
  .make historicalTurn historicalTurnResult []
    (by simp) (by simp [maxOutcomeObservations])
def historicalOperation : Value := .text "rg update_vsyscall kernel/time"
def historicalTurnFrame : AllEdge :=
  .make historicalTurn
    [historicalOperation, .text "finish every uncovered part of the pvclock inquiry"]
    (by simp) (by native_decide)

/-- A root turn may reconnect as advice, but only an All child can erase Work. -/
theorem parent_turn_outcome_cannot_erase_a_native_operation :
    let values := [historicalTurnOutcome.relation, historicalTurnFrame.relation]
    (discoverRaw (.text "TSC") values "TSC").bind (fun discovery =>
      (discovery.hits.find? fun matched =>
        matched.edge.relation == historicalTurnOutcome.relation).map fun matched =>
          (!discovery.view.localUnions.isEmpty,
            matched.applicability,
            (Matcher.extraction discovery).priorOutcomes.isEmpty,
            (Matcher.extraction discovery).residual.length)) =
      some (false, Applicability.advisory, true, 1) := by
  native_decide

/-- Projection always transports the complete causal Outcome owner. -/
theorem projection_preserves_the_whole_outcome :
    let values := [historicalTurnOutcome.relation, historicalTurnFrame.relation]
    (discoverRaw (.text "TSC") values "TSC").bind (fun discovery =>
      (discovery.hits.find? fun matched =>
        matched.edge.relation == historicalTurnOutcome.relation).map fun matched =>
          matched.projectionOutcome == historicalTurnResult) = some true := by
  native_decide

/-- A root turn cannot enter automatic context through one coincidental clause. -/
theorem parent_turn_fragment_is_not_automatic :
    let values := [historicalTurnOutcome.relation, historicalTurnFrame.relation]
    (discoverRaw (.text "TSC") values "TSC").bind (fun discovery =>
      (discovery.hits.find? fun matched =>
        matched.edge.relation == historicalTurnOutcome.relation).map
          (·.automatic)) = some false := by
  native_decide

def advisoryParent : Value :=
  .text "Investigate pvclock host registration guest msr migration seqlock. generic timekeeping vdso clock_gettime syscall."
def advisoryCurrent : Value :=
  .text "Investigate tsc calibration watchdog refinement frequency stability. generic timekeeping vdso clock_gettime syscall."
def advisoryParentResult : Value := .text
  "pvclock-specific initialization.\ngeneric timekeeping vdso clock_gettime syscall.\nKVM-only detail."
def advisoryParentOutcome : OutcomeEdge :=
  .make advisoryParent advisoryParentResult []
    (by simp) (by simp [maxOutcomeObservations])
def advisoryParentFrame : AllEdge :=
  .make advisoryParent
    [.text "inspect pvclock source", .text "finish the pvclock inquiry"]
    (by simp) (by native_decide)
def advisoryChild : Value := .text "inspect pvclock source"
def advisoryChildResult : Value := .text "pvclock source was observed"
def advisoryChildOutcome : OutcomeEdge :=
  .make advisoryChild advisoryChildResult []
    (by simp) (by simp [maxOutcomeObservations])
def advisoryBackground (name : String) : OutcomeEdge :=
  .make (.text s!"investigate {name}") (.text s!"observed {name}") []
    (by simp) (by simp [maxOutcomeObservations])

/-- A grounded parent Turn projects coherent advice without completing the new Turn. -/
theorem parent_turn_projects_grounded_advice_without_erasing_work :
    let values := [advisoryParentOutcome.relation, advisoryParentFrame.relation,
      (advisoryBackground "unrelated-alpha").relation,
      (advisoryBackground "unrelated-beta").relation]
    (discoverRaw advisoryCurrent values
      "Investigate tsc calibration watchdog refinement frequency stability. generic timekeeping vdso clock_gettime syscall.").bind
      (fun discovery =>
        (discovery.hits.find? fun matched =>
          matched.edge.relation == advisoryParentOutcome.relation &&
            matched.automatic).map fun matched =>
          ((matched.applicability == .advisory, matched.work.fragmentIdentity,
              matched.groundedContext,
              (Matcher.extraction discovery).priorOutcomes.isEmpty),
            ((Matcher.extraction discovery).advisoryOutcomes.contains
                matched.projectionOutcome,
              matched.projectionOutcome == advisoryParentResult,
              matched.projectionOutcome == matched.edge.outcome,
              matched.projectedEdge.relation == matched.edge.relation ||
                matched.projectedEdge.observations.contains matched.edge.relation))) =
      some ((true, true, true, true), (true, true, true, true)) := by
  native_decide

/-- A related parent Turn cannot make an unrelated historical child mandatory Work. -/
theorem parent_advice_does_not_demand_unmatched_historical_children :
    let values := [advisoryParentOutcome.relation, advisoryParentFrame.relation,
      advisoryChildOutcome.relation,
      (advisoryBackground "unrelated-alpha").relation,
      (advisoryBackground "unrelated-beta").relation]
    (discoverRaw advisoryCurrent values
      "Investigate tsc calibration watchdog refinement frequency stability. generic timekeeping vdso clock_gettime syscall.").map
      (fun discovery =>
        let extraction := Matcher.extraction discovery
        (extraction.priorOutcomes.contains advisoryChildResult,
          extraction.advisoryOutcomes.contains advisoryParentResult,
          extraction.residual.length)) =
      some (false, true, 1) := by
  native_decide

def largerPrior : Value := .text "inspect alpha beta gamma"
def smallerDemand : Value := .text "alpha beta"
def largerOutcome : OutcomeEdge :=
  .make largerPrior (.text "larger prior outcome") []
    (by simp) (by simp [maxOutcomeObservations])

/-- Reverse containment can create local identity evidence but never completion. -/
theorem enclosing_past_work_is_advisory_not_completed :
    (discover smallerDemand [largerOutcome.relation] "alpha beta").bind
      (fun discovery => discovery.hits.head?.map fun matched =>
        let extraction := Matcher.extraction discovery
        (matched.applicability, discovery.view.localUnions.length,
          extraction.priorOutcomes.contains (.text "larger prior outcome"),
          decide (extraction.residual = [smallerDemand]))) =
      some (.advisory, 0, false, true) := by
  native_decide

/-- Fragment reuse is expressed by the existing Outcome constructor. -/
theorem projected_fragment_is_an_ordinary_outcome :
    (discover largerCurrent [observed.relation]
      "rg update_vsyscall kernel/time and investigate native tsc calibration").bind
      (fun discovery => discovery.hits.head?.map fun matched =>
        (OutcomeEdge.fromValue? matched.projectedEdge.relation).map fun edge =>
          (edge.work == matched.projectionWork,
            edge.outcome == matched.projectionOutcome,
            matched.projectedEdge.relation == matched.edge.relation ||
              edge.observations.contains matched.edge.relation)) =
      some (some (true, true, true)) := by
  native_decide

/-- Result text cannot bypass Work identity and become an automatic retrieval lane. -/
theorem outcome_text_cannot_enter_demand_without_work_identity :
    let unrelated := OutcomeEdge.make (.text "inspect unrelated subsystem")
      (.text "kernel/time update_vsyscall rg") []
      (by simp) (by simp [maxOutcomeObservations])
    (discover currentWork [unrelated.relation]
      "kernel/time update_vsyscall rg").map (fun discovery =>
        (discovery.hits.isEmpty, discovery.view.localUnions.isEmpty,
          (Matcher.extraction discovery).priorOutcomes,
          (Matcher.extraction discovery).residual.length)) =
      some (true, true, [], 1) := by
  native_decide

def echoedForeignRead : Value :=
  .text "Bash nl -ba arch/x86/kvm/cpuid.c sed n 1750 1785p"
def proposedTscRead : Value :=
  .text "Bash nl -ba arch/x86/kernel/tsc.c sed n 1080 1460p"
def echoedForeignOutcome : OutcomeEdge :=
  .make echoedForeignRead
    (.text "log echoed Bash nl -ba arch/x86/kernel/tsc.c sed n 1080 1460p") []
    (by simp) (by simp [maxOutcomeObservations])

/-- An echoed command may remain advice but cannot become completed support. -/
theorem echoed_command_in_outcome_never_completes_work :
    (discover proposedTscRead [echoedForeignOutcome.relation]
      "Bash nl -ba arch/x86/kernel/tsc.c sed n 1080 1460p").map
      (fun discovery =>
        let extraction := Matcher.extraction discovery
        (discovery.view.localUnions.length,
          extraction.priorOutcomes,
          extraction.advisoryOutcomes.contains echoedForeignOutcome.outcome)) =
      some (0, [], true) := by
  native_decide

def scaffoldingPast : Value :=
  .text "Bash rg n local_clock kernel x86"
def scaffoldingCurrent : Value :=
  .text "x86 kernel Bash rg n pmtmr"
def scaffoldingOutcome : OutcomeEdge :=
  .make scaffoldingPast (.text "kernel x86 local_clock") []
    (by simp) (by simp [maxOutcomeObservations])

def transportBackground (name : String) : OutcomeEdge :=
  .make (.text s!"Bash rg n {name} kernel x86") (.text name) []
    (by simp) (by simp [maxOutcomeObservations])

/-- Ubiquitous transport scaffolding never becomes completed Work. -/
theorem transport_scaffolding_is_advisory :
    let values := [scaffoldingOutcome.relation,
      (transportBackground "background_a").relation,
      (transportBackground "background_b").relation,
      (transportBackground "background_c").relation]
    (discover scaffoldingCurrent values
      "x86 kernel Bash rg n pmtmr").bind (fun discovery =>
        discovery.hits.head?.map fun _ =>
          ((Matcher.extraction discovery).priorOutcomes.isEmpty,
            (Matcher.extraction discovery).residual.length)) =
      some (true, 1) := by
  native_decide

def nativeOccurrence (work outcome : Value) : Value :=
  .applyList .occurrence [.semantic outcome, .semantic work]

def turnOccurrence (work outcome : Value) : Value :=
  .applyList .occurrence [.semantic work, .semantic outcome]

def nativeFlagPast : Value :=
  .text "shell\nrg -n --glob '*.c' old_symbol old/path kernel"
def nativeFlagCurrent : Value :=
  .text "shell\nrg -n --glob '!docs' new_symbol new/path kernel"
def nativeFlagOutcome : OutcomeEdge :=
  .make nativeFlagPast (.text "old result")
    [nativeOccurrence nativeFlagPast (.text "old result")]
    (by simp) (by simp [maxOutcomeObservations])
def nativeFlagBackground (name : String) : OutcomeEdge :=
  let work := .text s!"shell\nrg -n --glob '*.c' {name} kernel"
  let outcome := .text name
  .make work outcome [nativeOccurrence work outcome]
    (by simp) (by simp [maxOutcomeObservations])

theorem oriented_native_occurrence_is_native :
    Matcher.nativeOutcome nativeFlagOutcome = true := by
  native_decide

def turnFlagOutcome : OutcomeEdge :=
  let work := .text "investigate a clock"
  let outcome := .text "the investigation completed"
  .make work outcome [turnOccurrence work outcome]
    (by simp) (by simp [maxOutcomeObservations])

theorem oriented_turn_occurrence_is_not_native :
    Matcher.nativeOutcome turnFlagOutcome = false := by
  native_decide

/-- Native option syntax and ubiquitous path framing cannot erase unrelated Work. -/
theorem native_option_scaffolding_never_completes_work :
    let values := [nativeFlagOutcome.relation,
      (nativeFlagBackground "background_a").relation,
      (nativeFlagBackground "background_b").relation,
      (nativeFlagBackground "background_c").relation]
    let framed := framedValues values
    let graph := WorkGraph.fromValues framed
    (Matcher.discoverIn? logicalNormalizer nativeFlagCurrent framed [] graph
      (Matcher.Corpus.build logicalNormalizer graph)
      "shell\nrg -n --glob '!docs' new_symbol new/path kernel"
      none {} true true).map (fun discovery =>
        let extraction := Matcher.extraction discovery
        (extraction.priorOutcomes.isEmpty, extraction.residual.length)) =
      some (true, 1) := by
  native_decide

def batchedNativePast : Value := .text
  "Bash\nrg -n update_vsyscall kernel/time; sed -n '1,120p' arch/x86/kernel/pvclock.c"
def batchedNativeCurrent : Value := .text
  "Bash\nrg -n kernel/time update_vsyscall; rg -n tsc_init arch/x86/kernel/tsc.c"
def batchedNativeResult : Value := .text
  "kernel/time update_vsyscall was observed\npvclock source was read"
def batchedNativeOutcome : OutcomeEdge :=
  .make batchedNativePast batchedNativeResult
    [nativeOccurrence batchedNativePast batchedNativeResult]
    (by simp) (by simp [maxOutcomeObservations])

/--
One executed clause is one complete run-local Work even when its durable owner
is a larger native invocation. Its projected result cites that owner, and the
unmatched current clause stays open.
-/
theorem completed_native_clause_reuses_grounded_outcome_and_keeps_remainder :
    let values := framedValues [batchedNativeOutcome.relation]
    let graph := WorkGraph.fromValues values
    (Matcher.discoverIn? logicalNormalizer batchedNativeCurrent values [] graph
      (Matcher.Corpus.build logicalNormalizer graph)
      "Bash\nrg -n kernel/time update_vsyscall; rg -n tsc_init arch/x86/kernel/tsc.c"
      none {} true true).bind (fun discovery =>
        (discovery.hits.find? fun matched =>
          matched.edge.relation == batchedNativeOutcome.relation &&
            matched.work.pastWholeWork = false &&
            matched.applicability == .completed &&
            matched.groundedOutcomeFragment).map fun matched =>
          let extraction := Matcher.extraction discovery
          (discovery.view.localUnions.length,
            matched.applicability,
            matched.groundedOutcomeFragment,
            matched.projectionOutcome,
            extraction.priorOutcomes.contains matched.projectionOutcome,
            extraction.residual.length)) =
      some (1, .completed, true,
        .text "kernel/time update_vsyscall was observed", true, 1) := by
  native_decide

def batchedRangePast : Value := .text
  "Bash\nsed -n '1,120p' kernel/time/timekeeping.c; rg pvclock arch/x86/kernel/pvclock.c"
def batchedRangeCurrent : Value := .text
  "Bash\nsed -n '300,420p' kernel/time/timekeeping.c; rg tsc arch/x86/kernel/tsc.c"
def batchedRangeResult : Value := .text
  "kernel/time/timekeeping.c lines 1 through 120 were read"
def batchedRangeOutcome : OutcomeEdge :=
  .make batchedRangePast batchedRangeResult
    [nativeOccurrence batchedRangePast batchedRangeResult]
    (by simp) (by simp [maxOutcomeObservations])

/-- A shared file cannot complete a different observed range. -/
theorem different_native_clause_range_stays_advisory :
    let values := framedValues [batchedRangeOutcome.relation]
    let graph := WorkGraph.fromValues values
    (Matcher.discoverIn? logicalNormalizer batchedRangeCurrent values [] graph
      (Matcher.Corpus.build logicalNormalizer graph)
      "Bash\nsed -n '300,420p' kernel/time/timekeeping.c; rg tsc arch/x86/kernel/tsc.c"
      none {} true true).map (fun discovery =>
        let extraction := Matcher.extraction discovery
        (extraction.priorOutcomes.isEmpty, extraction.residual.length)) =
      some (true, 1) := by
  native_decide

def groundedPast : Value :=
  .text "Bash rg n shared_symbol shared_path kernel"
def groundedCurrent : Value :=
  .text "Bash rg n shared_symbol shared_path kernel; inspect new_only"
def groundedResult : Value := .text "shared_symbol was observed"
def groundedOutcome : OutcomeEdge :=
  .make groundedPast groundedResult [] (by simp) (by simp [maxOutcomeObservations])
def backgroundOutcome (name : String) : OutcomeEdge :=
  .make (.text s!"Bash rg n {name} kernel") (.text name) []
    (by simp) (by simp [maxOutcomeObservations])

/-- A complete past Work is reusable inside a larger Demand while its remainder stays open. -/
theorem distinctive_fragment_is_reusable_without_closing_the_inquiry :
    let values := [groundedOutcome.relation,
      (backgroundOutcome "background_a").relation,
      (backgroundOutcome "background_b").relation,
      (backgroundOutcome "background_c").relation]
    (discover groundedCurrent values
      "Bash rg n shared_symbol shared_path kernel; inspect new_only").bind (fun discovery =>
        (discovery.hits.find? fun matched =>
          matched.edge.relation == groundedOutcome.relation).map fun matched =>
            (matched.applicability,
              (Matcher.extraction discovery).priorOutcomes.contains groundedResult,
              (Matcher.extraction discovery).residual.length)) =
      some (.completed, true, 1) := by
  native_decide

def singlyGroundedPast : Value :=
  .text "Bash rg n shared_symbol old_only kernel"
def singlyGroundedCurrent : Value :=
  .text "Bash rg n shared_symbol new_only kernel"
def singlyGroundedOutcome : OutcomeEdge :=
  .make singlyGroundedPast groundedResult []
    (by simp) (by simp [maxOutcomeObservations])

/- One distinctive token alone may connect advice but cannot control planning. -/
theorem one_distinctive_anchor_keeps_partial_work_advisory :
    let values := [singlyGroundedOutcome.relation,
      (backgroundOutcome "background_a").relation,
      (backgroundOutcome "background_b").relation,
      (backgroundOutcome "background_c").relation]
    (discover singlyGroundedCurrent values
      "Bash rg n shared_symbol new_only kernel").bind (fun discovery =>
        (discovery.hits.find? fun matched =>
          matched.edge.relation == singlyGroundedOutcome.relation).map fun matched =>
            (discovery.view.localUnions.length, matched.applicability,
              (Matcher.extraction discovery).priorOutcomes.contains groundedResult,
              (Matcher.extraction discovery).advisoryOutcomes.contains groundedResult)) =
      some (0, .advisory, false, true) := by
  native_decide

def fragmentPast : Value :=
  .text "Bash rg pvclock_only; update_vsyscall kernel/time/vsyscall.c"
def fragmentCurrent : Value :=
  .text "Bash inspect tsc_only; kernel/time/vsyscall.c update_vsyscall"
def fragmentResult : Value := .text
  "kernel/time/vsyscall.c update_vsyscall writes the vDSO time data"
def fragmentOutcome : OutcomeEdge :=
  .make fragmentPast fragmentResult []
    (by simp) (by simp [maxOutcomeObservations])
def fragmentBackground (name : String) : OutcomeEdge :=
  .make (.text s!"Bash inspect {name} unrelated/path.c") (.text name) []
    (by simp) (by simp [maxOutcomeObservations])

def loopPast : Value := .text
  "for spec in arch/x86/kernel/pvclock.c:1:120; do f=${spec%%:*}; r=${spec#*:}; sed -n ${r}p ${f}; done"
def loopCurrent : Value := .text
  "for spec in arch/x86/kernel/tsc.c:840:1030 arch/x86/kernel/acpi/boot.c:1800:1900; do f=${spec%%:*}; r=${spec#*:}; sed -n ${r}p ${f}; done"
def loopOutcome : OutcomeEdge :=
  .make loopPast (.text "pvclock source excerpt") []
    (by simp) (by simp [maxOutcomeObservations])

/-- Shared shell scaffolding may nominate advice but never erases a different loop body. -/
theorem shell_scaffolding_does_not_complete_an_atomic_native_work :
    let values := [loopOutcome.relation,
      (fragmentBackground "background_a").relation,
      (fragmentBackground "background_b").relation]
    (discover loopCurrent values
      "for spec in arch/x86/kernel/tsc.c:840:1030 arch/x86/kernel/acpi/boot.c:1800:1900; do f=${spec%%:*}; r=${spec#*:}; sed -n ${r}p ${f}; done").map
      (fun discovery =>
        let extraction := Matcher.extraction discovery
        (extraction.priorOutcomes.isEmpty,
          extraction.residual.length)) = some (true, 1) := by
  native_decide

/-- A shared fragment may Union, but neither enclosing operation is completed. -/
theorem fragment_union_does_not_invent_completed_work :
    let values := [fragmentOutcome.relation,
      (fragmentBackground "background_a").relation,
      (fragmentBackground "background_b").relation,
      (fragmentBackground "background_c").relation]
    (discover fragmentCurrent values
      "Bash inspect tsc_only; kernel/time/vsyscall.c update_vsyscall").map
      (fun discovery =>
        let extraction := Matcher.extraction discovery
        (discovery.view.localUnions.length,
          discovery.passes,
          extraction.priorOutcomes.contains fragmentResult,
          !extraction.advisoryOutcomes.isEmpty,
          extraction.residual.length)) =
      some (1, 2, false, true, 1) := by
  native_decide

def pipedPast : Value := .text
  "rg pvclock_only|update_vsyscall kernel/time/vsyscall.c|print old"
def pipedCurrent : Value := .text
  "rg tsc_only|kernel/time/vsyscall.c update_vsyscall|print new"
def pipedResult : Value := .text
  "kernel/time/vsyscall.c contains update_vsyscall"
def pipedOutcome : OutcomeEdge :=
  .make pipedPast pipedResult [] (by simp) (by simp [maxOutcomeObservations])

/-- A dependent pipeline may reconnect advice, but it is not a completed subwork. -/
theorem pipeline_overlap_stays_advisory :
    let values := [pipedOutcome.relation,
      (fragmentBackground "background_a").relation,
      (fragmentBackground "background_b").relation]
    (discover pipedCurrent values
      "rg tsc_only|kernel/time/vsyscall.c update_vsyscall|print new").bind
      (fun discovery =>
        (discovery.hits.find? fun matched =>
          matched.edge.relation == pipedOutcome.relation &&
            Matcher.atomText? matched.projectionWork =
              some "rg kernel/time/vsyscall.c update_vsyscall print").map fun matched =>
            (discovery.view.localUnions.length,
              Matcher.atomText? matched.projectionWork,
              (Matcher.extraction discovery).priorOutcomes.contains pipedResult,
              !(Matcher.extraction discovery).advisoryOutcomes.isEmpty,
              (Matcher.extraction discovery).residual.length)) =
      some (1, some "rg kernel/time/vsyscall.c update_vsyscall print", false, true, 1) := by
  native_decide

def prosePast : Value := .text
  "Inspect source alpha. Trace generic timekeeping through vdso clock_gettime realtime syscall. Return the result."
def proseCurrent : Value := .text
  "Inspect source beta. syscall realtime clock_gettime vdso timekeeping generic. Return the result."
def proseResult : Value := .text
  "Generic timekeeping supplies realtime through vdso clock_gettime with syscall fallback."
def proseOutcome : OutcomeEdge :=
  .make prosePast proseResult [] (by simp) (by simp [maxOutcomeObservations])

/-- Prose overlap may create Union evidence but cannot close another Work. -/
theorem grounded_prose_reverse_containment_stays_advisory :
    let values := [proseOutcome.relation,
      (fragmentBackground "background_a").relation,
      (fragmentBackground "background_b").relation,
      (fragmentBackground "background_c").relation]
    (discover proseCurrent values
      "Inspect source beta. syscall realtime clock_gettime vdso timekeeping generic. Return the result.").map
      (fun discovery =>
        let extraction := Matcher.extraction discovery
        (!discovery.view.localUnions.isEmpty, discovery.passes,
          extraction.priorOutcomes.contains proseResult,
          extraction.advisoryOutcomes.contains proseResult,
          extraction.residual.length)) =
      some (true, 2, false, true, 1) := by
  native_decide

def halfPast : Value := .text "alpha beta old route"
def halfCurrent : Value := .text "beta alpha new branch"
def halfResult : Value := .text "alpha beta were observed"
def halfOutcome : OutcomeEdge :=
  .make halfPast halfResult [] (by simp) (by simp [maxOutcomeObservations])

/-- A grounded half-overlap resaturates equality but leaves its enclosing clause open. -/
theorem grounded_half_overlap_is_advisory_delivery :
    let values := [halfOutcome.relation,
      (fragmentBackground "background_a").relation,
      (fragmentBackground "background_b").relation,
      (fragmentBackground "background_c").relation]
    (discover halfCurrent values "beta alpha new branch").map (fun discovery =>
      let extraction := Matcher.extraction discovery
      (discovery.view.localUnions.length, discovery.passes,
        extraction.priorOutcomes.contains halfResult,
        extraction.advisoryOutcomes.contains halfResult,
        extraction.residual.length)) =
      some (1, 2, false, true, 1) := by
  native_decide

def dominantPast : Value :=
  .text "rg n alpha beta gamma delta epsilon old_target"
def dominantCurrent : Value :=
  .text "rg n epsilon delta gamma beta alpha new_target extra"
def dominantResult : Value :=
  .text "alpha beta gamma delta epsilon were observed"
def dominantOutcome : OutcomeEdge :=
  .make dominantPast dominantResult [] (by simp) (by simp [maxOutcomeObservations])

/-- A high-scoring partial overlap may Union, but it never erases unfinished Work. -/
theorem dominant_partial_fragment_stays_advisory :
    let values := [dominantOutcome.relation,
      (fragmentBackground "background_a").relation,
      (fragmentBackground "background_b").relation,
      (fragmentBackground "background_c").relation]
    (discover dominantCurrent values
      "rg n epsilon delta gamma beta alpha new_target extra").map
      (fun discovery =>
        let extraction := Matcher.extraction discovery
        (discovery.view.localUnions.length, discovery.passes,
          extraction.priorOutcomes.contains dominantResult,
          extraction.advisoryOutcomes.contains dominantResult,
          extraction.residual.length)) =
      some (1, 2, false, true, 1) := by
  native_decide

def flagVariantPast : Value :=
  .text "rg n clocksource_select"
def flagVariantCurrent : Value :=
  .text "rg n c 45 clocksource_select"
def flagVariantResult : Value :=
  .text "clocksource_select is defined in kernel/time/clocksource.c"
def flagVariantOutcome : OutcomeEdge :=
  .make flagVariantPast flagVariantResult []
    (by simp) (by simp [maxOutcomeObservations])

/-- Forward support may complete while the larger current clause stays open. -/
theorem transport_flag_variation_keeps_current_clause_open :
    (discover flagVariantCurrent [flagVariantOutcome.relation]
      "rg n c 45 clocksource_select").map (fun discovery =>
        let extraction := Matcher.extraction discovery
        (discovery.view.localUnions.length,
          extraction.priorOutcomes.contains flagVariantResult,
          discovery.hits.any fun matched =>
            matched.work.demandInPrior.complete,
          extraction.residual.length)) =
      some (0, true, false, 1) := by
  native_decide

def searchedBootFile : Value :=
  .text "rg n pmtmr_ioport arch/x86/kernel/acpi/boot.c"
def readBootFile : Value :=
  .text "sed n 950 1030p arch/x86/kernel/acpi/boot.c"
def searchedBootResult : Value :=
  .text "arch/x86/kernel/acpi/boot.c contains pmtmr_ioport"
def searchedBootOutcome : OutcomeEdge :=
  .make searchedBootFile searchedBootResult []
    (by simp) (by simp [maxOutcomeObservations])

/- The same target alone is advice, not completion of a different operation. -/
theorem shared_target_reuses_observation_without_closing_demand :
    (discover readBootFile [searchedBootOutcome.relation,
      (backgroundOutcome "background_a").relation,
      (backgroundOutcome "background_b").relation,
      (backgroundOutcome "background_c").relation]
      "sed n 950 1030p arch/x86/kernel/acpi/boot.c").map (fun discovery =>
        let extraction := Matcher.extraction discovery
        (extraction.priorOutcomes.isEmpty,
          extraction.advisoryOutcomes.contains searchedBootResult,
          extraction.residual.length)) =
      some (true, true, 1) := by
  native_decide

def priorSourceRead : Value :=
  .text "shell sed n 1 280p drivers/clocksource/acpi_pm.c"
def differentSourceRead : Value :=
  .text "shell sed n 1 260p arch/x86/kernel/acpi/boot.c"
def priorSourceResult : Value := .text "contents of the ACPI PM clocksource"
def priorSourceOutcome : OutcomeEdge :=
  .make priorSourceRead priorSourceResult []
    (by simp) (by simp [maxOutcomeObservations])

/-- Shared shell syntax cannot erase reads of different targets and ranges. -/
theorem different_native_targets_are_advisory_only :
    (discover differentSourceRead [priorSourceOutcome.relation]
      "shell sed n 1 260p arch/x86/kernel/acpi/boot.c").map (fun discovery =>
        let extraction := Matcher.extraction discovery
        (extraction.priorOutcomes.isEmpty, extraction.residual.length)) =
      some (true, 1) := by
  native_decide

def sameTargetRead : Value :=
  .text "shell sed n 1 280p drivers/clocksource/acpi_pm.c"
def reorderedTargetRead : Value :=
  .text "drivers/clocksource/acpi_pm.c 280p 1 n sed shell"

/-- Syntax order may vary when every unit still identifies the same operation. -/
theorem equivalent_native_target_is_locally_unioned_and_completed :
    (discover reorderedTargetRead [priorSourceOutcome.relation]
      "drivers/clocksource/acpi_pm.c 280p 1 n sed shell").map (fun discovery =>
        let extraction := Matcher.extraction discovery
        (discovery.view.localUnions.length,
          extraction.priorOutcomes.contains priorSourceResult,
          extraction.residual.length)) =
      some (1, true, 1) := by
  native_decide

def genericClocksourceHeaderRead : Value :=
  .text "shell sed n 1 240p include/vdso/clocksource.h"
def architectureClocksourceHeaderRead : Value :=
  .text "shell sed n 1 240p arch/x86/include/asm/vdso/clocksource.h"
def genericClocksourceHeaderResult : Value :=
  .text "contents of the generic vDSO clocksource header"
def genericClocksourceHeaderOutcome : OutcomeEdge :=
  .make genericClocksourceHeaderRead genericClocksourceHeaderResult []
    (by simp) (by simp [maxOutcomeObservations])

/-- A shared path suffix can form advice, but cannot erase a different file read. -/
theorem path_suffix_overlap_never_completes_another_file :
    (discover architectureClocksourceHeaderRead
      [genericClocksourceHeaderOutcome.relation]
      "shell sed n 1 240p arch/x86/include/asm/vdso/clocksource.h").map
      (fun discovery =>
        let extraction := Matcher.extraction discovery
        (extraction.priorOutcomes.isEmpty, extraction.residual.length)) =
      some (true, 1) := by
  native_decide

def relativeGenericClocksourceHeaderRead : Value :=
  .text "./include/vdso/clocksource.h 240p 1 n sed shell"

/-- A leading relative-path marker is spelling, not a different operation. -/
theorem relative_path_spelling_preserves_operation_identity :
    (discover relativeGenericClocksourceHeaderRead
      [genericClocksourceHeaderOutcome.relation]
      "./include/vdso/clocksource.h 240p 1 n sed shell").map
      (fun discovery =>
        let extraction := Matcher.extraction discovery
        (discovery.view.localUnions.length,
          extraction.priorOutcomes.contains genericClocksourceHeaderResult,
          extraction.residual.length)) =
      some (1, true, 1) := by
  native_decide

end Eggshell.MatcherLaws
