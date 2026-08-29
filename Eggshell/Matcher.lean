module

public import Eggshell.LogicalText
public import Eggshell.Persistence

@[expose] public section

namespace Eggshell.Matcher

open Eggshell.LogicalText

def atomText? : Value → Option String
  | .atom bytes => String.fromUTF8? bytes
  | .apply _ _ => none

/--
A logical interval remembers both its exact normalized bytes and its unit
ordinals.  Match preparation therefore never rescans an Atom to rediscover the
same byte-to-unit correspondence.
-/
structure IndexedSpan where
  span : ByteSpan
  first : Nat
  last : Nat
  deriving Repr, DecidableEq, BEq, Hashable

namespace IndexedSpan

def units (span : IndexedSpan) : List Nat :=
  (List.range (span.last - span.first)).map (span.first + ·)

end IndexedSpan

def indexedSpan? (logical : LogicalText.T) (span : ByteSpan) : Option IndexedSpan := do
  let ordinals := LogicalText.unitsIn logical span
  let first ← ordinals.head?
  let final ← ordinals.getLast?
  pure { span, first, last := final + 1 }

abbrev SurfaceIndex := Std.HashMap String (List IndexedSpan)

def surfaceIndex (text : LogicalText.T) : SurfaceIndex :=
  LogicalText.grams text |>.foldl (fun index gram =>
    let span : IndexedSpan := { span := gram.span, first := gram.first, last := gram.last }
    index.insert gram.text (span :: index.getD gram.text [])) {}

def surfaceKeys (index : SurfaceIndex) : Std.HashSet String :=
  index.fold (fun keys key _ => keys.insert key) {}

structure Pattern where
  logical : LogicalText.T
  surface : SurfaceIndex
  surfaces : Std.HashSet String

def makePattern (logical : LogicalText.T) : Pattern :=
  let surface := surfaceIndex logical
  {
    logical
    surface
    surfaces := surfaceKeys surface
  }

def compile (normalize : Normalizer) (text : String) : Pattern :=
  makePattern (LogicalText.build normalize text)

/-!
Native Work remains one persistent Atom and one Outcome owner.  The matcher
uses this private, rebuildable shell view only to prevent evidence from two
independent clauses being combined into a fragment that never occurred.
-/

inductive ShellQuote where
  | plain
  | single
  | double
  deriving Repr, DecidableEq

structure ShellSplit where
  quote : ShellQuote := .plain
  escaped : Bool := false
  parentheses : Nat := 0
  braces : Nat := 0
  current : List Char := []
  clauses : List String := []

namespace ShellSplit

def append (state : ShellSplit) (character : Char) : ShellSplit :=
  { state with current := character :: state.current }

def close (state : ShellSplit) : ShellSplit :=
  let clause := String.ofList state.current.reverse |>.trimAscii.copy
  if clause.isEmpty then { state with current := [] }
  else { state with current := [], clauses := clause :: state.clauses }

def topLevel (state : ShellSplit) : Bool :=
  state.quote = .plain && state.parentheses = 0 && state.braces = 0

end ShellSplit

def shellControlProgram (command : String) : Bool :=
  let text := command.trimAscii
  ["for ", "while ", "until ", "if ", "case ", "select ", "function "].any
      (fun marker => text.startsWith marker) ||
    ["; do", "; then", "; done", "; fi", "; esac"].any fun marker =>
      text.contains marker

/--
Split only unconditional top-level shell sequencing.  Quoted separators,
substitutions, pipelines, conditional `||`, and control programs stay atomic.
-/
def shellClauses (command : String) : List String :=
  if shellControlProgram command then [command.trimAscii.copy]
  else
    let rec scan (characters : List Char) (state : ShellSplit) : ShellSplit :=
      match characters with
      | [] => state.close
      | character :: tail =>
          if state.escaped then
            scan tail { (state.append character) with escaped := false }
          else match state.quote with
          | .single =>
              let state := state.append character
              scan tail (if character = '\'' then { state with quote := .plain } else state)
          | .double =>
              let state := state.append character
              if character = '\\' then scan tail { state with escaped := true }
              else scan tail (if character = '"' then { state with quote := .plain } else state)
          | .plain =>
              if character = '\\' then
                scan tail { (state.append character) with escaped := true }
              else if character = '\'' then
                scan tail { (state.append character) with quote := .single }
              else if character = '"' then
                scan tail { (state.append character) with quote := .double }
              else if character = '(' then
                scan tail { (state.append character) with
                  parentheses := state.parentheses + 1 }
              else if character = ')' then
                scan tail { (state.append character) with
                  parentheses := state.parentheses - 1 }
              else if character = '{' then
                scan tail { (state.append character) with braces := state.braces + 1 }
              else if character = '}' then
                scan tail { (state.append character) with braces := state.braces - 1 }
              else if state.topLevel && (character = ';' || character = '\n') then
                scan tail state.close
              else if state.topLevel && character = '&' then
                scan tail state.close
              else scan tail (state.append character)
      termination_by characters.length
    let clauses := (scan command.toList {}).clauses.reverse
    if clauses.isEmpty then [command.trimAscii.copy] else clauses

theorem shellClauses_ne_nil (command : String) : shellClauses command ≠ [] := by
  simp only [shellClauses]
  split
  · simp
  · split <;> simp_all

def shellTool (name : String) : Bool :=
  let normalized := name.toLower
  normalized = "bash" || normalized = "shell"

/-- Extract the shell program from lossless canonical native input for matching only. -/
def shellCommand? (input : String) : Option String := do
  let json ← (Lean.Json.parse input).toOption
  let command ← (json.getObjVal? "command").toOption
  command.getStr?.toOption

/-- A match-only view of one canonical `tool\ninput` Work Atom. -/
def nativeWorkSurfaces (text : String) : List String :=
  match text.splitOn "\n" with
  | [] => [text]
  | tool :: input =>
      if shellTool tool then
        let encoded := "\n".intercalate input
        let command := (shellCommand? encoded).getD encoded
        (shellClauses command).map (tool ++ "\n" ++ ·)
      else [text]

theorem nativeWorkSurfaces_ne_nil (text : String) : nativeWorkSurfaces text ≠ [] := by
  cases parts : text.splitOn "\n" with
  | nil => simp [nativeWorkSurfaces, parts]
  | cons tool input =>
      simp only [nativeWorkSurfaces, parts]
      split
      · intro empty
        exact shellClauses_ne_nil
          ((shellCommand? ("\n".intercalate input)).getD ("\n".intercalate input))
          (List.map_eq_nil_iff.mp empty)
      · simp

structure WorkPattern where
  pattern : Pattern
  value : Value
  /-- True only when this pattern denotes the complete persistent Work owner. -/
  whole : Bool

def compileWorkPatterns (normalize : Normalizer)
    (text : String) (native : Bool) : List WorkPattern :=
  let owner : WorkPattern := {
    pattern := compile normalize text
    value := .text text
    whole := true
  }
  if !native then [owner]
  else
    match nativeWorkSurfaces text with
    | [surface] => [{
        pattern := compile normalize surface
        value := .text text
        whole := true
      }]
    | fragments => owner :: fragments.map fun fragment => {
        pattern := compile normalize fragment
        value := .text fragment
        whole := false
      }

/-- Every rebuildable match view retains its complete authoritative Work owner. -/
theorem compileWorkPatterns_has_whole (normalize : Normalizer)
    (text : String) (native : Bool) :
    ∃ pattern ∈ compileWorkPatterns normalize text native,
      pattern.value = .text text ∧ pattern.whole = true := by
  simp only [compileWorkPatterns]
  split
  · simp
  · cases surfaces : nativeWorkSurfaces text with
    | nil => simp
    | cons first rest =>
        cases rest with
        | nil => simp
        | cons second rest => simp

