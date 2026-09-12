module

public import Eggshell.SearchUnicode
public import Lean.Data.Json

@[expose] public section

namespace Eggshell.SearchRank

@[extern "log1p"] opaque log1p (x : Float) : Float

def asciiTerm (c : Char) : Bool :=
  ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9') || "_./:-".contains c

def singleTerm (c : Char) : Bool :=
  (0x3040 ≤ c.toNat && c.toNat ≤ 0x30ff) || (0x3400 ≤ c.toNat && c.toNat ≤ 0x9fff)

def terms (text : String) : List String := Id.run do
  let folded := text.toList.flatMap (SearchUnicode.fold · |>.toList)
  let mut result := []
  let mut current := ""
  for c in folded do
    if asciiTerm c then current := current.push c
    else
      if !current.isEmpty then result := result ++ [current]; current := ""
      if singleTerm c then result := result ++ [String.singleton c]
  if !current.isEmpty then result := result ++ [current]
  return result.eraseDups

def anchor (term : String) : Bool :=
  term.toList.any fun c => "_/:.".contains c || SearchUnicode.isDigit c

def scoreOrder (a b : Float × Nat) : Bool :=
  a.1 > b.1 || (a.1 == b.1 && a.2 ≤ b.2)

def lexical (query : String) (candidates : List String) (anchors := false) : List Nat := Id.run do
  let wanted := (terms query).filter fun term => !anchors || anchor term
  let documents := candidates.map terms
  let mut scores := []
  for (document, index) in documents.zipIdx do
    let score := wanted.foldl (fun total term =>
      if document.contains term then
        let count := (documents.filter (·.contains term)).length
        total + log1p (documents.length.toFloat / count.toFloat)
      else total) (0 : Float)
    if score > 0 then scores := scores ++ [(score, index)]
  return (scores.mergeSort scoreOrder).map (·.2)

def fused (rankings : List (List Nat)) : List Nat :=
  let ids := rankings.flatten.eraseDups
  let scores := ids.map fun id =>
    (rankings.foldl (fun score ranking =>
      match (ranking.zipIdx.find? (·.1 == id)) with
      | some (_, rank) => score + 1 / (61 + rank).toFloat
      | none => score) (0 : Float), id)
  (scores.mergeSort scoreOrder).map (·.2)

/-- All provider output goes through this constructor. It cannot invent an
    index, duplicate an outcome, or exceed the selected context budget. -/
def select (count limit : Nat) (anchors ranking : List Nat) : List Nat :=
  ((anchors ++ ranking).eraseDups.filter (· < count)).take limit

theorem unique_indices (xs : List Nat) : xs.eraseDups.Nodup := by
  match xs with
  | [] => simp
  | x :: tail =>
    rw [List.eraseDups_cons, List.nodup_cons]
    constructor
    · simp
    · exact unique_indices (tail.filter fun y => !y == x)
termination_by xs.length
decreasing_by
  have := List.length_filter_le (fun y => !y == x) tail
  simp only [List.length_cons]
  omega

theorem selected_no_duplicates (n k : Nat) (a r : List Nat) : (select n k a r).Nodup := by
  exact (List.take_sublist k _).nodup (List.filter_sublist.nodup (unique_indices (a ++ r)))

theorem selected_within_budget (n k : Nat) (a r : List Nat) :
    (select n k a r).length ≤ k := by simp [select, List.length_take, Nat.min_le_left]

theorem selected_is_existing (n k : Nat) (a r : List Nat) (id : Nat)
    (member : id ∈ select n k a r) : id < n := by
  have h := List.mem_of_mem_take member
  have filtered := List.mem_filter.mp h
  simpa using filtered.2

theorem selected_was_ranked (n k : Nat) (a r : List Nat) (id : Nat)
    (member : id ∈ select n k a r) : id ∈ a ∨ id ∈ r := by
  have h := List.mem_of_mem_take member
  have filtered := (List.mem_filter.mp h).1
  simpa using filtered

theorem zero_budget_is_empty (n : Nat) (a r : List Nat) : select n 0 a r = [] := rfl

def windows (text : String) : List String :=
  let characters := text.toList
  (List.range ((max 1 characters.length + 383) / 384)).map fun index =>
    String.ofList ((characters.drop (index * 384)).take 512)

end Eggshell.SearchRank
