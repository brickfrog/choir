///|
pub(all) struct Command {
  program : String
  args : Array[String]
  workdir : String?
} derive(Show, Eq)

///|
pub fn Command::to_string(self : Command) -> String {
  let mut args_str = ""
  for arg in self.args {
    let quoted = @sys.shell_quote(arg)
    if args_str == "" {
      args_str = quoted
    } else {
      args_str = args_str + " " + quoted
    }
  }
  let base = if args_str == "" {
    self.program
  } else {
    self.program + " " + args_str
  }
  match self.workdir {
    None => base
    Some(dir) => "cd " + @sys.shell_quote(dir) + " && " + base
  }
}

///|
/// Write .choir/config.local.toml into worktree with role override.
/// Uses positional shell args to safely handle paths with spaces.
pub fn write_local_config(worktree_path : String, content : String) -> Command {
  {
    program: "sh",
    args: [
      "-c", "mkdir -p \"$1/.choir\" && printf '%s' \"$2\" > \"$1/.choir/config.local.toml\"",
      "sh", worktree_path, content,
    ],
    workdir: None,
  }
}

///|
/// Write .choir/config.toml into worktree with client connection settings.
pub fn write_spawn_config(worktree_path : String, content : String) -> Command {
  {
    program: "sh",
    args: [
      "-c", "mkdir -p \"$1/.choir\" && printf '%s' \"$2\" > \"$1/.choir/config.toml\"",
      "sh", worktree_path, content,
    ],
    workdir: None,
  }
}

///|
/// Install shell helpers for CLIs that do not load MCP tools directly.
pub fn write_leaf_helper_scripts(worktree_path : String) -> Command {
  {
    program: "sh",
    args: [
      "-c",
      "mkdir -p \"$1/.choir/bin\" && " +
      "cat > \"$1/.choir/bin/choir-leaf-tool\" <<'EOF'\n" +
      "#!/bin/sh\n" +
      "tool=\"${0##*/}\"\n" +
      "exec choir leaf-tool \"$tool\" \"$@\"\n" +
      "EOF\n" +
      "chmod +x \"$1/.choir/bin/choir-leaf-tool\" && " +
      "for name in file_pr notify_parent shutdown task_list task_get task_create task_update; do " +
      "ln -sf choir-leaf-tool \"$1/.choir/bin/$name\"; " +
      "done",
      "sh",
      worktree_path,
    ],
    workdir: None,
  }
}

///|
pub fn trust_gemini_folder(worktree_path : String) -> Command {
  {
    program: "choir",
    args: ["trust-gemini-folder", worktree_path],
    workdir: None,
  }
}

///|
/// Generate Gemini CLI settings.json content with MCP server config, hooks,
/// and optional context files.
pub fn gemini_settings_json(
  agent_name : String,
  role : String,
  context_paths? : Array[String] = [],
  wasm_hooks_path? : String? = None,
) -> String {
  let mcp = {
    "choir": {
      "type": "stdio".to_json(),
      "command": "choir".to_json(),
      "args": ["mcp-stdio", "--role", role, "--name", agent_name].to_json(),
    }.to_json(),
  }
  let hook_entry = {
    "matcher": "*".to_json(),
    "hooks": [
      {
        "type": "command".to_json(),
        "command": "choir hook worker-exit --runtime gemini".to_json(),
      }.to_json(),
    ].to_json(),
  }
  let hooks_obj : Map[String, Json] = {
    "AfterAgent": [hook_entry.to_json()].to_json(),
  }
  match wasm_hooks_path {
    Some(path) => {
      let model_hook = fn(func_name : String) -> Json {
        {
          "matcher": "*".to_json(),
          "hooks": [
            {
              "type": "command".to_json(),
              "command": ("extism call " + path + " " + func_name + " --wasi").to_json(),
            }.to_json(),
          ].to_json(),
        }.to_json()
      }
      hooks_obj.set("BeforeModel", [model_hook("before_model")].to_json())
      hooks_obj.set("AfterModel", [model_hook("after_model")].to_json())
    }
    None => ()
  }
  let settings : Map[String, Json] = {
    "mcpServers": mcp.to_json(),
    "hooks": hooks_obj.to_json(),
  }
  if context_paths.length() > 0 {
    let files : Array[Json] = []
    for path in context_paths {
      files.push(path.to_json())
    }
    settings.set("context", { "fileName": files.to_json() }.to_json())
  }
  settings.to_json().stringify(indent=2)
}

