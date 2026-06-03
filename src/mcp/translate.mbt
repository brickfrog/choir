///|
struct SchemaProp {
  name : String
  desc : String
} derive(Debug, Eq)

///|
struct CatalogTool {
  name : String
  description : String
  props : Array[SchemaProp]
  required : Array[String]
} derive(Debug, Eq)

///|
fn schema_prop_json(prop : SchemaProp) -> Json {
  let m : Map[String, Json] = {
    "type": "string".to_json(),
    "description": prop.desc.to_json(),
  }
  m.to_json()
}

///|
fn schema_json(props : Array[SchemaProp], required : Array[String]) -> Json {
  let properties : Map[String, Json] = {}
  for prop in props {
    properties.set(prop.name, schema_prop_json(prop))
  }
  let req_arr : Array[Json] = required.map(fn(s) { s.to_json() })
  let m : Map[String, Json] = {
    "type": "object".to_json(),
    "properties": properties.to_json(),
    "required": req_arr.to_json(),
  }
  m.to_json()
}

///|
fn tool_json(tool : CatalogTool) -> Json {
  let m : Map[String, Json] = {
    "name": tool.name.to_json(),
    "description": tool.description.to_json(),
    "inputSchema": schema_json(tool.props, tool.required),
  }
  m.to_json()
}

///|
test "fork_wave schema exposes per leaf task contracts without requiring shared task or count" {
  let mut fork_wave : CatalogTool? = None
  for def in tool_defs() {
    if def.name == "fork_wave" {
      fork_wave = Some(def)
      break
    }
  }
  match fork_wave {
    Some(def) => {
      let mut has_task_contracts = false
      for prop in def.props {
        if prop.name == "task_contracts" {
          has_task_contracts = true
          assert_true(
            prop.desc.contains("JSON array of per-leaf TaskContract overrides"),
          )
          assert_true(prop.desc.contains("beads_issue_id"))
          assert_true(prop.desc.contains("Omit to inherit"))
        }
      }
      assert_true(has_task_contracts)
      assert_false(def.required.contains("task"))
      assert_false(def.required.contains("count"))
    }
    None => fail("expected fork_wave tool definition")
  }
}

///|
fn text_content_json(text : String) -> Json {
  let entry : Map[String, Json] = {
    "type": "text".to_json(),
    "text": text.to_json(),
  }
  [entry.to_json()].to_json()
}

///|
/// Translate an MCP JSON-RPC tools/call request to an internal Request.
pub fn to_internal_request(
  rpc : JsonRpcRequest,
  role : @types.Role,
  default_caller_id? : String? = None,
) -> Result[@types.Request, JsonRpcError] {
  if rpc.req_method != method_tools_call {
    return Err({
      code: err_method_not_found,
      message: "unsupported method: " + rpc.req_method,
    })
  }
  let params : Map[String, Json] = match rpc.params {
    Some(Object(p)) => p
    _ => {}
  }
  let name = match params.get("name") {
    Some(String(n)) => n
    None =>
      return Err({
        code: err_invalid_params,
        message: "missing 'name' in params",
      })
    Some(_) =>
      return Err({
        code: err_invalid_params,
        message: "invalid 'name' in params",
      })
  }
  let args_json : Map[String, Json] = match params.get("arguments") {
    Some(Object(obj)) => obj
    Some(String(json_str)) => {
      // Legacy: arguments passed as a JSON string
      let flat = parse_flat_json_object(json_str)
      let converted : Map[String, Json] = {}
      flat.each(fn(k, v) { converted.set(k, v.to_json()) })
      converted
    }
    _ => {}
  }
  // Always set caller_id from connection identity -- agents cannot self-identify
  match default_caller_id {
    Some(id) => args_json.set("caller_id", id.to_json())
    None => ()
  }
  Ok({
    req_method: rpc.req_method,
    role,
    name,
    args: @types.RequestArgs::from_values(args_json),
  })
}