/--
Whole native invocations are authoritative owners, not fragment search
domains.  Once an invocation has observable clause boundaries, comparisons
use those clauses only; otherwise an orderless match could combine a path from
one clause with a range or symbol from another and invent Work that never ran.
-/
def comparisonPatterns (patterns : List WorkPattern) : List WorkPattern :=
  let clauses := patterns.filter (!·.whole)
  if clauses.isEmpty then patterns else clauses

theorem comparisonPatterns_clause_only {patterns : List WorkPattern}
    (hasClause : (patterns.filter (!·.whole)).isEmpty = false)
    {pattern : WorkPattern} (member : pattern ∈ comparisonPatterns patterns) :
    pattern.whole = false := by
  simp only [comparisonPatterns, hasClause, Bool.false_eq_true, ↓reduceIte,
    List.mem_filter] at member
  simpa using member.2

structure Evidence where
  query : IndexedSpan
  target : IndexedSpan
  deriving Repr, DecidableEq, BEq, Hashable

/--
Every exact one-to-three-unit anchor remains evidence, but lookup is indexed
instead of comparing every query position with every target position.
-/
def surfaceEvidenceFromQuery (query target : Pattern) : List Evidence :=
  query.surface.fold (fun evidence gram spans =>
    spans.foldl (fun evidence querySpan =>
      (target.surface.getD gram []).foldl
          (fun evidence targetSpan =>
            { query := querySpan, target := targetSpan } :: evidence)
          evidence) evidence) []

def surfaceEvidenceFromTarget (query target : Pattern) : List Evidence :=
  target.surface.fold (fun evidence gram spans =>
    spans.foldl (fun evidence targetSpan =>
      (query.surface.getD gram []).foldl
          (fun evidence querySpan =>
            { query := querySpan, target := targetSpan } :: evidence)
          evidence) evidence) []

/-- The indexed join scans its smaller side; orientation of Evidence never changes. -/
def surfaceEvidence (query target : Pattern) : List Evidence :=
  if query.surface.size ≤ target.surface.size then
    surfaceEvidenceFromQuery query target
  else
    surfaceEvidenceFromTarget query target

def evidenceWeight (weights : Array Nat) (evidence : Evidence) : Nat :=
  evidence.query.units.foldl (fun total ordinal =>
    total + weights.getD ordinal 1) 0

def preferredEvidence (weights : Array Nat)
    (left right : Evidence) : Bool :=
  if evidenceWeight weights left != evidenceWeight weights right then
    evidenceWeight weights left > evidenceWeight weights right
  else if left.query.units.length != right.query.units.length then
    left.query.units.length > right.query.units.length
  else if left.target.units.length != right.target.units.length then
    left.target.units.length < right.target.units.length
  else if left.target.span.start != right.target.span.start then
    left.target.span.start < right.target.span.start
  else left.query.span.start < right.query.span.start

def rankedEvidence (weights : List Nat) (items : List Evidence) : List Evidence :=
  let weights := weights.toArray
  (items.toArray.mergeSort fun left right =>
    !preferredEvidence weights right left).toList

/-- Sorting evidence changes extraction cost only; it cannot invent or drop evidence. -/
theorem mem_rankedEvidence (weights : List Nat) (items : List Evidence)
    (item : Evidence) :
    item ∈ rankedEvidence weights items ↔ item ∈ items := by
  simp [rankedEvidence]

structure Coverage where
  coveredUnits : List Nat
  totalUnits : Nat
  coveredWeight : Nat
  totalWeight : Nat
  distinctiveAnchors : Nat
  querySpans : List ByteSpan
  targetSpans : List ByteSpan
  deriving Repr, DecidableEq

namespace Coverage

def complete (coverage : Coverage) : Bool :=
  coverage.totalUnits != 0 && coverage.coveredUnits.length = coverage.totalUnits

/--
Semantic completion is exact: every logical unit must occur in the current
Demand. Extraction cost never changes this judgment.
-/
theorem complete_iff_units (coverage : Coverage) :
    coverage.complete = true ↔
      coverage.totalUnits != 0 ∧
        coverage.coveredUnits.length = coverage.totalUnits := by
  simp [complete]

/--
Coverage magnitude is an extraction cost, not an admission threshold. A
natural-language overlap may be weak yet useful advisory work; only complete
forward coverage may erase a proposed operation.
-/
def compareScore (left right : Coverage) : Ordering :=
  compare (left.coveredWeight * right.totalWeight)
    (right.coveredWeight * left.totalWeight)

end Coverage

/-
An anchor identifies Work only when it is rare in the current Outcome corpus.
The criterion is relative rather than vocabulary-specific: a unit may occur in
at most one eighth of candidates, with one occurrence admitted in a small
corpus. Common repository roots and transport syntax therefore lose authority,
while symbols and natural-language terms retain it when they distinguish Work.
-/
def rareAnchor (noveltyCeiling weight : Nat) : Bool :=
  let candidateCount := noveltyCeiling - 1
  let documentFrequency := noveltyCeiling - weight
  documentFrequency ≤ Nat.max 1 (candidateCount / 8)

theorem rareAnchor_iff_frequency_bound (noveltyCeiling weight : Nat) :
    rareAnchor noveltyCeiling weight = true ↔
      noveltyCeiling - weight ≤ Nat.max 1 ((noveltyCeiling - 1) / 8) := by
  simp [rareAnchor]

def distinctiveAnchorCount (query : Pattern) (weights : List Nat)
    (noveltyCeiling : Nat) (covered : List Nat) : Nat :=
  (covered.filterMap fun ordinal =>
    if rareAnchor noveltyCeiling (weights.getD ordinal 0) then
      match query.logical.units[ordinal]? with
      | some unit => if unit.text.isEmpty then none else some unit.text
      | none => none
    else none).eraseDups.length

def workCoverage (query : Pattern) (weights : List Nat)
    (noveltyCeiling : Nat) (ranked : List Evidence) : Option Coverage :=
  let selected := ranked.foldl (fun selected candidate =>
    let queryUsed := selected.flatMap (·.query.units)
    let targetUsed := selected.flatMap (·.target.units)
    if candidate.query.units.any queryUsed.contains ||
        candidate.target.units.any targetUsed.contains then selected
    else selected ++ [candidate]) []
  if selected.isEmpty then none else
  let workUnits := List.range query.logical.units.length
  let covered := selected.flatMap (·.query.units) |> hashDistinct
  let coveredWeight := covered.foldl (fun total ordinal =>
    total + weights.getD ordinal 1) 0
  let totalWeight := workUnits.foldl (fun total ordinal =>
    total + weights.getD ordinal 1) 0
  some {
    coveredUnits := covered
    totalUnits := workUnits.length
    coveredWeight
    totalWeight
    distinctiveAnchors := distinctiveAnchorCount query weights noveltyCeiling covered
    querySpans := selected.map (·.query.span) |> hashDistinct
    targetSpans := selected.map (·.target.span) |> hashDistinct
  }

def sameLogicalUnits (left right : Pattern) : Bool :=
  left.logical.units.map (·.text) == right.logical.units.map (·.text)

def completeCoverage (pattern : Pattern) (weights : List Nat)
    (noveltyCeiling : Nat) : Coverage :=
  let covered := List.range pattern.logical.units.length
  {
    coveredUnits := covered
    totalUnits := covered.length
    coveredWeight := weights.foldl (· + ·) 0
    totalWeight := weights.foldl (· + ·) 0
    distinctiveAnchors := distinctiveAnchorCount pattern weights noveltyCeiling covered
    querySpans := pattern.logical.units.map (·.logical)
    targetSpans := pattern.logical.units.map (·.logical)
  }

/-- Every aligned unit of one atomic Work participates; no best-fragment shortcut closes it. -/
def pairedCoverages (query target : Pattern)
    (queryWeights targetWeights : List Nat) (noveltyCeiling : Nat) :
    List (Coverage × Coverage) :=
  if LogicalText.isEmpty query.logical || LogicalText.isEmpty target.logical ||
      queryWeights.length != query.logical.units.length ||
      targetWeights.length != target.logical.units.length then []
  else if sameLogicalUnits query target then
    [(completeCoverage query queryWeights noveltyCeiling,
      completeCoverage target targetWeights noveltyCeiling)]
  else
    let forward := rankedEvidence queryWeights (surfaceEvidence query target)
    let reverse := rankedEvidence targetWeights (surfaceEvidence target query)
    match workCoverage query queryWeights noveltyCeiling forward,
        workCoverage target targetWeights noveltyCeiling reverse with
    | some queryInTarget, some targetInQuery => [(queryInTarget, targetInQuery)]
    | _, _ => []

