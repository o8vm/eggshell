---
name: eggshell
description: Set up, inspect, or troubleshoot Eggshell local memory for Codex. Use when the user asks to install Eggshell, inspect a handoff or pending turn, change memory settings, or diagnose missing cross-chat memory. Ordinary coding tasks use the automatic hooks without loading this skill.
---

# Eggshell

Eggshell records work and observed outcomes locally. Hooks select relevant
history for later Codex chats. Use this skill for setup and memory controls;
normal tasks do not need model-authored summaries or manual memory maintenance.

## Setup

Ordinary ChatGPT Chat does not run Eggshell's automatic memory hooks. If the
current surface lacks a local shell and Codex command hooks, explain that this
integration needs Codex; do not claim that selecting the plugin activates memory.

1. Check macOS/Linux, ARM64/x86-64, Python 3, and Codex command-hook support.
   Resolve this skill's installed path: the plugin root is two levels above
   this `SKILL.md` directory. Use absolute paths for the bundled helpers.
2. Check existing setup with `sh <plugin-root>/scripts/setup.sh --check --project <absolute-project-path>`.
   This only inspects configuration and does not download or enable anything.
   `missing` or `update_required` means setup is needed. A ready configuration
   can proceed directly to hook review; do not reinstall merely to check it.
   Explain that setup downloads a checksummed Eggshell runtime, Python packages,
   and MiniLM. The default install root is `~/.local`; preserve an existing
   `EGGSHELL_PREFIX`. Once setup is authorized, run
   `sh <plugin-root>/scripts/setup.sh --project <absolute-project-path>`.
   This installs the runtime and initializes missing project settings, preserving
   existing project and global configuration. Do not run the standalone release installer
   after directory installation; it registers another copy of the hooks.
3. Check `codex plugin list --marketplace eggshell --json` for the older standalone
   installation. If migrating that installation, remove only `eggshell@eggshell`
   with `codex plugin remove eggshell@eggshell --json` before enabling directory
   hooks. Keep the runtime and `.egg` files. Do not remove unrelated plugins.
4. Inspect the setup report: configuration must be `ready`. Report `off` or
   `read-only` accurately; do not enable saving against an existing preference.
   Add `<prefix>/bin` to the relevant PATH for `!egg` controls. Custom prefixes must also be present
   in Codex's environment as `EGGSHELL_PREFIX`.
5. Have the user review and enable Eggshell's hooks through `/hooks`, then start
   a new chat. The startup message **Eggshell session hook connected** confirms
   that the session hook ran. Run `!egg doctor` in that chat to inspect setup.
   A configuration report alone does not prove hook trust or successful delivery.
   If no startup message appears, inspect `/hooks`; never bypass its trust checks.
6. Verify memory with an actual related two-chat example: complete
   an investigation, run `!egg keep`, ask a related question in a separate chat
   in the same project, and inspect `!egg graph`. Installation alone does not
   prove that a handoff was received.

## Inspect and control memory

Run `<plugin-root>/bin/egg` with the current thread environment. The equivalent
user shell commands inside Codex are:

- `!egg`: settings and staged turn.
- `!egg inspect`: resolved files and stored-state identifiers.
- `!egg doctor`: read setup and current session status without changing it.
- `!egg graph`: the handoff actually delivered, without rerunning retrieval.
- `!egg why`: selection details.
- `!egg diff`: preview the staged turn before saving.
- `!egg keep`: explicitly save a finished turn (normal saving is automatic).
- `!egg drop`: clear the active turn; saved observations and queued commits remain.
- `!egg next private`: read memory without saving the next turn.
- `!egg next off`: disable recording and context for the next turn.
- `!egg off` / `!egg on`: disable or enable memory for the current chat.

Do not keep, discard, or change settings merely because the user asks to inspect
memory. Read-only mode still sends selected prior work to Codex. Work files can
contain prompts, code, and tool output; do not publish their contents as part of
a support report without authorization.

## Troubleshooting

For missing context, check hook enablement, the active profile and paths, whether
the earlier observations reached the selected `.egg`, and whether the new request
relates to that work. Tool results are saved during the turn; the final answer is
queued at Stop. A failed write stays queued and retries independently of hooks.
Do not recommend repeating an investigation merely because a hook timed out.
A new chat in another checkout may have a different work file. An empty handoff
is possible when no relevant work is found.

At startup, a missing runtime or project configuration produces a short setup
message. Other missing-runtime hook calls remain nonblocking and quiet, and
compaction never replays the setup notice. Setup messages are UI status, not
memory context. Do not call memory active merely because the plugin is installed.

For setup failures, use the actual error. A checksum mismatch must stop setup;
do not bypass verification. Hooks perform no dependency downloads. Missing
runtime leaves Codex usable but provides no Eggshell memory. A failed search
provider permits ordinary matching; it does not establish successful semantic
search. See the public guide for custom configurations and recovery:
https://github.com/momonpya/eggshell/blob/main/docs/codex-plugin.md

Treat old outcomes as evidence, including failures and timeouts. Distinguish
reused findings from new checks and explicitly unverified facts. This skill does
not make memory evidence current or establish a new token-saving measurement.