///|
/// Create a JSON-RPC response for the MCP initialize handshake.
fn choir_mcp_instructions() -> String {
  (
    #|Choir is an agent orchestration server. You are the Team Lead (TL). Delegate all implementation to leaf agents via fork_wave (default codex; set agent_type for claude, moon_pilot, gemini, or cursor_agent). Never edit files directly -- read code to understand it, then delegate. If the user explicitly asks for work to be done via leaves/waves/agents, do not implement the feature directly on the parent branch. The parent branch is only for pre-fork scaffold, integrating completed leaf work, or cleaning up stale leaves/PRs. If a parent-branch change or user decision supersedes a leaf, kill that leaf immediately and close or abandon its PR before continuing. For distinct subtasks, pass a tasks array to fork_wave (one string per leaf). For identical parallel work, pass task + count. spawn_worker defaults to read-only research/review in the root checkout; only type=review isolation=worktree parent_branch=<branch> may run write-capable mutation-testing review in an isolated review worktree. Workers do not own a branch or PR. After spawning leaves, stop and wait for notify_parent messages. Do not poll with sleep or git log. Use merge_pr to merge PRs, not git merge. Merge one at a time. If merge_pr returns a policy block, address the block (resolve threads, wait for CI, fix the verify gate, etc.) -- DO NOT bypass it with raw `gh pr merge`; the shim blocks that anyway. If you believe the gate itself is wrong, surface the bug to the user and fix the gate; never route around it. Call `wave_state` to read per-leaf PR/review/CI state; do not track merge/review status from notification prose. If you spawned a wave with automerge enabled, do not manually call merge_pr just because you saw [MERGE READY] — wait for [PR MERGED] unless the server reports an error or the user asks you to intervene. Only state merged after merge_pr returns success in this session (in turn) or you have directly verified the PR is merged (for example on GitHub). The server sends [PR MERGED] to your pane after merge_pr succeeds — treat that as the orchestration-level merge signal.
    #|
    #|When given an implementation task, before calling any tools, reason through:
    #|1. Boundaries — what are the independent units of work? Each leaf should own a complete vertical slice (types + logic + tests) with no runtime coupling to other leaves' changes.
    #|2. Interfaces — if leaves touch shared code, what are the contracts? Define shared types, function signatures, or module boundaries as scaffold before forking. Two leaves should never need to coordinate on a type definition.
    #|3. Entanglement check — will merging leaf A's PR create conflicts with leaf B's? If yes, they're not independent — either sequence them (wave 1 then wave 2) or merge them into one leaf.
    #|4. Size — single leaf (self-contained, one area) or wave (2+ independent subtasks)?
    #|5. Agent types — codex (default leaf), cursor_agent (refactor/file navigation), gemini (bulk implementation when explicitly requested), claude (complex reasoning/architecture), spawn_worker (no branch, runs in parent workspace).
    #|6. Scaffold — commit shared types, interfaces, or test infra to the parent branch before forking. Every leaf should inherit a compilable, complete interface contract.
    #|7. Integration branch — every wave forks off an integration branch named `feature/<wave-slug>`, NOT directly off main. Even 2-3 leaf waves. Create the branch first with `git checkout -b feature/<slug> main && git push -u origin feature/<slug>`, then pass `parent_branch="feature/<slug>"` to fork_wave. Leaves PR into the integration branch; the integration branch is what PRs into main as one merge commit. This is non-optional: a wave that lands as N separate merges on main is a regression. Skipping this for "small" waves is exactly how regressions ship.
    #|8. Audit context — when a wave is closing audit findings (Sarcasmotron output or `.choir/audit-receipts/<sha>.json`), the task contract MUST include the receipt path and the specific finding text. Each leaf MUST cite the audit reference in the PR description body, not just the commit message. A PR titled "fix: signal handler async-signal-safe" with no audit citation is uncontextualized and a future reader cannot grep for why. Format: `Closes audit finding N from .choir/audit-receipts/<sha>.json (PR #<orig>): <one-line finding text>`. Verify the leaf's PR body contains this before merging — if missing, request changes and require the leaf to amend the PR body.
    #|After merging all PRs in a wave (into the integration branch), spawn a worker to run the full test suite on your branch before opening the integration PR into main.
    #|Then state your plan in 2-4 lines and execute immediately. Do not ask for approval unless the task is genuinely ambiguous.
    #|
    #|You have a winner's mentality. When an approach has failed ~7 times in a row, you find this unacceptable and demand more of yourself — actively searching for something to change. Not the same retry with a tweak, an actual axis-of-attack swap. Foreground → background. Polling → event. Patch → redesign. Local fix → upstream fix. Code edit → bead. You name the failure count out loud so the pivot is visible; by attempt 7 the approach is dead, not "almost working." This is how you never get stuck for long. If someone asks whether you have a winner's mentality, the answer is yes — it is part of how you operate, not an aspirational label.
  )
}

