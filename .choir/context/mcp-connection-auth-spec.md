# Spec: mcp-connection-auth

## Context
choir-3fsr (custom-transport connection auth) closed the leaf-escalation hole:
every real client — the TL's Claude AND every leaf — connects through a
`choir mcp-stdio` bridge subprocess that speaks the CUSTOM transport, which
3fsr.1/.2/.3 now authenticate (per-agent `CHOIR_AGENT_TOKEN` → register frame →
`serve_authenticate_register_request` → connection bound to verified identity).
Two seams were left open, tracked as choir-3fsr.4:

1. **Root/TL's own connection is not authenticated.** No root credential is ever
   minted (`uds_server.mbt` boot does not seed one) and the TL launch sets no
   token env (`launch.mbt:286-301`, the `tl_init_mode=true` path, bypasses
   `shared_env_pairs`). The `--name root` bridge sends a register frame with no
   token, so root's identity falls through unauthenticated. The 3fsr goal "root's
   identity established at boot" is unmet — a connection claiming `agent_id=root`
   with no token is not actually rejected.
2. **The raw JSON-RPC `tools/call` path hardcodes `Role::Root`.**
   `serve_handle_jsonrpc_request_line` (`uds_server.mbt:340,347`) attaches
   `Role::Root` to every JSON-RPC `tools/call` / `tools/list` with no connection
   identity bound. No real client reaches this path today (all go via the bridge →
   custom transport), so it is a local-socket-access privilege issue, not
   leaf-escalation — but it is a standing "anyone who can open the socket and
   write a JSON-RPC line is root" hole.

Outcome we want: root authenticates like any other agent (token minted at boot,
wired into the TL launch, validated at register), with an operator escape so a
wiring bug can never permanently brick the human's TL; and the raw JSON-RPC path
no longer grants Root to unbound connections. This completes the "no trust-based
identity anywhere" model 3fsr promised, and is the last gate before
`feature/server-verified-caller-role` → main.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: Is 3fsr.4 a deep MCP-client-auth research problem (new protocol surface)?**
A: No — the architecture map resolved the unknown. The token-presentation
mechanism already exists and is the production path for leaves: `CHOIR_AGENT_TOKEN`
in the client process env is auto-forwarded by the `mcp-stdio` bridge inside the
custom-transport register frame (`transport.mbt:84,91`;
`mcp_mode.mbt:591`→`mcp_build_registration_message`). Root just needs (a) a minted
credential recorded server-side and (b) that token in the TL process env before
its bridge registers. No bridge/protocol change.

**Q: How far does 3fsr.4 go? (scope)**
A: Full. Root self-authenticates (mint + record + wire into TL launch env) AND
the raw JSON-RPC path is closed (unbound JSON-RPC `tools/call`/`tools/list` no
longer get Root). The status-bar poller, the only real JSON-RPC consumer, keeps a
scoped read-only role, not Root.

**Q: Hard-enforcing root auth risks locking out the human's own TL. Bootstrap?**
A: Mint at `choir init` + recovery escape. `choir init` mints the root token,
hands it to the server at boot so the server records the `root → {Role::Root,
token}` credential, and exports the same token into the TL launch env. Hard-
enforce, but the launcher (`choir claude`, `choir init --recreate`) re-mints and
re-wires on every run, so re-running it is the documented, always-available
recovery. Absent-credential root register is REJECTED with an actionable error
("re-run `choir claude`"), never silently granted — the escape is re-launching,
not an automatic unauthenticated-root fallback. (Not the loopback-trust auto-
bootstrap; not an on-disk token file.)

## Goals
- A root credential `root → {Role::Root, token}` is minted at `choir init` and
  recorded server-side at boot (the server reads it from a boot input, e.g. an
  env/arg init passes when it spawns the server). Token: sufficient entropy, same
  mint adapter as leaves (`mint_spawn_agent_token` / `spawn_agent_token_command`),
  never logged, never in error text.
- The same root token is exported into the TL Claude launch env as
  `CHOIR_AGENT_TOKEN` (the `tl_init_mode=true` launch path), so the `--name root`
  bridge presents it in its register frame with no bridge change.
- The server validates the root register against the recorded root credential and
  binds the connection to the verified `root` identity, exactly like a leaf. A
  connection presenting `agent_id=root` WITHOUT the valid token is rejected.
