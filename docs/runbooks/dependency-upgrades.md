# Dependency and runtime upgrade runbook

Use this runbook to audit, qualify, or promote changes to Choir's pinned
providers, sandbox runtime, task inventory, toolchain, dependencies, and CI
environment. It is written as an executable contract for a human operator,
Claude, Codex, or a Choir Conductor.

When a Conductor receives this runbook, it may inspect and discuss the current
state, crystallize the required work as Beads, and submit a Goal. It does not
perform provider execution, integration, publication, or completion itself;
those remain `choird` authority.

## Delegation prompts

For a complete read-only audit:

```text
Follow docs/runbooks/dependency-upgrades.md in audit mode for all surfaces.
Check every declared pin, the binary or artifact actually used on this host,
the latest official upstream release, and the required qualification coverage.
Do not edit files, install or replace software, alter authentication, mutate
Beads, or run live paid-provider probes. Return the required Pin Audit Report
and mark anything not safely observable as NOT_RUN.
```

For one candidate qualification:

```text
Follow docs/runbooks/dependency-upgrades.md in qualification mode for
<component> candidate <version or commit>. Keep the admitted installation
unchanged, use isolated candidate paths, run every applicable hermetic and live
qualification check, and return the required Pin Audit Report. Do not promote,
publish, release, or replace the installed runtime.
```

For a provider patch-release fast path:

```text
Follow docs/runbooks/dependency-upgrades.md in qualification mode using the
provider patch fast path for <Claude Code or Codex CLI> candidate <version>.
Verify the isolated candidate identity, review the release notes and exact
driver flags, run the reduced hermetic baseline, the affected targeted live
checks, and one bounded implementation Take. Escalate to full qualification
if any eligibility condition fails. Return the required Pin Audit Report and
stop before promotion, installation, push, or release.
```

For promotion after reviewing qualification evidence:

```text
Follow docs/runbooks/dependency-upgrades.md in promotion mode for
<component> candidate <version or commit>, using qualification report <path or
identifier>. Recheck the report against the current commit, preserve a
rollback artifact, update every canonical pin atomically, run the required
verification, and stop before pushing, releasing, or changing the installed
production binary unless I explicitly authorize those actions.
```

## Modes and authority

### Audit mode

Audit mode is the default whenever the request says `check`, `inspect`,
`review`, `what is outdated`, or otherwise does not explicitly authorize an
upgrade.

- Keep the repository and external systems read-only.
- Do not install, update, remove, or replace binaries or packages.
- Do not change provider login or run a command that may trigger login.
- Do not mutate `.choir`, the active Beads store, Git configuration, branches,
  tags, releases, or remote state.
- Do not run paid-provider or live KVM probes. Record them as `NOT_RUN` unless
  the user explicitly authorizes live qualification.
- Use official upstream release pages, repositories, package registries, and
  security advisories for current-version claims.

### Qualification mode

Qualification mode may build and execute a candidate, but must not replace the
admitted installation.

- Start from a clean branch or dedicated worktree.
- Put downloaded sources, candidate binaries, provider homes, BoxLite homes,
  and test repositories in dedicated temporary or versioned candidate paths.
- Never reuse the active `.choir` state or Beads database as a fixture.
- Never overwrite provider-managed authentication. Reuse an already admitted
  subscription only through the existing sterile driver boundary.
- Treat a missing live prerequisite as `BLOCKED` or `NOT_RUN`; do not weaken a
  gate, enable ambient credentials, disable seccomp, or broaden host access to
  make a probe pass.
- Do not update an expected version, hash, or policy identity merely because a
  candidate failed the current gate. The candidate must independently satisfy
  the capability and conformance requirements first.

### Promotion mode

Promotion mode updates repository pins after qualification has passed. It does
not imply permission to push, publish a release, replace an installed binary,
purge state, or alter authentication.

- Bind the qualification report to the exact candidate bytes and current Git
  commit.
- Update every coupled pin, fixture, policy identity, current-version document,
  and verification surface in one coherent change.
- Preserve the previously admitted binary or bundle before any separately
  authorized installation switch.
- Stop on evidence drift. Do not have an admission gate produce its own missing
  evidence.

## Status vocabulary

Use only these statuses in the report:

- `CURRENT`: declared, observed, and upstream identities agree.
- `UPDATE_AVAILABLE`: the admitted identity is healthy and a newer official
  candidate exists.
