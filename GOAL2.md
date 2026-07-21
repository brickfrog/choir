# Choir Migration Workflow Goal

Status: draft extension charter

Depends on: `GOAL.md`

Research refreshed: 2026-07-21

## Purpose

Choir already provides the execution substrate: a Conductor turns user intent
into a durable Goal, `choird` schedules Parts and Takes, Claude or Codex can do
the work, BoxLite isolates mutation, passive gates require verification and
independent audit receipts, promotion is serialized, and the combined Goal tree
is verified before publication.

This document defines the additional workflow needed for large, repetitive
transformations such as language ports, framework upgrades, API replacements,
and repository-wide architectural rewrites. These jobs are different from an
ordinary collection of Beads because the process itself must improve while the
work is running. A repeated defect is evidence that the shared instructions or
judge are wrong, not merely that another file needs a patch.

The product outcome is:

> A user can discuss a large transformation with the Conductor, prove the
> transformation's rules and judge on representative cases, accept a durable
> migration contract, and let Choir generate and complete the resulting Parts
> until mechanical and behavioral parity gates pass.

The Conductor exercises judgment and steering. `choird` remains the sole
workflow authority.

## What the Anthropic Migration Process Adds

The useful idea is not “spawn hundreds of agents.” Choir already knows how to
fan work out safely. The useful idea is to make the loop that produces the code
an explicit, testable product object.

Anthropic's reported workflow contributes these mechanisms:

1. Build the judge before implementation fanout. Prove it accepts the original
   and rejects deliberately broken controls.
2. Capture a rulebook, dependency map, and gap inventory before generating the
   production queue.
3. Stress-test the process on representative work, discard the resulting code,
   and retain only what was learned about the process.
4. Generate the queue mechanically from repository state so it is reproducible
   and resumable.
5. Treat recurring review findings as defects in the shared rulebook. Revise
   the contract and redo the affected work instead of hand-patching instances.
6. Put expensive global operations behind one owner. Parts may run in parallel;
   compilers, full builds, or shared parity suites may need serialized batching.
7. Use behavioral comparison against the original system when unit tests alone
   cannot establish parity.

These mechanisms fit Choir's existing architecture. They do not justify a new
scheduler, provider-owned workflow state, prompt-owned completion, per-worker
pull requests, a GUI, or usage-priced provider execution.

## Normative Boundaries

- This document extends `GOAL.md`; it does not replace or fork its Goal, Part,
  Take, receipt, integration, publication, or cancellation protocols.
- Existing accepted Goal selection remains immutable. Adding or removing Parts
  requires a new Goal. Revising shared instructions may invalidate and rerun
  selected Parts, but it may not silently change the selected set.
- Gates remain passive. A missing judge, rehearsal, verification, audit,
  parity, or global-check receipt causes a typed blocked state. The gate never
  runs the missing work itself.
- Provider sessions and native subagents remain disposable execution details
  inside a Take. They do not own the migration contract or queue.
- The normal product path uses the locally authenticated Claude and Codex
  clients already supported by Choir. No usage-priced provider path is added by
  this workflow.
- Beads remains the durable source of proposed work and dependency edges.
  Migration discovery may propose Beads; only accepted Beads become Parts.
- Semble and external search remain optional, explicitly admitted research
  capabilities. Neither is required for execution or correctness.
- Exact source reads, deterministic scripts, compilers, tests, and parity
  comparisons are evidence. Semantic search results are context, not proof.
- Unresolved gaps are durable typed artifacts or follow-up Beads. An accepted
  candidate may not hide them in free-form TODO comments.

## Migration Contract

A `MigrationContract` is the immutable accepted definition of one
transformation process. It binds:

```text
MigrationContract {
  id
  goal_family_id
  revision
  source_revision
  target_architecture_artifact_digest
  rulebook_artifact_digest
  dependency_map_artifact_digest
  gap_inventory_artifact_digest
  inventory_generator_artifact_digest
  judge_definition_digest
  parity_definition_digest?
  batch_policy
  expensive_check_policy
  audit_panel_policy
  accepted_at
}
```

