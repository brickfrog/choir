# Migration Workflow Charter

Originally developed as the repository-root `GOAL2.md`, this charter is retained
as the architectural record for Choir's migration workflow.

Status: Slices 1 and 2 implemented; later slices remain staged

Depends on: [Goal workflow charter](goal-workflow.md)

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

> A user can discuss a large transformation with the Conductor, validate the
> transformation's rules and judge on representative cases, accept a durable
> migration contract, and let Choir generate and complete the resulting Parts
> until the contract's declared mechanical and behavioral checks pass.

The Conductor exercises judgment and steering. `choird` remains the sole
workflow authority.

## What the Anthropic Migration Process Adds

The useful idea is not “spawn hundreds of agents.” Choir already knows how to
fan work out safely. The useful idea is to make the loop that produces the code
an explicit, testable product object.

[Anthropic's reported workflow](https://claude.com/blog/ai-code-migration)
and its
[reference kit](https://github.com/anthropics/code-migration-kit-with-claude-code/tree/cf91c9d5068d9aaf95a36164169f08c3e636c909)
contribute these mechanisms:

1. Build the judge before implementation fanout. Validate that it accepts the
   original and rejects deliberately broken controls.
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

The report is useful operational prior art, not proof of a universal recipe.
Its companion repository says that it is reconstructed reference code rather
than the artifacts used by the reported migrations, and the reported Bun port
still had nineteen regressions after its pre-merge suite passed. Choir therefore
binds exact declared evidence and reports its limits; it never turns a finite
parity suite into a claim of semantic equivalence.

## Normative Boundaries

- This document extends the [Goal workflow charter](goal-workflow.md); it does
  not replace or fork its Goal, Part, Take, receipt, integration, publication,
  or cancellation protocols.
- Existing accepted Goal selection remains immutable. Adding or removing Parts
  requires a new Goal. Revising shared instructions may invalidate and rerun
  selected Parts, but it may not silently change the selected set.
- Gates remain passive. Missing required contract, qualification, rehearsal,
  verification, audit, or parity evidence causes a typed blocked state. The
  gate never runs the missing work itself.
- New orchestration remains pure. Component runtimes, external transformers,
  parity programs, and replay processes execute only through typed effects and
  `src/exec` adapters; migration code does not call `@sys` or `@process`.
- Migration features reuse the base command-artifact, `ProcessExecution`,
  verification-slot, Goal assurance, lease, and receipt protocols. This charter
  adds no parallel context-delivery, global-check, parity-receipt, or replay
  receipt subsystem.
- Fixed migration domains are enums or typed records, and new failure paths use
  `ChoirError` suberrors rather than `Result[..., String]`.
- Provider sessions and native subagents remain disposable execution details
  inside a Take. They do not own the migration contract or queue.
- The normal product path uses the locally authenticated Claude and Codex
  clients already supported by Choir. No usage-priced provider path is added by
  this workflow.
- Beads remains the MVP durable source of proposed work and dependency edges.
  A deterministic inventory may propose Beads, but only separately accepted
  open Beads become Parts through the ordinary `GoalProposal` and
  `SelectionDecision` path. A future base crystallized-spec selection source may
  be used once it exists; this workflow does not depend on it.
- Semble and external search remain optional, explicitly admitted research
  capabilities. Neither is required for execution or correctness.
- Exact source reads, deterministic scripts, compilers, tests, and parity
  comparisons are evidence. Semantic search results are context, not proof.
- A passed judge or parity suite proves only the declared checks over their
  captured scenarios and environments. Choir reports that scope and any
  declared blind spots; it does not claim whole-program equivalence.
- Unresolved gaps are durable typed artifacts or follow-up Beads. An accepted
  candidate may not hide them in free-form TODO comments.

## MoonBit Leverage

MoonBit does not make orchestration correct merely by being less common than
Rust, Python, or TypeScript. Choir already receives the ordinary benefits of a
typed language through closed enums, suberrors, exhaustive matching, immutable
domain values, and a pure control plane around injected effects. Its immediate
advantage here is cheap conformance over that pure core.

### Immediate leverage: cross-target state-machine properties

Migration contracts, inventory dispositions, impact calculations, gate inputs,
and finding projections should remain in target-clean packages that import no
`src/exec`, `src/sys`, async runtime, or host capability. Closed records and
enums that are safe to generate may implement `Arbitrary` and, where a sound
smaller-case relation exists, `Shrink` for a pinned `moonbitlang/quickcheck`
property suite under `moon test --target all`.

The properties cover canonical projection, stale-evidence rejection, impact-set
soundness over generated graphs, and identical fixed byte fixtures under native
debug/release, `wasm`, `wasm-gc`, and `js`. The matrix records
`moon version --all`; compiler diversity is not independent implementation
evidence. Failures retain QuickCheck replay state and, where sound, a minimized
counterexample as a fixed fixture. Random generation never chooses a production
transition or substitutes for receipts.

New migration digests use explicit versioned encoders and byte fixtures;
derived JSON remains transport and diagnostic data. Base records reuse their
normative identity. If one lacks it, the implementing slice adds and fixtures it
explicitly rather than claiming inherited machinery. This approach is not
unique to MoonBit, but it is cheap because Choir's authoritative model is
already MoonBit; host adapters and the daemon remain native.

### Bounded experiments

- **Portable preflight:** compile one pure `CandidatePreflight` to native and an
  import-free Wasm component for non-authoritative feedback inside a Take. Start
  only after a baseline shows material preflight-rejectable retries; a separate
  charter must predeclare sample, rejection classes, toolchain/build cost,
  expected provider-time savings, import checks, forged-success control, and a
  kill threshold. Native server validation remains authoritative.
- **Executable proof:** apply experimental `moon prove` to one real pure
  admission function. Keep it only with no `proof_axiomatized` items, a disclosed
  trusted/assumed dependency surface, pinned MoonBit/Why3/solver identities, and
  unchanged runtime, overflow, canonical-byte, property, and all-target tests.
  Mathematical-integer proof is bounded defense-in-depth, not a receipt or a
  claim about codecs, hashes, adapters, or effects.
- **Portable replay:** comparing one pure decision under native and Wasm may
  expose backend drift but shares the same source and currently has no consumer.
  Add no replay receipt, service, or `AssuranceKernel` unless a real defect or
  offline-verifier requirement appears; an experiment can use ordinary
  verification slots and `ProcessExecution`.

Virtual packages remain experimental and plain-function-only, so injected
capabilities and target-specific files remain normative. Experimental LLVM and
a native dynamic-plugin ABI are outside this charter.

## Feasibility and Workflow Shape

Not every repository-wide change needs this machinery. Before preparatory
mutation, the Conductor prepares a read-only, content-addressed feasibility
report from admitted observation and research capabilities. The report records:

- the concrete reason to migrate and a valid `Decline` outcome;
- whether the work is a `MechanicalEvolution`, `StructurePreservingPort`,
  or `ArchitectureRedesign`;
- the expected unit granularity and a bounded inventory estimate;
- which work can be expressed as deterministic transformations and which needs
  model judgment;
- the available judge, the cost of making it portable, and known evidence
  gaps;
- the expensive-check topology and expected local machine pressure; and
- an initial capacity range from available repository history or a declared
  benchmark, with `Unknown` as a valid result rather than invented precision.

After a bounded pilot or rehearsal exists, a revised report may replace that
range with units times the observed per-unit distribution and its stated sample
limits. The pre-mutation feasibility report never calls an unrun pilot
“measured,” and no estimate transfers another project's agent-count or token
claim.

The report advises the user and Conductor; it authorizes nothing. `choird`
content-addresses it when ingesting the proposal and binds it only if the user
accepts the later migration contract. If a future workflow needs a separate
provider-backed feasibility session, it must add an explicit auxiliary
`TakePurpose`; it may not overload `Implementation`, verification, or a gate.

The accepted workflow shape becomes part of the migration contract.
Structure-preserving ports may use file- or package-level rule bakeoffs.
Architectural redesigns use subsystem units and a disposable integrated
rehearsal because line-by-line translation comparison is not meaningful.
Mechanical evolutions prefer an admitted codemod or semantic transformation
before any agent implementation.

## Migration Contract

A `MigrationContract` is the immutable accepted definition of one
transformation process. A preparatory Goal establishes its draft lineage;
rehearsal and production Goals bind an accepted revision from that lineage.
Every Goal still has its own immutable selected set, base, and integration
target. The lineage is provenance and status grouping, not a scheduler above
the Goal machine.

The contract binds:

```text
MigrationContract {
  id
  migration_lineage_id
  revision
  source_revision
  workflow_shape
  feasibility_report_artifact_digest
  target_architecture_artifact_digest
  rulebook_artifact_digest
  dependency_map_artifact_digest
  gap_inventory_artifact_digest
  inventory_generator_artifact_digest
  qualified_inventory_artifact_digest
  transformation_plan_artifact_digest
  context_assembly_policy_digest
  judge_definition_digest
  judge_qualification_assurance_record_digest
  parity_definition_digest?
  validation_plan_digest
  rehearsal_policy
}
```

Every artifact is content-addressed and stored through the existing artifact
boundary. Fixed policies are enums or typed records, not open strings.
Batch size, concurrency, and resource admission remain ordinary
`GoalPolicyRevision` fields. Changing which evidence is required instead creates
a new validation-plan and migration-contract revision.

`MigrationContractRef` binds contract ID, lineage ID, revision, and exact
contract artifact digest. A revision number or lineage ID by itself is never an
authorization identity.

Acceptance metadata is not mixed into the semantic artifact. A separate
authoritative `MigrationContractAcceptance` record binds the exact reference,
the durable user-input or preaccepted policy authorization, event sequence, and
`accepted_at`. The initial contract requires explicit user acceptance. Replay
returns that record; it does not regenerate a timestamp or silently activate an
equal-looking contract.

`RehearsalPolicy` is `NotRequired` or `Required(sample_artifact_digest)`. The
sample artifact is accepted with the contract and contains exact inventory
stable keys plus their ordinary, dependency-heavy, or known-gap strata. Missing
strata are explicit. Runtime randomness or a provider cannot choose a more
convenient rehearsal sample after acceptance.

The contract separates shared process instructions from per-Part work:

- The migration contract says **how** this transformation must be performed.
- A Part contract says **what** one selected Part must change and verify.
- A Take is one execution under exact revisions of both contracts.

The transformation plan classifies each inventory unit as irrelevant,
deterministic, agent-assisted, or unresolved. It does not contain an open-ended
command or permit a prompt to choose its own execution class. A deterministic
entry binds a content-addressed `DeterministicTransformSpec`: a registered tool
or trusted Goal-contract/base-tree script, literal argument and input
projection, output normalizer, and replay/idempotence policy. For an admitted
Take, `choird` materializes that definition into the existing Take-bound
`ProcessSpec`; `ProcessExecution` then records its
`validated_process_spec_digest`. Naming a tool or component alone is not an
executable contract.

Each migration Part's `TaskContractRevision` includes an exact
`MigrationContractRef`. Existing verification and audit receipts already bind
the task-contract digest, so changing an impacted Part's reference makes only
that Part's earlier evidence stale without adding migration-specific receipt
fields. Unaffected Parts keep their prior task-contract revisions and receipts;
the activation record proves why they were carried forward, and final status
reports the effective migration revision per Part rather than pretending the
Goal has one homogeneous revision.

### Explicit base-machine additions

This extension adds four explicit base seams: an
immutable completion-mode field in the accepted Goal contract; a typed cause in
the cancellation request and summary; `Publishable` checks in publication and
final-PR intent authorization; and a post-assurance runner branch that submits
ordinary cancellation for `EvidenceOnly` Goals.

```text
GoalCompletionMode
  Publishable
  EvidenceOnly(evidence_binding_digest)

GoalCancellationCause
  UserRequested
  EvidenceOnlyCompleted(evidence_binding_digest,
                        assurance_record_digest)
  SupersededByContractRevision(supersession_artifact_digest)
```

The completion mode is immutable at Goal acceptance. The cause is carried by
the base cancellation request and the terminal summary required by the
[Goal workflow charter](goal-workflow.md);
current cause-less user cancellation maps to `UserRequested` when this slice is
built.
These additions do not create another Goal lifecycle, terminal state, terminal
outbox family, or cancellation protocol. Publication and final-PR intent
authorization additionally require `Publishable`.

## Contract Revision and Impact

A recurring finding may produce a `ContractRevisionProposal`. It contains the
finding class, supporting occurrences, proposed artifact changes, and a
deterministically computed impact set. A Part may be excluded only when the
changed artifact has no dependency path to that Part's context manifest,
transformation rule, mutation declaration, or verification plan. Uncertain
dependency is inclusion, not permission to carry evidence forward.

The Conductor may explain or recommend a revision, but it cannot activate one.
Activation is an authoritative `choird` transition following explicit user or
accepted Goal policy approval.

Activation must:

1. persist the new immutable contract revision;
2. persist the exact impacted Part IDs and the reason each Part is included;
3. persist the invalidation relation so gates derive affected authorization
   receipts as stale without editing or deleting evidence;
4. classify whether the revision can apply to the current Goal without changing
   its accepted promotion cardinality;
5. cancel or supersede affected in-flight Takes using the existing cancellation
   ordering rules only when in-place application is valid;
6. schedule new Takes only after the application event commits; and
7. leave unaffected Parts and the accepted selected set unchanged.

The activation record binds the old and new migration revisions, changed
artifact digests, exact impacted Part set with per-Part reasons, and every
carried-forward task-contract revision. `choird` creates new
`TaskContractRevision` values only for impacted Parts that are not integrated.
A judge or generally applicable Part-validation change impacts every Part to
which it applies; Goal-level verification changes update the ordinary assurance
policy before sealing.

The base protocol permits at most one winning candidate and integration receipt
per Part. Therefore a revision that impacts an already integrated Part cannot
apply in place. While the user considers the proposal, they may use the existing
explicit `GoalPolicyPause`; no finding, revision precondition, or gate installs
that pause automatically.

If the user accepts supersession, the cancellation-request transaction persists
a typed `MigrationSupersession` artifact binding the old and new contract
references, impacted integrated Parts, Goal ID, head observed at the decision,
and installed cutoff sequence. It then uses the existing cancellation path with
`SupersededByContractRevision(supersession_artifact_digest)`. The Goal reaches
ordinary terminal `Canceled` after effect reconciliation and claim release; it
does not occupy a fictional migration-paused state. The Conductor may then
propose a follow-up Goal under the new revision from the exact terminal preserved
head. A pre-cutoff integration reconciled during cancellation may make that
terminal head differ from the head observed at the supersession decision.
Supersession and ordinary success retain the base terminal compare-and-set: if
`Succeeded` wins first, the revision cannot relabel that Goal and applies only
to a separately accepted follow-up.

After typed cancellation is terminal, the Conductor may propose a
content-addressed `MigrationContinuationRef` binding the prior Goal ID,
supersession artifact, terminal `cancellation_summary_id`, terminal preserved
head, and new `MigrationContractRef`. Every proposed migration task contract in
that follow-up carries the same continuation reference. `choird` validates the
already-durable summary and exact expected base during selection. The existing
`SelectionDecision` then captures the base and accepted task contracts, so it
needs no new cancellation-summary field. Missing or inconsistent continuation
provenance rejects the proposal; selection does not create it.

The same sequence applies after branch sealing or when the change affects base,
selection, or integration target. A gate neither creates the follow-up Goal nor
reopens the integrated Part. The MVP proposal uses a new repair Bead identity;
it never reuses a closed source Bead as open work. No continuation Take starts
until the old Goal is terminally canceled, its claims are released, and the new
`SelectionDecision` has committed. Status distinguishes this typed
supersession cause from `UserRequested`. The migration lineage may span such
Goals; each Goal keeps its own immutable selection and promotion order.

A proposal that changes the judge definition or negative controls cannot become
an active production revision until a new ordinary preparatory Goal supplies
matching qualification evidence. The activation precondition does not schedule
that Goal.

If the dependency map, inventory generator, or source revision changes in a way
that adds or removes work, accepted supersession uses the same typed
cancellation-and-follow-up sequence. Choir does not mutate accepted selection
in place.

Candidate generation or validation may reveal an obligation that conservative
discovery missed. If it is wholly covered by an already selected Part's exact
mutation declaration and dependency closure, and that Part is not integrated,
it becomes a typed finding and a new Take for that Part under any required
task-contract revision. An integrated Part follows the continuation rule above.
If the obligation needs a new Part, path, dependency, or target, `choird`
records an `OutOfSelectionObligation`; the Conductor may propose a follow-up
Goal. Adaptive discovery may improve the plan; it never grants itself selection
authority.

## Judge Construction

A migration Goal cannot enter production fanout until its judge is qualified
under the exact evidence contract below.

The judge definition contains portable checks that can run against both the
source and transformed systems where applicable. It may combine:

- external-facing tests;
- compiler or type-checker results;
- deterministic output comparisons;
- repository invariants;
- smoke scenarios; and
- bounded performance or artifact-shape checks.

Judge qualification uses the ordinary Goal machine rather than a new Take or
receipt family. A preparatory Goal produces the judge, rulebook, fixtures, and
negative controls. Its existing Part and Goal verification plans exercise:

- the unchanged source producing the captured baseline outcomes;
- every declared deliberately broken control failing for the expected reason;
- portable tests preserving their original assertions; and
- the execution environment and tool identities.

The preparatory Goal then receives the ordinary combined audit. At migration-
contract acceptance, `choird` validates and binds the content-addressed
`GoalAssuranceRecord` artifact, exact qualifying Goal and seal, judge definition,
and bound source identity. The record must be at `GoalAudited` and contain its
complete Goal-verification authorization set plus passing Goal-audit receipt.
The qualifying Goal itself must be terminal `Succeeded` or terminal `Canceled`
with the exact `EvidenceOnlyCompleted` cause. An active
`GoalExecutionAssured` Goal and a record captured earlier in the assurance
machine are not qualifying evidence. For an evidence-only preparatory Goal, the
completion binding is the canonical digest of the qualifying Goal, seal, judge
definition, and source identity; contract acceptance validates that exact
binding in the terminal cause.

Production admission is a pure precondition over that immutable qualification
reference and the accepted migration contract. Missing, corrupt, failed, or
differently digested evidence blocks fanout; admission never launches the
preparatory work. Because qualification binds a terminal Goal, it has no live
cross-Goal lifecycle predicate that can silently change during production.
Replacing or revoking the judge requires an explicit migration-contract
revision and follows the impact/supersession rules above.

Any judge, fixture, or generator that production reads from the repository must
exist in the contract's captured `source_revision`. When preparation changes the
tree, the user may choose the preparatory Goal's assured sealed tree as the
production base or merge it and capture the resulting revision; the contract
cannot qualify a judge from one tree while running against the pre-preparation
tree.

A judge that has no negative controls is unqualified.

Negative controls may be hand-authored migration faults or a bounded,
content-addressed mutant set. They are selected for the contract's declared risk
classes; an unbounded repository-wide mutation campaign is neither required nor
implied. Controls are immutable fixtures applied only inside the verification
sandbox's declared scratch roots; they never mutate the source subject or real
checkout. A surviving control creates a judge defect and blocks fanout.

Pre-existing source failures are never silently treated as passing. The judge
definition either requires a clean baseline or binds each expected baseline
failure by scenario and normalized outcome. Later comparison classifies
`MigrationRegression`, `InheritedSourceFailure`, `EnvironmentMismatch`,
and `JudgeDefect` separately.

Even a validated judge remains bounded evidence. Final status reports its
scenario count, negative-control classes and results, excluded surfaces,
permitted nondeterminism, and any substitute oracle. The word “parity” in this
document means parity under that exact declared definition.

## Ordered Validation Plan

Migration candidates often fail cheaply before they need a compiler, broad
test suite, or parity run. The contract therefore orders existing
`VerificationSpec` values from cheapest to most expensive. Each step declares
its exact `PartCandidate` or `GoalTree` subject, prerequisites, resource limits,
and cost rank.

Typical steps are:

1. output and mutation-shape validation;
2. parser or AST validation;
3. focused build or type-check;
4. affected regression tests when the repository can compute them
   deterministically;
5. combined-tree build and smoke scenarios; and
6. source-versus-target parity scenarios.

The MVP has no mutable `AffectedSet` verification subject. Part checks run in
ordinary Part-verification slots; combined checks and parity run once against
the sealed Goal tree. A future intermediate affected-set subject would need its
own immutable tree identity and invalidation proof before it could be added.

Failure records the typed observation and stops later work for that exact
candidate; it does not erase evidence or bless a different candidate. A cheap
validator cannot stand in for an omitted expensive one. Ordering optimizes
resource use only after the accepted contract has declared which checks are
required. Existing verification authorization slots and `ProcessExecution`
records provide uniqueness, crash recovery, and exact process evidence.

## Deterministic Inventory

The inventory generator is a versioned executable artifact admitted through
the typed process boundary. Given the captured source revision, it emits a
canonical inventory containing:

```text
MigrationInventory {
  schema_version
  source_revision
  generator_digest
  units[] {
    stable_key
    source_paths[]
    dependency_keys[]
    ownership_claim
    gap_classes[]
    disposition
    transformation_rule_ids[]
    proposed_verification_specs[]
  }
}
```

The preparatory Goal owns generator creation and the first inventory artifact.
One ordinary verification spec and authorization slot use an eligible
registered comparison runner or trusted base-tree executable. That runner
invokes the generator twice from the same immutable source in two fresh scratch
roots, records both outputs, and fails unless their canonical digests match. A
candidate-created generator may be exercised through an admitted registered
build/test runner; it does not become its own authorizing verifier. This is one
verification subject/spec/receipt, not two competing authorizations. The
production proposal consumes the qualified inventory artifact. No production
gate runs the generator.

Two runs against the same source revision and generator must produce the same
canonical digest. Drift blocks submission and records both outputs as evidence.

`stable_key` is unique under a versioned derivation. Units, paths, dependency
keys, gaps, rules, and verification specs have canonical ordering; repository
paths use the base `RepoPath` rules. Every dependency key resolves to another
unit or an explicit external dependency. A discovered unit remains present with
one typed disposition, so “irrelevant” and “unresolved” cannot disappear from
the denominator.

The Conductor uses the inventory and Beads graph to propose a Goal. `choird`
still performs ordinary selection validation, dependency closure, ownership
normalization, and admission. The inventory neither rewrites Beads nor bypasses
`GoalProposal` and `SelectionDecision`; it cannot mint Parts directly.

The accepted transformation plan deterministically projects each ready unit to
a proposed Bead specification: a lineage/revision/stable-key idempotency key,
typed instruction references, dependency IDs, mutation declaration, and
verification specs. After the user accepts that plan, the Conductor uses the
ordinary task-mutation surface to materialize those Beads before proposing a
Goal. An existing exact proposal is adopted; conflicting content blocks.
`choird` selection, admission, and migration gates never create the Beads they
require. `Irrelevant` units create no Bead, and `Unresolved` units create gap
work or require user input rather than masquerading as implementation-ready.

Repository state remains the source for resumability: a unit is not considered
complete merely because a provider reports it complete. Durable accepted
receipts and promoted commits determine what remains.

Migration status is a pure projection across the qualified inventory and its
bound Goals. It reports checks passed only when every unit is either proven
irrelevant or mapped to accepted integrated evidence under its effective
contract, no unresolved unit remains, and the latest required Goal assurance
and parity evidence pass. For work integrated in one Goal, the receipt must
appear in that Goal's durable integration chain. Carry-forward from a
superseded Goal counts only when the next accepted `SelectionDecision` captures
the prior Goal's exact preserved head as its base and every accepted migration
task contract binds the same validated `MigrationContinuationRef`. If either
identity differs, earlier integration evidence is not carried forward. The
projection may report the next missing proposal or Goal, but it is not a
scheduler, gate, or second completion authority.

### Hybrid transformation cascade

Deterministic discovery and transformation cover regular cases; providers
handle only residual variation requiring judgment. Once process-only candidate
production exists, the fixed order is:

1. deterministic discovery produces candidate locations and dependencies;
2. typed applicability rules classify proven irrelevant, mechanically
   transformable, agent-assisted, and unresolved units;
3. admitted deterministic transformations handle the cases they cover;
4. provider Takes receive only the residual units that require judgment; and
5. every candidate enters the same independent verification, audit, promotion,
   and combined-tree assurance path regardless of how it was produced.

`UnitDisposition` returns only
`Irrelevant(rule_id)`, `Mechanical(rule_id)`,
`AgentAssisted(reason_class)`, or `Unresolved(gap_class)`, with these closed
subdomains:

```text
AgentAssistedReason
  SemanticJudgment
  CrossUnitContext
  ArchitecturalChoice
  UnsupportedMechanicalTool
  MechanicalQualificationFailed

UnresolvedGapClass
  MissingRule
  AmbiguousApplicability
  MissingDependency
  OwnershipConflict
  UnsupportedLanguage
  MissingJudge
  ContextLimit
```

Free-form rationale is evidence only. Adding a class is a schema revision with
canonical fixtures; a provider cannot invent one or select its own lane. The
first release labels every provider-executed unit `AgentAssisted`, even when the
work is repetitive.

A later generic base extension may avoid a provider harness for an exact
supported producer:

```text
TakePurpose +=
  DeterministicImplementation(part_id, task_contract_revision_id,
                              deterministic_transform_spec_digest)
```

It belongs to a selected Part, materializes the accepted transform as a
Take-bound `ProcessSpec`, runs through the typed sandbox process boundary with
no harness, and still ends in ordinary candidate normalization. Replay,
mutation-boundary, and declared-idempotence checks precede separate verification
and audit; the transform mints no receipt. Until this extension exists, Choir
admits only agent-assisted implementation and hides no mutation inside
discovery, verification, audit, or a gate.

Every disposition remains in the inventory with its rule/reason identity.
False positives, punts, context limits, unsupported languages, and missing tools
stay in the denominator.

### Progressive mechanization from accepted examples

[REFAZER](https://www.microsoft.com/en-us/research/publication/learning-syntactic-program-transformations-examples/)
shows that examples can synthesize AST transformations;
[Getafix](https://arxiv.org/abs/1902.06111) and
[SPINFER](https://www.usenix.org/conference/atc20/presentation/serrano) show
context-sensitive false positives, misses, and ranking ambiguity. This is
therefore deferred until a real codemod can anchor a tool-specific charter. Its
durable invariants are:

- the accepted rule-producing task contract precommits source, eligible
  examples, labels, split, training/evaluation partitions, and tool identity;
- positive examples bind exact before/accepted-after evidence, while negative
  examples are user-accepted no-change expectations—not absence, punts, or
  `Irrelevant` labels;
- synthesis receives only training data in a tree-only workspace without Git or
  Choir history; and
- ordinary verification and audit receive the sealed disjoint evaluation set
  and bind applicability, misses, unexpected edits, replay/idempotence,
  mutation boundary, engine, parser, toolchain, and normalizer.

This enforces only Choir's recorded artifact/sandbox separation; it cannot
detect upstream model contamination or shared generator bias. Report measured
performance on that corpus and toolchain, never generalization. Known label
exposure invalidates evaluation; no fictional detector covers unknown exposure.

The five ordinary steps are: a preparatory Goal authors one recipe in a mature
DSL; verification and audit qualify the committed corpus; normal assurance
makes it reviewable; the user accepts a contract revision binding the exact
`DeterministicTransformSpec`; and only a newly selected Goal activates
`Mechanical(rule_id)` for predeclared stable keys. There is no synthesis
receipt, mid-Goal activation, self-classification, automatic fallback, or
gate-triggered synthesis. Runtime matches outside the accepted keys are
undeclared mutation; failures use ordinary evidence and explicit revision or
follow-up rules. Do not invent a MoonBit codemod DSL merely to stay monolingual.

## Exact Take Context

Accepting a durable rulebook is insufficient if workers receive an ambient,
truncated, or prompt-specific approximation of it. Before a migration Take is
launched, Choir deterministically builds a content-addressed
`PartContextManifest`:

```text
PartContextManifest {
  migration_contract_ref
  part_task_contract_revision_id
  part_task_contract_digest
  context_assembly_policy_digest
  rulebook_section_digests[]
  dependency_neighborhood_digest
  applicable_gap_entry_digests[]
  source_path_manifest_digest
  prior_take_context_digest?
}
```

The context assembly policy defines canonical ordering, size limits, required
sections, and typed failure behavior. It selects only contract material
applicable to the Part; it does not copy a growing global document blindly into
every prompt.

```text
CommandPreparationBlock
  MissingRequiredArtifact(artifact_digest)
  StaleBinding
  SizeLimitExceeded(actual_bytes, limit_bytes)
  DigestMismatch
  UnsupportedTemplate
```

The corresponding failure path is a `ChoirError` suberror, not a free-form
string.

This charter introduces deterministic command-artifact preparation; the
[Goal workflow charter](goal-workflow.md) defines
the artifact digest fields but not a builder for their bytes. The pure builder
binds the exact Take and purpose, canonical execution subject, current task and
Goal contract digests, `MigrationContractRef` when present, immutable
role-specific command-template digest, provider surface/profile digest,
context-assembly policy, and the applicable Part manifest or Goal-context
projection. It emits exact command bytes plus a versioned provenance record
containing those inputs, the resulting artifact digest, and byte length.

After Take admission and before planning a `HarnessSessionStartIntent` or
`HarnessCommandIntent`, a `choird` command-preparation transition persists the
artifact through the existing artifact effect/adapter boundary. It is an
ordinary precursor step, not a validation gate. The existing harness intent
fields then carry the resulting
`initial_command_artifact_digest`/`command_artifact_digest`; no second launch
protocol or context receipt is added.

Intent authorization gains a passive predicate over an already-persisted
preparation: its Take, purpose, subject, contracts, provider profile, context
projection, size policy, and command digest must still match exactly. Missing,
stale, oversized, or partially staged context records a typed preparation block
and creates no authorized harness effect. The predicate never invokes the
builder or repairs its inputs. The durable preparation proves which bytes and
immutable context Choir supplied; it cannot prove that a model attended to
them. Later mechanical checks and independent audit establish conformance.

Auditors receive the relevant rule and gap references through their own exact
command artifact while remaining independent from the implementation transcript.
Existing Part-audit receipts bind the task contract, which already contains the
`MigrationContractRef`; Goal-audit receipts bind the sealed tree and exact
integration/verification evidence set. Neither gains a redundant
context-manifest field.

For combined Goal verification, the new builder starts from the exact immutable
Goal-verification subject and seal. For Goal audit, it starts from the complete
canonical `AuditSubject::GoalCandidate`, including its contract, seal, and
receipt-set digests. It follows the durable integration receipt order to resolve
each Part's effective task-contract and migration-contract reference,
deduplicates shared sections, and orders the projection canonically. Missing or
oversized required combined context blocks command preparation; it is not
silently summarized. A process-only verification instead binds the same
accepted inputs through its `ProcessSpec` and `input_artifact_set_digest`; it
does not manufacture a harness command merely to obtain a context digest.

## Disposable Rehearsal

Before production fanout, Choir can run a bounded rehearsal Goal over
representative units. Its purpose is to falsify the contract cheaply.

The rehearsal's accepted Goal contract uses the generic completion mode already
declared above:

```text
RehearsalBinding {
  migration_contract_ref
  sampled_inventory_digest
}

GoalCompletionMode::EvidenceOnly(rehearsal_binding_digest)
```

Scheduling, implementation, verification, audit, promotion, sealing, and Goal
assurance use the ordinary machine. Publication and final-PR intent preparation
require `GoalCompletionMode::Publishable`, so an evidence-only Goal is
non-publishable from acceptance rather than becoming non-publishable at the end.

When the rehearsal reaches exact `GoalExecutionAssured`, the ordinary Goal
runner's post-assurance branch validates the immutable completion binding and
assurance-record digest, then submits the existing cancellation transition with
`EvidenceOnlyCompleted(rehearsal_binding_digest,
assurance_record_digest)`. Cancellation follows the base cutoff,
reconciliation, claim-release, terminal `Canceled`, and cancellation-outbox
path. This branch runs no missing work and adds no rehearsal scheduler, gate,
terminal state, terminal event, or receipt family. A competing cancellation
request linearizes through the same compare-and-set; only the exact
`EvidenceOnlyCompleted` cause qualifies production.

A rehearsal:

- uses the real sandbox, provider, verification, and audit boundaries;
- samples explicit ordinary, dependency-heavy, and known-gap units;
- records defects in the rulebook, judge, inventory, and ownership claims; and
- can never enter production integration or publication.

Before Goal selection, the Conductor explicitly proposes rehearsal-only Beads
keyed to the sampled inventory units. They have distinct IDs from production
Beads and Parts. Closing them through ordinary Part integration therefore cannot
claim or close the production queue. No selection or production-admission
predicate creates these Beads. A later base crystallized-spec source may replace
them only as a complete existing selection seam.

A finding or failed verification leaves ordinary failed evidence and an
applicable base Active condition; it produces no `RehearsalEvidenceRef`. After
the evidence is inspected, the user may cancel it, revise the contract, and
accept another rehearsal. Only a rehearsal that reaches exact Goal assurance
and then terminates through the typed evidence-only cancellation can qualify the
matching contract revision for production. `UserRequested` cancellation never
qualifies it.

A multi-Part rehearsal must be able to exercise composition and combined-tree
checks; otherwise it is not an end-to-end rehearsal. It uses its ordinary Goal
ref (`refs/heads/choir/goals/<goal-id>`) and ordinary promotion chain. No
rehearsal ref class or production integration target is added. Its distinct
Goal, Beads, Parts, selection, and receipts authorize only that rehearsal's
assurance; no rehearsal candidate or integration receipt is reusable by a
production Goal.

Ordinary terminal cleanup removes disposable runtime roots, but durable state,
artifacts, and exact local Goal and seal-witness refs remain under the base
retention rules. Only explicit archival or purge may delete them. Contract
revisions learned from the rehearsal survive, but a production Take must
regenerate its change under the accepted contract revision.

When rehearsal is required, the production `GoalProposal` includes an exact
`RehearsalEvidenceRef` containing the rehearsal Goal ID, migration-contract
reference, sampled-inventory digest, completion-binding digest,
assurance-record digest, and terminal `cancellation_summary_id`. The Conductor
proposes that reference from read-only terminal state; the accepted Goal
contract binds it. Admission checks that the already-durable Goal is terminal
`Canceled`, its immutable completion mode and cancellation cause contain those
exact bindings, and its assurance record matches. It schedules no rehearsal
work. A contract revision makes the reference inapplicable and requires another
rehearsal when the new revision's policy still requires one.

## Findings and Loop Repair

Auditors produce typed findings under closed domains:

```text
MigrationFindingClass
  RuleViolation | RuleGap | JudgeFalsePositive | JudgeFalseNegative
  InventoryOmission | DependencyMismatch | OwnershipMismatch
  ApplicabilityMismatch | BehavioralMismatch | UnsupportedCase

MigrationFindingSeverity
  Advisory | Blocking

MigrationFindingDisposition
  RepairPart | ReviseContract | ReviseJudge
  FollowUpGoalRequired | AwaitUserDecision

MigrationFindingAnchor
  Rule(rule_id) | JudgeScenario(scenario_id) | InventoryUnit(stable_key)
  DependencyEdge(source_stable_key, target_stable_key)
  OwnershipClaim(stable_key) | ParityScenario(scenario_id)
  Contract(migration_contract_ref)

MigrationFinding {
  schema_version
  id
  pattern_key
  class
  severity
  anchor
  audit_take_id
  audit_subject_digest
  evidence_digest
  disposition
}
```

This is the schema of the existing `AuditResult.findings_artifact`, not a new
receipt or parallel audit-result table. The enclosing `AuditResult.audit_subject`
remains the complete base `PartCandidate` or `GoalCandidate`, including all
task/Goal contract, seal, and receipt-set identities. The artifact repeats only
that complete subject's digest; it does not introduce a weaker migration-shaped
subject.

`pattern_key` is the digest of a versioned canonical projection containing
`schema_version`, `class`, and `anchor`. Subject-specific Goal, Part, Take,
candidate, and receipt IDs remain in each occurrence's audit subject and
evidence but are intentionally excluded from the pattern projection. Thus the
same rule violation or parity-scenario mismatch can aggregate across Parts,
while two unrelated findings that merely share a broad class cannot. New
classes or anchor shapes require a schema revision and fixed canonical fixtures.
Severity and disposition route work but never waive the enclosing audit outcome
or authorize a transition. `Blocking` requires a nonpassing `AuditResult`;
subject/disposition combinations that cannot be acted on are invalid.

A blocking Part-audit occurrence normally returns that non-integrated Part for
repair. A blocking Goal-audit occurrence is bound to the sealed tree and
therefore blocks publication rather than reopening a Part; the Conductor may
propose a follow-up Goal from that evidence.
Occurrences with the same `pattern_key` create one pattern observation across
restart. While the Conductor proposes a contract revision, the user may accept
an explicit `GoalPolicyRevision` that pauses new affected Takes; neither the
finding projection nor a gate installs the pause. The integrated-Part rule above
still determines whether that revision can apply in the current Goal.

The advisory status projection reports counts by class and effective contract,
affected Parts, the next repair/revision/input route, queue and active-Take
counts, and waiting/running/invalidated verification slots. It cannot satisfy a
gate or activate a revision.

Prior-Take context is a bounded content-addressed artifact containing the typed
outcome, finding classes, verification failures, and relevant evidence links.
Retries may receive it. Raw transcripts, secrets, and unbounded provider events
are excluded.

## Expensive Global Checks

Some checks are fast enough to run inside each Part. Others serialize the
repository or take long enough that parallel invocation wastes time and causes
contention.

The [Goal workflow charter](goal-workflow.md) already provides the needed
ownership. Per-Part checks are ordinary Part-verification slots. Full builds,
combined smoke tests, and parity are
ordinary Goal-verification slots against the sealed `GoalTree`. Their existing
subject/spec uniqueness and `ProcessExecution` records prevent duplicate
authorization and reconcile crashes. This charter adds no global-check lease,
process owner, intent, receipt, or recovery loop.

The first release accepts the cost of running required combined checks once at
Goal assurance rather than inventing mutable intermediate batch subjects. If a
real tool requires singleton access to a compiler daemon, license, device, or
shared cache, the smallest general extension is a typed exclusive resource
claim on ordinary Take admission. It must reuse the Take lease and cancellation
protocol and be justified by a measured contention case.

## Behavioral Parity

When the original program is executable, a deterministic comparison can add
useful final evidence beyond an implementation-specific test suite.

A `ParityDefinition` declares normalized scenarios, permitted nondeterminism,
redaction, resource limits, comparison rules, and the captured source identity.
It becomes an ordinary Goal `VerificationSpec`. The spec digest binds the
definition and source; its evidence artifact binds both output manifests, the
normalizer, and comparison results. The existing Goal-verification receipt
binds that spec and the sealed `GoalTree`; there is no parity-specific receipt.

Permitted differences must be explicit rules in the contract. An auditor
cannot waive an unexplained mismatch in prose. A mismatch produces failed
verification evidence. Goal-tree parity runs after the immutable seal, so its
impact analysis may identify an owning Part but cannot reopen it; it blocks
publication. The Conductor may propose a follow-up Goal from the exact sealed
tree. The evidence classifies localization as `SelectedPart(part_id)`,
`OutsideSelection(obligation_digest)`, or `Unlocalized`. The latter two block
for diagnosis or a follow-up rather than assigning the failure arbitrarily; the
verification gate itself creates no obligation or proposal.

If the source cannot be executed, the contract must name the substitute judge
and its limitation. Choir reports the weaker evidence in final status rather
than claiming behavioral parity.

After a migration, ordinary accepted work may retain a versioned
`BackslidingGuard` artifact that detects reintroduction of a retired API,
dependency, file shape, or invariant. It is a read-only recipe that can be
admitted by later Goal verification or installed deliberately in the
repository's own CI. Choir does not turn it into an ambient daemon or silently
monitor the repository after publication.

## Independent Review Policy

The existing independent audit remains the required baseline for every Part
and the combined Goal tree.

A multi-auditor panel is not part of the first three slices. The
[Goal workflow charter](goal-workflow.md) already requires any future version
to bind a canonical contributor set rather than
overload the baseline receipt. Choir should design adjudication only after a
diagnostic study shows that an extra independent audit catches systemic defects
often enough to justify the added provider capacity and a new authorization
model. Provider diversity alone is not mechanical verification.

## User Flow

The intended interaction remains conversational:

1. The user reviews feasibility, including `Decline`; the Conductor may then
   propose one bounded judge/rulebook/inventory preparatory Goal.
2. Choir completes that Goal and presents its artifacts, terminal qualification
   evidence, sealed tree, and unresolved decisions.
3. The user chooses the production source and accepts the exact migration
   contract; required rehearsal loops through explicit repair until one ends by
   qualifying evidence-only cancellation.
4. The Conductor proposes the production Goal from accepted inventory Beads,
   binding rehearsal evidence when required.
5. Choir schedules Parts by dependency and ownership; Claude and Codex workers
   may be mixed.
6. Findings repair eligible non-integrated Parts or let the Conductor propose a
   contract revision; integrated impact requires a follow-up Goal.
7. Combined checks and parity use ordinary sealed-Goal verification. Failure
   blocks publication and may support a follow-up, never reopening the seal.
8. Existing assurance, publication, and final-PR protocols complete the Goal.

Command spelling remains a Conductor-adapter concern. Conceptually, the user
may ask: “work on this migration until the accepted inventory and declared
checks are complete.” No arbitrary Part count is part of the product contract.

## Feature Priority and Delivery Slices

The strongest product direction is not to implement every mechanism in this
document at once. The work divides into auditable slices that remain useful if
a later slice is declined.

### Slice 1: contract, context, and findings

1. Add feasibility/workflow-shape proposal records and the immutable
   `MigrationContract` reference carried by migration task contracts.
2. Introduce deterministic command-artifact preparation over the existing
   harness intent digest fields, with `PartContextManifest` and exact Goal
   projections as inputs. Do not add a second launch or receipt protocol.
3. Define the typed migration-finding artifact and a deduplicated pattern
   projection over existing audit results.
4. Give the new pure domain values explicit canonical encoders, fixed byte
   fixtures, and generated properties on every supported MoonBit target.

This slice adds command preparation and extends the existing harness-intent
authorization predicate. It changes no scheduler, Take purpose, Goal lifecycle,
process runner, verification subject, or receipt family.

### Slice 2: bounded end-to-end migration

1. Qualify one judge through an ordinary preparatory Goal, including bounded
   negative controls, baseline-failure classification, Goal verification, and
   combined audit.
2. Add deterministic inventory execution, stable unit dispositions, and
   canonical two-run determinism validation, then materialize accepted inventory
   units as proposed Beads before Goal selection.
3. Initially admit only agent-assisted units through the existing
   `Implementation` purpose.
4. Add generic `GoalCompletionMode`, typed cancellation causes, multi-Part
   rehearsal on the ordinary Goal ref, ordinary Goal assurance followed by the
   existing cancellation path, and exact `RehearsalEvidenceRef` admission.
5. Bind each production task contract to the accepted migration revision and
   validate impact-limited invalidation for non-integrated Parts plus mandatory
   follow-up-Goal routing when an impacted Part is already integrated.

The MVP is valuable when it can complete one bounded migration with an honest
inventory denominator and repair a shared contract defect. It does not need an
audit panel, affected-set batching, process-only implementation, generic
campaign layer, or component ABI.

### Slice 3: mechanics, scale, and durable prevention

1. Add the generic `DeterministicImplementation` Take purpose only after a real
   codemod demonstrates enough volume to save provider capacity.
2. Allow a separately accepted preparatory Goal to turn accepted pilot or
   rehearsal examples into one deterministic rule qualified on a sealed,
   disjoint corpus for a later Goal. Do not promote a rule inside an already
   selected Goal.
3. Add ordered validation metadata while continuing to use existing Part and
   Goal verification slots and `ProcessExecution`.
4. Add original-versus-target parity as an ordinary Goal-verification spec for
   workflows that have a runnable source oracle.
5. Add adaptive out-of-selection obligation reporting and a versioned
   `BackslidingGuard` artifact.
6. Add a typed exclusive resource claim to ordinary Take admission only if a
   measured compiler, license, device, or cache bottleneck requires it.

### Slice 4: opt-in experiments

- Evaluate a second-auditor and adjudication policy only after measuring how
  often one independent audit misses systemic migration defects relative to
  its subscription-capacity cost.
- Run `moon prove` against one small executable production-admission function.
  Keep no proof layer that uses `proof_axiomatized`, hides assumed dependencies,
  replaces runtime tests, or distorts the function merely to satisfy the
  experimental prover.
- Compare one import-free WIT `CandidatePreflight` with the same pure native
  validator on a real Take. Keep it authority-free and do not create a plugin
  API before it demonstrates a material reduction in rejected submissions.
- Revisit portable native/Wasm replay only after a real cross-backend defect or
  an external offline-verifier requirement supplies a consumer.
- Evaluate MoonBit virtual packages only in disposable conformance work. They
  are not a prerequisite for any production slice while the language documents
  them as experimental.

Each accepted slice removes superseded temporary code immediately. No slice
may leave an alternate scheduler, compatibility format, prompt-owned state
machine, or gate-triggered worker behind.

## Acceptance

Acceptance is staged with the delivery slices; optional scale mechanisms do not
hold a smaller useful release hostage.

Slice 1 is accepted when:

- choosing `Decline` from the feasibility report creates no migration contract,
  implementation Take, or repository mutation;
- replaying context assembly for the same Part and contract produces the same
  manifest and command-artifact digests, while removing one required byte
  prevents command authorization;
- missing command preparation blocks before provider dispatch, and the
  authorization predicate neither builds the artifact nor schedules a worker;
- occurrences with the same canonical finding `pattern_key` produce one
  pattern observation across restart, while different anchors do not deduplicate;
- existing Part-audit receipts remain unchanged and bind the migration revision
  only through the exact task-contract digest;
- every new migration-domain canonical encoding has fixed byte fixtures, is
  independent from diagnostic JSON layout, and passes its declared all-target
  properties with reproducible QuickCheck replay states; and
- the recorded MoonBit toolchain runs those fixtures under native debug and
  release modes when they select different compiler backends.

Slice 2 is accepted when:

- the qualifying preparatory Goal records source baselines, rejects every
  declared broken control, completes combined audit, and supplies the exact
  `GoalAssuranceRecord` artifact digest bound by the migration contract;
- an active `GoalExecutionAssured` preparatory Goal remains ineligible until it
  reaches ordinary `Succeeded` or exact evidence-only `Canceled`;
- missing or stale qualification evidence blocks production admission without
  scheduling work from the precondition;
- the same source revision and inventory generator produce byte-identical
  canonical inventories, every discovered unit remains in the denominator with
  a typed disposition, and drift is rejected;
- replaying inventory-to-Bead proposal yields the same IDs, content, and
  dependency edges without duplicating a Bead, while rejected proposals create
  no Part;
- migration status refuses completion for an unresolved unit, an unintegrated
  unit, or carried-forward integration evidence whose next `SelectionDecision`
  does not capture the superseded Goal's exact preserved head and task contracts
  carrying one validated `MigrationContinuationRef`;
- rehearsal candidates compose on their ordinary Goal ref, and immutable
  `EvidenceOnly` mode prevents publication and final-PR intent authorization
  from Goal acceptance onward;
- exact assurance of an evidence-only rehearsal enters the existing
  cancellation path, reaches ordinary terminal `Canceled` with
  `EvidenceOnlyCompleted`, and emits only the existing cancellation outbox
  event;
- a competing `UserRequested` cancellation can win the terminal compare-and-set
  but then creates no qualifying `RehearsalEvidenceRef`;
- a seeded rehearsal defect leaves ordinary failed evidence and a
  non-authorizing base Active condition, creates no `RehearsalEvidenceRef`, and
  cannot admit production merely because the experiment ran;
- rehearsal-only Beads use distinct identities, close only themselves, and
  leave every production Bead record and the qualified inventory artifact
  unchanged;
- required production rehearsal admission accepts only an exact terminal
  `RehearsalEvidenceRef` for the current migration revision, and a revision
  change blocks without scheduling another rehearsal from the precondition;
- activating a contract revision persists an exact impact set, makes gates
  derive affected receipts as stale, reruns only impacted non-integrated Parts,
  and never changes Goal selection;
- a revision that impacts an integrated Part admits no second winning candidate
  or integration receipt in that Goal, blocks publication, terminates through
  ordinary `Canceled` with `SupersededByContractRevision`, and requires an
  explicitly accepted follow-up Goal whose selection captures the preserved
  head and task contracts carrying the terminal continuation reference;
- a supersession-versus-success race commits exactly one base terminal decision;
  if `Succeeded` wins, the new revision never rewrites the completed Goal;
- if a pre-cutoff integration reconciles during supersession cancellation, the
  continuation accepts only the terminal preserved head and rejects the earlier
  observed head;
- no continuation Take starts before the prior Goal's cancellation/claim release
  and the continuation `SelectionDecision` both commit;
- a bounded end-to-end fixture validates its judge, ends a multi-Part rehearsal
  through typed evidence-only cancellation, completes an agent-assisted
  production Goal with at least one pre-integration contract repair, performs
  existing combined-tree assurance, and reaches the ordinary publication
  boundary.

Slice 3 capabilities are accepted independently when implemented:

- replaying a deterministic transformation from the same subject yields the same
  canonical change digest, undeclared mutation is rejected, and declared
  idempotence is demonstrated;
- synthesis receives only the precommitted training partition, ordinary
  verification receives the sealed disjoint evaluation partition, a seeded
  negative case fails qualification, the result is reported only as performance
  on that corpus, and only an explicitly accepted contract revision plus a new
  Goal can activate the exact learned rule;
- parity comparison detects a deliberately introduced output difference and
  its ordinary Goal-verification evidence binds the exact source, sealed target,
  scenario, normalizer, and declared limitations without reopening the sealed
  Goal;
- any exclusive resource claim is fenced by the existing Take lease and cannot
  survive cancellation or authorize work by itself;
- newly discovered out-of-selection work cannot mutate the accepted Goal and
  leaves one deduplicated typed obligation from which the Conductor may propose
  a follow-up Goal; and
- a `BackslidingGuard` detects a seeded reintroduction without running as an
  ambient post-publication effect.

Slice 4 experiments are accepted only as evidence for a later decision. A WIT
preflight experiment requires a separate charter with a measured baseline,
predeclared sample and rejection classes, exact import-boundary checks, full
incremental toolchain/build cost, expected provider-time savings, and a kill
threshold. It must remain non-authoritative, match fixed native fixtures, and
show that a forged component success cannot change server rejection. A
`moon prove` experiment must discharge obligations over the executable
admission function without `proof_axiomatized`, disclose assumed dependencies,
remain reproducible under pinned tools, and leave runtime, canonical-byte,
overflow, and all-target tests authoritative.

At charter audit, the checked-in hermetic CI command
`CHOIR_TEST_NO_EXEC=1 moon test --target native` is not a valid green baseline:
it selects unconditional native Git integration tests while the environment
guard correctly aborts every real process. Before any slice claims acceptance,
a prerequisite maintenance change must place every intentional real-process
test exclusively in the `CHOIR_TEST_REAL_EXEC=1` lane, or equivalently exclude
it from no-exec selection, without weakening the abort guard. This is
pre-existing test-lane debt rather than a migration capability or an allowable
baseline exception.

After that prerequisite, `moon check --target native`, `moon test --target
native`, both CI test lanes, Choir lint, and all existing conformance commands
must pass. Pure assurance packages also run their declared `moon check --target
all` and `moon test --target all` matrix; native-only adapters remain covered by
narrow hermetic tests.

Every test uses pure state-machine or narrow adapter fixtures where possible.
Real process, Git, provider, and BoxLite cases remain hermetic and operate only
inside dedicated disposable roots. Public-API-only coverage lives in blackbox
`_test.mbt` files; inline tests exist only when private symbols are required.

## Explicit Non-Goals

- A generic workflow language or user-authored state machine.
- A migration-only scheduler parallel to the Goal/Part/Take machine.
- An online self-modifying rule learner, automatic activation from accepted
  patches, or a gate that synthesizes the transformation it requires.
- Migration-specific context-delivery, global-check, parity-receipt, replay
  receipt, process-recovery, or lease subsystems parallel to the base Goal
  workflow charter.
- Provider-owned task or completion authority.
- Per-Part pull requests, tmux/Zellij mailboxes, or a required dashboard.
- Hand-patching generated output while leaving a known rulebook defect.
- Treating TODO comments as durable gap tracking.
- Mandatory semantic indexing, Semble, Exa, or network research.
- Cloud execution, multi-user operation, or a usage-priced provider path.
- Claiming formal or whole-program equivalence from finite judge, mutation, or
  parity evidence.
- Rewriting mature OpenRewrite, Coccinelle, compiler, or repository tools in
  MoonBit merely to keep the implementation monolingual.
- A general untrusted-plugin marketplace, ambient Wasm host imports, or
  prompt-generated MoonBit compiled directly into workflow authority.
- A production dependency on an unpinned or not-yet-stable Component Model ABI.
- Binding canonical artifact identity to derived JSON layout, experimental
  virtual packages, experimental LLVM output, or an unstable native plugin ABI.
- Treating an experimental `moon prove` result as a production receipt, skipping
  runtime/overflow tests because a proof passed, or admitting axiomatized or
  undisclosed-assumption authorization claims.
- Automatic post-merge production monitoring. Regressions found after merge
  become evidence for a new follow-up Goal.

## Prior-Art Decisions

The research below refreshes and narrows the broader register in the
[Goal workflow charter](goal-workflow.md) for large-transformation workflows.
Repository links are pinned to the inspected
upstream revisions where a repository is the evidence; papers and official
manuals are linked directly and interpreted within their stated scope.
The generic orchestration register in the
[Goal workflow charter](goal-workflow.md) remains controlling and is not
repeated here.

| Prior art | Relevant mechanism | Choir decision |
|---|---|---|
| [Anthropic large migration report](https://claude.com/blog/ai-code-migration) and [pinned reference kit](https://github.com/anthropics/code-migration-kit-with-claude-code/tree/cf91c9d5068d9aaf95a36164169f08c3e636c909) | feasibility, judge validation, rulebook and gap inventory, disposable stress test, mechanical queue, loop repair, serialized compiler, behavioral parity | Adopt the bounded mechanisms, including a valid decline outcome and an explicitly unknown or evidence-backed capacity range. Treat the kit as reconstructed reference material and the reported regressions as evidence that passing parity is not semantic proof. Do not copy API-priced scale assumptions. |
| [Google, *Migrating Code At Scale With LLMs*](https://arxiv.org/html/2504.09691) | deterministic reference discovery, conservative classification, LLM handling of residual variation, cheap-to-expensive validation, nightly renewal, explicit punts and failures | Adopt the hybrid transformation cascade, stable denominator, and ordered validation. Reject the assumption that every repository has Google's code index, build graph, production rollout machinery, or model budget. |
| [Google large-scale change infrastructure](https://abseil.io/resources/swe-book/html/ch22.html) | comprehensive change generation, ownership-aware sharding, affected-test selection, resource caps, automated review, and backsliding prevention | Adopt deterministic inventory, ownership-aware Parts, optional deterministic affected-test selection, and an emitted guard artifact. Use the existing Goal-verification and one-PR flow; defer mutable affected-set subjects and mass independent submissions. |
| [OpenRewrite recipes](https://docs.openrewrite.org/concepts-and-explanations/recipes) at [inspected engine revision](https://github.com/openrewrite/rewrite/tree/9176265d062b3e4de13f87e1f814dd2e69e61b01) | composable deterministic search and transformation recipes with language-aware trees | Prefer an admitted recipe over model work when it covers the case. Preserve the recipe, parser, runtime, input, and output digests; do not reimplement a mature engine in MoonBit. |
| [Coccinelle semantic patches](https://kernel.org/doc/html/latest/dev-tools/coccinelle.html) at [inspected revision](https://github.com/coccinelle/coccinelle/tree/233b5ceb1d5a701fb270ebdf0a9bd6be0a6ce53b) | declarative semantic matching and tree-wide transformation used for Linux changes | Treat a semantic patch as another typed deterministic process artifact. Its coverage and false-positive classes remain explicit inventory evidence. |
| [REFAZER](https://www.microsoft.com/en-us/research/publication/learning-syntactic-program-transformations-examples/) | synthesizing and ranking AST transformations from a few concrete input/output edits | Permit accepted examples to propose a recipe for a later Goal. Separate construction, sealed disjoint evaluation, and explicit activation; examples alone under-specify intent. |
| [Getafix](https://arxiv.org/abs/1902.06111) and [SPINFER](https://www.usenix.org/conference/atc20/presentation/serrano) | context-sensitive clustering or inference of recurring fixes, with imperfect top-ranked accuracy, precision, and recall | Preserve context, negative cases, misses, and exact applicability as evidence. Never let an inferred pattern classify itself, authorize mutation, or silently absorb a failed evaluation case. |
| [Microsoft CodePlan](https://www.microsoft.com/en-us/research/publication/codeplan-repository-level-coding-using-llms-and-planning/) and [archived replication package](https://github.com/microsoft/CodePlan/tree/e83f560a1e67c67f621fac9918f02f7016a49cbe) | incremental dependency analysis, may-impact analysis, and adaptive planning after each edit | Adopt typed newly discovered obligations and recomputed impact. Reject adaptive mutation of the accepted Part set; out-of-selection work becomes a follow-up Goal proposal. |
| [Mutation testing at Google](https://arxiv.org/abs/2102.11378) | scalable, filtered artificial faults expose tests that pass without detecting relevant defects | Adopt bounded risk-class negative controls for judge construction. Reject an unbounded mutation campaign or the inference that killed mutants prove correctness. |
| [MoonBit multi-target commands](https://docs.moonbitlang.com/en/latest/toolchain/moon/commands.html), [FFI boundaries](https://docs.moonbitlang.com/en/latest/language/ffi.html), and [WIT component tutorial](https://docs.moonbitlang.com/en/latest/toolchain/wasm/component-model-tutorial.html) | one pure package can target native and Wasm; Wasm host access appears through imports; WIT generates typed component interfaces | Adopt all-target properties for pure migration state. Inspect and reject unexpected imports in one component experiment through existing process execution; do not add an assurance kernel, replay receipt, or component platform without measured value. |
| MoonBit [derived traits](https://docs.moonbitlang.com/en/stable/language/derive.html), official [QuickCheck](https://mooncakes.io/docs/moonbitlang/quickcheck), and [virtual packages](https://docs.moonbitlang.com/en/latest/language/packages.html#virtual-packages) | generated values, shrinking and deterministic failure replay, JSON codecs, and build-time-swappable package implementations | Adopt generated state-machine inputs, retained counterexamples, and cross-target properties. Keep canonical bytes explicit because derived JSON is for human-readable storage/debugging; defer virtual packages because the manual marks them experimental and plain-function-only. |
| MoonBit [formal verification](https://docs.moonbitlang.com/en/latest/language/verification.html) | `moon prove` attaches pre/postconditions to executable MoonBit and discharges proof obligations through SMT solvers | Try one proof over a real pure admission function without `proof_axiomatized`, recording the assumed dependency surface. Keep it defense-in-depth only: the verifier is experimental, uses mathematical rather than machine integers, and does not replace runtime, overflow, codec, or backend tests. |
| [WebAssembly Component Model worlds](https://component-model.bytecodealliance.org/design/worlds.html) and the [road to Component Model 1.0](https://bytecodealliance.org/articles/the-road-to-component-model-1-0) | WIT explicitly declares every import/export and can express an import-free pure component; the ABI and specification are still evolving toward 1.0 | Use the explicit import boundary in one pinned experiment. Treat current component tooling as versioned experimental infrastructure, not a stable Choir plugin contract or correctness dependency. |

### Research conclusions

The migration prior art converges on six choices: assess feasibility before
fanout; use deterministic tools for regular cases and models for residuals;
version shared rules and recurring findings; validate cheap-to-expensive; report
finite judges as bounded evidence; and promote example-derived rules only after
sealed disjoint evaluation, assurance, explicit revision, and a later Goal.

Choir already has the graph, authority boundary, isolated Takes, serialized
promotion, passive receipts, and combined-tree assurance. The first additions
are exact command preparation, typed findings, an immutable migration contract,
terminal judge qualification, deterministic inventory, and rehearsal.
Process-only implementation, parity, resource claims, and panels wait for
measured need.

MoonBit contributes low-cost generated/cross-target conformance now, with
portable preflight and one assumption-explicit executable proof as bounded
experiments. Portable replay has no consumer. No surveyed project provides an
authority model Choir should import wholesale.
