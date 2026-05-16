# Spec: long-tool-call-handling

## Context

The cbm auto-audit shipped in PR #346 runs server-side for ~5-10 minutes per
file_pr→main call (Sarcasmotron review worker against `git diff main...HEAD`).
Codex's MCP client treats a 120s tool-call pause as a timeout and the leaf
reports `[FAILED]` to the TL — even though the server is still progressing
correctly and will eventually return the actual response (PR URL on success,
findings on audit failure).

Observed live 2026-05-16 on PR #347 (choir-wgc fix): 4 separate auto-audit
runs (488s + 474s + 418s + 654s = ~35 min server-side), 3 of which the leaf
prematurely reported as `[FAILED]` at the 120s mark; the TL had to fish the
actual error/findings out of `.choir/serve.log` and relay via `send_message`.
After the relay, the leaf successfully waited out the subsequent calls
without bailing — proof that the prompt-side fix works once the leaf is
told.

Observable target: a Dev leaf's file_pr→main call that triggers an auto-audit
sees a normal 5-10 min wait, never misreports `[FAILED]` at 120s, eventually
receives the actual response (PR URL or audit findings), and acts on it. A
TL or user watching `.choir/serve.log` sees periodic `audit-on-file-pr pr=N
elapsed=Ns` heartbeats so "is it still working?" has a verifiable answer.

## Clarifications
> Q&A from the crystallize step. Durable; leaves read this.

**Q: What should a leaf do when file_pr appears to time out at ~120s?**
A: Wait silently for the actual response. Prompt rule: *"file_pr against main
triggers a server-side audit that takes ~5-10 minutes. A 120s pause is normal
and expected — the MCP call IS still pending, the server is working. Do NOT
report `[FAILED]` until either the call returns OR ~15 minutes have passed
AND `.choir/serve.log` shows no active `audit-on-file-pr-*` worker (i.e. the
worker has shut down cleanly without the file_pr call returning — a genuinely
stuck state)."* Pure markdown change to `.choir/prompts/profiles/leaf.md`;
matches what proved to work in the PR #347 live retry.

**Q: How should the server signal progress while file_pr blocks?**
A: Periodic delivery-log heartbeats only. The auto-audit's spawn-and-wait
path writes a heartbeat line to `.choir/serve.log` + `.choir/delivery.log`
every ~60s (`audit-on-file-pr pr=N agent=<leaf_id> elapsed=Ns status=running`)
while the worker is alive; a final line on worker complete (`elapsed=Ns
status=ok|error findings_count=N`). The leaf doesn't get a pane event (the
MCP tool call is still synchronous from its perspective), but a TL / user
watching the log sees clear "still working" signal. Smallest server change;
no MCP protocol shifts. Pairs with the prompt rule above (leaf checks log
if in doubt).

## Goals

### Leaf prompt rewrite

- `.choir/prompts/profiles/leaf.md`: add (or extend) a section explaining
  the file_pr→main long-call behavior. Concrete text (paraphrase; keep the
  spirit, not the exact words):

  > **file_pr against main blocks for ~5-10 min on the server-side audit.**
  > When you call `file_pr` with `parent_branch: main`, the choir server
  > runs a Sarcasmotron audit worker against your diff before completing
  > the PR creation. That worker typically runs 5-10 minutes. The MCP tool
  > call stays pending the whole time. **A 120s pause is normal, expected,
  > and does not mean the call failed.** Do NOT report `[FAILED]` at 120s;
  > the server is still working. Wait for the actual response: either the
  > call returns with the PR URL (success) or with `audit found N findings:
  > ...` (audit blocking; address the findings, push, retry).
  >
  > Only treat file_pr as actually failed when BOTH (1) ~15 minutes have
  > passed since the call started AND (2) `tail .choir/serve.log | grep
  > "audit-on-file-pr.*<your branch>"` shows the audit worker has shut
  > down without your file_pr returning. In that genuinely-stuck case,
  > report `[BLOCKED]` to your parent with the elapsed time and the last
  > log line.