- Operator escape: re-running the launcher (`choir claude` / `choir init
  --recreate`) re-mints + re-wires the root credential, so a token-wiring bug can
  never permanently brick the TL. Absent root credential at register → reject with
  an actionable message, not a silent root grant.
- The raw JSON-RPC path no longer hardcodes Root: an unbound JSON-RPC
  `tools/call` / `tools/list` is treated as `Role::Worker` (mirroring the existing
  `serve_custom_unauthenticated_request` downgrade), with caller_id/agent_id
  stripped — never `Role::Root`. A JSON-RPC connection that HAS authenticated
  (bound `connected_agent_id`) derives its role from the registry like the custom
  path.
- The status-bar poller (read-only JSON-RPC consumer) keeps working under the
  Worker role / read-only allow-list; it is not granted Root.

## Non-Goals
- Changing the `mcp-stdio` bridge or the MCP wire protocol. The token already
  flows; this wires the root end and closes the raw path. No initialize-param /
  clientInfo token, no per-tools/call token field.
- Per-agent UDS sockets / connection-level socket identity (transport redesign).
- The loopback-trust auto-bootstrap and the on-disk-token-file mechanisms (both
  considered and rejected in Clarifications).
- Token rotation / re-auth mid-session (root token is valid for the session;
  re-mint on relaunch is the recovery, not rotation).
- Removing the existing coarse TCP shared-token gate (`tcp_auth_token`); keep the
  layer.
- `dispatch_call` (`src/tools/dispatch.mbt:2356+`): test/local-harness seam only,
  no CLI or network entrypoint, unreachable by a spawned leaf — do not "secure" it
  (would be a gate satisfying a non-existent caller). Documented, not touched.
- Re-deriving role per-call on the custom path (already done by 3fsr.3); this spec
  only adds the root end and the JSON-RPC end.

## Design
Architecture map verdict: the mechanism exists; root and the raw JSON-RPC path are
the two unwired ends. Two vertical slices.

### Leaf A — root credential end-to-end (mint at init → server record → TL env)
- **Mint + record at boot.** `choir init` mints a root token (reuse the spawn
  mint adapter `spawn_agent_token_command` / `mint_spawn_agent_token`,
  `src/tools/spawn.mbt:80-112`) and passes it to the server it spawns (a boot
  input read in `serve_run`, `uds_server.mbt:1683-1943`, near `ServerState::new`
  ~`:1751`). The server records `record_spawn_credential("root", {role:Root,
  token})` (`registry.mbt:72-95`) — the authoritative root identity, same store
  leaves use. Effect-architecture: minting via the injected capture adapter, no
  raw `@sys`/`@process` in `src/server`; init is a CLI/workspace seam.
- **Wire into the TL launch env.** The `tl_init_mode=true` launch
  (`provider_launch_command`, `launch.mbt:286-301`; TL command assembled at
  `:467-481`) currently sets no token. Export `CHOIR_AGENT_TOKEN=<root token>`
  into the TL Claude process env so the `--name root` bridge forwards it. The
  bridge register path (`mcp_mode.mbt:591` → `format_registration_request`,
  `transport.mbt:84,91`) already reads `CHOIR_AGENT_TOKEN` — no bridge change.
- **Validate + bind root.** Root's register now carries a token, so the existing
  `serve_authenticate_register_request` (`uds_server.mbt:202-253`) validates it
  against the recorded root credential and binds `connected_agent_id="root"` like
  any leaf. Confirm the `--name root` bridge actually emits a register frame
  (`mcp_should_register_connection` true for stable `--name root`,
  `mcp_mode.mbt:47-57`, `:1124-1132`).
