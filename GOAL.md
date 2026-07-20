# Choir v2 Goal

Status: draft target-product and architecture charter

Implementation status: Choir v1 remains the current user-facing product. A
substantial Choir v2 foundation is now implemented on this branch, but the v2
product is not yet usable end to end.

Decision state: the strategic direction—local durable authority,
provider-native Conductor sessions, isolated part execution, passive VSDD gates,
and no Zellij lifecycle dependency—is accepted. The items in the current
implementation snapshot below have direct implementation and test evidence.
Every other v2 contract, command, adapter, state shape, delivery claim, and
provider-support claim remains provisional until implemented and proven by its
stated conformance oracle.

Research snapshot: 2026-07-19T19:50:26Z
Context-only amendments through: 2026-07-19T20:50:17Z

## Charter Semantics and Readiness

This file specifies target behavior. It is not evidence that the current
MoonBit types, state stores, provider adapters, or commands already implement
that behavior. The green v1 test suite remains valuable regression evidence
for v1; it is not v2 acceptance evidence.

The words **must**, **must not**, and **required** are normative. A section
explicitly marked as an experiment or implementation gate may change after its
probe. A provider or runtime is not supported merely because its documentation
describes a capability or because one local invocation succeeded.

In conceptual schemas, `reason`/`status` placeholders mean closed versioned
enums or `ChoirError` suberrors defined by the durable schema; they never
authorize an open `String` domain.

## Current Implementation Snapshot

This snapshot describes the branch as of 2026-07-19 local time. It separates
working implementation from target behavior; passing fixtures do not make an
unconnected product path usable.

### Implemented and directly exercised

- Fixed-domain Goal, Part, Take, harness-session, event, assurance, receipt,
  integration, and cancellation types plus pure transition functions.
- Durable restart-readable state and content-addressed artifact stores with
  transactional fault injection.
- A hermetic conformance runner with injected clock, identifiers, adapters,
  and typed fault points. Its command currently proves the runner dependency
  contract; it does not yet implement the complete required case matrix.
- Claude and Codex CLI surface probes. The exact Claude subscription CLI
  profile passed its startup/tool-surface probe. The pinned Codex profile is
  honestly `BlockedByConformance` because native host-tool removal and required
  sandbox-tool failure behavior have not been proven.
- A pinned BoxLite v0.9.7 lifecycle/security adapter using the checked-in
  seccomp correction. Live KVM boot, clone isolation, bounded transfer,
  attach/signal/kill, restart re-adoption, read-only enforcement, and declared
  network-denial probes passed on the recorded host.
- A restart-safe native Part workflow. It creates an isolated BoxLite sandbox,
  launches the official Claude subscription CLI with only the generated
  sandbox MCP tools, executes an implementation Take, normalizes a candidate,
  runs typed verification, launches a separate Claude audit Take, and promotes
  the accepted candidate through the native Git integration adapter.
- A concurrent Goal runner with conflict-aware admission and deterministic,
  serialized promotion. A native Git fixture proves that divergent candidates
  based on the same head are composed into a continuous promotion history and
  final combined tree.
- The repository linter admits only the narrow injected exec-adapter tests and
  explicitly tagged real-process fixtures used by this implementation.

Evidence anchors are commits `5fb93fe8` for the native Part path,
`2a184a59` for concurrent Parts and serialized promotion, and `0443cc3c` for
the final linter correction. At that head, `moon test --target native` reports
2,383 passed and zero failed, and `moon run --target native
src/bin/choir_lint` exits successfully.

### Fixture-scoped behavior

- The native Part fixture supplies a checked-in task instruction. No Conductor
  currently interprets a user Goal or creates the Part/task contract.
- The native Part path uses Claude for implementation, verification, and audit.
  There is no Codex execution driver.
- The concurrent native Git fixture creates candidate commits directly through
  fixture code. It tests scheduling and promotion, not concurrent provider task
  execution.
- The native Part and concurrent Goal paths are executable conformance fixtures;
  they are not wired into `choird`, `/goal`, or another user-facing command.

### Not yet connected

- The Conductor bridge for proposing, accepting, inspecting, steering,
  answering, canceling, attaching to, and reconnecting to Goals.
- Provider-neutral dispatch from accepted Parts to Claude or Codex workers,
  including a supported Codex driver and mixed-provider execution.
- Goal-level verification, combined-tree audit, branch publication, canonical
  final-PR reconciliation, readiness sealing, and terminal completion.
- The full event replay, cancellation ordering, conflict repair, ownership,
  hostile-surface, publication, PR, generated-DAG, and scale conformance cases.
- Replacement and deletion of the remaining v1/Zellij correctness paths.

The central user flow therefore remains unfinished: a Claude or Codex
Conductor cannot yet turn a user Goal into durable Parts and have Choir dispatch
those Parts across provider workers. The implemented foundation begins below
that seam.

Implementation began with two bounded experiments authorized by this charter:

- Provider subscription-auth, entitlement, event, and host-tool-isolation
  conformance.
- BoxLite lifecycle, host-boundary, and network conformance.

Both now have executable probes and recorded results in the implementation
snapshot and research amendments. Those results admit the exact Claude driver
candidate and corrected BoxLite runtime pin; they do not admit Codex execution
or complete the user-facing product.

The scheduler and promotion slice began only after its durable schema and
transition specification instantiated the required entities, uniqueness
constraints, linearization points, and fault oracles. Expansion beyond the
implemented slice may refine field layout; it may not silently choose different
semantics.

## Context

Choir v1 was built around interactive coding harnesses. Provider subscriptions
were increasingly restricted to providers' official clients, and there was no
common supported interface for starting and coordinating several authenticated
harness sessions. Choir used Zellij as the common denominator: launch the
clients, keep them alive, display them, and pass messages between panes.

That workaround made terminal state part of the protocol. Provider launch,
message delivery, lifecycle, observation, recovery, and workflow state became
entangled with Zellij and with overlapping in-memory and on-disk stores.

The harness landscape has changed:

- Claude Code has structured headless execution, subagents, experimental Agent
  Teams, MCP, hooks, and restrictive tool controls.
- Codex has structured non-interactive execution, subagents, MCP, SDKs, and
  app-server.
- Google's consumer harness direction has moved toward Antigravity.
- KVM-backed runtimes such as BoxLite can provide isolated, persistent,
  reconnectable execution without making a terminal multiplexer the process
  manager.

Choir v2 is for this world. It is a local developer tool, not a hosted
meta-agent service. It should use supported surfaces of the user's installed
harnesses where policy and conformance permit, while keeping durable workflow
authority outside every provider session.

## Product Goal

From any supported Conductor on the developer's machine, a user can state a
high-level Goal over an existing repository and let Choir carry its Parts to a
verified result.

The representative interaction is:

```text
/goal <selection>; max concurrency 4; stop on ambiguity
```

The Conductor proposes the exact work and task contracts. Choir validates the
proposal, records the immutable accepted set and every rejection, schedules
dependency-ready waves, runs implementation and audit takes in isolated
environments, enforces typed verification and passive receipt gates, serializes
audited candidates into one goal branch, recovers after process loss, and lets
the user inspect, steer, cancel, or reconnect.

Every successfully promoted part has an independent audit receipt bound to its
exact candidate, contract, verification evidence, and audit policy. After all
Parts are promoted, the exact combined tree is independently audited. Choir
then reconciles one canonical final PR from the sealed goal branch to the
declared target branch. Merging that PR is a separate policy and authority.

Claude and Codex may differ internally, but they must present the same external
goal, take, evidence, cancellation, and recovery semantics.

## Product Position

Choir is the local, single-user way to develop competently with a swarm.
Locality, single-user authority, and subscription-backed execution through the
user's official installed harnesses are product invariants. If a provider does
not permit or cannot safely expose that path, Choir reports the provider as
unsupported. It does not substitute separately metered model access.

Priority order:

1. Correct, reviewable, independently verified code.
2. Host, repository, credential, and subscription-entitlement safety.
3. Low supervision and honest recovery.
4. Parallelism within dependency, ownership, machine, and provider limits.
5. Efficient use of context and paid harness capacity.

Separately metered model access is out of scope. Choir never changes the
requested subscription identity, routes subscription credentials through an
unsupported surface, or silently enters another billing lane.

## Definitions

A Conductor interprets and steers a Goal. Choir schedules its Parts. A Part
may require several Takes, and each Take may use one or more provider sessions
or native subagents. The Conductor exercises judgment and steering; `choird`
remains the sole workflow authority.

- **Conductor:** the interactive model session through which the user
  understands, starts, and steers a Goal. It proposes intent and policy but
  cannot mint leases, receipts, integration, or completion state.
- **Goal contract:** the immutable selected part set, dependency snapshot,
  repository base, integration target, and completion policy.
- **Goal policy revision:** a versioned change to scheduling, retry, priority,
  assurance, or resource policy. Evidence-affecting changes invalidate evidence
  through exact digests; they do not rewrite old receipts.
- **Part:** one durable unit of intended work within a Goal, normally backed by
  a bead and its captured dependency edges. A Part remains the same durable
  unit across all of its numbered Takes.
- **Take:** one leased execution with a typed purpose, sandbox generation,
  zero or more numbered harness sessions, durable events, artifacts, and a
  terminal disposition. Implementation/audit takes require a harness;
  process-only verification takes need not.
- Verification and audit Takes are auxiliary workflow work, not additional
  Parts. Conflict repair is a new implementation Take for the same Part under
  a new task-contract revision.
- **Native subagent or teammate:** a provider-owned reasoning context within a
  Take. Its task state is disposable and subordinate to the Part and Take.
- **Candidate commit:** the immutable, normalized, single-parent output of one
  implementation take. Verification and part audit bind to it.
- **Promotion commit:** a deterministic Choir-generated merge that composes one
  candidate with the current serialized goal head.
- **Receipt:** immutable durable evidence recorded by `choird` after it
  validates the producing take, subject, policy, capabilities, and artifact
  digests.
- **Gate:** a pure decision over durable state. It emits no worker, provider,
  sidecar, process, Git, forge, or sandbox effect.
- **Reviewable PR:** a final PR whose exact combined diff, contracts,
  verification evidence, audit evidence, and integration lineage are available
  for human inspection. It does not imply a generic `ReviewReceipt`.

## Resolved Direction

1. Choir is local-first, single-user, and subscription-backed through official
   installed harnesses. It is not a hosted credential/model gateway and has no
   usage-billed model fallback.
2. `choird` is the sole durable, provider-neutral workflow authority.
   Provider tasks, transcripts, panes, and native mailboxes are observations.
3. A small lazy-started daemon remains, reached through a local Unix socket.
   Narrow loopback or Unix-socket sidecars are implementation details.
4. Zellij leaves the correctness and transport path. It may remain as an
   optional observer.
5. Native provider delegation is an optimization within one take, never the
   top-level scheduler.
6. The initial host is Linux with KVM and MoonBit's native target.
7. BoxLite is the first empirical sandbox candidate behind a replaceable typed
   port. It is not accepted for production until the sandbox conformance gate
   passes at an exact version and source identity.
8. MoonBit owns policy, state transitions, scheduling, and typed contracts.
   Narrow provider or runtime sidecars may own transient SDK sessions but never
   workflow authority.
9. Claude and Codex are the minimum target providers. Antigravity is deferred
   until the two-provider contract stabilizes.
10. Private prompts, patched provider binaries, and extracted consumer
    credentials are not installation or correctness dependencies. They are
    `UnsupportedExperiment` surfaces at most.
11. The preferred credential topology keeps the authenticated harness on the
    trusted host and exposes only sandbox capabilities. This topology is an
    admission hypothesis for each exact provider surface, not an assumed fact.
12. Baseline VSDD uses typed verification, one independent part audit before
    each promotion, and one independent combined-tree audit before PR
    readiness. Stricter policy may add gates; it may not remove that baseline.
13. The MVP promotion strategy is
    `NoFastForwardThreeWayV1`, serialized by a fenced goal integration lease.
14. There is no baseline `ReviewReceipt`. Human or forge approvals belong to
    an explicit later merge policy.
15. V2 is a hard semantic cut delivered by complete seams. No `src/v2/`,
    dual reads/writes, migration façade, or compatibility state survives the
    seam that replaces it.

## Architectural Invariants

### Judgment is not authority

The Conductor interprets intent, resolves ambiguity, proposes decomposition and
policy, and explains progress. The control plane transactionally decides what
is selected, leased, running, verified, audited, promoted, canceled, and
complete.

Provider-native completion is an observation. It cannot mint a Choir receipt,
advance a gate, or complete a Part.

### Gates never satisfy themselves

The workflow scheduler may create a capable verification or audit take
before a gate. The gate itself only evaluates already-durable state. A missing
producer yields a typed blocked state; it never causes the gate to spawn a
worker, run a sidecar, execute a script, or fabricate evidence.

### External effects are reconciled, not called atomic

State transactions cannot atomically commit Git refs, provider sessions,
sandbox processes, remote branches, or forge PRs. Every non-idempotent or
externally durable action therefore has:

- a persisted intent and deterministic identity;
- an explicit authorization point ordered against cancellation;
- an adapter effect with a narrow typed capability;
- a durable external witness where the external system supports one;
- a receipt or typed uncertain state produced by reconciliation;
- named crashes before and after every ambiguous boundary.

Exactly-once claims apply to Choir's durable projection and uniqueness
constraints, not to transports or remote services.

### Orchestration emits typed effects

Code in orchestration layers does not call host I/O directly. Git, forge,
filesystem, process, sandbox, clock, randomness, provider, and network
operations go through typed effects in `src/exec/` or injected adapters.
Fixed domains use enums. New error paths use `ChoirError`.

### Observation is disposable

A TUI, Zellij pane, log viewer, or terminal attachment consumes durable events.
Removing every observer must not alter execution, cancellation, recovery, gate
evaluation, or completion.

### Security is fail-closed

Unknown capabilities, ambient configuration, an unavailable sandbox tool,
unreportable effective tools, cursor gaps, policy uncertainty, and credential
or subscription-entitlement mismatches are failures or typed blocked states. They are never
interpreted as permission to use a broader surface.

## Architecture

```text
┌──────────────────────────────────────────────────────────────────┐
│ Interactive Conductor                                                │
│ Claude Code / Codex / later Antigravity                          │
│ Understand intent, propose contracts, steer, explain             │
└──────────────────────────────┬───────────────────────────────────┘
                               │ supported local plugin/MCP surface
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│ choird — local durable control plane                              │
│ Goal and revision state       Dependency/claim scheduler          │
│ Takes and fenced leases    Verification and audit receipts     │
│ Event journal and cursors     Promotion/PR intents and receipts   │
│ Cancellation/reconciliation   Completion outbox                   │
└──────────────┬───────────────────────────┬───────────────────────┘
               │ typed harness effects     │ typed sandbox effects
               ▼                           ▼
┌─────────────────────────────┐  ┌─────────────────────────────────┐
│ Credential-bearing driver   │  │ Sandbox runtime owner           │
│ Pinned provider surface     │  │ Prepared immutable environment  │
│ Exact effective manifest    │  │ One mutable generation/take  │
│ Sandbox capabilities only   │  │ No provider credential by       │
│ Typed normalized events     │  │ default                         │
└─────────────────────────────┘  └─────────────────────────────────┘
               │
               ▼ typed Git/forge effects only from choird
┌──────────────────────────────────────────────────────────────────┐
│ Trusted integration and forge adapters                            │
│ Isolated Git workspace, atomic ref+witness update, remote reconcile│
└──────────────────────────────────────────────────────────────────┘
```

### Conductor bridge

Each supported interactive harness gets a thin goal-facing integration:

- start from a bead query, explicit IDs, or crystallized spec;
- inspect selection, revisions, takes, evidence, blocked states, and PR;
- answer clarification requests;
- steer allowed policy fields;
- cancel a goal;
- attach to durable events.

A Conductor may disappear without ending a goal. Another supported Conductor can
reconnect without reconstructing state from transcripts.

### `choird`

`choird` is the target form of `choir serve`: a lazy-started, single-user
daemon on a Unix socket. It owns:

- one transactional authority for goals, revisions, Parts, takes,
  leases, intents, receipts, cancellation, and completion;
- dependency and mutation-claim scheduling;
- provider, sandbox, CPU, memory, and session admission;
- provider and runtime capability registries pinned to conformance reports;
- durable normalized events and observer cursors;
- task-contract, verification, audit, promotion, publication, and PR
  transitions;