/--
Outcome text is fallible context, never equality authority.  Its coverage is
therefore the exact orderless multiset intersection of normalized units.  Each
target occurrence is consumed once, avoiding the quadratic Cartesian product
of repeated words in large native results while preserving concrete source
spans for the handoff.
-/
def surfaceContextCover (query target : Pattern)
    (weights : List Nat) (noveltyCeiling : Nat) : Option Coverage :=
  if LogicalText.isEmpty query.logical || LogicalText.isEmpty target.logical ||
      weights.length != query.logical.units.length then none
  else
    let rec consume : List LogicalText.Unit → List Nat → Nat →
        SurfaceIndex → List Nat → Nat → List ByteSpan →
        List ByteSpan → (List Nat × Nat × List ByteSpan × List ByteSpan)
      | [], _, _, _, covered, coveredWeight, querySpans, targetSpans =>
          (covered.reverse, coveredWeight, querySpans.reverse, targetSpans.reverse)
      | _, [], _, _, covered, coveredWeight, querySpans, targetSpans =>
          (covered.reverse, coveredWeight, querySpans.reverse, targetSpans.reverse)
      | unit :: units, weight :: rest, ordinal, remaining, covered,
          coveredWeight, querySpans, targetSpans =>
          let occurrences := (remaining.getD unit.text []).filter fun span =>
            span.last = span.first + 1
          match occurrences with
          | [] => consume units rest (ordinal + 1) remaining covered
              coveredWeight querySpans targetSpans
          | targetSpan :: tail =>
              consume units rest (ordinal + 1) (remaining.insert unit.text tail)
                (ordinal :: covered) (coveredWeight + weight)
                (unit.logical :: querySpans) (targetSpan.span :: targetSpans)
    let (covered, coveredWeight, querySpans, targetSpans) :=
      consume query.logical.units weights 0 target.surface [] 0 [] []
    if covered.isEmpty then none else
      some {
        coveredUnits := covered
        totalUnits := query.logical.units.length
        coveredWeight
        totalWeight := weights.foldl (· + ·) 0
        distinctiveAnchors :=
          distinctiveAnchorCount query weights noveltyCeiling covered
        querySpans
        targetSpans
      }

def fragmentJudgment (priorInDemand demandInPrior : Coverage)
    (sameFragment subwork pastWholeWork groundedFragment : Bool) :
    ApplicabilityJudgment :=
  /-
  Local equality and applicability are separate. A whole historical Work may
  control the current plan only when it is wholly contained in the Demand. A
  smaller run-local fragment may control only that same fragment when actual
  result bytes ground it. The fragment need not equal the larger invocation
  that carried it; the unmatched Demand remains open. Ungrounded overlap stays
  advisory.
  -/
  let reusable := sameFragment && subwork &&
    ((pastWholeWork && priorInDemand.complete) ||
      (groundedFragment &&
        (priorInDemand.complete || demandInPrior.complete)))
  let direction := if reusable then .pastWorkInsideCurrentDemand
    else if priorInDemand.complete then .pastWorkInsideCurrentDemand
    else if demandInPrior.complete then .currentDemandInsidePastWork
    else .overlapping
  { direction, reusableOutcome := reusable }

/-- Completion requires local identity and one complete, observed positive subwork. -/
theorem fragment_completion_requires_local_identity
    (priorInDemand demandInPrior : Coverage)
    (sameFragment subwork pastWholeWork groundedFragment : Bool)
    (completed : (fragmentJudgment priorInDemand demandInPrior
      sameFragment subwork pastWholeWork groundedFragment).delivery = .completed) :
    sameFragment = true ∧ subwork = true ∧
      ((pastWholeWork = true ∧ priorInDemand.complete = true) ∨
        (groundedFragment = true ∧
          (priorInDemand.complete = true ∨ demandInPrior.complete = true))) := by
  have reusable := ApplicabilityJudgment.completed_only_for_forward_reusable completed |>.2
  simp only [fragmentJudgment, Bool.and_eq_true, Bool.or_eq_true] at reusable
  exact ⟨reusable.1.1, reusable.1.2, reusable.2⟩

/-- Equality may reconnect a parent turn, but only an All child may erase Work. -/
theorem parent_turn_never_completes
    (priorInDemand demandInPrior : Coverage)
    (sameFragment pastWholeWork groundedFragment : Bool) :
    (fragmentJudgment priorInDemand demandInPrior sameFragment false
      pastWholeWork groundedFragment).delivery =
      .advisory := by
  simp [fragmentJudgment, ApplicabilityJudgment.delivery]

structure WorkAlignment where
  priorInDemand : Coverage
  demandInPrior : Coverage
  /-- True exactly when the Outcome owner occupies an All-child position. -/
  subwork : Bool
  /-- A match-only clause may reconnect its owner, but cannot complete that owner. -/
  pastWholeWork : Bool
  /-- The whole current and historical Work already share one active equivalence class. -/
  wholeWorkIdentity : Bool
  /-- The selected fragments share one active run-local equivalence class. -/
  fragmentIdentity : Bool
  currentFragment : Value
  pastFragment : Value
  currentSpan : ByteSpan
  pastSpan : ByteSpan

/--
Equality and context have different witnesses.  A child Operation is grounded
by the fragment currently being proposed; a parent Turn only nominates a prior
subtree, so its Outcome is grounded against the whole current Demand.
-/
def WorkAlignment.contextDemand (aligned : WorkAlignment) (current : Value) : Value :=
  if aligned.subwork then aligned.currentFragment else current

theorem WorkAlignment.parent_contextDemand {aligned : WorkAlignment} {current : Value}
    (parent : aligned.subwork = false) :
    aligned.contextDemand current = current := by
  simp [WorkAlignment.contextDemand, parent]

theorem WorkAlignment.subwork_contextDemand {aligned : WorkAlignment} {current : Value}
    (subwork : aligned.subwork = true) :
    aligned.contextDemand current = aligned.currentFragment := by
  simp [WorkAlignment.contextDemand, subwork]

/-- Outcome text may satisfy a Demand fragment, but never establishes Work identity. -/
structure ContextAlignment where
  demandInOutcome : Coverage
  /-- Exact source lines carrying the matched Outcome evidence, never new authority. -/
  outcomeFragment : Option Value := none
  alreadyVisible : Bool := false

/-- One Outcome owner with independent Work-identity and positive-result lanes. -/
structure Match where
  demand : Value
  edge : OutcomeEdge
  work : WorkAlignment
  context : Option ContextAlignment := none
  /-- External relatedness is deliverable context, never equality authority. -/
  retrieved : Bool := false

namespace Match

def groundedContext (matched : Match) : Bool :=
  matched.context.any fun context =>
    context.demandInOutcome.coveredWeight != 0

/-- Historical Outcome bytes may ground advice; bytes from the current result may not. -/
def transportGroundedContext (matched : Match) : Bool :=
  matched.context.any fun context =>
    !context.alreadyVisible && context.demandInOutcome.coveredWeight != 0

theorem transportGroundedContext_is_grounded {matched : Match}
    (transported : matched.transportGroundedContext = true) :
    matched.groundedContext = true := by
  cases context : matched.context with
  | none => simp [transportGroundedContext, context] at transported
  | some value =>
      simp [transportGroundedContext, groundedContext, context] at transported ⊢
      exact transported.2

/-- A native fragment is grounded only by result bytes projected from its owner. -/
def groundedOutcomeFragment (matched : Match) : Bool :=
  matched.context.any fun context =>
    context.demandInOutcome.coveredWeight != 0 &&
      context.outcomeFragment.isSome

