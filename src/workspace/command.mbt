///|
pub(all) struct Command {
  program : String
  args : Array[String]
  workdir : String?
} derive(Debug, Eq)

///|
pub impl Show for Command with output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
/// Marker `Command.program` for `run_native_choir_file_command` / `exec.run`.
/// Args: `[worktree_path, basename_under_.choir, file_body]`.
pub let native_write_choir_file_program : String = "__choir_native_write_choir_file__"

///|
/// Marker for `run_native_workspace_rel_file_command`: args `[workspace_root, relative_path, file_body]`.
pub let native_write_workspace_rel_file_program : String = "__choir_native_write_workspace_rel_file__"

///|
/// Args: `[worktree_path]` — install `.choir/bin/choir-leaf-tool` and tool symlinks.
pub let native_leaf_helpers_program : String = "__choir_native_leaf_helpers__"

///|
/// Args: `[project_dir, workspace, branch]` — best-effort prune/remove worktree path, `rm -rf`,
/// and delete branch; always returns `0` from the runner.
pub let native_worktree_bootstrap_cleanup_program : String = "__choir_native_worktree_bootstrap_cleanup__"

///|
/// Args: `[project_dir, branch]` — best-effort `git fetch origin <branch>` with stderr warnings;
/// always returns `0` from the runner.
pub let native_git_fetch_origin_branch_best_effort_program : String = "__choir_native_git_fetch_origin_branch_best_effort__"

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
/// Ensure `.choir/` exists and write `basename` (e.g. `config.toml`) under it.
/// Returns `0` on success, `1` on failure, `-1` if `cmd` is not a native choir-file write.
pub fn run_native_choir_file_command(cmd : Command) -> Int {
  if cmd.program != native_write_choir_file_program {
    return -1
  }
  if cmd.args.length() != 3 {
    return 1
  }
  let worktree_path = cmd.args[0]
  let basename = cmd.args[1]
  let content = cmd.args[2]
  let choir_dir = worktree_path + "/.choir"
  if !@sys.create_dir_all(choir_dir) {
    return 1
  }
  let path = choir_dir + "/" + basename
  if !@sys.write_file_sync(path, content) {
    return 1
  }
  0
}

///|
fn validate_workspace_rel_path(rel : String) -> Bool {
  if rel == "" || rel.has_prefix("/") {
    return false
  }
  if rel.contains("..") {
    return false
  }
  true
}

///|
fn parent_dir_for_file(full_path : String) -> String {
  let last_slash = match full_path.rev_find("/") {
    Some(i) => i
    None => -1
  }
  if last_slash <= 0 {
    return "."
  }
  full_path[0:last_slash].to_string()
}

///|
/// Ensure `workspace_root/relative_path` exists (parent dirs) and write `content`.
/// Returns `0` on success, `1` on failure, `-1` if `cmd` is not this native write.
pub fn run_native_workspace_rel_file_command(cmd : Command) -> Int {
  if cmd.program != native_write_workspace_rel_file_program {
    return -1
  }
  if cmd.args.length() != 3 {
    return 1
  }
  let root_raw = cmd.args[0]
  let rel = cmd.args[1]
  let content = cmd.args[2]
  if !validate_workspace_rel_path(rel) {
    return 1
  }
  let root = match @sys.realpath_native(root_raw) {
    Some(p) => p
    None => root_raw
  }
  let full = root + "/" + rel
  if !full.has_prefix(root + "/") && full != root {
    return 1
  }
  let parent = parent_dir_for_file(full)
  if !@sys.create_dir_all(parent) {
    return 1
  }
  let parent_real = match @sys.realpath_native(parent) {
    Some(p) => p
    None => return 1
  }
  if !parent_real.has_prefix(root + "/") && parent_real != root {
    return 1
  }
  if !@sys.write_file_sync(full, content) {
    return 1
  }
  0
}

///|
fn leaf_helper_script_body() -> String {
  (
    #|#!/bin/sh
    #|tool="${0##*/}"
    #|exec choir leaf-tool "$tool" "$@"
  )
}

