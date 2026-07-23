# macOS Apple Silicon Host Port Charter

Status: deferred design and qualification charter

Target host: Apple Silicon macOS, with an M2 MacBook as the first required
host

Implementation status: `NOT_RUN`. Choir's supported host remains Linux
x86-64 with KVM. The Darwin MoonBit development target is not evidence of a
working or secure macOS Choir runtime.

Decision state: a native macOS port is plausible and should preserve the
existing Goal, Part, Take, effect, receipt, assurance, integration, and
publication machine. It must not introduce a macOS scheduler, bypass a passive
gate, or fall back to direct host execution when a host capability is absent.

Planning snapshot: 2026-07-22

## Purpose

The immediate continuity need is to operate from an M2 MacBook while the
qualified Linux desktop may be in transit or temporarily unreachable. Remote
use of an existing Linux host is the supported near-term answer. This charter
defines the separate future work required for the MacBook itself to become a
qualified Choir execution host.

The target experience is the existing one:

1. Claude or Codex runs as the interactive Conductor.
2. `choird` remains the sole durable workflow authority.
3. Subscription-backed provider Takes receive only their exact admitted Choir
   MCP tools.
4. Model-directed process and filesystem effects occur in an isolated BoxLite
   microVM generation.
5. Verification, independent audit, integration, cancellation, and recovery
   retain the same typed evidence and passive-gate semantics as Linux.

Native macOS support is not achieved merely because Choir compiles, BoxLite
boots one VM, or a provider completes one prompt. The complete platform,
provider, sandbox, process-lifetime, filesystem, and network matrices must pass
against exact Darwin/ARM64 artifact identities.

## Current Platform Facts

| Surface | Linux host today | M2 macOS target | Current status |
|---|---|---|---|
| Host virtualization | KVM | Hypervisor.framework | macOS `NOT_RUN` |
| BoxLite | Pinned v0.9.7 Linux CLI plus corrected six-file runtime | Separately pinned Darwin/ARM64 CLI and runtime | macOS `NOT_RUN` |
| Guest | Linux x86-64 OCI filesystem and kernel | Linux ARM64 OCI filesystem and kernel | macOS `NOT_RUN` |
| Provider host boundary | Bubblewrap plus sterile environment | Qualified macOS host-containment adapter | Unselected, `NOT_RUN` |
| Process identity and cleanup | `/proc`, process groups, Linux parent-death signal | Darwin process inspection, owned groups, and explicit liveness channel | Unimplemented |
| Claude Code | Pinned Linux x86-64 executable | Separately pinned official Darwin/ARM64 executable | `NOT_RUN` |
| Codex CLI | Pinned Linux x86-64 executable | Separately pinned official Darwin/ARM64 executable | `NOT_RUN` |
| Choir native executable | Linux x86-64 admitted installation | Darwin/ARM64 build and installation | Build/runtime `NOT_RUN` |
| Durable workflow semantics | Implemented and qualified | Reused without a parallel state machine | Portable by design, unproven on macOS |

KVM is not required for a native macOS port. BoxLite's supported Apple Silicon
path uses Hypervisor.framework directly while continuing to run a Linux guest.
This is one level of virtualization, not KVM nested inside a general-purpose
Linux VM.

Apple documents nested virtualization only for M3 and later hosts. The target
M2 therefore must not be designed around a Linux-VM-to-nested-KVM workaround.
Even on a later chip, that route would be a distinct Linux/ARM64 host surface
requiring its own artifacts and qualification; it would not inherit the
current Linux/x86-64 evidence.

## Binding Architecture

The [Goal workflow charter](goal-workflow.md) remains authoritative. A macOS
port may add host implementations behind existing typed seams, but it must not
fork or reinterpret the lifecycle machine.

The port must preserve these invariants:

- `choird`, not a provider, hypervisor, terminal, or helper process, owns
  durable lifecycle decisions.
- Code in the authoritative control plane remains free of direct host I/O.
- Host behavior stays in `src/exec/`, low-level primitives stay in `src/sys/`,
  and `src/bin/choir/` only composes admitted capabilities.
- The provider process has no native mutation authority outside its dedicated
  sterile state. Exact MCP tools remain its only model-directed execution
  surface.
- One Take receives one mutable sandbox generation. Separate Takes do not
  share mutable VM or workspace state.
- Missing containment, process-identity, network, credential, or VM controls
  block dispatch. They never select an unsandboxed fallback.
- Cancellation and parent loss terminate and reconcile the exact owned
  provider, MCP, BoxLite, and guest execution tree.
- A gate observes prerequisite evidence; it never spawns work to manufacture
  that evidence.
- Platform-specific executable and runtime hashes are explicit. A version
  string or upstream claim is not artifact identity.
