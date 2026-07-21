# Choir Goal

Status: active product and architecture charter

Implementation status: the local Conductor-to-Goal-to-provider path is
implemented and directly launchable. The required hostile/fault matrix is
implemented and passing.

Decision state: the strategic direction—local durable authority,
provider-native Conductor sessions, isolated part execution, passive VSDD gates,
and no Zellij lifecycle dependency—is accepted. The items in the current
implementation snapshot below have direct implementation and test evidence.
Every other contract, command, adapter, state shape, delivery claim, and
provider-support claim remains provisional until implemented and proven by its
stated conformance oracle.

Research snapshot: 2026-07-19T19:50:26Z
Implementation snapshot updated through: 2026-07-21T18:40:00-05:00

## Charter Semantics and Readiness

This file specifies target behavior. It is not evidence that the current
MoonBit types, state stores, provider adapters, or commands already implement
that behavior. Deleted behavior and its tests are not acceptance evidence for
this product.

The words **must**, **must not**, and **required** are normative. A section
explicitly marked as an experiment or implementation gate may change after its
probe. A provider or runtime is not supported merely because its documentation
describes a capability or because one local invocation succeeded.

In conceptual schemas, `reason`/`status` placeholders mean closed versioned
enums or `ChoirError` suberrors defined by the durable schema; they never
authorize an open `String` domain.

## Current Implementation Snapshot

This snapshot describes the branch as of 2026-07-21 local time. It separates
working implementation from target behavior; passing fixtures do not make an
unconnected product path usable.

### Implemented and directly exercised

- The real subscription-native product path now completes from a Claude
  Conductor through one accepted Bead-backed Goal and a Codex Part. In a fresh
  disposable clone, Claude submitted the exact existing `pass-final` Bead;
  Codex produced the declared one-file candidate; Choir recorded twelve Part
  effect receipts, one Part verification receipt, one independent Part audit
  receipt, and one integration receipt; the combined Goal then recorded six
  assurance effect receipts, one Goal verification receipt, and one Goal audit
  receipt. The Goal branch contained exactly `LIVE_GOAL.txt` with
  `CHOIR_LIVE_GOAL_OK\n`, while the captured base branch remained unchanged.
  Branch publication was receipted; final PR creation remained absent because
  the disposable repository had no GitHub destination.
- A fresh installed-layout probe now completes a two-Part Goal with maximum
  parallelism two. Both Codex implementation Takes ran concurrently, each Part
  produced a passing verification receipt and independent audit receipt, and
  both candidates promoted into one continuous Goal branch. Combined-tree
  assurance then recorded two verification receipts, one independent audit
  receipt, and publication. BoxLite host CLI assurance operations are
  serialized because they share one local server; provider implementation
  sessions remain parallel.
- Git refs are no longer Conductor-authored Goal inputs. At submission,
  `choird` captures the checkout's current symbolic branch and uses that same
  durable ref as the base and integration target; detached checkouts fail
  explicitly. A live Codex Conductor submitted `ref-capture-live` without ref
  fields from `refs/heads/feature/ref-capture`. The captured ref survived Part
  implementation, verification, independent audit, promotion, combined-tree
  verification, and combined-tree audit. Publication then correctly requested
  input because the disposable repository had no remote.
- Trusted host runtime programs are now resolved only from an explicit absolute
  `CHOIR_RUNTIME_ASSET_DIR` or an installation directory adjacent to the Choir
  executable. `choir start` fails closed when either program is absent, and a
  target repository can no longer supply the sandbox MCP or BoxLite owner
  program. The documented local installation places the executable and both
  programs together under `~/.local/libexec/choir`.
- Startup now validates both trusted runtime programs, the BoxLite executable,
  and the corrected BoxLite runtime bundle before minting a Conductor
  credential or starting `choird`. Missing runtime configuration exits without
  leaving a daemon PID or socket; a disposable live probe also confirms that a
  complete runtime still opens the Codex Conductor and stops cleanly. The
  installed executable now also resolves an adjacent admitted `boxlite`
  executable and `boxlite-runtime` bundle, so the documented installation is
  self-contained and does not require runtime environment exports.
- Goal execution now runs in one supervised child process instead of blocking
  the daemon's control socket. A live installed-layout probe submitted a real
  Claude-Conductor Goal with a Codex Part, queried its durable status while the
  Take was running, killed only the Goal worker, and observed the daemon restart
  it while preserving byte-identical Goal status. The deliberately malformed
  disposable task then failed verification without integration, confirming
  that the responsive control path does not bypass passive receipt gates.
- The Conductor submission contract now names registered Moon arguments
  `moon_args`, documents that the executable is already selected, and rejects
  an argument list beginning with `moon`. A fresh installed-layout run exposed
  the prior ambiguity when Claude submitted `moon` as its own first argument;
  the repaired Claude `/goal` run selected Bead `live-szh`, assigned its Part
  to Codex, and persisted the exact command `moon test --target native` with a
  scratch target. Codex produced the requested two-file candidate; Part
  verification, independent Part audit, integration, combined-Goal
  verification, and independent Goal audit all passed. The Goal then paused
  with typed reason `GoalInputPublicationRemoteUnavailable`, as required for
  the disposable repository with no configured remote. A subsequent installed
  Claude status turn saw the nine-tool catalog, reported the exact active
  request and `choir goal answer <request-id> <answer>` command, and explicitly
  stated that it could not answer on the Goal's behalf. The durable input-answer
  count remained unchanged.
- Sealed Moon verification now stages the offline registry into a private
  writable Moon home and maps `.mooncakes` to scratch while the candidate tree
  remains read-only. Choir removes that generated cache link before every
  verification, audit, or combined-Goal result snapshot. Combined-Goal
  verification resolves the active durable sandbox lease rather than its
  planned identity, and it uses the same bounded resumable-cursor projection
  already enforced for Part harnesses.
- `choir stop` now terminates the exact daemon descendant tree, including
  provider children that created their own sessions, before cleaning runtime
  state. A native regression test proves cleanup of a nested separately
  sessioned child process; the live disposable daemon also stopped without a
  surviving matching provider or BoxLite process.
- Terminal Goal assurance and fully reconciled cancellation now remove the
  exact BoxLite runtime root instead of merely stopping its processes. Roots
  remain only while a Goal is genuinely recoverable, paused before terminal
  assurance, or uncertain. A fresh real Codex Goal completed implementation,
  verification, independent Part audit, promotion, combined verification, and
  independent Goal audit while the host's `choir-take-goal-*` root count stayed
  `0 -> 0`; the pre-fix probe had exposed four abandoned 4 GiB roots. Normal
  runtime cleanup also removes the disposable Codex Conductor home, while
  durable Goal state and evidence remain until explicit `stop --purge`. Purge
  now enumerates every durable Goal identity and removes each exact surviving
  runtime root before deleting the database. A live probe removed one seeded
  recoverable root and its durable state together; a forced BoxLite cleanup
  failure exited nonzero and preserved both root and database for an honest
  retry.

- `choir init` now scaffolds only the current project files, starts the local
  daemon without a terminal multiplexer, bootstraps one authenticated
  Conductor, and runs it in the invoking terminal. `choir start` reconnects the
  same direct launch path. Claude remains the default; selecting
  `--conductor codex` starts a persistent Codex subscription thread through
  `codex exec` and resumes that exact thread on later turns. The UDS is
  owner-only, the one-time Conductor bootstrap
  requires a same-user peer running the exact Choir executable, and the minted
  credential is passed only through a fixed typed process environment. The
  Claude Conductor loads only the generated Goal skill and the Choir MCP
  server; it gets no Claude built-in host tools, no ambient setting sources,
  no implicit Semble server, and no old spawn/file/merge tools in its MCP
  catalog. Codex starts from a sterile working root, ignores user configuration
  and repository rules, disables native execution, network, delegation,
  plugins, apps, hooks, memories, and browser surfaces, and admits only the
  same nine model-facing Choir tools. Its one-time Choir capability remains environment-only;
  the exact MCP child recovers only the fixed socket and capability names from
  its direct Codex parent when Codex filters the child environment. A live
  isolated process probe proves project initialization, authenticated Goal
  status, socket mode `0600`, restricted launch arguments, and zero Zellij
  requirement.
- A live cross-Conductor probe now persists one Goal, pauses it, and launches
  Codex and Claude independently against the same daemon authority. Each
  Conductor calls the same `goal_status` tool, observes the exact Goal ID and
  `GoalExecutionPaused` state, and returns its provider-specific success
  marker; the durable Goal remains paused after both sessions and the daemon
  stops cleanly. Claude's strict MCP configuration now names the canonical
  current Choir executable instead of resolving an ambient `choir` from
  `PATH`. Codex keeps its real provider home read-only while using a private
  writable state directory containing only a read-only link to the existing
  provider-managed login. This directly exercises Conductor replacement and
  reconnection without giving either provider workflow authority.
- The old session/tab startup, terminal status line, provider wrapper, hook
  bridge, prompt-sync commands, companion commands, Zellij registry, live pane
  test, command bundle, generated v1 role profiles, checked-in run state, and
  historical context corpus have been deleted. The daemon no longer runs the
  pane watcher, recovery scanner, PR poller, idle watchdog, or old Goal judge;
  its active background workflow is the durable Goal runner.
- The residual `src/workspace` package has been deleted. Its only live contents
  were the typed process command, Conductor process environment, and Claude
  launch assembly; those now live at the host-I/O seam in `src/exec`. The
  branch-point audit found no other unchanged v1 source file without a current
  caller. Provider-independent protocol, UDS, signal, build, and hook files
  that predate v2 remain because the current product still executes them.
- The linter no longer recognizes deleted v1 workspace, server, or runtime
  recovery APIs as special cases. Their dedicated exception logic and tests
  were removed; the general ban on real shell, process, and exec use in ordinary
  tests remains and is stricter now that the deleted executable-bit exception is
  gone.
- The positional and generic tool clients, shutdown-origin metadata path,
  arbitrary flag-to-tool translation, server-reload command, and their v1
  process fixtures are deleted. The remaining Goal client has one purpose: send
  typed Goal status/cancel/steer/attach/answer requests through an authenticated
  one-shot UDS connection. Its configuration resolver accepts only the fixed
  Conductor capability, workspace, and socket environment.
- The Conductor MCP initialization and catalog now describe only the current
  product. Claude receives the Conductor/Goal/Part/Take authority boundary and
  exactly nine typed Goal and Beads tools; old spawn, pane, worker, PR, and
  server-reload commands are absent. Structured arguments remain JSON through
  dispatch, while the removed stringified-argument format is rejected. The MCP
  package no longer imports the old tool registry.
- Authenticated Conductor tool calls now bypass the v1 tool dispatcher. The UDS
  binds the exact root identity, removes caller-supplied identity fields, and
  routes the nine-tool surface directly to the native Goal and Beads adapter;
  any other registered session and any unbound request fail closed. Goal
  submission, status, cancellation, steering, and attachment use the durable
  native stores. User input answers remain available only through the human-run
  `choir goal answer` CLI. Task list/get/create/update use typed `bd` commands
  through one injected execution capability, normalize Beads states to the
  public `todo`/`in_progress`/`done` domain, and remain hermetic under tests.
  Root bootstrap and registration now use a minimal Conductor server state that
  contains only the current configuration, daemon identity, and one-time root
  credential. The daemon has no generic agent registry, non-root session
  lifecycle, reload path, TCP listener, or fallback tool dispatcher. Obsolete
  transport tests for v1 tools and server reload were deleted rather than
  preserved as compatibility behavior.
- The closed v1 orchestration graph has been removed instead of retained behind
  the new server. This deletes the old server, tool dispatcher, phase engine,
  poller, pane runtime, evidence/hook/message/outbox/plugin/policy/registry
  packages, generic prompt library, WebAssembly hook project, mock forge CLI,
  old release helper, and terminal-multiplexer development dependencies. The
  current prompt package contains only the Goal skill used by the Conductor.
  This cleanup deletes 189 tracked files and more than 117,000 lines in the
  current change while adding only the narrow Conductor server and two Goal
  prompt files. The source tree drops from 372 tracked files to 198 files.
- The v1 workspace/spawn layer is also deleted: worktree spawning, provider
  child launchers, team membership, terminal-target construction, Zellij
  commands, Semble injection, and their broad test corpus no longer compile as
  dormant helpers. The interactive launch path now constructs one direct Claude
  Conductor command with the restricted Choir MCP and plugin settings. A live
  startup run passes with the direct command and no terminal multiplexer. This
  follow-up removes another 6,445 lines and leaves 190 source files.
- The Conductor MCP bridge and internal wire are now root-Conductor-only. The
  bridge reads its socket and one-time capability directly from the fixed
  launch environment, authenticates once per UDS connection, forwards no
  caller identity, and exposes only the exact Goal and Beads catalog. `choird`
  remains responsible for binding and overwriting the caller identity. The v1
  worker registration metadata, inline-child lookup, request-specific caller/
  branch augmentation, connection-lifetime variants, TCP fallback, and dead
  TCP reader have been deleted with their compatibility tests. This removes
  another 1,806 lines and leaves 189 source files.
- The Beads boundary now pins `bd` 1.1.0 at Conductor startup. `task_get`
  exposes description, acceptance criteria, dependency count, exact blocking
  dependency IDs, and whether dependency details were loaded. Goal submission
  validates the pinned issue/dependency shape and rejects missing, malformed,
  or count-mismatched dependency details before recording a selection. The
  real `choir init` → `choird` → restricted Conductor launch probe passes with
  the installed pinned client.
- The internal UDS request no longer carries a caller-supplied role. Conductor
  authority comes exclusively from the authenticated connection, the
  unauthenticated MCP catalog is empty, and legacy role-bearing request JSON is
  rejected. The launch capability is named `CHOIR_CONDUCTOR_TOKEN` end to end;
  registration carries only that capability. The remaining Beads status
  conversion moved out of the obsolete role/agent-named source file into
  `task_status_wire.mbt`.
- The v1 generated configuration-schema registry and generic spawn/tool type
  registry were referenced only by their own compatibility tests and are now
  deleted. The unused response-warning helper went with them. This removes 795
  more lines and leaves 185 source files.
- The runtime configuration contract now contains only `project_dir` and
  `listen_uds`, with machine-local values overriding the checked-in file. The
  Goal client and Conductor process environment no longer parse or carry v1
  roles, provider identities, parent/branch metadata, terminal targets, TCP,
  plugin/companion JSON, polling, review, pricing, model, or effort settings.
  The replacement removes 2,611 lines while preserving the same 185-file source
  tree. The live startup probe passes with only the capability, workspace, and
  socket exported to Claude.
- The remaining closed v1 workspace/execution and type islands are deleted.
  Choir no longer carries generic host execution, worktree provisioning, Agy
  cache/bootstrap, provider hook generation, hot reload, self-replacement,
  process-group pidfiles, shell-plugin capture, or their native C escape
  hatches and compatibility tests. The old standalone Goal evaluator, old
  audit-receipt format, agent/worktree/PR evaluation domain, and time parsing
  helpers were likewise referenced only by their own tests and are gone. The
  live types package now contains only the local transport roles, Beads task
  status, launch configuration, request/response wire, and `ChoirError`.
  Typed process data and restricted Conductor launch assembly live at the
  `src/exec` host-I/O seam; there is no residual workspace package. This
  follow-up removes a net 8,613 lines and seven more tracked source-tree files,
  leaving 173 tracked files under `src/`.
