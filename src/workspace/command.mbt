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
    #|
    #|const multilineKeys = ["read_first", "steps", "verify", "done_criteria", "boundary", "constraints", "key_decisions", "non_goals"];
    #|const statusEnum = Type.Union([Type.Literal("success"), Type.Literal("failure"), Type.Literal("info")]);
    #|const childRoleEnum = Type.Union([Type.Literal("dev"), Type.Literal("tl")]);
    #|const allAgentTypeEnum = Type.Union([
    #|  Type.Literal("gemini"),
    #|  Type.Literal("claude"),
    #|  Type.Literal("moon_pilot"),
    #|  Type.Literal("codex"),
    #|  Type.Literal("cursor_agent"),
    #|  Type.Literal("pi"),
    #|]);
    #|
    #|function normalizeRole(value: string | undefined): ChoirRole {
    #|  return value === "root" || value === "tl" || value === "dev" || value === "worker" ? value : "tl";
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
    #|function normalizeParams(toolName: string, params: Record<string, unknown>) {
    #|  const normalized: Record<string, unknown> = { ...params };
    #|  for (const key of multilineKeys) {
    #|    const value = normalized[key];
    #|    if (Array.isArray(value)) normalized[key] = value.join("\n");
    #|  }
    #|  if (["fork_wave", "spawn_worker", "merge_pr", "file_pr", "notify_parent", "shutdown"].includes(toolName) && !normalized.caller_id) {
    #|    const agentId = currentAgentId();
    #|    if (agentId) normalized.caller_id = agentId;
    #|  }
    #|  return normalized;
    #|}
    #|
    #|async function runChoirTool(pi: ExtensionAPI, toolName: string, params: Record<string, unknown>, signal: AbortSignal) {
    #|  const callerRole = currentRole();
    #|  const execResult = await pi.exec(
    #|    "choir",
    #|    ["tool", toolName, "--caller-role", callerRole, "--json", JSON.stringify(normalizeParams(toolName, params))],
    #|    { signal, timeout: 600000 },
    #|  );
    #|  const stdout = execResult.stdout.trim();
    #|  const stderr = execResult.stderr.trim();
    #|  if (stdout) {
    #|    let parsed: any;
    #|    try {
    #|      parsed = JSON.parse(stdout);
    #|    } catch {
    #|      throw new Error("invalid JSON from choir tool " + toolName + ": " + stdout + (stderr ? " stderr: " + stderr : ""));
    #|    }
    #|    if (parsed && typeof parsed === "object" && typeof parsed.ok === "boolean") {
    #|      if (parsed.ok) return parsed.result ?? {};
    #|      throw new Error(parsed.error || ("choir tool " + toolName + " failed"));
    #|    }
    #|  }
    #|  const suffix = [stderr, stdout].filter(Boolean).join(" | ");
    #|  throw new Error("choir tool " + toolName + " failed" + (suffix ? ": " + suffix : ""));
    #|}
    #|
    #|function builtinToolsForRole(role: ChoirRole): string[] {
    #|  if (role === "root" || role === "tl") return ["read", "bash", "grep", "find", "ls"];
    #|  if (role === "dev") return ["read", "bash", "edit", "write", "grep", "find", "ls"];
    #|  return ["read", "bash", "grep", "find", "ls"];
    #|}
    #|
    #|function extensionToolNamesForRole(role: ChoirRole): string[] {
    #|  if (role === "root" || role === "tl") return ["fork_wave", "spawn_worker", "merge_pr", "resolve_review_thread", "agent_list", "cancel_wave"];
    #|  if (role === "dev") return ["file_pr", "resolve_review_thread", "notify_parent", "shutdown", "task_list", "task_get", "task_update"];
    #|  return ["notify_parent", "shutdown", "task_list", "task_get"];
    #|}
    #|
    #|function thinkingLevelForRole(role: ChoirRole): "high" | "medium" {
    #|  return role === "root" || role === "tl" ? "high" : "medium";
    #|}
    #|
    #|export default function choirExtension(pi: ExtensionAPI) {
    #|  const role = currentRole();
    #|
    #|  if (role === "root" || role === "tl") {
    #|    pi.registerTool({
    #|      name: "fork_wave",
    #|      label: "fork_wave",
    #|      description: "Spawn one or more Choir child agents in worktrees.",
    #|      parameters: Type.Object({
    #|        caller_id: Type.Optional(Type.String()),
    #|        task: Type.Optional(Type.String()),
    #|        tasks: Type.Optional(Type.Array(Type.String())),
    #|        agent_type: Type.Optional(allAgentTypeEnum),
    #|        role: Type.Optional(childRoleEnum),
    #|        parent_branch: Type.Optional(Type.String()),
    #|        count: Type.Optional(Type.Number()),
    #|        slug_prefix: Type.Optional(Type.String()),
    #|        read_first: Type.Optional(Type.Array(Type.String())),
    #|        steps: Type.Optional(Type.Array(Type.String())),
    #|        verify: Type.Optional(Type.Array(Type.String())),
    #|        done_criteria: Type.Optional(Type.Array(Type.String())),
    #|        boundary: Type.Optional(Type.Array(Type.String())),
    #|        constraints: Type.Optional(Type.Array(Type.String())),
    #|        context: Type.Optional(Type.String()),
    #|        key_decisions: Type.Optional(Type.Array(Type.String())),
    #|        non_goals: Type.Optional(Type.Array(Type.String())),
    #|      }),
    #|      async execute(_toolCallId, params, signal, onUpdate) {
    #|        onUpdate?.({ content: [{ type: "text", text: "Running choir tool fork_wave..." }] });
    #|        const result = await runChoirTool(pi, "fork_wave", params as Record<string, unknown>, signal);
    #|        return { content: [{ type: "text", text: JSON.stringify(result ?? {}, null, 2) }], details: result ?? {} };
    #|      },
    #|    });
    #|    pi.registerTool({
    #|      name: "spawn_worker",
    #|      label: "spawn_worker",
    #|      description: "Spawn a non-branch-owning Choir worker.",
    #|      parameters: Type.Object({
    #|        caller_id: Type.Optional(Type.String()),
    #|        task: Type.String(),
    #|        prompt: Type.Optional(Type.String()),
    #|        slug: Type.Optional(Type.String()),
    #|        agent_type: Type.Optional(allAgentTypeEnum),
    #|        type: Type.Optional(Type.String()),
    #|        read_first: Type.Optional(Type.Array(Type.String())),
    #|        steps: Type.Optional(Type.Array(Type.String())),
    #|        verify: Type.Optional(Type.Array(Type.String())),
    #|        done_criteria: Type.Optional(Type.Array(Type.String())),
    #|        boundary: Type.Optional(Type.Array(Type.String())),
    #|        constraints: Type.Optional(Type.Array(Type.String())),
    #|        context: Type.Optional(Type.String()),
    #|        key_decisions: Type.Optional(Type.Array(Type.String())),
    #|        non_goals: Type.Optional(Type.Array(Type.String())),
    #|      }),
    #|      async execute(_toolCallId, params, signal, onUpdate) {
    #|        onUpdate?.({ content: [{ type: "text", text: "Running choir tool spawn_worker..." }] });
    #|        const result = await runChoirTool(pi, "spawn_worker", params as Record<string, unknown>, signal);
    #|        return { content: [{ type: "text", text: JSON.stringify(result ?? {}, null, 2) }], details: result ?? {} };
    #|      },
    #|    });
    #|    pi.registerTool({
    #|      name: "merge_pr",
    #|      label: "merge_pr",
    #|      description: "Merge a tracked Choir PR after review is clean.",
    #|      parameters: Type.Object({
    #|        pr_number: Type.Number(),
    #|        parent_branch: Type.Optional(Type.String()),
    #|        caller_id: Type.Optional(Type.String()),
    #|        force: Type.Optional(Type.Boolean()),
    #|      }),
    #|      async execute(_toolCallId, params, signal, onUpdate) {
    #|        onUpdate?.({ content: [{ type: "text", text: "Running choir tool merge_pr..." }] });
    #|        const result = await runChoirTool(pi, "merge_pr", params as Record<string, unknown>, signal);
    #|        return { content: [{ type: "text", text: JSON.stringify(result ?? {}, null, 2) }], details: result ?? {} };
    #|      },
    #|    });
    #|    pi.registerTool({
    #|      name: "resolve_review_thread",
    #|      label: "resolve_review_thread",
    #|      description: "Resolve a GitHub pull request review thread by thread id.",
    #|      parameters: Type.Object({
    #|        thread_id: Type.String(),
    #|        caller_id: Type.Optional(Type.String()),
    #|      }),
    #|      async execute(_toolCallId, params, signal, onUpdate) {
    #|        onUpdate?.({ content: [{ type: "text", text: "Running choir tool resolve_review_thread..." }] });
    #|        const result = await runChoirTool(pi, "resolve_review_thread", params as Record<string, unknown>, signal);
    #|        return { content: [{ type: "text", text: JSON.stringify(result ?? {}, null, 2) }], details: result ?? {} };
    #|      },
    #|    });
    #|    pi.registerTool({
    #|      name: "agent_list",
    #|      label: "agent_list",
    #|      description: "List active agents known to the Choir registry by default.",
    #|      parameters: Type.Object({
    #|        parent_id: Type.Optional(Type.String()),
    #|        include_inactive: Type.Optional(Type.Boolean()),
    #|      }),
    #|      async execute(_toolCallId, params, signal, onUpdate) {
    #|        onUpdate?.({ content: [{ type: "text", text: "Running choir tool agent_list..." }] });
    #|        const result = await runChoirTool(pi, "agent_list", params as Record<string, unknown>, signal);
    #|        return { content: [{ type: "text", text: JSON.stringify(result ?? {}, null, 2) }], details: result ?? {} };
    #|      },
    #|    });
    #|    pi.registerTool({
    #|      name: "cancel_wave",
    #|      label: "cancel_wave",
    #|      description: "Cancel active children of the current caller.",
    #|      parameters: Type.Object({ force: Type.Optional(Type.Boolean()) }),
    #|      async execute(_toolCallId, params, signal, onUpdate) {
    #|        onUpdate?.({ content: [{ type: "text", text: "Running choir tool cancel_wave..." }] });
    #|        const result = await runChoirTool(pi, "cancel_wave", params as Record<string, unknown>, signal);
    #|        return { content: [{ type: "text", text: JSON.stringify(result ?? {}, null, 2) }], details: result ?? {} };
    #|      },
    #|    });
    #|  }
    #|
    #|  if (role === "dev") {
    #|    pi.registerTool({
    #|      name: "resolve_review_thread",
    #|      label: "resolve_review_thread",
    #|      description: "Resolve a GitHub pull request review thread by thread id.",
    #|      parameters: Type.Object({
    #|        thread_id: Type.String(),
    #|        caller_id: Type.Optional(Type.String()),
    #|      }),
    #|      async execute(_toolCallId, params, signal, onUpdate) {
    #|        onUpdate?.({ content: [{ type: "text", text: "Running choir tool resolve_review_thread..." }] });
    #|        const result = await runChoirTool(pi, "resolve_review_thread", params as Record<string, unknown>, signal);
    #|        return { content: [{ type: "text", text: JSON.stringify(result ?? {}, null, 2) }], details: result ?? {} };
    #|      },
    #|    });
    #|    pi.registerTool({
    #|      name: "file_pr",
    #|      label: "file_pr",
    #|      description: "Create or update a PR for the current branch through Choir.",
    #|      parameters: Type.Object({
    #|        caller_id: Type.Optional(Type.String()),
    #|        branch: Type.Optional(Type.String()),
    #|        parent_branch: Type.Optional(Type.String()),
    #|        title: Type.Optional(Type.String()),
    #|        body: Type.Optional(Type.String()),
    #|      }),
    #|      async execute(_toolCallId, params, signal, onUpdate) {
    #|        onUpdate?.({ content: [{ type: "text", text: "Running choir tool file_pr..." }] });
    #|        const result = await runChoirTool(pi, "file_pr", params as Record<string, unknown>, signal);
    #|        return { content: [{ type: "text", text: JSON.stringify(result ?? {}, null, 2) }], details: result ?? {} };
    #|      },
    #|    });
    #|  }
    #|
    #|  if (role === "dev" || role === "worker") {
    #|    pi.registerTool({
    #|      name: "notify_parent",
    #|      label: "notify_parent",
    #|      description: "Send a status message to the current parent agent.",
    #|      parameters: Type.Object({
    #|        caller_id: Type.Optional(Type.String()),
    #|        message: Type.String(),
    #|        status: Type.Optional(statusEnum),
    #|      }),
    #|      async execute(_toolCallId, params, signal, onUpdate) {
    #|        onUpdate?.({ content: [{ type: "text", text: "Running choir tool notify_parent..." }] });
    #|        const result = await runChoirTool(pi, "notify_parent", params as Record<string, unknown>, signal);
    #|        return { content: [{ type: "text", text: JSON.stringify(result ?? {}, null, 2) }], details: result ?? {} };
    #|      },
    #|    });
    #|    pi.registerTool({
    #|      name: "shutdown",
    #|      label: "shutdown",
    #|      description: "Tell Choir this agent is done and request pane shutdown.",
    #|      parameters: Type.Object({ caller_id: Type.Optional(Type.String()) }),
    #|      async execute(_toolCallId, params, signal, onUpdate) {
    #|        onUpdate?.({ content: [{ type: "text", text: "Running choir tool shutdown..." }] });
    #|        const result = await runChoirTool(pi, "shutdown", params as Record<string, unknown>, signal);
    #|        return { content: [{ type: "text", text: JSON.stringify(result ?? {}, null, 2) }], details: result ?? {} };
    #|      },
    #|    });
    #|    pi.registerTool({
    #|      name: "task_list",
    #|      label: "task_list",
    #|      description: "List Choir tasks.",
    #|      parameters: Type.Object({}),
    #|      async execute(_toolCallId, params, signal, onUpdate) {
    #|        onUpdate?.({ content: [{ type: "text", text: "Running choir tool task_list..." }] });
    #|        const result = await runChoirTool(pi, "task_list", params as Record<string, unknown>, signal);
    #|        return { content: [{ type: "text", text: JSON.stringify(result ?? {}, null, 2) }], details: result ?? {} };
    #|      },
    #|    });
    #|    pi.registerTool({
    #|      name: "task_get",
    #|      label: "task_get",
    #|      description: "Get a Choir task by id.",
    #|      parameters: Type.Object({ id: Type.String() }),
    #|      async execute(_toolCallId, params, signal, onUpdate) {
    #|        onUpdate?.({ content: [{ type: "text", text: "Running choir tool task_get..." }] });
    #|        const result = await runChoirTool(pi, "task_get", params as Record<string, unknown>, signal);
    #|        return { content: [{ type: "text", text: JSON.stringify(result ?? {}, null, 2) }], details: result ?? {} };
    #|      },
    #|    });
    #|  }
    #|
    #|  if (role === "dev") {
    #|    pi.registerTool({
    #|      name: "task_update",
    #|      label: "task_update",
    #|      description: "Update Choir task state/notes.",
    #|      parameters: Type.Object({
    #|        id: Type.String(),
    #|        status: Type.Optional(Type.String()),
    #|        assignee: Type.Optional(Type.String()),
    #|        notes: Type.Optional(Type.String()),
    #|      }),
    #|      async execute(_toolCallId, params, signal, onUpdate) {
    #|        onUpdate?.({ content: [{ type: "text", text: "Running choir tool task_update..." }] });
    #|        const result = await runChoirTool(pi, "task_update", params as Record<string, unknown>, signal);
    #|        return { content: [{ type: "text", text: JSON.stringify(result ?? {}, null, 2) }], details: result ?? {} };
    #|      },
    #|    });
    #|  }
    #|
    #|  pi.on("session_start", async () => {
    #|    const liveRole = currentRole();
    #|    pi.setActiveTools([...builtinToolsForRole(liveRole), ...extensionToolNamesForRole(liveRole)]);
    #|    pi.setThinkingLevel(thinkingLevelForRole(liveRole));
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
