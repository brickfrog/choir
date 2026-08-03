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
  [pinned corrected CLI and runtime](docs/boxlite-runtime.md)
- Bubblewrap (`bwrap`) for the read-only host boundary around provider clients
- Node.js
- Claude Code logged into the user's paid subscription
- Codex CLI logged into the user's paid subscription

GitHub CLI is required only when Choir should publish the final pull request.
No separately metered model credential is required or supported by the default
execution profiles.

After installing, `choir doctor` checks every dependency above in one
read-only pass and exits nonzero if a required dependency is missing or a
pinned infrastructure contract has drifted. Provider releases are reported as
information; Choir admits them through protocol, capability, subscription, and
effective-surface qualification before dispatch.

```bash
scripts/install-choir.sh --prefix "$HOME/.local" \
  /absolute/path/to/corrected-boxlite-v0.9.7 \
  /absolute/path/to/corrected-runtime
choir init
```

The prefix defaults to `$HOME/.local`. The corrected BoxLite paths may instead
be supplied as `BOXLITE_BINARY` and `BOXLITE_RUNTIME`.

This layout is self-contained: Choir resolves the admitted BoxLite executable,
runtime bundle, and trusted runtime programs relative to its own executable.
`CHOIR_BOXLITE_BINARY`, `CHOIR_BOXLITE_RUNTIME_DIR`, and
`CHOIR_RUNTIME_ASSET_DIR` remain explicit development overrides; they are not
required for an installed build.

For an unpackaged development build, set `CHOIR_RUNTIME_ASSET_DIR` to the
absolute `scripts` directory before starting Choir. Choir never loads these
trusted host-side programs from the target repository.

## One isolated change

For a single MoonBit task, `choir take` is the smallest useful Choir surface.
It needs no Bead, Goal, daemon, branch, commit, or pull request:

```bash
choir take --provider codex --scope src \
  --verify "test --target native" \
  "Reject empty package names and add focused tests"
```

Choir captures an exact clean `HEAD`, gives exactly one selected subscription
provider only the Choir sandbox tools inside a network-disabled BoxLite guest,
seals the candidate read-only, and runs the registered Moon tool independently.
The bounded patch, changed paths, verification result, provider usage, and
identity digests are printed to the terminal. The command is a dry run by
default. Add `--apply` to apply only that verified patch after Choir rechecks
the clean `HEAD` and patch digest immediately before mutation:

```bash
choir take --provider claude --scope src --apply \
  "Fix the parser boundary and cover the regression"
```

Omitting `--scope` deliberately admits the whole repository. This first
surface is MoonBit-first: verification is a controlled `moon` invocation
(`moon test --target native` by default), not an arbitrary host command.
Provider output cannot apply to the host, mint a verification receipt, or
create durable workflow state. Use a durable Goal when the task needs multiple
dependency-ordered Parts, independent audit, crash-resumable execution, or
receipt-bound pull-request promotion.

`choir init` creates the local project state, starts `choird`, and opens the
selected Conductor in the current terminal (Claude by default). Later sessions
can use `choir start`.

From the Conductor, discuss the intended feature, create or refine Beads when
needed, then invoke the provider's built-in `/goal`. The Conductor proposes the selected Parts and
their contracts; Choir validates and schedules them according to dependencies,
mutation overlap, and the requested concurrency. Concurrency is bounded at
separate layers: per Goal by `maximum_parallel_parts`, and portfolio-wide by a
durable lease on each provider surface, sized by the `[capacity]` section of
`.choir/config.toml`
(`claude`, `codex`, and an optional `global` ceiling across all surfaces).
`capacity.goals` separately bounds concurrent durable Goal jobs and their
BoxLite servers (default `4`). `capacity.work_orders` bounds the independent
durable WorkOrder coordinators and their read-only planner sandboxes (also
default `4`). A Part or planner refused a provider slot is told when to come
back rather than retried in a loop.

Project configuration is deliberately closed: `.choir/config.toml` and its
machine-local overlay `.choir/config.local.toml` accept only
`delivery.pull_requests`, `delivery.merge_method`, `capacity.claude`,
`capacity.codex`, `capacity.global`, `capacity.goals`, and
`capacity.work_orders`. Unknown tables and fields are rejected instead of being
silently ignored; the local file may override the same supported fields.

Choir does not install a slash command or skill named `goal`: `/goal` remains
Claude Code's built-in session goal. While a durable Choir Goal is running, a
deterministic Stop hook parks Claude instead of letting the built-in Goal loop
start another turn. `choird` continues execution independently and sends each
material durable Goal projection through an MCP Channel; that event wakes
Claude for the next useful turn. This makes progress event-driven rather than
a loop of `goal_status` calls, while `choird` remains the only lifecycle
authority.

Goal operation is conversational: ask the Conductor to show status, pause,
resume, change concurrency, attach a Take, cancel, or relay your explicit
answer to an input request. You should not need to leave the Conductor to run
the corresponding CLI command.

The CLI mirrors remain available for automation and recovery:

```bash
choir start --conductor claude
choir start --conductor codex
choir goal status <goal-id>
choir goal steer <goal-id> pause
choir goal steer <goal-id> resume
choir goal steer <goal-id> concurrency 4
choir goal cancel <goal-id>
choir goal archive <goal-id> [--dry-run]
choir goal attach <take-id>
choir goal answer <request-id> <answer>
choir stop
choir stop --purge
```

Normal stop preserves recoverable Goal state for restart. `stop --purge`
requires exact ownership receipts for every direct Take and Goal runtime,
reconciles their BoxLite boxes, removes the canonical repository-scoped
BoxLite home,
deletes durable state and exact local Goal/witness refs, and reports the
reclaimed bytes. It does not delete global caches, external version bundles,
user branches, remote branches, PRs, or source Beads. Missing or ambiguous
ownership and any external cleanup failure keep the database and exit nonzero
so the purge can be retried safely.

`goal archive` is the selective alternative: it reclaims one finished Goal
instead of wiping the installation. Archiving is not deleting. It keeps the
durable Goal record, the Goal's branch, and any stored content another Goal or
a permanent retention still needs; it releases that Goal's own idempotency
witness refs and content whose every recorded retention has expired. A Goal
that is still active, paused, blocked, or recovery-uncertain is refused with
the reason, and `--dry-run` reports exactly what would be released without
releasing it. Sandbox runtime roots are not archived: each one is removed when
its Goal reaches a terminal state, and any residue is reclaimed on the next
daemon start.

## Documentation

Read the documentation overview in [English](docs/overview.md) or
[简体中文](docs/overview.zh.md)（语言/中文）。

## Operations

Use the [dependency and runtime upgrade runbook](docs/runbooks/dependency-upgrades.md)
to audit or qualify provider CLIs, BoxLite, Beads, MoonBit, native libraries,
and CI/release infrastructure. It defines a read-only audit mode, component
qualification gates, promotion boundaries, and the required report format for
human or agent-driven maintenance.

Use the [Goal troubleshooting runbook](docs/runbooks/troubleshooting.md) when a
Goal stops making progress: it maps the on-disk operational surface, the typed
block, pause, and assurance-block reasons, and the read-only and steering
commands that recover from each.

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
