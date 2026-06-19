# Spec: completion-handoff-hooks

## Context
Leaf and worker agents must end their task with a **completion handoff**: call
`notify_parent` (with the final report), then `shutdown`. Today that discipline
is delivered as STATIC PROMPT TEXT in the spawn profile (`src/prompts/loader.mbt`
`WORKER_REVIEW_DEFAULT` / `LEAF_PROFILE_DEFAULT` etc.). It is unreliable: the
agent reads it at spawn, runs a long task, and by completion has dropped it from
attention — it prints its report and idles/exits without handing off. Observed
repeatedly this session (codex audit workers stalled with `[WORKER STALLED — no
handoff]`; the report existed but `notify_parent` was never called).

A deep-research pass (deep-research workflow; 23/25 claims confirmed 3-0 against
official provider docs) settled the mechanism:
- **Skills do NOT fix this.** Skills on every provider that has them (Claude
  Agent Skills, Codex Skills, Gemini Agent Skills) are MODEL-INVOKED via
  progressive disclosure — they load only when the model decides the task matches
  the skill description, reproducing the exact "model must remember to trigger
  it" gap. `AGENTS.md` is eagerly concatenated up-front = same failure as static
  text.
- **The reliable lever is each provider's in-runtime completion/stop HOOK** (NOT
  an external supervisor): it fires when the agent tries to finish and can
  block/continue/re-prompt. Codex `Stop` (soft: `decision:"block"` →
  continuation prompt), Claude `SubagentStop` (HARD block via exit-code-2 or
  `decision:"block"`), Gemini `AfterAgent`, Cursor `stop`+`followup_message`.

Outcome we want: leaf/worker agents launched by choir are mechanically
re-prompted at task-end to call `notify_parent` if they haven't, so handoffs stop
silently failing — without an external supervisor calling `notify_parent` on
their behalf.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: Which providers in v1?**
A: **Codex + Claude first.** Codex is the default leaf/worker agent (the one that
actually stalls); Claude is the TL plus some leaves. Together that is ~all real
usage. Gemini (`AfterAgent`) and Cursor (`stop`) are deferred to a follow-up —
their hooks are softer/newer and currently buggier (Gemini AfterAgent
endless-loop #20426; Cursor can't hard-block and runs no hooks in Cloud VMs).

**Q: Skills, hooks, or both?**
A: **Pure completion-hooks.** Skills are model-invoked (per the research) and add
no enforcement; the hook script carries the instruction AND enforces it. No skill
is introduced. Static prompt text remains ONLY as the fallback for hook-less
agent types (moon_pilot).

**Q: How does the hook know the agent already handed off (idempotency)?**
A: Server-authoritative query. The server already records each `notify_parent`
call per agent; the hook asks the server "has `$CHOIR_AGENT_ID` handed off since
spawn?" via a bounded read-only call, rather than trusting a local file that both
the CLI and MCP `notify_parent` paths would have to remember to write. The hook
blocks/re-prompts ONLY when the answer is "no."

## Goals
- For **codex** leaf/worker agents: a `Stop` hook (configured at launch) that, on
  a normally-completed turn, checks the handoff signal and — if the agent has not
  called `notify_parent` since spawn — returns `decision:"block"` with a
  continuation prompt instructing it to call `notify_parent` (final report) then
  `shutdown`. Loop-guarded so it can never wedge.
- For **claude** leaf/worker agents: a `SubagentStop` hook (installed under
  `.choir/hooks`, NOT via the synthesized plugin) that, on the same condition,
  uses the **exit-code-2 script path** to block the stop and feed the
  call-`notify_parent` instruction back. Loop-guarded via `stop_hook_active`.
- A **server-side handoff signal**: the server can answer "did agent X call
  `notify_parent` since its current spawn?" for the hook to query (read-only,
  fast, fail-open).
- **Idempotent + bounded**: the hook fires ONLY when the handoff was actually
  skipped, and is capped so a stuck agent re-prompts a small fixed number of
  times then is allowed to stop (the idle-watchdog remains the ultimate backstop).
- **moon_pilot and any hook-less agent type** keep the existing static prompt
  text — unchanged.
- The hook's decision logic is a pure, unit-testable function
  (`(provider, handed_off: Bool, attempts: Int) -> Decision`); the I/O (server
  query, exit code / JSON emission) lives at the launch/CLI seam.

## Non-Goals
- No skills. Skills do not enforce; this spec deliberately does not add a
  per-provider handoff skill.
- No external supervisor / watchdog that calls `notify_parent` on the agent's
  behalf (explicit operator constraint). The hook only RE-PROMPTS the agent; the
  agent still makes the call. The existing idle-watchdog (reap stalled agent → TL
  notices) stays as-is for the blind spots, but it never synthesizes a handoff.
- Gemini and Cursor hooks (v2 follow-up).
- Changing the `notify_parent` tool/CLI semantics, or the TL's own handoff (the
  TL is the human's session, not a hook-enforced sub-agent).
- Hard-blocking on providers that can't (Cursor); not in v1 anyway.

## Design
### Server handoff signal
- The server already logs `tools/call notify_parent` per agent (serve.log). Add a
  per-agent "handed-off since spawn" bit to the registry/agent state, set when a
  `notify_parent` succeeds for that agent_id, reset at (re)spawn. Expose a
  read-only lookup the hook can reach over the existing client transport (e.g. a
  `handoff-status` leaf-tool subcommand, or fold into an existing read-only
  call). Read-only ⇒ all roles; fast UDS round-trip.

