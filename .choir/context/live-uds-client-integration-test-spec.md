# Spec: live-uds-client-integration-test

## Context
The choir-3fsr connection-auth work shipped four-plus integration faults in a row
(#606 TL role-flex, #607 OneShot binding, #608 agent_id-arg-as-identity, #610
leaf-tool env-identity fallback + sender_id provenance) — every one of them
invisible to the test suite and caught only after a live restart on the new
binary. Root cause: every existing server test calls the in-process helper
`serve_handle_request_line(state, line, ...)`, which feeds a request STRING
straight into the handler. It never opens a kernel socket, never runs the accept
loop, never exercises the per-connection bind (`serve_handle_uds_connection` /
`ServeUDSClient.connected_agent_id`), the OneShot disconnect scheduling, the wire
framing, or the real client connect/identity-resolution path
(`client_call_uds` → `client_register_if_needed`; `resolve_leaf_local_cfg`).
Those un-exercised seams are exactly where the regressions lived.

Outcome: a tightly-scoped, hermetic native test that stands up a REAL choir
server on a temp UDS socket and drives the REAL built client over it (both ends
in the same test process — no subprocess, no git repo), covering the five
regression classes (A–E) the Sarcasmotron client-path sweep enumerated. This is
the durable replacement for "green CI + paper audit shipped a broken auth
integration, the live smoke caught it."

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: How "real" should the client side be (the server side is always the real
listener + accept)?**
A: **Real socket, both ends in-process.** Open a real kernel UDS socket on a temp
path; drive the actual per-connection serve routine (`serve_handle_uds_connection`
over a real accepted `server_fd`-side client fd) AND the real client path
(`client_call_uds` → `client_register_if_needed` → write/read framing) from the
same test process. This exercises accept + connection→agent_id bind + OneShot
disconnect scheduling + framing. No subprocess of the built binary; no
hand-rolled byte frames where the real client path exists.

**Lane (corrected after the first CI run):** real-socket tests must follow the
repo's real-exec-integration convention or the static `choir_lint`
`test-exec-reference` rule rejects them. Each case is NAMED
`test "real exec integration: live UDS: <case>"` (so `is_explicit_real_exec_integration_test`
exempts it — `src/lint/lint.mbt:1223`) AND self-skips with
`if !@exec.real_exec_integration_enabled() { return }` at the top (so the
default/hermetic suite never opens real sockets — mirrors `src/exec/exec_test.mbt`).
The cases run ONLY under `CHOIR_TEST_REAL_EXEC=1`, in a CI lane extended from
`.github/workflows/ci.yml:66` (`... moon test --target native src/exec
src/bin/choir`). The runtime `CHOIR_TEST_NO_EXEC` tripwire never sees them
(they self-skip); the static lint exempts them by name.