///|
/// Install leaf helper scripts under `worktree_path/.choir/bin` without shell heredocs.
/// Returns `0` on success, `1` on failure, `-1` if `cmd` is not this native command.
pub fn run_native_leaf_helpers_command(cmd : Command) -> Int {
  if cmd.program != native_leaf_helpers_program {
    return -1
  }
  if cmd.args.length() != 1 {
    return 1
  }
  let worktree_path = cmd.args[0]
  if worktree_path == "" {
    return 1
  }
  let bin_dir = worktree_path + "/.choir/bin"
  if !@sys.create_dir_all(bin_dir) {
    return 1
  }
  let script_path = bin_dir + "/choir-leaf-tool"
  if !@sys.write_file_sync(script_path, leaf_helper_script_body()) {
    return 1
  }
  if !@sys.chmod_mode(script_path, 0o755) {
    return 1
  }
  let names = [
    "file_pr", "notify_parent", "shutdown", "task_list", "task_get", "task_create",
    "task_update",
  ]
  for name in names {
    let link_path = bin_dir + "/" + name
    if !@sys.symlink_force("choir-leaf-tool", link_path) {
      return 1
    }
  }
  0
}

///|
/// Best-effort worktree cleanup before a fresh `git worktree add`. Implemented in `stub.c` (direct
/// `git`/`rm` argv, no shell).
/// Returns `0` on success, `1` on bad args, `-1` if `cmd` is not this native command.
pub fn run_native_worktree_bootstrap_cleanup_command(cmd : Command) -> Int {
  if cmd.program != native_worktree_bootstrap_cleanup_program {
    return -1
  }
  if cmd.args.length() != 3 {
    return 1
  }
  @sys.worktree_bootstrap_cleanup_native(cmd.args[0], cmd.args[1], cmd.args[2])
  0
}

///|
/// Best-effort `git fetch origin <branch>` in `project_dir`. Returns `0` on success, `1` on bad args,
/// `-1` if `cmd` is not this native command.
pub fn run_native_git_fetch_origin_branch_best_effort_command(
  cmd : Command,
) -> Int {
  if cmd.program != native_git_fetch_origin_branch_best_effort_program {
    return -1
  }
  if cmd.args.length() != 2 {
    return 1
  }
  @sys.git_fetch_origin_branch_best_effort_native(cmd.args[0], cmd.args[1])
  0
}

///|
/// Write `workspace_root/relative_path` with native file I/O (via `exec.run` sentinel).
pub fn workspace_relative_file_command(
  workspace_root : String,
  relative_path : String,
  content : String,
) -> Command {
  {
    program: native_write_workspace_rel_file_program,
    args: [workspace_root, relative_path, content],
    workdir: None,
  }
}

///|
/// Write .choir/config.local.toml into worktree with role override.
/// Executed as a native file write by `exec.run`, not an inline shell snippet.
pub fn write_local_config(worktree_path : String, content : String) -> Command {
  {
    program: native_write_choir_file_program,
    args: [worktree_path, "config.local.toml", content],
    workdir: None,
  }
}

///|
/// Write .choir/config.toml into worktree with client connection settings.
pub fn write_spawn_config(worktree_path : String, content : String) -> Command {
  {
    program: native_write_choir_file_program,
    args: [worktree_path, "config.toml", content],
    workdir: None,
  }
}

///|
/// Install shell helpers for CLIs that do not load MCP tools directly.
pub fn write_leaf_helper_scripts(worktree_path : String) -> Command {
  { program: native_leaf_helpers_program, args: [worktree_path], workdir: None }
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
  for name in ["problems", "common", role] {
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
    program: native_write_choir_file_program,
    args: [worktree_path, "gemini-settings.json", content],
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
  workspace_relative_file_command(worktree_path, ".cursor/mcp.json", content)
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

///|
/// Request a PR reviewer via `gh pr edit --add-reviewer` (GitHub Reviewers API).
pub fn gh_pr_add_reviewer(
  pr_number : Int,
  reviewer : String,
  project_dir : String,
) -> Command {
  {
    program: "gh",
    args: ["pr", "edit", pr_number.to_string(), "--add-reviewer", reviewer],
    workdir: Some(project_dir),
  }
}
