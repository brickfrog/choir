# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased] - 2026-04-03

### Added
- **Copilot Reliability**: Automated `gh pr edit --add-reviewer @copilot` in `file_pr` to replace flaky comment-triggers.
- **Review Context**: Support for `review_context` in `file_pr` and `fork_wave`, automatically injecting intent into Copilot reviews.
- **Host Adapters**: New `PaneWatchHost` and `RecoveryReconcileInput` snapshots to contain server-heavy I/O.
- **Robust Poller**: Recognition of both `[bot]` and non-suffixed Copilot identities.
- **Idiomatic Errors**: `ChoirError` converted to `suberror` for use with MoonBit's `raise` / `try` patterns.

### Changed
- fork-wave: enrich TaskContract from Chainlink issue when issue_id provided (#6)
- ChainlinkIssue Show impl ignores self and logger — printing issues produces no output (#4)
- Non-numeric items in blocked_by array silently dropped during parse (#5)
- chainlink-to-taskcontract: map ChainlinkIssue into TaskContract (#3)
- test spec issue (#2)
- test spec issue (#1)
- **Architecture**: Completed all 6 major migrations from the North Star plan; the core is now purely logic-driven with explicit effects.
- **Boilerplate Reduction**: Switched all lifecycle and phase types to `derive(ToJson, FromJson)`, deleting over 1,500 lines of manual serialization.
- **Modernized Core**: Refactored `src/tools`, `src/server`, and `src/phase` to leverage checked exceptions.
- **Unified Init**: `choir init` now shares the same runtime asset generators as `fork_wave`.
- **Shrunken Server**: Decoupled post-tool orchestration and recovery logic from `ServerState`.

### Removed
- Dead `init_*` code and duplicate Pi extension generators in `main.mbt`.
- Manual JSON converter boilerplate across the codebase.

## [0.1.0] - 2026-03-31

### Added
- Initial project release with local server and multi-agent orchestration.
- Support for Claude, Gemini, Codex, and Pi runtimes.
- Git worktree-based isolation for leaf agents.