- `src/prompts/loader.mbt` loads this; no loader logic change required. Add
  a `loader_test.mbt` grep-style assertion that the new key phrases are
  present ("A 120s pause is normal", "Do NOT report [FAILED] at 120s",
  "audit-on-file-pr").

### Server-side heartbeats

- Wherever `file_pr_require_audit_receipt` spawns the audit worker (see
  `src/tools/file_pr.mbt:~1565` and the audit-spawn/await loop): add a
  periodic heartbeat that runs concurrently with the worker-await. Every
  60 seconds while the worker is alive (use the existing `@async.sleep`
  seam):
  1. Compute elapsed seconds since spawn.
  2. Emit `@moontrace.info("audit-on-file-pr", fields=[field("pr",
     pr_number), field("agent", tracked_agent_id), field("elapsed_s",
     elapsed), field("status", "running")])`.
  3. Append a one-line entry to `.choir/delivery.log` with the same data
     (matches the existing poller-delivery-line shape so `choir logs`
     interleaves it).

- On worker complete (notify_parent received OR shutdown), emit one final
  line: `audit-on-file-pr pr=N agent=... elapsed=Ns status=ok findings_count=N`
  or `status=error reason=...`.

- Heartbeat cadence: 60s default (configurable via a config knob like
  `audit_heartbeat_sec`; 0 disables). The heartbeat task must NOT block the
  worker-await — implement as a parallel task that loops until a "worker
  done" signal flips.

- Outer budget unchanged (15 min by spec; still terminates the audit with
  the existing structured error).

- Factor the heartbeat-line construction as a pure function for testing
  (e.g. `pub fn audit_heartbeat_log_line(pr_number, agent_id, elapsed_s,
  status~, findings_count?) -> String`).

### End-to-end

- A Dev leaf calls `file_pr(parent=main)`. The MCP call blocks (codex
  observes a long pause; the prompt tells it this is normal). Every 60s a
  heartbeat line appears in `.choir/serve.log` + `.choir/delivery.log`.
  After 5-10 min the file_pr call returns:
  - Success: PR URL, leaf proceeds to review cycle as today.
  - Audit found findings: leaf addresses them, pushes, retries file_pr —
    which runs ANOTHER audit (separate cost concern tracked in `choir-3bj`).
- A TL / user watching `.choir/serve.log` sees the heartbeats and knows the
  audit is progressing. The "[FAILED] at 120s" misreport stops happening.

## Non-Goals

- Async file_pr returning an `audit_pending` token (option (b) in
  `choir-mje`). The right end-state, but bigger protocol change; deferred
  to a follow-up bead.
- A pane-side `[AUDIT IN PROGRESS]` event sent into the leaf's pane. The
  leaf's MCP call is synchronous from codex's perspective — events would
  interleave with the pending response. Heartbeats land in the log only.
- Raising codex's per-tool MCP client timeout. Choir doesn't control codex's
  config; the prompt rule is the workaround on the agent side.
- Streaming audit findings as they appear. The audit returns one final
  report; we don't change that.
- Heartbeats on other long tool calls (notify_parent, send_message, etc.) —
  scope is the file_pr→main auto-audit specifically.
- Reducing audit duration (that's `choir-3bj`'s delta-audit optimization).

## Design

### `.choir/prompts/profiles/leaf.md` (markdown only)

Insert a new H3 section after the existing "Do not exit voluntarily after
file_pr" / post-fix-push terminal handoff area. Wording per Goals above.

`src/prompts/loader.mbt` loads it; no logic change. Update `loader_test.mbt`
to assert the new key phrases are present via grep-style content check
(matching the pattern of prior post-fix-push handoff test).

### `src/tools/file_pr.mbt` — heartbeats around the audit-spawn

