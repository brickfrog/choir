# Goal troubleshooting runbook

Use this runbook when a Choir Goal stops making progress: nothing advances, a
Part is blocked, the Goal is paused, assurance is stuck, or the Conductor has
gone quiet. It is written as an executable contract for a human operator,
Claude, Codex, or a Choir Conductor.

The runbook covers **observation and steering only**. Diagnosis reads durable
state and logs; recovery uses the typed steering surface that `choird` already
exposes. A Conductor or operator following this runbook does not mint receipts,
hand-edit `workflow.db`, fabricate evidence, or drive Parts, Takes, or
integration directly. Those remain `choird` authority.

## Delegation prompts

For a read-only diagnosis:

```text
Follow docs/runbooks/troubleshooting.md in diagnosis mode for the Goal behind
<bead-id or goal-id>. Use only the read-only commands, read the typed reason
fields rather than inferring from receipt counts, and return the required
Goal Triage Report. Do not steer, retry, cancel, answer, restart choird, or
purge anything.
```

For an authorized unblock:

```text
Follow docs/runbooks/troubleshooting.md in recovery mode for the Goal behind
<bead-id or goal-id>. Diagnose first and return the Goal Triage Report, then
apply only the single steering action the report justifies. Do not use
`choir stop --purge`, do not re-run a provider attempt that may already have
had an effect, and stop for my decision if the typed reason is a recovery
uncertainty.
```

## Modes and authority

### Diagnosis mode

Diagnosis mode is the default whenever the request says `why is this stuck`,
`check`, `look at`, or does not explicitly authorize a state change.