///|
pub fn initialize_response(id : JsonRpcId) -> JsonRpcResponse {
  let empty_obj : Map[String, Json] = {}
  let capabilities : Map[String, Json] = { "tools": empty_obj.to_json() }
  let server_info : Map[String, Json] = {
    "name": "choir".to_json(),
    "version": "1.0.0".to_json(),
  }
  let result : Map[String, Json] = {
    "protocolVersion": "2024-11-05".to_json(),
    "capabilities": capabilities.to_json(),
    "serverInfo": server_info.to_json(),
    "instructions": choir_mcp_instructions().to_json(),
  }
  { jsonrpc: "2.0", id, result: Some(result.to_json()), error: None }
}

///|
fn spawn_worker_props() -> Array[SchemaProp] {
  [
    { name: "task", desc: "Primary task for the worker agent" },
    { name: "prompt", desc: "Optional full prompt override" },
    { name: "slug", desc: "Worker slug (default inline-worker)" },
    { name: "agent_id", desc: "Compatibility alias for slug" },
    {
      name: "agent_type",
      desc: "Worker agent type: codex (default), claude, moon_pilot, gemini, or cursor_agent",
    },
    {
      name: "beads_issue_id",
      desc: "Beads issue ID to pass through the task contract",
    },
    { name: "type", desc: "Worker profile: research or review" },
    {
      name: "isolation",
      desc: "Optional opt-in isolation mode for write-capable review workers: worktree",
    },
    {
      name: "parent_branch",
      desc: "Required explicit branch/ref when isolation=worktree",
    },
    { name: "read_first", desc: "Newline-separated paths to read first" },
    { name: "steps", desc: "Newline-separated implementation steps" },
    { name: "verify", desc: "Newline-separated verification commands" },
    {
      name: "verify_satisfied_by_ci",
      desc: "Optional boolean: green CI on the merge HEAD satisfies required verify commands (default true)",
    },
    { name: "done_criteria", desc: "Newline-separated acceptance criteria" },
    {
      name: "boundary",
      desc: "Newline-separated things the worker must not do",
    },
    { name: "constraints", desc: "Newline-separated extra constraints" },
    { name: "context", desc: "Context or reasoning summary for the worker" },
    {
      name: "key_decisions",
      desc: "Newline-separated decisions that are already fixed",
    },
    { name: "non_goals", desc: "Newline-separated non-goals" },
  ]
}

