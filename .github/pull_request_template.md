## Summary

Describe the user-visible or semantic change.

## Why

Explain the problem and why this is the smallest general solution.

## Verification

- [ ] `lake build eggshell eggshell_tests`
- [ ] `PLUGIN_DATA=.lake/eggshell-tests-data .lake/build/bin/eggshell_tests`
- [ ] Documentation and privacy behavior are updated when relevant.
- [ ] Performance claims report total tokens and quality, not tool calls alone.

If this changes persistent graph semantics, matching, Union, saturation, or
handoff selection, describe the invariant and include a focused regression test.