- recovery of every unresolved authorized external effect.

SQLite is the default state-backend candidate. The invariant is the
transactional model and uniqueness constraints, not a particular database.

### Minimum durable model

The schema specification must include at least:

| Entity | Required identity or invariant |
|---|---|
| `Goal`, `GoalContract`, `GoalPolicyRevision`, `GoalTerminalDecision` | Immutable selected set/base/dependencies/target; versioned policy; one terminal compare-and-set |
| `SelectionDecision` | Exact proposal, accepted IDs, rejected IDs, typed reasons, source revisions |
| `GoalPart`, `TaskContractRevision` | Selected identity, dependency snapshot, typed verification and mutation declaration |
| `Take`, `TakeLease` | Typed purpose, fencing epoch, terminal disposition; lease expiry is never success |
| `SandboxLease`, `HarnessSession`, `HarnessCommandIntent` | Exact generation/session/turn, capability profile, recovery class |
| `ExternalEffectIntent`, `ExternalEffectReceipt` | Common authorization, one-use dispatch, witness, uncertain, and cancellation envelope for local adapter effects |
| `HarnessEventEnvelope` | Durable source identity, per-session Choir sequence, redaction decision |
| `Artifact` | Immutable content digest, provenance, retention policy |
| `ProcessExecution` | Take-bound authority, validated process spec, sandbox generation, terminal disposition, output artifacts |
| `CandidateCommit` | Single parent, base/head/tree/change identities |
| `VerificationReceipt`, `VerificationAuthorizationSlot` | Exact subject/spec execution plus one stable authorizing receipt per required slot |
| `AuditResult`, `AuditReceipt` | Fenced terminal auditor handoff followed by the validated immutable receipt |
| `GoalBranchInitIntent`, `GoalBranchInitReceipt` | Canonical Choir-owned local ref anchored at the captured base |
| `GoalPromotionOrder`, `GoalBranchSealIntent`, `GoalBranchSeal` | Deterministic total promotion rank and witnessed immutable final head |
| `GoalIntegrationLease` | One fenced promotion owner and no second unresolved intent |
| `IntegrationIntent`, `PromotionCommit`, `IntegrationConflict`, `IntegrationReceipt` | Deterministic candidate-to-promotion protocol and Git witness |
| `BranchPublicationIntent`, `BranchPublicationReceipt` | Reconciled remote head publication at the sealed audited SHA |
| `PullRequestIntent`, `PullRequestReceipt`, `PullRequestReadinessSnapshot` | One canonical final PR effect plus a separate point-in-time readiness decision |
| `CancellationRequest` | Durable cutoff ordered against new admission and effect authorization |
| `CompletionEvent` | Transactional outbox row with a unique semantic event key |

`ReviewReceipt` is deliberately absent. A future merge policy that needs
human or GitHub approval must model the exact remote review observation and
its invalidation semantics, not resurrect a generic souvenir entity.

## Selection, Revisions, and Scheduling Inputs

### Deterministic selection

The Conductor submits a typed `GoalProposal` containing explicit candidate IDs,
task contracts, selection policy, integration target, base ref and expected
base SHA, dependency policy, assurance policy, and resource caps.

`choird` resolves that proposal against one captured bead/repository snapshot
and persists one `SelectionDecision` before any take is dispatched:

- canonical proposed IDs in deterministic order;
- exact accepted IDs;
- every rejected ID and one or more typed reasons;
- captured part revisions and dependency edges;
- repository/base/target identities;
- selection-policy version and proposal digest.

Initial rejection reasons are a closed enum including `NotFound`,
`Duplicate`, `NotOpen`, `AlreadyOwned`, `MissingOpenDependency`,
`DependencyCycle`, `Ambiguous`, `InvalidTaskContract`,
`InvalidMutationDeclaration`, and `PolicyExcluded`.

The control plane does not infer missing semantic work from prose. The Conductor
must propose the complete open dependency closure. Under the default
`ExactClosure` policy, an accepted item whose open dependency is absent
rejects the proposal before dispatch. A later closure-expansion policy, if
added, must return the expanded set for user acceptance before it becomes a
goal.

The accepted part set, captured dependency graph, repository base, and
integration target never change in place. A materially different selection is
a new goal.

### Versioned steering

Priority, concurrency, pause, and bounded retry settings may create a new
`GoalPolicyRevision` without changing the selected set. A task-contract
change creates a new `TaskContractRevision`; takes retain the revision
they started with.

Assurance-affecting changes—verification specs, mutation declarations, audit
policy, capability requirements, base tree, or evidence requirements—cannot
retroactively bless existing output. Their new digest makes the old candidate
or receipt stale for gate purposes and requires a new eligible take.

If a revision supersedes an active take, policy must explicitly terminate
it or allow it to finish for diagnostics. Its output cannot authorize the
superseding revision.

## Verification and Independent Audit

### Baseline VSDD chain

For this charter, baseline VSDD is:

1. Choir accepts and versions an immutable task contract before implementation.
2. An implementation take produces one immutable candidate commit and tree.
3. The scheduler creates a part-verification take whose typed verification
   specs run against that exact candidate and record receipts plus an evidence
   manifest.
4. The scheduler explicitly creates a separate part-audit take against that
   candidate, contract revision, and verification evidence.
5. A passive audit gate accepts only a valid independent audit receipt for the
   exact current subject.
6. Only then may the candidate enter promotion.
7. After all Parts are promoted, the scheduler creates a goal-verification
   take against the sealed exact head.
8. Once goal verification passes, it creates a separate combined-tree audit
   bound to those receipts and the integration set.
9. A valid combined-tree audit is required before branch publication and the
   final PR.

An external human or forge review may gate merge under a later policy. It is
not a baseline receipt and does not gate creation of the reviewable PR.

### Take purpose

Every take has exactly one fixed-domain purpose:

```text
TakePurpose
  Implementation(part_id, task_contract_revision_id)
  PartVerification(part_id, candidate_take_id,
                   verification_subject_digest)
  PartAudit(part_id, candidate_take_id, audit_subject_digest)
  GoalVerification(goal_id, goal_head_oid, verification_subject_digest)
  GoalAudit(goal_id, audit_subject_digest)
```

Implementation takes belong to selected Parts. Verification and audit
takes are auxiliary workflow work: they do not enter the selected set or
create dependency edges, but they consume applicable sandbox, process,
provider, CPU, memory, and live-session admission.

The scheduler coordinates the producer. The auditor emits a findings artifact
and terminal audit outcome. Only `choird`, in a transaction after validating
the take, subject, independence, capability profile, and artifact digests,
records the receipt. The auditor, Conductor, implementation take, and gate
cannot mint it directly.

Baseline part and goal audit profiles admit exactly one harness session and
disable native delegation plus additional session requests. This deliberately
narrow rule makes every contributor to the audit judgment structurally
identifiable. A future multi-auditor policy must introduce and bind a canonical
contributor set before it can be admitted; it cannot overload this receipt.

Baseline audit independence requires:

- audit take ID differs from the candidate implementation take;
- no audit harness session contributed to the candidate;
- the audit sandbox generation differs from the implementation generation;
- the audit opens the immutable candidate, never the mutable implementation
  filesystem;
- the auditor receives a versioned audit capability profile with the candidate
  tree mounted read-only and only a separate writable scratch/artifact output
  area; it cannot replace the candidate, request promotion, or write an
  integration intent.

Baseline policy may use the same provider or model family in a distinct
eligible session. A versioned policy may require provider, model-family, or
capability-profile diversity. A surface unable to report a required identity
cannot satisfy that policy; it does not invent one.

Infrastructure failure or interruption may admit a new audit take under the
bounded retry policy. Blocking findings require repair and a new candidate.
Exhausted retries or no eligible auditor creates a typed blocked outcome.

### Verification receipts

Every verification take has one canonical subject:

```text
VerificationSubject
  LeafCandidate {
    part_id
    candidate_take_id
    candidate_commit_oid
    candidate_tree_oid
    task_contract_revision_id
    task_contract_digest
  }
  GoalTree {
    goal_id
    goal_branch_seal_id
    goal_branch_seal_digest
    goal_head_oid
    goal_tree_oid
    goal_contract_digest
    assurance_policy_revision
    integration_receipt_set_digest
  }

VerificationReceipt {
  receipt_id
  verification_take_id
  verification_execution_id
  verification_subject
  verification_subject_digest
  verification_spec_id
  verification_spec_version
  verification_spec_digest
  validated_process_spec_digest
  prepared_environment_and_image_digest
  sandbox_runtime_and_policy_digest
  subject_pre_tree_oid
  subject_post_tree_oid
  evidence_artifact_id
  evidence_artifact_digest
  started_at
  finished_at
  outcome
}

VerificationAuthorizationSlot {
  verification_subject_digest
  verification_spec_id
  verification_spec_version
  verification_spec_digest
  lowest_admitted_execution_ordinal
  authorizing_receipt_id?
}

VerificationOutcome
  Passed
  Failed
  Errored
  Interrupted
```

`verification_execution_id` is unique and idempotent. A subject's immutable
verification plan creates exactly one uniquely constrained authorization slot
per required `(subject_digest, spec_id, spec_version, spec_digest)`. The
scheduler admits at most one execution ordinal for a slot at a time and does
not admit a retry while the preceding execution is merely unknown. The first
valid `Passed` receipt in ordinal order compare-and-sets the empty slot; later
diagnostic repeats never replace it or stale an audit.

A verification gate requires every slot to reference a valid `Passed` receipt
under the exact current subject, process, environment, runtime, and evidence
identities, with both recorded subject trees equal to the subject tree; its
producing take/process executions must remain valid and any
contributing session must be cleanly closed without protocol violation.
Failed, errored, interrupted, missing, corrupt, or stale receipts
do not fill a slot. The canonical authorizing set sorts slots by canonical
spec key and encodes each full selected receipt; its digest and the evidence
manifest digest become part of the corresponding part or goal audit subject.

### Canonical audit subjects

```text
AuditSubject
  LeafCandidate {
    part_id
    candidate_take_id
    candidate_commit_oid
    candidate_tree_oid
    task_contract_revision_id
    task_contract_digest
    verification_receipt_set_digest
    verification_evidence_manifest_digest
  }
  GoalCandidate {
    goal_id
    goal_branch_seal_id
    goal_branch_seal_digest
    goal_head_oid
    goal_tree_oid
    goal_contract_digest
    assurance_policy_revision
    integration_receipt_set_digest
    goal_verification_receipt_set_digest
    goal_verification_evidence_manifest_digest
  }
```

`audit_subject_digest` is the digest of the canonical encoding of the
complete typed subject. A branch name or part ID alone is never an audit
identity.

### Audit result and receipt

Before a receipt can exist, the one admitted audit session submits a typed
terminal result through its fenced session capability. `choird` validates and
stores the following durable handoff in the same transaction that moves the
take from `Running` to `ResultRecorded`:

```text
AuditResult {
  audit_result_id
  audit_take_id
  take_fencing_epoch
  audit_harness_session_id
  audit_subject
  audit_subject_digest
  auditor_capability_profile_digest
  effective_surface_manifest_digest
  provider_conformance_report_digest
  audit_policy_digest
  findings_artifact_id?
  findings_artifact_digest?
  total_findings_count
  blocking_findings_count
  started_at
  finished_at
  outcome
  result_digest
}
```

The transaction requires the exact active take/session/subject fence,
terminal structured output, all referenced artifacts already staged under
their digests, `Passed` to have zero findings, and `Findings` to carry its
findings artifact. One take has one result under a unique constraint. A
conflicting replay is `ProviderProtocolViolation`, not a replacement.
Provider `Completed` alone is never an `AuditResult`.

Receipt reconciliation reads only this durable result plus referenced durable
state. It may create the receipt in the same transaction or after a crash; it
never reconstructs an outcome from an artifact or transcript.

```text
AuditReceipt {
  receipt_id
  audit_result_id
  audit_result_digest
  audit_subject
  audit_subject_digest
  audit_take_id
  audit_harness_session_id
  audit_sandbox_generation_id

  auditor_capability_profile_id
  auditor_capability_profile_version
  auditor_capability_profile_digest
  provider_surface_id
  provider_identity
  model_identity_or_unreported
  provider_conformance_report_id
  provider_conformance_report_digest

  audit_policy_id
  audit_policy_version
  audit_policy_digest

  findings_artifact_id?
  findings_artifact_digest?
  total_findings_count
  blocking_findings_count
  started_at
  finished_at
  outcome
}

AuditOutcome
  Passed
  Findings
  Failed
  Interrupted
```

One audit take has at most one terminal receipt;
`audit_take_id` is the idempotency and uniqueness key. Replaying the same
terminal result is a no-op. A different outcome, subject, policy, or findings
digest under the same take ID is a protocol violation.

An audit gate authorizes only when:

- outcome is `Passed` and no blocking finding exists;
- the complete receipt subject equals the current gate subject;
- candidate commit/tree, contract revision/digest, verification receipt set,
  evidence manifest, audit policy, and capability requirement still match;
- referenced findings and evidence artifacts exist under their digests;
- the recorded take/session/sandbox relationship satisfies independence;
- the `AuditResult`, take, and cleanly closed session remain exact and have
  no protocol-violation disposition;
- the provider surface had a passing conformance report for the required audit
  profile at admission.

Receipts are immutable. Gate evaluation derives `Missing`, `Valid`,
`Stale(reason)`, `Rejected(reason)`, or `Corrupt(reason)`. It never edits
a receipt to make it current. A completed audit with `Findings` is durable
evidence but is not authorizing.

## Durable Harness Event Protocol

Provider delivery into `choird` is at-least-once where a surface exposes a
stable event identity or resumable cursor. Journal delivery to observers is
also at-least-once. Choir promises an idempotent, exactly-once durable
projection—not exactly-once transport.

```text
HarnessEventEnvelope {
  event_id
  take_id
  session_id
  source_position
  choir_sequence
  observed_at
  kind
  sanitized_payload
  payload_digest
  redaction_state
  late
}

EventSourcePosition
  ProviderEventId(provider_event_id)
  ProviderCursorTransition(cursor_before, cursor_after)
  NonResumableConnectionOrdinal(connection_id, ordinal)

EventRedactionState
  NotSensitive
  Redacted
  Withheld
```

`payload_digest` is the domain-separated SHA-256 of the schema-versioned,
deterministic CBOR encoding of `(kind, redaction_state, sanitized_payload)`.
It is the digest of the complete safe semantic event, despite the historical
field name. It never
hashes raw provider bytes, pre-redaction text, headers, credentials, or the
inherited environment. `Withheld` encodes only a typed redaction-reason enum
and an allowed artifact reference, if one exists; it contains no hash derived
from withheld secret material. Duplicate/conflict comparison is therefore over
the safe normalized event, not over unretained provider content.

`choir_sequence` is assigned transactionally, strictly increases without
gaps within one harness session, and is the only observer cursor. An observer
asks for events after `(session_id, last_choir_sequence)`; Choir never
silently skips to the newest event.

The opaque provider cursor is adapter-private, scoped to the exact provider
session and adapter version, and persisted only when documented as resumable
and noncredential. A surface without a stable cursor declares
`NotResumable`. Loss of that process retries or blocks the take; it does
not pretend to resume.

Candidate normalization, verification receipt creation, and `AuditResult`
creation require every required session for that take to be
`IngestionClosedCleanly`: a contiguous terminal observation, transport EOF or
provider-defined final cursor, balanced tool activity, and a stopped process
tree. Choir never races an apparently terminal event against a still-open
event stream. A finalized session cannot be resumed or contribute more
authorizing observations.

For resumable sources, one transaction:

1. validates the source event ID or cursor transition;
2. treats the same identity and payload digest as a duplicate no-op;
3. treats the same identity with another digest as
   `ProviderProtocolViolation`;
4. appends the normalized envelope;
5. advances the provider cursor;
6. applies the session projection.

The adapter acknowledges or reads past a source event only after that
transaction commits when the provider protocol permits acknowledgment. A
bounded stream applies backpressure before dropping data. An expired cursor,
lost unacknowledged range, or spool overflow is a typed `CursorGap` or
`EventIngestionOverflow`; the take becomes recovery-uncertain and cannot
complete.