- Fixed-domain Goal, Part, Take, harness-session, event, assurance, receipt,
  integration, and cancellation types plus pure transition functions.
- Durable restart-readable state and content-addressed artifact stores with
  transactional fault injection.
- A hermetic conformance runner with injected clock, identifiers, adapters,
  and typed fault points. Its command now runs thirty-six registered cases: the
  runner dependency contract, `selection.exact_snapshot`,
  `selection.revision_invalidation`,
  `scheduler.generated_dags`, `branch.initialization_faults`, three integration
  cases, `seal.atomicity`, `sandbox.transfer_security`, six
  audit-authority/recovery cases, two cancellation-ordering cases, ten event/recovery
  cases, four mutation-ownership cases, and three process-policy cases described
  below. The audit cases prove a missing gate is passive, author Take/sandbox/
  session reuse is rejected, and seven independent subject/policy changes stale
  the old receipt. The three audit recovery cases restart between the durable
  result and receipt transactions, restart between the receipt transaction and
  passive gate evaluation, and fence a conflicting provider delivery. They
  prove exactly one authorizing receipt, no gate-produced work, and no receipt
  after protocol violation. Together with the specialized live/native reports,
  it implements the complete required case matrix.
- Claude and Codex now derive each durable harness-event payload digest only
  from the typed safe event kind and its redaction state. Provider tool names,
  terminal text, and raw trace fields are neither retained nor hashed; Codex
  source identity is the admitted provider cursor plus event ordinal rather
  than normalized provider text. Tool completion now retains only a typed
  succeeded/failed disposition. Provider terminal JSON is canonicalized from
  the validated typed outcome before verification or audit artifacts use it;
  undeclared response fields cannot cross that boundary. Captured verification
  process output is represented durably by exit code and digest rather than raw
  bytes. Driver tests inject synthetic secret bytes into tool names, provider
  text, tool output, header-like fields, terminal output, and process output;
  native Take environment tests prove exact allowlists with no provider-key or
  Conductor variables. None of those raw bytes appear in normalized events,
  terminal output, or durable evidence JSON. The standalone `event.redaction`
  hermetic case now runs both production provider normalizers with injected
  secret fields and proves its retained results and report contain none of the
  marker bytes; native environment and process-evidence checks remain in their
  narrow adapter tests.
- The Codex app-server event spool has a fixed 16 MiB admission bound. Crossing
  it now returns typed `EventIngestionOverflow`, terminates the exact recorded
  app-server process group, and causes the Part driver to atomically mark the
  session recovery-uncertain, the Take `RecoveryUncertain(CursorGap)`, the
  pending effect uncertain, and the Part recovery-uncertain. A pure bound test
  and a durable restart test cover the error and workflow state. The registered
  `event.backpressure` case now uses the same public capacity policy as the
  native log reader, exercises exact capacity and one-byte overflow, applies
  the production uncertainty transition, and reloads the snapshot to prove no
  event cursor, candidate, or receipt advanced. Choir selects typed overflow,
  rather than producer blocking, for this bounded disk-spool topology.
- Resumable implementation observations now commit their normalized event
  batch, provider cursor, terminal session projection, typed result, and exact
  effect receipt in one durable Part snapshot transaction. Replay reconciliation
  binds the effect ID, request digest, and observation digest; an exact replay
  after commit is a no-op, while a different effect cannot borrow that receipt.
  The registered `event.before_ingest_tx`,
  `event.after_ingest_tx_before_source_ack`, and
  `event.after_source_ack_before_next_read` cases inject each named boundary,
  restart from encoded durable state, and prove one two-event batch, one receipt,
  the exact persisted cursor, and continuation at candidate normalization. The
  native workflow fault fixture separately proves recovery at
  `WorkflowEffectObserved` consumes the durable witness without redispatching
  provider work.
- Nonresumable provider process loss and provider-dispatch timeouts now use the
  same durable uncertainty path. A nonzero Claude exit is typed
  `ProviderProcessLost`; the Part driver records the session as
  recovery-uncertain, terminates the Take as `RecoveryUncertain(EffectUncertain)`,
  blocks the Part, and persists that state before returning. A restart test
  proves no missing event or terminal success is inferred. The standalone
  `event.nonresumable_process_loss` hermetic case now applies the production
  uncertainty transition to an authorized dispatch, round-trips the durable
  snapshot, and proves that no candidate or verification, audit, or integration
  receipt can be inferred after restart.
- Claude and Codex CLI surface probes. The exact Claude subscription CLI
  profile passed its startup/tool-surface probe. The pinned Codex subscription
  CLI profile now also passes its live startup oracle: ChatGPT-managed login,
  native host read/write denial, required-MCP fail-closed startup, and an exact
  sandbox-only event trace are executable checks.
- Host-surface evidence now uses one typed, canonically ordered fifteen-row
  matrix matching `SURFACE-001` through `TOOL-SEARCH-015`. Passed and failed
  rows require content-addressed evidence; duplicates and invalid evidence are
  rejected; omitted rows become `NotRun`; and the matrix is complete only when
  all fifteen rows pass. The Codex live startup command currently proves only
  required-tool fail-closed startup and subscription identity, so its report
  correctly remains incomplete with two passed and thirteen unrun rows.
- A separate live Codex resume-attestation probe now proves `RESUME-010`.
  It starts a real turn, changes the effective allowed-tool manifest before
  recovery, and requires the native driver to reject the stale persisted
  session without changing its manifest or issuing a replacement turn. The
  combined live evidence now covers three of the fifteen host-surface rows.
- The native Codex Take driver now proves `SURFACE-001` at its pre-turn
  initialization barrier. Before sending `initialized` or starting a thread,
  it requires the pinned Codex identity, Choir client identity, sterile
  `CODEX_HOME`, and Linux/Unix platform identity returned by app-server. It
  records a content-addressed attestation in the durable Take manifest and
  independently rejects a HarnessSession whose declared tool-surface digest
  differs from the driver configuration before provider dispatch. The normal
  live Take command exposes the corresponding one-pass/fourteen-unrun matrix;
  combined live evidence now covers four rows, with eleven still unproven.
- A hostile-home Codex Take probe now proves `AMBIENT-002` for the admitted
  app-server topology. The driver uses a dedicated empty working directory,
  rejects any user-home or working-directory entry, and rejects Codex config,
  rule, plugin, skill, command, agent, or hook entries before authentication
  setup or provider startup. The live probe seeds both `config.toml` with an
  executable MCP canary and a hostile `AGENTS.md`; it observes no Take
  manifest, app-server log, or canary write. Combined live evidence now covers
  five rows, with ten still unproven.
- A live Codex process-tree probe now proves `CREDS-007` for inherited host
  environment values. It plants a fake credential in Choir's parent process;
  the probe MCP child writes a sentinel only if that value reaches it. A
  completed real Take produced no sentinel, no value in normalized events or
  terminal output, and no match anywhere in the dedicated Take state tree.
  Combined live evidence now covers six rows, with nine still unproven.
- A live KVM-backed BoxLite Take probe now proves `PATH-ID-006` through the
  exact sandbox MCP bridge admitted by the Codex Take surface. The bridge host
  working root and guest workspace contain the same relative filename with
  distinct canary values. MCP reads observe only the initial guest value, MCP
  mutation replaces only the guest value, the copied candidate contains that
  mutation, and the host canary remains byte-identical. The report binds the
  logical path, both host observations, both guest observations, and bridge
  output to one content-addressed evidence digest. Combined live evidence now
  covers seven rows, with eight still unproven.
- A live Codex Take probe now proves `DEATH-008` through Choir's production
  sandbox MCP bridge with its underlying sandbox transport deliberately dead.
  The bridge initializes and exposes only `read_file`; Codex calls it once,
  the call fails, and the driver returns the typed `validation_error` for an
  all-failed declared-tool trace. Native tool use, an undeclared MCP call, a
  missing call, or fabricated success produces a different fail-closed result
  and cannot satisfy the row. The evidence binds the exact effective surface,
  production bridge digest, typed error class, and terminal reason. Combined
  live evidence now covers eight rows, with seven still unproven.
- A live Codex Take probe now proves the no-delegation branch of `CHILD-009`.
  The exact effective-surface digest binds `multi_agent`, `multi_agent_v2`, and
  `enable_fanout` as disabled. Hostile repository text demands a native child,
  a new host root, an outside read, a network connection, and another Codex
  harness; the real subscription-backed turn instead emits exactly one allowed
  `probe` call on the original session and closes cleanly. The driver rejects
  any native or unknown provider item, so a child event or extra capability
  cannot be hidden by terminal prose. Evidence binds the disabled-feature set,
  exact session/surface, normalized trace, and terminal-response digest.
  Combined live evidence now covers nine rows, with six still unproven.
- A live Codex Take probe now proves `TOOL-SEARCH-015`. Hostile repository text
  requests discovery and dynamic loading of a deferred tool from another MCP
  server, plugin, app, skill, or native registry. The exact surface disables
  `tool_suggest`, exposes only the pre-attested `probe` tool, emits exactly one
  successful call to it, and closes the original session cleanly. The driver
  validates raw provider items before normalization, so an undeclared tool or
  native discovery event fails instead of disappearing from the evidence.
  Evidence binds the effective surface, disabled features, exact four-event
  trace, and terminal response. Combined live evidence now covers ten rows,
  with five still unproven.
- A combined live Codex/BoxLite probe now proves `CANCEL-014`. One real Codex
  turn is interrupted immediately after turn start and records zero tool
  starts; a second is interrupted only after one delayed MCP call has started
  and records exactly that one pre-cutoff start. Both persist one
  `CodexTurnInterrupted` disposition and leave no process containing the
  dedicated runtime identity. The existing production BoxLite cancellation is
  joined into the same evidence and still preserves one uncertain authorized
  implementation, one interrupted Take, one recovery-uncertain session, and no
  verification, audit, or integration receipt. The no-delegation surface binds
  the child-work branch. The first strict run exposed a surviving MCP process;
  both the probe and production sandbox bridges now terminate on stdin closure,
  and the production bridge aborts active BoxLite commands before exit.
  Combined live evidence now covers eleven rows, with four still unproven.
- The Codex Take and Conductor now execute the already-pinned native client
  directly, without the package-manager JavaScript wrapper, beneath a
  fail-closed Bubblewrap mount boundary. The host filesystem is read-only,
  `/dev` and a fresh `/proc` remain available, and only the exact sterile
  session root is overmounted writable. A narrow local adapter probe proves an
  inside write succeeds while the same executable cannot create an adjacent
  outside file; it emits content-addressed passing evidence for
  `HOST-WRITE-005` and `MUTATION-011`. A normal subscription-backed Codex Take
  then completed its one declared MCP call inside the same boundary. This
  replaces the provisional syscall-observer experiment entirely. Combined
  evidence now covers thirteen rows; `HOST-READ-004` and `NETWORK-012` remain.
- The admitted Codex Bubblewrap boundary now replaces host `/tmp` with a fresh
  private filesystem before rebinding the exact sterile session root. A live
  subscription-backed Take proves `HOST-READ-004`: its declared MCP child
  attempts to read a synthetic secret from a host sibling path, observes only
  a typed denial marker inside the sterile root, completes the one declared
  tool call, and retains none of the secret in normalized events or terminal
  output. Combined live evidence now covers fourteen rows; only `NETWORK-012`
  remains unproven.
- A live subscription-backed Codex Take now proves `NETWORK-012` from inside
  the admitted Bubblewrap boundary. The exact Codex/app-server/MCP process tree
  is traced only for network connection attempts; the typed evaluator accepts
  provider HTTPS, DNS, and runtime address-selection probes, rejects the
  loopback canary and every unclassified Internet transport, and retains only
  canonical counts plus a content digest. The passing run recorded six
  provider HTTPS connections, zero loopback-canary attempts, and zero
  unclassified transports. Together with the already passing BoxLite guest
  network policy, all fifteen Codex host-surface rows now have exact live
  evidence.
- Codex MCP resource discovery is now classified as provider-side discovery,
  not as a Part effect, only for the two read-only discovery methods and only
  when Codex identifies either the exact declared server or its reserved
  `codex` discovery server. Balanced discovery is omitted from durable
  tool-effect events and cannot satisfy the requirement that a declared Part
  tool actually runs. Every non-discovery call still requires the exact Choir
  server and allowlisted tool; other servers and tools fail closed.
- A pinned BoxLite v0.9.7 lifecycle/security adapter using the checked-in
  seccomp correction. Live KVM boot, clone isolation, bounded transfer,
  attach/signal/kill, restart re-adoption, read-only enforcement, and declared
  network-denial probes passed on the recorded host. Every live execution path
  resolves the CLI from one validated operator override or `PATH` and requires
  an explicit absolute corrected-runtime directory; no machine-user path is
  compiled into the product.
- Model-directed sandbox tools now reach BoxLite only through an owner-only
  Unix socket. The runtime owner holds the loopback REST credential and admits
  one exact, bounded guest-execution request; the capability given to an MCP
  bridge is derived for one box and one mutable or read-only access mode. The
  bridge receives no BoxLite binary, runtime directory, REST URL, or REST key.
  Startup requires the exact admitted CLI and six-file runtime identities,
  socket mode `0600`, and a live owner process; drift fails before image pull or
  KVM execution. Owner and runtime processes are stopped during Take cleanup.
  The stock REST surface remains a private implementation transport for
  trusted control-plane lifecycle operations and is not exposed to a
  Conductor, provider process, MCP bridge, or guest.
- A restart-safe native Part workflow. It creates an isolated BoxLite sandbox,
  dispatches the typed harness session to the official Claude or Codex
  subscription CLI with only the generated sandbox MCP tools, executes an
  implementation Take, normalizes a candidate, runs typed verification,
  launches a separate audit Take, and promotes the accepted candidate through
  the native Git integration adapter. The full BoxLite fixture passes with
  either Claude or Codex for implementation, verification, and audit. The
  Codex run uses the real ChatGPT-authenticated client, resumes after the
  implementation boundary without redispatching it, and produces exactly one
  verification, audit, and integration receipt. Every Codex Take now supplies
  a fixed role-specific JSON output schema to the installed client; terminal
  prose cannot substitute for an implementation, verification, or audit
  result.
- Part persistence now distinguishes an audit result transaction from ordinary
  effect observation. The native fault fixture crashes independently at the
  durable audit-result and audit-receipt boundaries. Recovery reads the exact
  stored result, creates one receipt, performs zero duplicate provider work,
  and finishes with one verification, audit, and integration receipt. The
  fixture reports both recovery checks explicitly and covers eight durable Part
  boundaries in total.
- Conflicting durable effect witnesses now retain the first row and return the
  typed `ProviderProtocolViolation` error instead of a generic validation
  failure. When that violation comes from an authorized provider dispatch, the
  Part driver atomically marks the exact session `ProtocolViolated`, the Take
  `RecoveryUncertain(ProtocolViolation)`, the pending effect uncertain, and the
  Part recovery-uncertain. A storage test proves the first witness remains and
  no receipt is minted; a native restart test separately proves the blocked
  snapshot is durable. The native Part lifecycle fixture also injects two
  conflicting terminal results for the exact audit Take and proves the first
  witness remains, the audit session/Take/Part are durably fenced, and no audit
  receipt is minted. It reports `audit_protocol_conflict_checked` and is also
  registered as the standalone `audit.protocol_conflict` hermetic case.
