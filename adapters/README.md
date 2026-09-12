# Eggshell adapters

Use the same local memory engine from Claude Code, Gemini CLI, Cursor, or
OpenCode. These adapters are a separate package: the existing Eggshell engine,
retriever, handoff prompt, and Codex plugin do not depend on them.

**Status:** experimental, source-built adapters with automated tests against the
real memory engine. Live sessions in these four agents and their token savings
have not yet been evaluated. The published Codex experiment does not establish
a reduction rate for these adapters.

| Agent | Integration | When selected memory can reach the agent |
| --- | --- | --- |
| Claude Code | Project command hooks | Before a prompt, before a tool, or after a tool result |
| Gemini CLI | Project command hooks | Before a prompt or after a tool result; a covered operation can be denied before execution |
| Cursor | Project command hooks | After a tool result; a covered operation can be denied before execution |
| OpenCode | Project JavaScript plugin | A separate context part on a user message, or after a tool result; a covered operation can be denied before execution |

Cursor's prompt hook cannot inject context. Its adapter stages the request but
does not mark that hook's retrieved memory as delivered. Later tool hooks can
deliver it. This difference is part of the integration contract.

## Install

You need macOS or Linux, Python 3.9 or later, the project's pinned Lean
toolchain, and an agent version supporting the events listed below. OpenCode
uses its own JavaScript runtime; the plugin has no npm dependencies.

From an Eggshell source checkout, install the local runtime and search model,
then build the separate adapter companion:

```sh
lake build eggshell
.lake/build/bin/eggshell install runtime
export PATH="${EGGSHELL_PREFIX:-$HOME/.local}/bin:$PATH"
(cd adapters/native && lake build)
```

In a project without existing Eggshell project, parent, or global configuration,
run `egg init` from that project's directory. Existing configuration and memory
profiles continue to apply.

Back in the source checkout, choose **one** adapter:

```sh
python3 adapters/install.py claude --project /absolute/path/to/project
python3 adapters/install.py gemini --project /absolute/path/to/project
python3 adapters/install.py cursor --project /absolute/path/to/project
python3 adapters/install.py opencode --project /absolute/path/to/project
```

The installer copies the companion and adapters into
`${EGGSHELL_PREFIX:-$HOME/.local}/share/eggshell-adapters` and adds only the chosen
project integration. `--prefix` selects another runtime prefix. Existing hooks
and other settings are preserved; repeat installation does not duplicate hooks.
Invalid configuration and unowned plugin files are rejected without replacement.
The installer does not enable globally disabled hooks or approve project trust.

Review the new hooks or plugin in your agent, then restart the project chat.
Installation alone does not demonstrate that memory is being saved or delivered.

| Agent | Project file |
| --- | --- |
| Claude Code | `.claude/settings.json` |
| Gemini CLI | `.gemini/settings.json` |
| Cursor | `.cursor/hooks.json` |
| OpenCode | `.opencode/plugins/eggshell.js` |

These are local command/plugin integrations. Ordinary ChatGPT Chat and agent
environments without access to the local companion are not covered.

## Verify two-chat reuse

Use the repository and questions in the [two-chat example](../docs/try-it.md),
running both chats in your selected agent. Let the first chat perform a real
investigation, then ask a related question in a new chat in the same project.
The first chat's tool results should reach `.eggs/work.egg` before it finishes.

For inspection, supply the native session ID from the agent's hook/debug output:

```sh
python3 "$HOME/.local/share/eggshell-adapters/eggshell_adapter.py" \
  control claude --session NATIVE_SESSION_ID doctor
python3 "$HOME/.local/share/eggshell-adapters/eggshell_adapter.py" \
  control claude --session NATIVE_SESSION_ID graph
```

Run these from the project directory. Replace `claude` with your chosen adapter,
and adjust the path for a custom prefix. `doctor` checks local configuration;
`graph` shows the handoff whose delivery was acknowledged. The same entrypoint
accepts the existing `off`, `on`, `why`, `inspect`, and other engine controls.
It launches no model turn.

