# Choir

Choir is a local, subscription-native development orchestrator. Claude Code is
the interactive Conductor; `choird` turns an accepted Goal into durable Parts,
runs Claude Code or Codex Takes in BoxLite microVMs, verifies and audits each
candidate independently, serializes promotion, verifies the combined tree, and
publishes one final pull request.

Provider sessions never own workflow state. SQLite, typed effects, receipts,
leases, and reconciliation remain authoritative across client exits and daemon
restarts. Zellij is not required.

## Install

Required:

- Linux with KVM enabled
- Git
- [MoonBit](https://www.moonbitlang.com/) (or `nix develop` for the pinned toolchain)
- [Beads](https://github.com/gastownhall/beads) 1.1.0 (`bd`)
- [BoxLite](https://github.com/boxlite-ai/boxlite) v0.9.7 with Choir's
  [pinned corrected runtime](docs/boxlite-runtime.md)
- Bubblewrap (`bwrap`) for the read-only host boundary around provider clients
- Node.js
- Claude Code 2.1.216 logged into the user's paid subscription
- Codex CLI 0.144.6 logged into the user's paid subscription

GitHub CLI is required only when Choir should publish the final pull request.
No separately metered model credential is required or supported by the default
execution profiles.

Select the admitted BoxLite installation before starting Choir:

```bash
export CHOIR_BOXLITE_BINARY=/absolute/path/to/boxlite
export CHOIR_BOXLITE_RUNTIME_DIR=/absolute/path/to/corrected-runtime
```

```bash
moon build --target native --release
install -Dm755 _build/native/release/build/src/bin/choir/choir.exe ~/.local/bin/choir
choir init
```

`choir init` creates the local project state, starts `choird`, and opens the
Claude Conductor in the current terminal. Later sessions can use `choir start`.

From the Conductor, discuss the intended feature, create or refine Beads when
needed, then invoke `/goal`. The Conductor proposes the selected Parts and
their contracts; Choir validates and schedules them according to dependencies,
mutation overlap, available provider capacity, and the requested concurrency.

Useful commands:

```bash
choir goal status <goal-id>
choir goal steer <goal-id> pause
choir goal steer <goal-id> resume
choir goal steer <goal-id> concurrency 4
choir goal cancel <goal-id>
choir stop
```

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