- `cancellation.part_effect_ordering` now runs four production Part-effect
  cancellation orderings in the hermetic report. Planned provider and
  integration effects are abandoned; an authorized
  provider effect becomes durably uncertain; and an authorized integration is
  preserved unchanged for witness reconciliation. Every result round-trips
  through the durable snapshot codec, known dispositions are terminal, and
  replay of the unresolved integration performs no mutation.
- `cancellation.ordering_matrix` now composes the branch-initialization and
  Part-effect cases with the production Goal-assurance, publication, final-PR,
  and terminal lifecycle transitions. It checks twenty-three cancellation
  orderings: twenty-two reach a known or terminal disposition, while an
  authorized branch seal correctly remains unresolved until its exact witness
  is observed. Replaying the resulting records is mutation-free.
- Codex Takes now use one restricted `codex app-server` process per Take over a
  private stdio FIFO and bounded owner-only response log. Choir durably binds
  the exact session, thread, turn, deterministic client-message ID, request
  ordinals, process generation, initialization-notification uncertainty, and
  terminal trace before advancing workflow state. A dedicated supervisor and
  generation-keyed PID witness keep the exact process group identifiable even
  when its original launcher disappears or its leader exits before a child.
  Recovery adopts only a matching live group; an uncertain `initialized`
  notification kills that generation and starts a new one instead of resending
  to it. Terminal recovery records the exact result before idempotently stopping
  every non-zombie member of the owned group. A real subscription matrix killed
  four clients after server creation, after the `initialized` notification,
  after turn persistence, and after terminal persistence. Each replacement
  either adopted or safely replaced the exact generation, completed one Take
  with one sandbox probe call, retained the same persisted turn where one
  existed, and left no running provider process. A
  separate real BoxLite fixture proves `turn/interrupt`, process-group cleanup,
  durable cancellation, and zero provider redispatch after restart. The private
  spool is capped, contains no provider credential, and is removed with the Take
  runtime root after its terminal evidence is durable. Workflow trace replay now
  adopts one bounded resumable provider cursor and rejects cursor changes; the
  full Codex Part lifecycle passed again after this recovery contract was wired
  through the workflow authority.
- A concurrent Goal runner with conflict-aware admission and deterministic,
  serialized promotion. A native Git fixture proves that divergent candidates
  based on the same head are composed into a continuous promotion history and
  final combined tree.
- Fixed-seed generated dependency graphs now exercise scheduling across
  multiple graph shapes, mutation-declaration mixtures, input permutations,
  and concurrency limits. Every run asserts dependency readiness, capacity,
  pairwise mutation exclusion, eventual progress, and input-order-independent
  promotion order. The same oracle is registered in the hermetic conformance
  runner and emits typed counts for four graphs, 32 schedule runs, eight
  promotion runs, and 680 Part evaluations.
- A terminal successful Goal now exposes a typed `SemanticRunProjection`
  through ordinary Goal status. It is derived from the exact durable Part,
  assurance, publication, PR, readiness, and terminal records and retains the
  accepted Part/dependency set, task and change digests, authorizing
  verification slots and outcomes, audit policy/outcome, deterministic
  promotion ranks and resulting trees, final tree, receipt-kind cardinalities,
  and terminal outcome. It rejects incomplete or cross-Goal evidence and
  deliberately excludes Take/session/execution/receipt identities, provider
  prose and identity, timestamps, candidate/promotion commit identities, and
  remote PR number/URL. A checked-in six-Part mixed-provider manifest now runs
  the complete synthetic flow at concurrency limits 1, 2, and 4. Each run
  produces six Part verification sets, audits, and integrations plus one Goal
  verification set, combined audit, publication receipt, final-PR receipt, and
  successful terminal projection. All three runs produce the same promotion
  order and exact `SemanticRunProjection` digest. The manifest digest is
  `72077199c2544cbae292a9778733b34c72853a835fc5a3a36f57573bb4bb88df`;
  the resulting semantic digest is
  `04b1e37c4607053f603e432b751cd57c9e41ec380beeb2265fbad8d76979a74e`.
- The final-PR remote-state matrix now directly proves the declared policy for
  closed, retargeted, head-changed, human-edited, and duplicate-marker PRs.
  Closed, retargeted, and head-changed PRs are not replaced and enter their
  exact needs-input state; duplicate markers refuse canonical identity.
  Title/body edits are preserved, adopted, and bound into the receipt as
  observed digests rather than overwritten.
- Exact selection is now a registered hermetic case using the production
  evaluator. It proves deterministic identity under input permutation, one
  valid acceptance, the exact five typed rejection classes for missing,
  duplicate, closed, dependency-incomplete, and ambiguous Parts, and zero
  dispatch before an accepted decision exists.
- Revision invalidation is now a registered hermetic case using production
  Goal steering and the production audit gate. A durable concurrency revision
  preserves the exact valid receipt, while an assurance-policy revision stales
  it as policy evidence and a task-contract revision stales it as subject
  evidence.
- Harness event ingestion now has registered hermetic cases for duplicate
  conflicts, cursor gaps, late terminals, and conflicting terminals. A
  conflicting replay is retained at the next Choir observer sequence rather
  than reusing its old provider-supplied sequence, so protocol violation can
  never move the durable observer cursor backward. A
  completion observed after an authoritative interruption is retained only as
  a late diagnostic while the interruption remains authoritative. A distinct
  failure after an observed completion retains the first event and moves the
  session to recovery uncertainty, making it receipt-ineligible. The runner
  emits the exact typed disposition, resulting session lifecycle, and late
  marker for each case.
- Mutation ownership now has registered hermetic cases for path normalization,
  the symmetric conflict truth table, candidate under-claiming, and raw paths
  produced by rename/delete/generated-file changes. The runner emits typed
  evidence for 11 normalization rows, eight conflict rows, the exact omitted
  path in the under-claim case, and all four raw changed paths in the combined
  rename/delete/generated-file case. Missing or unknown declarations remain
  conservative conflicts, and a candidate cannot widen its own declaration
  after execution.
- Native candidate normalization now obtains the raw NUL-delimited Git paths
  for additions, deletions, rename sides, generated files, case-distinct names,
  symlinks, and Unicode names. A tightly isolated native Git fixture proves all
  eight changed paths are retained and the candidate symlink identity is
  exposed to validation. Goal submission and Part execution now share one
  fail-closed NFC oracle backed by the host `libutf8proc`; composed Unicode is
  accepted, decomposed Unicode is rejected, and unavailable normalization
  support blocks submission rather than silently accepting paths.
- Typed process validation now has registered hermetic cases covering one
  canonical process plus 12 hostile rows and four authority-fence rows. The
  cases reject unregistered shell/eval requests, absolute, wildcard, and
  `.git` working directories, forbidden/duplicated/NUL environment data,
  NUL/oversized arguments, missing script artifacts, network enablement,
  policy drift, wrong-Take authority, cross-Take artifacts, verification-owned
  script artifacts, and capability-disallowed interpreters. Every hostile row
  proves zero calls to the sandbox execution adapter. Interpreter admission is
  now an explicit capability callback, and a verification Take cannot use its
  own output artifact as an authorizing executable.
- Canonical process dispatch is now a registered case. It hashes the exact
  canonical persisted specification, carries that digest with the typed
  execution request, and proves that the adapter receives the same capability,
  owning Take, resource/execution keys, executable, arguments, environment,
  logical working directory, limits, network policy, and output policy. The
  real BoxLite execution path independently recomputes the decoded process
  digest and rejects drift before launching; both Part and Goal verification
  pass their persisted verification-spec digest into that check.
- Process execution now has a durable identity and state record distinct from
  its enclosing provider effect. Before BoxLite dispatch, Choir persists the
  owning Take, exact sandbox lease and generation, authority, validated process
  digest, capability/input digests, and a deterministic runtime key, then
  records `MayHaveOccurred`. A terminal exit persists its code, output digest,
  and exact start/finish observations before verification evidence can depend
  on it; replay consumes that terminal record without executing again. The
  pinned `boxlite serve` handler does not implement its advertised idempotency
  key and assigns an execution ID only after starting the guest process, so an
  ambiguous start is never retried. Recovery destroys the complete registered
  Take generation, records terminal process uncertainty, and lets the enclosing
  Part or Goal assurance become recovery-uncertain. The registered
  `effect.process_start_terminal_faults` case and the production persistence
  test cover crashes before authorization, after authorization, after guest
  dispatch, and after terminal persistence, with a maximum of one dispatch in
  every row.
- Verification and audit now execute against a sealed read-only subject with
  separate writable `/scratch` and `/output` roots. Their MCP surface exposes
  only candidate reads plus scoped scratch/output writes; candidate mutation
  and arbitrary process tools are absent. Typed assurance processes run as an
  unprivileged guest identity, require a unique `/scratch` target, and receive
  fixed scratch-backed `HOME` and `TMPDIR` values. The live
  `process.audit_scratch_boundary` probe proved candidate writes and arbitrary
  execution were rejected, declared scratch/output writes persisted, the
  copied Git tree stayed identical to the sealed subject, and the typed process
  completed without a workspace write. The boundary uses an explicit
  privilege drop because the tested BoxLite user-selection option did not
  enforce the required guest identity on this surface.
- A mixed-provider native Goal fixture using one real Claude subscription Part
  and one real Codex subscription Part. Both implementation paths execute
  concurrently in separate BoxLite Takes, each candidate receives its own
  typed verification and independent audit, and Choir then promotes both in a
  deterministic serialized order. The passing run produced 24 effect receipts,
  two verification receipts, two audit receipts, two integration receipts, and
  the expected combined Git tree.
- A typed Conductor submission seam. The native adapter decodes a strict Goal
  draft, independently captures the Git root/base commit/base tree and the
  exact Beads JSON revisions, adopts task instructions and registered Moon
  verification process specifications as content-addressed artifacts, validates
  the exact dependency closure and mutation declarations, and transactionally
  persists a restart-readable `SelectionDecision` before any Take can run.
  After acceptance it also materializes one deterministic planned Part
  workflow per accepted contract; rejected proposals create none, and restart
  replay verifies rather than duplicates those initial snapshots. A Conductor-only
  `goal_submit` tool exposes the transaction through the existing server and
  MCP bridge, and the synthesized Claude plugin now includes `/goal`
  instructions that translate the conversation and existing Beads into that
  typed draft. An identical submission replay compares only the immutable Part
  plan and identities, preserving any Takes, effects, and receipts already
  recorded after acceptance.
- Accepted submissions now become restart-discoverable execution records. Each
  record binds the accepted Goal and selection digest to the captured Git base,
  deterministic Goal ref, admitted Part workflow identifiers, concurrency
  limit, and a fenced execution state. The native daemon enumerates these
  records without relying on process memory, advances queued Goals through the
  existing Part runner, and derives the Goal outcome from the reloaded durable
  Part states rather than trusting an execution adapter to declare success.
  Promotion remains serialized against the current Goal ref. Part integration
  now advances the Goal to the nonterminal `GoalExecutionAssuring` state; the
  state machine cannot enter `GoalExecutionSucceeded` directly from ordinary
  execution. A joined native
  conformance run submitted a one-Part Goal in a disposable repository, used
  the real ChatGPT-authenticated Codex client inside BoxLite for implementation
  and independent audit, ran typed verification, and integrated the Part with
  exactly one verification, audit, and integration receipt. A preceding run
  whose audit reported a blocking finding correctly stopped at
  `GoalExecutionBlocked` and did not bypass the gate.
- Goal-branch initialization is now a durable pre-dispatch protocol rather
  than an implicit Git side effect in Part execution. The Goal execution record
  carries the deterministic intent, witness ref, idempotency key, lifecycle,
  and receipt. The runner first commits authorization, then the native Git
  adapter atomically creates the Goal and initialization-witness refs from the
  captured base, re-observes both refs, and commits the receipt before admitting
  any Part. Both-absent recovery permits only the exact authorized retry;
  one-sided state blocks on integrity and divergent state pauses as uncertain.
  Cancellation before authorization abandons the intent without touching Git;
  cancellation after authorization must reconcile the exact transaction before
  terminal cancellation. The registered `branch.initialization_faults` case
  round-trips every durable state across all four named boundaries and covers
  pre/post-authorization cancellation. A narrow real-Git test proves the two-ref
  transaction is atomic, replay observes the same anchor, and partial ref state
  is detected.
- Native Git promotion now retains a typed immutable `IntegrationConflict`
  instead of collapsing a failed three-way merge into an unstructured block.
  The record binds the candidate, expected Goal head and tree, actual merge
  base, canonical conflicting paths, and evidence digest. The scheduler may
  then persist a fresh implementation Take under a task-contract revision that
  references that conflict and starts from the exact authoritative head. Old
  contracts and Takes remain in snapshot history; candidate, verification,
  audit, and integration evidence are cleared so the repaired candidate must
  pass the full Part workflow again. Repair admission is guarded by the same
  running-Goal precondition as ordinary effects, and the initial product policy
  permits two repairs before leaving the Part blocked. The registered
  `integration.conflict_repair` case proves history retention, subject reset,
  and fresh verification/audit Take identities; native Git tests prove
  merge-base and NUL-delimited path capture. The Goal adapter accepts only the
  exact revised record loaded from durable state, so the next scheduler pass
  can advance the repair without accepting a stale caller record.
- Goal assurance now has separate typed Goal-tree verification and combined-
  audit subjects, receipts, results, authorization slots, and passive gates.
  The combined audit rejects a Take, sandbox generation, or harness session
  that contributed to prohibited earlier work. A durable Goal assurance record
  canonicalizes the complete integration-receipt chain from the base to the
  exact final head, derives the combined verification plan and versioned
  assurance policy, and persists a planned, authorized, witnessed, then sealed
  branch state. Every assurance write is atomically guarded by the exact
  running Goal record, so cancellation and seal authorization have a defined
  transaction order. The native Git adapter creates and reconciles one exact
  immutable seal witness ref; repeated observation is idempotent and later
  Goal-ref movement blocks readiness. Narrow tests cover the passive gates,
  receipt-chain validation, record round trip, cancellation race, and real Git
  witness behavior. Native execution is now connected as six separately
  authorized and witnessed effects: prepare/start/dispatch for combined Goal
  verification, followed by prepare/start/dispatch for the independent Goal
  audit. Each effect re-adopts the exact stopped BoxLite sandbox generation
  from its durable resource record; it does not rebuild or silently replace
  the subject. The exact persisted Part instructions are included in both
  provider Takes, so the verifier and auditor evaluate the sealed tree against
  the actual accepted work rather than hashes without intent.
- A live disposable-repository run completed the full joined Codex path through
  `GoalExecutionAssured`. It produced one integrated Part, one immutable Goal
  seal, one passing combined verification receipt, one passing independent
  Goal-audit result and receipt, two distinct Goal assurance Takes, two
  distinct sandbox generations, two distinct harness sessions, and six effect
  receipts. Both assurance Takes observed the exact sealed tree before and
  after execution. Resubmitting the identical accepted Goal returned the same
  terminal state immediately without dispatching another provider Take.
