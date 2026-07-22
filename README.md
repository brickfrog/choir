# Choir

Choir provides durable, sandboxed orchestration for Claude Code and Codex coding
agents. Either provider can act as the interactive Conductor; `choird` turns an
accepted Goal into durable Parts, runs subscription-backed Takes in BoxLite
microVMs, verifies and audits each candidate independently, serializes
promotion, verifies the combined tree, and publishes one final pull request.

Provider sessions never own workflow state. SQLite, typed effects, receipts,
leases, and reconciliation remain authoritative across client exits and daemon
restarts.

## Install

Required:

- Linux with KVM enabled
- Git
- libutf8proc
- SQLite 3 development headers when building and `libsqlite3.so.0` at runtime
- [MoonBit](https://www.moonbitlang.com/) (or `nix develop` for the pinned toolchain)
- [Beads](https://github.com/gastownhall/beads) 1.1.0 (`bd`)
- [BoxLite](https://github.com/boxlite-ai/boxlite) v0.9.7 with Choir's
  [pinned corrected runtime](docs/boxlite-runtime.md)
- Bubblewrap (`bwrap`) for the read-only host boundary around provider clients
- Node.js
- Claude Code 2.1.217 logged into the user's paid subscription
- Codex CLI 0.145.0 logged into the user's paid subscription

GitHub CLI is required only when Choir should publish the final pull request.
No separately metered model credential is required or supported by the default
execution profiles.

```bash
moon build --target native --release
install -Dm755 _build/native/release/build/src/bin/choir/choir.exe ~/.local/libexec/choir/choir
install -Dm644 scripts/choir_sandbox_mcp.mjs scripts/choir_boxlite_owner.mjs -t ~/.local/libexec/choir
install -Dm755 /absolute/path/to/boxlite-v0.9.7 ~/.local/libexec/choir/boxlite
cp -a /absolute/path/to/corrected-runtime ~/.local/libexec/choir/boxlite-runtime
ln -sfn ../libexec/choir/choir ~/.local/bin/choir
choir init
```

This layout is self-contained: Choir resolves the admitted BoxLite executable,
runtime bundle, and trusted runtime programs relative to its own executable.
`CHOIR_BOXLITE_BINARY`, `CHOIR_BOXLITE_RUNTIME_DIR`, and
`CHOIR_RUNTIME_ASSET_DIR` remain explicit development overrides; they are not
required for an installed build.

For an unpackaged development build, set `CHOIR_RUNTIME_ASSET_DIR` to the
absolute `scripts` directory before starting Choir. Choir never loads these
trusted host-side programs from the target repository.

`choir init` creates the local project state, starts `choird`, and opens the
selected Conductor in the current terminal (Claude by default). Later sessions
can use `choir start`.

From the Conductor, discuss the intended feature, create or refine Beads when
needed, then invoke `/goal`. The Conductor proposes the selected Parts and
their contracts; Choir validates and schedules them according to dependencies,
mutation overlap, available provider capacity, and the requested concurrency.

Useful commands:

```bash
choir start --conductor claude
choir start --conductor codex
choir goal status <goal-id>
choir goal steer <goal-id> pause
choir goal steer <goal-id> resume
choir goal steer <goal-id> concurrency 4
choir goal cancel <goal-id>
choir goal attach <take-id>
choir goal answer <request-id> <answer>
choir stop
choir stop --purge
```

Normal stop preserves recoverable Goal state for restart. `stop --purge`
removes every recorded Goal runtime and exact local Goal/witness ref before
deleting durable state. It does not delete user branches, remote branches, PRs,
or source Beads. If external cleanup fails, Choir keeps the database and exits
nonzero so the purge can be retried safely.

## Architecture

The accepted design records are retained under
[docs/charters](docs/charters/README.md). They document the durable Goal
workflow and its migration extension without occupying the repository root.

## Operations

Use the [dependency and runtime upgrade runbook](docs/runbooks/dependency-upgrades.md)
to audit or qualify provider CLIs, BoxLite, Beads, MoonBit, native libraries,
and CI/release infrastructure. It defines a read-only audit mode, component
qualification gates, promotion boundaries, and the required report format for
human or agent-driven maintenance.

## Verify

```bash
node --test scripts/choir_sandbox_mcp_test.mjs
moon check --target native
moon test --target native
moon run --target native src/bin/choir_lint
moon run --target native src/bin/choir_conformance -- hermetic
```

## License

MIT
