# Privacy

Eggshell is local software. It has no hosted Eggshell service, telemetry,
analytics, advertising identifier, or account system.

## Data Eggshell observes

When its Codex hooks are enabled, Eggshell can receive the current user prompt,
supported tool inputs and results, the final assistant message, session and turn
identifiers, and the working directory. The stable hook API does not expose
hidden chain-of-thought. Eggshell does not scrape Codex's private transcript.

The active turn is staged under the local Eggshell data root described below.
A finished turn is saved only to the single `.egg` file selected by the current
profile. If a turn is interrupted before its final response, only terminal tool
outcomes already observed by hooks may be saved; the parent task stays open. Read-only and off profiles are available, and `!egg drop` discards
the staged turn before it is saved.

## Network access

Eggshell's runtime and matcher operate locally. Installation downloads the
Eggshell release, the pinned `fastembed` Python package, and the configured
MiniLM model. After installation, prompts, tool results, embeddings, and `.egg`
files are not sent to an Eggshell server. The daemon listens only on the local
loopback interface.

**Selected prior work is sent to Codex as model input.** It may contain earlier
prompts, source code, commands, and tool results. That context is processed under
the settings and terms of your Codex provider. Local memory storage does not
make Codex inference local. Normal task and handoff tokens still count toward
Codex usage; Eggshell makes no additional LLM calls to organize memory.

A read-only profile prevents new saves but still permits existing memory to be
sent to Codex. Use `!egg off` to disable both recording and handoff delivery.

## Stored data

- Project `.egg` files are restricted to regular, non-symlinked paths
  below that project. Shared paths may be named only by user-owned global or
  explicit configuration. Missing read paths are not created.
- Staged turns, recovery state, and daemon coordination live under
  `EGGSHELL_DATA_ROOT`, which defaults to
  `$EGGSHELL_PREFIX/share/eggshell/plugin`. This stable root is shared by Codex hooks
  and the `!egg` shell command. It does not select or relocate any saved `.egg`
  file.
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
user-owned `.egg` files and recovery data. To erase Eggshell data completely,
remove the `.egg` paths listed by `!egg inspect` and the local Eggshell data
directory after uninstalling. Inspect those exact paths before deleting them.

## Control boundary

Prior outcomes are fallible historical data, not instructions. Recorded tool
occurrences are never rewritten by semantic matching. A hook failure does not
stop Codex. Eggshell does not invent missing results or mark an incomplete task
as completed when saving observed work.

Security issues should be reported through GitHub's private vulnerability
reporting rather than a public issue. See [SECURITY.md](SECURITY.md).