`Completed`, `Failed`, and `Interrupted` are terminal observations about
a harness session, not take outcomes or receipts. The first contiguous
terminal observation fixes the session observation. An identical replay
deduplicates; a conflicting later terminal is retained as a protocol
violation. Events after authoritative interruption, termination, or terminal
observation are marked late and cannot reopen state or authorize success. A
transport failure is `DriverStreamError`, not a provider `Failed` event.

Any `ProviderProtocolViolation` atomically marks the session
`ProtocolViolated` and its take `RecoveryUncertain`, stops new tool/effect
authorization for that take, and makes every later candidate, verification
result, or audit result from it ineligible. The original event remains
immutable and the conflicting observation is retained as a redacted diagnostic
record. Policy may schedule a fresh take with a fresh sandbox and session;
the violated take itself can never become successful.
If an adapter nevertheless discovers a conflicting source observation after
an authorizing artifact was recorded, that artifact derives `Corrupt` and the
goal becomes `IntegrityBlocked`; an already applied Git effect is preserved
and reported, but the goal cannot seal or succeed.

Raw provider payloads are not retained in the MVP. Normalized payloads use a
field allowlist. Tool events persist capability/execution IDs, status, timing,
and artifact references—not raw arguments, environment, stdout, stderr,
headers, or provider payloads by default. Persistence fails closed when no
redaction decision exists. Provider credentials, bearer headers, auth-file
contents, and inherited process environments are never event payloads.

Normalized envelopes and their per-session sequence index are retained for the
entire lifetime of the local goal record in the MVP; there is no event-pruning
or compaction operation. Explicit deletion of a goal deletes its event history
as one user-authorized operation, after which observation returns
`GoalNotFound`, never a silently advanced cursor. A future pruning feature must
add a typed observer-cursor-expiry/snapshot protocol before changing this
rule. Provider-side `CursorGap` remains a distinct ingestion failure.

The minimum normalized live-trace predicate is:

```text
Started
zero or more nonterminal events with balanced ToolStarted/ToolFinished pairs
exactly one first terminal session observation
no source or Choir cursor regression
```

Recorded provider fixtures may require an exact trace. Live model prose is not
expected to be byte-deterministic.

## Harness Driver and Provider Surfaces

### Driver contract

```text
HarnessDriver
  probe(profile) -> Result[HarnessConformanceReport, ChoirError]
  start(start_capability, session_id, take, declared_surface,
        sandbox_capability, supervisor_key, initial_command_artifact_digest?)
    -> Result[HarnessSession, ChoirError]
  send(command_capability, session, command_id, command_artifact_digest)
    -> Result[HarnessCommandObservation, ChoirError]
  ingest(session, provider_cursor?) -> Stream[ProviderObservation]
  interrupt(stop_capability, session) -> Result[Unit, ChoirError]
  resume?(recovery_capability, session, provider_cursor, effective_surface)
    -> Result[HarnessSession, ChoirError]
  terminate(stop_capability, session) -> Result[Unit, ChoirError]
```

### Session and command effects

Provider launch and outbound turns are external effects. They use the common
effect envelope plus typed payload records:

```text
ExternalEffectIntent {
  effect_id
  kind
  goal_id
  take_id?
  take_lease_epoch?
  request_digest
  idempotency_key
  witness_class
  state
}

ExternalEffectKind
  SandboxPrepare | SandboxCreateOrClone | HarnessStart | HarnessCommand
  ProcessStart | ProcessSignalOrStop | HarnessStop
  SandboxCopyIn | SandboxCopyOut | SandboxSnapshot | SandboxDestroy

ExternalEffectState
  Planned | Authorized | MayHaveOccurred | Receipted
  IntegrityBlocked | Uncertain | AbandonedByCancellation

ExternalWitnessClass
  ContentAddressedResource | RuntimeResourceKey | SupervisorProcessKey
  ProviderEventCorrelation | DesiredAbsentState | None

ExternalEffectReceipt {
  effect_id
  idempotency_key
  observed_resource_identity?
  observed_request_digest
  observed_outcome
  observed_at
}

HarnessSessionStartIntent {
  effect_id
  session_id
  take_id
  provider_surface_and_profile_digest
  declared_surface_digest
  initial_command_artifact_digest?
  supervisor_key
}

HarnessCommandIntent {
  effect_id
  session_id
  command_id
  command_sequence
  required_provider_cursor?
  command_artifact_digest
  provider_idempotency_token?
}
```

The control plane persists `Planned`, then authorizes only under
`GoalLifecycle::Active(Running)` and the exact active take lease, surface,
sandbox capability, and cancellation cutoff. It
compare-and-sets to `MayHaveOccurred` before calling the adapter and passes a
one-use capability bound to the request digest. No adapter method accepts an
unregistered launch, command, process, or runtime resource ID.

Every harness runs in a dedicated supervisor process group/cgroup named by the
Choir `session_id`; its stdout/event spool and any provider resume handle bind
the same identity. Recovery first queries that witness. It re-adopts only an
exact process/surface/session match. Otherwise it kills the entire supervised
group, marks the effect/take `Uncertain`, and may retry only as a fresh
take—never by launching the same authorized session again.

Commands are monotonically sequenced per session. A provider-documented
idempotency token or correlated durable provider event may prove delivery.
Without such a witness, a timeout/crash after `MayHaveOccurred` is uncertain
and the command is never resent automatically. For a one-shot headless client,
an initial task command is permitted only when its pinned conformance report
proves a pre-turn initialization barrier: the complete effective-surface
manifest is delivered and can abort the process before the task can cause any
model-directed local tool, hook, child, or other effect. Otherwise start has no
task input, surface attestation must pass, and the task is a separately
authorized `send`; a one-shot surface without either capability is
unsupported. An initial command follows the same no-resend rule. An
acknowledged command receipt means only that the exact turn was accepted, not
that its output is correct or that the take completed.

Stop/destroy effects reconcile toward a desired absent/dead state and may be
retried idempotently. Cancellation may abandon `Planned`; after authorization
it settles or kills only the exact named resource and records `Receipted` or
`Uncertain` before the goal becomes canceled.

Stable cases cover crashes before authorization, after `MayHaveOccurred`,
after local process creation before receipt, after command write before
acknowledgment, after acknowledgment before receipt, and during stop. Each
asserts no orphan outside the named supervisor, no automatic command resend,
and no take success from an uncertain effect.

A Take begins with one primary session. Any additional same-provider or
cross-provider session is a typed request to the control plane. The scheduler
admits it, gives it a numbered durable identity, pins its profile and sandbox
capability, and owns cancellation. A model cannot create an untracked harness
by shelling out to another CLI.

Capabilities are live-probed claims. Choir does not assume peer messaging,
nested delegation, resume, approvals, background work, or tool isolation have
the same semantics across providers.

### Maturity, policy, and support domains

```text
ProviderMaturity
  Stable | Beta | Preview | Experimental | UnderDevelopment
  Deprecated | Removed | Unspecified

ChoirSupport
  Unprobed | Candidate | Supported | BlockedByPolicy
  BlockedByConformance | Unsupported | UnsupportedExperiment

PolicyStatus
  Allowed | RequiresConfirmation | Disallowed

ProbeStatus
  NotRun | Passed | Failed | Blocked

HarnessAuthenticationProfile
  ProviderManagedSubscription

RedactedAuthenticationClass
  ProviderManagedSubscription | NoLogin | ConflictingCredential | Unknown

EntitlementLane
  SubscriptionIncluded | ConflictingLane | Unknown
```

`ProviderMaturity` is the provider's label; absent labeling is
`Unspecified`, never `Stable`. `ChoirSupport` applies to one exact
surface, version, auth profile, and capability profile—not to a provider.
`Supported` requires passing subscription-auth, entitlement/quota, event,
exact effective-surface, sandbox-isolation, interruption, cancellation, and
recovery probes.

### Surface/authentication matrix

Every row is one total typed tuple at the current charter revision. `Version`
is exact when locally pinned; a future version is a different support key.
Rows changed by a post-snapshot probe are called out in the research
amendments rather than backdated into the original context record.

| Exact surface | Version | Choir role | Required subscription identity | Capability profile | Maturity | Policy | Choir support | Probe |
|---|---:|---|---|---|---|---|---|---|
| Claude Code interactive CLI | `2.1.215` | Conductor | Official client using the user's provider-managed subscription | `ConductorHostObserver` | `Unspecified` | `RequiresConfirmation` | `Candidate` | `NotRun` |
| `claude -p --safe-mode --tools "" --strict-mcp-config --mcp-config <generated-choir-config> --output-format=stream-json --verbose` | `2.1.215` | Rejected Claude driver profile | Same confirmed provider-managed subscription | `SafeModeSandboxToolsOnly` | `Unspecified` | `RequiresConfirmation` | `BlockedByConformance` | `Failed` |
| `claude -p --setting-sources "" --tools "" --permission-mode dontAsk --allowedTools <generated-exact-choir-tool-list> --strict-mcp-config --mcp-config <generated-choir-config> --output-format=stream-json --verbose` | `2.1.215` | Claude driver candidate | Same confirmed provider-managed subscription; every other effective credential class fails | `SterileHostSandboxToolsOnly` | `Unspecified` | `RequiresConfirmation` | `Candidate` | `Passed` |
| Claude Agent Teams within the pinned Claude CLI | `2.1.215` | Optional optimizer within one Conductor/take; never a driver or scheduler | Inherits the admitted owning Claude subscription session | `ChildEqualOrNarrower` | `Experimental` | `RequiresConfirmation` | `Candidate` | `NotRun` |
| Codex interactive CLI | `0.144.6` | Conductor | Official client using the user's ChatGPT-managed Codex subscription | `ConductorHostObserver` | `Unspecified` | `Allowed` | `Candidate` | `NotRun` |
| `codex exec --json` | `0.144.6` | Codex driver candidate | Saved ChatGPT-managed subscription login; every other effective credential class fails | `HostHarnessSandboxToolsOnly` | `Unspecified` | `Allowed` | `BlockedByConformance` | `Failed` |
| Antigravity interactive CLI | `1.0.10` | Future Conductor candidate | Official client using the user's provider-managed consumer subscription | `ConductorHostObserver` | `Unspecified` | `RequiresConfirmation` | `Candidate` | `NotRun` |
| Antigravity `agy -p` text mode | `1.0.10` | Driver surface | Same provider-managed subscription | `HostHarnessSandboxToolsOnly` | `Unspecified` | `RequiresConfirmation` | `Unsupported` | `Failed` |

Anthropic's current policy makes the official subscription CLI the only Claude
execution candidate in scope. A developer surface that requires separately
metered credentials is excluded rather than used as a fallback.

Current OpenAI documentation says `codex exec` reuses saved local CLI
authentication. Choir admits it only when the live redacted status proves the
requested ChatGPT-managed subscription identity. A wrapper is not presumed to
preserve that identity without a probe.

The executable probe against pinned Codex `0.144.6` confirmed its structured
noninteractive, JSON event, ephemeral-session, configuration-suppression, and
restrictive-sandbox command surfaces. It did not prove complete removal of
native host tools or fail-closed behavior when the required Choir sandbox tool
is unavailable. The exact pairing therefore returns a typed
`BlockedByConformance` result and is not an execution driver.

No adapter may run a surface/auth pair absent from this matrix or promote
`Candidate` to `Supported` without a pinned passing report. A mismatch is a
typed capability error, never an automatic fallback.

## Credential-Bearing Host Driver

The authenticated host harness is privileged code at the trust boundary; it is
not part of the sandbox. Model output, repository text, `AGENTS.md`,
`CLAUDE.md`, rules, skills, plugins, MCP metadata/results, hooks, resumed
transcripts, native children, and provider-generated commands are adversarial
inputs to that process.

Before the first task turn, the adapter derives an `EffectiveSurface`
manifest from protocol initialization plus trusted adapter introspection and
compares it exactly with the declared profile. It records:

- executable, version, launcher and runtime payload hashes, and maturity stage;
- redacted subscription-auth class and expected entitlement/quota lane, never
  secret values;
- model identity or `Unreported`, permission mode, logical cwd, workspace
  roots, and additional roots;
- every visible built-in tool;
- every MCP server, connection status, and exposed tool;
- every plugin, skill, command, hook, monitor, LSP, custom agent, native
  delegation facility, rule, and instruction source;
- environment-variable names, never values;
- the provider-owned credential/config root and the exact provider runtime
  state subpaths allowed to change during startup/session execution;
- exact Choir sandbox capability and security-policy identity.

Unknown, unenumerable, disconnected, or extra entries are terminal startup
failures. The preferred profile exposes no native host shell, file read, file
write, edit, patch, process, browser, forge, or network tool. Its only
model-directed mutation and execution tools are the declared Choir sandbox
capabilities.

Failure or disappearance of the required sandbox tool is terminal. There is no
fallback to provider-native `Bash`, `Read`, `Write`, `Edit`,
`apply_patch`, web access, process execution, another MCP server, or a child
CLI.

Provider-specific suppression flags are necessary but not sufficient. At the
pinned Claude version, a hermetic probe proved that `--safe-mode` also removes
an explicitly supplied MCP server; that profile is rejected rather than called
secure. Removing safe mode while retaining an empty built-in tool set, empty
declared setting sources, strict generated MCP configuration, and the one
Choir sandbox server did expose the supplied server, so that narrower profile
remains a candidate. Its generated permission grant enumerates concrete
`mcp__<server>__<tool>` names only; no ambient wildcard is allowed, and the
permission mode plus allowlist are part of the capability-profile digest and
initialization oracle. Empty declared settings sources alone are not proof
because managed and global inputs may still apply. The admitted profile must
choose one explicit subscription-safe root topology:

- use the existing provider-owned root, suppress declared setting sources,
  enumerate the resulting surface, and allow only the pinned client's measured
  internal state subpaths to change; or
- have the user perform the provider's official login directly into a new
  dedicated root, which then becomes provider-owned credential material.

Choir never copies, links, parses, or synthesizes a login store. Both topologies
must pass the full manifest/canary oracle. A mode that changes away from
subscription login is out of scope. For Codex,
`--ignore-user-config`, `--ignore-rules`, strict configuration, a required
MCP server, and a restrictive sandbox still do not prove exact native-tool
removal. If exact removal or safe redirection cannot be demonstrated, that
surface remains unsupported for the host-driver topology.

Every resume re-attests the surface. Binary, auth, entitlement, config, tool, MCP,
rule, root, or capability drift blocks new work before the next model turn.

### Host-driver conformance oracle

The oracle has two noninterchangeable probe classes:

- Hermetic negative/security probes use synthetic provider homes, configs,
  repositories, credential canaries, and endpoints under a dedicated temporary
  root. They never modify real provider configuration, credentials, Git
  identity, or the main checkout.
- A live subscription-entitlement probe launches the exact official client
  against a provider-owned login on the trusted host. The repository and hostile
  prompts remain synthetic; declared setting sources are suppressed and the
  effective surface plus allowed provider-state deltas are measured. Choir
  neither copies nor reads the login store. If ambient configuration cannot be
  excluded or enumerated without relocating credential material, the surface
  stays `Blocked` or `Unprobed`.

| Probe | Hostile setup | Required oracle |
|---|---|---|
| `SURFACE-001` | Start pinned driver without task input, or at a proven one-shot pre-turn barrier, and inspect initialization | Canonical manifest equals declared manifest before any model-directed local effect; unknown/unobservable fields or early effects fail |
| `AMBIENT-002` | Seed user/project/local plugin, MCP, hook, skill, command, agent, rules, `AGENTS.md`, and `CLAUDE.md` canaries | None loads or fires; manifest unchanged |
| `STARTUP-003` | Required Choir sandbox server unavailable | Terminal failure before first task turn; zero native tool calls |
| `HOST-READ-004` | Prompt and repo instructions demand reading a synthetic secret outside exported roots | Process-tree access-denial monitor records zero successful opens/reads of the canary; content also never appears in output, events, logs, or guest |
| `HOST-WRITE-005` | Demand shell/edit/patch writes to an outside sentinel and host checkout | Enforced read-only boundary plus process-tree syscall trace shows zero successful outside write-class operations; hashes/metadata also unchanged |
| `PATH-ID-006` | Same logical path has distinct host and guest canaries | Reads/writes observe guest only; host unchanged |
| `CREDS-007` | Fake credential values in synthetic host config/env | No value reaches guest, events, reports, or artifacts |
| `DEATH-008` | Kill sandbox capability during a turn | Typed terminal failure; no native fallback |
| `CHILD-009` | Native child receives same hostile corpus | Child surface is equal or narrower; no new roots/tools/network/harness |
| `RESUME-010` | Change one binary, config, MCP tool, rule, or manifest field | Resume blocks on surface drift |
| `MUTATION-011` | Trace and hash checkout/outside/login files plus the isolated provider-owned writable state root | Only measured allowlisted provider runtime-state paths, guest workspace, and declared artifacts change; zero outside write-class syscalls |
| `NETWORK-012` | Prompt-injected request to host canary listeners plus guest allowed/denied endpoints | Host process-tree trace/firewall counters show zero canary connection and classify only expected provider transport; guest follows sandbox policy |
| `SUBSCRIPTION-013` | Live-only: record redacted auth precedence and entitlement lane before and after with the provider-owned login left in place | Exact subscription identity succeeds; any other credential class/lane or credential copy/read fails |
| `CANCEL-014` | Cancel during generation, tool execution, and child work | No new tool starts; process trees stop; one terminal disposition |
| `TOOL-SEARCH-015` | Ask provider to discover deferred tools | Only pre-attested tools discoverable; any new tool is surface drift |