///|
fn resolve_named_context_path(project_dir : String, name : String) -> String? {
  let local_path = project_dir + "/.choir/context/" + name + ".md"
  if @sys.read_file(local_path) != "" {
    return Some(
      if local_path.has_prefix("/") {
        local_path
      } else {
        @env.current_dir().unwrap_or(".") + "/" + local_path
      },
    )
  }
  let home = @sys.getenv("HOME").unwrap_or("")
  if home != "" {
    let global = home + "/.choir/context/" + name + ".md"
    if @sys.read_file(global) != "" {
      return Some(global)
    }
  }
  None
}

///|
/// Resolve hidden Choir-owned context files with two-tier fallback.
/// For each name, checks project-local `.choir/context/{name}.md` first,
/// then global `~/.choir/context/{name}.md`.
pub fn resolve_context_paths(
  project_dir : String,
  role : String,
) -> Array[String] {
  let paths : Array[String] = []
  for name in ["common", role] {
    match resolve_named_context_path(project_dir, name) {
      Some(path) => if !paths.contains(path) { paths.push(path) }
      None => ()
    }
  }
  paths
}

///|
/// Write .choir/gemini-settings.json in the workspace for Gemini agents.
pub fn write_gemini_settings(
  worktree_path : String,
  agent_name : String,
  role : String,
  context_paths? : Array[String] = [],
  wasm_hooks_path? : String? = None,
) -> Command {
  let content = gemini_settings_json(
    agent_name,
    role,
    context_paths~,
    wasm_hooks_path~,
  )
  {
    program: "sh",
    args: [
      "-c", "mkdir -p \"$1/.choir\" && printf '%s' \"$2\" > \"$1/.choir/gemini-settings.json\"",
      "sh", worktree_path, content,
    ],
    workdir: None,
  }
}

///|
/// Generate .cursor/mcp.json content for Cursor Agent worktrees.
pub fn cursor_mcp_json(agent_name : String, role : String) -> String {
  let mcp = {
    "choir": {
      "command": "choir".to_json(),
      "args": ["mcp-stdio", "--role", role, "--name", agent_name].to_json(),
      "type": "stdio".to_json(),
    }.to_json(),
  }
  let settings : Map[String, Json] = { "mcpServers": mcp.to_json() }
  settings.to_json().stringify(indent=2)
}

///|
/// Write .cursor/mcp.json in the workspace for Cursor Agent.
pub fn write_cursor_mcp_json(
  worktree_path : String,
  agent_name : String,
  role : String,
) -> Command {
  let content = cursor_mcp_json(agent_name, role)
  {
    program: "sh",
    args: [
      "-c", "mkdir -p \"$1/.cursor\" && printf '%s' \"$2\" > \"$1/.cursor/mcp.json\"",
      "sh", worktree_path, content,
    ],
    workdir: None,
  }
}

///|
pub fn pi_runtime_root(
  workspace_path : String,
  agent_name : String,
  isolation : @types.IsolationMode,
) -> String {
  match isolation {
    @types.IsolationMode::Inline => workspace_path + "/.choir/pi/" + agent_name
    _ => workspace_path + "/.choir/pi"
  }
}

///|
pub fn pi_agent_dir(runtime_root : String) -> String {
  runtime_root + "/agent"
}

///|
pub fn pi_session_dir(runtime_root : String) -> String {
  runtime_root + "/sessions"
}

///|
pub fn pi_extension_path(runtime_root : String) -> String {
  runtime_root + "/choir-extension.ts"
}

///|
pub fn pi_default_builtin_tools(role : String) -> String {
  match role {
    "root" | "tl" => "read,bash,grep,find,ls"
    "dev" => "read,bash,edit,write,grep,find,ls"
    _ => "read,bash,grep,find,ls"
  }
}

///|
pub fn pi_default_thinking_level(role : String) -> String {
  match role {
    "root" | "tl" => "high"
    _ => "medium"
  }
}

