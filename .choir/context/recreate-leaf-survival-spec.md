# Spec: recreate-leaf-survival

## Context
`choir init --recreate` restarts the server as a BRAND-NEW process (kills the old
server by pid, launches a fresh `choir serve` tab). Leaf tabs persist across the
recreate (init only reaps Server/TL). But the fresh server has no in-memory spawn
credentials, and `recover_state` (`src/runtime/recovery.mbt`) restores agent rows
+ PR tracking but NOT `spawn_credentials`. So a leaf still mid-work reconnects with
its old `CHOIR_AGENT_TOKEN`, the fresh server has no matching credential
(`uds_server.mbt`), register is rejected, and the leaf can no longer
`file_pr`/`notify_parent` — its in-flight work is silently orphaned. (The #604
reload-credential env-carry only covers the in-place `server_reload` re-exec, not
the operator-initiated `--recreate` fresh process.)

This is a P2, operator-initiated edge case: it only bites a leaf that is STILL
WORKING (PR not yet filed). Already-filed PRs are unaffected — the poller tracks
them via GitHub across the restart. The actual harm is the SILENT loss.

Outcome (chosen fix): rather than engineer a cross-process credential carry (new
root-only export surface, gold-plating a deliberate-operator edge case),
`choir init --recreate` REFUSES when it would orphan live working leaves — listing
them and telling the operator to drain first — unless `--force` is passed. This
eliminates the silent data loss with near-zero new surface.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: f6kd is a P2 operator-initiated edge case — what's the right-sized fix?**
A: **Guardrail / drain-first.** Make `choir init --recreate` detect live working
leaves (active leaf agents with no filed PR) and refuse, directing the operator to
drain first, with a `--force` override. Do NOT build the credential carry (the
root-only export RPC) — that adds security surface to handle a deliberate-operator
edge case. Eliminate the silent data loss; that's the actual harm.

**Q: How should the guardrail behave when live working leaves exist?**
A: **Hard refuse + `--force`.** Exit non-zero, list the live leaves, and do NOT
kill/recreate the server unless `--force` is passed. The operator must consciously
override (drain the leaves, or `--force`).

## Goals
- A pure decision function, e.g.
  `init_recreate_orphan_guard(candidates : Array[OrphanLeaf], force : Bool) ->
  Result[Unit, OrphanGuardError]`: candidates non-empty AND !force ⇒ refuse with a
  message naming the leaves and the remedy (drain or `--force`); empty OR force ⇒
  proceed. Unit-testable, no I/O.
- Orphan detection: enumerate "live working leaves" = leaf agents (role
  Dev/Worker) that are still ACTIVE (not a terminal done/failed state) AND have NO
  filed PR (no tracked/open PR for their branch). Reuse the persisted agent +
  PR-tracking state that `recover_state` already reads; inject the readers so it is
  hermetic-testable. (No new server RPC; no live-server query dependency.)
- `--force` flag parsed by `choir init` and threaded to the recreate path.
- Wiring: the guard runs in the `--recreate` flow BEFORE the server kill /
  runtime cleanup. On refuse ⇒ print the message, exit non-zero, leave the running
  server + leaves UNTOUCHED. On `--force` ⇒ proceed (and still print a warning
  naming the leaves being orphaned).
- The guard inherits to anything that calls `choir init --recreate` (e.g.
  `choir-sanity`); automated flows opt in via `--force`.
- Observable: with a live working leaf present, `choir init --recreate` exits
  non-zero and names the leaf; with `--force` it proceeds with a warning; with no
  live working leaves it behaves exactly as today.

## Non-Goals
- NOT carrying spawn credentials across the recreate (the rejected option (a) — a
  root-only export RPC + `CHOIR_RELOAD_CREDENTIALS` carry). Recorded as a
  follow-up if the edge case ever proves common enough to warrant it.
- No change to the `server_reload` in-place re-exec credential carry (#604) — that
  path already works and is untouched.
- No change to `recover_state`'s restore behavior (it still restores agent rows +
  PR tracking; we only READ the same state to detect orphan candidates).
- Not auto-draining or auto-filing leaves' PRs; not respawning leaves with fresh
  credentials. The guard only refuses/warns; the operator drains.
- No change to the `--purge` path semantics beyond the shared `--force` plumbing
  if relevant.

## Design
Single leaf. `choir init` is a bin/CLI seam (`src/bin/choir/init.mbt`); keep the
decision pure and inject the I/O (per the effect architecture — no raw `@sys`/
`@process` in the decision logic; readers injected with defaults).