Every artifact is content-addressed and stored through the existing artifact
boundary. Fixed policies are enums or typed records, not open strings.

The contract separates shared process instructions from per-Part work:

- The migration contract says **how** this transformation must be performed.
- A Part contract says **what** one selected Part must change and verify.
- A Take is one execution under exact revisions of both contracts.

A Part verification or audit receipt for a migration Goal binds both the Part's
task-contract revision and the migration-contract revision. A receipt from an
older revision cannot authorize promotion under a newer revision.

## Contract Revision and Impact

A recurring finding may produce a `ContractRevisionProposal`. It contains the
finding class, supporting occurrences, proposed artifact changes, and a
deterministically computed impact set.

The Conductor may explain or recommend a revision, but it cannot activate one.
Activation is an authoritative `choird` transition following explicit user or
accepted Goal policy approval.

Activation must:

1. persist the new immutable contract revision;
2. persist the exact impacted Part IDs and the reason each Part is included;
3. mark affected authorization receipts stale without deleting evidence;
4. cancel or supersede affected in-flight Takes using the existing cancellation
   ordering rules;
5. schedule new Takes only after the revision event commits; and
6. leave unaffected Parts and the accepted selected set unchanged.

If the dependency map, inventory generator, or source revision changes in a way
that adds or removes work, the current Goal pauses and proposes a follow-up
Goal. Choir does not mutate accepted selection in place.

## Judge Construction

A migration Goal cannot enter production fanout until its judge is proven.

The judge definition contains portable checks that can run against both the
source and transformed systems where applicable. It may combine:

- external-facing tests;
- compiler or type-checker results;
- deterministic output comparisons;
- repository invariants;
- smoke scenarios; and
- bounded performance or artifact-shape checks.

Judge validation is separate work scheduled before the gate. Its receipt binds
the judge definition and evidence for:

- the unchanged source passing all baseline checks;
- every declared deliberately broken control failing for the expected reason;
- portable tests preserving their original assertions; and
- the execution environment and tool identities.

A judge that has no negative controls is unproven. A failed judge gate reports
the missing or stale receipt and cannot launch validation itself.

## Deterministic Inventory

The inventory generator is a versioned executable artifact admitted through
the typed process boundary. Given the captured source revision, it emits a
canonical inventory containing:

```text
MigrationInventory {
  source_revision
  generator_digest
  units[] {
    stable_key
    source_paths[]
    dependency_keys[]
    ownership_claim
    gap_classes[]
    proposed_verification_specs[]
  }
  inventory_digest
}
```

Two runs against the same source revision and generator must produce the same
canonical digest. Drift blocks submission and records both outputs as evidence.

The Conductor uses the inventory and Beads graph to propose a Goal. `choird`
still performs ordinary selection validation, dependency closure, ownership
normalization, and admission. The inventory does not bypass Beads or mint Parts
directly.

Repository state remains the source for resumability: a unit is not considered
complete merely because a provider reports it complete. Durable accepted
receipts and promoted commits determine what remains.

## Disposable Rehearsal

Before production fanout, Choir can run a bounded rehearsal Goal over
representative units. Its purpose is to falsify the contract cheaply.

A rehearsal:

- uses the real sandbox, provider, verification, and audit boundaries;
- samples explicit ordinary, dependency-heavy, and known-gap units;
- may compare results from the rulebook against an unconstrained expert prompt;
- records defects in the rulebook, judge, inventory, and ownership claims; and
- ends in `RehearsalDiscarded`, never promotion or publication.

Candidate commits produced by a rehearsal are non-promotable by type. Their
working roots are removed during ordinary sandbox cleanup after evidence is
sealed; Choir does not promise immediate pruning of unreachable Git objects.
The contract revisions learned from the rehearsal survive. Reusing rehearsal
code in a production Take is forbidden; the production Take must regenerate it
under the accepted contract revision.

