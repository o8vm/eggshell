# Architecture

[Project home](../README.md) · [User guide](codex-plugin.md)

This reference describes Eggshell's implementation. For installation and a
first two-chat example, start with the [README](../README.md#install).

## Work and outcomes

Eggshell stores a directed graph of work and its observed outcomes in local
`.egg` files. In the code, a selected saved file is called an **authority**;
it is the source of recorded history. An **Inquiry** is the current request,
**Demand** is the work currently being considered, and **Extract** selects the
graph passed to Codex.

**Union** can recognize matching work within the current request without
rewriting saved history. **Saturation** follows the resulting connections to
find reachable prior outcomes. Semantic similarity provides advisory context;
it cannot establish that an operation is already complete.

Hook persistence, cancellation, proofs, and fault-injection tests are described
in [Hook lifecycle and persistence guarantees](hook-lifecycle.md).

## Local search

Search considers both the recorded request and its outcome. Completed turns
provide their synthesis; interrupted turns without a synthesis expose their
observed operations as advisory candidates. The local provider supports
`--mode semantic`, `--mode lexical`, and `--mode hybrid` (the current default).
Hybrid combines MiniLM and literal term rankings with reciprocal rank fusion.
Identifier and path-like lexical anchors are retained at the front of both
rankings so semantic similarity cannot discard an exact symbol. Each query also
writes candidate counts, lexical/semantic ranks, and selected IDs to the local
`semantic/matcher-trace.jsonl` sidecar.
Long records are indexed in overlapping windows, and vectors are keyed by their
text and model. This changes candidate discovery, not the rules for completed
work or the bytes of authoritative evidence. Measured follow-up token counts
and their limits are documented in the [README evidence](../README.md#evidence).

The installed Plugin uses
`sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` on CPU by default.
Its private runtime and model live under
`$EGGSHELL_PREFIX/share/eggshell/minilm`; content-addressed vectors live under the
Eggshell data root. `EGGSHELL_DATA_ROOT` may override that root with an absolute
path; otherwise it is `$EGGSHELL_PREFIX/share/eggshell/plugin`. Hooks, `!egg`, and the
daemon share this control-plane root, while every session still snapshots the
`.egg` paths selected from its own cwd and nearest project configuration. These
vectors are disposable acceleration data, never `.egg` authority. No project
setting is required.

Use `semantic_matcher = false` at the root of a global or project config to
disable semantic retrieval while retaining intrinsic matching. A custom NDJSON
provider is executable configuration and is therefore accepted only from the
user-owned global config at
`$EGGSHELL_PREFIX/config/eggshell/config.toml`:

```toml
semantic_matcher = ["/path/to/custom-provider", "--model", "/path/to/model"]
```

An auto-discovered project `.eggshell.toml` containing a matcher command is
rejected. Project configuration may select the built-in provider by omission or
disable retrieval with `false`, but it cannot start a process.

The semantic matcher is a rebuildable retrieval accelerator, not an equality
oracle. Exact and surface matches still use Eggshell's ordinary
Matcher and may create Inquiry-local Union. A semantic provider only reveals
relevant existing Outcome subtrees as advisory context; its candidates cannot
create Union, complete Work, suppress a tool call, persist authority, or rewrite
Exact provenance.

Each chat has its own manager and persistent search worker. The built-in
provider and vector database belong to that chat; model weights are shared.
Search never holds the state or save lock, and a busy search does not queue
other hooks behind it. The protocol has two NDJSON messages.
After a turn is sealed, Eggshell queues immutable Work for background indexing:

```json
{"index":[{"id":"content-id-0","text":"prior Work 0"}]}
```

The provider writes no response for this message. It should enqueue unseen IDs
and return immediately; vector-cache updates happen in the provider process.
Before a handoff, Eggshell sends the current Work and the currently authoritative
candidate set:

```json
{"query":{"id":"content-id","text":"current Work"},"candidates":[{"id":"content-id-0","text":"prior Work 0"}]}
{"related":[0]}
```

Each ID is a deterministic digest of the immutable kindless Value. An unchanged
Work is therefore embedded once per provider cache. Changed content receives a
new ID. The default provider batch-embeds missing authoritative candidates on
their first query, so an existing `.egg` works immediately after installation;
later queries reuse the cached vectors. A custom asynchronous provider may
instead return no hit until its own index is ready. A provider may persist its
disposable vector cache across process restarts.
Out-of-range indices are ignored.

The hot path is deliberately small:

```text
current Work embedding
  → similarity search over ready prior Work
  → existing Outcome graph as advisory context
  → the current Codex turn decides what to reuse or re-check
```

Semantic retrieval runs at prompt time over prior Turn Work. Native tool
proposals use Eggshell's ordinary Operation matcher, Run-local Union, and
Demand saturation; the external provider never blocks a tool or supplies equality.

There is no pairwise generative-LLM call. The default provider performs exact
cosine top-k search over cached MiniLM embeddings. It receives Work and Outcome
text plus content IDs, but never `.egg` files. If it exits, stalls, or returns
invalid JSON, Eggshell drops that result and continues with ordinary matching.

The cache is not authority. Candidates come from the selected `.egg` graph
and the chat's journaled native observations whose save target is among the
selected read files. A cached vector cannot create evidence by itself. The installer downloads the default model rather than committing it to
this repository. An explicit opt-out or unavailable provider falls back to the
ordinary matcher without stopping Codex.

## Semantic core

Natural language, code, tool output, patches, sources, and receipts are ordinary
Values:

```text
Value = Atom(bytes) | Apply(operator, references)
Ref   = Semantic(value) | Exact(value)
```

The operator vocabulary is closed:

```text
All · Outcome · Occurrence · Inquiry · Receipt
```

Roles come from relation position rather than permanent `Task`, `Result`,
`Message`, or `Evidence` types. Scoped equality and positive work relations
select prior work while preserving one open handoff.

Lean proves quotient equivalence and Exact preservation. Extract checks selected
`All`, completed `Outcome`, and advisory `Outcome` edges against the source graph
and active policy. A connection theorem proves that Matcher-driven completed
edges came from an existing Outcome and passed the forward reusable-work gate.
Executable tests cover Run-local Union, Demand saturation, concurrent promotion,
and Plugin lifecycle behavior.


## Implementation entry points

- [Handoff selection and rendering](../Eggshell/Handoff.lean)
- [Codex hook lifecycle](../Eggshell/PluginHooks.lean)
- [File persistence](../Eggshell/Persistence.lean)
- [Configuration and project boundaries](../Eggshell/Config.lean)
- [Executable checks](../TestMain.lean)