### Hook decision (pure, shared)
- `completion_hook_decision(provider, handed_off, attempts, max_attempts) ->
  Decision` where Decision ∈ { AllowStop, BlockWithInstruction(text) }.
  - `handed_off == true` ⇒ AllowStop.
  - `handed_off == false && attempts < max_attempts` ⇒ BlockWithInstruction (the
    call-`notify_parent`-then-`shutdown` text).
  - `attempts >= max_attempts` ⇒ AllowStop (give up; watchdog backstop).
- Per-provider emission of the Decision:
  - **codex** `Stop`: emit `{"decision":"block","reason":<text>}` (or
    `continue:false` to stop); track attempts via the provider's
    `stop_hook_active`-equivalent / a per-run counter.
  - **claude** `SubagentStop`: on Block, exit code 2 with the instruction on
    stderr (the reliable path; do NOT rely on prompt-feedback JSON, #20221).
    Guard via `stop_hook_active`.

### Wiring
- **codex** (`src/workspace/launch.mbt` codex command / `codex_mcp_override_args`
  area): add the `Stop` hook to the codex hooks config choir writes for the
  spawned agent. The hook invokes a small choir entrypoint (e.g. `choir hook
  completion-handoff --provider codex`) that does the server query + emits the
  decision.
- **claude** (`src/bin/choir/claude_wrapper.mbt` / launch): install a
  `SubagentStop` hook under `.choir/hooks` (NOT the synthesized plugin — plugin
  Stop hooks mishandle exit 2, #10412) pointing at the same `choir hook
  completion-handoff --provider claude` entrypoint.
- The `choir hook completion-handoff` entrypoint is the only new binary surface;
  it reads `$CHOIR_AGENT_ID`, queries the server, applies
  `completion_hook_decision`, and emits the provider-correct output. Fail-open: if
  the server is unreachable or the query errors, AllowStop + log (never wedge the
  agent on infra failure).
- **moon_pilot / hook-less**: no hook; the static handoff prompt text stays.

### Fallback / blind spots
- Codex `Stop` does not fire on Esc-aborted turns (#22858); Claude edge cases
  similar. For any path where the hook never fires, the existing idle-watchdog
  reaps the stalled agent and the TL handles it (current behavior) — acceptable,
  no new mechanism.

## Verify
- Unit (pure): `completion_hook_decision` — handed_off=true ⇒ AllowStop;
  handed_off=false & attempts<cap ⇒ Block with the notify_parent instruction;
  attempts>=cap ⇒ AllowStop. Per-provider emission shape (codex JSON
  `decision:block`; claude exit-2 + stderr text).
- Server signal: a `notify_parent` success sets the agent's handed-off bit;
  absent before, present after; reset on respawn. The read-only handoff-status
  lookup returns the right value.
- Wiring: the codex launch command includes the `Stop` hook config; the claude
  launch installs the `SubagentStop` hook under `.choir/hooks` (assert path is NOT
  the plugin dir).
- Fail-open: server-unreachable ⇒ the hook entrypoint emits AllowStop (never
  blocks) and logs.
- Loop-cap: with handed_off perpetually false, the decision yields AllowStop once
  `attempts>=max_attempts` (no infinite block).
- Observable (documented live check, not hermetic): spawn a codex worker whose
  task tells it to finish WITHOUT calling notify_parent; confirm the Stop hook
  re-prompts and the worker then calls notify_parent (the handoff reaches the
  parent). Self-skip the live exec under `CHOIR_TEST_NO_EXEC`.
- `CHOIR_TEST_NO_EXEC=1 moon test --target native`, `moon test --target native`,
  `moon run src/bin/choir_lint --target native`.

## Boundary (do not)
- The hook only RE-PROMPTS; it must NEVER call `notify_parent` for the agent or
  otherwise synthesize a handoff. No external supervisor.
- Idempotent: block ONLY when the agent has not handed off this spawn (server
  query). Never block an agent that already called `notify_parent`.
- Bounded: every hook is loop-capped (`stop_hook_active` / per-run attempt
  counter / `continue:false`); a stuck agent re-prompts a small fixed number of
  times then is allowed to stop. Never wedge an agent in an infinite continue
  loop.
- Fail-open on infra error: server unreachable / query failure ⇒ AllowStop + log,
  not block.
- Install Claude hooks under `.choir/hooks`, NOT the synthesized plugin (#10412);
  use the exit-code-2 script path, not prompt-feedback JSON (#20221).
- Pin to the deployed CLI's hook surface; if a provider's hook API doesn't match
  what choir writes, fall back to the static prompt for THAT provider rather than
  emit a broken hook config that wedges the agent.
- Decision logic pure/testable; no raw `@sys.*`/`@process.*` in forbidden layers
  (`src/server`, `src/tools`, ...). The hook entrypoint is a CLI/bin seam.
- Do not remove the static handoff prompt text for moon_pilot / hook-less types.

## Follow-Ups
- **Gemini** `AfterAgent` + **Cursor** `stop`+`followup_message` (v2), once the
  Gemini endless-loop bug (#20426) and the Cursor Cloud-VM gap are acceptable /
  mitigated.
- Once codex+claude hooks are proven in practice, drop the now-redundant static
  handoff text from the codex/claude profiles (keep it only for moon_pilot).
- Idle-watchdog tuning for the hook blind spots (codex Esc-abort #22858, Cursor
  cloud VMs) — confirm the reap → TL-handles path is prompt enough.
- Gemini-CLI → Antigravity-CLI migration (flagged ~2026-06-18 for some tiers):
  confirm whether `AfterAgent` survives before wiring Gemini.
- Research sources (for the implementer): code.claude.com/docs/en/hooks,
  developers.openai.com/codex/hooks, geminicli.com/docs/hooks/reference,
  cursor.com/docs/hooks.