## Findings and Loop Repair

Auditors produce typed findings with a stable class and rule reference:

```text
MigrationFinding {
  id
  class
  severity
  rule_reference
  migration_contract_revision
  part_id
  take_id
  candidate_commit
  evidence_digest
  disposition
}
```

The first occurrence normally returns the Part for repair. Repeated occurrences
of the same class across Parts create a pattern observation. Policy may pause
new affected Takes while the Conductor proposes a contract revision.

The durable status projection shows:

- finding counts by class and contract revision;
- affected and potentially affected Parts;
- whether the next action is Part repair, contract revision, judge repair, or
  user input;
- queue depth and active Takes; and
- global checks waiting, running, or invalidated.

This projection is advisory. It may recommend an action but cannot satisfy a
gate or activate a revision.

Prior-Take context is a bounded content-addressed artifact containing the typed
outcome, finding classes, verification failures, and relevant evidence links.
Retries may receive it. Raw transcripts, secrets, and unbounded provider events
are excluded.

## Expensive Global Checks

Some checks are fast enough to run inside each Part. Others serialize the
repository or take long enough that parallel invocation wastes time and causes
contention.

The migration contract classifies each check as:

- `PerPart`: required in the Part verification workflow;
- `AffectedSet`: batched for a set of changed Parts;
- `GoalTree`: run against the current sealed Goal head; or
- `ParitySuite`: compare the sealed Goal tree with the captured source.

`AffectedSet`, `GoalTree`, and `ParitySuite` checks use a goal-scoped exclusive
lease and durable intent/receipt reconciliation. A check key binds the check
definition, exact tree OID, environment digest, and affected-set digest. The
same key is deduplicated after restart; a different tree never reuses its
receipt.

Only the check runner owns the expensive process. Part workers submit patches
and wait for receipts. Verification gates inspect those receipts; they do not
start the compiler or build daemon.

Cancellation follows the existing external-effect rules. If the process
finished before cancellation but its receipt is missing, recovery reconciles
the durable intent and observed artifact before deciding whether another run is
needed.

## Behavioral Parity

When the original program is executable, the strongest final judge is often a
deterministic comparison rather than an implementation-specific test suite.

A `ParityDefinition` declares normalized scenarios, permitted nondeterminism,
redaction, resource limits, and comparison rules. Each scenario runs against
the captured original revision and the sealed Goal tree in isolated
environments. The resulting receipt binds both identities, both output
manifests, the normalizer digest, and the exact comparison result.

Permitted differences must be explicit rules in the contract. An auditor
cannot waive an unexplained mismatch in prose. A mismatch creates a finding and
a repair Part or follow-up Bead.

If the source cannot be executed, the contract must name the substitute judge
and its limitation. Choir reports the weaker evidence in final status rather
than claiming behavioral parity.

## Independent Review Policy

The existing independent audit remains the required baseline for every Part
and the combined Goal tree.

Migration contracts may additionally request an audit panel:

- two auditors receive the same sealed subject in separate Takes;
- policy may require different provider families when both are locally
  available;
- agreement produces an ordinary authorization receipt set;
- disagreement schedules a separate adjudication Take; and
- adjudication binds both finding sets and cannot be performed by either
  candidate author.

This is optional policy, not a second universal completion system. Provider
diversity is useful evidence of independence but does not replace mechanical
verification.

## User Flow

The intended interaction remains conversational:

1. The user discusses a transformation and desired outcome with the Claude
   Conductor.
2. The Conductor proposes judge construction, rulebook, dependency-map,
   gap-inventory, and inventory-generation work as Beads.
3. Choir completes those preparatory Parts and presents their immutable
   artifacts and unresolved decisions.
4. The user accepts the migration contract.
5. Choir validates the judge and runs a disposable rehearsal when policy
   requires it.
6. The Conductor proposes the production Goal from the deterministic inventory
   and existing Beads.
7. Choir schedules Parts sequentially or concurrently according to dependencies
   and ownership claims. Claude and Codex workers may be mixed.
