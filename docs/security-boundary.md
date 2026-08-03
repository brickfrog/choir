# Choir security boundary

This document describes the boundary enforced by the current Choir
implementation. It is a statement of controls and limits, not a claim that a
model will produce correct or secure code.

## Threat model and trusted computing base

Choir treats provider output, provider tool arguments, repository content,
paths, Git metadata, and persisted workflow observations as untrusted. The
desired property is narrower: a provider may propose repository changes only
through an admitted sandbox surface, and Choir adopts or promotes those changes
only after independently checking bounded evidence tied to exact Git trees.

The trusted computing base includes the host kernel and KVM, BoxLite and its
pinned runtime assets, Bubblewrap, the installed Choir binary and trusted
runtime scripts, Git, MoonBit, SQLite, the local artifact store, and the host
provider CLI used to reach the provider service. Compromise of any of these can
invalidate the boundary. GitHub and provider services supply effects and
observations; neither is semantic authority for workflow correctness.

The supported host is Linux with KVM. Choir qualifies provider clients by
protocol, capability, subscription, and effective tool surface. A successful
qualification shows compatibility with the tested boundary, not that the
provider account will remain available.

## Interactive Conductor

The Conductor is an interactive, read-only view of the repository that can
discuss work, propose a Goal, and request typed steering through `choird`. Its
Bubblewrap boundary mounts the selected repository read-only at `/workspace`,
uses a synthetic writable HOME, and binds only the selected provider
executable, its exact subscription credential, the Choir executable, and the
daemon socket needed for that session.

The Conductor does not dispatch provider Takes, mint receipts, integrate
commits, publish pull requests, or decide completion. Those actions remain
`choird` authority. The provider's built-in `/goal` command proposes work; it
does not bypass the durable workflow gates.

## Host provider process

Implementation and assurance providers run as host-side subscription clients
because they must reach their model APIs. Choir wraps each client in a
Bubblewrap filesystem boundary with a sterile writable HOME. The real HOME is
not mounted. The boundary read-allows the minimal system executable and library
roots, binds the admitted provider executable and one exact credential file,
and exposes the BoxLite owner socket or provider adapter socket only when that
surface requires it. Host paths such as `/mnt`, `/var`, `/root`, other users,
and sibling repositories are not mounted.

The host provider process therefore retains network access to its provider
service and can use the specifically bound subscription credential for that
authentication. The model is not given a host file or shell tool that can read
the credential; repository reads and mutations go through the sandbox MCP
surface. Subscription qualification and effective-surface tests fail closed
when the executable, credential shape, protocol, or admitted tools disagree.

## BoxLite guest and tool surfaces

Every Take guest is created with BoxLite security enabled and networking
disabled. The runtime policy fixes the image digest and resource bounds. Choir
does not mount the host repository, host HOME, sibling repositories, provider
credentials, or the host artifact store into the guest.

Mutable implementation Takes receive only repository-relative `read_file`,
`list_files`, `write_file`, `replace_text`, and bounded `run` tools. The
workspace owner validates paths, argv, working directories, timeouts, frame
sizes, and output limits before executing them inside the guest.

Assurance Takes receive a read-only sealed subject plus `read_file`,
`list_files`, disposable scratch/output writes, and `read_audit_context`. They
do not receive repository mutation or general execution tools. Read-only
WorkOrder planning has the same read/scratch/output surface without
`read_audit_context`; it does not receive implementation tools. Tool manifests
and runtime-policy digests are part of provider admission.

## Direct `choir take`

`choir take` is daemon-free and handles one selected provider session. It
requires a clean captured `HEAD`, admits at most the declared repository scopes
(or the whole repository when scope is deliberately omitted), and rejects
special or escaped paths. The provider edits only its disposable guest
workspace.

After the provider returns, Choir seals the candidate read-only, captures its
exact base and candidate tree identities, rejects out-of-scope or structurally
unsafe changes, and emits a patch bounded to 1 MiB. Choir independently runs
the registered Moon verification in the guest; provider output cannot claim
that verification succeeded.

The command is a dry run unless `--apply` is present. Apply is allowed only for
a passing result, and immediately before host mutation Choir rechecks the
captured clean HEAD, patch digest, patch applicability, and candidate identity.
Direct Takes do not create Beads, Goals, branches, commits, receipts, or pull
requests.

Repository verification is currently MoonBit-only. `--verify` selects a
bounded `moon` argument vector, not an arbitrary host command.