**Q: Drive the real identity-resolution path (config.local.toml + env), where
#610 hid?**
A: **Yes — but with injected adapters, not real files/process env.**
`resolve_leaf_local_cfg(path_exists_fn, read_file_fn, env_get)` is fully injected;
the test passes closures returning an in-memory `config.local.toml` (only
`default_role`/`listen_uds`) and an in-memory env map
(`CHOIR_AGENT_ID`/`CHOIR_ROLE`/`CHOIR_AGENT_TOKEN`). This drives the REAL
resolution/synthesis logic (catching the #610 env-fallback class) while writing
no real files and mutating no real process env (honoring the repo test-boundary
rules: no ambient host state, no repo-state mutation).

**Q: Which client lifetimes?**
A: **Both OneShot and Session.** OneShot (leaf-tool CLI: register+call+close) must
bind the auth identity but leave `connected_agent_id = None` and schedule NO
disconnect (the #607 surface). Session (mcp-stdio bridge: persistent fd, multiple
calls) binds connection→agent_id and schedules disconnect on close. Their
bind/disconnect logic differs, so both are covered.

## Goals
- A new hermetic native test (inline/whitebox in the `src/bin/choir` package,
  since `ServeUDSClient`, `serve_handle_uds_connection`, `client_call_uds`,
  `resolve_leaf_local_cfg` are package-private) with a small harness that:
  creates a temp dir + sock path, `@uds.server_create`s a real listener, connects
  a real client fd, `accept`s the server side, and drives the real per-connection
  serve routine against the real client write/read — then tears down (close all
  fds, `rm_rf` the temp dir).
- The harness seeds server credentials via the existing test helpers (boot root
  credential for root/TL; minted spawn credentials for sub-TL / Dev / Worker
  tokens) so register authenticates against real credential state.
- **Case A (#606 — strict role gate):** an authenticated root (bound `Role::TL`)
  and a sub-TL call a TL-gated tool over the socket → succeed; a Dev/Worker
  connection claiming a supervisor role → rejected with authenticated-identity
  mismatch. (Covers the strict `req.role != agent.role` reinstated by 47vy.)
- **Case B (sub-TL):** a `role=tl` spawn credential connects (Session), calls a
  TL-gated tool → succeeds; its bound id is the branch-derived id, not `root`.
- **Case C (#607 + #610-Finding1 — OneShot env identity):** a checkout whose
  injected `config.local.toml` carries only `default_role`/`listen_uds`, with
  injected env `CHOIR_AGENT_ID`/`CHOIR_ROLE`/`CHOIR_AGENT_TOKEN` per role →
  `resolve_leaf_local_cfg` synthesizes the env identity (NOT downgraded to
  Worker), the OneShot register authenticates as that identity, the follow-up call
  on the same OneShot invocation authenticates, AND the OneShot register leaves
  `connected_agent_id = None` and schedules no disconnect.
- **Case D (#608 — agent_id arg is not identity):** an authenticated root/TL call
  carrying a TARGET `agent_id` arg (e.g. a kill_agent victim) != caller → NOT
  rejected; a Dev call spoofing `caller_id=root` → rejected.
- **Case E (#610-Finding2 — sender_id provenance):** an authenticated Dev/Worker
  `send_message` with `sender_id=root` → delivered/logged as the bound id (server
  overwrites provenance with the authenticated identity), not as `root`; an
  unbound/oneshot path does not let `sender_id` become `root`.
- All five cases assert over a REAL socket round-trip (write framed request →
  real serve handler → read framed response), not `serve_handle_request_line`.

## Non-Goals
- No subprocess of the built `choir` binary; no driving sh scripts, temp git
  repos, or repo-state mutation (repo test-boundary rules).
- No change to production auth/binding/resolution code — this is a test-only
  addition. If the test surfaces a real bug, file it separately; do not fold a
  production fix into this leaf unless it is the test that is wrong.
- Not replacing the existing `serve_handle_request_line` unit tests — this adds
  the socket-level layer they omit; they stay.
- Not testing TCP transport, the reload/replace-self path, or Gemini/Cursor
  clients — UDS leaf-tool (OneShot) + mcp-stdio bridge (Session) only.
- Not mutating real process environment or writing real config files (inject via
  the existing adapter closures).

## Design
Single leaf — one cohesive harness plus the five cases; the harness is the bulk
of the work and the cases are thin assertions over it.

**Package / placement:** inline `test` blocks in `src/bin/choir` (alongside the
existing `async test "..."` blocks in `uds_server.mbt`, or a new sibling source
file in the same package, e.g. `uds_live_integration.mbt`, to keep it readable).
Whitebox is required: the seams are package-private.

**Harness (`with_live_uds_server(fn(ctx) { ... })`-shaped):**
1. Temp dir under a dedicated test area; sock path = `<tmpdir>/server.sock`.
2. `@uds.server_create(sock)` → `server_fd`; set nonblocking as the real loop
   does (`uds_server.mbt:2862-2872`).
3. Seed `ServerState` with credentials via existing helpers (boot root credential
   + minted spawn credentials for the roles under test).
4. Client side: real `@uds.client_connect(sock)` (or the real `client_call_uds`
   for the OneShot cases, which connects + registers + calls + closes).
5. Server side: `@uds.accept_nonblocking(server_fd)` → server-side client fd; wrap
   in `ServeUDSClient`; pump `serve_handle_uds_connection` to process the framed
   request(s) and drive the bind/disconnect lifecycle.
6. Teardown: close client + server fds, `@sys.rm_rf(tmpdir)`. Guard so a failed
   assertion still tears down (no fd/socket leak into the suite).

**OneShot vs Session in the harness:**
- OneShot: prefer driving the real `client_call_uds(role, config, local_cfg,
  req)` (connect→register→call→close) so the real client framing + register path
  runs; assert server-side `connected_agent_id == None` and no disconnect
  scheduled (the #607 invariant), and that the call authenticated.
- Session: connect once, send register then ≥2 tool calls on the SAME fd, assert
  the connection→agent_id bind persists across calls and a disconnect is scheduled
  on close.

**Identity resolution (Case C):** call `resolve_leaf_local_cfg` /
`leaf_tool_load_config` with injected `path_exists_fn`/`read_file_fn`/`env_get`
closures returning the in-memory `config.local.toml` + env map; feed the resolved
`LocalConfig`/identity into the real register over the socket. Assert it resolves
to the env identity, not a Worker downgrade.

**Seams referenced (read first):**
- `src/bin/choir/uds_server.mbt`: `serve_handle_uds_connection` (per-connection
  loop, ~:2122), `ServeUDSClient` (+`connected_agent_id`, ~:45), the accept/listen
  block (~:2862-2895), and the existing credential-seeding test helpers
  (`serve_assert_register_ok`, the boot/spawn credential setup, ~:933-1130).
- `src/bin/choir/leaf_tool.mbt`: `client_connect_uds` (:823), `client_call_uds`
  (:837), `client_register_if_needed`, `resolve_leaf_local_cfg` (:477),
  `leaf_tool_load_config` (:551), the injected-adapter defaults (:438-449).
- `src/server/handler.mbt`: `request_with_authenticated_identity` (strict check),
  `request_with_verified_caller` (caller_id/sender_id normalization) — for what
  each case must observe.
- `src/uds/uds.mbt`: `server_create`, `client_connect`, `accept_nonblocking`,
  `read_bytes_nonblocking`, `write_bytes`, `close`.

## Verify
- `CHOIR_TEST_REAL_EXEC=1 moon test --target native src/bin/choir` — the five
  cases RUN (real sockets) and pass. Observable:
  `CHOIR_TEST_REAL_EXEC=1 moon test --target native src/bin/choir 2>&1 | grep -i
  "live UDS"` shows the five `real exec integration: live UDS: <case>` markers
  passing.
- `CHOIR_TEST_NO_EXEC=1 moon test --target native` — full suite green; the live
  cases SELF-SKIP (suite stays hermetic, no real sockets).
- `moon test --target native` — full suite green (cases self-skip in the default
  lane too).
- `moon run src/bin/choir_lint --target native` — exit 0 (the
  `real exec integration:` naming clears `test-exec-reference`).
- CI: `.github/workflows/ci.yml` real-exec lane extended to include
  `src/bin/choir` so the cases actually execute in CI.
- Negative-control sanity: temporarily reverting the 47vy strict check (or #608
  fix) in a scratch build makes Case A (or D) FAIL — i.e. the test actually
  catches the regression class it targets. (Documented manual check in the PR, not
  committed.)

## Boundary (do not)
- Both socket ends in the SAME test process. No subprocess of the built binary, no
  sh harness, no temp git repo, no `git`/repo-state mutation.
- Do NOT mutate real process environment or write real config files — inject the
  `config.local.toml`/env via the existing adapter closures.
- Temp area only for the sock path; ALWAYS tear down (close every fd, `rm_rf` the
  tmpdir) even on assertion failure — no leaked sockets/fds into the suite.
- Test-only: do not modify production auth/binding/resolution code in this leaf.
  If a real bug surfaces, file a separate bead; do not smuggle a fix in here.
- Drive the REAL per-connection serve routine + REAL client path — do NOT fall
  back to `serve_handle_request_line` for the socket-level assertions (that is the
  exact gap being closed).
- Whitebox/inline in `src/bin/choir` (private seams). Do not put these in a
  blackbox `_test.mbt` (won't compile against the private symbols).
- Real-exec-integration lane is MANDATORY: name each case
  `test "real exec integration: live UDS: <case>"` and self-skip via
  `@exec.real_exec_integration_enabled()`. Do NOT let the live cases run real
  sockets in the default/hermetic suite, and do NOT try to suppress the
  `test-exec-reference` lint any other way (no inline-ignore hacks).
- No new raw `@sys.*`/`@process.*` in the forbidden layers; `@uds.*` and the
  test-local `@sys.rm_rf`/temp-dir use stay at the bin/test seam.

## Follow-Ups
- Extend to the TCP transport register path (same bind logic, different listener)
  once UDS is locked.
- A `CHOIR_TEST_REAL_EXEC`-gated variant that subprocesses the actual built
  leaf-tool / mcp-stdio binary end-to-end (highest fidelity), if the in-process
  socket test ever proves insufficient.
- Fold the reload/replace-self credential-restore path into a live case (it has
  its own credential lifecycle).