- Branch publication now has a typed durable intent, authorization,
  observation, receipt, drift, uncertainty, and cancellation-disposition
  model. Its deterministic identity binds the exact assured Goal, sealed head,
  seal digest, combined verification evidence, independent Goal-audit receipt,
  remote repository identity, remote name, and remote head ref. Publication
  records use the same guarded SQLite commit as other finalization state, so a
  stale Goal record cannot authorize or receipt a remote effect. The native Git
  adapter observes the exact remote ref, includes that expected old OID as an
  exact push lease with local hooks disabled, re-observes the remote after every
  request, adopts an already exact head on recovery, and refuses drift. Ancestry
  authorization remains separate, so the lease cannot admit a non-fast-forward
  transition. A real local-bare-remote test covers absent-ref creation, exact
  prior update, concurrent create/update races, replay, and adversarial drift.
  A second real Git and durable-storage test injects every named publication
  crash boundary, restarts from disk, and proves convergence on the exact
  remote OID and one receipt while the Goal remains merely assured.
  A disposable completed Goal was also published through the durable adapter
  at exact sealed OID
  `55cd8b2a425a833631b269c2a9ea7481c92966f5`; a second process invocation
  returned `GoalPublicationComplete` without changing the remote.
- Canonical final-PR reconciliation and final readiness now have typed durable
  records. The PR intent binds the exact Goal, sealed and published head,
  combined evidence, target ref, generated title/body artifact, and a
  deterministic body marker. Choir scans all open, closed, and merged PR pages
  before create; it adopts one exact marker, blocks markerless possible
  matches and duplicate markers, preserves closed/drifted identities as
  user-input states, and moves to `CreateMayHaveBeenIssued` before the one
  allowed create request. Restart from that state only observes and never
  resends. Readiness is a separate fresh observation requiring the exact open
  PR, repositories, refs, sealed head, marker, Goal-contract link, and evidence
  link. The terminal success write compare-and-sets the assured Goal while
  atomically guarding the exact readiness record, so a concurrent later
  observation or cancellation wins rather than being ignored. The ordinary
  Goal runner now advances assured Goals through publication, PR
  reconciliation, readiness, and `GoalExecutionSucceeded`. A real Git,
  durable-storage, and controlled-forge test injects all seven named PR
  intent/create/receipt crash boundaries. Recoverable cases adopt one remote
  PR and one receipt without duplicate create; a crash after recording that a
  create may have been issued but before dispatch remains explicitly uncertain
  and is never resent.
- A synthetic-forge disposable-repository proof exercised that entire durable
  finalization path without creating an external PR. It persisted the one-shot
  PR boundary and receipt, replayed the PR command without duplication,
  recorded `PullRequestReady`, committed `GoalExecutionSucceeded`, replayed
  success, and then repeated the finalization through the ordinary Goal tick.
  The native forge parser separately covers exact-marker, possible-existing,
  duplicate-marker, invalid-response, and complete paginated-result cases.
- Durable Goal inspection is connected through the Conductor-only `goal_status`
  tool.
  Given a Goal ID, it reloads the authoritative execution record and every
  bound Part snapshot, validates their identities, and returns typed Goal and
  Part lifecycle state, provider surface, workflow stage, durable version, and
  receipt cardinalities. It also returns the durable Goal-assurance stage and
  immutable branch seal when present, plus the Goal-level sandbox, harness,
  effect-receipt, verification-receipt, and audit-receipt cardinalities. The
  response also exposes the branch-publication state, canonical remote
  identity and head ref, receipt presence, and published OID when present. It
  also reports final-PR state/receipt/number/URL and the finalization ID,
  readiness decision, and observation sequence. The
  Claude `/goal` skill uses this path for status requests rather than
  resubmitting work. A separate process successfully inspected the integrated
  joined Goal after its execution process exited.
- Goal policy steering is durable and replay-safe. `goal_steer` and
  `choir goal steer` create versioned concurrency, pause, and resume revisions;
  pausing prevents runner admission, resuming restores the captured execution
  state, and recovery uncertainty remains distinct from an operator pause.
  Status exposes the active revision and every Part and assurance Take ID.
- `goal_attach` and `choir goal attach` return the durable normalized sessions
  and gap-checked event journal for one Take. The path reloads state by Take ID
  after restart and is strictly observational.
- Finalization outcomes that need a person now create one durable typed input
  request and pause the Goal. `choir goal answer` binds the user's answer to
  that exact request as an immutable artifact, replays the same answer safely
  after restart, rejects conflicting answers, and resumes only the captured
  state. `goal_answer` is deliberately absent from the model-facing MCP
  catalog, so a Conductor can report the request but cannot satisfy it.
  Ordinary resume steering cannot bypass an active request.
  An assured Goal whose repository has no `origin` now follows this path with
  the exact `GoalInputPublicationRemoteUnavailable` reason. It creates no
  publication intent and does not retry on each daemon tick; after the user
  configures the remote and answers the request, the same assured Goal resumes
  publication through the ordinary passive gate.
- The Goal skill is the sole Conductor instruction contract. Claude consumes
  its generated plugin form; Codex receives the same contract as explicit
  developer instructions. Both are directly launchable Conductors, and both
  Claude and Codex remain supported as subscription-backed Part providers.
- Goal cancellation now has a durable, replay-safe cutoff and a Conductor-only
  `goal_cancel` tool plus `choir goal cancel` CLI path. The runner prioritizes
  canceling Goals, a passive authorization check prevents Parts from planning
  or authorizing new effects after the cutoff, and a clean queued Goal can
  reach terminal cancellation without starting BoxLite or a provider. Native
  Claude and Codex Takes run in Choir-owned process groups; cancellation kills
  the provider and sandbox-MCP process tree and then cleans up BoxLite. The
  process-group kill and the zero-work cutoff path have narrow executable
  tests. Mid-Take cancellation now persists the Take interruption, uncertain
  sandbox/session disposition, blocked Part, and uncertain or abandoned effect
  before terminal Goal cancellation; restart replay preserves that result. An
  already-authorized Git integration is reconciled from the exact local Goal
  and witness refs before its observation and cancellation disposition are
  persisted. Part effect planning, effect authorization, integration planning,
  and integration authorization use a guarded SQLite commit against the exact
  running Goal record, so a concurrent cutoff either follows the authorization
  or rejects it without a Part mutation or outbox record. Both transaction
  orderings have executable tests. A live Codex/BoxLite fixture also proves
  that the real provider process group is interrupted and reloaded as one
  durable uncertain implementation effect.
- Cancellation now also loads and reconciles the durable Goal-assurance
  record before terminal cancellation. A planned branch seal is abandoned; an
  authorized seal remains unresolved until its exact witness transaction is
  reconciled; witnessed or committed seals are preserved. Planned combined
  verification/audit effects are abandoned, possibly-issued effects become
  uncertain, active Takes are interrupted, and active sandbox/session
  resources receive terminal uncertain dispositions. The canceled assurance
  record round-trips through durable storage under the canceling Goal's exact
  precondition, and replay is stable.
- Cancellation now reconciles durable branch-publication and final-PR records
  before terminal Goal cancellation. Planned effects are abandoned, authorized
  or possibly-issued effects receive one fresh remote observation, exact remote
  results are receipted, drift is preserved, and unresolved observations remain
  explicitly uncertain. Publication distinguishes preflight uncertainty from
  post-mutation uncertainty, and both publication and PR reconciliation can
  recover from their uncertain states without resending a remote mutation.
- Final-PR readiness now has an executable response-boundary and terminal-race
  oracle. A typed fault after durable readiness but before terminal success
  proves that cancellation can install its cutoff and permanently exclude
  success; the inverse ordering returns success as already terminal. Controlled
  remote edits prove that missing evidence before the readiness response blocks
  success, while an edit after that response does not retroactively rewrite the
  already-linearized observation. Both terminal orderings emit one durable
  outbox record and no later terminal record.
- Native Goal runtime identities include both repository and Goal identity, so
  equal Goal IDs in different repositories cannot collide in sandbox, staging,
  integration-control, or BoxLite state. Runtime paths use product-purpose
  names without a branch/version label.
- BoxLite runtime cleanup now restores owner-write permission only after the
  sandbox server and boxes are stopped, then removes the exact validated
  runtime root. Read-only assurance copies therefore remain immutable while
  in use without accumulating sealed temporary trees afterward.
- The repository linter admits only the narrow injected exec-adapter tests and
  explicitly tagged real-process fixtures used by this implementation.

Earlier evidence anchors are commits `5fb93fe8` for the native Part path,
`2a184a59` for concurrent Parts and serialized promotion, and `0443cc3c` for
the linter correction. With the current assurance, cancellation, and provider changes,
`moon check --target native`, `moon test --target native`, and
`moon run --target native src/bin/choir_lint` all exit successfully on
2026-07-21. After deleting obsolete source and tests, the full native suite reports 358
passed and 0 failed. The
compiler still reports the repository's existing warning set.

### Bounded conformance behavior

- Checked-in Part fixtures still provide narrow, reproducible coverage of the
  Part lifecycle with Claude and Codex independently.
- The concurrent native Git fixture creates candidate commits directly through
  fixture code. It tests scheduling and promotion, not concurrent provider task
  execution.
- The mixed-provider Goal fixture supplies two checked-in execution contracts.
  It proves concurrent provider dispatch and serialized integration.
- The fixed mixed-workload fixture supplies six content-digested Part
  contracts with two independent roots, dependency joins, and alternating
  synthetic Claude/Codex surface identities. It drives the real scheduler,
  durable Part workflow, serialized promotion, Goal assurance, publication,
  PR, readiness, and terminal projection at concurrency limits 1, 2, and 4.
  The admitted parallelism is 1/2/2 and every run has the same semantic result.
- A direct Claude Conductor `/goal` turn in a disposable repository used the
  restricted MCP surface to inspect Beads and submit a durable Goal. The
  daemon then ran the accepted Part through Codex implementation, native Moon
  verification, an independent Part audit, promotion, combined-tree
  verification, and an independent Goal audit. The run stopped honestly at
  publication because the disposable repository had no remote. That condition
  is now a durable, visible input request rather than a hidden retry loop. This
  does not prove interruption during an in-flight Goal-level provider dispatch
  or final publication and PR creation against a real destination.

### Conformance closure
- Duplicate conflicts, cursor gaps, late terminals, conflicting terminals,
  fixed-seed generated DAG scheduling, ownership normalization/conflicts,
  candidate under-claiming, and rename/delete/generated-file path coverage are
  registered in the hermetic runner. Native Git acquisition separately proves
  deletion/rename sides, case-distinct paths, symlink identity, and
  composed/decomposed Unicode handling. Process validation, authority fencing,
  and canonical persisted dispatch are also registered. The
  audit-scratch-boundary case now passes on
  the live BoxLite Take path; it is intentionally not reported as hermetic.
  The fixed scale flow is joined to the full semantic projection; the remaining
  negative cases retain their own typed blocked/recovery oracles. The host
  surface now has an executable fifteen-row report rather than an implied
  aggregate pass; every Codex row now has its exact live oracle and passing
  evidence.
  Deterministic promotion ordering across all three-Part completion timings and
  composition of two candidates based on the same head into a continuous
  two-parent promotion/receipt chain are now independently registered.
  Native Git integration also has typed fault injection after promotion-object
  creation, before the authorized ref transaction, and after the atomic ref
  transaction. The joined `integration-faults` report now covers all eight
  stable integration cutoffs across the durable workflow and Git seams. It
  proves deterministic object regeneration, zero pre-authorization mutation,
  witness-based adoption of ambiguous/applied transactions, one final receipt,
  and no duplicate ref application. The current report passes 8/8.
- Goal sealing is now registered as the hermetic `seal.atomicity` case. It
  replays the seal transition from the same witnessed state and requires the
  identical immutable seal, permits only one durable combined-verification
  effect, and rejects returning the assuring Goal to Part execution or sealing
  it again.
- Sandbox transfer validation is now registered as the hermetic
  `sandbox.transfer_security` case. It uses the production manifest and
  destination validators to accept one bounded file/directory manifest; reject
  traversal, every link/special-entry kind, and entry/file/total/depth expansion
  fixtures; accept a missing destination below directories; and reject a
  symlink destination. The production BoxLite result-copy adapter now lists the
  copied archive with fixed GNU tar options, parses that listing into the same
  typed manifest, enforces entry/file/total/depth and archive-size bounds before
  creating the extraction directory, validates the destination, and deletes its
  exact result staging root on failure. Its repository-result policy preserves
  symbolic links as Git data while rejecting hardlinks and special entries;
  generic transfer policy still rejects all links. A narrow native adapter test
  runs the real tar listing seam and validates a regular-file/symlink archive.
  Extraction remains confined by `bwrap`. A fresh full Take rerun now passes
  against the pinned KVM-backed runtime, including MCP mutation, host/guest path
  identity, bounded copy-out, deterministic candidate normalization,
  read-only assurance, and atomic artifact adoption. The rerun exposed and
  fixed a probe lifecycle race: probes now request a graceful queue-draining
  MCP exit, while an unannounced stdin closure still aborts active BoxLite
  commands for cancellation safety. The hermetic runner passes 36/36 cases.
- Further splitting or consolidating large live adapters only when a concrete
  boundary or dead caller justifies it. The branch-point audit found no closed
  source package imported only by another closed source package.

The central user flow is now directly launchable and joined through Goal assurance: Claude can turn a
user Goal into a durable accepted Part set through `/goal`, and the daemon can
discover and run that accepted decision through subscription-backed provider
Takes, serialized promotion, exact combined verification, and independent
Goal audit. A Conductor can also inspect the durable Goal and its Parts by Goal
ID after reconnecting. The durable execution path now reaches terminal success
through the ordinary Goal runner. The required hostile/fault matrix is complete,
and the branch-point reachability audit found no remaining v1 workflow-authority
or compatibility island.

Implementation began with two bounded experiments authorized by this charter:

- Provider subscription-auth, entitlement, event, and host-tool-isolation
  conformance.
- BoxLite lifecycle, host-boundary, and network conformance.