Locate the audit spawn-and-await site (`interpret_spawn_worker` invocation
at `~L1565` and the wait for the worker's `notify_parent` report). Wrap the
wait with a parallel heartbeat task:

```moonbit
let started_at = @env.now().reinterpret_as_int64() / 1000L
let mut audit_done = false
let heartbeat_task = async fn() {
  while !audit_done {
    @async.sleep(audit_heartbeat_sec * 1000)
    if audit_done { break }
    let elapsed = @env.now().reinterpret_as_int64() / 1000L - started_at
    @moontrace.info(
      "audit-on-file-pr",
      fields=[
        @moontrace.field("pr", pr_number),
        @moontrace.field("agent", tracked_agent_id),
        @moontrace.field("elapsed_s", elapsed),
        @moontrace.field("status", "running"),
      ],
    )
    append_delivery_log_line(
      audit_heartbeat_log_line(pr_number, tracked_agent_id, elapsed)
    )
  }
}
// run heartbeat_task + await worker; on worker done, flip audit_done = true.
// emit one final "elapsed_s=N status=ok|error" line.
```

Factor the heartbeat-line formatter as a pure function:
```
pub fn audit_heartbeat_log_line(pr_number : Int, agent_id : String,
  elapsed_s : Int64, status~ : String = "running",
  findings_count? : Int? = None) -> String { ... }
```

### Config knob

Add `audit_heartbeat_sec : Int` to the config struct (alongside
`worker_no_handoff_prod_sec` / etc.) with default `60`; `0` disables.

### Tests

- `audit_heartbeat_log_line` truth-table: known pr/agent/elapsed/status →
  expected formatted string (running, ok, error).
- Loader test: leaf.md contains the new key phrases.
- Heartbeat-loop wiring test: mock the audit-spawn-await with a synthetic
  worker that takes 180s; assert ≥2 heartbeat log lines appear (at ~60s
  and ~120s). Hermetic — mock `@async.sleep` + the timer seam + the worker
  await; no real sleeping.
- No-heartbeat case: `audit_heartbeat_sec=0` disables heartbeats; assert
  zero heartbeat lines in the same 180s scenario.
- Final-line: on worker complete, the final line has `status=ok` (or
  `status=error reason=...`) and the actual elapsed time, regardless of
  heartbeat cadence.

## Verify

- `moon test --target native`: all tests pass; new tests cover the four
  cases above.
- Observable: on the next Dev leaf's file_pr→main, `tail -f .choir/serve.log
  | grep audit-on-file-pr` shows heartbeats at ~60s intervals; the final
  line on worker complete shows the actual elapsed time. The leaf does not
  report `[FAILED]` at 120s.
- `grep "A 120s pause is normal" .choir/prompts/profiles/leaf.md` ⇒ matches.
- `grep -c "audit-on-file-pr" .choir/prompts/profiles/leaf.md` ⇒ ≥1.

## Boundary (do not)

- Heartbeats apply ONLY to the audit-on-file-pr spawn-and-await path. Do
  not add heartbeats to other long-running calls in this PR (notify_parent,
  send_message, merge_pr, etc.).
- The heartbeat task must NOT block the worker-await — concurrent task,
  flips a `done` flag when the await completes.
- `audit_heartbeat_sec == 0` must fully disable heartbeats (no log lines).
- No new MCP tool surface, no new poller event types, no pane-side
  `[AUDIT IN PROGRESS]` events.
- No `@sys.*`/`@process.*` direct calls in `src/server`/`src/tools` beyond
  the existing adapter seams (`@async.sleep` + the existing delivery-log
  append helper).
- Use the existing config struct shape (alongside `worker_no_handoff_*`);
  `ChoirError` for new error paths (there shouldn't be any; heartbeat
  failure is silently ignored).
- All tests hermetic — mock the async/sleep/worker-await seams.
- Prompt rewrite must not regress the existing "Do not exit voluntarily
  after file_pr" / post-fix-push handoff guidance.

## Follow-Ups

- Async file_pr with `audit_pending` token + poller event (option (b) in
  `choir-mje`). The proper end-state. File as a separate bead in this PR
  if not already filed (the wording in `choir-mje`'s update covered it as
  a future fix shape; a dedicated bead would track the implementation).
- `choir-3bj` (delta-audit on retry) — reduces per-audit cost, which
  composes with these heartbeats.
- `choir-cfw` (completion-chime / notify-send hook) — orthogonal UX layer.
- A future `audit-in-progress` HookEvent (via the shell-hook substrate)
  would let users wire a custom notification on heartbeat events too —
  follow-up if `choir-cfw` ships and users want progress visibility, not
  just completion.
