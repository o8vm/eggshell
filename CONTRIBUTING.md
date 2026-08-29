# Contributing

Eggshell keeps a deliberately small semantic core. Before proposing a new
operator or persistent data type, show why the behavior cannot be expressed by
the existing `Value`, `All`, `Outcome`, `Occurrence`, `Inquiry`, `Receipt`, and
scoped Union machinery.

## Development check

Install the toolchain pinned in `lean-toolchain`, then run:

```sh
lake build eggshell eggshell_tests
PLUGIN_DATA=.lake/eggshell-tests-data .lake/build/bin/eggshell_tests
```

Tests must use an isolated `PLUGIN_DATA`; they refuse the normal user data
directory. Keep public claims tied to completed, reproducible measurements.
For performance work, total tokens mean input plus reasoning output plus final
output. Quality non-regression and `.egg` growth are constraints; tool count and
elapsed time are diagnostics.

## Pull requests

Keep changes focused, remove replaced code, update user documentation with the
same change, and explain the invariant being preserved. Do not commit models,
vector caches, `.egg` authorities, generated build output, credentials, or
private benchmark transcripts.