## Audit context and receipt binding

Part audit context compares the persisted Part contract's base tree with the
verified candidate tree. Combined Goal audit context compares the Goal's
captured base tree with its sealed final tree and derives scopes from persisted
Part contracts. Current checkout state is never substituted for either audit
subject.

Choir captures canonical, sorted paths, per-file statistics, mutation
declarations, subject identities, and a deterministic Git diff. Unified diffs
up to 1 MiB are included; a larger diff is omitted in full after a one-byte
sentinel proves it exceeded the limit. Canonical metadata excluding the diff is
also limited to 1 MiB and fails closed when it cannot be represented exactly.
Malformed trees, paths, duplicate entries, inconsistent statistics, and stale
or missing artifacts are validation failures.

The context is stored as a content-addressed artifact retained through the
Goal's terminal boundary. Its digest is part of the Part or Goal audit subject,
Take purpose, effect identity, result, and receipt gates. Before assurance
dispatch, the exact artifact is uploaded to
`/run/choir/audit-context/<digest>` inside the audit box and verified there.

The auditor must call `read_audit_context` with that lowercase SHA-256 digest
and consecutive byte cursors. Each response contains at most 128 KiB and ends
on a valid UTF-8 boundary. Retained harness events must prove successful,
gap-free, non-overlapping coverage from byte zero through EOF for the expected
digest. The passive gate performs no read itself. Wrong, failed, incomplete,
stale, or overlapping reads cannot produce an accepted audit result or receipt.

## Durable Goals and promotion

An accepted Goal persists Part contracts, typed effects, provider sessions,
artifacts, and receipts in the durable workflow store. Candidate evidence is
adopted only when its identities match the planned effect and retained
artifacts. Verification and audit are separate capabilities from
implementation; provider terminal text cannot mint their receipts.

Promotion is serialized. A Part can integrate only when its verification and
audit gates accept receipts for the exact candidate tree and current contract.
Goal assurance seals and verifies the combined tree, binds its audit context,
and publishes only the receipted tree. Pull-request and merge observations are
checked against the stored repository, branch, commit, and remote identities.
Durable state and reconciliation preserve this authority across provider,
Conductor, daemon, and host-process exits.

## Failure and recovery

Cancellation persists a typed cutoff; late observations cannot silently
revive canceled work. Provider loss, expired leases, ambiguous process
termination, uncertain external effects, missing artifacts, failed
verification, audit protocol failures, and identity mismatches stop or block
the relevant transition. Choir does not convert an unknown observation into
success.

Retries and repairs are bounded workflow decisions with explicit ownership.
An executor may carry out an authorized effect and reconcile its observation,
but a passive gate does not spawn work to manufacture the evidence it requires.
Human steering can pause, resume, answer an explicit request, change allowed
concurrency, or cancel; it cannot forge receipts or skip assurance.

## Storage and cleanup

Each Take uses an owned runtime root, BoxLite boxes, a repository-scoped
BoxLite home/cache, and bounded provider session state. Direct Take and Goal
cleanup use exact ownership receipts and reconcile owned boxes and processes;
ambiguous ownership fails closed instead of broad deletion. Goal runtime roots
are removed at the terminal boundary and residual owned roots are reclaimed on
the next daemon start.

Content-addressed artifacts have explicit retention. `choir goal archive`
releases one terminal Goal's expired content and owned witness references while
preserving its durable record, branch, and anything another retention still
owns. `choir stop` preserves recoverable state. `choir stop --purge` requires
exact ownership, reconciles matching runtimes and the repository BoxLite home,
then removes durable state and exact owned refs. It does not delete global
caches, external version bundles, user branches, remote branches, pull
requests, or source Beads.

## Explicit non-goals

Choir does not claim:

- that a model's implementation or audit judgment is correct;
- protection from a compromised host kernel, KVM, BoxLite, Bubblewrap, Choir
  binary, trusted runtime asset, Git, MoonBit, SQLite, or artifact store;
- provider-account availability, subscription continuity, or protection from a
  compromised provider service;
- arbitrary non-MoonBit repository verification before portable toolchains are
  separately designed, compared, and admitted;
- that GitHub, provider APIs, Beads, or any other external service is semantic
  authority for workflow correctness;
- confidentiality from repository content deliberately admitted to the selected
  provider session; or
- safety of a patch after a human or external process changes it outside the
  checked apply and promotion paths.