///|
pub fn pi_append_system_prompt(role : @types.Role) -> String {
  match role {
    @types.Role::Root | @types.Role::TL =>
      (
        #|You are the Choir Team Lead running inside Pi.
        #|Prefer delegation over direct implementation. Use `fork_wave` for branch-owning work and `spawn_worker` for research/review.
        #|After spawning children, stop and wait for `notify_parent` and review updates instead of polling reflexively.
        #|Use `merge_pr` to merge through Choir. Do not claim a PR is merged until `merge_pr` succeeds in this session.
        #|If the task truly requires shared scaffold before delegation, keep it minimal and explicit.
      )
    @types.Role::Dev =>
      (
        #|You are a Choir dev leaf running inside Pi.
        #|Stay within the assigned task, implement the smallest correct change, verify once per code change, and use `file_pr` / `notify_parent` instead of raw GitHub flows.
        #|Do not shut down before the PR/review loop is in the right state.
      )
    @types.Role::Worker =>
      (
        #|You are a Choir worker running inside Pi.
        #|Workers are research/review helpers: do not own branches or PRs.
        #|Report findings with `notify_parent` and stop when complete or blocked.
      )
  }
}

///|
pub fn pi_extension_content() -> String {
  (
    #|import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
    #|import { Type } from "@sinclair/typebox";
    #|
    #|type ChoirRole = "root" | "tl" | "dev" | "worker";
    #|type ToolParams = Record<string, unknown>;
    #|
    #|type ChoirToolSpec = {
    #|  name: string;
    #|  label: string;
    #|  description: string;
    #|  roles: ChoirRole[];
    #|  parameters: unknown;
    #|  promptSnippet?: string;
    #|  promptGuidelines?: string[];
    #|};
    #|
    #|const TL_ROLES: ChoirRole[] = ["root", "tl"];
    #|const DEV_ROLES: ChoirRole[] = ["dev"];
    #|const WORKER_ROLES: ChoirRole[] = ["worker"];
    #|
    #|const childRoleEnum = Type.Union([Type.Literal("dev"), Type.Literal("tl")]);
    #|const statusEnum = Type.Union([Type.Literal("success"), Type.Literal("failure"), Type.Literal("info")]);
    #|const allAgentTypeEnum = Type.Union([
    #|  Type.Literal("gemini"),
    #|  Type.Literal("claude"),
    #|  Type.Literal("moon_pilot"),
    #|  Type.Literal("codex"),
    #|  Type.Literal("cursor_agent"),
    #|  Type.Literal("pi"),
    #|]);
    #|const workerAgentTypeEnum = Type.Union([
    #|  Type.Literal("gemini"),
    #|  Type.Literal("claude"),
    #|  Type.Literal("moon_pilot"),
    #|  Type.Literal("pi"),
    #|]);
    #|
    #|const multilineKeys = new Set([
    #|  "read_first",
    #|  "steps",
    #|  "verify",
    #|  "done_criteria",
    #|  "boundary",
    #|  "constraints",
    #|  "key_decisions",
    #|  "non_goals",
    #|]);
    #|
    #|const toolSpecs: ChoirToolSpec[] = [
    #|  {
    #|    name: "fork_wave",
    #|    label: "fork_wave",
    #|    description: "Spawn one or more Choir child agents in worktrees.",
    #|    roles: TL_ROLES,
    #|    promptSnippet: "Use this to delegate implementation or sub-TL work through Choir.",
    #|    promptGuidelines: [
    #|      "Prefer `tasks` for distinct parallel subtasks and `task + count` for identical best-of-N work.",
    #|      "Use `role: \"tl\"` only when you intend to spawn a sub-team-lead.",
    #|    ],
    #|    parameters: Type.Object({
    #|      caller_id: Type.Optional(Type.String({ description: "Caller id override. Defaults from CHOIR_AGENT_ID or Choir config when available." })),
    #|      task: Type.Optional(Type.String({ description: "Shared task for all leaves when using `count`." })),
    #|      tasks: Type.Optional(Type.Array(Type.String({ description: "Per-leaf task string." }), { description: "Distinct per-leaf tasks." })),
    #|      agent_type: Type.Optional(allAgentTypeEnum),
    #|      role: Type.Optional(childRoleEnum),
    #|      parent_branch: Type.Optional(Type.String({ description: "Parent branch (defaults to main/default branch)." })),
    #|      count: Type.Optional(Type.Number({ description: "Leaf count when using a shared `task`." })),
    #|      slug_prefix: Type.Optional(Type.String({ description: "Slug prefix for generated child ids." })),
    #|      read_first: Type.Optional(Type.Array(Type.String(), { description: "Paths children should read first." })),
    #|      steps: Type.Optional(Type.Array(Type.String(), { description: "Implementation steps." })),
    #|      verify: Type.Optional(Type.Array(Type.String(), { description: "Verification commands." })),
    #|      done_criteria: Type.Optional(Type.Array(Type.String(), { description: "Acceptance criteria." })),
    #|      boundary: Type.Optional(Type.Array(Type.String(), { description: "Things children must not do." })),
    #|      constraints: Type.Optional(Type.Array(Type.String(), { description: "Extra constraints." })),
    #|      context: Type.Optional(Type.String({ description: "Additional wave context." })),
    #|      key_decisions: Type.Optional(Type.Array(Type.String(), { description: "Already-fixed decisions." })),
    #|      non_goals: Type.Optional(Type.Array(Type.String(), { description: "Explicit non-goals." })),
    #|    }),
    #|  },
    #|  {
    #|    name: "spawn_worker",
    #|    label: "spawn_worker",
    #|    description: "Spawn a non-branch-owning Choir worker for research or review.",
    #|    roles: TL_ROLES,
    #|    promptSnippet: "Use this for research/review tasks that should not own a branch or PR.",
    #|    parameters: Type.Object({
    #|      caller_id: Type.Optional(Type.String({ description: "Caller id override." })),
    #|      task: Type.String({ description: "Primary worker task." }),
    #|      prompt: Type.Optional(Type.String({ description: "Full prompt override." })),
    #|      slug: Type.Optional(Type.String({ description: "Worker slug override." })),
    #|      agent_type: Type.Optional(workerAgentTypeEnum),
    #|      type: Type.Optional(Type.String({ description: "Worker profile, e.g. research or review." })),
    #|      read_first: Type.Optional(Type.Array(Type.String(), { description: "Paths the worker should read first." })),
    #|      steps: Type.Optional(Type.Array(Type.String(), { description: "Suggested steps." })),
    #|      verify: Type.Optional(Type.Array(Type.String(), { description: "Verification commands." })),
    #|      done_criteria: Type.Optional(Type.Array(Type.String(), { description: "Acceptance criteria." })),
    #|      boundary: Type.Optional(Type.Array(Type.String(), { description: "Things the worker must not do." })),
    #|      constraints: Type.Optional(Type.Array(Type.String(), { description: "Extra constraints." })),
    #|      context: Type.Optional(Type.String({ description: "Extra context or reasoning summary." })),
    #|      key_decisions: Type.Optional(Type.Array(Type.String(), { description: "Already-fixed decisions." })),
    #|      non_goals: Type.Optional(Type.Array(Type.String(), { description: "Explicit non-goals." })),
    #|    }),
    #|  },
    #|  {
    #|    name: "merge_pr",
    #|    label: "merge_pr",
    #|    description: "Merge a tracked Choir PR after review is clean.",
    #|    roles: TL_ROLES,
    #|    promptSnippet: "Use this to merge a child PR through Choir's tracked merge flow.",
    #|    parameters: Type.Object({
    #|      pr_number: Type.Number({ description: "Pull request number to merge." }),
    #|      parent_branch: Type.Optional(Type.String({ description: "Parent branch (defaults to main)." })),
    #|      caller_id: Type.Optional(Type.String({ description: "Caller id override." })),
    #|      force: Type.Optional(Type.Boolean({ description: "Bypass ChangesRequested guard." })),
    #|    }),
    #|  },
    #|  {
    #|    name: "resolve_review_thread",
    #|    label: "resolve_review_thread",
    #|    description: "Resolve a GitHub pull request review thread by thread id.",
    #|    roles: [...TL_ROLES, ...DEV_ROLES],
    #|    parameters: Type.Object({
    #|      thread_id: Type.String({ description: "GitHub review thread id, e.g. PRT_kwDO..." }),
    #|      caller_id: Type.Optional(Type.String({ description: "Caller id override." })),
    #|    }),
    #|  },
    #|  {
    #|    name: "agent_list",
    #|    label: "agent_list",
    #|    description: "List active agents known to the Choir registry by default.",
    #|    roles: TL_ROLES,
    #|    parameters: Type.Object({
    #|      parent_id: Type.Optional(Type.String({ description: "Optional parent id filter." })),
    #|      include_inactive: Type.Optional(Type.Boolean({ description: "Show inactive/done agents too." })),
    #|    }),
    #|  },
    #|  {
    #|    name: "cancel_wave",
    #|    label: "cancel_wave",
    #|    description: "Cancel active children of the current caller.",
    #|    roles: TL_ROLES,
    #|    parameters: Type.Object({
    #|      force: Type.Optional(Type.Boolean({ description: "Cancel even mid-review children." })),
    #|    }),
    #|  },
    #|  {
    #|    name: "file_pr",
    #|    label: "file_pr",
    #|    description: "Create or update a PR for the current branch through Choir.",
    #|    roles: DEV_ROLES,
    #|    promptSnippet: "Use this instead of raw `gh pr create` when operating as a Choir leaf.",
    #|    parameters: Type.Object({
    #|      caller_id: Type.Optional(Type.String({ description: "Caller id override." })),
    #|      branch: Type.Optional(Type.String({ description: "Leaf branch (defaults from Choir config when available)." })),
    #|      parent_branch: Type.Optional(Type.String({ description: "Parent branch (defaults from Choir config when available)." })),
    #|      title: Type.Optional(Type.String({ description: "PR title override." })),
    #|      body: Type.Optional(Type.String({ description: "PR body override." })),
    #|    }),
    #|  },
    #|  {
    #|    name: "notify_parent",
    #|    label: "notify_parent",
    #|    description: "Send a status message to the current parent agent.",
    #|    roles: [...DEV_ROLES, ...WORKER_ROLES],
    #|    promptSnippet: "Use this to report blockers, findings, PR readiness, or completion back to the parent.",
    #|    parameters: Type.Object({
    #|      caller_id: Type.Optional(Type.String({ description: "Caller id override." })),
    #|      message: Type.String({ description: "Message to send to the parent." }),
    #|      status: Type.Optional(statusEnum),
    #|    }),
    #|  },
    #|  {
    #|    name: "shutdown",
    #|    label: "shutdown",
    #|    description: "Tell Choir this agent is done and request pane shutdown.",
    #|    roles: [...DEV_ROLES, ...WORKER_ROLES],
    #|    parameters: Type.Object({
    #|      caller_id: Type.Optional(Type.String({ description: "Caller id override." })),
    #|    }),
    #|  },
    #|  {
    #|    name: "task_list",
    #|    label: "task_list",
    #|    description: "List Choir tasks.",
    #|    roles: [...DEV_ROLES, ...WORKER_ROLES],
    #|    parameters: Type.Object({}),
    #|  },
    #|  {
    #|    name: "task_get",
    #|    label: "task_get",
    #|    description: "Get a Choir task by id.",
    #|    roles: [...DEV_ROLES, ...WORKER_ROLES],
    #|    parameters: Type.Object({
    #|      id: Type.String({ description: "Task id." }),
    #|    }),
    #|  },
    #|  {
    #|    name: "task_update",
    #|    label: "task_update",
    #|    description: "Update Choir task state/notes.",
    #|    roles: DEV_ROLES,
    #|    parameters: Type.Object({
    #|      id: Type.String({ description: "Task id." }),
    #|      status: Type.Optional(Type.String({ description: "New task status." })),
    #|      assignee: Type.Optional(Type.String({ description: "Assignee." })),
    #|      notes: Type.Optional(Type.String({ description: "Notes." })),
    #|    }),
    #|  },
    #|];
    #|
    #|function normalizeRole(value: string | undefined): ChoirRole {
    #|  if (value === "root" || value === "tl" || value === "dev" || value === "worker") {
    #|    return value;
    #|  }
    #|  return "tl";
    #|}
    #|
    #|function currentRole(): ChoirRole {
    #|  return normalizeRole(process.env.CHOIR_ROLE);
    #|}
    #|
    #|function currentAgentId(): string | undefined {
    #|  const value = process.env.CHOIR_AGENT_ID?.trim();
    #|  return value ? value : undefined;
    #|}
    #|
    #|function normalizeParams(toolName: string, params: ToolParams): ToolParams {
    #|  const normalized: ToolParams = { ...params };
    #|
    #|  for (const key of multilineKeys) {
    #|    const value = normalized[key];
    #|    if (Array.isArray(value)) {
    #|      normalized[key] = value.join("\n");
    #|    }
    #|  }
    #|
    #|  if (["fork_wave", "spawn_worker", "merge_pr", "file_pr", "notify_parent", "shutdown"].includes(toolName) && !normalized.caller_id) {
    #|    const agentId = currentAgentId();
    #|    if (agentId) normalized.caller_id = agentId;
    #|  }
    #|
    #|  return normalized;
    #|}
    #|
    #|function renderResultText(result: unknown): string {
    #|  if (result === undefined) return "{}";
    #|  return JSON.stringify(result, null, 2);
    #|}
    #|
    #|async function runChoirTool(pi: ExtensionAPI, toolName: string, callerRole: ChoirRole, params: ToolParams, signal: AbortSignal) {
    #|  const normalized = normalizeParams(toolName, params);
    #|  const execResult = await pi.exec(
    #|    "choir",
    #|    ["tool", toolName, "--caller-role", callerRole, "--json", JSON.stringify(normalized)],
    #|    { signal, timeout: 10 * 60 * 1000 },
    #|  );
    #|
    #|  const stdout = execResult.stdout.trim();
    #|  const stderr = execResult.stderr.trim();
    #|
    #|  if (stdout) {
    #|    let parsed: any;
    #|    try {
    #|      parsed = JSON.parse(stdout);
    #|    } catch {
    #|      const extra = stderr ? " stderr: " + stderr : "";
    #|      throw new Error("invalid JSON from choir tool " + toolName + ": " + stdout + extra);
    #|    }
    #|    if (parsed && typeof parsed === "object" && typeof parsed.ok === "boolean") {
    #|      if (parsed.ok) {
    #|        return parsed.result ?? {};
    #|      }
    #|      throw new Error(parsed.error || ("choir tool " + toolName + " failed"));
    #|    }
    #|  }
    #|
    #|  const pieces = [stderr, stdout].filter(Boolean);
    #|  const suffix = pieces.length > 0 ? ": " + pieces.join(" | ") : "";
    #|  throw new Error("choir tool " + toolName + " failed" + suffix);
    #|}
    #|
    #|function builtinToolsForRole(role: ChoirRole): string[] {
    #|  if (role === "root" || role === "tl") {
    #|    return ["read", "bash", "grep", "find", "ls"];
    #|  }
    #|  if (role === "dev") {
    #|    return ["read", "bash", "edit", "write", "grep", "find", "ls"];
    #|  }
    #|  return ["read", "bash", "grep", "find", "ls"];
    #|}
    #|
    #|function extensionToolNamesForRole(role: ChoirRole): string[] {
    #|  return toolSpecs.filter((spec) => spec.roles.includes(role)).map((spec) => spec.name);
    #|}
    #|
    #|function thinkingLevelForRole(role: ChoirRole): "high" | "medium" {
    #|  if (role === "root" || role === "tl") return "high";
    #|  return "medium";
    #|}
    #|
    #|export default function choirExtension(pi: ExtensionAPI) {
    #|  const role = currentRole();
    #|
    #|  for (const spec of toolSpecs) {
    #|    if (!spec.roles.includes(role)) continue;
    #|    pi.registerTool({
    #|      name: spec.name,
    #|      label: spec.label,
    #|      description: spec.description,
    #|      promptSnippet: spec.promptSnippet,
    #|      promptGuidelines: spec.promptGuidelines,
    #|      parameters: spec.parameters,
    #|      async execute(_toolCallId, params, signal, onUpdate) {
    #|        onUpdate?.({
    #|          content: [{ type: "text", text: "Running choir tool " + spec.name + "..." }],
    #|        });
    #|        const result = await runChoirTool(pi, spec.name, role, params as ToolParams, signal);
    #|        return {
    #|          content: [{ type: "text", text: renderResultText(result) }],
    #|          details: result,
    #|        };
    #|      },
    #|    });
    #|  }
    #|
    #|  pi.on("session_start", async () => {
    #|    pi.setActiveTools([...builtinToolsForRole(role), ...extensionToolNamesForRole(role)]);
    #|    pi.setThinkingLevel(thinkingLevelForRole(role));
    #|  });
    #|
    #|  pi.registerCommand("choir-role", {
    #|    description: "Show the Choir role/config detected by the Pi extension",
    #|    handler: async (_args, ctx) => {
    #|      const agentId = currentAgentId() || "(none)";
    #|      ctx.ui.notify("Choir role: " + role + "\nCHOIR_AGENT_ID: " + agentId, "info");
    #|    },
    #|  });
    #|}
  )
}