8. Findings return individual Parts for repair or propose a versioned contract
   correction when they reveal a pattern.
9. Serialized global checks and behavioral parity burn down the remaining
   mechanical queue.
10. Existing combined-tree assurance, publication, and final-PR protocols
    complete the Goal.

Command spelling remains a Conductor-adapter concern. Conceptually, the user
may ask: “work on this migration until the accepted inventory and parity judge
are complete.” No arbitrary Part count is part of the product contract.

## Implementation Work

The following work is additional to the completed base architecture:

1. Add the content-addressed `MigrationContract` and revision/impact types.
2. Add judge definitions, negative-control validation, and passive judge gates.
3. Add deterministic inventory execution and canonical replay validation.
4. Add the non-promotable rehearsal lifecycle and cleanup proof.
5. Add typed migration findings, pattern aggregation, and bounded prior-Take
   context artifacts.
6. Bind Part verification and audit authorization to the migration-contract
   revision and invalidate only the computed impact set after revision.
7. Add the goal-scoped global-check lease, deduplicated intent/receipt protocol,
   and status projection.
8. Add the original-versus-target parity runner and normalizer contract.
9. Add optional two-auditor disagreement and adjudication policy.
10. Connect these capabilities to the Conductor without giving the Conductor
    durable authority or native host mutation.

Implementation should land in that order where dependencies require it. Each
slice must remove any superseded temporary code immediately; no alternate
migration scheduler, compatibility format, or prompt-owned state machine may
remain.

## Acceptance

The workflow is complete only when all of the following are executable and
reproducible:

- The same source revision and inventory generator produce byte-identical
  canonical inventories; a drifted output is rejected.
- A judge validation passes the unchanged source and rejects every declared
  broken control. Removing the negative evidence blocks production fanout.
- A rehearsal completes real implementation, verification, and audit work but
  cannot create an integration intent, move a Goal ref, or publish a PR.
- Activating a contract revision persists an exact impact set, stales affected
  receipts, leaves unrelated completed Parts accepted, and never changes Goal
  selection.
- A recurring finding produces one deduplicated pattern observation across
  restart rather than repeated free-form warnings.
- Two Parts requesting the same expensive check for the same tree cause one
  process execution and one canonical receipt. A changed tree requires a new
  execution.
- Cancellation and crash injection before execution, after process completion,
  and before receipt persistence reconcile without duplicate global checks.
- Parity comparison detects a deliberately introduced output difference and
  binds its finding to the exact source, target, scenario, and normalizer.
- Audit-panel disagreement cannot authorize promotion until an independent
  adjudication receipt exists.
- An end-to-end fixture starts from a captured source revision, validates its
  judge, discards rehearsal output, completes a multi-Part migration with at
  least one contract repair, runs a serialized global check, proves parity,
  performs combined-tree assurance, and reaches the ordinary publication
  boundary.
- `moon check --target native`, `moon test --target native`, Choir lint, and all
  existing conformance commands continue to pass.

Every test uses pure state-machine or narrow adapter fixtures where possible.
Real process, Git, provider, and BoxLite cases remain hermetic and operate only
inside dedicated disposable roots.

## Explicit Non-Goals

- A generic workflow language or user-authored state machine.
- A migration-only scheduler parallel to the Goal/Part/Take machine.
- Provider-owned task or completion authority.
- Per-Part pull requests, tmux/Zellij mailboxes, or a required dashboard.
- Hand-patching generated output while leaving a known rulebook defect.
- Treating TODO comments as durable gap tracking.
- Mandatory semantic indexing, Semble, Exa, or network research.
- Cloud execution, multi-user operation, or a usage-priced provider path.
- Automatic post-merge production monitoring. Regressions found after merge
  become evidence for a new follow-up Goal.

## Prior-Art Decisions

The research below refreshes and narrows the broader register in `GOAL.md` for
large-transformation workflows. Repository links are pinned to the inspected
upstream revisions.

