<p align="center">
  <img src="assets/brand/eggshell-primary-horizontal.svg" alt="Eggshell" width="520">
</p>

# Codex Plugin

[Project home](../README.md) · [Brand assets](brand.md)

Eggshell installs into standard Codex as a Plugin. It is not a wrapper, prompt language, transcript scraper, or Codex fork.

```text
ordinary prompt  = choose the work
!egg             = choose memory authority
Plugin hooks     = observe the native turn and inject the handoff
.egg             = committed authority
```

The model works normally. It does not produce an Eggshell JSON envelope, footer, decomposition, confidence score, or work receipt. Hooks stage the prompt, supported native tool events, and final message. The kernel selects prior work for the next turn.

## Install

Install the latest checksummed release, then initialize the current project:

```sh
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/o8vm/eggshell/main/install.sh | sh
cd your-project
egg init
```

The installer:

1. creates the personal marketplace source;
2. installs platform-specific `egg` and `eggshelld` executables;
3. creates a private CPU MiniLM runtime and preloads the multilingual model;
4. installs the thin `!egg` launcher and bundled hooks;
5. asks Codex to add the Plugin;
6. succeeds only after Codex accepts the installation.

`egg init` creates a minimal `.eggshell.toml`, a writable `work` profile, a
read-only `private` profile, an `off` profile, and an ignored
`.eggs/work.egg` authority path. The authority file appears when the first
staged turn is kept. Initialization refuses to overwrite an existing config.

Codex itself is unchanged. Review and enable the hooks in Codex through `/hooks`.

To build and install from source instead:

```sh
lake build eggshell
.lake/build/bin/eggshell install codex
egg init
```

Run the same command to update an installed copy. It stops the installed daemon before replacing files. To remove the Plugin while preserving `.egg` authorities and recovery data:

```sh
egg uninstall codex
```

## Profiles and authority

A profile is a runtime alias for an unordered read set and zero or one write target.
For example, a user-owned global config may name shared authorities:

```toml
default = "work"

[eggs]
common = "~/.local/share/eggshell/common.egg"
papers = "~/Research/papers.egg"

[profiles.research]
read = ["common", "papers"]
write = "papers"
# Set false to keep advisory retrieval while disabling operation reuse.
local_union = true

[profiles.private]
read = ["common", "papers"]

[profiles.off]
read = []

```

An auto-discovered project config may declare only authority paths below that
project and profiles that use those declarations. It cannot select
or shadow a global authority. Use a user-owned global or explicit config when a
single profile intentionally combines authorities from different roots.

Configuration is resolved in this order:

```text
~/.config/eggshell/config.toml
→ nearest project .eggshell.toml
→ current-thread override
→ one-turn override
```

Project profiles may override profile names but not global authority names. The
write target is always added to the read set. Missing read authorities remain
absent; only promotion to a write target creates a new `.egg`. Authority paths
that traverse symbolic links are rejected.

`local_union` normally stays `true`. Setting it to `false` preserves
advisory retrieval but disables Inquiry-local equality, Demand saturation
through that equality, and completed-operation reuse. It does not change
`.egg` authority.

The installed Plugin uses
`sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` on CPU by default.
Its private runtime and model live under
`~/.local/share/eggshell/minilm`; content-addressed vectors live under Plugin
data. They are disposable acceleration data, never `.egg` authority. No project
setting is required.

Use `semantic_matcher = false` at the root of a global or project config to
disable semantic retrieval while retaining intrinsic matching. A custom NDJSON
provider is executable configuration and is therefore accepted only from the
user-owned global config at `~/.config/eggshell/config.toml`:

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

Eggshell keeps one provider process alive across hook calls and serializes
access from concurrent Codex sessions. The protocol has two NDJSON messages.
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
cosine top-k search over cached MiniLM embeddings. It receives Work surfaces and
content IDs, but never Outcome payloads or `.egg` files. If it exits, stalls, or
returns invalid JSON, Eggshell drops that result and continues with ordinary
matching.