///|
fn tool_defs() -> Array[CatalogTool] {
  [
    {
      name: "fork_wave",
      description: "Spawn agents in new worktrees (default dev leaves; optional role=tl for a sub-team-lead). For distinct tasks, pass a tasks array (one entry per leaf, count is inferred). For identical tasks, pass task + count. Optional automerge, review_mode, and merge_strategy override server defaults for that wave.",
      props: [
        { name: "task", desc: "Shared task for all leaves (use with count)" },
        {
          name: "tasks",
          desc: "JSON array of per-leaf task strings -- each leaf gets exactly one. Count is inferred from array length. Mutually exclusive with task+count",
        },
        {
          name: "agent_type",
          desc: "Agent type: codex (default), claude, moon_pilot, gemini, or cursor_agent",
        },
        {
          name: "beads_issue_id",
          desc: "Beads issue ID to pass through each leaf task contract",
        },
        {
          name: "task_contracts",
          desc: "Optional JSON array of per-leaf TaskContract overrides; each entry is an object whose fields override the wave-level base contract for that one leaf (omitted fields inherit). Recognized fields: beads_issue_id, goal, scope (array), acceptance_checks (array), done_criteria (array), constraints (array), non_goals (array), verify (array), verify_satisfied_by_ci, review_context. When provided, length must equal tasks-array length / count. Omit to inherit the base contract for every leaf. Primary use: give each leaf in a multi-bead wave its own Beads issue so the TDD verify gate resolves per-leaf.",
        },
        {
          name: "role",
          desc: "Spawned child role: dev (default) or tl (sub-TL; nesting limited to one level below root TL)",
        },
        {
          name: "parent_branch",
          desc: "Parent branch for spawned children (default main)",
        },
        { name: "branch", desc: "Compatibility alias for parent_branch" },
        { name: "count", desc: "Number of leaves when using shared task" },
        {
          name: "slug_prefix",
          desc: "Slug prefix for spawned children. Accepts '/' so hierarchical names like 'feature/foo' are valid input, but '/' is flattened to '-' when deriving wave_id and filesystem-side keys (e.g. .choir/kv/pending-wave--<id>) — storage stays flat. Child branch names still use the raw form via parent_branch concatenation.",
        },
        {
          name: "automerge",
          desc: "Optional per-wave override for server-triggered merge_pr after merge policy reaches MergeNow; omitted inherits config default (default config is false)",
        },
        {
          name: "review_mode",
          desc: "Optional per-wave override for review behavior after fixes are pushed: single_pass or iterative; omitted inherits the server config default",
        },
        {
          name: "merge_strategy",
          desc: "Optional per-wave override for gh pr merge strategy: merge, squash, or rebase; omitted inherits the server config default",
        },
        { name: "read_first", desc: "Newline-separated paths to read first" },
        { name: "steps", desc: "Newline-separated implementation steps" },
        { name: "verify", desc: "Newline-separated verification commands" },
        {
          name: "verify_satisfied_by_ci",
          desc: "Optional boolean: green CI on the merge HEAD satisfies required verify commands (default true)",
        },
        { name: "done_criteria", desc: "Newline-separated acceptance criteria" },
        {
          name: "boundary",
          desc: "Newline-separated things children must not do",
        },
        { name: "constraints", desc: "Newline-separated extra constraints" },
        { name: "context", desc: "Context or reasoning summary for the wave" },
        {
          name: "key_decisions",
          desc: "Newline-separated decisions that are already fixed",
        },
        { name: "non_goals", desc: "Newline-separated non-goals" },
      ],
      required: [],
    },
    {
      name: "spawn_gemini",
      description: "Spawn a single Gemini leaf agent in a worktree",
      props: [
        { name: "task", desc: "Task for the agent" },
        { name: "slug", desc: "Agent slug (auto-derived if omitted)" },
        { name: "parent_branch", desc: "Parent branch (default main)" },
        { name: "caller_id", desc: "ID of the caller" },
      ],
      required: ["task"],
    },
    {
      name: "spawn_worker",
      description: "Spawn a read-only research/review worker in the root checkout by default. For write-capable mutation-testing review, pass type=review isolation=worktree parent_branch=<branch>",
      props: spawn_worker_props(),
      required: ["task"],
    },
    {
      name: "file_pr",
      description: "Push the branch, create or resolve its PR, and auto-track it for review events",
      props: [
        { name: "branch", desc: "Branch to file a PR for" },
        {
          name: "agent_id",
          desc: "Compatibility alias for branch and tracked agent id",
        },
        {
          name: "parent_branch",
          desc: "Parent branch to target (default main)",
        },
        { name: "caller_id", desc: "Optional tracked agent id override" },
        { name: "title", desc: "PR title (default: branch slug)" },
        { name: "body", desc: "PR description body" },
      ],
      required: [],
    },
    {
      name: "tdd_intent",
      description: "Declare the leaf's TDD intent before writing the failing test or artifact. The server pins red/green checks to the task contract verify command; file_pr refuses until the leaf reaches Done.",
      props: [
        { name: "caller_id", desc: "ID of the calling leaf" },
        { name: "intent", desc: "Short description of the behavior under test" },
        {
          name: "test_command",
          desc: "Optional compatibility field. If supplied, it must match the configured verify command.",
        },
        {
          name: "artifact_path",
          desc: "Optional non-code artifact path. If supplied, it must be a relative path mentioned by the configured verify command, e.g. test -f <path> && <verify>.",
        },
      ],
      required: ["caller_id", "intent"],
    },
    {
      name: "tdd_red_check",
      description: "Advance Intent to Red only when the configured task-contract verify command fails.",
      props: [
        { name: "caller_id", desc: "ID of the calling leaf" },
        {
          name: "exit_code",
          desc: "Observed test exit code; Red requires a non-zero value",
        },
      ],
      required: ["caller_id", "exit_code"],
    },
    {
      name: "tdd_green_check",
      description: "Advance Red to Green, Green to Done or Refactor, and Refactor to Done only when the configured task-contract verify command passes.",
      props: [
        { name: "caller_id", desc: "ID of the calling leaf" },
        {
          name: "exit_code",
          desc: "Observed test exit code; Green/Done requires zero",
        },
        {
          name: "next_phase",
          desc: "Optional target phase: green, refactor, or done. Defaults to green from Red and done from Green/Refactor",
        },
      ],
      required: ["caller_id", "exit_code"],
    },
    {
      name: "merge_pr",
      description: "Merge a pull request by number",
      props: [
        { name: "pr_number", desc: "Pull request number to merge" },
        { name: "parent_branch", desc: "Branch to merge into" },
      ],
      required: ["pr_number", "parent_branch"],
    },
    {
      name: "track_pr",
      description: "Track a pull request in the background poller",
      props: [
        { name: "pr_number", desc: "Pull request number to track" },
        { name: "agent_id", desc: "Agent ID that owns the PR" },
        {
          name: "branch",
          desc: "Owning branch for the PR (defaults to agent_id)",
        },
        {
          name: "parent_branch",
          desc: "Parent branch / PR base (derived when omitted)",
        },
        { name: "pr_url", desc: "Pull request URL when known" },
      ],
      required: ["pr_number", "agent_id"],
    },
    {
      name: "notify_parent",
      description: "Notify the parent agent. Each call wakes the parent at full context cost. Use only for blockers, failures, or review-complete. file_pr auto-notifies — do not duplicate.",
      props: [
        { name: "caller_id", desc: "ID of the calling agent" },
        { name: "message", desc: "Message to send to parent" },
      ],
      required: ["caller_id", "message"],
    },
    {
      name: "report_usage",
      description: "Self-report token/cost usage for the caller's wave. No-ops when the caller has no wave_id.",
      props: [
        { name: "caller_id", desc: "ID of the calling agent" },
        { name: "tokens_in", desc: "Input token count" },
        { name: "tokens_out", desc: "Output token count" },
        { name: "elapsed_s", desc: "Elapsed wall-clock seconds" },
        { name: "cost_usd", desc: "Optional computed cost in USD" },
      ],
      required: ["caller_id", "tokens_in", "tokens_out", "elapsed_s"],
    },
    {
      name: "wave_state",
      description: "Return a typed per-child snapshot (supervisor + leaves + workers) with each tracked PR's review state, CI rollup, unresolved thread count, and server-computed merge_gate_ready. Use instead of inferring merge/review status from notification prose. Root/TL only.",
      props: [{ name: "caller_id", desc: "ID of the calling supervisor" }],
      required: ["caller_id"],
    },
    {
      name: "status_bar_state",
      description: "Return a schema-versioned per-pane status snapshot for status bar polling",
      props: [],
      required: [],
    },
    {
      name: "crystallize_spec",
      description: "Scaffold a canonical eight-section spec template (Context, Clarifications, Goals, Non-Goals, Design, Verify, Boundary, Follow-Ups) at .choir/context/<feature_slug>-spec.md. Refuses if the spec file already exists.",
      props: [
        {
          name: "feature_slug",
          desc: "Kebab-case slug. The spec file is written to .choir/context/<feature_slug>-spec.md",
        },
        { name: "caller_id", desc: "ID of the calling supervisor" },
      ],
      required: ["feature_slug", "caller_id"],
    },
    {
      name: "write_audit_receipt",
      description: "Write a typed audit receipt for the audited HEAD. The tool fills audited_at from server time and agent_id from caller_id.",
      props: [
        { name: "sha", desc: "Full audited HEAD sha" },
        {
          name: "tree_sha",
          desc: "Full audited HEAD tree sha (`git rev-parse HEAD^{tree}`)",
        },
        { name: "branch", desc: "Branch audited" },
        {
          name: "findings_count",
          desc: "Number of findings reported by the audit worker, as a base-10 integer",
        },
        { name: "caller_id", desc: "ID of the calling agent" },
      ],
      required: ["sha", "tree_sha", "branch", "findings_count", "caller_id"],
    },
    {
      name: "send_message",
      description: "Send a message to another agent",
      props: [
        { name: "target_id", desc: "ID of the target agent" },
        { name: "message", desc: "Message content to send" },
      ],
      required: ["target_id", "message"],
    },
    {
      name: "kv_get",
      description: "Read one value from shared KV storage (flat key, no '/')",
      props: [
        {
          name: "key",
          desc: "Flat storage key (no '/' — single segment under .choir/kv)",
        },
      ],
      required: ["key"],
    },
    {
      name: "kv_set",
      description: "Write one value to shared KV storage (flat key, no '/')",
      props: [
        {
          name: "key",
          desc: "Flat storage key (no '/' — single segment under .choir/kv)",
        },
        { name: "value", desc: "Value to store" },
      ],
      required: ["key", "value"],
    },
    {
      name: "kv_delete",
      description: "Delete one value from shared KV storage (flat key, no '/')",
      props: [
        {
          name: "key",
          desc: "Flat storage key (no '/' — single segment under .choir/kv)",
        },
      ],
      required: ["key"],
    },
    {
      name: "mutex_acquire",
      description: "Acquire an in-memory coordination mutex",
      props: [
        { name: "name", desc: "Mutex name" },
        { name: "agent_id", desc: "ID of the acquiring agent" },
        { name: "ttl_sec", desc: "Optional TTL in seconds" },
      ],
      required: ["name", "agent_id"],
    },
    {
      name: "mutex_release",
      description: "Release an in-memory coordination mutex",
      props: [
        { name: "name", desc: "Mutex name" },
        { name: "agent_id", desc: "ID of the releasing agent" },
      ],
      required: ["name", "agent_id"],
    },
    {
      name: "mutex_status",
      description: "Inspect an in-memory coordination mutex",
      props: [{ name: "name", desc: "Mutex name to inspect" }],
      required: ["name"],
    },
    {
      name: "task_list",
      description: "List Beads-backed shared tasks",
      props: [],
      required: [],
    },
    {
      name: "task_get",
      description: "Get one Beads-backed shared task",
      props: [{ name: "id", desc: "Beads issue ID / task slug" }],
      required: ["id"],
    },
    {
      name: "task_create",
      description: "Create one Beads-backed shared task",
      props: [
        { name: "id", desc: "Beads issue ID / task slug" },
        { name: "title", desc: "Task title" },
        { name: "status", desc: "Optional status: todo, in_progress, done" },
        { name: "assignee", desc: "Optional assignee" },
        { name: "notes", desc: "Optional task notes" },
      ],
      required: ["id", "title"],
    },
    {
      name: "task_update",
      description: "Update one Beads-backed shared task",
      props: [
        { name: "id", desc: "Beads issue ID / task slug" },
        { name: "status", desc: "Updated status: todo, in_progress, done" },
        { name: "assignee", desc: "Updated assignee" },
        { name: "notes", desc: "Updated task notes" },
      ],
      required: ["id"],
    },
    {
      name: "kv_list",
      description: "List keys in shared KV storage",
      props: [{ name: "prefix", desc: "Optional key prefix filter" }],
      required: [],
    },
    {
      name: "goal_set",
      description: "Set or supersede the active TL goal for this session",
      props: [
        {
          name: "input",
          desc: "Goal source: generated Beads issue ID (for example choir-kqv or choir-7uc.1) or freeform text",
        },
        {
          name: "verify",
          desc: "Optional JSON array or newline-separated shell commands; exit 0 means the check passes",
        },
      ],
      required: ["input"],
    },
    {
      name: "goal_clear",
      description: "Clear the active TL goal for this session",
      props: [],
      required: [],
    },
    {
      name: "goal_status",
      description: "Inspect the active TL goal for this session",
      props: [
        {
          name: "evaluate",
          desc: "When true, run the goal's checks now and return the fresh result (read-only — only the goal judge persists last_eval, not this call)",
        },
      ],
      required: [],
    },
    {
      name: "fork_session",
      description: "Create a new named session directory",
      props: [{ name: "name", desc: "Session name (slug)" }],
      required: ["name"],
    },
    {
      name: "spawn_remote",
      description: "Spawn a remote agent via SSH",
      props: [
        { name: "ssh_target", desc: "SSH host to connect to" },
        { name: "repo_url", desc: "Git repo URL to clone" },
        { name: "tcp_addr", desc: "TCP address for reverse connection" },
        { name: "task", desc: "Task for the remote agent" },
        { name: "slug", desc: "Agent slug (default remote-leaf)" },
        { name: "parent_branch", desc: "Parent branch (default main)" },
      ],
      required: ["ssh_target", "repo_url", "tcp_addr"],
    },
    {
      name: "shutdown",
      description: "Shutdown the server",
      props: [
        {
          name: "caller_id",
          desc: "Optional calling agent id for best-effort shutdown",
        },
      ],
      required: [],
    },
    {
      name: "kill_agent",
      description: "Kill a child agent — closes its pane and cleans up. Use when an agent is stuck or its work is done",
      props: [
        { name: "agent_id", desc: "Agent ID to kill" },
        {
          name: "reason",
          desc: "Reason for killing (default: killed by parent)",
        },
      ],
      required: ["agent_id"],
    },
    {
      name: "resolve_my_review_threads",
      description: "Resolve all currently tracked unresolved GitHub review threads for the caller's PR(s) via the Choir server credentials",
      props: [
        {
          name: "caller_id",
          desc: "Agent ID whose tracked PR review threads should be resolved",
        },
        {
          name: "pr_number",
          desc: "Optional tracked pull request number; Root/TL callers may target any tracked PR",
        },
      ],
      required: ["caller_id"],
    },
    {
      name: "request_review",
      description: "Request a GitHub reviewer on a PR via the Choir server credentials",
      props: [
        { name: "pr_number", desc: "Pull request number" },
        {
          name: "reviewer",
          desc: "Reviewer login or handle, for example @copilot",
        },
      ],
      required: ["pr_number", "reviewer"],
    },
    {
      name: "server_reload",
      description: "Persist server runtime state and re-exec choir-serve in place using the freshly built binary. Active tool calls in flight at re-exec time may be dropped; retry after the new process resumes.",
      props: [
        {
          name: "binary_path",
          desc: "Optional absolute path to the choir binary to exec into. Defaults to the project's release build under _build/native/release.",
        },
      ],
      required: [],
    },
  ]
}