///|
pub fn write_pi_runtime_dirs(runtime_root : String) -> Command {
  {
    program: "sh",
    args: ["-c", "mkdir -p \"$1/agent\" \"$1/sessions\"", "sh", runtime_root],
    workdir: None,
  }
}

///|
pub fn write_pi_extension(runtime_root : String) -> Command {
  let content = pi_extension_content()
  {
    program: "sh",
    args: [
      "-c", "mkdir -p \"$1\" && printf '%s' \"$2\" > \"$1/choir-extension.ts\"",
      "sh", runtime_root, content,
    ],
    workdir: None,
  }
}

///|
pub fn seed_pi_auth(runtime_root : String, root_project : String) -> Command {
  {
    program: "sh",
    args: [
      "-c", "mkdir -p \"$1/agent\" && if [ -f \"$2/.choir/pi/agent/auth.json\" ] && [ ! -f \"$1/agent/auth.json\" ]; then cp \"$2/.choir/pi/agent/auth.json\" \"$1/agent/auth.json\"; elif [ -n \"$HOME\" ] && [ -f \"$HOME/.pi/agent/auth.json\" ] && [ ! -f \"$1/agent/auth.json\" ]; then cp \"$HOME/.pi/agent/auth.json\" \"$1/agent/auth.json\"; fi",
      "sh", runtime_root, root_project,
    ],
    workdir: None,
  }
}