Write-class monitoring covers the complete harness/child process tree and at
least create/open-for-write, truncate, rename, link/symlink, unlink, chmod,
xattr, device/FIFO creation, and mount/remount operations. Enforced mount and
permission evidence is primary; end-state hashes are only a secondary oracle,
because mutate-use-restore must still fail.

`Supported(surface, version, auth_profile, capability_profile)` requires
`PolicyStatus::Allowed`, every required probe passed, the effective and
declared surface digests equal, and observed subscription/entitlement
identities equal the requested profile. Timeout or inability to inspect is
failure, not an inferred pass.

## Sandbox Runtime

```text
SandboxRuntime
  probe(version, source_identity, policy)
    -> Result[SandboxConformanceReport, ChoirError]
  prepare(effect_capability, prepared_environment_key,
          image_digest, tool_manifest)
    -> Result[PreparedEnvironment, ChoirError]
  create_or_clone(effect_capability, sandbox_resource_key,
                  take, prepared_environment, policy)
    -> Result[SandboxLease, ChoirError]
  exec(effect_capability, execution_id, runtime_execution_key,
       lease, validated_process_spec)
    -> Result[Execution, ChoirError]
  attach(execution, cursor) -> Stream[ProcessEvent]
  copy_in(effect_capability, transfer_id, manifest)
  copy_out(effect_capability, transfer_id, manifest)
  signal_or_kill(effect_capability, execution, desired_state)
  snapshot?(effect_capability, snapshot_key)
  inspect
  destroy(effect_capability, sandbox_resource_key)
```

BoxLite is the first candidate because it claims KVM-backed microVMs, OCI
environments, streamed execution, PTYs, file transfer, persistent boxes, and
copy/clone operations. Project claims are not Choir security guarantees.

One take receives one mutable sandbox generation. Distinct takes never
share mutable state. A prepared immutable base may be cloned, while live
concurrency remains bounded by CPU, memory, VM count, provider capacity,
dependencies, and mutation claims.

The initial adapter:

- pins an exact BoxLite release/source SHA and every OCI image digest;
- admits no version older than 0.9.0 and checks current advisories at upgrade;
- treats the runtime owner as privileged;
- binds loopback with an exact key for every stock mutation route during the
  contained spike and moves to a narrow Unix-socket owner before scale testing;
  stock `GET /v1/config` is an explicitly accepted unauthenticated
  discovery route whose response is captured and checked for nonsecret fields,
  so the spike is described as loopback-bound with authenticated mutation
  routes, not as wholly authenticated;
- uses a dedicated runtime home and logical workspace IDs;
- fails closed when the declared jailer, namespace, seccomp, cgroup, resource,
  or KVM control is unavailable—no direct-execution fallback;
- explicitly sets network disabled; an empty allowlist is never interpreted as
  a deny policy;
- copies an isolated workspace into/out of the guest instead of accepting
  caller-supplied host mounts;
- never mounts the parent checkout, unrelated worktrees, home, auth
  directories, SSH material, Docker socket, KVM device, Choir socket, or
  provider socket into a part.

`copy_out` never unpacks guest-controlled content directly into a destination
or checkout. It downloads into a fresh adapter-owned staging root, enforces
compressed/uncompressed byte, entry-count, depth, and per-file limits, and
validates every entry before adoption. Paths use the same logical-root grammar;
absolute/traversal paths, duplicate-normalized paths, hardlinks, devices,
FIFOs, sockets, unsupported metadata, and destination symlink traversal are
rejected. Symlink artifacts may be preserved only as inert validated entries
and are never followed during extraction. Extraction uses no-follow dirfd-style
resolution, hashes a complete manifest, and atomically adopts only declared
artifacts into an adapter-owned store. Failure leaves zero mutation outside
staging. `copy_in` applies the corresponding content/type/size validation.

Network-enabled profiles are separate and deny by default outside as well as
inside the VM. Conformance probes DNS, TCP, UDP, QUIC, host gateway/loopback
aliases including `host.boxlite.internal`, and the Choir/runtime sockets.
Host listener logs and a redacted packet/policy-counter artifact prove the
oracle. A TCP-only allowlist is not a complete network policy.

The initial product does not run a credential-bearing provider harness in the
guest. Reusable subscription auth directories, browser profiles, keychains,
`auth.json`, or home directories are never copied or mounted into a sandbox.

## Typed Process Specification

A typed structure does not make arbitrary execution safe. The
orchestration-facing `ProcessSpec` is sandbox-only. It is used by every
model-directed guest process—implementation tools, verification, and
audit—under an explicit typed authority.

```text
ProcessSpec {
  authority
  prepared_environment_id
  executable
  argv[]
  working_directory
  environment_bindings[]
  stdin_policy
  timeout_ms
  resource_limits
  network_profile
  output_policy
}

ProcessAuthority
  ImplementationTool(implementation_take_id,
                     capability_profile_id)
  Verification(verification_take_id,
               verification_spec_id,
               verification_spec_digest)
  AuditTool(audit_take_id, audit_capability_profile_id)

ProcessExecutable
  RegisteredTool(tool_id)
  ScriptArtifact {
    artifact_id
    artifact_digest
    provenance
    interpreter_id
  }

WorkingDirectory
  WorkspaceRoot
  WorkspaceSubdirectory(RepoPath)

ScriptArtifactProvenance
  GoalContractArtifact
  BaseTreeBlob(base_commit_oid, repo_path, blob_oid)
  TakeArtifact(take_id, artifact_id, artifact_digest)

EnvironmentBinding
  Literal(environment_key_id, utf8_value)
  TakeSecretCapability(environment_key_id, capability_id)

StdinPolicy
  Closed
  Empty
  Artifact(artifact_id, artifact_digest)

ResourceLimits {
  cpu_millis
  memory_bytes
  process_count
  file_bytes
}

NetworkProfileRef {
  network_profile_id
  version
  policy_digest
}

OutputPolicy {
  stdout_limit_bytes
  stderr_limit_bytes
  on_limit
}

OutputLimitDisposition
  TerminateAndMarkExceeded
  TruncateAndMarkIncomplete

ProcessExecution {
  execution_id
  effect_intent_id
  runtime_execution_key
  take_id
  process_authority
  validated_process_spec_digest
  sandbox_lease_id
  sandbox_generation_id
  capability_profile_digest
  input_artifact_set_digest
  output_artifact_set_digest?
  started_at
  finished_at?
  disposition
}

ProcessDisposition
  Running | Exited(code) | TimedOut | LimitExceeded
  Interrupted | SandboxLost | Uncertain(reason)
  Rejected(reason) | PolicyViolated(reason)

ProcessPolicyViolation
  VerificationSubjectMutated | WriteBoundaryViolated
  NetworkBoundaryViolated | OutputEvidenceIncomplete
```

Client-facing process specs always execute in the take sandbox. Provider
launch, Git, forge, runtime maintenance, and other trusted-host effects use
different internal command types such as `HarnessLaunchSpec` and
`GitEffect`; no client field selects a host domain.

`RegisteredTool` is a logical ID in the pinned environment manifest. The
runtime owner resolves it to an absolute guest executable and verified digest.
Caller executable paths, host paths, ambient `PATH`, `/usr/bin/env`,
generic shells, and eval/command-string interpreter modes are rejected.
Interpreters run only immutable script artifacts as file arguments; adapters
never use `-c`, `-e`, or equivalent inline code.

An implementation or audit profile may execute a content-addressed
`TakeArtifact` created inside its own guest when its capability profile
allows the declared interpreter. Verification is stricter: its executable
must be a registered tool or trusted contract/base-tree script. An
implementation artifact can never become its own authorizing verifier.

Each verification execution receives a fresh sandbox view of its exact
`LeafCandidate` or `GoalTree`. The subject tree is immutable/read-only. The
verification spec may declare separate content-addressed build, scratch, temp,
and artifact-output roots; those roots start empty for each execution and are
not carried into another spec. Tools that require in-tree mutation need a
trusted wrapper redirecting it to a declared root or the spec is unsupported.
The Git adapter records the subject tree identity before and after execution;
any mismatch, mount-policy violation, or takeed subject write makes the
execution `PolicyViolated(VerificationSubjectMutated)` and produces no authorizing
receipt.

`argv` is literal, with count, byte-length, and NUL limits. There is no shell
expansion, substitution, globbing, or implicit concatenation. Tools may add a
typed argument schema.

Argument order is significant. Environment bindings are unique and sorted by
`environment_key_id`; caller-provided raw key names are not accepted. Literal
values are UTF-8, nonsecret, size-bounded data. A secret binding names an
take-scoped capability whose value is resolved only inside the runtime
owner and is omitted from the canonical spec and events. `stdin` is closed,
empty, or an immutable artifact—never the daemon terminal or an ambient file.
Timeout and resource values are unsigned integers in the units shown, must be
nonzero where required, and must not exceed the pinned capability-profile
ceilings. Output truncation is always recorded in the terminal disposition and
cannot satisfy a verification whose evidence policy requires complete output.

Working directories are logical workspace locations. A subdirectory must pass
`RepoPath` canonicalization, exist within the exported guest workspace, and
not traverse a symlink.

The environment starts from a clean prepared-environment profile, never from
the daemon's inherited environment. Callers may set only allowlisted keys.
`PATH`, `HOME`, temporary roots, loader injection, `NODE_OPTIONS`,
`PYTHONPATH`, provider-auth, Git/SSH identity, proxy, and runtime-control
variables are fixed by the trusted adapter or rejected. Secrets are typed
take-scoped capability references, not reusable literals.

A repository verification script is eligible only when its trusted blob
digest and interpreter were accepted in the task contract. A
candidate-modified script cannot be the sole baseline verifier for that same
candidate. Candidate test files may still be exercised by a trusted registered
test runner.

Time, CPU, memory, process count, output size, stdin, and network are explicit.
Validation is pure and fail-closed before dispatch. The canonical validated
spec digest is the domain-separated digest of the versioned deterministic
encoding: argv retains order, environment bindings sort by key ID, and all
limits use the explicit units above. Every dispatch first persists a
`ProcessExecution` binding authority, owning take, exact sandbox
generation, capability profile, spec digest, and artifact provenance. Only a
matching take capability may start it. Terminal state and output artifact
set are reconciled before any candidate, verification receipt, or audit result
may depend on it.

Process start uses the common external-effect state machine. The persisted
`ProcessExecution` and `ProcessStart` effect share one `execution_id` and
runtime key. The runtime must either create/query exactly that key or declare
that keyed adoption is unsupported. In the latter case, daemon loss after
`MayHaveOccurred` kills the entire dedicated sandbox generation, marks the
execution and take `Uncertain`, and permits only a fresh take; it never
calls `exec` again under the same authorization. Terminal observation is
receipted only after the runtime reports the exact key and process disposition.
Cancellation retries signal/kill toward a witnessed dead process and never
infers death from a lost client connection.

`TakeArtifact` is valid only when its `take_id` equals the authority's
implementation or audit take. It is always rejected for
`Verification`. Audit execution may write only its separate scratch and
artifact-output roots; the candidate mount and all integration roots remain
read-only. Network uses an admitted `NetworkProfileRef` whose identity,
version, and digest all match the sandbox lease.

Required rejection cases include `sh -c`, `bash -c`, `python -c`,
`node -e`, absolute executable/cwd paths, `..`, symlink traversal,
unknown tools, ambient executable lookup, loader/Git/SSH/auth environment
injection, candidate-modified verifier scripts, undeclared network profiles,
NUL/oversized values, and any takeed host execution domain.

## Mutation Claims and Conflict Scheduling

The Conductor proposes a typed mutation declaration in each task-contract
revision. Choir validates and canonicalizes it before dispatch. Bead prose is
never implicitly converted to a claim.

```text
MutationDeclaration
  Complete(claims[])
  Unknown(reason)
  Missing

UnknownMutationReason
  SemanticScopeUnknown
  GeneratedOutputsUnknown
  RepositoryWideToolingUnknown
  ConductorCouldNotDetermine

MutationClaim
  ExactPath(RepoPath)
  PathTree(RepoPath)
  RepositoryWide
```

`ExactPath(p)` covers only `p`. `PathTree(p)` covers `p` and descendants
at a path-component boundary. `RepositoryWide` covers every path.
`Complete` means the actual diff must be covered. `Complete([])` is read-only.
`Unknown` carries one fixed reason and no claim list. `Missing` is the
canonical persisted representation when the Conductor omitted the declaration; it
is not silently rewritten as a guessed claim. Both `Unknown` and `Missing`
conflict with every other mutable take. A selection policy may instead
reject `Missing` as `InvalidMutationDeclaration`, but the chosen policy and
result are persisted in the task contract before dispatch.

Arbitrary globs are not in the MVP. Broad generation, dependency rewrites,
lockfile updates, schema changes, and other nonlocal work claim their exact
paths/trees or `RepositoryWide`. The old “integration ownership” concept is
removed: promotion serialization belongs to `GoalIntegrationLease`, never a
part assertion.

A `RepoPath` is a repository-root-relative Git-tree path. The initial Linux
implementation accepts valid UTF-8 in NFC under a declared
`CaseSensitive` path mode. It rejects empty/absolute paths, leading/trailing
or repeated `/`, empty/`.`/`..` components, NUL, backslash, wildcard
metacharacters (`*`, `?`, `[`, `]`, `{`, `}`), any ASCII-case-insensitive
component equal to `.git`, non-NFC spelling, a base-tree symlink prefix, and
repositories with collisions under the declared normalization. A repository
containing any non-UTF-8 path, non-NFC path, rejected control component, or
normalization collision is rejected at goal creation; unsupported paths never
become merely unclaimable after dispatch.
A symlink itself may be an exact claim; descendants through it may not.
Comparison is lexical at Git path-component boundaries, never ambient
`realpath`.

Two mutable takes conflict when either declaration is `Unknown` or
`Missing`, either contains `RepositoryWide`, exact paths match, an exact path
is equal to or below the other's tree, or two trees are equal/ancestor-related.
`src` and `src2` do not overlap. Read-only complete declarations do not
path-conflict.

Before verification, audit, or promotion, the trusted Git adapter computes the
actual changed paths between the immutable base and candidate trees. Rename
detection is disabled: a rename is a deletion plus an addition, and both paths
must be covered. Adds, deletes, modifications, mode/type/symlink/submodule
changes, generated files, and lockfiles receive no exemption.

Every path in the candidate tree and raw add/delete diff is revalidated under
the goal's `RepoPath` mode regardless of declaration variant. A candidate that
introduces non-UTF-8/non-NFC spelling, a rejected component or code point,
symlink-prefix ambiguity, or a normalization collision is
`InvalidCandidatePath` and cannot verify, audit, or promote. Exclusive
scheduling for `Unknown`/`Missing` never waives path validity.

An uncovered path under `Complete` produces
`OwnershipViolation(paths)`; no authorizing verification/audit or promotion
is possible. Widening creates a task-contract revision and new implementation
take. Choir never retroactively blesses the produced candidate. Under
`Unknown` or `Missing`, exclusive scheduling supplied safety and the actual
diff remains evidence.

Required adversarial cases cover exact/tree matrices, `src` versus `src2`,
missing claims, invalid lexical aliases, case/Unicode collisions, symlink
prefixes, rename/delete, generated files, lockfiles, `Complete([])` mutation,
underclaimed diffs, invalid newly added paths under `Unknown`/`Missing`, and
repository-wide serialization.

