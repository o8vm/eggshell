# Hook lifecycle and persistence guarantees

The hook deadline must not be the lifetime of a save. Eggshell records observed
work during a turn so losing a final hook does not force another investigation.

## Ownership and progress

Each chat owns one manager, one persistent search worker, and one persistent
writer. Kernel file locks protect the manager lease, short state transitions,
and shared `.egg` commits. An exited process cannot leave an owned directory
lock behind. All writers of a shared file must use the updated runtime; old
versions use a different lock protocol.

`PostToolUse` journals the native result before contacting the manager. It also
creates an immutable checkpoint when the turn's metadata is available. The
manager records the same event idempotently. Search runs in a separate process
and never holds a session state lock or a save lock. Default semantic providers
and vector caches belong to individual chats; model weight files remain shared.

A manager checks its save queue independently of hook requests. A writer commits
observed operation roots through the existing compiler and `.egg` transaction.
It removes a queue entry only after that commit returns successfully. An error
or process exit leaves the entry available for retry; replay filters roots
already present in the authority. Active tool receipts are retained in the
session journal, including after a commit, to reconstruct the final turn.
The manager also reconciles the active turn's receipts into that queue. If a
native hook exits between the receipt write and queue registration, the receipt
is saved without waiting for another hook. Its in-memory scan cursor advances
only after registration; restart replays receipts through the same idempotent
transaction. Receipt identity is the native tool-use ID within its turn.
Each authority write uses its own temporary sibling and publishes by atomic
rename. A killed writer's incomplete temporary file cannot block the next save
and is never read as committed evidence.

Intermediate saves contain actual native Work/Outcome relations, Exact
occurrence identity, and the existing staged graph's open All edge. That edge
makes the observed operations reusable children in an independent chat. They do not invent a final answer or close the parent task.
Stop queues a final answer when one exists; a null final message closes staging
without fabricating a parent Outcome. Interrupted turns retain their open
remainder. A new turn archives the previous metadata instead of waiting for its
save. The chat's pending observations remain available to its search while a
commit is waiting, restricted to targets in the current read set.

A slow save is not killed by a hook timeout. Transient authority contention is
retried by the independent writer. Slow search has a separate bounded request;
expiration kills and reaps its worker process group, including provider children.
Another hook does not queue behind that search. The native hook runner also
supervises its RPC subprocess, so a stalled connection cannot consume the host's
entire command-hook deadline. These deadlines bound waiting, not the lifetime of
journaled evidence.

## Delivery and compaction

A search captures a turn ID, a context epoch, and a monotonic deadline. State
publication checks all three again under the session lock. Stop, Interrupt,
compaction, and a new turn invalidate old work. The client acknowledges an offer
only after flushing the native hook output. Missing or expired acknowledgments
do not mark graph context delivered. This receipt confirms a stdout write, not
an independent acknowledgment from the Codex model.

Evidence-specific checkpoints are retained across compaction, while context-delivery
keys are cleared. The same observed Outcome projection does not trigger another
checkpoint, even if its first response was lost. New completed evidence may
trigger a checkpoint for the same native operation; an earlier denial does not
exempt that operation from reuse. Compacted staged results are rendered with their actual
bytes instead of claiming they are still visible. A corrupt state file is
quarantined and memory is disabled; `egg off` does not depend on parsing the
pending file or loading project configuration. Older state and pending files
receive defaults only for newly introduced fields; invalid existing fields are
still rejected. Session journals currently remain on disk after final promotion.

## What is proved and tested

The following Lean theorems are compiled with warnings treated as errors:

- `expired_request_cannot_publish`, `old_turn_cannot_publish`,
  `old_context_cannot_publish`, and `accepted_request_is_current` establish the
  exact gate used by publication and acknowledgment.
- `rejected_offer_changes_nothing` and `disabled_memory_rejects_delivery` prove
  that the actual acknowledgment transition cannot publish rejected evidence.
- `compaction_preserves_checkpoint` proves that compaction retains
  evidence-specific checkpoints. Existing handoff proofs tie checkpoints to
  completed evidence and deduplicate the same Outcome projection.
- `checkpoint_ignores_parent_status` and `checkpoint_has_only_observed_roots`
  show that the live-save Outcome selector depends only on observed tool events.
  `operation_checkpoint_keeps_open_remainder` proves that the same compiler
  retains an open child in its parent decomposition.
  Existing transaction proofs cover well-formed values, authority identity,
  revision checks, and preservation of previously committed values.

`TestMain.lean` checks these transitions through the production functions,
including unacknowledged, expired, old-turn, and old-epoch receipts, exact
incremental roots, replay without revision growth, final promotion, and corrupt
state recovery. Its deterministic hook fixtures explicitly drain the independent
writer; real concurrency is exercised separately.

`tests/test_hook_lifecycle.py` runs the production binary in isolated temporary
directories without model downloads or LLM calls. It injects authority lock
contention, lock-owner death, search hangs and deadlines, writer death, manager
death, lost receipts, and malformed state. It checks actual `.egg` bytes before
Stop, autonomous retries, reuse of uncommitted observations, process-group
cancellation, another chat's progress, restart recovery, and abandoned files
from an interrupted atomic write. A separate case removes queue registration
while retaining the journal and checks autonomous recovery before Stop. Another
case checks that new evidence can trigger reuse for a previously denied operation,
while unchanged evidence remains deduplicated. CI runs it on Linux
and macOS alongside the existing Lean and package regressions.

The proofs concern the stated pure transitions and graph contracts. They do not
prove OS scheduling, disk durability through power loss, or arbitrary future
model behavior. The process tests cover those concrete interruption paths under
working local filesystem and OS primitives. A permanent disk error cannot be
turned into a successful commit; its queue must remain intact. This change does
not establish a new token-reduction measurement.
