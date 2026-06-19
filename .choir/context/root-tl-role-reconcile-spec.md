# Spec: root-tl-role-reconcile

## Context
choir has two names for the root supervisor's role. The boot credential records
`agent_id="root"` as `Role::Root` (`uds_server.mbt:217`,
`runtime_commands.mbt:125`), but everything else treats the TL as `Role::TL`:
the launch sets `CHOIR_ROLE=tl`, the MCP bridge sends `role=tl`, and the tool
allow-lists / supervisor checks use `Role::TL`. This split caused a cascade of
auth regressions this session: the TL was locked out (`req.role=TL` vs bound
`Role::Root`) until the #606 supervisor-flex band-aid, and root couldn't
`file_pr`/`track_pr` until the #611 allow-list band-aid. Each band-aid patched a
facet instead of the cause. choir-3fsr (P1 ancestor: choir-47vy) calls for
reconciling root to ONE role. Outcome: root is `Role::TL` everywhere, the
`Role::Root` variant is gone (so no future code can re-open the drift), the few
"identify the root specifically" sites key off `agent_id == "root"`, and the
#606/#611 band-aids are reverted — re-tightening the verified-caller check to
strict role equality.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: How far does the reconcile go?**
A: **Eliminate `Role::Root` entirely.** Root becomes `Role::TL`; remove the
`Role::Root` enum variant from `src/types/domain.mbt` so the compiler forces every
match arm to be handled (no silent drift). The ~8 sites that currently use
`Role::Root` to mean "the root specifically" switch to keying off
`agent_id == "root"`. The wire role string `"root"` parses to `Role::TL`.

**Q: Revert the #606 (supervisor role-flex) and #611 (Root in file_pr/track_pr
allow-lists) band-aids?**
A: **Revert both.** With root == `Role::TL` and the bridge sending `tl`, the
verified-caller check gets `req.role == agent.role` again, so #606's
supervisor-flex relaxation is removed — restoring strict role equality (tighter
spoof gate). Root is already covered by `[TL, Dev]`, so #611's explicit `Root`
entries come back out.

**Q: Won't root and sub-TLs (fork_wave role=tl) both be `Role::TL` then — how do
we still tell the root apart?**
A: By `agent_id`. The root's agent_id is the literal `"root"`; sub-TLs have
branch-derived ids. Anywhere the old code distinguished THE root from other
supervisors by `role == Role::Root`, use `agent_id == "root"`. Anywhere it meant
"any supervisor", use `is_supervisor_role(role)` (which is now just `== TL`).

## Goals
- The boot/reload root credential records `Role::TL` (not `Role::Root`):
  `serve_record_boot_root_credential` (`uds_server.mbt:211`) and the
  `runtime_commands.mbt` reload credential.
- The `Role::Root` enum variant is removed from `src/types/domain.mbt`; the build
  compiles only once every former `Role::Root` match arm is resolved.
- `Role|TL → same` sites (Category A) collapse to the `TL` arm:
  `is_supervisor_role` (`domain.mbt:12`), `mcp_mode.mbt:27/53`, `wave_state.mbt`,
  `dispatch.mbt:255/2352`, `spawn.mbt:434`, `claude_wrapper.mbt:221`,
  `phase/service.mbt:488`, and the `registry.mbt` allow-lists
  (`[Root, TL] → [TL]`, `[Root, TL, Dev] → [TL, Dev]`).
- `Role::Root → "identify the root"` sites (Category B) key off `agent_id ==
  "root"` (or the appropriate context), preserving today's behavior:
  `handler_disconnect.mbt:1149-1151` (→"root"), `workspace.mbt:422` (→"root"),
  `status_bar_state.mbt:692` (→"root"), `parse.mbt:1628` & `recovery.mbt:370`
  (→`AgentType::Claude`), `phase/lifecycle.mbt:335` (→`Supervisor(Planning)`),
  `spawn.mbt:447` (roots collection), `pending_wave.mbt:608`.
- The wire role string `"root"` parses to `Role::TL` (`transport.mbt:12`,
  `hooks.mbt:335`) — a back-compat alias so an old client/credential saying
  `"root"` still binds as a supervisor.
- #606 reverted: `request_with_authenticated_identity` (`handler.mbt`) uses
  strict `req.role == agent.role` again (drop the supervisor-flex clause); a
  non-supervisor claiming a supervisor role is still rejected.
- #611 reverted: `file_pr`/`track_pr` allow-lists drop the explicit `Role::Root`
  (back to `[TL, Dev]`) — root, now `TL`, is still allowed.
- Live: a real root TL (bound as `Role::TL`) can `fork_wave`/`file_pr`/
  `track_pr`/`merge_pr`/`kill_agent`; root-specific behaviors (disconnect names
  "root", recovery agent-type, lifecycle) unchanged.