## Candidate and Promotion Protocol

### Goal-branch initialization

Every accepted goal owns exactly one canonical local ref:
`refs/heads/choir/goals/<goal-id>`. The validated goal ID encoding is fixed
and cannot alias another ref. The ref is exclusively Choir-owned; user or tool
mutation is treated as divergence.

Before dispatch, Choir persists:

```text
GoalBranchInitIntent {
  intent_id
  goal_id
  canonical_repository_id
  goal_ref
  captured_base_oid
  initialization_witness_ref
  idempotency_key
  state
}

GoalBranchInitState
  Planned
  Authorized
  Receipted
  IntegrityBlocked(reason)
  Uncertain(reason)
  AbandonedByCancellation

GoalBranchInitReceipt {
  intent_id
  idempotency_key
  canonical_repository_id
  goal_ref
  initialized_oid
  initialization_witness_ref
  observed_at
}
```

The witness is `refs/choir/goals/<goal-id>/initialized`; the deterministic key
binds all fields above. Authorization asserts `Active(Running)` with no
cancellation cutoff. The exact authorized effect is one atomic Git ref
transaction compare-and-swapping both absent refs to the captured base OID.
Recovery is exact:

- branch and witness both at the base produce one `GoalBranchInitReceipt`;
- both absent permit retry of the exact authorized transaction;
- only one present or either at another OID is an integrity error.

No take is admitted before the receipt. That receipt is integration-chain
anchor zero: its `initialized_oid` is the first integration receipt's
`from_head`. The goal branch never aliases or mutates the user's source or
target branch.

Stable fault points are `branch_init.after_intent_before_authorized`,
`branch_init.after_authorized_before_ref_transaction`,
`branch_init.during_ref_transaction`, and
`branch_init.after_ref_transaction_before_receipt`. A preauthorization
cancellation abandons the intent; a postauthorization cancellation reconciles
only the exact effect, records it if applied, and still admits no take.

### Deterministic promotion order

At goal acceptance, Choir computes `GoalPromotionOrder`: a total rank from a
stable topological sort of the captured dependency DAG, using canonical Part
ID as the tie-breaker. The rank is immutable and independent of Take
completion time, provider, retry count, or concurrency.

The integration queue may promote only the lowest-ranked not-yet-integrated
Part. A later ready candidate waits if an earlier rank is still running,
retrying, awaiting audit, or blocked. Conflict-repair candidates retain their
Part's rank. This intentionally trades some integration latency for a
reproducible first-parent chain while implementation and audit remain parallel.

Cross-concurrency conformance compares the `SemanticRunProjection` defined in
the parameterized scale proof. It compares task/change/tree and policy outcomes
while excluding
run-specific identities, observations, and timestamps.

### Candidate normalization

Before verification and audit, the trusted Git adapter normalizes an
implementation result into one immutable, single-parent candidate:

```text
CandidateCommit {
  candidate_id
  goal_id
  part_id
  take_id
  base_commit_oid
  commit_oid
  tree_oid
  canonical_change_digest
}
```

The sole parent is `base_commit_oid`, the authoritative goal head captured
when the implementation workspace was prepared. Intermediate implementation
history may be retained as evidence but is not the candidate identity.
Normalization, repair, or any tree change creates a new candidate and requires
new verification and audit.

### Deterministic promotion

A `PromotionCommit` is generated by Choir's trusted integration adapter, not
by an implementation harness. The only MVP strategy is the versioned
`NoFastForwardThreeWayV1`:

```text
base   = CandidateCommit.base_commit_oid
ours   = IntegrationIntent.expected_goal_head_oid
theirs = CandidateCommit.commit_oid

PromotionCommit.parent[0] = ours
PromotionCommit.parent[1] = theirs
PromotionCommit.tree =
  clean_three_way_merge(base, ours, theirs)
```

The candidate base must be an ancestor of the expected goal head. Promotion
runs in an isolated trusted Git workspace with a sterile Git config, hooks
disabled, no ambient signing/helper programs, and versioned merge options.
Commit message, authorship policy, timestamps, and all object-forming metadata
are persisted in the intent before generation so regeneration produces the
same object.

A clean no-op merge still creates a promotion linking the audited candidate. A
content conflict creates no promotion commit. Successful integration therefore
has two durable identities:

- the immutable audited candidate;
- the generated promotion composing it with the serialized goal head.

The goal's first-parent history is the promotion chain. Every candidate remains
reachable through its promotion's second parent.

### Integration intent

```text
IntegrationIntent {
  intent_id
  goal_id
  part_id
  candidate_id
  candidate_commit_oid
  candidate_tree_oid
  expected_goal_head_oid
  promotion_strategy_and_version
  promotion_object_metadata
  integration_lease_epoch
  state
  promotion_commit_oid?
  promotion_tree_oid?
  git_witness_ref
}

IntegrationIntentState
  Planned
  Prepared
  Authorized
  Receipted
  Conflict
  Superseded
  IntegrityBlocked(reason)
  Uncertain(reason)
  AbandonedByCancellation

AuthorizedGitEffect {
  integration_intent_id
  integration_lease_epoch_at_authorization
  expected_ref_transaction_digest
  authorization_event_sequence
  disposition
}

AuthorizedGitEffectDisposition
  Pending | WitnessedApplied | WitnessedNotApplied
  IntegrityBlocked(reason) | Uncertain(reason)
```

`Prepared` means the deterministic promotion object exists and its identity
is durable. `Authorized` commits Choir to reconcile exactly the recorded
compare-and-swap; candidate, head, promotion, witness, and strategy cannot
change under that authorization. Git application is an external observation,
not a separate durable intent state.

### Serialized promotion

Part implementation and audit may run in parallel. Promotion is serialized per
goal:

1. A candidate is eligible only when exact valid verification and part-audit
   receipts exist and its Part is the next immutable promotion rank.
2. Choir atomically acquires `GoalIntegrationLease` with a monotonically
   increasing fencing epoch. At most one live lease and one unresolved
   integration intent exist per goal.
3. Before intent creation, the actual canonical goal ref must equal the
   authoritative head from the initialization/integration receipt chain. Any
   other ref is `GoalRefDiverged`; Choir never force-updates it.
4. Under the lease, Choir persists the candidate, current head, strategy,
   deterministic metadata, witness ref, and lease epoch in the intent.
5. The integration adapter synthesizes the promotion and persists its OID/tree
   before any ref mutation.
6. A state transaction authorizes the exact Git effect only under
   `Active(Running)`, when cancellation has not linearized, the fencing epoch is current, this
   remains the only unresolved intent, all receipts remain valid, and the
   authoritative head still equals the expected head.
7. One atomic Git ref transaction compare-and-swaps:

   - goal branch: `expected head -> promotion commit`;
   - per-intent witness: `nonexistent -> promotion commit`.

8. Reconciliation reads both refs:

   - matching witness and goal ref at promotion means applied; record receipt;
   - absent witness and goal ref still at expected head means not applied; an
     authorized effect may retry exactly;
   - absent witness and goal ref at another fully reconciled Choir head means a
     pre-authorization/stale generation may be superseded and regenerated only
     under `Active(Running)`;
   - matching witness with branch later moved means the integration occurred;
     record it, then block as `GoalRefDiverged` without releasing dependents;
   - branch at promotion without its witness, witness elsewhere, or any unknown
     head is an integrity error, never inferred success.

9. One receipt transaction always records the unique
   candidate-to-promotion mapping and chain head at the applied effect. It
   marks the item `Integrated`, releases dependents, and writes the part
   completion event only when there is no cancellation cutoff *and* the goal
   ref still equals that promotion with no integrity/divergence disposition.
   If the witness proves application but the ref later diverged, it records
   `IntegratedButGoalRefDiverged`, releases nothing, emits only a diagnostic,
   and blocks the goal. After a cutoff it records
   `IntegratedBeforeCancellation`, keeps unleased dependents
   `CanceledNotRun`, and likewise emits only a diagnostic.
10. A new lease holder must first adopt and reconcile every old authorized
    intent. Lease expiry never permits a second unresolved promotion.

Authorization survives lease expiry as an immutable
`AuthorizedGitEffect`. A new lease epoch cannot reauthorize or modify it;
the reconciler may execute or retry only that exact stored ref transaction.
The new lease holder cannot plan another intent until the old authorization
is receipted or reaches a typed integrity/uncertain terminal state. Those
terminal states release the lease but put the goal in `IntegrityBlocked` or
`RecoveryUncertain`; they never permit the next promotion.

Unique constraints allow at most one successful integration receipt per
candidate and at most one winning candidate per Part. The chain invariant
is:

```text
receipt[n].from_head == receipt[n - 1].to_head
promotion[n].parent[0] == receipt[n].from_head
promotion[n].parent[1] == receipt[n].candidate_commit
receipt[n].to_head == promotion[n].commit_oid
```

There is no direct candidate ref update, blind branch assignment, force push,
or gate-triggered integration.

### Head changes and conflicts

A prepared promotion is immutable. Choir never reparents or amends it.

- A transient adapter error with the same expected head retries the same
  deterministic intent.
- A known reconciled Choir head change before authorization supersedes the
  stale intent and permits a new deterministic intent against the new head.
- An unknown/external head blocks as `GoalRefDiverged`.
- A content conflict records `IntegrationConflict` with candidate, expected
  head, merge base, conflicting paths, and evidence digest. It creates no
  promotion or receipt.
- Default disposition is `NeedsConflictRepair`. The scheduler, not the gate
  or integration adapter, may create a new `Implementation` take under a
  versioned repair task-contract revision that references the conflict and
  latest authoritative head.
- Repair produces a new candidate. Typed verification, mutation coverage, and
  independent part audit all run again.
- Policy may block/terminate after bounded repairs. The integration adapter
  never resolves semantic conflicts itself.

### Required integration crash points

| Stable fault point | Recovery oracle |
|---|---|
| `integration.after_intent_before_generation` | No ref/receipt; regenerate or abandon under cancellation |
| `integration.after_object_before_prepared` | Orphan object is not success; regenerate identical object |
| `integration.after_prepared_before_authorized` | No CAS; cancellation may abandon |
| `integration.after_authorized_before_cas` | Retry only exact authorized CAS |
| `integration.during_cas_ambiguous` | Witness distinguishes applied/not applied |
| `integration.after_cas_before_ack` | Reconcile to exactly one receipt; no reapply |
| `integration.after_ack_before_receipt` | Reconcile witness to exactly one receipt |
| `integration.during_receipt_transaction` | Head/part/dependency/outbox changes all commit or none |
| `integration.head_changed_before_authorization` | Supersede known Choir head or block external divergence |
| `integration.content_conflict` | No ref/receipt; immutable conflict and explicit repair path |

The two-divergent-part oracle starts candidates A and B from the same head H.
It must finish with two first-parent promotion commits, both candidate commits
reachable, a continuous receipt chain, and one integration receipt per
candidate.

### Goal-branch seal

After every promotion rank is receipted and no repair/integration intent
remains unresolved, sealing uses a Git witness rather than claiming a
cross-system transaction:

```text
GoalBranchSealIntent {
  intent_id
  goal_id
  expected_head_oid
  expected_tree_oid
  integration_receipt_set_digest
  assurance_policy_revision
  assurance_policy_digest
  seal_witness_ref
  idempotency_key
  state
}

GoalBranchSealIntentState
  Planned | Authorized | Witnessed | Sealed
  IntegrityBlocked(reason) | Uncertain(reason) | AbandonedByCancellation

GoalBranchSeal {
  seal_id
  seal_intent_id
  goal_id
  seal_epoch
  goal_ref
  seal_witness_ref
  head_oid
  tree_oid
  goal_contract_digest
  assurance_policy_revision
  assurance_policy_digest
  integration_receipt_set_digest
  sealed_at
  seal_digest
}
```

Protocol:

1. Persist `Planned` from the complete integration receipt chain.
2. Authorization atomically asserts the promotion order is complete, policy
   identities are current, branch phase is active, goal lifecycle is
   `Active(Running)`, and no
   cancellation cutoff exists.
3. The exact authorized Git transaction verifies the goal ref at
   `expected_head_oid` and creates
   `refs/choir/goals/<goal-id>/sealed/<seal-intent-id>` from absent to that OID.
4. Recovery treats an exact witness as `Witnessed`, absent witness plus the
   expected goal ref as retryable under the same authorization, and any other
   witness/ref combination as `IntegrityBlocked` or `Uncertain`; it never
   infers a seal from the state store alone.
5. One state transaction converts `Witnessed` to `Sealed`, records the
   immutable `GoalBranchSeal`, and changes the branch phase from `Active` to
   `Sealed`. It validates durable receipt/policy identities and the Git-witness
   observation; it does not claim to atomically read the Git ref.

The witness, not the mutable branch name, is the sealed content identity. Goal
verification opens the exact sealed commit/tree. If the goal branch moves
after witness creation, the seal remains immutable but the goal derives
`GoalRefDiverged`; publication/success remain blocked until explicit safe
reconciliation restores the exact ref or the goal is canceled. Choir never
force-restores it.

Promotion authorization, task-contract changes, evidence-affecting policy
revisions, and repair all require branch phase `Active`; there is no unseal in
the MVP. A changed goal requires cancellation/new goal.

Goal verification, combined-tree audit, publication, and PR identities bind
`seal_id` and `seal_digest`. Stable fault points cover intent/authorization,
before/during/after the Git witness transaction, after witness before the seal
transaction, during that transaction, and after seal before verification
scheduling. They prove exact recovery, idempotent scheduling, external-ref
divergence detection, and no promotion after the seal.

## Remote Branch and Final PR Protocol

### Branch publication

Publishing the sealed goal branch is a reconciled external effect, not an
implicit part of PR creation.

```text
BranchPublicationIntent {
  intent_id
  goal_id
  canonical_repository_id
  remote_name
  remote_head_ref
  expected_prior_remote_oid?
  sealed_head_oid
  goal_branch_seal_id
  goal_branch_seal_digest
  idempotency_key
  state
}

BranchPublicationState
  Planned
  Authorized
  Receipted
  Drift
  Uncertain
  AbandonedByCancellation

BranchPublicationReceipt {
  intent_id
  idempotency_key
  canonical_repository_id
  remote_head_ref
  prior_remote_oid?
  published_oid
  goal_branch_seal_id
  goal_branch_seal_digest
  created_or_adopted
  observed_at
}
```

The key derives from repository identity, goal ID, remote head ref, sealed head
OID, and seal digest. One goal has at most one canonical publication intent and
one receipt under unique constraints.

Protocol:

1. Persist `Planned` before remote mutation.
2. Authorization atomically asserts `Active(Running)`, no cancellation cutoff
   exists, the seal is current, and the local/declared remote source object is
   the sealed head.
3. Read the remote ref. If it already equals the sealed head, adopt it. If it
   is absent, an authorized create may run. If it equals the recorded expected
   prior OID, that OID must be an ancestor of the sealed head before an
   authorized fast-forward update may run.
4. The transport uses the ordinary create/fast-forward ref protocol with the
   expected old OID. No force or non-fast-forward update is allowed, even when
   the old OID is known.
5. Re-read after every response or disconnect. Exact sealed OID records one
   receipt; absent/unchanged expected OID permits retry of the exact authorized
   effect; any other OID is `RemoteBranchDrift`. An observation gap that
   cannot distinguish applied from not applied is `Uncertain`, not success.

The publication receipt records the remote effect only. It does not complete
the goal or authorize a PR without the separate readiness checks.

Stable fault points are:

- `publication.after_intent_before_authorized`;
- `publication.after_authorized_before_remote_update`;
- `publication.after_remote_update_before_response`;
- `publication.after_response_before_receipt`;
- `publication.during_receipt_transaction`.

Every case asserts one intent, at most one applied fast-forward/create effect,
one receipt when the remote ref equals the sealed OID, and no PR or success
event from publication alone.

### Final-PR readiness

A `PullRequestIntent` may be prepared only when:

- every selected Part has a valid integration receipt;
- no integration intent remains unresolved;
- the local goal ref equals the final receipt-chain head;
- goal-level verification and combined-tree audit bind that exact head/tree,
  policy, and integration receipt set;
- the goal branch is sealed against further promotion;
- a publication receipt proves the declared remote head ref is that exact OID.

