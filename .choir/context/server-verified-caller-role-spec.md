# Spec: server-verified-caller-role

## Context
The choir server trusts the client-supplied wire `role` (and `agent_id` /
`caller_id`) on every request; there is no connection authentication. A spawned
Dev leaf can present `role=Root` and spoof any role-gated decision (surfaced by
the choir-v9gi round-2 audit: the file_pr root empty-contract path is reachable
by a Dev leaf passing `role=root` + `agent_id=root`, skipping required verify).
The only connection-level identity (`connected_agent_id`, uds_server.mbt:45) is
itself set from the unauthenticated wire `agent_id` and used solely for
disconnect logging; the registry can map `agent_id -> role` but both the key and
the stored role were seeded from wire data. We want the server to **authenticate
each connection's agent identity** (a per-agent secret minted at spawn, presented
at register, validated server-side and bound to the connection) and derive role
**and** caller_id from that authenticated identity, never from per-request wire
values. This is bead choir-3fsr; it unblocks choir-v9gi.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: No connection auth exists; which approach?**
A: Per-agent token + handshake. Mint a per-agent secret at spawn (alongside
CHOIR_AGENT_ID/CHOIR_ROLE), the leaf presents it on its register request, the
server validates it against the spawn-recorded value and binds connection ->
agent_id. Role and caller_id then derive from the authenticated identity.
Generalizes the existing TCP shared-token pattern to per-agent. (Not: a minimal
register-time guard, which leaves agent_id spoofable; not SO_PEERCRED, which is
fragile across same-uid leaves.)

**Q: What does the auth bind?**
A: Full agent identity (authenticate agent_id), so BOTH the verified role
(registry lookup) and caller_id become trustworthy in one binding. Several gates
key off caller_id (resolve_my_review_threads, etc.), so role-only would leave
3fsr partially open.

**Q: Transport + rollout scope?**
A: Both UDS and TCP, hard-enforce. UDS (the primary leaf transport, no
connect-auth today) and TCP (currently only a single shared token, no per-agent
identity) both get per-agent auth; requests that fail it are rejected (no
log-only phase).

## Goals
- A per-agent secret token is minted at spawn and handed to the agent
  (env, alongside CHOIR_AGENT_ID/CHOIR_ROLE), with sufficient entropy; never
  logged or surfaced in errors.
- The server records, at spawn, the AUTHORITATIVE `(agent_id -> role, token)` for
  each spawned agent (the role the TL spawned it with, not the leaf's later
  self-declaration).
- The agent presents its token in the register handshake on BOTH UDS and TCP.
- The server validates the presented token against the spawn-recorded token for
  the claimed agent_id; on success it binds connection -> authenticated agent_id;
  on absent/mismatched token it REJECTS the register and drops the connection.
- After binding, dispatch derives the caller's role from the registry for the
  connection's authenticated agent_id (replacing `caller_role=req.role`), and
  caller_id from the authenticated agent_id (replacing the wire `caller_id`).
- A connection that presents wire role/agent_id/caller_id contradicting its
  authenticated identity is rejected (privilege-escalation attempt) rather than
  silently honored. The v9gi spoof (Dev leaf -> `file_pr agent_id=root`) fails
  closed end-to-end.
- Root/TL's own connection is authenticated too (its identity established at
  boot), so legit root feature->main flows keep working.

## Non-Goals
- Per-tool capability tokens / scoped capability envelopes (richer layer atop
  verified identity; separate).
- Encrypting the UDS/TCP channel (TLS). This is identity authentication, not
  transport confidentiality.
- Token rotation / re-auth mid-session (mint-at-spawn, valid for the agent's
  lifetime; reconnect handling is a follow-up if needed).
- Removing the existing coarse TCP shared-token gate; the per-agent layer is
  added without silently dropping an existing security layer.
- Fixing choir-v9gi's logic here; once role + caller_id are verified, v9gi's
  role-gate becomes sound and is unblocked separately.

## Design
Verdict from the architecture map: no usable verified-role binding exists today;
this adds connection authentication. Vertical slices:

### Leaf A — mint + record the per-agent credential at spawn (authoritative role)
- `src/workspace/spawn.mbt:108-122`: alongside CHOIR_AGENT_ID/CHOIR_ROLE/
  CHOIR_SESSION_ID, mint a per-agent secret and export `CHOIR_AGENT_TOKEN`.
