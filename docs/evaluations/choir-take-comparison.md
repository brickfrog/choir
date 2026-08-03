# `choir take` comparison attempt

## Outcome

The planned nine-cell comparison did not complete. No anonymous acceptance
pass, method ranking, or portable-toolchain expansion decision was produced.
The result must not be interpreted as evidence that `choir take` matches or
does not match direct Codex on the three planned tasks.

The immutable base was `87bfe26d`, the squash commit that added per-provider
Goal usage. The frozen matrix covered `choir-ov8`, `choir-zd5`, and `choir-66v`
under direct Codex, Claude invoking exactly one nested Codex session, and
`choir take --provider codex --apply`. Cells were to run sequentially from
detached worktrees at that base, with fixed scopes, MoonBit verification, and
synthetic outside-worktree and loopback canaries.

## Completed evidence

Only the first direct-Codex cell produced a candidate. It ran the `choir-ov8`
audit-context task in 35 minutes 39 seconds. Codex reported 32,651,706 input
tokens, including 32,276,736 cached input tokens, and 65,637 output tokens. Its
normalized patch was 52,781 bytes with SHA-256
`967bf14dc94f47606e51193086d4a61dedda0e6097a2f7bc868037074c27834a`.
The candidate passed 17 sandbox MCP tests and 974 hermetic native tests in its
isolated cell. It was not anonymously accepted or selected because the matrix
never reached the acceptance phase.

The next Claude-to-Codex cell used Claude Code 2.1.220. The initial attempt and
the one permitted infrastructure retry each requested the single frozen Bash
invocation, but Claude's noninteractive `dontAsk` policy denied it before the
nested Codex process started. No candidate or nested-provider usage existed for
either attempt. The retry authority was exhausted, so continuing could not
produce the required valid nine-cell matrix.

## Boundary and cleanup record

The failed delegated attempts were infrastructure failures, not rejected model
patches. Since all nine candidates were required before inspection and
selection, the comparison stopped at that point. No production patch was
adopted from the matrix; the remaining production tasks were implemented and
reviewed separately.

Synthetic canaries and their loopback endpoint were removed. The dedicated
temporary evidence root and detached worktrees were also removed after their
bounded result was recorded. Raw provider transcripts and patch blobs are not
tracked in this repository.

`choir-z0r` therefore closed as abandoned without a valid comparison decision.
`choir-bwh`, the portable per-project verification-toolchain work, closed
without authorization. A future expansion proposal requires a new frozen
comparison; it cannot treat this incomplete attempt as a passing or failing
matrix.