| Prior art | Relevant mechanism | Choir decision |
|---|---|---|
| Anthropic large migration process, supplied by the user | judge validation, rulebook and gap inventory, disposable stress test, mechanical queue, loop repair, serialized compiler, behavioral parity | Adopt as the workflow described in this document. Do not copy provider-owned orchestration or scale claims. |
| [OmniGent Polly](https://github.com/omnigent-ai/omnigent/tree/886f9d43ddb6de331cf08992b07a4ad8cebd980e) | supervisor delegates across harnesses and routes diffs to a different-vendor reviewer; policies can apply at several scopes | Adopt optional provider-diverse audit policy and layered contract scopes. Keep `choird`, not the supervisor prompt, authoritative. Reject its GUI, hosted, collaboration, and tmux surfaces as product requirements. |
| [Overstory](https://github.com/jayminwest/overstory/tree/ff38f3f76f084abcc34f519bcaa69580f6e53cf1) | brownfield discovery, base agent instructions plus task overlays, task groups, merge queue, checkpoint/handoff, replay and error views | Adopt deterministic discovery artifacts, HOW-versus-WHAT separation, bounded prior-Take context, and aggregate finding projections. Keep task groups observational. Overstory is archived, so it is design evidence rather than a dependency. |
| [Agent Orchestrator](https://github.com/AgentWrapper/agent-orchestrator/tree/12fc6632d2bdc81533d9a20dbe0370ebb533ce64) | typed reactions to CI failure, review changes, and stuck agents with retry and escalation policies | Adopt typed reaction classification and deduplication. A reaction may schedule ordinary work but cannot make a failed gate satisfy itself. Reject per-worker PR, dashboard, and terminal-session assumptions. |
| [Gas Town](https://github.com/gastownhall/gastown/blob/67a8d72a7aa415cad5b9832bdbba31b6ec026417/CHANGELOG.md) | gate instruction templates, dependency-aware fanout/gather, crash recovery, earlier-run context, and post-squash validation | Adopt versioned judge templates, bounded prior-Take evidence, and post-promotion combined-tree checks. Choir's fixed machine already supplies the lifecycle; formulas, convoys, and role proliferation add no required mechanism. |
| [Beads](https://github.com/gastownhall/beads/tree/70e329d8b381ac95e4cc1af8df2f088460412eaf) | durable graph, dependencies, claims, and queryable work state | Keep as the proposal and dependency source. Generate and claim per Bead/Part; do not assume batch claim atomicity or let inventory generation bypass selection. |
| [Semble](https://github.com/MinishLab/semble/tree/204ae4e6ab0a1ba55f98868c076eb47750b7e2e6) | local semantic search over code, documentation, and configuration with ignore controls | Keep optional and read-only for rulebook or gap research. Never treat semantic retrieval as judge evidence or a startup dependency. |
| Exa | networked semantic research | Keep optional as a fallback in an explicitly admitted research Take when ordinary and provider-supported search are inadequate. Persist provenance when it changes a contract; never use it in implementation, verification, audit, or control-plane work by default. |
| BoxLite | disposable and cloneable isolated execution | Reuse the already-proven sandbox adapter for rehearsal and production Takes. No migration-specific BoxLite layer is needed. |
| Claude and Codex native delegation | internal parallel reasoning and worker sessions | Reuse through the existing driver capabilities. Native task state remains subordinate and disposable. |

### Research conclusions

The surveyed systems repeatedly converge on four useful shapes: separate shared
instructions from task instructions, derive work from a durable graph, react to
mechanical observations, and serialize integration or other globally contended
operations. Choir already implements the graph, reaction authority, isolated
Takes, serialized promotion, and combined-tree assurance.

The genuinely missing work is therefore narrow: make the transformation process
itself durable and revisable; prove its judge; support disposable rehearsal;
aggregate systemic findings; and coordinate expensive global and parity checks.
No surveyed project provides a safer authority model that Choir should import
wholesale.
