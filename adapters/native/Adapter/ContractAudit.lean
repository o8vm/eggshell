module

import Adapter.Protocol
public meta import Lean

open Lean

run_meta do
  let contracts := #[
    ``Eggshell.Adapter.stop_is_quiet,
    ``Eggshell.Adapter.interrupt_is_quiet,
    ``Eggshell.Adapter.finish_is_quiet,
    ``Eggshell.Adapter.unsupported_cursor_prompt_is_quiet,
    ``Eggshell.Adapter.quiet_never_acknowledged,
    ``Eggshell.Adapter.accepted_owner_is_exact,
    ``Eggshell.Adapter.different_host_rejected,
    ``Eggshell.Adapter.different_chat_rejected,
    ``Eggshell.Adapter.terminal_is_journaled_first,
    ``Eggshell.Adapter.no_consumption_without_journal_prefix,
    ``Eggshell.Adapter.chosen_call_is_original,
    ``Eggshell.Adapter.ambiguous_calls_rejected,
    ``Eggshell.Adapter.saved_answer_is_authorized,
    ``Eggshell.Adapter.aborted_answer_not_saved,
    ``Eggshell.Adapter.unrelated_entry_preserved,
    ``Eggshell.Adapter.removed_entry_was_owned,
    ``Eggshell.Adapter.stop_wire_is_empty]
  for contract in contracts do
    let axioms ← Lean.collectAxioms contract
    for dependency in axioms do
      unless #[``propext, ``Quot.sound, ``Classical.choice].contains dependency do
        throwError "{contract} depends on unapproved axiom {dependency}"
    logInfo m!"Audited {contract}: {axioms}"