def workJudgment (matched : Match) : ApplicabilityJudgment :=
  fragmentJudgment matched.work.priorInDemand matched.work.demandInPrior
    matched.work.fragmentIdentity matched.work.subwork matched.work.pastWholeWork
    matched.groundedOutcomeFragment

def judgment (matched : Match) : ApplicabilityJudgment :=
  if matched.retrieved then
    { direction := .overlapping, reusableOutcome := false }
  else matched.workJudgment

def applicability (matched : Match) : Applicability :=
  if matched.judgment.delivery = .completed then .completed
  else .advisory

def projectionWork (matched : Match) : Value :=
  /-
  A child Outcome may satisfy one demanded fragment. A parent Turn is advisory
  for the current Demand; making the whole parent an All-child would incorrectly
  demand every unrelated historical sibling. The original owner remains Exact
  provenance on the projected Outcome.
  -/
  if matched.work.subwork then matched.work.currentFragment else matched.demand

theorem parent_projection_keeps_current_demand {matched : Match}
    (parent : matched.work.subwork = false) :
    matched.projectionWork = matched.demand := by
  simp [projectionWork, parent]

def projectionOutcome (matched : Match) : Value :=
  /-
  Authority remains the whole durable Outcome. Transport is smaller: a parent
  synthesis and a whole Operation keep the whole result, while a bounded
  native clause carries only the exact result fragment that grounded it. The
  derived Outcome cites its durable owner as Exact provenance.
  -/
  if !matched.work.subwork || matched.work.wholeWorkIdentity ||
      (matched.workJudgment.delivery = .completed &&
        matched.work.pastWholeWork && matched.work.priorInDemand.complete) then
    matched.edge.outcome
  else
    (matched.context.bind (·.outcomeFragment)).getD matched.edge.outcome

/-- A transported result is either its authority or exact bytes grounded in it. -/
theorem projectionOutcome_is_owned_or_grounded (matched : Match) :
    matched.projectionOutcome = matched.edge.outcome ∨
      ∃ context fragment,
        matched.context = some context ∧
        context.outcomeFragment = some fragment ∧
        matched.projectionOutcome = fragment := by
  unfold projectionOutcome
  split
  · exact Or.inl rfl
  · cases matched.context with
    | none =>
        left
        rfl
    | some context =>
        cases projected : context.outcomeFragment with
        | none =>
            left
            simp [projected]
        | some fragment =>
            right
            exact ⟨context, fragment, rfl, projected, by simp [projected]⟩

/--
Local fragment identity derives one ordinary run-local Outcome.  Its Exact
observation is the durable Outcome relation that supplied the result, so the
derived edge neither invents an outcome nor becomes persistent authority.
-/
def projectedEdge (matched : Match) : OutcomeEdge :=
  if matched.projectionWork == matched.edge.work &&
      matched.projectionOutcome == matched.edge.outcome then matched.edge else
    .make matched.projectionWork matched.projectionOutcome [matched.edge.relation]
      (by simp) (by simp [maxOutcomeObservations])

@[simp]
theorem projectedEdge_outcome (matched : Match) :
    matched.projectedEdge.outcome = matched.projectionOutcome := by
  unfold projectedEdge
  split
  · rename_i accepted
    simp only [Bool.and_eq_true, beq_iff_eq] at accepted
    exact accepted.2.symm
  · rfl

/-- A fragment projection either is its durable owner or cites that owner exactly. -/
theorem projectedEdge_has_owner_provenance (matched : Match) :
    matched.projectedEdge = matched.edge ∨
      matched.edge.relation ∈ matched.projectedEdge.observations := by
  unfold projectedEdge
  split
  · exact Or.inl rfl
  · exact Or.inr (by simp [OutcomeEdge.make])

def demandCoverage (matched : Match) : Option Coverage :=
  some matched.work.demandInPrior

/--
Work identity nominates automatic handoff. Outcome text never creates Union;
it only proves that an already-Unioned Work fragment has an observed owner.
-/
def automatic (matched : Match) : Bool :=
  if matched.retrieved then true else
  /-
  Completion and delivery are separate. A complete subwork may control one
  replan; one positive-weight result match may still connect fallible advice.
  Neither case lets zero-weight transport syntax enter Demand.
  -/
  if matched.work.subwork then
    matched.work.fragmentIdentity &&
      (matched.workJudgment.delivery = .completed ||
        matched.transportGroundedContext ||
        (matched.groundedContext &&
          (matched.work.priorInDemand.complete ||
            matched.work.demandInPrior.complete ||
            matched.work.priorInDemand.distinctiveAnchors != 0 ||
            matched.work.demandInPrior.distinctiveAnchors != 0)))
  else
    /-
    A parent Turn is never completed by this lane. Intent verbs normally do
    not reappear in an observed result, so requiring complete result coverage
    would discard the shared synthesis that links two different inquiries.
    One corpus-distinctive Work anchor in the result is sufficient for advisory
    projection; it cannot create Union or erase Work.
    -/
    matched.work.wholeWorkIdentity ||
      (matched.work.fragmentIdentity && matched.groundedContext &&
        (matched.work.priorInDemand.distinctiveAnchors > 1 ||
          matched.work.demandInPrior.distinctiveAnchors > 1))

/-- Grounded parent synthesis is deliverable advice without becoming Work completion. -/
theorem grounded_parent_context_is_automatic (matched : Match)
    (parent : matched.work.subwork = false)
    (identity : matched.work.fragmentIdentity = true)
    (grounded : matched.groundedContext = true)
    (anchors : matched.work.priorInDemand.distinctiveAnchors > 1 ∨
      matched.work.demandInPrior.distinctiveAnchors > 1) :
    matched.automatic = true := by
  simp [automatic, parent, identity, grounded, anchors]

/-- Partial child identity alone may saturate, but cannot transport an ungrounded result. -/
theorem advisory_subwork_automatic_requires_grounded_context (matched : Match)
    (intrinsic : matched.retrieved = false)
    (subwork : matched.work.subwork = true)
    (advisory : matched.workJudgment.delivery ≠ .completed)
    (automatic : matched.automatic = true) :
  matched.groundedContext = true := by
  simp [Match.automatic, intrinsic, subwork, advisory] at automatic
  rcases automatic.2 with transported | grounded
  · exact transportGroundedContext_is_grounded transported
  · exact grounded.1

end Match

def materializeFragment (source : LogicalText.T) (spans : List ByteSpan) :
    Option (Value × ByteSpan) := do
  let sourceSpans ← LogicalText.sourceSpans? source spans
  let fragments ← sourceSpans.mapM (LogicalText.sourceSlice? source)
  let sourceSpan ← LogicalText.envelope? sourceSpans
  /-
  This Atom is semantic identity, not a display excerpt.  Joining selected
  source pieces with whitespace preserves their units without inventing an
  ellipsis token that would make the derived fragment impossible to cover.
  -/
  let fragment := " ".intercalate fragments
  if fragment.trimAscii.isEmpty then none else pure (.text fragment, sourceSpan)

/-- Exact source parts intersecting a set of source spans. -/
def intersectingSourceParts (sourceSpans : List ByteSpan) (separator source : String) :
    List String :=
  let (_, selected) := source.splitOn separator |>.foldl
    (init := (0, [])) fun (offset, selected) line =>
      let stop := offset + line.toUTF8.size
      let intersects := sourceSpans.any fun span =>
        span.start < stop && offset < span.stop
      (stop + separator.toUTF8.size,
        if intersects then selected ++ [line] else selected)
  selected