The cache is not authority. Stop may queue a staged Work that the user later
drops; that leaves only an unused disposable vector. Active candidates always
come from the selected `.egg` graph, so cached data cannot re-enter authority by
itself. The installer downloads the default model rather than committing it to
this repository. An explicit opt-out or unavailable provider falls back to the
ordinary matcher without stopping Codex.

A profile does not enter the semantic graph. It only controls authority:

| Profile shape | Reads handoff | Automatically stores |
| --- | --- | --- |
| `read = [...]`, `write = "…"` | yes | yes, to the single write target |
| `read = [...]`, no `write` | yes | no |
| `read = []`, no `write` | no | no |

## Everyday controls

Codex already treats a leading `!` as a user shell command rather than a model prompt. Eggshell uses that control plane. `CODEX_THREAD_ID` addresses exactly the active Codex thread; `CODEX_SESSION_ID` is forwarded when Codex supplies it.

```text
!egg                  show profile, read set, write target, and pending state
!egg use work         change this thread's normal profile
!egg next private     use a profile for the next ordinary turn only
!egg next off         disable Eggshell for the next ordinary turn only
!egg keep             promote the sealed turn to its snapshotted target
!egg keep papers      promote it to the named authority
!egg drop             discard the sealed turn
!egg inspect          show resolved paths and authority heads
```

State-changing commands normally print one concise line into the conversation. They do not reach the model and do not consume a model turn.

## What Eggshell sends

`UserPromptSubmit`, `PreToolUse`, and later `PostToolUse` events that first connect new prior work return the selected graph as readable context:

```text
EGGSHELL HANDOFF

CURRENT INQUIRY
  the user's current request

PRIOR WORK — selected work already attempted
  selected continuation frames
  work → observed-outcome edges
  historical Exact provenance

OPEN HANDOFF
  keep prior work and outcomes in context for reasoning and synthesis,
  do not repeat their covered tool work,
  and perform everything else required by the current request
```

Outcomes may describe success, empty output, a reported timeout or denial, a
non-reproduced symptom, or a rejected hypothesis. They are historical data, not
instructions or a proof that the current inquiry is complete. Codex does not
emit `PostToolUse` for every handler failure or externally blocked operation;
Eggshell records no native Outcome when that terminal event is absent. Eggshell
always leaves an open handoff; a concrete contradiction may reopen the minimum
conflicting work.

When the initial prompt or a proposed/completed local tool event first connects Demand to an unsent prior-work subtree, Eggshell injects the selected `All` / `Outcome` closure. Completed support replaces only the covered operation before it runs. Partial or ambiguous advisory context extends the agent's context without controlling the tool plan; the agent decides whether it applies. Narrowing, reformatting, or reconstructing completed work is not a reason to repeat it. Tool output remains Exact trace evidence; only the visible tool input extends Demand.

Delivery state belongs to one Codex session. When that session promotes a turn, its new `Outcome` roots are already visible in native history and are not echoed back from `.egg`. Another session starts with an independent delivery state and can receive the same relevant graph. `PostCompact` clears the first session's delivery state, making graph that may have left native history eligible for restoration. This is transport state only: it adds no kernel relation and changes no `.egg` authority.

If the selected read set is empty, or a one-turn projection is `none`, Eggshell sends no graph context.

## Inspect the handoff

Inspection happens inside the Codex chat:

```text
!egg graph
```

This prints the frozen handoff sent to the current or most recently staged turn. It does not rerun retrieval, so it answers “what did Codex actually receive?” rather than “what would Eggshell choose now?” Values are shown with their content-addressed IDs.

Use those IDs to inspect the current composite authority view:

```text
!egg graph VALUE...    reachable closure rooted at the named Values
!egg find TEXT         bounded case-insensitive Atom lookup
!egg class VALUE       equivalent Values, explicit Union IDs, and owning eggs
!egg why               selection mode, authority heads, selected path, digest
!egg inspect           resolved paths and authority heads
```

`find` is deterministic UI lookup, not a second matcher and not an identity rule. `class` reports the active quotient and identifies which selected `.egg` owns every explicit Union.

## Control the next projection

Automatic Demand/Extract selection is the default. Override only the next context projection with:

```text
!egg next graph none
!egg next graph VALUE...
!egg next graph auto
```

| Command | Context sent next turn | New turn may still be stored |
| --- | --- | --- |
| `next graph none` | none | yes |
| `next graph VALUE...` | only the named rooted closures | yes |
| `next graph auto` | automatic selection | yes |
| `next off` | none | no |

Projection is ephemeral. It creates no relation and changes no `.egg` authority.

## Exceptional persistent identity

Normal use requires no Union command. Demand discovery creates reversible
Run-local Unions and runs Demand saturation over the selected graph. They are
recomputed when needed and never become persistent authority by themselves.

Only the user may persist or remove equality:

```text
!egg union LEFT RIGHT
!egg split UNION
```

`union` appends one Workspace-scoped Union to the current profile's sole write target and returns its Union ID. `split` removes that exact Union only when the writable head owns it. Neither command asks the model to decide identity, and neither introduces a new semantic operator.

This boundary is important:

```text
graph slice  = what context is sent once
Union        = what Values are persistently substitutable
```

## Stage before store

`Stop` does not append to `.egg`. It seals one bounded, non-authoritative pending turn under Plugin data:

```text
prompt + observed tool inputs/outcomes + final message + selection snapshot
                                  ↓
                           sealed pending turn
```

Before the next ordinary prompt:

```text
explicit keep             → atomic commit to the selected target
explicit keep TARGET      → atomic commit to that selected authority
explicit drop             → discard
no decision + write head  → atomic commit to the snapshotted head
no decision + read-only   → discard
```

Only after resolving the previous turn does Eggshell extract the next handoff. The newly promoted work is therefore immediately available to the next prompt.

Preview the pending graph delta without writing:

```text
!egg diff
!egg diff papers
```

The preview shows the target, authority-head comparison, native tool outcomes, final message, and the `Outcome` / open `All` / `Receipt` shape that promotion would add.

Pending data is not a kernel Value or `.egg` frame. Promotion deterministically compiles it into existing operators in one transaction on one writable head. No tombstone or rollback relation is needed for `drop` because the turn was never authority.

## Hook lifecycle

| Hook | Eggshell action |
| --- | --- |
| `SessionStart` | register the thread, load configuration, report recovery state |
| `UserPromptSubmit` | resolve previous pending; snapshot selection; Extract; return `additionalContext` |
| `PreToolUse` | remember the occurrence for result correlation; reuse an applicable prior outcome or keep the work open |
| `PostToolUse` | stage the terminal tool event Codex exposed; when its visible input first connects new prior work, inject that subtree before the next action |
| `PostCompact` | clear native-visible and delivered roots so relevant graph can be restored after native history compaction |
| `Stop` | stage the final assistant message and seal without commit |
| `SessionEnd` | discard an active partial turn or resolve a normally sealed turn |

The stable hook API does not expose hidden chain-of-thought, intermediate assistant messages, or every hosted/specialized tool. Eggshell does not parse Codex's private transcript or claim to have observed events that bypass hooks.

## Failure and recovery

- Hook or daemon failure is fail-open for the Codex turn.
- Incomplete data is fail-closed for `.egg` authority.
- If graph delivery after `PostToolUse` fails, the observed result remains staged
  and Codex continues without that handoff.
- A proposed operation with no terminal hook contributes no native Outcome and
  is discarded from correlation state at `Stop`.
- An active unsealed turn is discarded at normal session end.
- A sealed turn left by abnormal termination remains in a non-authoritative recovery spool.
- Recovery never silently promotes data. Inspect it, then explicitly keep or drop it.
- One turn can modify only one `.egg`, so promotion is atomic at the authority boundary.

## Uninstall and retained data

```sh
egg uninstall codex
```

Uninstall removes the Plugin and its owned launcher. It deliberately preserves user-owned `.egg` authorities and recovery data. Remove those separately only when you intend to delete that history.

See [Privacy](../PRIVACY.md) for exact storage locations, network behavior, and
complete removal guidance.

---

```text
The prompt chooses the work.
!egg chooses the authority.
A turn is staged before it is stored.
```