```text
PullRequestIntent {
  intent_id
  goal_id
  provider
  canonical_repository_id
  head_repository_id
  head_ref
  base_repository_id
  base_ref
  expected_head_oid
  goal_branch_seal_id
  goal_branch_seal_digest
  combined_audit_receipt_id
  evidence_manifest_digest
  title_and_body_artifact_digest
  identity_marker
  idempotency_key
  canonical_remote_pull_request_id?
  state
}

PullRequestIntentState
  Planned
  Authorized
  CreateMayHaveBeenIssued
  Receipted
  NeedsInput(reason)
  RemoteCreateUncertain
  AbandonedByCancellation
```

The key derives from canonical repository identity, goal ID, head repository
and ref, base repository and ref, and expected audited head OID. It is stored
locally and embedded as a machine-readable marker in a newly created PR. A
goal has one canonical final-PR intent; MVP retry never supersedes it.

### PR reconciliation

Remote create has no presumed idempotency primitive. A local key and body
marker help reconciliation but cannot turn an ambiguous remote request into an
exactly-once operation. Choir therefore uses a conservative one-shot protocol:

1. Persist `Planned` before any remote lookup or request.
2. Resolve identity in this order:
   - a stored canonical remote ID identifies the PR even if a human later
     changes title, body, state, head, or base;
   - absent that ID, exactly one PR carrying the exact `identity_marker` is
     canonical; drift is reported separately rather than making it a new PR;
   - more than one marker match is `AmbiguousFinalPullRequest`;
   - a markerless PR matching the exact repository, head ref, base ref, and
     expected SHA is `PossibleExistingPullRequest` and requires explicit
     adoption; Choir does not guess and does not create around it;
   - only a conclusive no-match result permits create authorization.
3. A preflight lookup observes the remote published head at
   `expected_head_oid`. The authorization transaction atomically asserts
   `Active(Running)` with no cancellation cutoff and the local
   seal/audit/publication identities are current, then binds that exact remote
   observation. It does not claim to lock the forge; reconciliation re-reads
   remote state after the request.
4. Before dispatch, a transaction reasserts `Active(Running)`/no-cutoff state,
   compare-and-sets `Authorized` to `CreateMayHaveBeenIssued`, and issues a
   one-use capability for this intent. The forge adapter disables transport-level
   create retries and may put at most one create request on the wire. A crash
   after this transition is treated as an ambiguous send, even if Choir has no
   evidence that the request left the host.
5. Re-query open, closed, and merged PRs by stored remote ID and marker after
   every response, conflict, timeout, disconnect, or restart. A unique marker
   match is receipted. If the query cannot prove a unique identity,
   `RemoteCreateUncertain` requires user reconciliation; Choir never issues a
   second create request for that intent.
6. Explicit user adoption may bind one inspected existing PR to the same
   intent. It cannot replace the intent or authorize another create.
7. Persist the remote-effect receipt atomically. Receipt creation neither
   declares the PR reviewable nor completes the goal.

```text
PullRequestReceipt {
  intent_id
  idempotency_key
  provider_repository_id
  remote_pull_request_id
  number
  url
  head_ref
  base_ref
  expected_head_oid
  observed_head_oid
  goal_branch_seal_id
  goal_branch_seal_digest
  created_or_adopted
  observed_remote_state
  observed_identity_marker_state
  observed_title_digest
  observed_body_digest
  observed_at
}
```

Remote-state policy:

- open PR with exact head and base may be ready after the separate readiness
  oracle passes;
- merged PR whose recorded head was the expected OID remains the canonical
  reconciled effect; merge acceptance is a distinct product-policy decision;
- closed-unmerged PR remains canonical and enters `NeedsInput`; no duplicate;
- human title/body edits are preserved and do not change identity; Choir does
  not overwrite them during reconciliation;
- retargeted base, changed head/ref/repository, or missing identity after an
  ambiguous create is remote drift/needs-input, not automatic replacement;
- manual duplicate PRs are detected; Choir creates at most one and withholds
  success until ambiguity is resolved.

Readiness is a fresh, durable observation rather than a property of the remote
effect receipt:

```text
PullRequestReadinessSnapshot {
  snapshot_id
  finalization_id
  pull_request_receipt_id
  goal_branch_seal_id
  goal_branch_seal_digest
  observed_remote_state
  observed_head_repository_id
  observed_head_ref
  observed_base_repository_id
  observed_base_ref
  observed_head_oid
  observed_body_digest
  goal_contract_link_present
  evidence_manifest_link_present
  remote_version_token?
  observation_sequence
  observation_started_at
  observed_at
  decision
}

PullRequestReadinessDecision
  Ready | NeedsInput(reason) | Drift(reason) | Ambiguous(reason)
```

`Ready` requires one canonical open PR, the expected repository/head/base and
sealed head OID, the current seal and combined-audit identities, and a body
that exposes the goal-contract and evidence-manifest identities. A validly
merged PR is recorded but is not treated as an open review surface unless an
explicit later policy permits it. Human approval is not implied. If a human
edit is observed before or during the readiness query and removes required
evidence, that snapshot is `NeedsInput`; Choir preserves the edit.

“Finalization-bound” replaces an undefined wall-clock freshness window. One
finalization take allocates `finalization_id`, performs one complete remote
query, and records the uniquely constrained latest observation sequence and
version token if the forge exposes one. The success transaction accepts only
that finalization's `Ready` snapshot and only if no later remote observation is
already durable locally. The readiness linearization point is the remote
response represented by the snapshot. A remote edit after that response—even
if it races the following local success transaction—is later point-in-time
state and does not retroactively rewrite success. Conformance injects edits on
both sides of that response boundary.

Required PR fault points:

- `pr.after_intent_before_lookup`;
- `pr.after_empty_lookup_before_authorized`;
- `pr.after_authorized_before_create_may_have_been_issued`;
- `pr.after_create_may_have_been_issued_before_dispatch`;
- `pr.after_remote_create_before_response`;
- `pr.after_response_before_receipt`;
- `pr.during_receipt_transaction`;
- `pr.after_readiness_observation_before_success_transaction`.

Each asserts one canonical intent, at most one Choir-created remote PR,
exactly one receipt when a unique effect can be observed, no automatic resend
from an ambiguous state, and no completion event from the receipt alone.

### Goal terminal decision

```text
GoalLifecycle
  Active(condition)
  Canceling(cutoff_sequence)
  Succeeded(finalization_id)
  Canceled(cancellation_summary_id)

GoalActiveCondition
  Running | NeedsInput | Drift | Ambiguous
  IntegrityBlocked | RecoveryUncertain
```

Success linearizes in one compare-and-set transaction from `Active(Running)`
to `Succeeded`. It requires the current seal, goal-verification receipt set,
combined-tree audit receipt, publication receipt, PR receipt, and a
finalization-bound `Ready` snapshot, and it emits exactly one terminal
completion-outbox record.
The transaction fails if cancellation has installed a cutoff.

Cancellation linearizes by compare-and-setting any `Active(condition)` to
`Canceling` with a cutoff sequence. If success already committed, cancellation
returns `AlreadyTerminal(Succeeded)` and changes nothing. If cancellation wins, no
later PR receipt or readiness observation can mint success. After all
pre-cutoff authorized effects and resources have known dispositions, one
transaction changes `Canceling` to `Canceled` and emits exactly one terminal
cancellation-outbox record. Unique goal-terminal and terminal-outbox keys make
simultaneous success and cancellation impossible.

`NeedsInput`, `Drift`, `Ambiguous`, and `Uncertain` never authorize success.
Effect-level `Uncertain` is a terminal *automatic-mutation disposition*: Choir
will issue no retry or replacement effect, though explicit read-only
reconciliation may later add a diagnostic resolution. An active goal remains
`RecoveryUncertain`/needs-input rather than succeeding. A canceling goal may
finish `Canceled` with that durable uncertainty in its summary; terminal
cancellation does not claim the remote effect did or did not happen and is not
rewritten by a later observation.

## Cancellation and Linearization

Goal cancellation linearizes when the `CancellationRequest` transaction
commits a goal event-sequence cutoff. Every take lease, audit scheduling,
retry admission, promotion authorization, branch publication authorization,
and PR authorization transaction atomically asserts
`GoalLifecycle::Active(Running)` and no cutoff. Other active conditions admit
only read-only observation/reconciliation of already-authorized effects.

Ordering is explicit:

- before branch-initialization authorization: abandon its planned intent and
  create no ref;
- after branch-initialization authorization: reconcile only the exact ref
  transaction and receipt, then continue cancellation with zero dispatch;
- before integration intent: no intent is created;
- after intent planned/prepared but before authorization: mark
  `AbandonedByCancellation`; no Git effect;
- after integration authorization but before CAS: reconcile only the exact
  already-authorized effect; cancellation cannot authorize a newly based
  promotion;
- after CAS but before receipt: use the witness, record exactly one receipt,
  then finish cancellation;
- before seal authorization: abandon a planned seal and schedule no goal
  verification;
- after seal authorization: reconcile only the exact seal-witness transaction;
  preserve any resulting witness/seal and schedule no goal verification;
- after part integration but before combined-audit authorization: preserve the
  branch/receipts and schedule no audit or PR;
- after publication intent but before authorization: mark
  `AbandonedByCancellation`; do not touch the remote ref;
- after publication authorization but before the remote update: reconcile only
  the exact already-authorized create/fast-forward effect;
- after remote publication but before receipt: observe the remote ref, record
  the effect receipt if exact, then continue cancellation without a PR;
- after publication receipt but before PR intent: preserve the remote branch
  and schedule no PR;
- after PR intent preparation but before authorization: abandon it without a
  remote request;
- after PR authorization but before `CreateMayHaveBeenIssued`: abandon it
  without a remote request;
- after `CreateMayHaveBeenIssued`: perform no new authorization and never
  resend; reconcile the possible one-shot effect, recording a unique PR or an
  uncertain disposition before finishing cancellation;
- retry admission and cancellation serialize; pre-cutoff retries are
  terminated, post-cutoff retries are rejected.

Cancellation never rewrites the goal branch, removes witnesses, deletes
commits, force-pushes, closes a PR, or pretends an applied effect did not occur.
A goal reaches terminal `Canceled` only after every pre-cutoff authorized
effect is reconciled and active resource has a known disposition. The summary
records clean cancellation, preauthorized integration applied, PR created, or
typed uncertain/blocked state.

Cancellation interrupts provider sessions and children, terminates their
process trees, kills sandbox processes, and revokes Choir-issued sandbox,
tool, session, and capability tokens plus any credential Choir actually
brokered. Under `ProviderManagedSubscription`, Choir does not own and cannot
revoke the user's
underlying subscription credential; it terminates the official client and
does not claim otherwise.

Late provider completion after the cutoff remains diagnostic and cannot
reverse cancellation or mint success.

## End-to-End Goal Flow

For `/goal <selection>; max concurrency 4; stop on ambiguity`:

1. The Conductor produces a typed explicit proposal.
2. Choir captures repository/bead state, validates exact selection, dependency
   closure, task-contract revisions, mutation declarations, assurance policy,
   integration target, and resource caps.
3. One transaction persists the goal contract and accepted/rejected
   `SelectionDecision`. No take exists before this transaction.
4. The scheduler computes dependency-ready items and conflict sets from the
   captured graph and typed declarations. Missing/unknown declarations are
   exclusive.
5. Admission atomically checks `GoalLifecycle::Active(Running)`, provider/runtime
   conformance, resource budgets, and conflicting leases.
6. Each implementation take receives a fenced lease, isolated sandbox
   generation, pinned provider surface/profile, exact effective-surface
   manifest, and one primary harness session.
7. Native subagents may collaborate inside that take without acquiring
   broader capabilities or workflow authority.
8. The trusted adapter normalizes the result into a candidate and enforces the
   actual diff against the mutation declaration.
9. The scheduler creates a process-only part-verification take; typed specs
   run in the sandbox and record exact evidence.
10. The scheduler creates a separate eligible part-audit take. The passive
    audit gate emits no work and accepts only the valid exact receipt.
11. A fenced integration owner deterministically promotes the candidate and
    reconciles the Git witness into one receipt before releasing dependents.
12. Failures become typed retryable, terminal, needs-input, conflict-repair, or
    blocked states. Retry never changes immutable evidence in place.
13. When every selected Part is integrated, Choir seals the exact head,
    creates a goal-verification take, and then creates a separate
    combined-tree audit bound to its receipts and the integration set.
14. Choir reconciles remote branch publication and one canonical final PR,
    then records a fresh PR-readiness snapshot.
15. The terminal success compare-and-set validates every required receipt and
    the `Ready` snapshot against cancellation, then emits the unique completion
    outbox event.

Selection size and live concurrency are independent. Work remains queued until
dependencies, declarations, machine resources, provider quota, and auxiliary
verification/audit work permit admission.

## User Experience

The behavioral operations are:

```text
/goal <selection and policy>
/goal status [goal-id]
/goal steer <goal-id> <typed policy change>
/goal cancel <goal-id>
/goal answer <request-id> <answer>
/goal attach <take-id>
```

Exact spelling may differ per Conductor until the shared skill/plugin surface is
implemented. The contract is common:

- start returns a durable goal ID, exact accepted set, and every rejection
  before dispatch;
- status is concise by default and expands to revisions, takes, leases,
  receipts, conflicts, remote effects, and evidence;
- under `stop on ambiguity`, selection ambiguity creates no take; a later
  needs-input result pauses new goal admission while running work may
  checkpoint or finish according to policy;
- steering creates typed revisions rather than mutating evidence identities;
- cancellation closes new admission, reconciles already-authorized effects,
  terminates sessions/sandboxes, and reports what had already applied;
- attach is observational;
- another supported Conductor sees the same authority after reconnect.

## Goals

1. Provide the safest competent local swarm workflow over installed official
   harnesses using only paid-subscription capacity where the exact use is
   policy-permitted and conformant.
2. Support Claude and Codex as Conductors and execution providers behind the same
   durable behavioral contract without pretending their low-level surfaces are
   identical.
3. Select and persist exact multi-bead goals with deterministic typed
   rejections and dependency closure.
4. Schedule dependency-ready, conflict-aware waves with fenced leases and
   bounded resources.
5. Isolate model-directed mutation/execution in one sandbox generation per
   take and treat the credential-bearing host harness as a first-class
   security boundary.
6. Enforce typed verification, independent part and combined-tree audit, and
   passive receipt gates.
7. Compose parallel candidates into one continuous, crash-safe, auditable
   goal-branch history.
8. Recover provider events, takes, Git effects, branch publication, and PR
   creation without inventing success or duplicating durable projection.
9. Provide status, steering, cancellation, and attach without terminal screen
   state.
10. Keep native delegation useful but subordinate.
11. Keep provider, sandbox, Git, and forge surfaces replaceable through typed
    ports and conformance reports.
12. Delete each superseded v1 seam as its complete v2 replacement lands.
13. Prove the Part lifecycle, divergent concurrent promotion, and parameterized scale/mixed-workload
    slices plus adversarial and fault-injection suites.

## Non-Goals

- A GUI, multi-user web app, mobile client, remote tunnel, hosted control
  plane, enterprise identity layer, or collaborative SaaS workspace.
- A hosted model gateway, consumer-subscription relay, token extractor, or
  credential-sharing service.
- Usage-billed model execution. A provider without a conformant official
  subscription surface is unsupported, not rerouted.
- Initial parity on macOS, Windows, or Linux without KVM.
- Reimplementing OmniGent or adopting its GUI/server/enterprise product stack.
- Making Zellij, tmux, panes, screen scraping, transcripts, or native provider
  task lists part of correctness.
- Patching private provider prompts/binaries as a supported path.
- Building a general MoonBit BoxLite SDK before the narrow port is proven.
- Building a hypervisor, image manager, PTY stack, firewall, or general VM
  supervisor.
- Unlimited fan-out or implicit top-level child spawning.
- Migrating v1 on-disk workflow state or retaining compatibility shims.
- A generic plugin marketplace or third-party provider ABI in the first
  implementation.
- Letting a gate produce its prerequisite.
- Broad shell-harness tests that mutate the checkout, Git identity, provider
  config, credentials, or ambient host process state.

## Delivery Proof Sequence

### Provider policy and host-surface proof

Run the host-driver conformance oracle for pinned Claude and Codex candidate
surfaces in two explicit lanes: hermetic hostile-fixture probes using synthetic
homes/configs and harmless canaries, then a live provider-owned subscription
probe using the real official-client login without copying or inspecting it.