- `DRIFT`: declared and actually executed identities disagree.
- `FAIL`: an executed required check rejected the declared or candidate
  identity.
- `BLOCKED`: qualification cannot continue without a missing prerequisite,
  user decision, or external-state change.
- `NOT_RUN`: a check was intentionally not executed; include the exact reason.
- `NOT_APPLICABLE`: the check does not apply to this component.

## Required Pin Audit Report

Every run must return this structure. Do not replace it with a general prose
summary.

```text
# Pin Audit Report

Mode: audit | qualification | promotion
Scope: all | <components>
As of: <timestamp and timezone>
Repository commit: <full commit SHA>
Host: <OS, architecture, kernel>

## Executive result
<safe to retain current pins, candidate qualified, or promotion blocked>

## Surface matrix
| Surface | Declared identity | Observed identity | Latest/candidate identity | Status | Evidence |

## Findings
### Blocking
### Important
### Advisory

Each finding includes file:line, the exact mismatch or failed invariant, and
the smallest next action.

## Verification
| Command or probe | Result | Evidence |

## Not run
| Check | Reason | Authority or prerequisite needed |

## Coupled files for an upgrade
<exact files expected to change; empty in audit mode>

## Rollback
<previous identities and recoverable artifacts that would be retained>
```

An all-surfaces report is incomplete if any row in the source-of-truth table
below is missing.

## Source-of-truth map

Do not copy current values from this runbook into code. Read the canonical
values from these locations on every run.

| Surface | Canonical declarations and enforcement | Coupled current documentation |
|---|---|---|
| Claude and Codex versions and executable hashes | `src/harness/surface_probe.mbt`, `src/exec/claude_driver_native.mbt`, `src/exec/codex_driver_native.mbt` | `README.md` |
| Provider identity recorded in Part evidence | `src/exec/part_lifecycle_native.mbt` | Dated charter evidence is historical |
| Provider CLI arguments, sterile environment, MCP surface, recovery | `src/exec/claude_driver_native.mbt`, `src/exec/codex_driver_native.mbt`, `src/exec/exec_native.mbt` | `docs/charters/goal-workflow.md` records evidence |
| BoxLite release, executable, patch, six-file runtime bundle, probe image, and policy | `src/sandbox/boxlite_probe.mbt`, enforced by `src/exec/exec_native.mbt` and `src/exec/boxlite_take_native.mbt` | `README.md`, `docs/boxlite-runtime.md` |
| Beads version and CLI contract | `src/exec/conductor_native.mbt` | `README.md` |
| MoonBit toolchain artifacts | `flake.nix`, `flake.lock`, `scripts/install-moonbit.sh` | `README.md`; migration verification documents are historical |
| MoonBit packages | `moon.mod` and the resolved `.mooncakes` state | None |
| GitHub Actions and runner image | `.github/workflows/ci.yml`, `.github/workflows/release.yml` | Release body in `release.yml` |
| Native library ABI assumptions | `src/exec/stub.c`, `src/exec/store.c`, `src/exec/moon.pkg`, Nix and CI dependency lists | `README.md` runtime requirements |
| Installed trusted JavaScript assets | `src/exec/exec_native.mbt` and the install commands in `README.md` | `README.md` |

Historical evidence is not a mutable pin registry. Never globally replace an
old version string in a dated charter or migration verification report. Append
new dated evidence when a candidate is qualified.

## Audit all surfaces

### 1. Record repository and host state

Run read-only commands and include their output or a concise digest in the
report:

```sh
git status --short
git rev-parse HEAD
git branch --show-current
uname -a
date --iso-8601=seconds
```

A dirty tree does not invalidate an audit, but the report must identify
overlapping files and must not edit them.

### 2. Enumerate declared pins

```sh
rg -n 'expected_surface_version|expected_.*executable_sha256' \
  src/harness/surface_probe.mbt
rg -n 'boxlite_(release|seccomp|runtime|probe|policy)' \
  src/sandbox/boxlite_probe.mbt
rg -n 'Beads 1\.1\.0|bd version' src/exec/conductor_native.mbt
rg -n 'moonbitToolchainVersion|rev =|hash =' flake.nix
sed -n '1,40p' moon.mod
rg -n 'uses:|ubuntu-latest|install-moonbit\.sh|apt-get install' \
  .github/workflows
rg -n 'dlopen\(' src/exec/stub.c src/exec/store.c
```

