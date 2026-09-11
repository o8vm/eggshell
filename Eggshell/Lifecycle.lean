module

public import Lean.Data.Json.FromToJson

@[expose] public section

namespace Eggshell.Plugin

/-- A search may publish only into the turn and context which requested it. -/
structure RequestStamp where
  turn : String
  epoch : Nat
  deadline : Nat
  deriving Repr, Lean.ToJson, Lean.FromJson

def RequestStamp.accepts (request : RequestStamp) (turn : String) (epoch now : Nat) : Bool :=
  request.turn == turn && request.epoch == epoch && now < request.deadline

theorem expired_request_cannot_publish (request : RequestStamp) (turn : String)
    (epoch now : Nat) (expired : request.deadline ≤ now) :
    request.accepts turn epoch now = false := by
  simp [RequestStamp.accepts, Nat.not_lt.mpr expired]

theorem old_turn_cannot_publish (request : RequestStamp) (turn : String)
    (epoch now : Nat) (stale : request.turn ≠ turn) :
    request.accepts turn epoch now = false := by
  simp [RequestStamp.accepts, stale]

theorem old_context_cannot_publish (request : RequestStamp) (turn : String)
    (epoch now : Nat) (stale : request.epoch ≠ epoch) :
    request.accepts turn epoch now = false := by
  simp [RequestStamp.accepts, stale]

theorem accepted_request_is_current (request : RequestStamp) (turn : String)
    (epoch now : Nat) (accepted : request.accepts turn epoch now = true) :
    request.turn = turn ∧ request.epoch = epoch ∧ now < request.deadline := by
  simpa [RequestStamp.accepts, and_assoc] using accepted

end Eggshell.Plugin