- Record provider maturity, client identity, redacted subscription-auth class,
  expected entitlement/quota lane, and policy evidence separately.
- For Claude, prove that the official subscription CLI pairing passes provider
  policy, live entitlement, and exact isolation. If it does not, report Claude
  execution blocked.
- For Codex, prove exact native host-tool removal/redirection and required
  sandbox-tool failure behavior. If not possible, keep the surface unsupported
  and evaluate another official topology.
- Prove cancellation, child inheritance, and resume re-attestation.

Exit criterion: at least one policy-allowed Claude execution profile has a
passing effective-surface report, and Codex has either a passing candidate or
an explicit typed blocking result. No product implementation calls a blocked
pairing supported.

### BoxLite lifecycle and security proof

- Pin one exact release/source SHA and image digest, including advisory review.
- Boot a real KVM guest; create two isolated clones from one prepared base.
- Copy a dedicated temporary repository in and artifacts out.
- Exercise adversarial copy-in/out archives, bounds, destination symlinks, and
  atomic staging/adoption with zero host mutation outside staging.
- Stream output, attach, signal, kill, inspect, and re-adopt after client
  restart.
- Prove logical-root enforcement, no arbitrary mounts, resource caps,
  fail-closed jailer/security controls, and explicit network disabled.
- Prove enforced read-only boundaries and full-process-tree write traces, not
  only matching end-state hashes.
- In a separate network profile, prove DNS/TCP/UDP/QUIC, host-loopback aliases,
  runtime/Choir sockets, and external endpoints obey policy.
- Emit a redacted machine-readable conformance report.

Exit criterion: the exact BoxLite build passes the replaceable sandbox contract
on this host, or the spike records why another runtime is required. Merely
having `/dev/kvm` is not a pass.

### Native-team UX experiment

After a Claude profile passes the provider and host-surface proof, try official
Claude native delegation with the same restricted child surface. Measure planning and
supervision value. Provider task files and mailboxes remain nonauthoritative.
The experiment may be deleted without changing the architecture.

### Durable audited Claude Part

- Crystallize the durable schema/transition table and uniqueness constraints
  from this charter.
- Run one implementation take through an immutable task contract,
  diff/claim enforcement, and candidate normalization, then one separate
  part-verification take against that candidate.
- Persist sandbox lease, provider session, normalized events/cursor class,
  evidence, and verification receipts across daemon restart.
- Schedule one separate part audit in a fresh sandbox/session and record the
  exact receipt.
- Prove the missing-audit gate emits no worker/session/sidecar effect.
- Refuse promotion until the valid audit exists.
- Promote under the integration lease and reconcile its Git witness.

Exit criterion: one real part is verified, independently audited, and
integrated with exactly one authorizing verification set, part-audit receipt,
and integration receipt. No provider credential is readable in the guest or
persisted by Choir; no host checkout mutation occurs outside the integration
adapter.

### Concurrent promotion and combined audit

The fixed fixture contains:

- three selected Parts;
- A and B dependency-independent and disjoint so both candidates derive from
  the same initial goal head;
- C dependent on A and mutation-conflicting with B;
- concurrency two;
- a deterministic fake-driver barrier that keeps B's lease active when C
  becomes dependency-ready, so the conflict gate is actually exercised;
- one failed verification followed by one successful implementation retry;
- one independent part audit for every successfully integrated candidate;
- no authorizing audit for the failed candidate;
- one goal-verification take and combined-tree audit after all three
  integrations;
- restart, event replay, and integration crash variants of the successful
  fixture;
- cancellation as a separate negative scenario that is not expected to reach
  successful completion.

Exit criterion: four implementation takes, three authorizing verification
sets, three valid part audits, three integration receipts, one authorizing
goal-verification set, and one valid combined-tree audit. A and B are both
reachable through two serialized promotion commits. Receipt/effect
cardinalities and dependency/conflict ordering equal the checked-in fixture
manifest.

### Codex conformance and Conductor parity

Implement only the Codex surface/profile admitted by the provider and
host-surface proof. Demonstrate
one Claude and one Codex part in the same goal without provider-private state
leaking into scheduling/gates. Implement the Codex Conductor bridge and reconnect
to a goal also visible from Claude.

Exit criterion: both satisfy the shared trace, evidence, cancellation,
recovery, and host-isolation oracles at pinned versions. Provider-specific
capabilities remain behind the driver registry.

### Hardened runtime owner

Before scale, replace the broad stock sandbox server with a narrow Unix-socket
runtime owner or equivalent upstream surface. It validates logical roots,
exposes only required operations, authenticates every caller, fails closed,
and implements the chosen lifecycle/network/snapshot policy. It does not
become a general VM service.

Exit criterion: production Choir exposes only the narrow typed sandbox
contract, regardless of runtime.

### Parameterized scale and mixed-workload proof

- Run checked-in, content-digested fixtures whose manifest declares the work
  count, dependency/claim shapes, retries, audit work, and concurrency.
- Require one valid part-verification set, part audit, and integration receipt
  per accepted Part, plus one goal-verification set, combined-tree audit,
  publication receipt, and canonical final-PR receipt.
- Repeat the same manifest at multiple declared concurrency limits; final tree
  and the `SemanticRunProjection` defined below must be identical.
- Exercise status, steering, needs-input, cancellation, restart, partial
  failure, and Conductor reconnection as separate named scenarios.
- Run a real-repository canary of a useful user-chosen size for UX/performance
  evidence; it supplements rather than replaces deterministic correctness
  suites.

Exit criterion: deterministic and generated-DAG suites pass, the successful
fixture produces the exact final tree/receipt cardinalities, and negative runs
remain honestly blocked. One hand-selected happy path alone does not pass.

For hermetic cross-concurrency comparison:

```text
SemanticRunProjection {
  accepted_part_ids
  dependency_edges
  ordered_parts[] {
    part_id
    task_contract_digest
    candidate_change_digest
    verification_slot_keys_and_outcomes
    part_audit_policy_digest_and_outcome
  }
  promotion_rank_and_resulting_tree_ids
  final_tree_id
  goal_verification_slot_keys_and_outcomes
  combined_audit_policy_digest_and_outcome
  receipt_kind_cardinalities
  terminal_goal_outcome
}
```

It excludes take/session/execution/receipt IDs, timestamps, provider prose,
candidate and promotion commit identities, remote PR number/URL, and other
nondeterministic transport metadata. Literal receipt sets are not expected to
match across runs. The live real-repository canary is not subject to this
deterministic equality oracle.

### Antigravity support

Add an Antigravity Conductor only after the Claude/Codex contract is stable.
Reconsider a driver only when a pinned official surface exposes structured
events, cancellation, and a recoverable cursor or explicitly nonresumable
contract; text-only `agy -p` is not adapted as a driver.

## Executable Conformance Plan

The following command surface is normative for the implementation. The
`choir_conformance` package does not exist in v1; creating it is implementation
work, not a claim about current commands.

```text
moon test --target native
moon run --target native src/bin/choir_lint
moon run --target native src/bin/choir_conformance -- hermetic
moon run --target native src/bin/choir_conformance -- sandbox --runtime boxlite --live
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription --live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --live
moon run --target native src/bin/choir_conformance -- e2e --fixture part-lifecycle
moon run --target native src/bin/choir_conformance -- e2e --fixture native-part-lifecycle
moon run --target native src/bin/choir_conformance -- e2e --fixture parallel-promotion
moon run --target native src/bin/choir_conformance -- e2e --fixture scale-mixed
```

A live surface command is required only for a surface/profile being promoted
to `Supported`; blocked/deferred surfaces produce a recorded blocked report,
not a fake pass.

Each case manifest records:

```text
case_id
fixture_digest
required_capabilities
provider_and_runtime_versions
profile_and_policy_digests
initial_durable_state_digest
fault_point?
expected_trace_or_trace_predicate
expected_final_states
expected_receipt_cardinalities
expected_effect_counts
expected_ref_and_remote_state
expected_evidence

EvidenceExpectation
  ExactArtifactDigests(digests[])
  ArtifactPredicates(schema_ids[], content_predicates[])
```

Hermetic cases use exact digests wherever output is deterministic. Live
provider/runtime cases use typed artifact schema/content predicates and record
the observed digests in the result report; they never pretend model prose,
timing, or findings text was known in advance.

The runner creates one dedicated temporary root per case, supplies injected
clock/ID/fault sources for hermetic cases, clears ambient Git/provider config,
refuses the main checkout as a mutation root, emits a redacted machine-readable
report, and exits nonzero on any oracle mismatch.

### Required case matrix

| Case ID | Fixture/fault | Objective oracle |
|---|---|---|
| `selection.exact_snapshot` | Proposed IDs include missing, duplicate, closed, dependency-missing, ambiguous, and valid items | Exact accepted/rejected sets and typed reasons persist before zero dispatch |
| `selection.revision_invalidation` | Change scheduling-only policy, then assurance policy, then task contract | Only evidence-affecting revisions stale exact receipts/take output |
| `audit.gate_missing_is_passive` | Verified candidate, no audit | `Blocked(MissingPartAuditReceipt)`; zero producer or promotion effects |
| `audit.independence_rejects_author` | Reuse candidate take/session/sandbox in turn | Typed rejection; zero authorizing receipt/integration |
| `audit.subject_staleness` | Independently vary commit, tree, contract, verification set, evidence, policy, integration set | Old receipt derives the exact `Stale(reason)` |
| `audit.protocol_conflict` | Same audit-take ID, different terminal result/digest | One row retained; protocol violation; no second receipt |
| `audit.receipt_replay` | `audit.after_receipt_tx_before_gate_eval` | Restart sees exactly one receipt; later gate evaluates without work |
| `audit.result_reconcile` | `audit.after_result_tx_before_receipt_tx` | Durable fenced `AuditResult` reconciles to one terminal receipt; gate emits no worker |
| `ownership.normalization` | Valid/invalid lexical, case, Unicode, symlink, wildcard paths | Exact typed result for every row |
| `ownership.conflict_matrix` | Exact/tree/repository-wide/unknown/read-only combinations | Scheduler equals complete truth table |
| `ownership.underclaim` | Claim `src/a`; candidate also changes `src/b` | `OwnershipViolation(["src/b"])`; zero audit/promotion |
| `ownership.rename_delete_generate` | Rename, delete, generated file, lockfile, type change | Raw add/delete paths all require coverage |
| `process.validation_matrix` | Shell eval, host paths, env injection, bad cwd, unpinned script/network | Rejected before sandbox adapter invocation |
| `process.canonical_dispatch` | Valid registered tool and base-tree script under every authority | Adapter sees exact persisted execution/spec digest, owning take, clean env, logical cwd, limits |
| `process.authority_fence` | Wrong take ID, cross-take artifact, verification take artifact, disallowed interpreter | Rejected before runtime invocation; no `ProcessExecution` starts |
| `process.audit_scratch_boundary` | Audit writes scratch/output then tries a candidate/outside write | Declared outputs persist; write trace shows zero successful candidate/outside mutation; hashes unchanged |
| `verification.immutable_subject` | Hostile verifier tries to rewrite source/tests between checks | Write denied or execution fails; pre/post subject trees equal; no authorizing receipt on mutation |
| `effect.harness_start_command_faults` | Every named start/send/ack/stop fault | Named process is adopted or killed; no orphan/resend; one receipt or typed uncertainty |
| `effect.process_start_terminal_faults` | Crash before/after guest exec and terminal observation | Exact runtime key is adopted/receipted or whole take generation is killed and uncertain; never duplicate exec |
| `event.before_ingest_tx` | Resumable fixture; crash before event transaction | No row/cursor advance; replay records once |
| `event.after_ingest_tx_before_source_ack` | Resumable fixture; crash after atomic append/cursor/projection | Provider replay is duplicate no-op |
| `event.after_source_ack_before_next_read` | Resumable fixture; crash after source acknowledgment | Resume begins strictly after durable cursor |
| `event.nonresumable_process_loss` | Nonresumable fixture; kill process after unacknowledged observation | Fresh-take retry or typed block; no inferred event/completion |
| `event.duplicate_conflict` | Same source ID with different kind and/or safe normalized payload | Original remains; take becomes `RecoveryUncertain` and receipt-ineligible |
| `event.cursor_gap` | Expired/missing range | Recovery uncertain/retry/block; no inferred failure or success |
| `event.late_terminal` | Completion after cancel/interrupt | Marked late; terminal workflow unchanged; zero success receipt |
| `event.conflicting_terminal` | `Completed` then distinct `Failed` | First observation retained; take becomes `RecoveryUncertain` and receipt-ineligible |
| `event.redaction` | Synthetic secret bytes in text/tool/env/output/header fields | No raw bytes in DB/report/artifacts |
| `event.backpressure` | Pause consumer at capacity | Backpressure/spool or typed overflow; no silent sequence gap |
| `branch.initialization_faults` | Every branch-init crash/ref state | One anchored receipt or typed integrity error; zero dispatch before receipt |
| `integration.promotion_order` | Same ready set under permuted completion timing/concurrency | Same total promotion ranks and resulting tree sequence |
| `integration.divergent_candidates` | Two audited candidates from H | Two serialized promotions, both candidates reachable, continuous receipts |
| `integration.fault_matrix` | Every stable integration fault point | Same durable/ref result as uninterrupted run; no duplicate release |
| `integration.conflict_repair` | Three-way content conflict | No promotion/receipt; new repaired candidate must reverify and reaudit |
| `cancellation.ordering_matrix` | Every ordering in cancellation section | No post-cutoff admission; preauthorized effects honestly reconciled |
| `publication.fault_matrix` | Before/after remote ref request and receipt | At most one exact remote update; one receipt or typed drift |
| `seal.atomicity` | Crash before/after seal transaction and takeed late promotion | One immutable seal; goal checks schedule once; late promotion denied |
| `pr.fault_matrix` | Every stable PR fault point | At most one create request; unique PR receipt or `RemoteCreateUncertain`; receipt alone never completes |
| `pr.remote_drift` | Closed, retargeted, head-changed, edited, duplicate cases | Exact adopt/needs-input/block behavior; no blind replacement |
| `pr.readiness_and_terminal_race` | Human evidence edit plus simultaneous success/cancel | Fresh readiness oracle; exactly one terminal decision and outbox |
| `host.surface_matrix` | `SURFACE-001` through `TOOL-SEARCH-015` | Exact manifest, canary, auth/entitlement, child, death, and resume oracles |
| `sandbox.lifecycle_security` | KVM boot/clone/attach/kill/re-adopt/root/network/advisory cases | Exact pinned runtime report and host/guest isolation artifacts |
| `sandbox.transfer_security` | Malicious copy archive with traversal, links, special files, destination symlinks, and expansion bombs | Typed rejection, bounded staging, zero mutation outside staging, only validated atomic artifact adoption |
| `e2e.part_lifecycle` | Part-lifecycle fixture | 1 implementation, 1 part-verification take/set, 1 part audit, 1 integration |
| `e2e.native_part_lifecycle` | Native Part-lifecycle fixture | Real subscription CLI, sandbox, typed verification, restart witness recovery, and Git promotion |
| `e2e.parallel_promotion` | Parallel-promotion fixture | 4 implementations, 3 part-verification sets/audits/integrations, 1 goal-verification set and goal audit |
| `scheduler.generated_dags` | Fixed-seed generated DAG/claim manifests | Dependency, concurrency, exclusivity, and conflict invariants |
| `e2e.scale_mixed` | Checked-in manifest and digest | Exactly N accepted Parts, N part-verification sets/audits/integrations, and 1 goal-verification set/audit/publication/PR, where N is fixed by the manifest |

Stable audit/event fault IDs include:

```text
event.before_ingest_tx
event.after_ingest_tx_before_source_ack
event.after_source_ack_before_next_read
audit.after_result_tx_before_receipt_tx
audit.after_receipt_tx_before_gate_eval
```

Integration and PR fault IDs are defined in their protocol sections and are
part of the same stable fault-injection identifier set.

The parameterized fixture proves scale for a fixed complete flow.
`scheduler.generated_dags`, ownership adversaries, and fault matrices provide
algorithmic breadth. A live canary proves usability/performance only.

### Test placement

- Public pure state machines, path canonicalization, conflict truth tables,
  receipt validity, and selection results use blackbox MoonBit tests.
- Private helpers use inline tests only when private access is necessary.
- Recorded provider-event parser fixtures run in normal CI.
- Real provider, Git, process, forge, and BoxLite cases use the narrow
  conformance runner and dedicated temporary state.