1. **Orphan model + detection** (`src/bin/choir/init.mbt`, or a small sibling in
   the same package):
   - `OrphanLeaf { agent_id, branch }` (minimal).
   - `init_recreate_orphan_candidates(... injected readers ...) ->
     Array[OrphanLeaf]`: enumerate leaf agents from persisted state (the same
     source `recover_state` uses — leaf worktrees / agent rows with role
     Dev/Worker), keep those that are ACTIVE and have NO filed PR (cross-check the
     persisted tracked-PR / branch→PR mapping). Inject the agent-list reader and
     the tracked-PR reader so tests feed fixtures.
2. **Pure guard** (`init_recreate_orphan_guard(candidates, force)`): refuse-or-pass
   per the Clarifications. The refusal message lists agent ids/branches and says:
   "drain these leaves (let them file PRs) or re-run with --force".
3. **Flag**: parse `--force` in the `choir init` arg handling; thread `force : Bool`
   into the recreate flow.
4. **Wire**: in the `--recreate` branch, BEFORE `init_kill_server_pid_*` /
   `init_cleanup_recreate_artifacts`, run detection + guard. Refuse ⇒ emit message,
   return the non-zero exit code, perform NO kill/cleanup. Force ⇒ warn + continue.
   No-candidates ⇒ unchanged flow.

**Seams (read first):** `src/bin/choir/init.mbt` — the recreate launch/kill plan
(`init_server_tab_launch_plan`, `init_kill_server_pid_string`,
`init_cleanup_recreate_artifacts`, arg parsing), and the existing `--purge`/
`--recreate`/`--no-attach` flag handling. `src/runtime/recovery.mbt` —
`recover_state`, `list_agents_in_container`, `persisted_tracked_prs`,
`apply_recovered_agent` (role/state/PR fields) for the detection source.
`src/types/domain.mbt` — `Role`, `AgentState` for the active/leaf predicates.

## Verify
- Unit (guard): candidates empty ⇒ Ok(proceed); candidates non-empty & !force ⇒
  Err naming each leaf; non-empty & force ⇒ Ok (proceed). The message contains the
  agent ids and the drain/--force remedy.
- Unit (detection): injected fixtures — an active leaf with no PR ⇒ candidate; an
  active leaf WITH a filed/tracked PR ⇒ NOT a candidate; a done/failed leaf ⇒ NOT a
  candidate; the root/TL ⇒ never a candidate.
- Unit (flag/wire): `--force` parsed ⇒ force=true threaded; recreate with refuse ⇒
  the kill/cleanup steps are NOT invoked (assert via the injected/mocked effect
  plan, no real process kill).
- Observable (documented manual, self-skip in hermetic): spawn a working leaf, run
  `choir init --recreate` ⇒ non-zero exit naming the leaf and refusing; re-run with
  `--force` ⇒ proceeds with a warning. (Do not kill real processes in hermetic
  tests.)
- `CHOIR_TEST_NO_EXEC=1 moon test --target native`, `moon test --target native`,
  `moon run src/bin/choir_lint --target native`.

## Boundary (do not)
- Do NOT implement credential carry / a credentials-export RPC here (explicitly
  out of scope; follow-up only). Creds still must never hit disk/logs anywhere.
- The guard must run BEFORE any destructive recreate step — a refusal leaves the
  server and leaves entirely untouched (no partial kill/cleanup).
- Detection must NOT add a new server RPC or require the live server; read the same
  persisted state `recover_state` uses, via injected readers.
- Decision logic pure + hermetic; no raw `@sys.*`/`@process.*` in the guard, and
  no test that kills real processes or mutates the real checkout.
- Don't change `server_reload` (#604), `recover_state` restore behavior, or the
  `--purge` semantics (beyond shared `--force` plumbing).
- `--force` preserves today's behavior exactly (proceed), plus a warning — do not
  change the non-orphan recreate path.

## Follow-Ups
- If `--recreate` over live leaves becomes common, revisit the credential carry
  (option (a): root-only export call on the old server pre-kill →
  `CHOIR_RELOAD_CREDENTIALS` env to the new Server tab → restore via the existing
  `parse_reload_credentials_env_string`). Filed-but-not-built here.
- Consider a `choir <drain>` helper that lands/abandons in-flight leaves cleanly,
  so the operator has a one-command remedy the guard can point to.
