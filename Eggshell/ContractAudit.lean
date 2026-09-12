module

import Eggshell.SearchRank
import Eggshell.SearchProvider
import Eggshell.Setup
public meta import Lean

open Lean

/- This module is imported by the test executable, not the product executable.
   Reject admissions and any new axiom outside Lean's standard logical basis. -/
run_meta do
  let contracts := #[
    ``Eggshell.SearchRank.unique_indices,
    ``Eggshell.SearchRank.selected_no_duplicates,
    ``Eggshell.SearchRank.selected_within_budget,
    ``Eggshell.SearchRank.selected_is_existing,
    ``Eggshell.SearchRank.selected_was_ranked,
    ``Eggshell.SearchRank.zero_budget_is_empty,
    ``Eggshell.Setup.configured_is_preserved,
    ``Eggshell.Setup.check_never_initializes,
    ``Eggshell.Setup.initialize_only_when_missing,
    ``Eggshell.SearchProvider.accepted_cache_identity,
    ``Eggshell.SearchProvider.changed_cache_text_rejected,
    ``Eggshell.SearchProvider.changed_cache_model_rejected]
  for contract in contracts do
    let axioms ← Lean.collectAxioms contract
    for dependency in axioms do
      unless #[``propext, ``Quot.sound, ``Classical.choice].contains dependency do
        throwError "{contract} depends on unapproved axiom {dependency}"
    logInfo m!"Audited {contract}: {axioms}"