Search for every current literal before proposing an upgrade. Classify each
match as one of:

- canonical current declaration;
- enforcement or fixture coupled to the declaration;
- mutable current documentation;
- immutable historical evidence.

### 3. Observe what this host would actually execute

Do not assume that a command found first on `PATH`, a repo-local cache, and the
Nix declaration are the same artifact.

```sh
command -v claude codex bd boxlite moon node git gh bwrap
claude --version
codex --version
bd --version
boxlite --version
moon version
node --version
git --version
gh --version
bwrap --version
find .nix-moon -mindepth 2 -maxdepth 3 -type f -path '*/bin/moon' \
  -exec {} version \; 2>/dev/null
ldconfig -p 2>/dev/null | rg 'libutf8proc|libsqlite3|libuv|libssl'
```

Hash the exact provider artifacts using the same resolution rules as the
drivers. Claude has one admitted executable identity. Codex has both a
JavaScript launcher and a native executable identity; hashing only the wrapper
is incomplete. Do not print credentials, provider homes, configuration files,
or unredacted environment variables.

For BoxLite, audit both the CLI and the selected runtime directory. The runtime
identity comprises exactly the file set returned by
`boxlite_runtime_bundle_files()`; an extra, missing, or changed file is a
finding.

### 4. Compare declarations, observations, and official upstream state

For every surface:

1. Read the declared identity from the canonical source.
2. Capture the identity actually used on this host.
3. Check the latest official upstream release and security advisories.
4. Compare supported flags, output formats, protocol surfaces, and artifact
   layouts—not just version numbers.
5. Record `CURRENT`, `UPDATE_AVAILABLE`, or `DRIFT` before recommending work.

Use only primary upstream sources for technical claims. Release freshness is
time-sensitive and must be checked live. A newer release is not automatically
admissible.

### 5. Audit toolchain coherence

Report these as distinct identities:

- the host `moon` found on `PATH`;
- `.nix-moon/bin/moon`, if present;
- the toolchain release and fixed-output hashes declared in `flake.nix`;
- the version requested by CI and release workflows;
- the compiler versions recorded by the most recent nonhistorical verification.

`latest` is a floating request, not a pin. A cached `.nix-moon` directory is an
observation, not proof that it matches the current flake. Any disagreement is
`DRIFT`, even when all variants happen to compile the repository.

### 6. Audit floating infrastructure

Explicitly report, but do not mislabel as exact pins:

- `ubuntu-latest` runner images;
- GitHub Actions referenced by a floating major tag;
- unversioned APT and Nix packages;
- Node.js, Git, GitHub CLI, Bubblewrap, KVM, and kernel versions;
- dynamically loaded shared-library SONAMEs.

For GitHub Actions, check the official latest release, required runner version,
and `runs.using` Node runtime. Do not update a major solely to silence a warning
without reviewing its migration notes.

## Common qualification baseline

Resolve a provider candidate by prepending its isolated `bin` directory to
`PATH`. Resolve a BoxLite candidate with the absolute
`CHOIR_BOXLITE_BINARY` and `CHOIR_BOXLITE_RUNTIME_DIR` development overrides.
Record `command -v`/`realpath`, version output, and SHA-256 immediately before
every live run so the report proves which bytes were exercised.

An unadmitted candidate is expected to fail the current identity gate. First
exercise its CLI and capability contract independently. Only after those
checks pass, stage the candidate version and hashes in the qualification
worktree and run the admission and conformance suite there. Those staged pin
edits are qualification evidence; they are not permission to merge, install,
push, or release the candidate.

For a full qualification, run this baseline before changing a canonical pin,
then again after candidate changes. A pre-existing failure must be separated
from a candidate regression. The provider patch fast path below uses its
smaller baseline instead.

```sh
git diff --check
node --test scripts/choir_sandbox_mcp_test.mjs
moon check --target native
moon test --target native
moon run --target native src/bin/choir_lint
moon run --target native src/bin/choir_conformance -- hermetic
moon build --target native --release
nix flake check --no-build
```

Use the repository's documented environment controls for real-exec tests. Do
not remove `CHOIR_TEST_NO_EXEC` protections or make hermetic tests depend on the
ambient host.

### Provider patch fast path

An exact provider pin is an admission boundary, not a requirement to repeat
every live boundary probe for each daily patch release. A Claude Code or Codex
CLI candidate may use this fast path only when all of the following are true:

- only the patch component changed;
- an official changelog and exact platform artifact identity are available;
- the isolated candidate's version and hash match that official identity;
- every release-note item has been mapped to the exact CLI arguments, startup
  events, structured output, MCP surface, authentication, sandbox, and process
  lifecycle used by Choir;
- removed or renamed flags and non-additive protocol changes are absent;
- any additive event or field is ignored safely or covered by a focused parser
  test; and
- no applicable security advisory or trust-boundary change requires broader
  evidence.

A default-model or pricing change does not by itself force the full matrix, but
the report must call it out and the bounded live Take must record the model
identity actually observed.

Before staging the candidate pin, record its absolute isolated path, version,
SHA-256, official source, release notes, and auto-update exposure. Review the
help for every flag emitted by the relevant Choir driver. Then stage every
coupled version, hash, fixture, provider-evidence identity, and current-version
document before running:

```sh
git diff --check
node --test scripts/choir_sandbox_mcp_test.mjs
CHOIR_TEST_NO_EXEC=1 moon test --target native
moon check --target native
moon run --target native src/bin/choir_lint
moon run --target native src/bin/choir_conformance -- hermetic
moon build --target native --release
```

For Claude Code, the minimum live fast-path evidence is
`--required-tool-startup-live` plus one affected driver probe. For Codex CLI,
it is `--driver-live` plus one affected driver probe. Each selected probe must
run through the existing sterile driver boundary and at least one must execute
a bounded implementation Take. Select affected probes from the full matrices
below and explain the selection in the report; do not run unrelated probes
merely to make the report longer.

Escalate to the full qualification matrix before promotion when eligibility is
uncertain, a targeted or hermetic check fails, the observed bytes drift, the
candidate changes packaging or executable layout, or the release affects
authentication, permission enforcement, sandbox escape resistance, credential
isolation, cancellation, process ownership, recovery, or required MCP-tool
discovery beyond what the selected probes establish. A fast-path report lists
the unselected full-matrix checks as `NOT_RUN` with `eligible patch fast path`
as the reason.

## Claude Code qualification

### Candidate preparation

- Install or unpack the candidate outside the admitted executable path.
- Record version, artifact source, SHA-256, installation mechanism, and whether
  the provider auto-updater can replace it during qualification.
- Preserve provider-managed subscription authentication, but run the candidate
  through a dedicated sterile home and the existing host boundary.
- Review CLI help for every flag used by the Conductor and Take driver.

### Full qualification declaration and startup checks

```sh
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription --synthetic-startup
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription --live
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription --required-tool-startup-live
```

The synthetic-home check is intentionally passive. When the unauthenticated
client returns the exact fail-closed no-login terminal, its initialization may
show the declared MCP server as pending and expose no tools. That observation
does not prove tool availability. The authenticated `--live` and
`--required-tool-startup-live` checks own required-tool discovery, execution,
and fail-closed startup evidence.

### Full qualification driver boundary checks

```sh
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription --driver-ambient-live
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription --driver-host-read-live
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription --driver-credentials-live
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription --driver-child-isolation-live
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription --driver-tool-search-live
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription --driver-network-live
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription --driver-capability-death-live
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription --driver-cancellation-live
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription --driver-parent-loss-live
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription --host-boundary
```

Also run the native Claude cancellation fixture and at least one isolated
implementation Take before promotion. The candidate must preserve exact MCP
discovery, native-tool removal, credential isolation, structured output,
redaction, cancellation, process-loss classification, and sandbox-only mutation.

### Coupled promotion files

At minimum, inspect:

- `src/harness/surface_probe.mbt`;
- `src/exec/claude_driver_native.mbt` and tests;
- `src/exec/part_lifecycle_native.mbt` provider identity;
- conformance fixtures containing the exact version or startup shape;
- `README.md`;
- a new dated charter evidence entry, without rewriting old evidence.

## Codex CLI qualification

### Candidate preparation

- Record and separately hash the JavaScript launcher and native executable.
- Use a dedicated sterile `CODEX_HOME`; do not qualify against ambient project
  configuration or inherited feature flags.
- Review `codex --help`, `codex exec --help`, and app-server protocol changes.
- Re-evaluate every disabled feature and required MCP configuration entry.

### Required declaration and live driver checks

```sh
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-ambient-live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-credentials-live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-capability-death-live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-child-isolation-live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-tool-search-live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-host-read-live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-network-live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-cancellation-live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-recovery-live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-initialization-recovery-live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-resume-drift-live
```