## Remove an adapter

From the source checkout:

```sh
python3 adapters/install.py claude --project /absolute/path/to/project --uninstall
```

Only the exact entries installed by this adapter are removed. Modified or
unrelated entries remain. The runtime, other adapters, configuration, and saved
memory are preserved.

## Boundaries and guarantees

- **One engine manager per chat.** The adapter namespaces native session IDs by
  harness. Its small SQLite database records opaque turn/call identifiers;
  transactions finish before any engine or search call. It starts no additional
  adapter manager and holds no cross-chat lock during normal operation.
- **The engine owns memory.** Tool names, inputs, and results are passed through
  to the existing engine. Its journal captures results before manager RPC or
  search. Search and saving retain their existing independent workers.
  The companion retains the engine's authorized turn snapshot so a late tool
  result can be queued under its original task after that task has been sealed.
- **Delivery requires a supported output.** Unsupported context fields are
  discarded without acknowledgment. Command adapters acknowledge after writing
  and flushing the host response. OpenCode acknowledges after inserting the
  context into its output object. The engine rejects receipts from an obsolete
  turn or compaction epoch. This confirms delivery at the integration boundary,
  not that a model used the evidence correctly.
- **End-of-turn hooks cannot request another iteration.** The output translator
  returns `{}` for every `Stop`, `Interrupt`, and `SessionEnd` input, independent
  of the engine reply. The OpenCode plugin does not create follow-up prompts or
  replace the agent's compaction prompt.
- **Failures preserve ordinary agent execution.** Adapter errors emit an empty
  hook response, with diagnostics on stderr. The companion uses the engine's
  existing bounded transport; captured tool receipts stay available to its
  writer. A covered operation can still receive the engine's normal denial and
  reuse instructions. Permission approvals are never granted by the adapter.

Gemini CLI does not provide native tool call IDs. The adapter correlates its
before/after events by exact tool name and arguments, preserves separate
occurrences, and uses the hook timestamp to recognize replayed events. If the
same operation overlaps different turns, or another hook changes its arguments,
the originating task may be ambiguous. When the possible originating operations
were writable and memory still permits writing, the result
is retained under the adapter's private `unattributed` directory instead of
being assigned to another task or promoted into the graph.

Cursor emits assistant text separately from loop completion. The adapter holds
a private temporary candidate only when memory is writable, and saves it as a
final answer only when the loop reports completion. An abort is not a successful
final outcome. OpenCode similarly waits for an idle session and a completed
assistant message; if final text was not observed, it preserves tool progress
without inventing an answer.

## Development and contract tests

```sh
(cd adapters/native && lake build)
python3 tests/test_adapters.py -v
node --test tests/test_opencode_adapter.mjs
```

Tests exercise actual engine processes, saving before turn completion, reuse in
a separate chat, concurrent tool results, off mode, compaction receipts, output
translation, and installation ownership. They make no LLM or network calls.
The OpenCode output-object tests separately verify insertion-before-ack order.

The dependency is one-way: `adapters/native` imports the engine as a local Lake
dependency. `adapters/eggshell_adapter.py` owns host JSON translation and
identifier correlation; `adapters/opencode.mjs` owns OpenCode plugin callbacks.
The companion translates neither host tools nor retrieval results. No adapter
code is linked into the existing `eggshell` executable or Codex plugin.

Reference contracts checked on 2026-09-12:
[Claude Code hooks](https://code.claude.com/docs/en/hooks),
[Gemini CLI hooks](https://geminicli.com/docs/hooks/reference/),
[Cursor hooks](https://cursor.com/docs/hooks), and
[OpenCode plugins](https://opencode.ai/docs/plugins/).
OpenCode callbacks were also checked against `@opencode-ai/plugin` 1.18.30's
published type declarations. Event availability may differ in older clients.