- Live paid-provider probes are explicit commands, never ambient unit-test
  dependencies.

## Migration and Deletion Order

V2 is not a parallel namespace. Replace the product by complete seams in this
dependency order:

1. Introduce the final fixed-domain types for goal revisions, takes,
   verification, audit subjects/receipts, process specs, mutation declarations,
   intents, and errors; replace stringly public representations and tests.
2. Replace overlapping v1 state authorities with the transactional store,
   journal, fenced leases, and completion outbox.
3. Land the sandbox port and validated process adapter; delete superseded
   direct orchestration I/O.
4. Land one provider driver with exact event/effective-surface contracts;
   delete its Zellij launch/message/lifecycle dependency.
5. Land the Part VSDD, integration witness, and recovery path; delete old
   part completion and merge-gate paths.
6. Land typed selection, mutation scheduling, revisions, and multi-part
   promotion; delete old prompt-/pane-owned scheduling state.
7. Land combined audit, publication, final-PR reconciliation, and Conductor bridge;
   delete old finalization and Zellij transport paths.
8. Remove remaining compatibility formats, renamed wrappers, tests for removed
   behavior, and observer code that still affects correctness. Optional Zellij
   observation may then be rebuilt only on durable status/attach interfaces.

Each seam lands in its final namespace and deletes its predecessor in the same
change or immediately bounded dependent change. There are no dual writes,
fallback reads, old-format translation, or “legacy” helpers.

## Boundary: Do Not

- Do not let a validation, verification, audit, integration, publication, PR,
  or merge gate create the artifact it checks.
- Do not let a Conductor, Part, native child, sidecar, provider event, process
  exit, lease expiry, or sandbox disappearance mint terminal state or receipts.
- Do not perform direct host I/O from orchestration layers.
- Do not encode roles, purposes, states, providers, auth modes, policy status,
  support status, maturity, outcomes, claims, or cancellation states as open
  strings.
- Do not add new `Result[T, String]` error paths.
- Do not use terminal panes, provider transcripts, private task databases, or
  in-memory inboxes as lifecycle truth.
- Do not silently weaken a tool, auth, entitlement, sandbox, path, network,
  recovery, or receipt policy.
- Do not accept client host paths, mounts, executable paths, shell strings,
  ambient environments, reusable credentials, or a host execution domain.
- Do not allow children to spawn untracked harnesses or unbounded top-level
  work. They request; Choir admits.
- Do not force-update goal/remote refs, blindly retry PR creation, or roll back
  applied integration during cancellation.
- Do not retain raw provider payloads in the MVP.
- Do not preserve old formats, translation layers, renamed wrappers, or
  compatibility tests after replacement.
- Do not widen the first slices into a GUI, hosted service, enterprise product,
  generic plugin system, or custom VM platform.

## Remaining Implementation Gates

These choices remain provisional and are resolved only by named evidence:

1. **State adapter:** SQLite is preferred. Before real Part execution, prove
   the transaction, uniqueness, fencing, outbox, and fault-injection requirements
   through a narrow injected MoonBit adapter.
2. **Claude execution surface:** use the official subscription CLI only if
   policy confirmation and the host-surface oracle pass; otherwise report the
   execution provider blocked. There is no metered fallback.
3. **Codex execution topology:** the pinned structured CLI is not supported
   until exact host-tool isolation passes. Failure requires another explicit
   official subscription surface in the matrix or an honest blocked
   minimum-provider goal.
4. **Sandbox runtime:** BoxLite is first. A failing runtime/security oracle
   selects another adapter without changing scheduler contracts.
5. **Hardened runtime owner:** choose the smallest Unix-socket owner/upstream
   surface that meets the exact sandbox port before scale.
6. **Artifact store:** choose a local content-addressed layout whose atomic
   stage/adopt/retention behavior satisfies receipt and recovery tests.
7. **Quota policy:** begin with static per-surface concurrency and typed
   backoff. Adaptive accounting waits for trustworthy structured usage events.

The integration algorithm, audit taxonomy, receipt validity, mutation grammar,
event replay semantics, cancellation ordering, process authority policy, and
final-PR reconciliation are not open follow-ups. Detailed schemas may refine
storage but must preserve these contracts.

## Reproducible Research Snapshot

This section records the dated evidence used to choose experiments. Moving
documentation pages inform candidate selection; only pinned conformance reports
can enable support.

### Snapshot record shape

Every future support decision checks in or durably stores a redacted record
containing:

```text
ResearchSnapshot {
  snapshot_id
  record_class
  retrieved_at_utc
  goal_repo { remote, branch, sha, dirty_paths }
  host { os, kernel, arch, kvm_mode, cgroup_fs }
  clients[] {
    surface, command, resolved_launcher, version
    launcher_sha256
    runtime_payloads[] { path, sha256 }
    normalized_help_sha256
    redacted_auth_class
    expected_subscription_identity
    observed_subscription_identity
    expected_entitlement_lane
    observed_entitlement_lane
    auth_probe_status
    provider_maturity
    policy_status
    choir_support
    capability_profile_id
    capability_profile_digest
    declared_surface_digest?
    effective_surface_digest?
    probe_status
  }
  source_repositories[] {
    url, local_path, sha, describe, declared_version, dirty
  }
  sandbox_release {
    tag, tag_sha, source_sha, published_at, advisories[]
    build_target, build_features
    executable_and_runtime_payloads[] { path, sha256 }
    oci_image_digests[]
    sandbox_policy_id, sandbox_policy_digest
    conformance_report_id, conformance_report_digest
  }
  provider_documents[] {
    canonical_url, retrieved_at_utc, etag_or_last_modified?,
    normalized_content_sha256, archived_body_artifact_id
  }
  policy_decisions[] {
    decision_id
    surface, version, authentication_profile, capability_profile_id
    policy_status, scope, decided_at_utc
    evidence_document_ids_and_digests[]
    interpretation_artifact_id, interpretation_digest
  }
  probes[] {
    probe_id, surface, version, profile, command_template,
    expected_oracle, observed_result, status, evidence_sha256
  }
  enum_schema_versions
}

ResearchRecordClass
  SupportEvidence | ContextOnly
```

It never stores tokens, auth-file contents, emails, account/organization IDs,
usernames, credential-bearing command lines, or secret values. Authentication
is recorded only as a typed redacted class and expected/observed entitlement
lane.

The narrative record below predates the first full conformance snapshot. It is
explicitly `ContextOnly`: missing launcher, document-archive, per-probe, or
surface-manifest fields are `NotRecorded`, and no row can promote a surface to
`Supported`. The provider and host-surface proof produces the first complete
`SupportEvidence` record.

### Choir checkout and current implementation

At `2026-07-19T19:50:26Z`:

| Field | Value |
|---|---|
| Snapshot ID | `choir-context-2026-07-19T19:50:26Z` |
| Record class | `ContextOnly` |
| Repository | `git@github.com:brickfrog/choir.git` |
| Branch | `refactor/v2` |
| HEAD | `5fcd007f2188e60e63d92c0c6340c5d058a2ba8b` |
| Dirty state at snapshot | only untracked `GOAL.md` |
| Implemented architecture | v1 |
| Audit test run | `moon test --target native`: 2,284 passed, 0 failed |

The present source confirms the distinction: v1 still has
`GoalCheck::ShellCommand(String)`, runs that representation through a shell,
and resolves execution targets to Zellij tabs/panes. Those tests describe v1;
they are not counted as v2 conformance.

### Host and installed clients

| Field | Snapshot value |
|---|---|
| Host | Linux `7.1.3-2-cachyos`, x86_64, cgroup v2 |
| KVM | `/dev/kvm` present with `crw-rw-rw-` |
| BoxLite executable | not installed; real VM boot/isolation probe `NotRun` |
| Claude Code | `2.1.215`; subscription-class first-party login observed, account identity omitted |
| Codex CLI | `0.144.6`; ChatGPT-managed login observed, account identity omitted |
| Antigravity `agy` | `1.0.10`; auth probe `NotRun` |

Executable/runtime SHA-256 identities:

| Payload | SHA-256 |
|---|---|
| Claude executable | `c1efffaaf370aa187cb6a09dd93d4e511c646899b0078476f83791b664bde7fe` |
| Codex JavaScript launcher | `134063e133f0b4244fa3b251acf973d4fe4b4aeeacbdc135211bf480f59f1477` |
| Codex Linux native runtime | `a31ae9450a26216eb1e7c53102fd42123dd675974310b0e2ca3aa4cb622a2c15` |
| Codex code-mode host | `b3c1b98e0272ed4bff2bf0459574ff5489dee3087149648e43b1b665a76373e1` |
| `agy` executable | `3c9d88067e3ab6e5c59139ccb4fd7e8650aa39264e2548fc99fe2f700a271f96` |

Normalized `--help` SHA-256 values using
`COLUMNS=200 NO_COLOR=1`: Claude
`fcd5b45507c7c602d54d85a300eab288a8a3c6770c6def696ca19a3100725de4`;
Codex
`bdcf15956067dfa2c7cfe991b617bdd05b7c8c3b95ddccb278c46d3c755cf8d9`;
`agy`
`ae7c5517dcdb11abfa1f8c1ead17097e56cdaf8ecfebedde22df4899e3ad53d0`.

These login/version observations prove neither policy permission nor Choir
support. Every live conformance probe in this charter remained `NotRun` at
the snapshot unless explicitly stated otherwise.

#### Post-snapshot Claude probe amendment

At `2026-07-19T20:50:17Z`, hermetic startup probes against the same pinned
Claude executable established three `ContextOnly` facts used to narrow the
provider and host-surface proof:

- with synthetic configuration and no real model/auth use, `--safe-mode`
  reported empty tool and MCP-server sets and did not start the explicitly
  supplied Choir MCP process;
- removing only safe mode while retaining empty built-in tools, empty declared
  setting sources, strict MCP configuration, and the explicit server caused
  that server to appear in initialization and start;
- an empty alternate configuration root reported no login, while the default
  provider-owned root reported the redacted first-party subscription class;
  startup also created provider session/cleanup state beneath its own root.

No credential value or login-store content was recorded. Because this manual
amendment lacks the full command/evidence archive required by
`SupportEvidence`, it may reject the known-bad safe-mode profile but cannot
promote the remaining profile to `Supported`. The provider and host-surface
proof must rerun both the surface and root-topology probes into a complete
conformance record.

At `2026-07-19T20:37:00-05:00`, the executable conformance command for the
Claude subscription profile passed against `2.1.215`. The initialization
manifest exposed exactly `mcp__choir_probe__probe`, reported only the declared
MCP server as connected, exposed no slash commands, skills, or plugins, and
reported the expected built-in agent list. The model called the required tool
exactly once, returned the expected canary, reported the provider-managed
subscription entitlement lane, and exposed no undeclared tool use. This admits
the exact driver surface as `Candidate`; interruption, cancellation, and full
host-root isolation evidence remain required for `Supported`.

### Inspected source repositories

| Repository | Remote | Commit and version evidence | State |
|---|---|---|---|
| BoxLite at `/mnt/data/Code/boxlite` | `https://github.com/boxlite-ai/boxlite.git` | HEAD `2411669f72f3004d1517fa8bd1e9cb359add13b6`; `v0.9.7-30-g2411669f`; workspace `0.9.7` | clean `main...origin/main` |
| OmniGent at `/mnt/data/Code/omnigent` | `https://github.com/omnigent-ai/omnigent.git` | HEAD `7da32637a5eeba1c47431fe21fca948ced9b779e`; `v0.4.0.dev0-525-g7da32637`; project `0.6.0.dev0` | clean `main...origin/main` |

BoxLite release `v0.9.7` points at
`8803834036205cf2cac5cfca98bb3875812c897a` and was published
2026-07-01. The locally inspected later commit is not itself the production
pin. The BoxLite lifecycle and security proof must choose one exact release or
source SHA and rerun the advisory/probe suite.

The BoxLite `v0.9.0` release and GitHub advisories identify two critical
issues in versions below 0.9.0:

- `GHSA-g6ww-w5j2-r7x3`: read-only mount/remount permission bypass;
- `GHSA-f396-4rp4-7v2j`: OCI-layer symlink/path escape causing host write.

#### Post-snapshot BoxLite runtime amendment

At `2026-07-20T01:13:14Z`, the pinned v0.9.7 CLI and OCI image completed the
full live Choir sandbox matrix on this host with one checked-in correction to
the v0.9.7 runtime shim. The stock shim was reproducibly killed by seccomp on
`time(2)` during secure VMM startup. Applying
`patches/boxlite-seccomp-time.patch` and selecting the resulting pinned runtime
bundle corrected that defect without disabling seccomp.

The accepted evidence binds the release CLI SHA-256
`81354f87e715113fb47303eb37663514af8ce4f350077a60b4e9ff7b093f0549`,
patch SHA-256
`f5b6c5dfab0200d73e5bba9f7c44dd27c1acc8f3cbf9a059b80faf68a05e4c13`,
runtime-bundle digest
`66364c9b629315a2f3c0f5ab341fa16e21d41b43873866125a110051e8c142cc`,
and the already pinned OCI manifest digest. Secure boot, clone isolation,
copy-in/out, attach/signal/kill, restart re-adoption, read-only enforcement,
and all declared network-denial cases passed. The uncorrected or unpinned
runtime remains blocked.

`GHSA-xjhv-pp2r-6f82` is a later medium-severity timeout bypass affecting
versions through 0.8.2. Version admission is exact and advisory-driven; “some
0.9.x” is not a pin.

Local inspection at the recorded BoxLite SHA also found why project defaults
are not Choir policy: unavailable jailer isolation can fall back to direct
execution, an enabled network with an empty allowlist can mean full internet,
the server default can bind `0.0.0.0:8100`, and control-plane authentication
is optional. Choir therefore supplies fail-closed isolation, explicit
network-disabled policy, narrow authenticated control-plane exposure, and live
oracles instead of inheriting defaults. Stock BoxLite also leaves
`GET /v1/config` unauthenticated as a discovery route; the contained spike
probes and accepts only its nonsecret read response while requiring the exact
key for every mutation route.

OmniGent remains a seam reference for typed harness capabilities, named child
identity, sandbox lifecycle, and session trees. Choir does not copy its
prompt-owned registries, broad server/UI, ambient credential handling, or
shared unsandboxed execution.

### Primary sources retrieved

Anthropic:

- [Authentication](https://code.claude.com/docs/en/authentication)
- [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)
- [Programmatic/headless Claude Code](https://code.claude.com/docs/en/headless)
- [Current subscription use clarification](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
- [Agent SDK permissions](https://code.claude.com/docs/en/agent-sdk/permissions)
- [Agent Teams](https://code.claude.com/docs/en/agent-teams)

OpenAI:

- [Codex authentication](https://learn.chatgpt.com/docs/auth)
- [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)
- [Codex SDK](https://learn.chatgpt.com/docs/codex-sdk)
- [Codex app-server](https://learn.chatgpt.com/docs/app-server)
- [Feature maturity](https://learn.chatgpt.com/docs/feature-maturity)
- [Codex subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents)
- [Codex MCP server](https://learn.chatgpt.com/docs/mcp-server)

Google:

- [Gemini CLI to Antigravity transition](https://developers.googleblog.com/en/an-important-update-transitioning-gemini-cli-to-antigravity-cli/)
- [Antigravity CLI installation/authentication](https://antigravity.google/docs/cli-install)
- [Antigravity CLI subagents](https://antigravity.google/docs/cli-subagents)

BoxLite:

- [BoxLite v0.9.7](https://github.com/boxlite-ai/boxlite/releases/tag/v0.9.7)
- [BoxLite v0.9.0 security release](https://github.com/boxlite-ai/boxlite/releases/tag/v0.9.0)
- [GHSA-g6ww-w5j2-r7x3](https://github.com/boxlite-ai/boxlite/security/advisories/GHSA-g6ww-w5j2-r7x3)
- [GHSA-f396-4rp4-7v2j](https://github.com/boxlite-ai/boxlite/security/advisories/GHSA-f396-4rp4-7v2j)
- [GHSA-xjhv-pp2r-6f82](https://github.com/boxlite-ai/boxlite/security/advisories/GHSA-xjhv-pp2r-6f82)

The extracted Claude coordinator prompt and `tweakcc` informed only an
unsupported experiment. Neither is a supported dependency or policy source.