## Non-Goals
- No change to sub-TL (`fork_wave role=tl`) behavior — they were already
  `Role::TL` and stay so.
- No change to the MCP wire protocol beyond parsing `"root"` → `TL` and the
  credential role value.
- Not touching the completion-handoff hooks, the 3fsr connection-auth mechanism
  itself (token mint/validate/bind), or the handoff_status surface — only the
  ROLE the root binds as and the strict-vs-flex check.
- Not renaming the `"root"` agent_id (it stays `"root"`); only the role changes.

## Design
This is an ATOMIC refactor: removing the `Role::Root` enum variant won't compile
until every match arm is handled, so it lands as ONE coordinated change (one
leaf), not parallel slices.

1. **Flip the credential role** to `Role::TL`: `serve_record_boot_root_credential`
   (`uds_server.mbt:217`), `runtime_commands.mbt:125/133`.
2. **Remove `Role::Root`** from the `Role` enum (`src/types/domain.mbt:3`). Then
   resolve every compiler error:
   - Category A (Root|TL together) → keep the `TL` arm / drop `Root`.
   - Category B (root-specific) → replace `role == Role::Root` with `agent_id ==
     "root"` at the call site (thread agent_id where needed), preserving the
     mapped value (→"root" / →Claude / →Supervisor(Planning) / roots-collection).
     Each Category B site: confirm whether it means "the root" (use agent_id) or
     "any supervisor" (use is_supervisor_role).
   - Wire parse (`transport.mbt:12`, `hooks.mbt:335`): `"root"` → `Role::TL`.
3. **Revert #606**: in `request_with_authenticated_identity` (`handler.mbt`),
   restore `if req.role != agent.role { mismatch }` (remove the `||
   is_supervisor_role(...) && is_supervisor_role(...)` flex). Update/replace the
   #606 whitebox test: a TL-labeled request on a TL-bound root is now a plain
   exact match; a Dev claiming a supervisor role is still rejected.
4. **Revert #611**: `registry.mbt` `file_pr` and `track_pr` allow-lists
   `[Root, TL, Dev] → [TL, Dev]`.
5. **Tests / helpers**: update every test asserting `Role::Root` (the
   `serve_assert_register_ok(..., Role::Root)`, `init.mbt:885/907`,
   `recovery.mbt:379`, `uds_server.mbt` register tests) to `Role::TL`. The
   compiler + `grep -rn "Role::Root"` returning zero is the completeness check.

## Verify
- `grep -rn "Role::Root" src/` returns NOTHING (variant fully removed).
- Unit: `request_with_authenticated_identity` — a TL-bound `agent_id="root"`
  request with `role=tl` is accepted (exact match); a Dev-bound connection
  sending `role=tl` is REJECTED (strict check restored, escalation still blocked);
  an `agent_id` TARGET arg (kill_agent victim) still does not trip it (#608
  behavior intact).
- Root-specific behavior preserved: a disconnect for `agent_id="root"` still names
  "root"; `default_agent_type` for the root recovery path still yields the right
  type; root's lifecycle still `Supervisor(Planning)`.
- Allow-lists: `lookup(Role::TL, "file_pr")`, `lookup(Role::TL, "track_pr")` =
  Ok; `lookup(Role::Worker, "file_pr")` = Err.
- Observable (live, self-skips under CHOIR_TEST_NO_EXEC or documented manual): a
  real root TL binds as `Role::TL` and `track_pr`/`file_pr`/`fork_wave` succeed;
  the serve.log register shows `role="tl"` for `agent_id="root"`.
- `CHOIR_TEST_NO_EXEC=1 moon test --target native`, `moon test --target native`,
  `moon run src/bin/choir_lint --target native`.

## Boundary (do not)
- Atomic: remove the `Role::Root` variant AND fix every match arm in the same PR;
  do not leave a compatibility shim variant or a `legacy_root` alias.
- Preserve behavior: every Category B site must keep its current effect for the
  root, now keyed off `agent_id == "root"` — do NOT silently change what the root
  maps to (agent_id "root", AgentType Claude, Supervisor(Planning), etc.).
- Do not change sub-TL behavior (they stay `Role::TL`).
- Keep the security tightening: strict `req.role == agent.role` (do not
  reintroduce supervisor-flex); a non-supervisor claiming supervisor stays
  rejected; the #608 agent_id-arg-is-not-identity behavior stays.
- Do not touch the 3fsr token mint/validate/bind, the completion-handoff hooks,
  or `handoff_status`.
- `"root"` agent_id is unchanged; only the role binding flips to TL.
- No raw `@sys.*`/`@process.*` added to forbidden layers.

## Follow-Ups
- If any Category B site is genuinely ambiguous (root vs any-supervisor), flag it
  in the PR rather than guessing.
- Once landed, the `is_supervisor_role` helper is `role == Role::TL` only —
  consider whether it still earns its name or should be inlined (minor; not this
  spec).