- Linux remains supported throughout the port. Shared abstractions must not
  weaken its already passing evidence.

## Near-Term Operating Plan

Until this charter is implemented and qualified, use the MacBook as a remote
terminal for a Linux/KVM Choir host:

```text
M2 MacBook -- private SSH transport --> Linux host --> Choir --> BoxLite/KVM
```

SSH, Tailscale, power recovery, and similar access mechanisms are external
operator infrastructure, not a new Choir control plane. Choir does not gain a
remote tunnel, hosted coordinator, or credential relay.

Before the Linux desktop is shipped or otherwise becomes unavailable:

1. Do not leave a Goal running with the expectation that the MacBook can adopt
   it. Active Goal state, witnesses, runtime generations, and provider process
   identity remain host-local.
2. Finish or deliberately cancel current Goals and confirm reconciliation.
3. Push wanted repository commits and preserve ordinary repository backups.
4. Preserve the self-contained qualified Choir installation and durable state
   using an operator backup appropriate for the Linux host. A backup is not a
   portable live-resume claim.
5. Do not copy Claude or Codex authentication directories to the Mac. Log in
   through each official Darwin client if native qualification work begins.
6. If uninterrupted Choir availability becomes necessary before the port,
   prepare a second real Linux host with KVM and qualify its installed bytes.
   Treat it as a separate host, not an automatic failover replica.

## Required Port Seams

### 1. Platform identity and installation

Add an explicit closed host-platform identity that distinguishes at least the
currently admitted Linux/x86-64 surface from Darwin/ARM64. Platform identity
must select a complete artifact and policy set; it must not be inferred only
from which executable happens to resolve on `PATH`.

The Darwin installation must be self-contained like Linux. It must resolve the
Choir executable, trusted JavaScript programs, BoxLite executable, and BoxLite
runtime from a versioned installation root. Development overrides may remain
explicit, but target repositories must never provide trusted host programs.

Admission must hash and record:

- the Darwin/ARM64 Choir executable;
- each official provider executable;
- the BoxLite CLI and every selected runtime file;
- trusted Choir-owned JavaScript programs;
- native libraries whose identity affects the boundary;
- the platform-specific Linux guest kernel/runtime artifacts; and
- exact ARM64 OCI manifest digests rather than mutable tags or an
  architecture-ambiguous index.

The current BoxLite seccomp correction is specific to the qualified Linux
runtime and x86-64 profiles. The macOS port must determine from source and a
live control probe whether any corresponding correction is required. It must
not mechanically apply the Linux patch or silently omit an applicable fix.

### 2. Provider host containment

The Linux driver uses Bubblewrap to present a read-only host, a private
writable temporary directory, a sterile provider home, a dedicated working
tree, and only the exact BoxLite-owner socket mapping required by the Take.
macOS needs an independently enforced adapter with equivalent observable
properties.

A feasibility spike must compare available Darwin mechanisms, including the
containment used by the official provider clients and BoxLite, without
assuming that a private, deprecated, or provider-controlled mechanism is an
acceptable Choir boundary. The selected adapter must support a generated,
minimal policy and fail closed when the operating system refuses it.

At minimum, the live boundary must prove:

- writes persist only in the declared sterile home, scratch, and working
  roots;
- the source/assurance subject is read-only when its Take role requires it;
- unrelated repositories, user documents, SSH state, browser state, provider
  auth stores, Keychain items, and system configuration are not readable by
  model-directed tools or child processes;
- target repositories cannot inject settings, plugins, skills, hooks, MCP
  servers, executables, dynamic libraries, or trusted runtime programs;
- child processes inherit an equal-or-narrower boundary;
- the only usable model tools are the exact generated Choir MCP allowlist;
  and
- loss of the boundary is terminal rather than a prompt, retry loop, or direct
  execution fallback.

Claude and Codex may use different official credential storage on macOS. The
adapter must allow only the minimum client-owned authentication operation
needed for the admitted subscription surface. Authentication evidence remains
redacted, is never copied into a guest, and is not made available to the target
repository or sandbox MCP process.

### 3. Process lifetime and identity

Replace Linux `/proc` and `PR_SET_PDEATHSIG` assumptions with injected Darwin
capabilities. Likely implementation ingredients include bounded Darwin process
inspection, owned POSIX process groups, and an inherited liveness pipe or Unix
socket whose closure terminates children. Exact mechanisms remain an
implementation decision until a narrow spike proves them.

The adapter must distinguish process existence from process identity. PID reuse
must not allow Choir to signal or adopt an unrelated process. Durable witness
records must retain the same compare-before-act behavior as Linux.

Required fault cases include:

- provider exits normally, nonzero, by signal, and during a tool call;
- provider forks children and creates a new session or process group;
- MCP or BoxLite owner dies independently;
- `choird`, the Goal worker, terminal, or parent process disappears;
- cancellation races provider completion and guest execution;
- the machine sleeps and resumes;
- the process is replaced while a stale PID remains recorded;
- Choir restarts with live, dead, and identity-mismatched witnesses; and
- cleanup partially succeeds and must be retried without widening its target.

No Darwin primitive may treat an unobservable child tree as successfully
terminated. An inability to establish exact identity produces typed
uncertainty and blocks promotion.

### 4. BoxLite Hypervisor.framework adapter

Preserve the existing narrow owner model: the model-facing MCP process receives
only box-and-access-scoped capabilities, while the privileged BoxLite owner
retains lifecycle, runtime-directory, API-key, and cleanup authority.

The Darwin adapter must separately prove:

- exact BoxLite and runtime artifact identity before VM creation;
- secure Hypervisor.framework boot on the M2 host;
- immutable prepared base and isolated copy-on-write clones;
- bounded copy-in and staged, no-follow copy-out;
- streamed execution, attach, signal, kill, inspect, restart, and re-adoption;
- read-only subject enforcement across the complete process tree;
- explicit CPU, memory, disk, and concurrency limits;
- denied DNS, TCP, UDP, QUIC, loopback/host aliases, and Choir/runtime sockets
  under the network-disabled profile;
- no unintended host mounts or paths through macOS filesystem sharing;
- complete runtime-root cleanup after terminal assurance or cancellation; and
- honest behavior across laptop sleep, wake, low-disk, and abrupt shutdown.

The guest is ARM64 Linux. Any toolchain used for implementation, verification,
or audit must therefore have admitted Linux/ARM64 artifacts. Rosetta or other
translation is not assumed. If a repository requires x86-64-only tooling, the
Take must be rejected or assigned to a separately supported host surface.

### 5. Darwin filesystem semantics

The default macOS filesystem commonly differs from Linux in case sensitivity,
Unicode normalization behavior, metadata, and path-length constraints. The
port must not let these differences change the accepted Git tree or weaken
archive/path validation.

Add narrow unit or adapter coverage for:

- case-colliding Git paths;
- composed and decomposed Unicode names;
- symlink, hardlink, device, FIFO, and socket rejection;
- executable-bit preservation;
- destination symlink traversal and no-follow adoption;
- Unix-socket path limits;
- extended attributes and resource forks;
- atomic rename behavior and cross-filesystem staging; and
- case-sensitive Linux guest results copied onto a case-insensitive host.

When a tree cannot be represented safely and byte-faithfully on the host
filesystem, fail before mutation rather than normalize or drop entries.

### 6. Provider qualification

Claude Code and Codex CLI are separate Darwin/ARM64 surfaces. Each requires its
own exact version, executable hash, official subscription login, sterile-home
behavior, initialization manifest, allowed-tool digest, cancellation proof,
and rollback artifact.

Reuse the existing provider matrix without weakening a row:

- exact startup and platform identity;
- hostile ambient configuration;
- required-tool fail-closed startup;
- host read and write confinement;
- host/guest path identity;
- credential isolation;
- child-process isolation;
- capability death;
- nonresumable parent loss;
- mutation boundary;
- network boundary;
- provider-managed subscription identity;
- cancellation;
- tool discovery and execution; and
- resume/restart re-attestation where the surface supports resume.

Official clients may behave differently around Keychain, login callbacks,
auto-update, native sandboxing, and application support directories. Those
behaviors must be observed on the exact candidate. Neither Linux evidence nor
another provider's Darwin evidence transfers automatically.

## Delivery Slices

### Slice 0: Read-only feasibility audit

- Build and run the existing hermetic MoonBit suite on the M2 without changing
  production claims.
- Inventory every Linux-specific source seam and native library.
- Inspect exact Darwin/ARM64 provider and BoxLite artifacts and their official
  update/install behavior.
- Run harmless BoxLite boot, process-lifetime, filesystem, and containment
  spikes from isolated temporary roots.
- Select or reject a provider host-containment mechanism based on observed
  enforcement.
- Produce a gap report. Do not add a permissive fallback to make probes pass.

Exit criterion: the report identifies a viable independently enforced provider
boundary and exact host primitives, or records a blocking reason. All product
support remains `NOT_RUN`.

### Slice 1: Typed platform capabilities

- Introduce closed platform/runtime identities and injected host capabilities.
- Move remaining Linux-specific decisions behind the host boundary without
  changing the Linux behavior.
- Add Darwin implementations for executable resolution, process identity,
  liveness, bounded signaling, and filesystem primitives.
- Keep public-API tests blackbox and private helper tests inline. Use narrow
  adapters rather than broad shell harnesses.

