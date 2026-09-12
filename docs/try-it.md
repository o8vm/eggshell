# Try Eggshell in two chats

[Install](../README.md#install) · [Sample source](../examples/two-chats) · [Recorded study](demo.md) · [Share your result](https://github.com/momonpya/eggshell/issues/new?template=first-run.yml)

Use a small, public Python project to check whether work from one Codex chat is
saved and delivered to the next. The first chat investigates configuration; the
second implements a related option. You can try this without sharing a private
repository or inventing your own task.

## Prepare the sample

[Install Eggshell](../README.md#install) first. The sample uses Python's standard
library and makes no network requests. Your Codex chats use normal model tokens.

In a terminal:

```sh
git clone --depth 1 https://github.com/momonpya/eggshell.git eggshell
cd eggshell/examples/two-chats
egg init
python3 -m unittest -v
```

If you already cloned the repository, use its `examples/two-chats` directory.
Run `egg init` once there. It refuses to overwrite an existing `.eggshell.toml`.
Start Codex with **this sample directory as its working directory**, review and
enable Eggshell's hooks through `/hooks`, and begin a new chat.

The initial test run should report **five passing tests**. It tests only the
sample client; it does not yet demonstrate that Eggshell's hooks are enabled.

## Chat 1: investigate

Send this ordinary task prompt:

```text
Investigate how retry_plan.py loads settings and computes a retry plan. Explain
the precedence of defaults, settings.json, environment variables, and command-line
flags. Run the existing tests and identify where another environment override
would belong. Do not change files.
```

After the answer finishes, run these controls inside that same Codex chat:

```text
!egg keep
!egg inspect
```

Eggshell normally saves observed tool results as the task runs and the final
answer when it stops. `!egg keep` explicitly flushes a finished turn before this
exercise moves to a separate chat. `!egg inspect` should identify the sample's
`.eggs/work.egg`, rather than a different project's work file.

Confirm the file exists and is nonempty from the sample's terminal:

```sh
test -s .eggs/work.egg && echo 'saved work found' || echo 'no saved work yet'
```

The file's presence confirms persistence. Its size does not establish relevance
or token savings.

## Chat 2: continue with a related change

Open a **separate, new Codex chat** with the same sample directory as its working
directory. Send:

```text
Add a RETRY_MAX_ATTEMPTS environment override to retry_plan.py. It should override
settings.json, while --attempts must still take precedence. Add focused regression
coverage, run the tests, and summarize what changed and anything still unverified.
```

After that turn completes, inspect the context actually delivered to it:

```text
!egg graph
!egg why
```

Look for relevant work from chat 1: configuration precedence, source locations,
or the earlier test result. `!egg graph` displays the delivered handoff; it does
not perform a new search. The answer alone cannot establish whether memory
arrived, since the model can also investigate the source again.

| Check | Evidence to look for |
| --- | --- |
| Saved | The first chat created a nonempty `.eggs/work.egg`. |
| Delivered | `!egg graph` in chat 2 contains relevant work from chat 1. |
| Completed | The new environment override is implemented, command-line precedence is retained, and the regression tests pass. |
| Useful | The answer uses supported prior findings and clearly describes its new checks. Some additional reads may still be necessary. |

This small exercise checks setup and reuse. It does not establish a token
reduction rate or guarantee that every similar question will receive a handoff.
The [LLVM study](demo.md) reports separate token and answer-quality measurements.

## If a step does not work

| Where you stopped | Next check |
| --- | --- |
| `egg` is not found | Add the installation's `bin` directory to PATH, then reopen the terminal or Codex client. |
| Hooks are missing or disabled | Review `/hooks` after installation, enable Eggshell, and open a new chat. |
| No saved work | Check `!egg inspect` for the sample directory, run `!egg keep` in chat 1, and check `!egg` for an enabled writable profile. |
| Saved, but no handoff | Confirm chat 2 uses the same sample directory. Inspect `!egg why`; an empty handoff is useful feedback. |
| Handoff arrived, but the task failed | Note which prior facts arrived, what was repeated or missed, and which test failed. |

Use the [first-run feedback form](https://github.com/momonpya/eggshell/issues/new?template=first-run.yml)
whether it worked or stopped partway. The most useful report is the last step
that worked and the first step that did not. A short description is enough;
please keep private prompts, credentials, raw `.egg` files, and local personal
paths out of the public issue.