/--
Project only native result records.  A turn Outcome is already one coherent
natural-language synthesis and crosses the graph boundary whole, once.  A
native result can be arbitrarily large, so only its exact intersecting lines
cross while the durable owner remains whole in `.egg`.
-/
def materializeContext (source : LogicalText.T) (spans : List ByteSpan)
    (native : Bool) :
    Option Value := do
  if !native then none
  let sourceSpans ← LogicalText.sourceSpans? source spans
  /-
  Canonical native JSON retains string newlines as `\n`. Project those logical
  lines without flattening the authoritative object, its keys, or its types.
  -/
  let separator := if source.original.contains "\\n" then "\\n" else "\n"
  let selected := intersectingSourceParts sourceSpans separator source.original
  let fragment := "\n".intercalate selected
  if fragment.trimAscii.isEmpty then none else pure (.text fragment)

/-- The only searchable Work owners are existing positive Outcome relations. -/
def outcomeCandidates (graph : WorkGraph) : List OutcomeEdge := graph.outcomes

@[simp]
theorem outcomeCandidates_eq (graph : WorkGraph) :
    outcomeCandidates graph = graph.outcomes := rfl

structure Candidate where
  edge : OutcomeEdge
  work : Pattern
  /-- Rebuildable structural views of the same persistent Work owner. -/
  workPatterns : List WorkPattern
  outcome : Option Pattern
  /-- Exact occurrence distinguishes native operations from ordinary All children. -/
  native : Bool

/--
Native and turn occurrences already have opposite semantic orientation. A
native occurrence cites `[observed outcome, invoked Work]`; a turn occurrence
cites `[requested Work, final outcome]`. Relation position therefore recovers
the boundary without an Atom kind or a second persistent operator.
-/
def nativeOccurrenceFor (edge : OutcomeEdge) : Value → Bool
  | .apply .occurrence arguments =>
      match Relation.splitOccurrence arguments.toList with
      | some ([observed, work], _) => observed == edge.outcome && work == edge.work
      | _ => false
  | _ => false

def nativeOutcome (edge : OutcomeEdge) : Bool :=
  edge.observations.any (nativeOccurrenceFor edge)

theorem OutcomeEdge.native_has_oriented_occurrence {edge : OutcomeEdge}
    (native : nativeOutcome edge = true) :
    ∃ occurrence ∈ edge.observations, nativeOccurrenceFor edge occurrence = true := by
  exact List.any_eq_true.mp native

/-- One legal Work-to-Work comparison; clauses never cross this boundary. -/
structure PatternPair where
  past : Pattern
  current : Pattern
  pastValue : Value
  currentValue : Value
  pastWhole : Bool
  retrieved : Bool := false

def Candidate.intrinsicPairs (candidate : Candidate) (quotient : Quotient)
    (current : Value) (currentPattern : Pattern)
    (currentPatterns : List WorkPattern) : List PatternPair :=
  if quotient.toEquality.same current candidate.edge.work then [{
    past := candidate.work
    current := currentPattern
    pastValue := candidate.edge.work
    currentValue := current
    pastWhole := true
  }] else
    comparisonPatterns candidate.workPatterns |>.flatMap fun past =>
      comparisonPatterns currentPatterns |>.map fun present => {
        past := past.pattern
        current := present.pattern
        pastValue := past.value
        currentValue := present.value
        pastWhole := past.whole
      }

def Candidate.retrievalPair (candidate : Candidate) (current : Value)
    (currentPattern : Pattern) : PatternPair := {
  past := candidate.work
  current := currentPattern
  pastValue := candidate.edge.work
  currentValue := current
  pastWhole := true
  retrieved := true
}

/--
One immutable compilation of every Outcome owner. Candidate indexes are
rebuildable acceleration only; the authoritative candidate universe remains
exactly `graph.outcomes`.
-/
structure Corpus where
  candidates : List Candidate
  frequencies : Std.HashMap String Nat
  subworks : List Value

namespace Corpus

def compileCandidate (normalize : Normalizer) (edge : OutcomeEdge) : Option Candidate := do
    let text ← atomText? edge.work
    let work := compile normalize text
    let native := nativeOutcome edge
    let workPatterns := compileWorkPatterns normalize text native
    /-
    Outcome text is a positive-relation surface lane, not equality authority.
    -/
    let outcome := (atomText? edge.outcome).map fun text =>
      makePattern (LogicalText.build normalize text)
    pure { edge, work, workPatterns, outcome, native }

def fromCandidates (candidates : List Candidate) (subworks : List Value) : Corpus :=
  let subworks := subworks.eraseDups
  let frequencies := candidates.foldl (fun frequencies candidate =>
    ((candidate.work :: candidate.outcome.toList).flatMap (fun pattern =>
      pattern.logical.units.map (·.text)) |> hashDistinct).foldl
      (fun frequencies unit =>
        frequencies.insert unit (frequencies.getD unit 0 + 1)) frequencies) {}
  { candidates, frequencies, subworks }

def build (normalize : Normalizer) (graph : WorkGraph) : Corpus :=
  fromCandidates ((outcomeCandidates graph).filterMap
    (compileCandidate normalize)) graph.subworks

/-
Staged Outcomes extend the immutable corpus by compiling only unseen owners.
Document frequencies are rebuilt from the small compiled index; committed
Work patterns are not rescanned at every hook.
-/
def extend (normalize : Normalizer) (corpus : Corpus)
    (graph : WorkGraph) : Corpus :=
  let unseen := graph.outcomes.filter fun edge => corpus.candidates.all fun candidate =>
    candidate.edge.relation != edge.relation
  fromCandidates (corpus.candidates ++ unseen.filterMap
    (compileCandidate normalize)) (corpus.subworks ++ graph.subworks)

/--
Numeric ranges and one- or two-letter transport words carry no independent
Work identity. They still participate in exact surface coverage, but `rg`,
`nl`, and similar scaffolding cannot by themselves nominate a Work fragment.
One non-ASCII scalar remains meaningful because many languages encode a whole
word in one scalar.
-/
def identifyingUnit (unit : String) : Bool :=
  match unit.toList with
  | [] => false
  | first :: rest => first.val ≥ 128 ||
      ((first.isAlpha || first = '_') && rest.length ≥ 2)

/-- Exact, rebuildable document novelty; never persistent semantic authority. -/
def unitWeight (corpus : Corpus) (unit : String) : Nat :=
  if !identifyingUnit unit then 0 else
  corpus.candidates.length + 1 -
    Nat.min corpus.candidates.length (corpus.frequencies.getD unit 0)

/--
Native operation framing is positional. The tool constructor, operation verb,
and option names cannot become identity merely because their spelling is rare
in one corpus. The same words remain ordinary natural language elsewhere.
-/
def informationWeights (corpus : Corpus) (pattern : Pattern)
    (native : Bool := false) : List Nat :=
  let rec visit : List LogicalText.Unit → Nat → List Nat
    | [], _ => []
    | unit :: rest, ordinal =>
        let precededByDash := if unit.source.start = 0 then false else
          pattern.logical.original.toUTF8.get! (unit.source.start - 1) == 45
        let weight := if native && (ordinal < 2 || precededByDash) then 0
          else corpus.unitWeight unit.text
        weight :: visit rest (ordinal + 1)
  visit pattern.logical.units 0

end Corpus

/--
Exact symmetric intersection.  Scanning the smaller immutable key set changes
only cost: a surface is shared iff either set contains a key from the other.
-/
def sharesSurface (left right : Pattern) : Bool :=
  if left.surfaces.size ≤ right.surfaces.size then
    left.surfaces.any right.surfaces.contains
  else
    right.surfaces.any left.surfaces.contains

def externallyNominated (relations : List Value) (candidate : Candidate) : Bool :=
  relations.contains candidate.edge.relation

structure SemanticNominations where
  related : List Value := []

def SemanticNominations.contains (nominations : SemanticNominations)
    (candidate : Candidate) : Bool :=
  externallyNominated nominations.related candidate

def nominated (query : Pattern)
    (semantic : SemanticNominations) (candidate : Candidate) : Bool :=
  sharesSurface query candidate.work ||
    semantic.contains candidate

/--
Every admitted item remains an existing positive Outcome owner. An optional
semantic process can nominate an owner but cannot manufacture Work, Outcome,
provenance, or a relation outside the authoritative corpus.
-/
def admittedCandidates (query : Pattern)
    (corpus : Corpus) (semantic : SemanticNominations) : List Candidate :=
  corpus.candidates.filter (nominated query semantic)