### Required Conductor and lifecycle checks

```sh
moon run --target native src/bin/choir_conformance -- conductor --start-live
moon run --target native src/bin/choir_conformance -- conductor --reconnect-live
moon run --target native src/bin/choir_conformance -- e2e --fixture native-codex-part-lifecycle
moon run --target native src/bin/choir_conformance -- e2e --fixture native-codex-cancellation
```

The candidate must preserve app-server initialization, thread identity,
resumption, event cursor monotonicity, tool-call lifecycle, structured final
results, process-loss uncertainty, cancellation, and exact sandbox ownership.

### Coupled promotion files

At minimum, inspect:

- `src/harness/surface_probe.mbt`;
- `src/exec/codex_driver_native.mbt` and tests;
- `src/exec/part_lifecycle_native.mbt` provider identity;
- Codex startup and protocol conformance fixtures;
- `README.md`;
- a new dated charter evidence entry.

## BoxLite qualification

Treat the CLI, runtime directory, security policy, probe image, and live evidence
as one atomic qualification unit.

### Candidate preparation and review

1. Record the candidate release tag, source commit, archive hash, CLI hash, and
   upstream security advisories.
2. Review changes to the jailer, seccomp profiles, Bubblewrap invocation,
   libkrun, network configuration, transfer APIs, clone behavior, process
   control, and runtime bundle layout.
3. Build or unpack the candidate in a versioned directory outside the admitted
   installation.
4. Test the stock candidate before carrying the local seccomp patch forward.
5. Determine explicitly whether `patches/boxlite-seccomp-time.patch` is
   upstream, still required, conflicts, or is obsolete. Never disable seccomp
   to bypass this decision.
6. Enumerate and hash every runtime file. A changed file set requires a new
   policy review, not only new hash literals.
7. Pin the OCI probe image by platform-manifest digest.

### Required live checks

Select the candidate with explicit development overrides and dedicated BoxLite
state; do not replace the installed runtime.

```sh
moon run --target native src/bin/choir_conformance -- sandbox --runtime boxlite --live
moon run --target native src/bin/choir_conformance -- sandbox --runtime boxlite --take-live
moon run --target native src/bin/choir_conformance -- e2e --fixture native-part-lifecycle
moon run --target native src/bin/choir_conformance -- e2e --fixture parallel-promotion
```

Qualification requires:

- exact CLI and runtime-bundle identity;
- KVM availability and secure VMM boot;
- seccomp enabled, with no insecure fallback admitted;
- pinned image resolution;
- prepared-base creation and isolated clones;
- bounded copy-in and validated copy-out;
- attach, signal, kill, and process cleanup;
- daemon restart and runtime re-adoption;
- read-only host visibility where declared;
- guest network, host aliases, metadata endpoints, control endpoints, and
  unintended host services denied;
- one real Take returning a validated structured result.

### Coupled promotion files

At minimum, inspect:

- `src/sandbox/boxlite_probe.mbt` and tests;
- `src/exec/exec_native.mbt` and BoxLite integration tests;
- `src/exec/boxlite_take_native.mbt`;
- `patches/boxlite-seccomp-time.patch`;
- `docs/boxlite-runtime.md`;
- `README.md`;
- release runtime requirements;
- a new dated charter evidence entry.

Retain the previous CLI and complete runtime directory as the rollback unit.
Never mix files from two qualified bundles.

## Beads qualification

Beads is an editable source-work inventory, but accepted Goals depend on its
status, dependency, content, and claim semantics. A version-only smoke test is
insufficient.

### Candidate isolation

- Export the active store before a separately authorized installation change.
- For qualification, initialize a disposable Beads project under a dedicated
  temporary directory. Never use the active repository store.
- Do not install hooks, edit agent files, persist Git identity, or inherit
  repository-local Git state in the fixture.

### Required contract checks

Verify the candidate's exact output and exit behavior for:

- `bd --version`;
- `bd list --json --all --readonly`;
- `bd show <ids> --json --readonly`, including nested dependencies;
- create and update JSON output;
- open, in-progress, closed, blocked, and deferred status mapping;
- assignee and actor representation;
- dependency type, direction, closure, and count/detail consistency;
- `bd update <id> --claim --actor <actor> --json` atomicity;
- acknowledgement-loss reconciliation by rereading state;
- claim conflict behavior and cancellation release;
- close-after-integration behavior;
- multi-ID claim behavior, without assuming batch atomicity.

