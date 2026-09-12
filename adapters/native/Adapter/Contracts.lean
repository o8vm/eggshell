module

public import Lean

@[expose] public section

namespace Eggshell.Adapter

inductive Host where
  | claude | gemini | cursor | opencode
  deriving BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

def Host.name : Host → String
  | .claude => "claude"
  | .gemini => "gemini"
  | .cursor => "cursor"
  | .opencode => "opencode"

def Host.parse (name : String) : Except String Host :=
  match name with
  | "claude" => .ok .claude
  | "gemini" => .ok .gemini
  | "cursor" => .ok .cursor
  | "opencode" => .ok .opencode
  | _ => .error "expected claude, gemini, cursor, or opencode"

inductive Event where
  | start | prompt | before | after | answer | stop | interrupt | compact | finish
  deriving BEq, DecidableEq, Repr

def Event.engineName : Event → String
  | .start => "SessionStart"
  | .prompt => "UserPromptSubmit"
  | .before => "PreToolUse"
  | .after => "PostToolUse"
  | .answer => "AssistantMessage"
  | .stop => "Stop"
  | .interrupt => "Interrupt"
  | .compact => "PostCompact"
  | .finish => "SessionEnd"

def events : Host → List (String × Event)
  | .claude => [("SessionStart", .start), ("UserPromptSubmit", .prompt),
      ("PreToolUse", .before), ("PostToolUse", .after), ("PostToolUseFailure", .after),
      ("Stop", .stop), ("StopFailure", .interrupt), ("SessionEnd", .finish)]
  | .gemini => [("SessionStart", .start), ("BeforeAgent", .prompt),
      ("BeforeTool", .before), ("AfterTool", .after), ("AfterAgent", .stop),
      ("PreCompress", .compact), ("SessionEnd", .finish)]
  | .cursor => [("sessionStart", .start), ("beforeSubmitPrompt", .prompt),
      ("preToolUse", .before), ("postToolUse", .after), ("postToolUseFailure", .after),
      ("afterAgentResponse", .answer), ("stop", .stop), ("preCompact", .compact),
      ("sessionEnd", .finish)]
  | .opencode => [("SessionStart", .start), ("UserPromptSubmit", .prompt),
      ("PreToolUse", .before), ("PostToolUse", .after), ("PostCompact", .compact),
      ("Stop", .stop), ("Interrupt", .interrupt), ("SessionEnd", .finish)]

def contextAllowed : Host → Event → Bool
  | .claude, .prompt | .claude, .before | .claude, .after => true
  | .gemini, .prompt | .gemini, .after => true
  | .cursor, .after => true
  | .opencode, .prompt | .opencode, .after => true
  | _, _ => false

/-- This is the entire host-output vocabulary. There is no approval or retry. -/
inductive Reply where
  | quiet
  | context (text : String)
  | deny (reason : String)
  deriving BEq, DecidableEq, Repr

def projectReply (host : Host) (event : Event) (context denial : Option String) : Reply :=
  if event == .before then
    match denial with
    | some reason => .deny reason
    | none => if contextAllowed host event then context.map Reply.context |>.getD .quiet else .quiet
  else if contextAllowed host event then context.map Reply.context |>.getD .quiet else .quiet

theorem stop_is_quiet (h : Host) (c d : Option String) :
    projectReply h .stop c d = .quiet := by cases h <;> rfl

theorem interrupt_is_quiet (h : Host) (c d : Option String) :
    projectReply h .interrupt c d = .quiet := by cases h <;> rfl

theorem finish_is_quiet (h : Host) (c d : Option String) :
    projectReply h .finish c d = .quiet := by cases h <;> rfl

theorem unsupported_cursor_prompt_is_quiet (c d : Option String) :
    projectReply .cursor .prompt c d = .quiet := rfl

/-- A receipt exists in the acknowledge phase only after publishing completed.
    The IO interpreter constructs this value after its output write and flush. -/
structure Published where
  receipt : String

