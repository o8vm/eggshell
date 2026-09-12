# Privacy

Eggshell is local software. It has no hosted Eggshell service, telemetry,
analytics, advertising identifier, or account system.

## Data Eggshell observes

When an integration is enabled, Eggshell can receive the current user prompt,
supported tool inputs and results, the final assistant message, session and turn
identifiers, and the working directory. It does not scrape private transcripts
or collect hidden chain-of-thought. The separate
[harness adapters](adapters/README.md) forward selected event fields, excluding
account details, transcript paths, and reasoning fields.

The active turn is staged under the local Eggshell data root described below.
In a writable profile, observed tool results are journaled and queued for saving
to the single `.egg` file selected by that profile while the turn is still
running. The final answer is queued when the turn stops. If the turn is
interrupted, already observed tool outcomes can still be saved; the parent task
stays open until a final outcome is available. Read-only and off profiles are
available. `!egg drop` clears the active turn but does not erase saved
observations or cancel queued commits. It is not a way to retract data that a
hook has already recorded.

## Network access

Eggshell's runtime and matcher operate locally. Installation downloads the
Eggshell release, the pinned `fastembed` Python package, and the configured
MiniLM model. After installation, prompts, tool results, embeddings, and `.egg`
files are not sent to an Eggshell server. The daemon listens only on the local
loopback interface.

**Selected prior work is sent to your agent as model input.** It may contain earlier
prompts, source code, commands, and tool results. That context is processed under
the settings and terms of the agent's model provider. Local memory storage does
not make model inference local. Normal task and handoff tokens still count
toward model usage; Eggshell makes no additional LLM calls to organize memory.

A read-only profile prevents new saves but still permits existing memory to be
sent to the agent. Use `!egg off` in Codex, or the adapter's `control ... off`
command, to disable both recording and handoff delivery for that session.

## Stored data

- Project `.egg` files are restricted to regular, non-symlinked paths
  below that project. Shared paths may be named only by user-owned global or
  explicit configuration. Missing read paths are not created.
- Staged turns, recovery state, and daemon coordination live under
  `EGGSHELL_DATA_ROOT`, which defaults to
  `$EGGSHELL_PREFIX/share/eggshell/plugin`. Integrations use this stable root,
  with separate adapter session namespaces for each harness. It does not select
  or relocate any saved `.egg` file.
- Adapters store session ownership, opaque turn/call identifiers, and correlation
  hashes in per-session JSON files under the data root's `adapters` directory. Writable
  turns may also retain an authorized turn snapshot for late tool results and
  a temporary answer candidate under their session directory. Ambiguous Gemini
  tool results, when recording is permitted, stay in `adapters/unattributed`
  without being assigned to another task or inserted into the memory graph.
- The MiniLM runtime and model live under
  `$EGGSHELL_PREFIX/share/eggshell/minilm`.
- `EGGSHELL_PREFIX` defaults to `~/.local` and may point to another absolute
  filesystem when the home directory has limited quota.
- Disposable embedding vectors live under the Eggshell data root. They are
  a cache and cannot add saved work on their own.

Created `.egg`, staged-turn, and session-state files use owner-only `0600`
permissions. Eggshell-owned session directories and newly created work-file
directories use `0700` permissions.

`egg uninstall codex` removes the Plugin and launcher but intentionally keeps
user-owned `.egg` files and recovery data. The adapter uninstaller similarly
removes its integration entries while retaining memory and shared runtime files.
To erase Eggshell data completely,
remove the `.egg` paths listed by `!egg inspect` and the local Eggshell data
directory after uninstalling. Inspect those exact paths before deleting them.

## Control boundary

Prior outcomes are fallible historical data, not instructions. Recorded tool
occurrences are never rewritten by semantic matching. Hook errors return without
blocking ordinary agent execution. Eggshell does not invent missing results or mark an incomplete task
as completed when saving observed work.

Security issues should be reported through GitHub's private vulnerability
reporting rather than a public issue. See [SECURITY.md](SECURITY.md).
