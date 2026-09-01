# Privacy

Eggshell is local software. It has no hosted Eggshell service, telemetry,
analytics, advertising identifier, or account system.

## Data Eggshell observes

When its Codex hooks are enabled, Eggshell can receive the current user prompt,
supported tool inputs and results, the final assistant message, session and turn
identifiers, and the working directory. The stable hook API does not expose
hidden chain-of-thought. Eggshell does not scrape Codex's private transcript.

The active turn is staged under Codex's Plugin data directory. A sealed turn is
written only to the single `.egg` selected by the current profile. If a turn is
interrupted before its final response, only terminal tool outcomes already
observed by hooks and an open remainder may be promoted; no parent result is
fabricated. Read-only and off profiles are available, and `!egg drop` discards
the staged turn before it becomes authority.

## Network access

Eggshell's runtime and matcher operate locally. Installation downloads the
Eggshell release, the pinned `fastembed` Python package, and the configured
MiniLM model. After installation, prompts, tool results, embeddings, and `.egg`
files are not sent to an Eggshell server. The daemon listens only on the local
loopback interface.

## Stored data

- Project `.egg` authorities are restricted to regular, non-symlinked paths
  below that project. Shared paths may be named only by user-owned global or
  explicit configuration. Missing read paths are not created.
- Staged turns, recovery state, and daemon coordination live under
  `EGGSHELL_DATA_ROOT`, which defaults to
  `$EGGSHELL_PREFIX/share/eggshell/plugin`. This stable root is shared by Codex hooks
  and the `!egg` shell command. It does not select or relocate any `.egg`
  authority.
- The MiniLM runtime and model live under
  `$EGGSHELL_PREFIX/share/eggshell/minilm`.
- `EGGSHELL_PREFIX` defaults to `~/.local` and may point to another absolute
  filesystem when the home directory has limited quota.
- Disposable embedding vectors live under the Eggshell data root. They are
  a cache and cannot create graph authority.

Created `.egg`, staged-turn, and session-state files use owner-only `0600`
permissions. Eggshell-owned session directories and newly created authority
directories use `0700` permissions.

`egg uninstall codex` removes the Plugin and launcher but intentionally keeps
user-owned `.egg` files and recovery data. To erase Eggshell data completely,
remove the `.egg` paths listed by `!egg inspect` and the local Eggshell data
directory after uninstalling. Inspect those exact paths before deleting them.

## Control boundary

Prior outcomes are fallible historical data, not instructions. Exact tool
occurrences are never rewritten by semantic matching. Eggshell is fail-open for
the Codex turn and fail-closed for persistent authority: a hook failure does not
stop Codex, but an incomplete staged turn is not committed.

Security issues should be reported through GitHub's private vulnerability
reporting rather than a public issue. See [SECURITY.md](SECURITY.md).