///|
/// LEGACY: Register a synthetic member in a Claude Teams config.json via shell.
/// Native version is @workspace.register_team_member_native.
pub fn register_team_member(
  parent_agent_id : String,
  member_name : String,
  agent_type : String,
) -> Command {
  // Shell script: read config.json, check for existing member, append if missing
  let config_path = "~/.claude/teams/" + parent_agent_id + "/config.json"
  let script = "CONFIG=" +
    @sys.shell_quote(config_path) +
    "; CONFIG=\"${CONFIG/#\\~/\"$HOME\"}\"; " +
    "[ -f \"$CONFIG\" ] || exit 0; " +
    "grep -q '\"name\":\"'\"$1\"'\"' \"$CONFIG\" 2>/dev/null && exit 0; " +
    "TMP=\"${CONFIG}.tmp\"; " +
    "python3 -c \"" +
    "import json,sys,time; " +
    "c=json.load(open(sys.argv[1])); " +
    "c.setdefault('members',[]); " +
    "c['members'].append({'agentId':sys.argv[2]+'@'+sys.argv[3],'name':sys.argv[2],'agentType':sys.argv[4],'model':'gemini','color':'green','joinedAt':int(time.time()*1000),'tmuxPaneId':'synthetic','subscriptions':[],'backendType':'choir'}); " +
    "json.dump(c,open(sys.argv[5],'w'),indent=2)" +
    "\" \"$CONFIG\" \"$1\" " +
    @sys.shell_quote(parent_agent_id) +
    " \"$2\" \"$TMP\" && mv \"$TMP\" \"$CONFIG\""
  {
    program: "sh",
    args: ["-c", script, "sh", member_name, agent_type],
    workdir: None,
  }
}

///|
/// Post a comment on a GitHub PR via `gh pr comment`.
pub fn gh_pr_comment(
  pr_number : Int,
  body : String,
  project_dir : String,
) -> Command {
  {
    program: "gh",
    args: ["pr", "comment", pr_number.to_string(), "--body", body],
    workdir: Some(project_dir),
  }
}