theorem admittedCandidate_has_outcome_owner
    {query : Pattern} {corpus : Corpus} {semantic : SemanticNominations}
    {candidate : Candidate}
    (admitted : candidate ∈ admittedCandidates query corpus semantic) :
    candidate ∈ corpus.candidates := by
  exact (List.mem_filter.mp admitted).1

/--
The candidate universe is exactly the owners of Outcome relations. Arbitrary
Atoms can provide evidence, but only an Outcome owner can erase completed work.
-/
def findIn (normalize : Normalizer) (quotient : Quotient)
    (corpus : Corpus) (current : Value) (currentText : String)
    (evidenceText : Option String := none)
    (semantic : SemanticNominations := {})
    (currentNative : Bool := false) : List Match :=
  let currentPattern := compile normalize currentText
  let currentPatterns := compileWorkPatterns normalize currentText currentNative
  /-
  Native results can reveal a symbol that reconnects historical context, but
  they are not the current Work. The context lane is surface-only and cannot
  create Local Union.
  -/
  let noveltyCeiling := corpus.candidates.length + 1
  /-
  Candidate admission is Work-to-Work only. Outcome text supplies the payload
  and its smallest relevant projection after a Work match; it is not a second
  retrieval engine that can inject unrelated history into Demand.
  -/
  admittedCandidates currentPattern corpus semantic |>.flatMap
      fun candidate =>
    let edge := candidate.edge
    /-
    Retrieval is an independent advisory lane, not a fallback after surface
    failure. A weak shared token must not hide a stronger semantic retrieval.
    It is placed first so an identical intrinsic alignment is processed later
    and remains the authoritative identity/applicability judgment.
    -/
    let related := if externallyNominated semantic.related candidate then
      [candidate.retrievalPair current currentPattern] else []
    let pairs := related ++ candidate.intrinsicPairs quotient current
      currentPattern currentPatterns
    pairs.flatMap fun pair =>
      let pastWeights := corpus.informationWeights pair.past candidate.native
      let currentWeights := corpus.informationWeights pair.current currentNative
      let alignments := if pair.retrieved then
        [(completeCoverage pair.past pastWeights noveltyCeiling,
          completeCoverage pair.current currentWeights noveltyCeiling)]
        else pairedCoverages pair.past pair.current
          pastWeights currentWeights noveltyCeiling
      alignments.filterMap fun (priorInDemand, demandInPrior) => do
        let pastComplete := priorInDemand.complete
        let currentComplete := demandInPrior.complete
        let (pastSpans, currentSpans) ←
          if pastComplete then
            some (priorInDemand.querySpans, priorInDemand.targetSpans)
          else if currentComplete then
            some (demandInPrior.targetSpans, demandInPrior.querySpans)
          else if priorInDemand.compareScore demandInPrior != .lt then
            some (priorInDemand.querySpans, priorInDemand.targetSpans)
          else
            some (demandInPrior.targetSpans, demandInPrior.querySpans)
        let pastSpan ← LogicalText.envelope? pastSpans
        let currentSpan ← LogicalText.envelope? currentSpans
        let pastFragment := if priorInDemand.coveredUnits.length =
            pair.past.logical.units.length then pair.pastValue else
          (materializeFragment pair.past.logical pastSpans).map (·.1) |>.getD pair.pastValue
        let currentFragment := if demandInPrior.coveredUnits.length =
            pair.current.logical.units.length then pair.currentValue else
          (materializeFragment pair.current.logical currentSpans).map (·.1) |>.getD pair.currentValue
        let subwork := corpus.subworks.any (quotient.toEquality.same edge.work)
        let wholeWorkIdentity := quotient.toEquality.same current edge.work
        let preliminaryWork : WorkAlignment := {
          priorInDemand
          demandInPrior
          subwork
          pastWholeWork := pair.pastWhole
          wholeWorkIdentity
          fragmentIdentity := quotient.toEquality.same currentFragment pastFragment
          currentFragment
          pastFragment
          currentSpan
          pastSpan
        }
        let context : Option ContextAlignment := do
          let outcomePattern ← candidate.outcome
          let contextDemandText := atomText? (preliminaryWork.contextDemand current)
            |>.getD currentText
          let contextDemandPattern := makePattern
            (LogicalText.build normalize contextDemandText)
          let contextDemandWeights := corpus.informationWeights contextDemandPattern
            currentNative
          /-
          Result coverage grounds an already-Unioned Work fragment in observed
          bytes. It never creates equality: external retrieval stays advisory,
          and the original Outcome relation remains Exact provenance.
          -/
          match surfaceContextCover contextDemandPattern outcomePattern contextDemandWeights
              noveltyCeiling with
          | some demandInOutcome =>
              pure {
                demandInOutcome
                outcomeFragment := materializeContext outcomePattern.logical
                  demandInOutcome.targetSpans candidate.native
                alreadyVisible := false
              }
          | none =>
              let evidence ← evidenceText
              let evidencePattern := makePattern (LogicalText.build normalize evidence)
              let outcomeWeights := corpus.informationWeights outcomePattern
              let outcomeInContext ← surfaceContextCover outcomePattern evidencePattern
                outcomeWeights noveltyCeiling
              pure {
                demandInOutcome := outcomeInContext
                alreadyVisible := true
              }
        pure {
          demand := current
          edge := edge
          work := preliminaryWork
          context := context
          retrieved := pair.retrieved
        }

def find (normalize : Normalizer) (quotient : Quotient)
    (graph : WorkGraph) (current : Value) (currentText : String) : List Match :=
  findIn normalize quotient (Corpus.build normalize graph)
    current currentText none {}

def localUnion? (quotient : Quotient) (inquiry : Value)
    (matched : Match) : Option UnionEdge := do
  if matched.retrieved then none
  let aligned := matched.work
  /-
  Surface and configured semantic matching nominate only reversible
  Inquiry-local equality. Applicability separately proves whether the selected
  historical Outcome may erase a complete small Work; otherwise the Union
  remains advisory context.
  -/
  if !aligned.priorInDemand.complete && !aligned.demandInPrior.complete &&
      aligned.priorInDemand.coveredWeight = 0 &&
      aligned.demandInPrior.coveredWeight = 0 then none else
  if quotient.toEquality.same aligned.currentFragment aligned.pastFragment then none
  else if exactSafe : Value.sameExactFootprint
      aligned.currentFragment aligned.pastFragment then
    some {
      left := aligned.currentFragment
      right := aligned.pastFragment
      scope := .run inquiry
      exactAuthority := Value.sameExactFootprint_sound exactSafe
    }
  else none

/-- A matcher nomination can only produce reversible Inquiry-local equality. -/
theorem localUnion_is_run_scoped {quotient : Quotient} {inquiry : Value}
    {matched : Match} {edge : UnionEdge}
    (created : localUnion? quotient inquiry matched = some edge) :
    edge.scope = .run inquiry := by
  simp only [localUnion?] at created
  split at created <;> try contradiction
  split at created <;> try contradiction
  split at created <;> try contradiction
  split at created <;> try contradiction
  next =>
    have equality := Option.some.inj created
    subst edge
    rfl

/-- Broad semantic retrieval can expose an Outcome but cannot assert identity. -/
theorem retrieved_never_unions (quotient : Quotient) (inquiry : Value)
    (matched : Match) (retrieved : matched.retrieved = true) :
    localUnion? quotient inquiry matched = none := by
  simp [localUnion?, retrieved]

/-- Broad semantic retrieval is always advisory, independent of its score. -/
theorem retrieved_is_advisory (matched : Match)
    (retrieved : matched.retrieved = true) :
    matched.judgment.delivery = .advisory := by
  simp [Match.judgment, retrieved, ApplicabilityJudgment.delivery]