- Use only the read-only commands in [Recovery commands](#recovery-commands).
- Read `.choir/state/control/workflow.db` **through** `choir goal status`,
  `choir goal list`, and `choir goal attach`. Never open, copy, edit, or delete
  the database or the artifact store while `choird` is running.
- Read the typed reason fields. A receipt or session count says what did or did
  not happen; it never says why the Goal stopped.
- Record anything you could not observe as `NOT_OBSERVED` with the exact
  reason. Do not guess a cause to complete the report.

### Recovery mode

Recovery mode may apply one steering action after diagnosis.

- Apply the smallest action the typed reason justifies, then re-read status.
- A blocked, canceled, or failed Goal is **not** by itself permission to retry
  or resubmit. Re-running a provider attempt is an explicit operator decision,
  because a Take that already had an effect must not be duplicated.
- Never treat `choir stop --purge` as an unblock step. It discards runtime
  state and owned Goal refs.
- Never repair state by writing to `.choir/state/`. If durable state is
  genuinely undecodable, that is a purge decision for the operator, not a
  troubleshooting step.

## Status vocabulary

Use only these statuses in the report:

- `RUNNING`: the Goal is progressing; no typed reason field is set.
- `WAITING`: the Goal is paused on an operator answer or an explicit pause.
- `BLOCKED`: a typed `PartBlockReason` or `GoalAssuranceBlockReason` is set.
- `UNCERTAIN`: a recovery uncertainty is recorded; an effect may already have
  occurred and no automatic decision is safe.
- `INFRASTRUCTURE`: `choird` is not running, is stale, or the socket is gone;
  durable Goal state is unchanged.
- `NOT_OBSERVED`: a check was intentionally not run; include the exact reason.

## Required Goal Triage Report

Every run must return this structure.

```text
# Goal Triage Report

Mode: diagnosis | recovery
Subject: <bead-id or goal-id>
As of: <timestamp and timezone>
Repository commit: <full commit SHA>
choird: running | not running | stale identity

## Executive result
<one line: what stopped the Goal, from the typed reason field>

## Observed state
| Field | Value | Source |
| state | | goal_status |
| lifecycle | | goal_status |
| pause_reason | | goal_status |
| active_input_request | | goal_status |
| assurance_stage | | goal_status |
| assurance_block_reason | | goal_status |
| blocked Parts (part_id, lifecycle, stage, dispatch_diagnostic) | | goal_status |

## Cause
<the typed variant, mapped through the tables below>

## Action taken or proposed
<exactly one steering action, or "none — operator decision required">

## Not observed
| Check | Reason |
```

A report that explains a stop from receipt counts, log tone, or elapsed time
instead of a typed reason field is incomplete.

## On-disk operational surface

Everything Choir keeps for one project lives under `.choir/` in the project
directory. Read these; do not edit them.

| Path | What it holds | When it is safe to read | When it is safe to remove |
|---|---|---|---|
| `.choir/state/control/workflow.db` | The durable workflow state store: Goal execution records, Part workflow snapshots, assurance records, and the fencing epoch. Configured by `native_goal_repository` in `src/exec/goal_execution_native.mbt` (`project_dir + "/.choir/state/control/workflow.db"`). | Always through `choir goal status`/`list`/`attach`. Direct inspection only with `choird` stopped, and read-only. | Only by `choir stop --purge`, which removes `.choir/state` wholesale (`choir_init_cleanup_purge_artifacts`, `src/sys/stub.c`). Never delete it by hand to unblock a Goal. |
| `.choir/state/control/artifacts` | The artifact store backing the state store: prompts, evidence, findings, and answer artifacts referenced by digest from `workflow.db` (`native_goal_repository`, same function). | Read-only, alongside the database. Artifacts are content-addressed; a missing artifact is corruption, not garbage. | Same as `workflow.db`. Removing artifacts separately from the database produces exactly the corrupt-gate states in the tables below. |
| `.choir/logs/serve.log` | The `choird` server log. `choir serve` and `choir run-goals` install a tracing subscriber that appends here (`src/bin/choir/server_native.mbt:1117` for the goal worker and the equivalent in `serve_run`), and the detached spawn path redirects the daemon's stdout and stderr into the same file at the C level (`src/sys/stub.c:1113`). | Always. This is the first thing to tail. | Only while `choird` is stopped; it is append-only operational history, not state. Truncating it loses evidence and unblocks nothing. |
| `.choir/logs/server-exits.log` | One fixed-format line per fatal serve signal, written from the signal handler because a crash bypasses MoonBit logging entirely (`src/sys/stub.c:233`; handlers installed by `install_crash_handlers`, `src/sys/io.mbt:1082`). The same handler is installed for `SIGTERM` and `SIGINT` (by `choir_register_cleanup_runtime_artifacts`) and for `SIGSEGV`, `SIGABRT`, and `SIGBUS` (by `choir_install_crash_handlers`), so both ordinary termination and a crash leave a line here. | Always. If `serve.log` just stops mid-run, this file says whether the process died. | Only while `choird` is stopped. |
| `.choir/run/server.pid` | The PID of the running server. Written by `choir serve` after it takes the instance lock, read by `choir stop` (`src/bin/choir/main.mbt:52`) and by `choir start` when it decides whether an existing daemon is replaceable (`src/bin/choir/start.mbt:457`). | Always. | Removed automatically: the signal handler and normal cleanup unlink `.choir/run/server.pid`, `.choir/run/server.sock`, and `.choir/run/run_id` (`src/sys/stub.c`). Remove it by hand only when no process owns it — see the stale-daemon procedure below. |

Everything under `.choir/run/` is runtime scaffolding for the current process
generation. Everything under `.choir/state/` is durable and authoritative.

```sh
ls -la .choir/run .choir/logs .choir/state/control
tail -n 200 .choir/logs/serve.log
tail -n 20 .choir/logs/server-exits.log
cat .choir/run/server.pid
```

## State to action

Read the typed reason first. `goal_status` returns a `GoalStatusReport`
(`src/workflow/goal_status.mbt:97`) whose reason fields are the cause; every
count in it is corroboration only.

### Fields to read, in order

| Field | Meaning | How to use it |
|---|---|---|
| `state` | `GoalExecutionState`: `GoalExecutionQueued`, `GoalExecutionRunning`, `GoalExecutionAssuring`, `GoalExecutionAssured`, `GoalExecutionPaused`, `GoalExecutionBlocked`, `GoalExecutionCanceling`, `GoalExecutionSucceeded`, `GoalExecutionCanceled` (`src/workflow/goal_execution.mbt`). | Tells you which of the three reason fields to read next: `Paused` → `pause_reason`; `Blocked` → the Parts table and `assurance_block_reason`. |
| `lifecycle` | `GoalLifecycle` (`src/control/domain.mbt:102`): `GoalActive(GoalActiveCondition)`, `GoalCanceling`, `GoalSucceeded`, `GoalCanceled`. The active condition is one of `GoalRunning`, `GoalNeedsInput`, `GoalDrift`, `GoalAmbiguous`, `GoalIntegrityBlocked`, `GoalRecoveryUncertain`. | Distinguishes "still active but needs attention" from "terminal". A terminal lifecycle is not retryable. |
| `assurance_stage` | `GoalAssuranceStage` (`src/workflow/goal_assurance.mbt:2`): the seal/verify/audit ladder, plus `GoalAssuranceBlocked`, `GoalAssuranceRecoveryUncertain`, `GoalAssuranceCanceled`. | Says how far Goal-level assurance got. `None` means assurance has not started; that is normal while Parts are still running. |
| `assurance_block_reason` | `GoalAssuranceBlockReason?` — set exactly when the stage is `GoalAssuranceBlocked`. | The cause of a Goal-level stop. See the assurance table. |
| `pause_reason` | `GoalPauseReason?` — set exactly when the Goal is paused. | The cause of a pause. See the pause table. |
| `active_input_request` | `GoalInputRequest?` with `id`, `reason`, `created_at_version`. | If present, the Goal is waiting on you, not stuck. Answer it with its `id`. |
| `parts[]` | Per-Part `GoalPartStatus`: `part_id`, `lifecycle` (carries `PartBlocked(PartBlockReason)`), `stage`, and `dispatch_diagnostic`. | The Part-level cause. `dispatch_diagnostic` carries the `TakeUncertaintyReason` (`TakeLeaseLost`, `TakeCursorGap`, `TakeEventConflict`, `TakeEffectUncertain`, `TakeProtocolViolation`) and a detail string. |
| Receipt and session counts | `goal_verification_receipt_count`, `goal_audit_receipt_present`, `publication_receipt_present`, `pull_request_receipt_present`, `assurance_effect_receipt_count`, `assurance_harness_session_count`, `assurance_sandbox_count`, and the per-Part `verification_receipt_count`, `audit_receipt_present`, `integration_receipt_present`, `effect_receipt_count`, `harness_session_count`. | **These describe what did or did not happen. They never say why a Goal stopped.** A zero receipt count is equally consistent with "not reached yet", "blocked before that gate", and "canceled". Quote the typed reason field as the cause and use counts only as supporting evidence. |

### `PartBlockReason` — a Part stopped

`PartBlockReason` (`src/control/domain.mbt:118`) appears inside a Part's
`lifecycle` as `PartBlocked(reason)`.

| Variant | Cause in the current source | Next action |
|---|---|---|
| `PartDependencyBlocked` | Declared in the enum, but no transition in `src/` constructs it today; Part dependency ordering is handled by the scheduler before dispatch rather than by blocking a Part with this reason. | Treat an observed occurrence as unexplained by the current code. Capture the full `goal_status` output and `serve.log`, and do not retry blindly — an unexplained block is an escalation, not an unblock. |
| `PartVerificationFailed` | The verification gate did not authorize the candidate: `authorize_part_verification` blocks the Part whenever the gate observation is anything other than valid (`src/workflow/authority.mbt`). The Part's `verification_receipt_count` may be nonzero — receipts existed, they just did not authorize. | Choir retains the failing evidence and automatically mints a fresh implementation/verification/audit revision. The repair loop is bounded to two revisions; unusable evidence or exhaustion terminally cancels the Goal with `GoalCancellationVerificationRepairFailed` instead of requesting user input. Use `choir goal attach <verification take-id>` only to diagnose the terminal result. |
| `PartAuditFindings` | The audit gate rejected the receipt — `AuditGateRejected(_)` in `record_part_audit_receipt` (`src/workflow/authority.mbt`). Check `audit_total_findings_count` and `audit_blocking_findings_count` on the Part for scale. | Choir retains the findings artifact and automatically mints a fresh repair revision. Bounded exhaustion or unroutable findings terminally cancel the Goal with `GoalCancellationAuditRepairFailed`; the Conductor and user do not authorize the repair. Use `choir goal attach <audit take-id>` only to inspect the terminal evidence. |
| `PartAuditUnavailable` | Declared in the enum, but no transition in `src/` constructs it today. An audit that cannot be observed currently surfaces as an `AuditGateMissing`/`AuditGateCorrupt` observation or as a recovery uncertainty instead. | Same as `PartDependencyBlocked`: capture state and escalate. Do not synthesize an audit receipt, and do not retry to "get an audit" — that is a gate satisfying itself. |
| `PartIntegrationConflict` | Promotion hit a conflicting head: the integration conflict path and the diverged reconciliation outcome both block with this reason (`src/workflow/authority.mbt`). Conflict repair is automatic and bounded — `maximum_part_conflict_repairs()` is 2 (`src/workflow/machine.mbt:295`); after that the Part stays blocked. | Do **not** run `retry`. It is refused by design: `plan_part_retry` returns `integration conflicts retry through conflict repair`, and `transition_part` rejects `RestartBlockedPart` for this reason (`src/control/transition.mbt:107`). Inspect the conflicting paths recorded on the Part, then either land or revert the conflicting change outside the Goal, or cancel the Goal and re-plan the work through the Conductor against the new head. |
| `PartOwnershipViolation` | Declared in the enum, but no transition in `src/` constructs it today. Ownership and mutation-boundary violations are currently rejected earlier, at validation and authorization, rather than parking a Part in this state. | Capture state and escalate. Never "fix" an ownership question by editing the repository on the Part's behalf. |
| `PartIntegrityBlocked` | Integration reconciliation returned `IntegrationReconciliationIntegrityError`; the Part is blocked with this reason and its stage is moved to `PartRecoveryUncertain` (`src/workflow/authority.mbt`). Git-level integrity of the integration target is in question. | Stop automated recovery. Inspect the repository and the Goal/witness refs by hand, read `serve.log` around the integration attempt, and decide as an operator. Do not retry, do not force-update refs, and do not purge to make the symptom disappear. |
| `PartRecoveryUncertain` | A provider dispatch or effect may or may not have happened: process loss and cancellation paths park the Part here (`record_part_provider_process_loss`, `src/workflow/machine.mbt`; `src/workflow/part_cancellation.mbt`). The Part's `dispatch_diagnostic` names the `TakeUncertaintyReason`. | Choir now recovers this without a command: before resuming a Part, the Goal Part adapter discharges an effect that demonstrably left no artifact and re-arms the Part with fresh Take, sandbox, and session identities, bounded by `maximum_part_recovery_retries` (`src/workflow/machine.mbt`). A Take whose effect left an artifact, or whose outcome is unobservable, stays parked on purpose. `choir goal steer <goal-id> retry [bead-id]` runs the same reconciliation on demand and returns `every blocked Part is parked on an effect that may have occurred; retry cannot decide this` (`src/exec/goal_execution_native.mbt`). If it stays parked, this is an explicit operator decision — inspect with `choir goal attach <take-id>` and decide whether the effect happened before doing anything else. |

### `GoalPauseReason` — the Goal is paused

`GoalPauseReason` (`src/workflow/goal_execution.mbt:15`) is set exactly when
`state` is `GoalExecutionPaused`.

| Variant | Cause in the current source | Next action |
|---|---|---|
| `GoalPauseRecoveryUncertain` | Choir paused itself because it could not safely decide how to continue — for example a diverged Goal/witness ref during branch initialization (`GoalBranchInitRefsDiverged`), or an execution-state transition observed under uncertainty (`src/workflow/goal_execution.mbt`). | Do not resume reflexively. Establish what actually happened first: read `serve.log` around the pause, inspect the Goal refs, and read the Parts table for a matching `PartRecoveryUncertain`. `choir goal steer <goal-id> resume` is an operator assertion that continuing is safe. |
| `GoalPauseRequested` | Someone paused the Goal: `GoalPolicyPause`, from `choir goal steer <goal-id> pause` or the equivalent `goal_steer` MCP call. This is not a fault. | `choir goal steer <goal-id> resume` when you want it to continue. Nothing else is required. |
| `GoalPauseAwaitingAnswer(request id)` | The Goal asked a question and parked on it. Only an assured Goal can raise one (`request_goal_execution_input`), and the reasons are `GoalInputPublicationRemoteUnavailable`, `GoalInputFinalizationNeedsUserInput`, `GoalInputFinalizationDrifted`, and `GoalInputFinalizationAmbiguous`. The inner id matches `active_input_request.id`. | Answer it: `choir goal answer <request-id> <answer>`. The answer is bound to that exact request id; an answer for an inactive or already-answered request is rejected (`input request is not active`, `input request answer conflicts`). Do not resume, retry, or cancel to work around an unanswered question. |

### `GoalAssuranceBlockReason` — Goal-level assurance stopped

`GoalAssuranceBlockReason` (`src/workflow/goal_assurance.mbt:23`) is recorded
when `assurance_stage` becomes `GoalAssuranceBlocked`. The deciding gate
observation is retained rather than discarded, so the reason is readable from
durable state instead of inferred.

| Variant | Cause in the current source | Next action |
|---|---|---|
| `GoalAssuranceVerificationBlocked(VerificationGateObservation)` | Combined Goal-level verification did not authorize the sealed Goal branch. The inner `VerificationGateObservation` (`src/control/part_assurance_domain.mbt:463`) is one of: `VerificationGateValid(receipt ids)` (never a block cause), `VerificationGateStale(reason)` — the evidence no longer matches the subject: `VerificationStaleSubject`, `VerificationStaleSpec`, `VerificationStaleEnvironment`, `VerificationStaleRuntime`; `VerificationGateRejected(reason)` — verification ran and said no: `VerificationMissingSlot`, `VerificationMissingReceipt`, `VerificationOutcomeNotPassing`, `VerificationTreeChanged`, `VerificationSessionNotCleanlyClosed`; `VerificationGateCorrupt(reason)` — the evidence itself is inconsistent: `VerificationDuplicateSlot`, `VerificationDuplicateReceipt`, `VerificationEvidenceMissing`, `VerificationReceiptProtocolViolation`. | `Rejected` is repaired automatically and must not be sent to the user for authorization: Choir retains the failing receipt, its command output, the failing spec, and the exact sealed subject, routes the implicated paths to the integrated Parts that own them, and mints one bounded repair revision each. Unrouteable output or an exhausted budget terminally cancels with `GoalCancellationVerificationRepairFailed`. Use `choir goal attach <goal_verification_take_id>` only to diagnose the terminal result. `Stale` and `Corrupt` are **not** repaired: `Stale` means the subject moved under the evidence — re-verify by planning fresh work, never by re-pointing old receipts; `Corrupt` is an evidence-integrity incident: capture `serve.log` and the artifact store state and escalate; do not delete artifacts to clear it. |
| `GoalAssuranceAuditBlocked(AuditGateObservation)` | The Goal-level audit gate did not authorize. The inner `AuditGateObservation` (`src/control/part_assurance_domain.mbt:564`) is one of: `AuditGateMissing` — no audit receipt is present at all; `AuditGateValid(receipt id)` (never a block cause); `AuditGateStale(reason)`: `AuditStaleSubject`, `AuditStalePolicy`, `AuditStaleCapabilityProfile`, `AuditStaleProviderConformance`; `AuditGateRejected(reason)`: `AuditOutcomeNotPassing`, `AuditHasBlockingFindings`, `AuditNotIndependent`, `AuditSessionNotCleanlyClosed`; `AuditGateCorrupt(reason)`: `AuditResultMismatch`, `AuditArtifactMissing`, `AuditReceiptProtocolViolation`. | `AuditHasBlockingFindings` is repaired automatically and must not be sent to the user for authorization: Choir retains the findings artifact, routes the blocking paths to their owning Parts, and mints one bounded repair revision each, terminally cancelling with `GoalCancellationAuditRepairFailed` on exhaustion or unroutable findings. Use `choir goal attach <goal_audit_take_id>` only to diagnose the terminal result. Other `Rejected` reasons are not repaired. `Missing` or `Stale` means the audit that this subject needs has not been produced under the current policy and profile — that is new authorized work, never an operator-supplied receipt. `AuditNotIndependent` and `AuditSessionNotCleanlyClosed` are trust-boundary failures; escalate rather than re-running until they pass. `Corrupt` is an evidence-integrity incident: capture and escalate. |

A Goal-level assurance block that Choir can repair — `VerificationGateRejected`
and `AuditGateRejected(AuditHasBlockingFindings)` — is transient: the runner
routes it into bounded repair on a later tick without any operator command.
Every other assurance block is a terminal answer. In neither case does
`choir goal steer ... retry` help: it acts on blocked **Parts**, does not
re-run Goal assurance, and `retry_native_goal_part` rejects a Goal that is not
in `GoalExecutionBlocked` with `Goal is not blocked`. Never authorize, retry,
or hand back a repairable audit or verification rejection as new Conductor
work; doing so duplicates the repair Choir already owns.

## Recovery commands

These are the commands that exist today, exactly as the CLI parses them
(`src/bin/choir/main.mbt`, `src/bin/choir/goal_cli.mbt`). The `goal`
subcommands require a running `choird`; without one they return
``no `choir serve` is running — start it, then run `choir goal`.`` promptly,
without waiting on the socket. That message means exactly one thing: the socket
was unreachable. Any other transport fault — a rejected registration, a
connection closed mid-stream, an unparseable response — is reported as itself,
so "start the daemon" is never the advice for a daemon that is already up.

The CLI is an operator and debugging fallback. **In a Conductor session the
equivalent typed MCP tools — `goal_list`, `goal_status`, `goal_steer`,
`goal_cancel`, `goal_attach`, `goal_answer` — are the normal path**, and Goal
operation is meant to stay conversational.

| Command | Effect | Mutates durable state? |
|---|---|---|
| `choir goal list` | Lists registered Goals. | No — read-only. |
| `choir goal status <goal-id\|--part bead-id>` | Returns the `GoalStatusReport`. `--part <bead-id>` selects the Goal by the user-facing Bead, because internal Goal ids are never shown to the user. | No — read-only. |
| `choir goal attach <take-id>` | Returns the Take, its origin (Part or assurance), and its harness sessions and events. The response is tagged `observational`. | No — read-only. |
| `choir goal steer <goal-id\|--part bead-id> pause` | Applies `GoalPolicyPause`; sets `pause_reason` to `GoalPauseRequested`. | **Yes.** |
| `choir goal steer <goal-id\|--part bead-id> resume` | Applies `GoalPolicyResume`. | **Yes.** |
| `choir goal steer <goal-id\|--part bead-id> concurrency N` | Applies `GoalPolicySetMaximumParallelParts(N)`; `N` must be a positive integer. | **Yes.** |
| `choir goal steer <goal-id\|--part bead-id> retry [bead-id]` | Re-arms one blocked Part with fresh Take/sandbox/session identities under the same task contract and returns the Goal to Running. The trailing Bead id is optional when exactly one Part is blocked; with several blocked Parts it is required (`several Parts are blocked; name the part_id to retry`). Refused for `PartIntegrationConflict`. | **Yes — and it re-dispatches a provider attempt. Explicit operator decision.** |
| `choir goal cancel <goal-id\|--part bead-id>` | Persists a cancellation request; the Goal moves toward `GoalExecutionCanceling`/`GoalExecutionCanceled`. Terminal and irreversible for that Goal. | **Yes.** |
| `choir goal answer <request-id> <answer>` | Binds one answer to the active input request id; remaining arguments are joined into the answer text. Replaying the identical answer is idempotent; a different answer for the same request is rejected. | **Yes.** |
| `choir serve` | Runs the orchestration server in the foreground: takes the instance lock, writes `.choir/run/server.pid`, installs crash handlers, mints the fencing epoch, and starts logging to `.choir/logs/serve.log`. | Runtime state only; durable Goal state is preserved and adopted. |
| `choir stop` | Reads `.choir/run/server.pid`, signals the server process tree, and removes runtime artifacts (`.choir/run/server.pid`, `.choir/run/server.sock`, `.choir/run/run_id`, and the Codex conductor runtime dir). Durable Goal state is preserved for restart. | Runtime state only. |
| `choir stop --purge` | Everything `choir stop` does, then `purge_native_goal_resources`: removes every recorded Goal runtime root, deletes the exact owned local Goal/witness Git refs, releases Bead claims, and finally removes `.choir/state` and `.choir/run`. It does not delete user branches, remote branches, PRs, or source Beads. If external cleanup fails it keeps the database and exits nonzero so the purge can be retried. | **Yes — it discards durable Goal state and owned Goal refs. This is not a routine unblock step.** Use it only when durable state is genuinely unusable and you have accepted losing in-flight Goals. |

Read-only triage, in order:

```sh
choir goal list
choir goal status --part <bead-id>
choir goal attach <take-id>
tail -n 200 .choir/logs/serve.log
```

## Common failure modes

### A. `choird` is not running, or is stale after a rebuild

**Symptom.** Every `choir goal` command returns
``no `choir serve` is running — start it, then run `choir goal`.``, or commands
succeed but behave like an older build. A different transport message means the
daemon is reachable and something else failed — do not restart it on that
evidence.

`choir stop` is honest about what it found: it reports `No choird was running
here` and exits 0 when there is no pid file, exits 1 when the pid file does not
name a daemon process, and exits 1 when the daemon is still alive after the
best-effort stop sequence. Only a verified termination prints `Choir stopped.`

**Look at first.**

```sh
cat .choir/run/server.pid
ps -p "$(cat .choir/run/server.pid 2>/dev/null || echo 0)" -o pid,lstart,cmd
ls -la .choir/run
tail -n 50 .choir/logs/serve.log
tail -n 20 .choir/logs/server-exits.log
```

- A missing `.choir/run/server.pid` with no listening socket: `choird` is not
  running. Start it (`choir serve`, or `choir start` if you also want a
  Conductor session).
- A `server.pid` naming a dead PID: the daemon died without running its
  cleanup. `.choir/logs/server-exits.log` will usually carry the fatal signal
  line, since that file is written from the signal handler precisely for exits
  that bypass MoonBit logging.
- A live daemon after a rebuild: `choir start` compares the running daemon's
  reported **build identity** (a content digest of the executable, not its
  path) with its own. Identical identity is left alone; a differing identity is
  replaced only when `.choir/run/server.pid` corroborates the socket peer;
  otherwise `choir start` refuses with `existing choird identity could not be
  verified` (`src/bin/choir/start.mbt`). Running `choir start` with the new
  binary is therefore the supported way to roll a stale daemon.

**Do not.** Do not delete `.choir/run/server.sock` or `.choir/run/server.pid`
while a process still holds them — the replacement daemon does its own runtime
cleanup under the instance lock, so a client that unlinks a live socket only
breaks the working case. Do not purge. Durable Goal state is untouched by any
of this: a Goal that was running before the daemon died is still recorded in
`workflow.db` and is adopted by the next generation under a fresh fencing
epoch.

### B. The Goal is waiting on an operator answer, not stuck

**Symptom.** Nothing progresses, but `state` is `GoalExecutionPaused` and
`serve.log` is quiet rather than erroring.

**Look at first.** `pause_reason` and `active_input_request` in
`choir goal status`. If `pause_reason` is `GoalPauseAwaitingAnswer(<request
id>)` there is a matching `active_input_request` whose `reason` is one of
`GoalInputPublicationRemoteUnavailable`, `GoalInputFinalizationNeedsUserInput`,
`GoalInputFinalizationDrifted`, or `GoalInputFinalizationAmbiguous`. The Goal
is assured and is asking a finalization or publication question.

```sh
choir goal status --part <bead-id>
choir goal answer <request-id> <answer text>
```

**Do not.** Do not `resume` a Goal that is awaiting an answer — the pause is
bound to the request id and the answer is what discharges it. Do not invent an
answer to unblock the Goal; the request exists because Choir will not decide
this itself. Do not cancel a Goal merely because it asked a question. Do not
answer a request id that is not the active one; it will be rejected.

### C. A terminal failed or recovery-uncertain Take

**Symptom.** A Part shows `PartBlocked(...)` or the stage
`PartRecoveryUncertain`, with a `dispatch_diagnostic` naming a
`TakeUncertaintyReason` (`TakeLeaseLost`, `TakeCursorGap`, `TakeEventConflict`,
`TakeEffectUncertain`, `TakeProtocolViolation`) and a detail string.

**Look at first.** The observational read is:

```sh
choir goal status --part <bead-id>
choir goal attach <take-id>
```

`choir goal attach` returns that Take, whether it came from a Part or from Goal
assurance, and its harness sessions and events — enough to see what the
provider actually did before it stopped. It changes nothing.

Then decide, in this order:

1. Did the Take leave an artifact? A Take that died leaving no candidate, no
   verification receipt, and no audit receipt did not occur; `retry`
   reconciles exactly those and makes the Part retryable.
2. If retry answers `every blocked Part is parked on an effect that may have
   occurred; retry cannot decide this`, the effect may already have happened,
   or the Part cannot observe its own outcome (integration and promotion). Stop
   and treat it as an operator decision.

**Do not.** A failed or uncertain Take is not permission to retry. Re-running a
provider attempt is an explicit operator decision, and duplicating an effect
that already landed is worse than a parked Part. Do not attach and then
"finish the work by hand" — an operator completing a Part outside `choird`
produces exactly the unaudited, unreceipted integration the workflow exists to
prevent. Do not clear a `PartIntegrityBlocked` Part with retry or purge.

### D. The Conductor session is parked by the Stop hook

**Symptom.** The Conductor stopped responding after a turn and appears idle,
while `choir goal status` shows the Goal still advancing.

**What is happening.** While a durable Choir Goal is running, a deterministic
Stop hook parks the provider session instead of letting the built-in `/goal`
loop start another turn (`conductor_stop_run`, `src/bin/choir/client.mbt`).
`choird` keeps executing and sends each material durable Goal projection
through an MCP Channel; that event wakes the session for the next useful turn.
Progress is event-driven rather than a loop of `goal_status` polling.

**Look at first.**

```sh
choir goal status --part <bead-id>
tail -n 100 .choir/logs/serve.log
```

If `state` is `GoalExecutionRunning` and `durable_version` is still
increasing, nothing is wrong: durable work is unchanged and the session will be
woken. A parked Conductor session is a UI state, not a Goal state.

**Do not.** Do not restart `choird`, cancel the Goal, or purge to "wake up" the
Conductor — none of those are session controls, and cancel and purge destroy
real work. Do not resubmit the same Beads because the chat looks idle; a quiet
Conductor is not evidence that the Goal stopped. If you genuinely need a new
session, start one; the Goal is durable and independent of it.

## Escalation boundary

Stop and hand back to a human operator, with the Goal Triage Report and no
further action, whenever:

- the typed reason is `PartIntegrityBlocked`, or any `Corrupt` gate observation;
- a Part stays parked after reconciliation because its effect may have occurred;
- an observed `PartBlockReason` is one the current source does not construct
  (`PartDependencyBlocked`, `PartAuditUnavailable`, `PartOwnershipViolation`);
- `.choir/state/control/workflow.db` cannot be opened or decoded; or
- the only remaining option under discussion is `choir stop --purge`.

In every one of those cases the correct next step is evidence and a decision,
not another attempt.