Exit criterion: Linux conformance remains green, Darwin hermetic tests pass,
and missing Darwin capabilities fail before provider or VM dispatch.

### Slice 2: Provider host boundary

- Implement the selected macOS containment adapter.
- Prove sterile configuration, exact tools, read/write confinement, child
  inheritance, credential isolation, and boundary death against harmless
  fixtures.
- Qualify one provider at a time; Claude and Codex support remain independent.

Exit criterion: at least one Darwin provider profile passes every applicable
host-surface row with exact artifact evidence. A blocked provider stays
unsupported rather than borrowing another provider's result.

### Slice 3: BoxLite and Take lifecycle

- Pin the Darwin BoxLite CLI, runtime bundle, ARM64 guest artifacts, and OCI
  manifests.
- Connect the existing owner/MCP capability split to the Darwin adapter.
- Run the complete sandbox lifecycle/security matrix and one isolated Take.
- Exercise sleep/wake, cancellation, parent loss, restart, and cleanup faults.

Exit criterion: the exact Darwin sandbox surface passes every required row and
leaves no process, socket, runtime root, or host mutation after terminal
cleanup.

### Slice 4: Durable Goal and installation proof

- Run native implementation, verification, independent audit, integration,
  combined-tree assurance, cancellation, and mixed-provider fixtures on the
  M2.
- Verify concurrent Takes remain isolated and bounded.
- Build a self-contained versioned Darwin installation with rollback.
- Test upgrade refusal, rollback, daemon restart, laptop sleep/wake, and clean
  uninstall/purge behavior.
- Update the dependency-upgrade runbook with a platform-specific Pin Audit
  Report and commands only after they exist.

Exit criterion: an installed-layout Goal completes through publication or an
explicitly unavailable forge boundary; every required platform matrix row
passes; rollback is preserved; and the README can honestly list the exact
supported macOS and chip range.

## Required Qualification Report

The first macOS admission report must include, at minimum:

| Evidence | Initial status |
|---|---|
| M2 model, macOS version, Darwin kernel, architecture | `NOT_RUN` |
| Hypervisor.framework availability and successful secure VM boot | `NOT_RUN` |
| Choir executable version and SHA-256 | `NOT_RUN` |
| BoxLite source/release, CLI hash, runtime manifest, and guest artifacts | `NOT_RUN` |
| ARM64 OCI manifest digests | `NOT_RUN` |
| Claude Darwin version/hash and full provider matrix | `NOT_RUN` |
| Codex Darwin version/hash and full provider matrix | `NOT_RUN` |
| Host-containment policy identity and adversarial read/write results | `NOT_RUN` |
| Process identity, cancellation, parent-loss, sleep/wake, and restart results | `NOT_RUN` |
| Filesystem representation and copy-in/out adversarial matrix | `NOT_RUN` |
| BoxLite lifecycle, isolation, resource, and network matrix | `NOT_RUN` |
| Native Take and durable Goal lifecycle receipts | `NOT_RUN` |
| Installed-layout resolution, upgrade, rollback, stop, and purge | `NOT_RUN` |

Anything unsafe, destructive, credential-revealing, unavailable, or not
directly observed remains `NOT_RUN`; it is never inferred from upstream
documentation.

## Explicit Non-Goals

- Supporting Intel Macs.
- Treating an M2 Linux VM as a nested-KVM production host.
- Replacing BoxLite with an unisolated local subprocess path.
- Moving provider credentials into a Linux guest.
- Sharing one active Goal database between Linux and macOS hosts.
- Live migration or automatic failover of provider processes or VM
  generations.
- Adding a remote Choir control plane, hosted model gateway, or credential
  relay.
- Using Docker Desktop, a broad container daemon socket, or a general desktop
  VM as an implicit authority boundary.
- Depending on provider-native background agents, teams, worktrees, or task
  state for correctness.
- Weakening Linux qualification to reach superficial cross-platform parity.
- Claiming support from compilation, one VM boot, or one successful provider
  turn.

## Primary References

- [Apple Hypervisor framework](https://developer.apple.com/documentation/hypervisor)
- [Apple Virtualization framework](https://developer.apple.com/documentation/virtualization)
- [Apple nested virtualization availability](https://developer.apple.com/documentation/virtualization/vzgenericplatformconfiguration/isnestedvirtualizationsupported)
- [BoxLite platform documentation](https://docs.boxlite.ai/)
- [BoxLite C SDK platform matrix](https://docs.boxlite.ai/reference/c/index)
- [BoxLite v0.9.7](https://github.com/boxlite-ai/boxlite/releases/tag/v0.9.7)
- [Choir BoxLite runtime pin](../boxlite-runtime.md)
- [Choir dependency-upgrade runbook](../runbooks/dependency-upgrades.md)