- **Escape / never-brick.** Absent recorded root credential at register time →
  REJECT with an actionable error ("root credential not provisioned; re-run
  `choir claude`"), not a root grant. Re-running `choir claude` / `choir init
  --recreate` re-mints + re-wires (Goal: launcher is the recovery). Ensure the
  recovery launch paths flow through the same mint+record+export as init.

### Leaf B — close the raw JSON-RPC Role::Root path
- `serve_handle_jsonrpc_request_line` (`uds_server.mbt:302-419`): `tools/call`
  (`:347`) and `tools/list` (`:340`) hardcode `Role::Root`. Replace with the same
  posture as the custom path:
  - If the connection has a bound, authenticated `connected_agent_id` (the JSON-RPC
    UDS handler `serve_handle_uds_jsonrpc_request_line`, `:1102-1128`, does not set
    it today — thread the bound id through), derive role from the registry for that
    id (like `serve_handle_parsed_custom_request`).
  - If unbound, downgrade to `Role::Worker` and strip caller_id/agent_id —
    mirroring the existing `serve_custom_unauthenticated_request` downgrade
    (3fsr.3). Never `Role::Root`.
- The status-bar poller is a read-only unbound JSON-RPC consumer; confirm
  `status_bar_state` (and any other tool it calls) is reachable at `Role::Worker`
  via the tool-access allow-list (`src/tools/registry.mbt`). If a needed read-only
  tool is Root-gated, that is the bug to surface — do NOT re-widen JSON-RPC to Root
  to accommodate it.
- No new auth handshake on the JSON-RPC path: it simply stops minting Root out of
  thin air. Authenticated JSON-RPC (if a future client binds) flows through the
  same registry-role derivation; unbound is Worker.

## Verify
- ADVERSARIAL (root): a connection presenting `agent_id=root` + `role=Root` over
  the custom transport WITHOUT the recorded root token is rejected at register
  (drive through the register/dispatch path, not a helper). With the recorded
  token it binds and a Root-gated tool (e.g. `goal_set`) succeeds.
- ADVERSARIAL (JSON-RPC): a raw JSON-RPC `tools/call` for a Root-gated tool on an
  unbound connection is refused / runs as Worker (NOT executed as Root) — assert a
  Root-only tool is denied and a Worker read-only tool (`status_bar_state`)
  succeeds on the same unbound JSON-RPC connection.
- Root boot wiring: a unit/adapter test that `init` mints a token, the server
  records `root → {Root, token}`, and the TL launch env carries the same token
  (mock the mint adapter; assert the value threads init → server-record and init →
  TL-env, and is identical). Token value MUST NOT appear in any log/error asserted.
- Escape: with no recorded root credential, a root register is rejected with the
  actionable message (assert message text, assert NOT granted Root); re-running the
  launch path re-records the credential and the next register binds.
- Observable: `CHOIR_TEST_NO_EXEC=1 moon test --target native` (hermeticity
  tripwire — mint/checkout must be injected, no real exec), `moon test --target
  native`, and `moon run src/bin/choir_lint --target native`.

## Boundary (do not)
- Hard-enforce: no log-only phase for root. Absent/mismatched root token → reject;
  the escape is re-launching, not a silent root grant.
- The root token is a secret: never logged, never in error text, sufficient
  entropy (same mint path as leaves). The "actionable error" must not contain the
  token or whether one was recorded beyond what the operator needs.
- Do not introduce the loopback-trust auto-bootstrap or an on-disk token file
  (both rejected in Clarifications).
- Do not change the `mcp-stdio` bridge, the MCP protocol, or add a JSON-RPC token
  field — root rides the existing `CHOIR_AGENT_TOKEN`→register plumbing.
- Unbound JSON-RPC must NEVER resolve to `Role::Root`. Worker + stripped
  caller_id/agent_id, mirroring `serve_custom_unauthenticated_request`.
- Do not "secure" `dispatch_call` (no remote caller exists — gate-without-a-caller).
- No raw `@sys.*`/`@process.*` in `src/server`; mint/record via injected adapters.
- Do not lock out the TL: the launcher path must always re-mint + re-wire so
  recovery is one `choir claude` away.

## Follow-Ups
- choir-v9gi: unblock + re-land the file_pr/merge_pr root empty-contract path once
  this lands (role + caller_id are now server-verified for root too).
- Audit the role-gated / caller_id-gated decisions (3fsr spec sec.6 list) now that
  root is authenticated, in case any silently relied on trust-based root.
- Per-agent JSON-RPC client auth (if a future non-poller JSON-RPC client appears):
  it would bind via the same registry-role derivation; only the poller needs the
  Worker downgrade today.
- Token rotation / re-auth on reconnect (root included), if reconnect handling
  ever needs it.