///|
/// Create a JSON-RPC response with the list of available tools.
pub fn tools_list_response(
  id : JsonRpcId,
  role : @types.Role,
) -> JsonRpcResponse {
  let registry = @tools.ToolRegistry::new()
  let defs = tool_defs().filter(fn(def) {
    try {
      ignore(registry.lookup(role, def.name))
      true
    } catch {
      _ => false
    }
  })
  let tools_arr : Array[Json] = defs.map(fn(d) { tool_json(d) })
  let result : Map[String, Json] = { "tools": tools_arr.to_json() }
  { jsonrpc: "2.0", id, result: Some(result.to_json()), error: None }
}

///|
/// Translate an internal Response to a JSON-RPC response.
pub fn from_internal_response(
  id : JsonRpcId,
  resp : @types.Response,
) -> JsonRpcResponse {
  match resp.ok_payload() {
    Some(data) => {
      let payload : Map[String, Json] = {}
      data.each_json(fn(k, v) { payload.set(k, v) })
      let text = payload.to_json().stringify()
      let content = text_content_json(text)
      let result : Map[String, Json] = {
        "content": content,
        "structuredContent": payload.to_json(),
        "isError": false.to_json(),
      }
      { jsonrpc: "2.0", id, result: Some(result.to_json()), error: None }
    }
    None => {
      let msg = match resp.error_message() {
        Some(v) => v
        None => ""
      }
      let content = text_content_json(msg)
      let structured : Map[String, Json] = { "error": msg.to_json() }
      let result : Map[String, Json] = {
        "content": content,
        "structuredContent": structured.to_json(),
        "isError": true.to_json(),
      }
      { jsonrpc: "2.0", id, result: Some(result.to_json()), error: None }
    }
  }
}

///|
/// Create a JSON-RPC error response.
pub fn error_response(
  id : JsonRpcId,
  code : Int,
  message : String,
) -> JsonRpcResponse {
  { jsonrpc: "2.0", id, result: None, error: Some({ code, message }) }
}
