# Contributing

Eggshell keeps a deliberately small semantic core. Before proposing a new
operator or persistent data type, show why the behavior cannot be expressed by
the existing `Value`, `All`, `Outcome`, `Occurrence`, `Inquiry`, `Receipt`, and
scoped Union machinery.

## Development check

Install the toolchain pinned in `lean-toolchain`, then run:

```sh
lake build eggshell eggshell_tests
EGGSHELL_DATA_ROOT="$PWD/.lake/eggshell-tests-data" \
  .lake/build/bin/eggshell_tests
```

Tests must use an isolated absolute `EGGSHELL_DATA_ROOT`; they refuse the normal
user data directory. Keep public claims tied to completed, reproducible measurements.
Build `search_tests` and run `.lake/build/bin/search_tests` to exercise the shipped
local search provider. Its MiniLM numerical runtime and model must already be
cached; the test uses offline mode and makes no generative model requests.
For performance work, total tokens mean input plus reasoning output plus final
output. Quality non-regression and `.egg` growth are constraints; tool count and
elapsed time are diagnostics.

## Pull requests

Keep changes focused, remove replaced code, update user documentation with the
same change, and explain the invariant being preserved. Do not commit models,
vector caches, `.egg` authorities, generated build output, credentials, or
private benchmark transcripts.

## Plugin packaging

`plugins/eggshell` contains the directory package's skill, hooks, and portable
launcher. The standalone installer embeds its manifest and hooks in
`Eggshell/Install.lean`; the existing test enforces that those definitions match.

Build `eggshell`, `eggshell_package`, and `setup_package_tests`, then run
`.lake/build/bin/setup_package_tests` when changing setup or packaging.
These native tests check configuration preservation, read-only inspection,
runtime checksums, ZIP readability, and deterministic packaging.

The manually dispatched **Plugin package** workflow builds and tests all four
platform runtimes, then runs the Lean `eggshell_package` executable. It publishes a small
`eggshell-codex-plugin.zip` and runtime archives whose names include their content
hashes on the release matching the plugin version. Existing standalone release
archives and the release tag are preserved. The ZIP pins the exact runtime
URLs and SHA-256 values; hooks never download dependencies.

A package build is separate from OpenAI directory submission and approval.
Before publishing a listing, inspect the uploaded package, confirm the hooks
and helpers survive normalization, and test setup and a related two-chat handoff
in the target Codex environment.
