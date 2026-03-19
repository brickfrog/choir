# ExoMonad Service Specification

**Status**: Draft v0
**Scope**: Language-agnostic specification for a MoonBit reimplementation of [exomonad](https://github.com/tidepool-heavy-industries/exomonad)
**Audience**: Implementors of the MoonBit rewrite

This spec describes the orchestration service that manages heterogeneous coding agent teams.
It does not describe the agents themselves — they are external processes (Claude CLI, Gemini CLI,
Moon Pilot) driven by specs and communicating via MCP, tmux, or file-based protocols.

### Conceptual Model: Hylomorphism Over Context Windows

The system is a hylomorphism over agent context windows:

- **Unfold** (anamorphism): scaffold the task tree — spawn agents, create worktrees, decompose work into branches
- **Fold** (catamorphism): integrate results — merge PRs, notify parents, collapse the tree back toward main

The orchestrator provides the structural recursion primitives. The TL agent decides how deep to unfold and when to fold. Each context window is a node in the tree; the orchestrator manages the edges.

---

## 1. Problem Statement

Coding agents working alone plateau quickly. Complex tasks require decomposition into parallel
subtasks, each assigned to a specialized agent, with results merged back up. This requires:

- Spawning agents in isolated workspaces (git worktrees, tmux panes)
- Routing messages between agents in a tree hierarchy (parent/child)
- Tracking agent lifecycle without polling or blocking the parent
- Merging work products (PRs) in dependency order

ExoMonad is the orchestrator that does this. It is NOT an agent — it has no LLM, makes no
decisions, generates no code. It executes effects on behalf of agent-side tool logic.

### 1.1 Trust Posture

The orchestrator trusts the agents it spawns. Agents run with full filesystem and git access
in their worktrees. The orchestrator does not sandbox, audit, or restrict agent behavior beyond
workspace isolation (separate worktree = separate branch).

### 1.2 Boundary

ExoMonad is a tool server, not a task planner. It does not decide what to build, does not
assign work, does not evaluate quality. The TL agent (Claude) makes all decomposition and
dispatch decisions. ExoMonad executes them.

---

## 2. Goals and Non-Goals

### 2.1 Goals

- Expose orchestration primitives as MCP tools (spawn, notify, PR, merge, message)
- Manage agent identity, workspace isolation, and lifecycle
- Route messages between agents via push-based delivery (no polling)
- Support heterogeneous agent types (Claude, Gemini, future: Moon Pilot)
- Compile in <2 seconds, produce a single native binary
- Zero external dependencies at runtime (no Docker, no Nix, no language-specific toolchains)
- Transport-agnostic server design (UDS for local, TCP for remote/SSH agents)

### 2.2 Non-Goals

- Agent intelligence or decision-making
- Code review or quality gating (that's Copilot + the agents)
- UI, dashboard, or web interface
- General-purpose job scheduling

---

## 3. System Overview

### 3.1 Architecture

Persistent server process managing shared state, with a thin stdio translator for MCP clients.

```
choir serve                     # persistent server, listens on transport(s)
  ├── Agent Registry               # in-memory, all agent state
  ├── Message Router               # push delivery to agents
  ├── GitHub Poller                # background task, PR/CI events
  ├── Mutex Registry               # coordination locks
  └── Tool Dispatch                # role-gated tool handlers

choir mcp-stdio                 # thin translator, one per MCP client
  Claude/Gemini ↔ stdin/stdout (JSON-RPC) ↔ mcp-stdio ↔ transport ↔ serve
```

The server holds all mutable state. `mcp-stdio` is stateless — it translates MCP JSON-RPC
to server requests over the configured transport. One `mcp-stdio` per agent session, one
`serve` per project.

### 3.2 Main Components

| Component | Responsibility |
|-----------|---------------|
| **Server** | Persistent process. Hosts all registries, poller, and tool dispatch. |
| **MCP Translator** | Stateless stdio bridge. Translates JSON-RPC ↔ server requests. |
| **Tool Registry** | Maps tool names to handler functions. Per-role tool sets. |
| **Agent Registry** | In-memory. Tracks spawned agents: identity, role, parent, workspace, alive status. |
| **Workspace Manager** | Creates/destroys git worktrees and tmux windows/panes. |
| **Message Router** | Delivers messages between agents (Teams inbox, tmux STDIN, future: ASP). |
| **PR Manager** | Creates, updates, and merges PRs via `gh` CLI. |
| **GitHub Poller** | Background task polling PR/CI status, firing events into agent panes. |
| **Mutex Registry** | In-memory coordination locks with FIFO queues and TTL expiry. |

### 3.3 Abstraction Layers

| Layer | What lives here |
|-------|----------------|
| **Tool Logic** | Tool schemas, argument parsing, dispatch. Per-role tool sets. |
| **Coordination** | Agent tree, message routing, mutex, lifecycle tracking. |
| **Execution** | Git worktree ops, tmux session management, process spawning. |
| **Transport** | UDS, TCP, stdio translation. See section 5. |
| **Integration** | GitHub API (via `gh`), Claude CLI, Gemini CLI, Moon Pilot CLI. |
| **Observability** | Structured logging, OTel spans, run ID propagation. |

### 3.4 External Dependencies

| Dependency | Purpose | Required |
|------------|---------|----------|
| `git` | Worktree creation, branch management | Yes |
| `gh` | GitHub PR operations | Yes |
| `tmux` | Agent isolation and multiplexing | Yes (local agents) |
| `claude` | Claude Code CLI (TL agent) | Yes (for Claude agents) |
| `gemini` | Gemini CLI (leaf agent) | Yes (for Gemini agents) |
| `moon pilot` | Moon Pilot CLI (future leaf agent) | No |
| `ssh` | Remote agent execution | No (see Appendix A) |

---

## 4. Core Domain Model

### 4.1 Entities

**Agent**
```
agent_id     : String         -- birth-branch name (immutable, deterministic)
role         : Role           -- root | tl | dev | worker
agent_type   : AgentType      -- Claude | Gemini | MoonPilot
parent       : Option[String] -- parent agent_id (None for root)
workspace    : WorkspacePath   -- filesystem path to worktree
branch       : BranchName     -- git branch
tmux_target  : Option[TmuxTarget] -- window or pane (None for remote agents)
host         : Host           -- Local | Remote(ssh_target)
alive        : Bool
```

**Role**
```
enum Role {
  Root    -- human-facing session, minimal tools
  TL      -- tech lead, can spawn children, merge PRs
  Dev     -- leaf agent, implements spec, files PR
  Worker  -- ephemeral pane, no branch, research/in-place edits
}
```

**AgentType**
```
enum AgentType {
  Claude      -- Claude Code CLI, MCP-native
  Gemini      -- Gemini CLI, MCP-native
  MoonPilot   -- Moon Pilot CLI, tmux-driven (future)
}
```

**Host**
```
enum Host {
  Local                          -- same machine as server
  Remote { ssh_target: String }  -- reachable via ssh (future, see Appendix A)
}
```

**Message**
```
sender    : String        -- agent_id
recipient : String        -- agent_id
content   : String        -- free-form text
status    : Option[Status] -- success | failure | info
```

**Workspace**
```
path          : FilePath      -- absolute path to worktree
branch        : BranchName    -- branch name
parent_branch : BranchName    -- base branch for PR
host          : Host          -- where the workspace lives
```

**PR**
```
number    : Int
branch    : BranchName
base      : BranchName
status    : PRStatus      -- open | merged | closed
ci_status : CIStatus      -- pending | passing | failing
```

**MutexLock**
```
name      : String
holder    : String        -- agent_id
acquired  : Timestamp
ttl       : Duration
```

### 4.2 Identifiers

- **Agent ID**: birth-branch name. `root` for the TL session. `main.feature-a` for a child.
  Immutable after creation. Deterministic from branch naming convention.
- **Branch naming**: `{parent_branch}.{slug}` (dot separator). PRs target parent branch.
- **Workspace path**: `.exo/worktrees/{agent_id}/` for worktree agents.
  `.exo/agents/{agent_id}/` for standalone agents.
- **Run ID**: UUID generated at session start, propagated to all children via env var.
  Used for OTel trace correlation.

---

## 5. Transport Layer

### 5.1 Design Principle

The server exposes a request/response interface over a transport. Tool calls, registry queries,
and lifecycle operations all go through the same interface. The transport is pluggable — the
server doesn't know or care whether requests arrive via UDS, TCP, or something else.

### 5.2 Transports

| Transport | Listener | Use case |
|-----------|----------|----------|
| **UDS** (default) | `.exo/server.sock` | Local agents. No port conflicts, filesystem-scoped discovery. |
| **TCP** (optional) | `0.0.0.0:{port}` | Remote agents via SSH tunnel or direct connect. |

The server binds one or both transports based on config. UDS is always available. TCP is
opt-in via config (`listen_tcp = "0.0.0.0:9100"`).

### 5.3 MCP Stdio Translator

`choir mcp-stdio` is a thin bridge process. It:
1. Reads JSON-RPC from stdin (MCP client)
2. Translates to a server request
3. Sends to server over configured transport (UDS by default)
4. Reads server response
5. Writes JSON-RPC to stdout (MCP client)

It holds no state. One instance per MCP client session (each Claude/Gemini session gets its own).
If the server is unreachable, `mcp-stdio` returns an MCP error response.

### 5.4 Transport for Hooks

Hooks (`session-start`, `pre-tool-use`) are invoked by the MCP client as a subprocess
(`choir hook <event>`). The hook binary connects to the server over the same transport,
sends the event, returns the response to stdout, and exits.

Fail-open: if the server is unreachable, hooks print `{"continue":true}` and exit 0.

### 5.5 Wire Format

Server requests and responses use JSON over the transport. Not MCP JSON-RPC — that's between
the MCP client and `mcp-stdio`. The internal wire format is simpler:

```json
// Request
{ "method": "tools/call", "role": "tl", "name": "fork_wave", "args": {...} }

// Response
{ "ok": true, "result": {...} }
{ "ok": false, "error": "..." }
```

### 5.6 Discovery

Agents discover the server via:
1. **UDS**: look for `.exo/server.sock` in the project root (walk up from cwd)
2. **TCP**: read `listen_tcp` from `.exo/config.toml`

`choir init` writes `.mcp.json` pointing `mcp-stdio` at the project root, which handles
discovery implicitly.

---

## 6. Tool Specification

### 6.1 Tool Registry

Each role exposes a subset of tools. Tool definitions include: name, description, JSON Schema
for arguments, and a handler function.

| Tool | Roles | Description |
|------|-------|-------------|
| `fork_wave` | root, tl | Spawn N parallel Claude agents in worktrees with own branches + PRs |
| `spawn_gemini` | root, tl | Spawn Gemini agent in a worktree with own branch + PR |
| `spawn_moon_pilot` | root, tl | Spawn Moon Pilot agent in a worktree with own branch + PR |
| `spawn_worker` | root, tl | Spawn ephemeral pane worker (any agent type, no branch, no PR, research/in-place) |
| `file_pr` | tl, dev | Create or update PR for current branch |
| `merge_pr` | root, tl | Merge a child's PR (auto-acquires `branch:{parent}` mutex) |
| `track_pr` | root, tl | Register PR with the GitHub poller for review tracking |
| `notify_parent` | tl, dev, worker | Send message to parent agent |
| `send_message` | all | Send message to any agent by ID |
| `shutdown` | dev, worker | Notify parent, close own pane (blocked if `ChangesRequested`) |
| `task_list` | tl, dev, worker | List tasks from `.exo/tasks/` |
| `task_get` | tl, dev, worker | Get task by ID |
| `task_create` | tl, dev, worker | Create a new task |
| `task_update` | tl, dev, worker | Update task status/owner/notes |
| `kv_get` | all | Read a key from the persistent KV store |
| `kv_set` | all | Write a key-value pair to the persistent KV store |
| `kv_delete` | all | Delete a key from the persistent KV store |
| `kv_list` | all | List all keys in the KV store |
| `mutex_acquire` | all | Acquire a named coordination lock (FIFO queue, TTL) |
| `mutex_release` | all | Release a held coordination lock |
| `mutex_status` | all | Query lock holder and queue length |
| `fork_session` | root, tl | Create a named session subdirectory for a nested team |

### 6.2 Tool Call Flow

```
Claude → stdin (JSON-RPC) → mcp-stdio → UDS/TCP → server
  → tool registry lookup (role + name)
  → JSON Schema validation
  → handler execution
  → response back through the chain
```

### 6.3 Tool Argument Validation

All tool arguments are validated against JSON Schema before dispatch. Invalid arguments return
a structured error, not a crash. Schema is defined per-tool in code, not in external files.

### 6.4 Hook Protocol

Hooks are lifecycle callbacks invoked by the MCP client (Claude Code) at specific events.
The orchestrator binary is called with a subcommand and receives event data on stdin.

| Hook | When | Purpose |
|------|------|---------|
| `session-start` | Claude session begins | Register session ID for context inheritance |
| `pre-tool-use` | Before any tool call | Allow/deny tool calls (role-based gating) |

Hook responses: `{ "continue": true }` to allow, exit code 2 to block with stderr message.
Fail-open: if the server is unreachable, hooks return `{ "continue": true }` and exit 0.

---

## 7. Configuration Specification

### 7.1 Config Files

| File | Scope | Purpose |
|------|-------|---------|
| `.exo/config.toml` | Project | Default role, shell command, transport, extra MCP servers |
| `.exo/config.local.toml` | Worktree | Role override for this specific worktree |

### 7.2 Resolution Order

`config.local.toml` role > `config.toml` default_role > auto-detect

### 7.3 Config Fields

```toml
# All fields optional — shown with defaults
default_role = "tl"              # project-wide default
role = "dev"                     # worktree-specific override (local only)
project_dir = "."
shell_command = "nix develop"    # environment wrapper

# Transport
listen_uds = ".exo/server.sock" # always on
listen_tcp = ""                  # opt-in, e.g. "0.0.0.0:9100"

# Observability
otlp_endpoint = ""               # e.g. "http://localhost:4317"

# Extra MCP servers — propagated to .mcp.json for all agents
# Each section becomes an entry in mcpServers{}
# [extra_mcp_servers.notebooklm]
# type = "stdio"
# command = "node"
# args = ["/path/to/notebooklm-mcp/index.js"]
```

### 7.4 MCP Client Registration

The orchestrator writes `.mcp.json` during init (and on each `spawn_agent`) to register itself
plus any extra MCP servers from config:

```json
{
  "mcpServers": {
    "choir": {
      "type": "stdio",
      "command": "choir",
      "args": ["mcp-stdio", "--role", "tl", "--name", "root"]
    },
    "notebooklm": {
      "type": "stdio",
      "command": "node",
      "args": ["/path/to/notebooklm-mcp/index.js"]
    }
  }
}
```

`extra_mcp_servers` entries from `config.toml` are merged into every `.mcp.json` the server
generates. This allows opt-in tooling (NotebookLM, custom MCPs) to be available to all agents
without per-agent configuration.

---

## 8. Agent Lifecycle State Machine

### 8.1 States

```
Spawning → Active → Completing → Done
                  → Failed
```

- **Spawning**: worktree created, tmux pane created, agent process starting
- **Active**: agent is running and accepting tool calls
- **Completing**: agent has called `shutdown` or `file_pr`, wrapping up
- **Done**: agent exited cleanly, parent notified
- **Failed**: agent exited with error or timed out, parent notified with failure status

### 8.2 Transitions

| From | To | Trigger |
|------|----|---------|
| Spawning | Active | Agent process detected running in tmux pane |
| Active | Completing | Agent calls `shutdown` or `file_pr` |
| Active | Failed | Agent process exits non-zero, pane dies, or timeout |
| Completing | Done | Parent notified, cleanup complete |
| Failed | Done | Parent notified with failure status |

### 8.3 Critical Phase Protection

Agents cannot exit during critical phases (e.g., `ChangesRequested` — Copilot requested
changes and the agent hasn't pushed fixes yet). The `shutdown` tool checks current phase
and rejects if exit would lose work.

---

## 9. Workspace Management

### 9.1 Workspace Layout

```
project-root/
├── .exo/
│   ├── config.toml
│   ├── config.local.toml        # worktree-specific
│   ├── server.sock              # UDS endpoint
│   ├── worktrees/               # git worktrees for agents
│   │   ├── main.feature-a/
│   │   └── main.feature-b/
│   ├── agents/                  # standalone agent dirs
│   ├── run_id                   # current swarm run UUID
│   └── tmp/                     # scratch space
└── .mcp.json                    # MCP server registration
```

### 9.2 Worktree Creation

1. `git worktree add .exo/worktrees/{slug} -b {parent_branch}.{slug}`
2. Create tmux window (Claude) or pane (Gemini) targeting the worktree path
3. Write `.exo/config.local.toml` with role override
4. Write `.mcp.json` with MCP server registration pointing to parent's server
5. Launch agent process in the tmux target

### 9.3 Worktree Cleanup

On agent completion or failure:
1. Close tmux pane/window
2. `git worktree remove .exo/worktrees/{slug}` (after PR merge or on failure)
3. Remove agent from registry

### 9.4 Isolation Modes

| Mode | Workspace | Branch | PR | Use case |
|------|-----------|--------|----|----------|
| `worktree` | Own worktree | Own branch | Yes | Implementation tasks |
| `inline` | Parent's directory | No branch | No | Ephemeral research/investigation |
| `standalone` | Own `git init` repo | Own repo | No | Information segmentation |

---

## 10. Message Routing

### 10.1 Delivery Priority

Messages from agent to agent are delivered via the first available channel:

1. **Teams inbox** (primary) — write JSON to `~/.claude/teams/{name}/inboxes/{inbox}.json`.
   Claude Code's InboxPoller delivers it as a native `<teammate-message>`.
2. **tmux STDIN** (fallback) — `tmux load-buffer` + `paste-buffer` into target pane.
   Works for any local agent type regardless of MCP support.
3. **TCP message** (remote agents) — server pushes message over TCP to remote agent's
   `mcp-stdio` instance. See Appendix A.

### 10.2 Parent Resolution

When an agent calls `notify_parent`, the server resolves the parent from the in-memory
agent registry. The caller's identity is determined from the `mcp-stdio` connection context
(role + name from CLI args, authenticated at connect time).

### 10.3 Bidirectional Messaging

`send_message` enables arbitrary agent-to-agent messaging. Routing by agent type and host:
- Claude (local): Teams inbox → tmux STDIN
- Gemini (local): tmux STDIN
- Moon Pilot (local): tmux STDIN (v1), ASP adapter (future)
- Any (remote): TCP push via server

### 10.4 Message Format

Messages delivered to agents are prefixed with sender identity:
```
[from: {agent_id}] {content}
```

Failure notifications:
```
[FAILED: {agent_id}] {content}
```

---

## 11. PR Workflow

### 11.1 Branch Naming Convention

`{parent_branch}.{slug}` with dot separator. PRs always target the parent branch, not main.
Merging follows a recursive fold up the tree: leaf → sub-TL → TL → main.

### 11.2 `file_pr`

1. Push current branch to remote
2. `gh pr create --base {parent_branch} --head {current_branch}`
3. If PR already exists, update it (push is sufficient)
4. Return PR URL

### 11.3 `merge_pr`

1. Auto-acquire mutex `branch:{parent_branch}` with a short TTL (default 120s)
2. `gh pr merge {number} --merge`
3. `git fetch` to update local refs
4. Release mutex `branch:{parent_branch}`

The auto-acquire serializes concurrent merges to the same parent branch without requiring
the TL to manage locks explicitly. The TL may also acquire the mutex manually beforehand
(e.g., to hold the lock across merge + rebase + merge sequences). If the auto-acquire finds
the TL already holds the lock, it is treated as idempotent and proceeds.

The mutex is released even on failure — a failed merge does not block subsequent agents.

### 11.4 Convergence Protocol

The orchestrator does not drive convergence. The loop is:

1. Leaf implements → commits → calls `file_pr`
2. Copilot reviews automatically on PR creation
3. GitHub poller detects review → injects comments into leaf's pane
4. Leaf addresses comments → pushes
5. Poller detects push after `ChangesRequested` → notifies parent `[FIXES PUSHED]`
6. Parent merges

The orchestrator's role is steps 3 and 5: detecting events and routing notifications.

---

## 12. GitHub Poller

### 12.1 Purpose

Background task in the server process that polls GitHub PR status and fires notifications
into agent panes. Runs as a cooperative async task alongside the transport listeners.

### 12.2 Tracked State Per PR

```
pr_number         : Int
agent_id          : String       -- owning agent
first_seen        : Timestamp
last_review_state : ReviewState  -- none | approved | changes_requested
last_sha          : CommitSha
notified_parent   : Bool
```

### 12.3 Events

| Event | Trigger | Action |
|-------|---------|--------|
| `ReviewReceived` | Copilot posts review comments | Inject comments into agent pane |
| `Approved` | Copilot approves PR | Notify parent `[PR READY]` |
| `FixesPushed` | New SHA after `ChangesRequested` | Notify parent `[FIXES PUSHED]` |
| `ReviewTimeout` | No review after 15min (5min after changes) | Notify parent `[REVIEW TIMEOUT]` |
| `CIFailed` | CI checks fail | Inject failure into agent pane |

### 12.4 Poll Interval

Configurable, default 30 seconds. Uses `gh api` to batch-query PR status for all tracked PRs.

---

## 13. KV Store

### 13.1 Purpose

Persistent key-value storage scoped to a swarm run. Agents can persist data across tool calls
and across context window boundaries. Useful for: task state, intermediate results, shared
coordination signals (e.g., "component X is claimed by agent Y").

### 13.2 Semantics

- **Scope**: per run_id. All agents in a swarm share one KV namespace.
- **Key format**: UTF-8 string, max 256 chars. Suggested convention: `{agent_id}/{key}` for
  private keys, `shared/{key}` for cross-agent coordination.
- **Value format**: JSON. No schema enforcement — agents define their own.
- **Persistence**: each key is stored as a separate file at `.exo/kv/{key}`. Survives server restart.
- **No TTL**: keys live until the run ends or are explicitly deleted.
- **No transactions**: last-writer-wins. Agents must coordinate externally if atomicity matters.

### 13.3 Storage

```
.exo/
└── kv/
    ├── shared/foo           # key "shared/foo"
    └── dev-1/state          # key "dev-1/state"
```

### 13.4 API

| Tool | Args | Returns |
|------|------|---------|
| `kv_get` | `key: String` | `{ value: JSON \| null }` |
| `kv_set` | `key: String, value: JSON` | `{ ok: true }` |
| `kv_delete` | `key: String` | `{ ok: true }` |
| `kv_list` | — | `{ keys: String[] }` — all keys in `.exo/kv/` |

---

## 14. Observability

### 13.1 Logging

Structured logging to stderr. Every log line includes:
- Timestamp
- Agent ID (if in agent context)
- Component name
- Message

### 13.2 OTel Integration

- Every tool call is a span with `agent_id`, `agent.role`, `agent.parent`, `swarm.run_id`
- `swarm.run_id` persisted to `.exo/run_id`, set as OTel resource attribute
- Propagated to children via `EXOMONAD_RUN_ID` env var
- Export to Grafana Tempo (optional, via OTLP)

### 13.3 Trace Queries

```bash
# All spans in a run
curl 'http://localhost:3200/api/search?q={resource.swarm.run_id="abc"}'

# Error spans for an agent
curl 'http://localhost:3200/api/search?q={span.agent_id="worker-1" && span:status=error}'
```

---

## 15. Failure Model

### 14.1 Failure Classes

| Class | Example | Recovery |
|-------|---------|----------|
| **Agent failure** | Process exits non-zero, pane dies | Notify parent with `[FAILED]`, parent re-decomposes |
| **Tool failure** | `gh pr create` fails, git conflict | Return structured error to agent, agent decides |
| **Server crash** | Binary segfaults, OOM | Fail-open: hooks return `continue: true`. Agents keep running. State recoverable on restart. |
| **Transport failure** | UDS deleted, TCP port in use | `mcp-stdio` returns MCP error. Agent retries or surfaces to user. |
| **Infrastructure failure** | GitHub API down, tmux dies | Log error, surface to agent. Do not retry silently. |

### 14.2 Recovery Principles

- **Fail loud, not silent.** Every failure is logged with enough context to debug without reproducing.
- **No automatic retries.** The orchestrator surfaces errors; agents or humans decide what to do.
- **Idempotent operations.** Workspace creation, PR creation, message delivery are all safe to retry.
- **State is recoverable.** On restart, reconstruct from filesystem + external state.

### 14.3 Server Restart Recovery

On restart, the server reconstructs in-memory state:
1. Scan `.exo/worktrees/` for active worktrees → rebuild agent registry
2. Scan tmux sessions for running agent panes → update alive status
3. Query `gh pr list` for open PRs → rebuild poller tracked state
4. Resume GitHub poller

Agents whose `mcp-stdio` lost the connection will reconnect on next tool call. The `mcp-stdio`
process stays alive (it's the MCP client's child), retries server connection, and resumes.

---

## 16. Security

### 15.1 Trust Boundary

The orchestrator runs on a developer's local machine. All agents are spawned by the developer
(or by the TL agent the developer launched). There is no multi-tenant isolation, no
authentication, no authorization beyond role-based tool gating.

### 15.2 Transport Security

- **UDS**: filesystem permissions. Socket owned by the user, mode 0600.
- **TCP**: bind to `127.0.0.1` by default. Binding to `0.0.0.0` is opt-in and documented
  as "for SSH tunneling, not open network exposure."
- **No TLS on local TCP.** If you need encrypted transport, use SSH tunneling.

### 15.3 Filesystem Safety

- Agents are confined to their worktree by convention, not enforcement
- The orchestrator never executes agent-provided code (it shells out to `git`, `gh`, `tmux`)
- Workspace paths are constructed from validated branch names, not raw user input

### 15.4 Secret Handling

- No secrets in config files. GitHub auth via `gh auth` (ambient credential).
- OTel endpoint is a URL, not a secret.
- Agent API keys managed by their respective CLIs (`~/.config/claude`, etc.), not by the
  orchestrator.

---

## 17. Reference Algorithms

### 16.1 Server Startup

```
fn main():
  config = load_config(".exo/config.toml")
  state = recover_state()  // reconstruct from filesystem if restarting

  // Bind transports
  uds_listener = bind_uds(config.listen_uds)
  tcp_listener = if config.listen_tcp: bind_tcp(config.listen_tcp) else None

  // Start background tasks
  spawn poller_loop(state)

  // Accept connections
  spawn accept_loop(uds_listener, state)
  if tcp_listener: spawn accept_loop(tcp_listener, state)

  wait_for_shutdown()
```

### 16.2 Spawn Agent (fork_wave / spawn_gemini)

```
fn spawn_agent(state: State, spec: SpawnSpec) -> Result[AgentId]:
  branch = "{parent_branch}.{spec.slug}"
  workspace = create_worktree(branch)
  write_config_local(workspace, spec.role)
  write_mcp_json(workspace, spec.role)
  tmux_target = create_tmux_target(spec.agent_type, workspace)
  launch_agent_process(tmux_target, spec.agent_type, spec.task)
  agent = Agent { id: branch, role: spec.role, ... }
  state.registry.insert(agent)
  return agent.id
```

### 16.3 Notify Parent

```
fn notify_parent(state: State, caller: AgentId, message: String, status: Status) -> Result[()]:
  parent = state.registry.get_parent(caller)?
  try:
    write_teams_inbox(parent, caller, message, status)
  catch:
    inject_tmux_stdin(parent.tmux_target, format_message(caller, message))
```

### 16.4 GitHub Poll Tick

```
fn poll_tick(state: State) -> List[Event]:
  events = []
  for (pr_num, pr_state) in state.tracked_prs:
    current = gh_pr_status(pr_num)
    if current.reviews != pr_state.last_review_state:
      match current.reviews:
        Approved => events.push(PRReady(pr_num))
        ChangesRequested =>
          events.push(ReviewReceived(pr_num, current.review_comments))
    if pr_state.last_review_state == ChangesRequested && current.sha != pr_state.last_sha:
      events.push(FixesPushed(pr_num))
    if now() - pr_state.first_seen > timeout && pr_state.last_review_state == None:
      events.push(ReviewTimeout(pr_num))
    state.update_pr(pr_num, current)
  return events
```

### 16.5 MCP Tool Dispatch

```
fn handle_request(state: State, req: Request) -> Response:
  tool = state.tool_registry.get(req.role, req.name)?
  validated_args = validate_schema(tool.schema, req.args)?
  result = tool.handler(state, validated_args)
  return Response { ok: true, result }
```

---

## 18. Test and Validation Matrix

### 17.1 Transport

- UDS listener accepts connections, dispatches requests
- TCP listener accepts connections when configured
- `mcp-stdio` translates JSON-RPC to internal wire format and back
- `mcp-stdio` returns MCP error when server is unreachable
- Hooks fail-open when server is unreachable

### 17.2 Tool Dispatch

- Tool call with valid args returns expected result
- Tool call with invalid args returns structured error
- Tool call for wrong role returns permission error
- Unknown tool name returns not-found error

### 17.3 Workspace Management

- Worktree creation produces valid git worktree at expected path
- Worktree cleanup removes directory and git worktree entry
- Branch naming follows `{parent}.{slug}` convention
- Concurrent worktree creation for different slugs succeeds

### 17.4 Message Routing

- `notify_parent` delivers via Teams inbox when available
- `notify_parent` falls back to tmux STDIN when Teams inbox fails
- `send_message` routes to correct agent by ID
- Message to nonexistent agent returns error

### 17.5 PR Workflow

- `file_pr` creates PR targeting parent branch
- `file_pr` on existing PR is idempotent (updates via push)
- `merge_pr` merges and updates local refs
- Branch naming convention produces correct PR base

### 17.6 Agent Lifecycle

- Spawned agent appears in registry with correct metadata
- Agent shutdown removes from registry and cleans up workspace
- Agent failure notifies parent with `[FAILED]` status
- Critical phase protection blocks premature shutdown

### 17.7 KV Store

- `kv_set` persists to `.exo/kv/{run_id}.json`
- `kv_get` on missing key returns `{ value: null }`
- `kv_delete` on missing key is idempotent, returns `{ ok: true }`
- KV state survives server restart

### 17.8 GitHub Poller

- Detects new review comments and injects into agent pane
- Detects approval and notifies parent
- Detects push after `ChangesRequested` and fires `FixesPushed`
- Fires timeout after configured interval with no review

### 17.9 Configuration

- `config.local.toml` role overrides `config.toml` default_role
- Missing config files use sane defaults
- Invalid config surfaces clear error message

### 17.10 Server Recovery

- Server restart reconstructs agent registry from filesystem
- Server restart resumes GitHub poller for open PRs
- `mcp-stdio` reconnects after server restart

### 17.11 Integration

- Full loop: spawn agent → agent works → files PR → Copilot reviews → notify parent → merge
- Multi-agent: spawn 3 parallel agents, all complete and merge without conflict
- Recovery: server restart mid-session, agents reconnect and resume

---

## 19. Implementation Checklist

### 19.1 Required for MVP

- [x] Server with UDS transport (`choir serve`)
- [x] MCP stdio translator (`choir mcp-stdio`)
- [x] Tool registry with role-based gating
- [x] `fork_wave` (Claude agent spawning)
- [x] `spawn_gemini` (Gemini agent spawning, worktree mode)
- [x] `spawn_worker` (ephemeral pane worker, any agent type, no branch)
- [x] `file_pr` and `merge_pr`
- [x] `notify_parent` with Teams inbox delivery + tmux fallback
- [x] `send_message`
- [x] In-memory agent registry
- [x] Workspace manager (git worktree + tmux)
- [x] Config file parsing (TOML, including `extra_mcp_servers`)
- [x] Hook protocol (session-start, pre-tool-use)
- [x] Structured logging

### 19.2 Required for Production

- [x] GitHub poller (background task in server)
- [x] Server restart recovery (reconstruct state from filesystem)
- [x] OTel span export (stderr JSON + OTLP HTTP to configurable endpoint)
- [x] `shutdown` with critical phase protection
- [x] Task list tools (`task_list`, `task_get`, `task_update`, `task_create`)
- [x] KV store (`kv_get`, `kv_set`, `kv_delete`, `kv_list`) persisted to `.exo/kv/`
- [x] Standalone isolation mode
- [x] Context inheritance (`fork_session`)
- [x] Mutex registry with FIFO queues and TTL (primary use case: `branch:{name}` locks for merge serialization)

### 19.3 Future Extensions

- [ ] TCP transport (for remote/SSH agents)
- [ ] Moon Pilot agent type
- [ ] ASP adapter for Moon Pilot messaging
- [ ] Remote workspace management (SSH, see Appendix A)
- [ ] GitHub REST client library (replace `gh` CLI subprocess calls with typed HTTP client)
- [ ] NotebookLM MCP integration (opt-in browser-automation MCP, configure via `extra_mcp_servers`)

---

## Appendix A: SSH Agent Extension

### A.1 Execution Model

Remote agents run on a different machine, reachable via SSH. The orchestrator spawns them by:

1. `ssh {target} "git clone {repo} && cd {repo} && git checkout -b {branch}"`
2. `ssh {target} "cd {repo} && gemini --mcp ..."` (or equivalent agent CLI)

The remote agent's `mcp-stdio` connects back to the server via TCP (SSH tunnel or direct).
The server treats remote agents identically to local agents in the registry — same tool
dispatch, same message routing — but delivery uses TCP push instead of tmux STDIN.

### A.2 Transport Requirements

- Server must listen on TCP (`listen_tcp` in config)
- SSH tunnel: `ssh -R 9100:localhost:9100 {target}` forwards server port to remote
- Remote `mcp-stdio` connects to `localhost:9100` (tunneled back to server)
- Alternative: direct TCP if machines are on the same network

### A.3 Workspace Differences

- No tmux management — remote agent runs in its own terminal/screen session
- No worktree — full `git clone` on the remote machine
- Cleanup is `ssh {target} "rm -rf {repo}"` or left to the user

### A.4 Message Delivery

- Teams inbox: not available (different filesystem)
- tmux STDIN: not available (different machine)
- TCP push: server sends message over the TCP connection to the remote agent's `mcp-stdio`,
  which injects it into the agent's stdin

This requires `mcp-stdio` to support bidirectional communication: it forwards tool calls
from the agent to the server, AND accepts pushed messages from the server to inject into
the agent. This is a multiplexing concern — JSON-RPC notifications from server to client.

### A.5 Open Problems

- **Authentication**: how does the server verify a remote `mcp-stdio` is who it claims to be?
  SSH tunnel sidesteps this (only local connections accepted). Direct TCP would need tokens.
- **Latency**: every tool call goes over the network. May need connection pooling or keepalive.
- **Failure detection**: local agents fail when their tmux pane dies. Remote agents need a
  heartbeat or timeout-based liveness check.
- **Git push race**: multiple remote agents pushing to the same remote repo may conflict.
  Same issue as local agents, but latency makes it worse.

### A.6 Phasing

SSH agents are a future extension. The transport abstraction (section 5) is designed to
support this without architectural changes — add a TCP listener, update `mcp-stdio` to
support server-initiated messages, update workspace manager with an SSH backend.
Do not build this until local orchestration is solid.