/-- Transport-only overlap cannot nominate fragment identity. -/
theorem no_complete_or_informative_fragment_no_local_union {quotient : Quotient}
    {inquiry : Value} {matched : Match} {aligned : WorkAlignment}
    (work : matched.work = aligned)
    (pastIncomplete : aligned.priorInDemand.complete = false)
    (currentIncomplete : aligned.demandInPrior.complete = false)
    (past : aligned.priorInDemand.coveredWeight = 0)
    (current : aligned.demandInPrior.coveredWeight = 0) :
    localUnion? quotient inquiry matched = none := by
  simp [localUnion?, work, pastIncomplete, currentIncomplete, past, current]

/-- Advisory result evidence cannot create or change a Local Union. -/
theorem localUnion_ignores_context (quotient : Quotient) (inquiry : Value)
    (matched : Match) :
    localUnion? quotient inquiry { matched with context := none } =
      localUnion? quotient inquiry matched := by
  rfl

def distinctLocalUnions (edges : List UnionEdge) : List UnionEdge :=
  edges.foldl (fun accepted edge =>
    if UnionEdge.newPair accepted edge.left edge.right then accepted ++ [edge]
    else accepted) []

def Match.continuationWork (matched : Match) : Value :=
  matched.projectionWork

/--
A parent match reconnects its existing positive subtree; a child match keeps
the locally identified fragment.  In both cases the current Work stays open.
-/
def continuation? (current : Value) (currentText : String)
    (hits : List Match) : Option AllEdge :=
  let work := hits.filterMap fun matched =>
    if matched.applicability != .irrelevant && matched.work.subwork then
      some matched.continuationWork
    else none
  let work := work |> hashDistinct |>.filter (current != ·)
  if work.isEmpty then none else
    let children := work ++ [HandoffRemainder.value currentText]
    if nonempty : children ≠ [] then
      if excludes : current ∉ children then some (.make current children nonempty excludes)
      else none
    else none

/-- Every synthesized continuation is open by construction. -/
theorem continuation_has_open_remainder {current : Value} {currentText : String}
    {hits : List Match} {edge : AllEdge}
    (created : continuation? current currentText hits = some edge) :
    HandoffRemainder.value currentText ∈ edge.children := by
  simp only [continuation?] at created
  split at created <;> try contradiction
  split at created <;> try contradiction
  split at created <;> try contradiction
  next nonempty excludes =>
    have equal := Option.some.inj created
    subst edge
    simp

theorem continuation_parent {current : Value} {currentText : String}
    {hits : List Match} {edge : AllEdge}
    (created : continuation? current currentText hits = some edge) :
    edge.parent = current := by
  simp only [continuation?] at created
  split at created <;> try contradiction
  split at created <;> try contradiction
  split at created <;> try contradiction
  next nonempty excludes =>
    have equal := Option.some.inj created
    subst edge
    rfl

structure Discovery where
  view : RunView
  hits : List Match
  current : Value
  passes : Nat

def Match.admission? (matched : Match) : Option OutcomeAdmission :=
  if matched.automatic then some {
    demand := matched.projectionWork
    relation := matched.projectedEdge.relation
    judgment := matched.judgment
  } else none

/-- Extract policy is a projection of selected Matches, never a second authority. -/
def admissions (hits : List Match) : List OutcomeAdmission :=
  hits.filterMap Match.admission?

def Discovery.policy (discovery : Discovery) : OutcomePolicy :=
  .admitted (admissions discovery.hits)

theorem admission_has_automatic_match {hits : List Match} {admission : OutcomeAdmission}
    (present : admission ∈ admissions hits) :
    ∃ matched ∈ hits, matched.automatic = true ∧
      admission.demand = matched.projectionWork ∧
      admission.relation = matched.projectedEdge.relation ∧
      admission.judgment = matched.judgment := by
  simp only [admissions, List.mem_filterMap] at present
  obtain ⟨matched, member, created⟩ := present
  unfold Match.admission? at created
  split at created
  · rename_i automatic
    simp only [Option.some.injEq] at created
    subst admission
    exact ⟨matched, member, automatic, rfl, rfl, rfl⟩
  · contradiction

def sameMatch (left right : Match) : Bool :=
  left.demand == right.demand && left.edge.relation == right.edge.relation &&
    left.work.currentFragment == right.work.currentFragment &&
    left.work.pastFragment == right.work.pastFragment

def upsertMatch (previous : List Match) (matched : Match) : List Match :=
  matched :: previous.filter (fun existing => !sameMatch matched existing)

def addMatches (previous newMatches : List Match) : List Match :=
  newMatches.foldl upsertMatch previous

def projectMatches (base : WorkGraph) (hits : List Match) : WorkGraph :=
  let outcomes := hits.foldl (fun current matched =>
    if !matched.automatic then current
    else
      let edge := matched.projectedEdge
      if current.any (fun existing => existing.relation == edge.relation) then current
      else current ++ [edge]) base.outcomes
  { base with outcomes }

def demandedMatches (normalize : Normalizer)
    (corpus : Corpus) (view : RunView) (current : Value)
    (evidenceText : Option String) (semantic : SemanticNominations)
    (currentNative : Bool) (tasks : List Value) : List Match :=
  tasks.flatMap fun task =>
    match atomText? task with
    | some text => findIn normalize view.quotient corpus task text
        (if task == current then evidenceText else none)
        (if task == current then semantic else {})
        (task == current && currentNative)
    | none => []

/--
A run-local continuation child is the result of a Match already accumulated in
this saturation. Re-matching that synthetic child would let advisory overlap
re-enter as a smaller Demand and incorrectly promote itself to completed Work.
Only the root or Demand newly exposed by the authoritative graph is matchable.
-/
def freshDemand (current : Value) (runAll : List AllEdge) (task : Value) : Bool :=
  task == current || runAll.all fun edge => !edge.children.contains task

theorem continuation_child_is_not_fresh {current child : Value}
    {runAll : List AllEdge} {edge : AllEdge}
    (edgeMember : edge ∈ runAll) (childMember : child ∈ edge.children)
    (different : child ≠ current) :
    freshDemand current runAll child = false := by
  unfold freshDemand
  rw [show (child == current) = false by simpa using different]
  simp only [Bool.false_or]
  apply List.all_eq_false.mpr
  exact ⟨edge, edgeMember, by simp [childMember]⟩

def newLocalUnions (view : RunView) (inquiry : Value)
    (hits : List Match) : List UnionEdge :=
  distinctLocalUnions <| hits.filterMap (localUnion? view.quotient inquiry)

def rootContinuation? (graph : WorkGraph) (equality : Equality)
    (current : Value) (currentText : String) (hits : List Match) : Option AllEdge := do
  if !(graph.decompositionsFor equality current).isEmpty then none else
  continuation? current currentText (hits.filter fun matched =>
    matched.demand == current && matched.automatic)

/-- Match fragments refine one external continuation; they cannot create independent plans. -/
theorem rootContinuation_parent {graph : WorkGraph} {equality : Equality}
    {current : Value} {currentText : String} {hits : List Match} {edge : AllEdge}
    (created : rootContinuation? graph equality current currentText hits = some edge) :
    edge.parent = current := by
  simp only [rootContinuation?] at created
  split at created <;> try contradiction
  next => exact continuation_parent created

def addContinuations (previous proposed : List AllEdge) : List AllEdge :=
  proposed.foldl (fun accepted edge =>
    if accepted.any (fun existing => existing.relation == edge.relation) then accepted
    else accepted ++ [edge]) previous

