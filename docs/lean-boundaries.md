# Lean contracts and runtime boundaries

Eggshell uses Lean for its memory engine, native harness adapters, retrieval
selection, setup decisions, package assembly, and process regression tests.
Adapter code stays in its separate Lake package. The engine does not import it.

## Executed functions with kernel-checked contracts

| Implementation | Proved property |
| --- | --- |
| `Adapter/Contracts.lean`: `projectReply` | Stop, Interrupt and SessionEnd cannot emit context, denial or retry instructions; unsupported Cursor prompt output is silent. |
| `ownerMatches` | Accepted correlation state belongs to the exact requested host and native chat, even if a file-location hash collides. |
| `chooseCall` | A selected occurrence belongs to the eligible original calls and all candidates agree on its originating turn; conflicting turns are rejected. |
| `maySaveAnswer` | Saving requires an enabled, writable, active, completed turn. An aborted turn cannot become a completed answer. |
| `commitPlan` | A terminal receipt is journaled before its correlation ID is marked consumed. The runtime interprets this plan before calling the manager. |
| `receiptToAck` | Silent/unsupported output cannot produce an acknowledgement. The runtime creates its publication token after writing and flushing the supported response. |
| `removeOwned` | An entry not in the recorded ownership set is preserved; an entry removed from the input belonged to that set. |
| `Eggshell/Setup.lean`: `action` | Existing configuration and check-only mode never select initialization. |
| `Eggshell/SearchRank.lean`: `select` | Every result was ranked, refers to an existing candidate, is unique, and fits the requested count limit. |
| `Eggshell/SearchProvider.lean`: `cacheMatches` | Reusing an embedding requires exact model and source text identity; changing either rejects the record. |

These are the functions invoked by production code, not a separate test-only
model. Builds reject `sorry`; the two `ContractAudit.lean` modules enumerate 29
contracts and reject any dependency outside `propext`, `Quot.sound`, and
`Classical.choice`, Lean's standard logical basis. They supplement the existing
graph, lifecycle and persistence proofs.

## Numerical boundary

`runtime/embedding.py` calls the pinned FastEmbed model and NumPy's existing
float32 normalization and dot-product kernels. It accepts text/vector batches
and returns vectors/scores. It performs no retrieval selection, state management,
ranking, or graph work. Keeping these numerical kernels avoids silently replacing
their floating-point implementation during the language migration.

Window splitting, Unicode case folding, lexical ranking, reciprocal-rank fusion,
cache identity checks and candidate selection run in Lean. Unicode 16.0 mappings
are frozen as Lean data to match the prior provider's environment. The new cache
checks both model and source text, rather than treating a hash as evidence of
identity. Prior caches can be rebuilt; saved `.egg` work is not rewritten.

The legacy-provider fixture covers 24 selections across lexical, semantic and
hybrid modes, including long records, exact identifiers, Unicode and changed
text under reused caller IDs. This comparison passed with the local pinned
model. It is a regression test, not a universal equivalence theorem. In
particular, the old Python lexical score summed an unordered set; Lean uses
the query's stable term order. Last-bit floating-point ties can therefore differ.
No new model-task token-reduction rate is claimed by this migration.

## Trusted external operations

The Lean compiler/runtime, OS file writes and locks, process and pipe operations,
cryptographic primitives, numerical libraries, and harness delivery APIs remain
trusted boundaries. The pure theorems do not prove disk survival through power
loss, eventual OS scheduling, correctness of arbitrary model answers, or that a
host actually consumed a successfully written response. Filesystem/transport
failures are reported; they are not represented as successful persistence or
model use. Atomic-file tests exercise process interruption, not power failure.

The remaining non-Lean product code is deliberately limited to the numerical
bridge, OpenCode's JavaScript host callbacks, and a shell bootstrap that must
obtain a pinned native executable before Lean code is available. The bootstrap
checks the archive checksum and member type before execution; project setup
decisions run in Lean. SVGs and the external raster/video encoders remain artwork
and rendering dependencies. The small Python project under `examples/two-chats`
is an investigation target, not Eggshell implementation or a runtime dependency.

## Verification

```sh
lake build eggshell eggshell_tests lifecycle_tests eggshell_package setup_package_tests search_tests
EGGSHELL_DATA_ROOT="$PWD/.lake/eggshell-tests-data" .lake/build/bin/eggshell_tests
.lake/build/bin/lifecycle_tests
.lake/build/bin/setup_package_tests
.lake/build/bin/search_tests
(cd adapters/native && lake build eggshell_bridge adapter_tests && .lake/build/bin/adapter_tests)
node --test tests/test_opencode_adapter.mjs
```

The numerical comparison requires the installed MiniLM runtime and cached model;
it runs with network access disabled for the model. Tests use isolated memory
roots and make no generative model calls. CI is configured to run the core and
adapter process tests on Linux and macOS; local success is not a claim that
remote CI ran.