Then run:

```sh
moon test --target native src/exec src/workflow
moon run --target native src/bin/choir_conformance -- hermetic
```

### Coupled promotion files

At minimum, inspect:

- `src/exec/conductor_native.mbt` and tests;
- `src/workflow/conductor_draft.mbt` and selection tests;
- `src/exec/goal_submission_native.mbt`;
- `src/exec/goal_execution_native.mbt`;
- generated Goal prompts if the user-facing contract changed;
- `README.md`.

Preserve a portable JSONL export and the previous database/binary until a
candidate-backed Goal has selected, claimed, integrated, and closed a Part.

## MoonBit, Nix, and package qualification

The MoonBit distribution used by `scripts/install-moonbit.sh`, the MoonBit
overlay release used by Nix, and the compiler's own reported version may use
different identifiers. Record the mapping; do not infer equality from similar
dates or hashes.

### Required procedure

1. Capture the host, `.nix-moon`, flake-declared, CI-requested, and release-
   requested identities separately.
2. Obtain candidate binaries and core sources from their official channels.
3. Recompute every fixed-output hash in `flake.nix` rather than using a fake
   hash or disabling verification.
4. Update MoonBit dependencies in `moon.mod` deliberately and inspect the
   resolved `.mooncakes` versions after `moon update`.
5. Run `moon clean` after changing package versions and before qualification.
   Native package upgrades can rename or remove C sources; an incremental
   archive may otherwise retain removed object members and report false
   duplicate-symbol failures.
6. Update `flake.lock` only for intended inputs and review the exact revision
   diff.
7. Recreate a candidate local toolchain outside the existing `.nix-moon`
   cache. Do not treat an old cache as candidate evidence.
8. Run the common baseline with the candidate toolchain, including the release
   build and native FFI surfaces.
9. Compare warning classes and counts. New warnings require disposition; they
   are not proof of failure by themselves.
10. Verify SQLite, utf8proc, libuv, OpenSSL, and C toolchain availability in the
   Nix shell, GitHub runner, and release artifact environment.
11. Ensure CI and release request a reproducible candidate identity. If either
    still requests `latest`, report `DRIFT` and do not call the toolchain fully
    pinned.

If `.nix-moon` does not match the current flake, preserve or move the old cache
before recreating it; do not recursively delete a broad or unresolved path.

## GitHub Actions and host-runtime qualification

For each action used by CI or release:

1. Check its official latest release and migration notes.
2. Inspect `action.yml` for its `runs.using` Node runtime.
3. Check the minimum GitHub runner version.
4. Review input/output changes used by the workflow.
5. Decide whether the repository intentionally follows a floating major tag or
   should pin a full commit SHA.
6. Run workflow syntax validation when available and verify the real PR check.

Also record changes to `ubuntu-latest`, APT package resolution, kernel/KVM,
Bubblewrap, Node, shared-library SONAMEs, and Git behavior. These can invalidate
runtime evidence without changing a repository version literal.

## Promotion and rollback

Before a separately authorized installation switch:

1. Confirm no active Goal depends on the old provider or runtime process.
2. Stop normally if required; never use `stop --purge` as an upgrade step.
3. Preserve the old provider binary, BoxLite CLI/runtime bundle, Beads export,
   or toolchain closure as applicable.
4. Install into a versioned location and switch an explicit symlink or
   configuration pointer atomically where the packaging layout permits.
5. Re-run identity and startup probes against the installed path.
6. Run one bounded canary Goal before removing the rollback artifact.
7. If any identity, isolation, recovery, verification, or integration check
   fails, restore the previous complete unit. Do not mix candidate and previous
   bundle files.

The final handoff must state what changed, what remains installed, which live
checks passed, which checks were not run, where rollback artifacts live, and
whether anything was pushed or released.

## Toolchain-coherence regression checks

Every audit must verify that CI, release, `scripts/install-moonbit.sh`, and
`flake.nix` name the same exact composite MoonBit release. The installer must
verify the platform and core archive hashes before extraction.

The Nix development shell keys each writable `.nix-moon` copy by the complete
Nix derivation identity. An older sibling cache may remain on disk, but it must
never be selected by the current shell. Treat a workflow request for `latest`,
an unverified installer archive, or reuse of an unkeyed `.nix-moon/bin` as
`DRIFT`.