/--
Candidate discovery, Run-local equality, quotient rebuilding, positive relation
projection, and Extract share one graph. Nothing produced here is durable.
-/
def discoverIn? (normalize : Normalizer) (inquiry : Value)
    (storedValues : List Value) (persistent : List UnionEdge)
    (base : WorkGraph) (corpus : Corpus) (currentText : String)
    (evidenceText : Option String := none)
    (semantic : SemanticNominations := {})
    (enableLocalUnion : Bool := true)
    (currentNative : Bool := false) : Option Discovery := do
  let current := Value.text currentText
  let roots (localUnions : List UnionEdge) (runAll : List AllEdge) :=
    current :: storedValues ++ localUnions.flatMap (fun edge =>
      [edge.left, edge.right]) ++ runAll.map (·.relation)
  let rec saturate : Nat → Nat → List UnionEdge → List AllEdge →
      List Match → Option Discovery
    | 0, _, _, _, _ => none
    | fuel + 1, passes, localUnions, runAll, accumulated => do
        let graph := projectMatches { base with all := runAll ++ base.all } accumulated
        let view ← RunView.make? graph (roots localUnions runAll) persistent localUnions
        let policy := OutcomePolicy.admitted (admissions accumulated)
        let demanded := (view.extractWith policy current).discovery
        let matchable := demanded.filter fun task =>
          !HandoffRemainder.isValue task && freshDemand current runAll task
        let passHits := demandedMatches normalize corpus view current
          evidenceText semantic currentNative matchable
        /-
        Retrieval-only mode keeps the identical candidate and graph projection
        lanes, but grants neither equality nor work erasure. Marking every hit
        retrieved makes that causal boundary explicit in the existing judgment.
        -/
        let passHits := if enableLocalUnion then passHits else
          passHits.map fun matched => { matched with retrieved := true }
        let accumulated := addMatches accumulated passHits
        let proposed := if enableLocalUnion then
          newLocalUnions view inquiry passHits else []
        if !proposed.isEmpty then
          saturate fuel (passes + 1) (localUnions ++ proposed) runAll accumulated
        else
          let proposedAll := match rootContinuation? graph view.quotient.toEquality
              current currentText accumulated with
            | some edge => [edge]
            | none => []
          /-
          Only an All that connects another Work subtree can expose new Demand.
          The remainder-only frame is installed in the final view without
          feeding its synthetic open leaf back into the same matcher run.
          -/
          let bridges := proposedAll.filter (fun edge => edge.children.length > 1)
          let nextRunAll := addContinuations runAll bridges
          let newAll := nextRunAll.length != runAll.length
          if newAll then
            saturate fuel (passes + 1) localUnions nextRunAll accumulated
          else
            let finalRunAll := addContinuations runAll proposedAll
            let finalGraph := projectMatches
              { base with all := finalRunAll ++ base.all } accumulated
            let finalView ← RunView.make? finalGraph (roots localUnions finalRunAll)
              persistent localUnions
            pure {
              view := finalView
              hits := accumulated
              current
              passes
            }
  let semanticBound := (current :: storedValues).flatMap Value.semanticNodes
    |> hashDistinct |>.length
  saturate ((semanticBound + 1) * (base.outcomes.length + 1) + 1)
    0 [] [] []

/-- Convenience boundary for callers without a reusable daemon-side corpus. -/
def discover? (normalize : Normalizer) (inquiry : Value)
    (storedValues : List Value) (persistent : List UnionEdge)
    (currentText : String) : Option Discovery :=
  let base := WorkGraph.fromValues storedValues
  discoverIn? normalize inquiry storedValues persistent base
    (Corpus.build normalize base) currentText none {}

def extraction (discovery : Discovery) : Extraction :=
  discovery.view.extractWith discovery.policy discovery.current

theorem completed_match_is_forward_and_reusable {matched : Match}
    (completed : matched.judgment.delivery = .completed) :
    matched.judgment.direction = .pastWorkInsideCurrentDemand ∧
      matched.judgment.reusableOutcome = true :=
  ApplicabilityJudgment.completed_only_for_forward_reusable completed

theorem completed_match_has_local_subwork {matched : Match}
    (completed : matched.judgment.delivery = .completed) :
    matched.work.fragmentIdentity = true ∧ matched.work.subwork = true ∧
      ((matched.work.pastWholeWork = true ∧
          matched.work.priorInDemand.complete = true) ∨
        (matched.groundedOutcomeFragment = true ∧
          (matched.work.priorInDemand.complete = true ∨
            matched.work.demandInPrior.complete = true))) ∧
      (matched.projectedEdge = matched.edge ∨
        matched.edge.relation ∈ matched.projectedEdge.observations) := by
  unfold Match.judgment at completed
  split at completed
  · simp [ApplicabilityJudgment.delivery] at completed
  · unfold Match.workJudgment at completed
    have reusable := fragment_completion_requires_local_identity _ _ _ _ _ _ completed
    exact ⟨reusable.1, reusable.2.1, reusable.2.2,
      Match.projectedEdge_has_owner_provenance matched⟩

/--
End-to-end connection theorem: every Work erased by Matcher→Extract comes from
an automatic Match over an existing Outcome owner and passed the forward,
reusable applicability gate. Candidate similarity alone is insufficient.
-/
theorem extraction_completed_has_match {discovery : Discovery} {demand : Value}
    {edge : OutcomeEdge}
    (used : (demand, edge) ∈
      (extraction discovery).selection.completedUses) :
    ∃ matched ∈ discovery.hits,
      matched.automatic = true ∧ matched.projectionWork = demand ∧
      matched.projectedEdge.relation = edge.relation ∧
      matched.judgment.direction = .pastWorkInsideCurrentDemand ∧
      matched.judgment.reusableOutcome = true ∧
      matched.work.fragmentIdentity = true ∧
      matched.work.subwork = true ∧
      ((matched.work.pastWholeWork = true ∧
          matched.work.priorInDemand.complete = true) ∨
        (matched.groundedOutcomeFragment = true ∧
          (matched.work.priorInDemand.complete = true ∨
            matched.work.demandInPrior.complete = true))) ∧
      (matched.projectedEdge = matched.edge ∨
        matched.edge.relation ∈ matched.projectedEdge.observations) ∧
      edge.outcome ∈ (extraction discovery).priorOutcomes := by
  have valid := Extract.runWithPolicy_sound discovery.view.graph
    discovery.view.quotient.toEquality discovery.policy discovery.current
  have sound := Selection.completedUse_sound valid used
  obtain ⟨admission, member, demandEq, relationEq, delivered⟩ :=
    OutcomePolicy.admitted_delivery_witness sound.2.2 (by decide)
  obtain ⟨matched, hit, automatic, matchDemand, matchRelation, matchJudgment⟩ :=
    admission_has_automatic_match member
  have completed : matched.judgment.delivery = .completed := by
    rw [← matchJudgment, delivered]
  have applicable := completed_match_is_forward_and_reusable completed
  have grounded := completed_match_has_local_subwork completed
  exact ⟨matched, hit, automatic, matchDemand.symm.trans demandEq,
    matchRelation.symm.trans relationEq, applicable.1, applicable.2,
    grounded.1, grounded.2.1, grounded.2.2.1, grounded.2.2.2,
    (extraction discovery).prior_visible _
      (Selection.completedUse_outcome_is_prior used)⟩

/-- Advisory delivery is likewise selected Match data, never free-floating retrieval. -/
theorem extraction_advisory_has_match {discovery : Discovery} {demand : Value}
    {edge : OutcomeEdge}
    (used : (demand, edge) ∈
      (extraction discovery).selection.advisoryUses) :
    ∃ matched ∈ discovery.hits,
      matched.automatic = true ∧ matched.projectionWork = demand ∧
      matched.projectedEdge.relation = edge.relation ∧
      matched.judgment.delivery = .advisory := by
  have valid := Extract.runWithPolicy_sound discovery.view.graph
    discovery.view.quotient.toEquality discovery.policy discovery.current
  have sound := Selection.advisoryUse_sound valid used
  obtain ⟨admission, member, demandEq, relationEq, delivered⟩ :=
    OutcomePolicy.admitted_delivery_witness sound.2.2 (by decide)
  obtain ⟨matched, hit, automatic, matchDemand, matchRelation, matchJudgment⟩ :=
    admission_has_automatic_match member
  exact ⟨matched, hit, automatic, matchDemand.symm.trans demandEq,
    matchRelation.symm.trans relationEq, matchJudgment ▸ delivered⟩

end Eggshell.Matcher