- Record `(agent_id -> {role, token})` server-side AT SPAWN as the authoritative
  source (the spawn runs through the fork_wave/spawn tool server-side). Home:
  extend the registry `Agent` (`src/types/domain.mbt:926-928`) with a token field
  and an authoritative spawn-role, or a server-side credential store keyed by
  agent_id. This also closes the "registry role seeded from wire" gap: the role
  comes from the spawn record, not the leaf's register `role`.
- Token: real entropy; never logged. Effect-architecture: generation via an
  injected adapter; no raw @sys in src/server.

### Leaf B — validate the token at register, bind connection -> agent_id (UDS + TCP)
- Leaf side: `format_registration_request` (`src/transport/transport.mbt:79-123`)
  includes the token from `CHOIR_AGENT_TOKEN`.
- UDS server: register handling (`src/bin/choir/uds_server.mbt:719-741`,
  `:149-158`, `:132-146`): validate the presented token against the spawn-recorded
  token for the claimed agent_id; on success set `connected_agent_id` to the
  VALIDATED agent_id; on failure reject the register and drop the connection
  (today `connected_agent_id` is set from wire `agent_id` unconditionally).
- TCP server: `serve_handle_connection` (`uds_server.mbt:630-667`) already gates
  the first line on the shared `tcp_auth_token`; layer the per-agent register-
  token validation after it and bind the connection's agent identity the same way.
- Result: a trustworthy connection -> authenticated agent_id binding.

### Leaf C — derive role + caller_id from the authenticated connection; reject mismatch
- Thread the connection's authenticated agent_id from the serve loop into request
  handling (`serve_handle_internal_request` -> `state.handle` -> `handle_request`).
- `src/tools/dispatch.mbt:2136` (tool-access `registry.lookup(role,name)`) and
  `:2232-2233` (`caller_role`/`caller_id`): use the registry role for the
  authenticated agent_id and the authenticated agent_id as caller_id, NOT the wire
  values. A request whose wire role/agent_id/caller_id contradicts the
  authenticated identity is rejected (surface the escalation attempt).
- Root/TL: establish the root identity + token at server boot so the TL's own
  connection authenticates; do not lock out root.

## Verify
- ADVERSARIAL (the core): a connection presenting `agent_id=root` + `role=Root`
  WITHOUT the valid root token is rejected at register; and a Dev leaf (validly
  authenticated as Dev) calling `file_pr agent_id=root` / `role=root` does NOT
  reach the supervisor path — it gets its verified Dev identity and fails closed.
  Drive end-to-end through the dispatch/register path, not a helper.
- A legit leaf spawned with its token registers successfully; its role/caller_id
  are the spawn-recorded values regardless of wire contents.
- Root/TL feature->main flow still works (file_pr/merge_pr as root succeed).
- Both UDS and TCP register paths exercised (token accepted / rejected).
- Observable: spawn a leaf, have it attempt `role=root`, and assert a role-gated
  tool (e.g. goal_set or the file_pr root path) refuses + the server logs the
  rejected/overridden identity (token value NOT in the log).
- `moon test --target native` and `moon run src/bin/choir_lint --target native`.

## Boundary (do not)
- Hard-enforce: reject unauthenticated/mismatched register; no log-only phase.
- The token is a secret: never logged, never in error text, sufficient entropy.
- Do not lock out root/TL — its connection must authenticate (boot-established).
- Do not trust wire role/agent_id/caller_id for ANY decision once auth lands;
  the authenticated identity is the sole source.
- No raw @sys.*/@process.* in src/server; token gen/storage via injected adapters.
- Do not encrypt the channel (out of scope) or remove the existing TCP shared
  token (keep layers coherent).

## Follow-Ups
- choir-v9gi: unblock + complete once role/caller_id are server-verified (the
  role-gate becomes sound; re-land the root empty-contract relaxation).
- Audit every role-gated and caller_id-gated decision (architecture map sec.6:
  tool-access allow-lists, goal_set, resolve_my_review_threads, file_pr Dev/TDD
  gates, prenotify, parent-branch policy, register supervisor-upgrade) now that
  the values are trustworthy.
- Token rotation / re-auth on reconnect, if reconnect handling needs it.
- choir-capability-envelopes (scoped per-tool capabilities) atop verified identity.