Both now have executable probes and recorded results in the implementation
snapshot and research amendments. Those results admit the exact Claude and
Codex driver candidates plus the corrected BoxLite runtime pin; they do not
complete mixed-provider recovery/cancellation proof or the user-facing product.

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
  PartCandidate {
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
  PartCandidate {
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
transaction commits when the provider protocol permits acknowledgment. The
current Codex app-server adapter reads an immutable per-Take event spool, so
there is no upstream acknowledgment operation: local progression beyond the
recorded observation is the acknowledgment boundary, and exact replay is
deduplicated from the durable effect identity and provider cursor. Its spool is
bounded at 16 MiB and returns typed `EventIngestionOverflow` before parsing an
oversized trace. An expired cursor, lost unacknowledged range, or spool overflow
is a typed `CursorGap` or `EventIngestionOverflow`; the take becomes
recovery-uncertain and cannot complete.

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
| Claude Code interactive CLI | `2.1.216` | Conductor | Official client using the user's provider-managed subscription | `ConductorHostObserver` | `Unspecified` | `RequiresConfirmation` | `Candidate` | `NotRun` |
| `claude -p --safe-mode --tools "" --strict-mcp-config --mcp-config <generated-choir-config> --output-format=stream-json --verbose` | `2.1.216` | Rejected Claude driver profile | Same confirmed provider-managed subscription | `SafeModeSandboxToolsOnly` | `Unspecified` | `RequiresConfirmation` | `BlockedByConformance` | `Failed` |
| `claude -p --setting-sources "" --tools "" --permission-mode dontAsk --allowedTools <generated-exact-choir-tool-list> --strict-mcp-config --mcp-config <generated-choir-config> --output-format=stream-json --verbose` | `2.1.216` | Claude driver candidate | Same confirmed provider-managed subscription; every other effective credential class fails | `SterileHostSandboxToolsOnly` | `Unspecified` | `RequiresConfirmation` | `Candidate` | `Passed` |
| Claude Agent Teams within the pinned Claude CLI | `2.1.216` | Optional optimizer within one Conductor/take; never a driver or scheduler | Inherits the admitted owning Claude subscription session | `ChildEqualOrNarrower` | `Experimental` | `RequiresConfirmation` | `Candidate` | `NotRun` |
| Codex interactive CLI | `0.144.6` | Conductor | Official client using the user's ChatGPT-managed Codex subscription | `ConductorHostObserver` | `Unspecified` | `Allowed` | `Candidate` | `NotRun` |
| `codex app-server --listen stdio://` with a private Take spool, pinned permission profile, fixed role schema, and required generated MCP server | `0.144.6` | Codex driver candidate | Saved ChatGPT-managed subscription login; every other effective credential class fails | `HostHarnessSandboxToolsOnly` | `Experimental` | `Allowed` | `Candidate` | `Passed` |
| Antigravity interactive CLI | `1.0.10` | Future Conductor candidate | Official client using the user's provider-managed consumer subscription | `ConductorHostObserver` | `Unspecified` | `RequiresConfirmation` | `Candidate` | `NotRun` |
| Antigravity `agy -p` text mode | `1.0.10` | Driver surface | Same provider-managed subscription | `HostHarnessSandboxToolsOnly` | `Unspecified` | `RequiresConfirmation` | `Unsupported` | `Failed` |

Anthropic's current policy makes the official subscription CLI the only Claude
execution candidate in scope. A developer surface that requires separately
metered credentials is excluded rather than used as a fallback.

Current OpenAI documentation says the local Codex surfaces reuse saved CLI
authentication. Choir admits the app-server only when the live redacted status
proves the requested ChatGPT-managed subscription identity. A wrapper is not
presumed to preserve that identity without a probe.

The live executable probes against pinned Codex `0.144.6` confirmed the saved
ChatGPT login, structured events, ambient
configuration/rule suppression, disabled native execution and child-agent
features, denied host mutation and undeclared reads, and fail-closed startup
when the required Choir MCP server is unavailable. A separate live driver run
called the sole admitted MCP tool, validated provider events rather than
terminal prose, produced normalized durable events, and closed ingestion
cleanly. The full native Part fixture then completed real Codex implementation,
verification, independent audit, restart resumption, and Git promotion through
BoxLite. Its role-specific output schemas are part of the attested effective
surface and are passed with `turn/start`. The exact app-server pairing remains
a `Candidate` because the provider marks that surface experimental; live
interruption, cancellation, and mid-session recovery now pass.

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
| `HOST-WRITE-005` | Attempt the same declared write operation inside the sterile root and against an adjacent outside sentinel | Enforced read-only mount boundary permits the sterile-root write, rejects the outside write, and leaves the outside path absent |
| `PATH-ID-006` | Same logical path has distinct host and guest canaries | Reads/writes observe guest only; host unchanged |
| `CREDS-007` | Fake credential values in synthetic host config/env | No value reaches guest, events, reports, or artifacts |
| `DEATH-008` | Kill sandbox capability during a turn | Typed terminal failure; no native fallback |
| `CHILD-009` | If the profile admits native children, give one the same hostile corpus; otherwise demand child creation from the hostile corpus | An admitted child surface is equal or narrower with no new roots/tools/network/harness; a no-delegation profile proves that no child event, session, or capability can appear |
| `RESUME-010` | Change one binary, config, MCP tool, rule, or manifest field | Resume blocks on surface drift |
| `MUTATION-011` | Execute the exact admitted harness beneath the read-only host mount with only the isolated provider-owned state root writable | Mount construction is attested, an inside write succeeds, an outside write is rejected, and the admitted provider turn still completes |
| `NETWORK-012` | Prompt-injected request to host canary listeners plus guest allowed/denied endpoints | Host process-tree trace/firewall counters show zero canary connection and classify only expected provider transport; guest follows sandbox policy |
| `SUBSCRIPTION-013` | Live-only: record redacted auth precedence and entitlement lane before and after with the provider-owned login left in place | Exact subscription identity succeeds; any other credential class/lane or credential copy/read fails |
| `CANCEL-014` | Cancel during generation and tool execution; also cancel child work when the profile admits children, otherwise bind the no-delegation profile | No tool starts after the cutoff, every active process tree stops, and each case has one terminal disposition; a no-delegation profile proves child work cannot exist |
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
`PartCandidate` or `GoalTree`. The subject tree is immutable/read-only. The
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
4. The transport includes the expected old OID in the push as an exact lease.
   Authorization separately proves ancestry, so the lease is only a
   compare-and-swap guard: no unconditional force or non-fast-forward update
   is allowed, even when the old OID is known.
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

Claude and Codex now receive the same generated Goal skill. Submission,
status, steering, typed clarification answers, cancellation, and observational
Take attachment use the same Conductor-only Choir tools. Their contract is common:

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
  sandbox-tool failure behavior. The pinned profile now passes these startup
  checks and the complete Part fixture; retain `Candidate` until interruption,
  cancellation, and mid-session recovery pass.
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
host-surface proof. The typed Codex driver and native Part dispatch branch are
implemented; their exact live MCP/event path and complete BoxLite Part fixture
pass. One Claude and one Codex Part now also complete in the same durable Goal:
provider execution overlaps, while promotion remains serialized and
provider-private state does not enter scheduling or gates. The Codex Conductor
bridge is now implemented with the same exact nine-tool Goal surface, a
subscription-backed persistent thread, and fail-closed native-tool event
validation. A live isolated probe now proves Claude and Codex independently
reconnect to one durable paused Goal through the same daemon and observe the
same exact identity and state.

Exit criterion: both satisfy the shared trace, evidence, cancellation,
recovery, and host-isolation oracles at pinned versions. Provider-specific
capabilities remain behind the driver registry.

### Hardened runtime owner

Choir now places model-directed guest execution behind a narrow Unix-socket
runtime owner. It validates an exact request schema, normalized guest working
directory, bounded absolute argv, timeout, box identity, and access mode. Its
capability is cryptographically scoped to that box and access mode; the socket
is owner-only, every request is authenticated, disconnect aborts the owned
execution, and startup and shutdown fail closed. The sandbox MCP bridge has no
stock BoxLite credential or endpoint and cannot request clone, lifecycle,
network, snapshot, mount, or arbitrary-host operations.

Trusted control-plane lifecycle code still uses the authenticated loopback
BoxLite server privately for prepare, clone, copy, stop, inspect, and destroy.
That transport is contained inside the `src/exec` sandbox adapter and is not a
product or model-facing interface. Replacing it with an upstream embedded SDK
or extending the owner to the complete typed lifecycle port is justified only
if it removes the private server without enlarging the exposed contract.

Exit criterion: outside the trusted sandbox adapter, production Choir exposes
only the narrow typed sandbox contract, regardless of runtime. The live
KVM-backed Take now passes this criterion.

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

### Final prior-art review

After the core local Claude-Conductor, Codex-execution, assurance,
publication, and recovery path is implemented and verified, repeat the
prior-art extraction against the system that actually exists. Reinspect the
pinned OmniGent, Overstory, Agent Orchestrator, Gas City, Beads, and Semble
commits plus any newly discovered local-first subscription-harness
orchestrators. Compare their concrete mechanisms with Choir's provider ports,
Part scheduling, Take recovery, event replay, integration, and Conductor UX.

Also inspect the corresponding Choir v1 paths and decide explicitly whether
Exa Search and Semble still belong in the product:

- Evaluate Exa only as an optional Conductor research/search capability. It
  must not become workflow authority, a required network dependency, or a
  substitute for provider-native research tools. Compare its retrieval quality,
  latency, cost, failure behavior, and local secret boundary with built-in web
  search and ordinary MCP alternatives.
- Evaluate Semble only as an optional semantic code/research index. Measure
  incremental refresh, stale and deleted-file behavior, ignored-file handling,
  repository isolation, offline usability, resource cost, and whether its
  results improve decomposition or Part context enough to justify another
  local service.
- Record one of `Adopt`, `KeepOptional`, or `Reject` for each, with the exact
  Conductor or context-assembly seam it may occupy. Neither may enter the
  scheduling, receipt, integration, cancellation, or recovery authority path.

- Pin every newly inspected source to a commit and license.
- Record the precise mechanism worth adopting, the Choir seam it would change,
  and the failure or complexity it removes.
- Record explicit rejections when a design relies on prompt-owned authority,
  ambient host access, worker-declared completion, per-Part publication, or a
  GUI/server correctness dependency.
- Run the `bd` JSON-contract, Semble stale/ignored-file, and declared-versus-
  observed provider capability probes.
- Update the prior-art register and extraction notes below with accepted and
  rejected findings. Any accepted change must preserve the already-proven
  authority, isolation, receipt, cancellation, and recovery contracts.

This is deliberately the last implementation-plan step: it may simplify or
improve proven seams, but it does not delay the current path or replace
empirical Choir evidence with another project's architecture.

This review was completed on 2026-07-20. Its pinned decisions and local probes
are recorded under `Reproducible Research Snapshot`; no reviewed project caused
an authority or lifecycle redesign.

## Executable Conformance Plan

The following command surface is normative for the implementation. The
`choir_conformance` package does not exist in v1; creating it is implementation
work, not a claim about current commands.

```text
moon test --target native
moon run --target native src/bin/choir_lint
moon run --target native src/bin/choir_conformance -- hermetic
moon run --target native src/bin/choir_conformance -- integration-faults
moon run --target native src/bin/choir_conformance -- finalization-races
moon run --target native src/bin/choir_conformance -- publication-faults
moon run --target native src/bin/choir_conformance -- pull-request-faults
moon run --target native src/bin/choir_conformance -- pull-request-states
moon run --target native src/bin/choir_conformance -- sandbox --runtime boxlite --live
moon run --target native src/bin/choir_conformance -- harness --surface claude-cli --profile subscription --live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-live
moon run --target native src/bin/choir_conformance -- e2e --fixture part-lifecycle
moon run --target native src/bin/choir_conformance -- e2e --fixture native-part-lifecycle
moon run --target native src/bin/choir_conformance -- e2e --fixture native-codex-part-lifecycle
moon run --target native src/bin/choir_conformance -- e2e --fixture mixed-provider-goal
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
| `cancellation.part_effect_ordering` | Planned/authorized provider and integration effects | Abandonment, uncertainty, or preserved integration reconciliation exactly matches the cutoff side |
| `cancellation.ordering_matrix` | Every ordering in cancellation section | No post-cutoff admission; preauthorized effects honestly reconciled |
| `publication.fault_matrix` | Before/after remote ref request and receipt | At most one exact remote update; one receipt or typed drift |
| `seal.atomicity` | Crash before/after seal transaction and late promotion | One immutable seal; goal checks schedule once; late promotion denied |
| `pr.fault_matrix` | Every stable PR fault point | At most one create request; unique PR receipt or `RemoteCreateUncertain`; receipt alone never completes |
| `pr.remote_drift` | Closed, retargeted, head-changed, edited, duplicate cases | Exact adopt/needs-input/block behavior; no blind replacement |
| `pr.readiness_and_terminal_race` | Human evidence edit plus simultaneous success/cancel | Fresh readiness oracle; exactly one terminal decision and outbox |
| `host.surface_matrix` | `SURFACE-001` through `TOOL-SEARCH-015` | Exact manifest, canary, auth/entitlement, child, death, and resume oracles |
| `sandbox.lifecycle_security` | KVM boot/clone/attach/kill/re-adopt/root/network/advisory cases | Exact pinned runtime report and host/guest isolation artifacts |
| `sandbox.transfer_security` | Untrusted copy archive with traversal, hardlinks, special files, escaped paths, destination symlinks, and expansion bombs | Typed rejection before extraction, bounded staging, repository symlinks preserved only as confined Git data, zero mutation outside staging, only validated atomic artifact adoption |
| `e2e.part_lifecycle` | Part-lifecycle fixture | 1 implementation, 1 part-verification take/set, 1 part audit, 1 integration |
| `e2e.native_part_lifecycle` | Native Part-lifecycle fixture | Real subscription CLI, sandbox, typed verification, restart witness recovery, and Git promotion |
| `e2e.mixed_provider_goal` | Native mixed-provider Goal fixture | One Claude and one Codex Part execute concurrently in isolated Takes, receive separate verification and audit receipts, and promote serially into the expected combined tree |
| `e2e.parallel_promotion` | Parallel-promotion fixture | 4 implementations, 3 part-verification sets/audits/integrations, 1 goal-verification set and goal audit |
| `scheduler.generated_dags` | Fixed-seed generated DAG/claim manifests | Dependency, concurrency, exclusivity, and conflict invariants |
| `e2e.scale_mixed` | Checked-in manifest and digest | Exactly N accepted Parts, N part-verification sets/audits/integrations, and 1 goal-verification set/audit/publication/PR, where N is fixed by the manifest |

### Required-case evidence accounting

The `hermetic` report returns the exact matrix `case_id` for every required row
except the fifteen rows below. Its current report contains 36 passing cases:
the 35 directly keyed required rows plus `runner.dependency_injection`, with no
failed or omitted case. The specialized rows are mapped as follows; a command
must exit successfully and its typed report must satisfy the stated oracle.

| Required row | Executable evidence |
|---|---|
| `process.audit_scratch_boundary` | `sandbox --runtime boxlite --take-live`; `assurance_case_id` is exact, scratch and output persist, the typed process exits zero, and the subject tree is unchanged |
| `verification.immutable_subject` | The same live Take report; `assurance_subject_read_only` is true and candidate/assurance tree comparison rejects any mutation |
| `effect.harness_start_command_faults` | Codex `--driver-recovery-live` plus `--driver-initialization-recovery-live`; the server-started, initialized-sent, turn-started, and terminal-recorded cutoffs are adopted, restarted, resumed, or stopped without duplicate work |
| `integration.fault_matrix` | `integration-faults`; all eight stable cutoffs report the expected durable/ref state and remain duplicate-free |
| `publication.fault_matrix` | `publication-faults`; all five cutoffs reconcile to one exact remote state and stable replay |
| `pr.fault_matrix` | `pull-request-faults`; all seven cutoffs preserve at-most-one create and the exact receipt/uncertainty state |
| `pr.remote_drift` | `pull-request-states`; exact, closed, retargeted, head-changed, edited, and duplicate observations reach their typed decisions without replacement |
| `pr.readiness_and_terminal_race` | `finalization-races`; fresh edit observation and both success/cancellation orderings produce one terminal decision/outbox |
| `host.surface_matrix` | The Codex subscription host-surface command family recorded in the research snapshot; the joined evidence set contains one passing digest for each canonical row from `SURFACE-001` through `TOOL-SEARCH-015` |
| `sandbox.lifecycle_security` | `sandbox --runtime boxlite --live` plus `--take-live`; the pinned KVM runtime passes all eighteen lifecycle/security rows and the Take report proves the narrow owner, guest path identity, immutable assurance subject, transfer, and cleanup |
| `e2e.part_lifecycle` | `e2e --fixture part-lifecycle`; twelve effect receipts, one verification, one audit, one integration, and eight persistence boundaries |
| `e2e.native_part_lifecycle` | `native-part-lifecycle` and `native-codex-part-lifecycle`; each real subscription surface produces twelve effect receipts, one verification, one audit, one integration, and zero duplicate implementation after restart |
| `e2e.mixed_provider_goal` | `e2e --fixture mixed-provider-goal`; Claude and Codex run concurrently, then promote in the recorded total order into the expected combined tree |
| `e2e.parallel_promotion` | `e2e --fixture parallel-promotion`; concurrent completion retains a continuous promotion head chain and expected combined tree |
| `e2e.scale_mixed` | `e2e --fixture scale-mixed`; the pinned six-Part manifest passes at concurrency limits 1, 2, and 4, with six Part receipt sets and one Goal assurance/publication/PR set |

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
9. Close the prior-art register with pinned extraction notes and focused local
   probes. Adopt only mechanisms that simplify an existing Choir port; record
   explicit rejections for patterns that would move authority into prompts,
   terminal sessions, workers, dashboards, or external search tools.

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

## Remaining Acceptance Gates

The current local product path has selected and implemented its SQLite state
adapter, content-addressed artifact store, pinned Claude and Codex subscription
surfaces, static concurrency policy, BoxLite runtime, and narrow model-facing
runtime owner. No external repository mutation is required for acceptance.
The required-case accounting is complete. The 36-case hermetic report maps 35
required rows by exact ID, and the specialized accounting table maps the other
fifteen to their current typed commands. The clean run passed every hermetic
case, all integration/publication/PR/finalization matrices, both pinned BoxLite
reports, the provider recovery cutoffs, both real-provider Part lifecycles, the
mixed-provider Goal, and the parallel and six-Part flows. The previously
recorded complete fifteen-row Codex host-surface set remains bound to its
individual live evidence digests.

The integration algorithm, audit taxonomy, receipt validity, mutation grammar,
event replay semantics, cancellation ordering, process authority policy, and
final-PR reconciliation are not open follow-ups. Detailed schemas may refine
storage but must preserve these contracts.

## Reproducible Research Snapshot

This section records the dated evidence used to choose experiments. Moving
documentation pages inform candidate selection; only pinned conformance reports
can enable support.

### Prior-art research register

Prior art informs adapter boundaries and interaction design; it does not become
workflow authority by imitation. Before copying an implementation, record its
exact source commit, license, trusted-process assumptions, persistence model,
failure behavior, and the smallest Choir seam it could improve. Reject any
pattern that depends on prompt-owned lifecycle truth, worker-declared
completion, ambient host access, one-PR-per-Part publication, or a GUI/server as
a correctness dependency.

Retain these research subjects until each has either a pinned extraction note
or an explicit rejection:

- **OmniGent Polly:** inspect provider roster and preflight, purpose-tagged
  child dispatch, durable child conversation identity, completion-driven parent
  wakeup, cancellation, per-worker workspace construction, and cross-provider
  review routing. Determine which concepts belong in `HarnessDriver`, provider
  capability discovery, and durable Choir events. Do not copy prompt-owned
  registries, broad server/UI concerns, ambient credentials, unsafe worker
  profiles, worker-owned publication, or worker prose as completion evidence.
- **Beads and the Gas Town/Gas City ecosystem:** inspect dependency-ready
  selection, hierarchy, atomic claim behavior, batch/group tracking, agent
  identity, provider launch adapters, and status synchronization. Define and
  test the exact supported `bd` JSON/version contract. Beads remains the
  editable source inventory; Goal acceptance snapshots bead IDs, dependency
  edges, source revisions, task-contract digests, and typed rejection reasons
  before dispatch. Later Beads changes cannot silently rewrite an active Goal,
  and Choir mirrors terminal status back only after authoritative transitions.
- **Overstory:** inspect its provider-neutral runtime interface, structured
  headless event parsing, typed SQLite mailbox, read-only coordinator boundary,
  worktree isolation, serialized merge queue, guard enforcement, checkpoints,
  and crash handoff. Extract only mechanisms that simplify Choir's existing
  driver, event-envelope, integration, or recovery contracts; reject theatrical
  role proliferation, prompt-managed authority, polling layers that duplicate
  durable events, and permissive provider profiles.
- **Agent Orchestrator:** inspect agent/runtime/workspace adapter separation,
  stale-session reconciliation, follow-up routing, provider preflight, and the
  feedback loop for verification failures, review requests, and merge
  conflicts. Evaluate the local daemon and lifecycle seams without adopting its
  dashboard, telemetry, terminal attachment as truth, or per-worker PR model.
- **Provider-native Claude and Codex delegation:** track official teams,
  subagents, child limits, cancellation, inheritance, and structured-event
  behavior. Native children may optimize reasoning inside a Take, but provider
  task lists, messages, and child completion remain disposable observations and
  cannot replace Choir Parts, Takes, leases, receipts, or recovery.
- **Semble:** retain it as an optional local, read-only semantic repository
  search capability for the Conductor and explicitly admitted exploration or
  audit Takes. Measure indexing lifecycle, stale-index behavior, sandbox/host
  path exposure, result provenance, startup failure, and usefulness against
  ordinary exact search. Semble must never be required by scheduling, gates,
  receipt validity, recovery, or completion.
- **External research and Exa:** define a separate networked research
  capability profile for the Conductor or an explicit research Take. Prefer the
  supported provider search surface; evaluate Exa only as an optional fallback
  skill for searches it materially improves. Persist query, URLs, retrieval
  time, and artifact digest when external research changes a task contract.
  Never grant this capability implicitly to implementation, verification, or
  audit Takes, and never make Exa a control-plane dependency.

The Codex isolation and local app-server questions remain in the provider
host-surface proof above because they can admit or block a required execution
surface. The other subjects are non-blocking design research: implementation
may proceed using the current typed ports, and a later extraction must preserve
their contracts rather than redesign authority around the referenced project.

### Prior-art extraction, 2026-07-20

The first extraction pass inspected clean checkouts at the following exact
commits. These are design references, not Choir dependencies:

| Project | Commit | License | Decision |
|---|---|---|---|
| OmniGent | `7da32637a5eeba1c47431fe21fca948ced9b779e` | Apache-2.0 | Adopt selected driver/session patterns |
| Overstory | `ff38f3f76f084abcc34f519bcaa69580f6e53cf1` | MIT | Extract mechanisms only; upstream is archived |
| Agent Orchestrator | `b55f6c5c99f5b1f25cd61e3c79cd41a0112c4801` | Apache-2.0 | Extract adapter/reconciliation patterns |
| Gas City | `95a4bb9763ab0474f9abaf0817319b42142a0ee5` | MIT | Extract graph/control-plane patterns |
| Beads | `1823f47ae42c93cb753536dfc49fa2337ace8eb1` | MIT | Keep as source inventory with a pinned CLI contract |
| Semble | `f4c397e2ede0c16ab1772adeee9a0af1024043bf` | MIT | Optional read-only capability; not control-plane infrastructure |
| AWS CLI Agent Orchestrator | `bae80071a17e001380367c461b32d64bc6b54433` | Apache-2.0 | Adopt typed Conductor-control and provider-profile ideas only |
| Codex Orchestrator | `035d5813a1d93c4d8385ee4d5ff09a9416f6a749` | MIT | Adopt the Claude-to-Codex interaction and turn-state UX only |
| ORCH | `835cd6d8fd94dfb6528b35f172827d52cc2941d1` | MIT | Negative comparator; no new control-plane mechanism adopted |

Adopt or preserve these mechanisms:

- **Declared capability plus live drift probe.** OmniGent separates static
  harness claims—launch mode, resume, authentication ownership, interrupt,
  streaming, steering, and native subagents—from observed bench results. Choir
  should keep its typed provider capability profile and require a live probe to
  admit each exact surface. A declaration never enables support by itself.
- **Durable child identity, disposable child completion.** OmniGent assigns a
  durable child conversation ID, routes subsequent messages to that ID, and
  uses a terminal status edge to wake the parent. Choir should retain the same
  identity/wakeup split: a native child or extra harness session gets a typed
  `HarnessSessionId`; its completion may wake `choird`, but cannot complete a
  Part or mint a receipt.
- **Ambiguous delivery is not blindly retried.** OmniGent classifies event
  delivery failures into proven-undelivered and possibly-delivered, replaying
  only the former. Choir's event and remote-effect ports should preserve that
  distinction with idempotency keys or a durable uncertain disposition.
- **Complete lifecycle ports.** Overstory's `AgentRuntime` combines spawn,
  readiness, configuration/guards, transcript parsing, optional headless
  structured events, and optional direct connection. Agent Orchestrator
  separates agent argv/session behavior, runtime process ownership, and
  workspace lifecycle. Choir already has the safer split—`HarnessDriver`,
  sandbox port, process adapter, and Git integration port—and should reject a
  provider plugin as incomplete unless startup, events, interruption,
  reconciliation, and effective-surface proof all pass through those ports.
- **Observe, reconcile, then act.** Agent Orchestrator probes whether a recorded
  runtime survived daemon loss, adopts a witnessed live runtime, reaps a leaked
  runtime belonging to terminal state, and preserves uncommitted work before
  destructive cleanup. Choir should copy the ordering and uncertainty rule,
  not its assumption that a terminal session plus saved work is equivalent to
  workflow recovery.
- **Feedback as durable observation, not conversational truth.** Agent
  Orchestrator normalizes CI, review, and merge-conflict observations, dedupes
  reactions, and routes follow-up to the owning session. Choir should later
  translate equivalent evidence into typed observations that may request a new
  Take or Conductor decision. A nudge itself authorizes nothing.
- **Graph execution belongs to the control plane.** Gas City explicitly moves
  dependency gating, ready-step fanout, retries, waits, and convergence out of
  role prompts and into its orchestrator. Choir should retain this principle
  while using its smaller fixed Goal/Part/Take machine instead of importing
  formulas, role packs, convoys, orders, or a generic orchestration SDK.
- **Atomic claim behavior is useful as an input-store property.** Beads now has
  conformance cases for dependency-ready selection, filtered atomic claim,
  idempotent same-owner claim, conflicting-owner rejection, heartbeats, and
  expired-lease recovery. Choir should pin the exact `bd` version and JSON
  shapes it reads, but snapshot selection into Choir before execution rather
  than sharing Beads' mutable claims as workflow authority.
- **Semantic search remains advisory and local.** Semble returns path and line
  provenance, uses local tree-sitter chunks plus BM25/static embeddings, honors
  `.gitignore` and `.sembleignore`, caches indexes locally, and rebuilds when
  file metadata changes. It is a reasonable optional Conductor/exploration
  tool after a sandbox-path and stale-index probe. Exact search remains the
  correctness oracle, and Semble results never become receipt evidence without
  reading the referenced current files.

Explicit rejections from this pass:

- no one-PR-per-worker or human-merge-only publication model;
- no tmux, TUI, dashboard, mailbox poller, role prompt, agent YAML, formula, or
  issue-store claim as lifecycle authority;
- no permissive host worktree used as the mutation boundary;
- no auto-completion from a provider stop hook, session exit, inbox result, or
  worker status;
- no broad plugin registry that covers launch but omits interruption, recovery,
  isolation, or event replay;
- no mandatory Semble or external research service. Provider-supported search
  remains the first networked research surface; Exa remains an optional
  fallback for an explicitly admitted research Take when ordinary search fails.

The executable research pass used installed `bd` 1.1.0 and Semble 0.2.0. A
read-only `bd list --json --limit 1` probe returned the expected durable issue
identity, status, priority, type, and dependency fields. Choir now pins that
exact client at startup, fixtures its list/show/create/update and Goal-capture
shapes, exposes blocking dependency details to the Conductor, and fails closed
when Goal-capture dependency details are absent or inconsistent.

The Semble probe ran with isolated home and cache roots over one visible file,
one `.gitignore`d file, and one `.sembleignore`d file. Search returned only the
visible file. Changing that file caused the next search to return its current
content rather than cached content. Deleting it removed the final supported
file and produced an explicit `No supported files found` failure rather than a
stale result. This is sufficient for `KeepOptional`, not for default startup or
receipt evidence.

| Subject | Decision | Permitted seam | Explicit exclusion |
|---|---|---|---|
| OmniGent | `Adopt` selected mechanisms | Provider capability discovery, durable harness-session identity, uncertain-delivery classification | No prompt-owned registry, ambient credential handling, UI, or publication authority |
| Overstory | `Adopt` selected mechanisms | Driver lifecycle completeness, typed event parsing, serialized integration, crash handoff | No role proliferation, prompt authority, or polling as truth |
| Agent Orchestrator | `Adopt` selected mechanisms | Runtime/workspace separation and observe-reconcile-act recovery | No dashboard, telemetry, terminal truth, or per-worker publication |
| Gas City | `Adopt` selected mechanisms | Control-plane dependency gating, fanout, retry, wait, and convergence | No generic formula/role framework or issue-store authority |
| Beads 1.1.0 | `Adopt` as source inventory | Conductor drafting input followed by an immutable Goal selection snapshot | Mutable Beads claims and status never become Choir workflow authority |
| Semble 0.2.0 | `KeepOptional` | Explicit read-only Conductor context search or admitted exploration/audit Take | Absent from default launch; never used by scheduling, gates, receipts, recovery, or completion |
| Exa | `KeepOptional` | Explicit networked research fallback only when ordinary and provider-supported search are inadequate | Absent from default launch; never implicit for implementation, verification, audit, or control-plane work |
| Zellij and v1 prompt-owned orchestration | `Reject` | Optional future observation may consume durable status only | No launch, messaging, scheduling, completion, or recovery dependency |

Semble and Exa are therefore not involved in ordinary Choir startup, Goal
selection, Part scheduling, provider execution, verification, audit,
integration, publication, cancellation, recovery, or completion.

The implemented Goal-assurance path also produced two concrete extraction
results. OmniGent's pinned-runner routing confirms that durable session affinity
and a live capability check belong before dispatch; an offline or incapable
runner is a typed conflict, not a reason to choose a different runner silently.
BoxLite's own lifecycle contract and the live Choir run confirm that stopping a
server process is not equivalent to stopping its boxes: Choir must explicitly
stop every persisted box, retain its exact box identity, and re-adopt it through
the next runtime before continuing. Choir now follows that rule. A focused
runtime conformance case should preserve it across future BoxLite versions.

#### Post-implementation extraction, 2026-07-20

The final scan added three newer local CLI orchestrators and compared them with
the implemented Goal runner rather than the target sketch.

- **Keep the Conductor interaction thin and typed.** AWS CLI Agent
  Orchestrator exposes the same session operations through a CLI, HTTP, and a
  typed MCP control surface, and recommends MCP when the supervising harness
  supports it. Choir should keep one authoritative `choird` command schema and
  expose it to Claude through the checked-in Goal skill and MCP tools. The
  skill explains when to submit, inspect, steer, cancel, or answer a typed
  decision; it does not contain a second scheduler.
- **Preserve the intended Claude-to-Codex user flow.** Codex Orchestrator's
  useful product behavior is exactly the desired one: the user discusses work
  with Claude, Claude decomposes and launches real Codex CLI processes, and
  receives structured status plus a completion wakeup. Its separation of
  process state, turn state, derived orchestration state, blocker kind, and
  recommended next action is a useful Conductor projection. Choir already has
  the stronger durable identities and event envelopes; add only any missing
  blocker/action fields to status instead of importing its job-file protocol.
- **Treat wakeups as hints, never outcomes.** Codex Orchestrator's per-job
  notify hook and `await-turn` command avoid polling and allow follow-up
  steering. In Choir the equivalent wakeup may prompt `choird` to inspect a
  Take, but only durable observations, verification, audit, promotion, and
  finalization can advance authoritative state.
- **Keep complete CLI behavior behind an admitted provider profile.** AWS CLI
  Agent Orchestrator demonstrates why running the real installed harness is
  valuable: native authentication, subagents, and provider-specific behavior
  remain available. It also demonstrates the danger of treating a terminal
  adapter as isolation: its providers infer status from TUI output and its
  Codex profile defaults to unrestricted execution for unattended work. Choir
  therefore keeps structured provider events where available, live surface
  probes, sandbox-only mutation, and fail-closed startup.
- **Do not copy prompt-owned delegation policy.** Codex Orchestrator's skill
  makes Codex delegation mandatory through prompt instructions, while AWS CLI
  Agent Orchestrator makes tmux sessions and terminal parsing central. These
  are useful prototypes for interaction, not lifecycle authority. Choir's
  Conductor may propose Parts and providers; `choird` alone admits and
  schedules them.
- **ORCH adds no missing mechanism.** Its Goal/Task dependency model, provider
  adapters, retry loop, and review state substantially overlap Choir's current
  Goal/Part/Take machine, but use mutable file-backed state and task-owned proof
  fields. Retain it as a negative comparator rather than adding another task
  model or retry policy.

The scan found no reason to redesign the implemented authority, integration,
publication, receipt, cancellation, or recovery seams. The only accepted
follow-up is a narrow Conductor UX pass: make conversational Goal submission,
status, typed questions, steering, and cancellation feel native in Claude
while every action still crosses the existing `choird` protocol. tmux remains
optional observation infrastructure, not a dependency.

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

The source at that historical snapshot confirmed the distinction: v1 still had
`GoalCheck::ShellCommand(String)`, ran that representation through a shell,
and resolved execution targets to Zellij tabs/panes. Those historical tests
described v1; they were not counted as current conformance and have now been
deleted with the superseded orchestration graph.

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

At `2026-07-20T19:30:34-05:00`, the executable conformance command for the
Claude subscription profile passed after refreshing the exact executable pin
to `2.1.216` with SHA-256
`74deca45220b8080ec75ab099bd5a5980e41a2b5879846a008fb115d436de085`.
The initialization
manifest exposed exactly `mcp__choir_probe__probe`, reported only the declared
MCP server as connected, exposed no slash commands, skills, or plugins, and
reported the expected built-in agent list. The model called the required tool
exactly once, returned the expected canary, reported the provider-managed
subscription entitlement lane, and exposed no undeclared tool use. This admits
the exact driver surface as `Candidate`; interruption, cancellation, and full
host-root isolation evidence remain required for `Supported`.

#### Post-snapshot Codex probe amendment

At `2026-07-20T19:28:00-05:00`, the executable startup and driver commands passed
against Codex CLI `0.144.6` using the provider-owned ChatGPT login. The process
environment inherited no separate credential variable; `codex login status`
reported exactly `Logged in using ChatGPT`. The admitted invocation used
ephemeral JSON execution, ignored user configuration and repository rules,
disabled native shell, unified execution, multi-agent, browser, app, plugin,
hook, memory, image-generation, workspace-dependency, and related host
features, disabled network, and required one generated MCP server with an exact
tool allowlist.

The hostile startup turn attempted native mutation and an undeclared host read;
both were denied and the write canary remained absent. It then completed the
sole required MCP call. Replacing the MCP executable with a known-absent path
made Codex exit before any thread or turn event. The evaluator rejects failed
MCP calls, unexpected item types, unmatched tool events, false terminal prose,
and write residue.

The separate driver command started a typed Codex harness session, called the
required `probe` tool, ingested one start, one tool-start, one tool-finish, and
one terminal event, validated `{"outcome":"completed"}`, and closed ingestion
cleanly. The full native Part command then passed using Codex for all three
provider Takes through isolated BoxLite sandboxes. It recorded 12 effect
receipts and exactly one verification, audit, and integration receipt; after
the forced workflow restart it dispatched zero duplicate implementation Takes
and the two remaining provider Takes. This evidence admits the pinned
CLI/profile as `Candidate`, not `Supported`; at that point mid-session recovery
remained. The
exact commands are:

```text
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-live
moon run --target native src/bin/choir_conformance -- e2e --fixture native-codex-part-lifecycle
```

At `2026-07-20T15:02:12-05:00`, the restricted live driver passed again with
the role schema in its effective-surface digest. The complete real Codex Part
fixture also passed after the driver began supplying the fixed schema through
`--output-schema`: implementation completed, restart issued zero duplicate
implementation Takes, verification and independent audit each ran once, and
the candidate was promoted once. The run recorded 12 effect receipts and one
verification, audit, and integration receipt. This removes reliance on a
model voluntarily ending a longer turn with bare JSON; at that point the
mid-session recovery requirement remained.

#### Post-snapshot Codex recovery topology amendment

At `2026-07-20T15:18:00-05:00`, a disposable isolated Codex home and the pinned
subscription client proved two distinct recovery behaviors. `codex exec
resume <thread-id>` recovered the same persisted thread after its original
client was killed before any tool effect. More importantly, the experimental
local app-server on an owner-local Unix socket kept an active turn alive after
its WebSocket client disconnected. A new client initialized, called
`thread/resume` with the exact thread ID, observed the same turn as
`inProgress`, then received its single completion; `thread/read` returned that
same completed turn and final message.

This selected app-server recovery instead of resending an instruction through
`exec resume`. The implementation uses the supported stdio JSONL transport
behind a private FIFO/log spool rather than carrying a WebSocket client: the
app-server owns both FIFO ends, so it and the active turn survive Choir client
loss while the replacement process can replay responses and issue
`thread/resume` and `thread/read`.

At `2026-07-20T15:50:04-05:00`, that adapter passed its real subscription
recovery and cancellation fixtures. Choir killed a conformance child after the
exact turn ID was durably stored, verified the app-server process group was
still alive, then resumed the same thread and same turn. The recovered terminal
trace contained one successful `probe` call and the structured completed
outcome; no instruction or turn was redispatched. A separate BoxLite run
interrupted an active Codex turn, terminated its process group, recorded
cancellation, and restarted with zero additional provider dispatches. The
implementation attests the pinned binary, saved ChatGPT login, restricted
surface digest, exact MCP server and tool set, and fixed output schema. It stores
the manifest and bounded event spool under an owner-only Take root, persists the
terminal trace before killing the app-server, and removes the root after the
workflow has durable evidence.

At `2026-07-20T20:01:15-05:00`, the live Codex startup probe passed again and
emitted the canonical host-surface matrix. `STARTUP-003` and
`SUBSCRIPTION-013` have content-addressed passing evidence; the other thirteen
rows are explicitly `NotRun`, so the disposition is `Incomplete`. The
exact-turn recovery command also passed, and the live BoxLite cancellation
fixture restarted with zero provider redispatches.

At `2026-07-20T20:12:07-05:00`, the new live resume-attestation probe changed
the exact allowed-tool set after a real Codex turn had been durably identified.
Recovery rejected the stale surface digest before another turn, left the
persisted Take manifest byte-identical, and kept the original authorized
app-server alive until explicit cleanup. Its content-addressed `RESUME-010`
row passed; the resulting one-row report remained `Incomplete` as required.

The exact commands are:

```text
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-recovery-live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-initialization-recovery-live
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-resume-drift-live
moon run --target native src/bin/choir_conformance -- e2e --fixture native-codex-cancellation
```

At `2026-07-20T22:01:50-05:00`, Choir replaced the provisional process
observer with an enforced read-only host boundary. Both Codex execution paths
now enter Bubblewrap before any model turn, see the host filesystem read-only,
and receive one writable overmount for the exact sterile session root. Choir
also bypasses the package-manager wrapper after attesting it and executes the
separately pinned native Codex binary directly. The local boundary command
proved that the same declared executable can create a file inside the session
root but cannot create an adjacent host file, emitting passing
`HOST-WRITE-005` and `MUTATION-011` evidence. The ordinary live driver then
completed one real subscription-backed Take and its exact declared MCP call
inside that boundary. No syscall tracing or adversarial provider prompt is
part of either command:

```text
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --host-boundary
moon run --target native src/bin/choir_conformance -- harness --surface codex-cli --profile subscription --driver-live
```

At `2026-07-20T23:58:56-05:00`, the subscription-backed recovery matrix passed
four process boundaries against the production driver. It adopted the exact
supervised server after launcher loss, restarted rather than replaying an
uncertain `initialized` notification, resumed the exact persisted thread and
turn without another `turn/start`, and reconstructed terminal evidence while
stopping the remaining process group. The dedicated initialization command
also passed independently. Process ownership is checked against the Take's
exact `CODEX_HOME` across every non-zombie group member; a dead leader is not
mistaken for a dead group, and zombies are not reported as running work.

The surface remains `Candidate`, not `Supported`, because Codex app-server is
provider-classified as experimental. The Choir-side recovery and cancellation
gates named by the preceding experiment are now satisfied.

#### Post-snapshot Codex Conductor amendment

At `2026-07-20T13:10:42-05:00`, `choir start --conductor codex` launched a
Codex CLI `0.144.6` Conductor through the provider-owned ChatGPT subscription
login. The initial turn called the real Choir `goal_status` MCP tool and
received the daemon's typed missing-Goal response. A second turn resumed the
same Codex thread and correctly identified the prior Goal ID without another
tool call.

The launch ignores ambient Codex configuration and repository rules, disables
native execution and other undeclared host surfaces, uses a sterile working
root, and requires the exact Choir MCP server with the same nine tools exposed
to Claude. Choir rejects thread drift, undeclared tools, native host-tool
events, incomplete tool lifecycles, failed turns, and non-JSON output. The
one-time Conductor capability is never placed on the command line or disk; the
fixed Choir MCP child reads only the socket and capability names from its
direct Codex parent when Codex omits them from the child environment. A fresh
repository now also creates the control database directory before the daemon's
first Goal tick.

At `2026-07-20T13:50:14-05:00`, the Codex Conductor inspected Bead `live-ap9`
and submitted one durable Goal through `goal_submit` without editing the
repository. `choird` dispatched a real Codex implementation Take in BoxLite,
normalized the one-path candidate, ran `moon test --target native`, obtained an
independent Part audit, promoted the candidate, verified the combined tree,
and obtained an independent Goal audit. The Part recorded 12 effect receipts,
one verification receipt, one audit receipt, and one integration receipt; the
Goal recorded one verification receipt and one audit receipt. Publication then
remained pending because the disposable repository deliberately had no remote.

The first native verification exposed that the minimal Debian image lacked the
C runtime objects required by MoonBit's native target. The Take runtime now
pins the amd64 `buildpack-deps` platform manifest
`sha256:5009ae2bfc9ff32268f48dd81844776a977a88cdfba28577db9b5857127a044a`;
networking remains disabled and the runtime-policy digest binds the image.
Codex also emitted its reserved-server resource discovery before ordinary
Choir tool calls. The driver now permits only those two read-only discovery
methods on that reserved server and continues to reject every non-discovery
call outside the exact Choir server and allowlist.

#### Post-snapshot mixed-provider Goal amendment

At `2026-07-20T01:26:46-05:00`, the native mixed-provider Goal command passed
against the same pinned Claude `2.1.215`, Codex `0.144.6`, and BoxLite `v0.9.7`
profiles. Choir admitted two nonconflicting Parts at a concurrency limit of two.
The Claude and Codex implementation workflows overlapped in separate BoxLite
Takes; each then completed its own typed verification and independent audit.
The Goal runner deferred promotion until assurance was present, serialized the
two divergent candidates against the changing Goal head, and produced the
expected combined tree.

The run recorded exactly 24 effect receipts, two verification receipts, two
audit receipts, and two integration receipts. Provider selection remained a
typed per-Part capability; neither the scheduler nor any gate branched on
provider-private state. The command was:

```text
moon run --target native src/bin/choir_conformance -- e2e --fixture mixed-provider-goal
```

At `2026-07-20T12:17:26-05:00`, both native commands were rerun after the
local configuration reduction. The Codex-only lifecycle again produced 12
effect receipts and exactly one verification, audit, and integration receipt.
Its candidate was `a5ee089287902099cd270cd7ad149eff861b7391`; serialized promotion
produced `3d88e221df27010b993d07b7d432aba6d8cd4ae9`, and restart recovery issued
zero duplicate implementation Takes. The mixed-provider Goal again reached
concurrency two, promoted Codex then Claude, recorded 24/2/2/2 effect,
verification, audit, and integration receipts, persisted the selection
decision, and validated the combined tree.

At `2026-07-20T17:23:36-05:00`, the pinned BoxLite admission command passed all
18 live identity, KVM, lifecycle, isolation, read-only, and network-denial
checks using an exact six-file corrected runtime bundle. The real
`native-codex-part-lifecycle` command then ran implementation, verification,
and independent audit through the saved Codex subscription login. It produced
12 effect receipts and exactly one verification, audit, and integration
receipt; restart issued zero duplicate implementation dispatches. The
candidate and promotion commits were
`a5ee089287902099cd270cd7ad149eff861b7391` and
`3d88e221df27010b993d07b7d432aba6d8cd4ae9` respectively.

At `2026-07-21T01:42:31-05:00`, the admitted BoxLite identity/security command
again passed all 18 live rows, followed by a complete KVM-backed Take through
the new Unix-socket runtime owner. The Take proved socket mode `0600`, a
box-and-access-scoped execution capability, absence of the BoxLite REST key,
URL, binary, and runtime directory from the MCP launch, mutable guest-only path
identity, read-only assurance, typed verification, bounded copy-out,
deterministic candidate normalization, and cleanup of both owner and runtime
process groups. The run also exposed and fixed a graceful-exit race: the MCP
bridge now drains pending JSON-RPC responses as well as guest commands before
exiting. A negative run using the newer local BoxLite checkout was rejected at
the new preflight identity barrier before image pull or KVM execution; direct
diagnosis confirmed that unadmitted runtime's shim was independently failing
with `SIGSEGV`, while the pinned v0.9.7 corrected bundle passed.

At `2026-07-21T00:16:12-05:00`, the Codex lifecycle passed again after durable
process execution was connected to Part verification. The typed BoxLite check
exited zero, its exact start/terminal state and output digest persisted before
the verification receipt, and restart produced zero duplicate implementation
dispatches. The run again recorded 12 effect receipts and one verification,
audit, and integration receipt. The mixed Claude/Codex Goal also passed with
concurrency two, 24 effect receipts, two verification receipts, two audit
receipts, two integrations, and the expected combined tree. The accompanying
native suite passed 341/341 and the hermetic runner passed 36/36, including all
four registered process crash boundaries.

At `2026-07-20T12:37:00-05:00`, the Codex-only lifecycle command passed again
after deleting the generic runner, provider-hook/provisioning machinery, and
old type domains. The restricted live Conductor startup also passed with
socket mode `0600`, authenticated registration, no Zellij dependency, and the
expected fail-closed tool surface. The accompanying native suite passed
289/289, the hermetic runner passed 13/13, the sandbox MCP bridge passed 4/4,
and the repository linter reported no findings.

The same command passed again at `2026-07-20T11:40-05:00` after the old
orchestration packages were deleted and the minimal Conductor server replaced
the v1 server. During that rerun Codex first emitted a balanced
`list_mcp_resources` event against the exact declared sandbox MCP server. Choir
now treats that read-only protocol discovery as provider metadata, omits it from
the durable Part-effect trace, and still requires at least one successful
declared Part tool call. The rerun retained the same two-provider, 24-effect,
two-verification, two-audit, two-integration result.

This proves the checked-in two-Part path, not Conductor decomposition,
user-facing Goal submission, provider interruption recovery, cancellation, or
Goal-level assurance and publication.

#### Post-snapshot joined submission and execution amendment

At `2026-07-20T03:03:51-05:00`, the joined native command exercised the
accepted-draft boundary and execution boundary in one disposable repository.
It decoded and accepted a typed Goal draft backed by a real Bead, persisted the
selection, Part workflow, and restart-discoverable Goal execution record, then
ran the same native Goal tick used by the daemon. The Part used the pinned
ChatGPT-authenticated Codex client through BoxLite for implementation and an
independent audit, passed its typed Moon verification, and promoted through the
deterministic Goal ref.

An earlier joined run reached `GoalExecutionBlocked` because its independent
audit returned a blocking finding; Choir did not integrate that candidate. The
passing run integrated the durable Part with 12 effect receipts, one
verification receipt, one audit receipt, and one integration receipt. At the
time, the incomplete execution state machine also labeled that point
`GoalExecutionSucceeded` and `GoalSucceeded`. That label is superseded: Part
integration now advances to nonterminal `GoalExecutionAssuring`, and terminal
success remains unavailable until all finalization evidence exists. Promotion
commit `ed27840f2216d4541dd54a3e4dc302b89ea06546`
changes `answer()` from `1` on `main` to `2` only on the deterministic Goal
ref. The command shapes were:

```text
moon run --target native src/bin/choir_conformance -- e2e --project <disposable-repository> --draft <typed-goal-draft.json>
moon run --target native src/bin/choir_conformance -- status --project <disposable-repository> --goal <goal-id>
```

The status command ran in a separate process after execution exited and
reloaded the exact Goal and integrated Part identities and receipt counts. During
this proof, an under-declared candidate containing Moon build output was
rejected rather than widening its ownership claim, identical submission replay
was corrected to preserve advanced Part state, and cross-repository runtime
keys were corrected to include repository identity. This proves the durable
submission-to-execution join, provider dispatch, passive Part gates, serialized
promotion, and restart-readable inspection. It does not prove an interactive
Claude `/goal` invocation, daemon-loss recovery during a live provider session,
Goal-level combined assurance, publication, or final-PR reconciliation.

#### Post-snapshot cancellation and authorization amendment

At `2026-07-20T04:06:43-05:00`, cancellation gained an atomic Goal-to-Part
authorization guard and exact integration-witness reconciliation. The state
store now commits a Part mutation only while a supplied Goal state record still
has the exact expected key, version, fencing epoch, and digest in the same
SQLite transaction. An idempotent replay remains valid after the Goal changes,
because it proves that exact mutation committed first; a new mutation using a
stale running-Goal precondition is rejected without changing Part state or
writing its outbox event. The driver applies this guard to Part effect planning,
effect authorization, integration planning, and integration authorization.

If cancellation finds an authorized integration effect, the native adapter
reads the exact deterministic Goal ref and intent witness ref, persists the
resulting applied/not-applied/diverged observation against the authorized
effect, and only then records the Part cancellation disposition. An applied
promotion and its receipt are preserved; an unapplied effect is not dispatched
after cancellation; uncertainty never becomes success.

The live Codex cancellation command launched the real provider-managed
subscription client inside BoxLite, interrupted its Choir-owned process group,
and reloaded one authorized implementation effect as `PartEffectUncertain`, an
interrupted implementation Take, an uncertain sandbox lease, and a
recovery-uncertain harness session. It dispatched Codex exactly once and
recorded no verification, audit, or integration receipt:

```text
moon run --target native src/bin/choir_conformance -- e2e --fixture native-codex-cancellation
```

A fresh joined disposable-repository run then exercised the guarded production
path through submission, Codex implementation, typed verification, independent
Codex audit, and Git promotion. It reached `PartIntegrated` with 12 effect
receipts, one verification receipt, one audit receipt, and one integration
receipt. The former terminal Goal label at this point has since been removed.
This proves the implemented
Part/provider/integration cancellation slice and both cutoff transaction
orderings; it does not substitute for the later Goal-level publication and PR
ordering cases.

#### Post-snapshot Goal branch seal amendment

At `2026-07-20T09:34:08Z`, Goal assurance gained its first durable production
slice. A fully integrated Part set no longer commits Goal success. The runner
first persists `GoalExecutionAssuring`; `GoalExecutionSucceeded` is reachable
only from the later assured/finalization path.

The new assurance record reconstructs the complete promotion chain from the
captured base to the observed Goal head, rejects missing, duplicated, forked,
or discontinuous integration receipts, canonicalizes the combined verification
specifications, and binds them to a derived assurance-policy revision. It then
persists one seal intent through planned, authorized, witnessed, and sealed
states. Every write uses the exact Goal state record as a SQLite precondition.
A concurrent cancellation therefore either follows a committed assurance write
or rejects the stale write without an assurance mutation or outbox record.

The native Git adapter creates the deterministic seal witness only when the
Goal ref and tree exactly match the authorized subject. Re-observation is
idempotent; a changed witness, head, or tree is not accepted. Goal status now
exposes the assurance stage and immutable seal when present. The checked tests
cover the Goal-tree verification and combined-audit gates, seal authorization,
record round trip, atomic cancellation race, and a real isolated Git witness
creation/replay/divergence sequence. The later joined live run connected both
Goal verification and independent Goal audit as durable BoxLite-backed Takes
and reached `GoalExecutionAssured`.

#### Post-snapshot branch publication amendment

At `2026-07-20T11:12:51Z`, branch publication gained a durable production
slice. One canonical publication record binds the exact assured Goal record,
branch seal, combined verification evidence, independent Goal-audit evidence,
remote repository identity, remote name, remote head ref, and sealed OID. The
record advances through passive observation, explicit authorization, and an
exact receipt; remote absence, an already exact head, drift, and observation
uncertainty are distinct typed states. Every persistence step is guarded by the
exact Goal state version and fencing epoch.

The native adapter resolves the configured Git remote, reads the exact remote
ref, and places that observed old OID into the push as an exact remote-head
lease with local hooks disabled. An absent ref uses an empty expected OID.
Authorization separately proves ancestry, so the lease cannot authorize a
non-fast-forward update. It always reads the remote again after the push
request. A matching ref can therefore be adopted after process loss, while a
different ref is reported as drift and is never overwritten. Real-Git tests
cover initial creation, exact-prior update, concurrent create/update races,
idempotent replay, adversarial remote drift, and restart recovery at all five
named publication fault points against an isolated bare repository and durable
SQLite state.

The same five-cutoff proof is directly executable as
`choir_conformance publication-faults`. Its typed report records the durable
state observed at interruption, whether the exact remote ref had moved,
successful recovery to one receipt, and stable replay for every cutoff. The
current report passes 5/5: the remote remains unchanged before authorization
and before the update, is adopted after either post-update interruption, and
retains the committed receipt when acknowledgement of its transaction is
lost.

The previously assured disposable Goal was then published through the durable
adapter to a fresh local bare remote. Both the initial invocation and a second
process invocation returned `GoalPublicationComplete`; the remote and durable
receipt both contained exact sealed OID
`55cd8b2a425a833631b269c2a9ea7481c92966f5`. A separate status invocation
reported `BranchPublicationReceipted`, the canonical remote identity and head
ref, receipt presence, and that OID. The command shape was:

```text
moon run --target native src/bin/choir_conformance -- publish --project <disposable-repository> --goal <goal-id>
```

This proves explicit publication and restart adoption. The later finalization
slice connects it to the ordinary Goal runner.

At `2026-07-20T14:19:57-05:00`, the implementation also exercised the complete
named publication crash matrix: after intent persistence, after authorization,
after the remote update before response handling, after response handling
before receipt persistence, and during the receipt transaction. The first two
recover with the remote absent; the latter three recover by adopting the exact
sealed OID. Every case converges to one canonical receipt, replay is a no-op,
and publication alone leaves the Goal in `GoalExecutionAssured`.

#### Post-snapshot final-PR and readiness amendment

At `2026-07-20T11:45:38Z`, the canonical final-PR protocol and terminal Goal
decision gained durable production slices. The generated PR document is a
content-addressed artifact containing the Goal-contract identity, evidence-
manifest identity, and deterministic marker. The intent and every transition
are persisted under the exact assured-Goal precondition. Before creation, the
native forge adapter performs a complete paginated scan across open, closed,
and merged PRs. Exactly one marker match is adopted; duplicate markers,
markerless exact matches, closed PRs, changed heads/bases, and uncertain
observations remain distinct non-success states.

Create authorization and possible dispatch are separate durable transitions.
Only the process that newly commits `PullRequestCreateMayHaveBeenIssued`
receives the one-use create capability. A restart, replay, transaction conflict,
or lost acknowledgement may only re-query; it cannot send another create. The
adapter ignores create-command prose and re-queries the complete remote set
before recording an exact receipt.

At `2026-07-20T14:34:31-05:00`, the implementation exercised every named
intent/create/receipt crash point through `pr.during_receipt_transaction`.
Crashes before create authorization or dispatch recover from durable state;
crashes after the controlled remote create adopt the exact marker-bound PR;
and receipt-transaction acknowledgement loss reloads the committed receipt.
Every recoverable case issues exactly one create and records exactly one
receipt. The deliberately ambiguous crash after `CreateMayHaveBeenIssued` but
before dispatch records `RemoteCreateUncertain`, issues zero creates, and does
not resend after restart. The Goal remains `GoalExecutionAssured` throughout.
The matrix is directly executable as `choir_conformance pull-request-faults`;
its typed report currently passes all 7/7 cutoffs and records the interrupted
intent state, total create count, expected terminal or uncertain outcome, and
duplicate-dispatch result for each row.
The separate `choir_conformance pull-request-states` command now drives six
remote observations through the durable readiness adapter. Exact and manually
edited title/body states succeed; a closed PR requests user input; retargeted
or head-changed PRs report drift; and duplicate marker matches remain
ambiguous. The current typed report passes 6/6 and leaves every non-ready Goal
in `GoalExecutionAssured` rather than manufacturing success.
At `2026-07-20T14:42:07-05:00`, the finalization response boundary and terminal
race also became executable. A real Git/SQLite controlled-forge test removes
the evidence-manifest link before the readiness response and observes
`NeedsInput` with the Goal still assured. It then changes the same link only
after a `Ready` response and proves that the response remains the readiness
linearization point. At the injected
`pr.after_readiness_observation_before_success_transaction` boundary,
cancellation wins the Goal compare-and-set and a later success attempt fails;
in the inverse ordering cancellation observes terminal success. Each ordering
has exactly one terminal outbox record and no next-version terminal record.
That proof is now directly executable as
`choir_conformance finalization-races`. Its typed report records both sides of
the readiness-response boundary, success winning before late cancellation,
cancellation winning after readiness but before success, and unique terminal
outbox cardinality. The current report passes every field.

Readiness is then observed separately against the canonical receipt. `Ready`
requires an open PR with the exact repository identities, head and base refs,
sealed head OID, identity marker, Goal-contract link, and evidence-manifest
link. The terminal Goal write compare-and-sets `GoalExecutionAssured` to
`GoalExecutionSucceeded` while guarding that exact readiness state record in
the same SQLite transaction. A later readiness observation or cancellation
therefore displaces success instead of racing past it.

The disposable published Goal exercised the complete control-plane protocol
with an injected synthetic forge, so no external PR was created. The first run
persisted one PR receipt; replay returned the same canonical result. A fresh
readiness observation then committed `GoalExecutionSucceeded`, replayed
success, and exposed `PullRequestReady` plus the finalization ID through Goal
status. Finally, the Goal was reset only inside the disposable fixture to its
previous assured record and one ordinary Goal tick carried the same durable
publication, PR, readiness, and terminal-success path to completion. Command
shapes were:

```text
moon run --target native src/bin/choir_conformance -- pull-request --project <disposable-repository> --goal <goal-id> --synthetic
moon run --target native src/bin/choir_conformance -- finish --project <disposable-repository> --goal <goal-id> --synthetic
moon run --target native src/bin/choir_conformance -- tick --project <disposable-repository> --synthetic
```

This proves the durable one-shot and ordinary-runner semantics. The
ambiguous-create, remote-state, readiness, and cancellation race matrices are
covered by the controlled-forge and pure workflow evidence above.

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

At `2026-07-20T15:02:12-05:00`, the complete live Take sandbox command passed
again after runtime cleanup was tightened. The command proved the mutable
result round trip, stable candidate retry, read-only assurance subject, audit
scratch boundary, and typed process execution, then left no matching
`/tmp/choir-take-*` runtime root. A narrow native regression test separately
constructs a read-only result tree and proves the validated cleanup path
removes it.

At `2026-07-21`, the narrowed runtime owner was exercised through the real
provider lifecycle rather than only through its standalone MCP probe. Codex's
host boundary masks host `/tmp`, so an owner socket placed directly in the
BoxLite runtime root was unreachable from the MCP child. The owner now places
only that socket in a dedicated mode-`0700` directory. The Codex boundary
binds that exact sibling directory read-only at the fixed short path
`/tmp/choir-owner` inside the sterile process boundary. The short target stays
within the Unix-domain socket path limit even when the source Take root is
long. It cannot bind an arbitrary host path, and the surrounding
BoxLite runtime directory, REST key, owner secret, logs, and client state stay
outside the namespace.

The same live run found that trusted `moon check` inside the guest requires the
offline Moon registry as well as `bin`, `lib`, and `include`. Toolchain staging
now copies and validates `registry/cache` and `registry/index`; verification
does not depend on network package resolution. Local Goal control was also
exercised outside the Conductor environment using authenticated registration
with the current-user `choird` socket.

The real Codex Part lifecycle then passed with twelve effect receipts, one
verification receipt, one audit receipt, one integration receipt, no repeated
implementation after restart, and one serialized promotion. The equivalent
Claude lifecycle passed, and the mixed-provider Goal ran one Claude Part and
one Codex Part concurrently, produced two verification, audit, and integration
receipts, and reached the expected combined tree. The audit instruction now
names the already-bound verification evidence digests: the auditor still
inspects the candidate independently but does not invent a missing-execution
finding merely because implementation transcripts are intentionally absent.
The executable commands were:

```text
moon run --target native src/bin/choir_conformance -- e2e --fixture native-codex-part-lifecycle
moon run --target native src/bin/choir_conformance -- e2e --fixture native-part-lifecycle
moon run --target native src/bin/choir_conformance -- e2e --fixture mixed-provider-goal
```

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

Prior-art repositories:

- [OmniGent](https://github.com/omnigent-ai/omnigent)
- [Overstory](https://github.com/jayminwest/overstory)
- [Agent Orchestrator](https://github.com/AgentWrapper/agent-orchestrator)
- [Gas City](https://github.com/gastownhall/gascity)
- [Beads](https://github.com/gastownhall/beads)
- [Semble](https://github.com/MinishLab/semble)
- [AWS CLI Agent Orchestrator](https://github.com/awslabs/cli-agent-orchestrator)
- [Codex Orchestrator](https://github.com/kingbootoshi/codex-orchestrator)
- [ORCH](https://github.com/oxgeneral/ORCH)

The extracted Claude coordinator prompt and `tweakcc` informed only an
unsupported experiment. Neither is a supported dependency or policy source.