def receiptToAck (reply : Reply) (published : Published) : Option String :=
  match reply with
  | .quiet => none
  | .context _ | .deny _ => some published.receipt

theorem quiet_never_acknowledged (p : Published) : receiptToAck .quiet p = none := rfl

structure Identity where
  host : Host
  native : String
  deriving BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- Hashes locate a file; the full identity authorizes access to its contents. -/
def ownerMatches (stored requested : Identity) : Bool := decide (stored = requested)

theorem accepted_owner_is_exact (a b : Identity) (h : ownerMatches a b = true) : a = b := by
  simpa [ownerMatches] using h

theorem different_host_rejected (a b : Identity) (h : a.host ≠ b.host) :
    ownerMatches a b = false := by
  simp only [ownerMatches, decide_eq_false_iff_not]
  intro equal
  exact h (congrArg Identity.host equal)

theorem different_chat_rejected (a b : Identity) (h : a.native ≠ b.native) :
    ownerMatches a b = false := by
  simp only [ownerMatches, decide_eq_false_iff_not]
  intro equal
  exact h (congrArg Identity.native equal)

inductive CommitStep where
  | journal | consume
  deriving BEq, DecidableEq

def commitPlan (terminal : Bool) : List CommitStep :=
  if terminal then [.journal, .consume] else [.consume]

theorem terminal_is_journaled_first : commitPlan true = [.journal, .consume] := rfl

theorem no_consumption_without_journal_prefix (steps : List CommitStep)
    (h : steps = commitPlan true) :
    ∃ rest, steps = .journal :: rest ∧ .consume ∈ rest := by
  subst steps
  exact ⟨[.consume], rfl, by simp⟩

structure Call where
  id : String
  native : String
  turn : String
  finished : Bool := false
  writable : Bool := false
  deriving BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- An attributed result carries a proof of origin, not a guessed current turn. -/
def chooseCall (calls : List Call) : Option { c : Call //
    c ∈ calls ∧ ∀ other ∈ calls, other.turn = c.turn } :=
  match calls with
  | [] => none
  | head :: tail =>
      if h : ∀ other ∈ head :: tail, other.turn = head.turn then
        some ⟨head, by simp, h⟩
      else none

theorem chosen_call_is_original (calls : List Call)
    (selected : { c : Call // c ∈ calls ∧ ∀ other ∈ calls, other.turn = c.turn }) :
    selected.val ∈ calls := selected.property.1

theorem ambiguous_calls_rejected (calls : List Call) (a b : Call)
    (ha : a ∈ calls) (hb : b ∈ calls) (different : a.turn ≠ b.turn) :
    chooseCall calls = none := by
  cases calls with
  | nil => simp at ha
  | cons head tail =>
    simp only [chooseCall]
    split
    next all => exact False.elim (different ((all a ha).trans (all b hb).symm))
    next => rfl

def maySaveAnswer (enabled writable active completed : Bool) : Bool :=
  enabled && writable && active && completed

theorem saved_answer_is_authorized (e w o c : Bool) (h : maySaveAnswer e w o c = true) :
    e = true ∧ w = true ∧ o = true ∧ c = true := by
  simpa [maySaveAnswer, and_assoc] using h

theorem aborted_answer_not_saved (e w o : Bool) : maySaveAnswer e w o false = false := by
  simp [maySaveAnswer]

/-- Configuration editing uses these exact functions on serialized entries. -/
def removeOwned (owned entries : List String) : List String :=
  entries.filter fun entry => !owned.contains entry

theorem unrelated_entry_preserved (owned entries : List String) (entry : String)
    (present : entry ∈ entries) (unowned : entry ∉ owned) :
    entry ∈ removeOwned owned entries := by
  simp [removeOwned, present, unowned]

theorem removed_entry_was_owned (owned entries : List String) (entry : String)
    (present : entry ∈ entries) (removed : entry ∉ removeOwned owned entries) : entry ∈ owned := by
  by_cases member : entry ∈ owned
  · exact member
  · exact False.elim (removed (unrelated_entry_preserved owned entries entry present member))

end Eggshell.Adapter
