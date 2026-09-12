# Search migration fixture

`search-golden.jsonl` contains 24 request/response comparisons: eight each for
lexical, semantic and hybrid retrieval. Expected selections were captured from
the embedded Python provider at commit `64d3737021c697eba4c9fa08a37924b1a9c6874f`,
using Python 3.14.6 (Unicode 16.0) and FastEmbed 0.8.0 with
`sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2`.

The fixture exercises changed text under reused IDs, Unicode, exact identifiers,
long records and retrieval limits. `tests/SearchTests.lean` sends the requests
through the native provider and checks every returned selection, using the
locally cached numerical runtime with model-network access disabled. This is a
selection regression test, not a token-reduction experiment or a proof of
floating-point equivalence. See `docs/lean-boundaries.md` for the proof scope.
