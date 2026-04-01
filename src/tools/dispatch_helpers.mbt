///|
async fn run_strict(
  runner : async (Array[@workspace.Command]) -> Array[Int],
  cmds : Array[@workspace.Command],
) -> Result[Unit, String] {
  let statuses = runner(cmds) catch { e => return Err(e.to_string()) }
  for i = 0; i < statuses.length(); i = i + 1 {
    let status = statuses[i]
    if status != 0 {
      // Re-run the failing command with stderr capture for a useful error message
      let cmd = cmds[i]
      let (_, stderr) = capture_command_output(cmd)
      let detail = stderr.trim().to_string()
      let msg = if detail != "" {
        cmd.program + " failed (exit " + status.to_string() + "): " + detail
      } else {
        "command failed with status " + status.to_string()
      }
      return Err(msg)
    }
  }
  Ok(())
}

///|
async fn runner_run_strict_first_failure(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for i = 0; i < cmds.length(); i = i + 1 {
    statuses.push(
      match i {
        0 => 0
        1 => 7
        _ => 3
      },
    )
  }
  statuses
}

///|
async test "run_strict returns first failing command index and status" {
  let result = run_strict(runner_run_strict_first_failure, [
    { program: "true", args: [], workdir: None },
    { program: "false", args: [], workdir: None },
    { program: "false", args: [], workdir: None },
  ])
  match result {
    Ok(_) => fail("expected run_strict failure")
    Err(e) => assert_true(e.contains("failed") && e.contains("7"))
  }
}

///|
fn sanitize_plugin_path_component(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    if is_alphanumeric_or_dash(c) || c == '.' {
      buf.write_char(c)
    } else {
      buf.write_char('_')
    }
  }
  let result = buf.to_string()
  if result == "" {
    "unknown"
  } else {
    result
  }
}

///|
fn plugin_request_agent_id(req : @types.Request) -> String {
  match req.args.get("agent_id") {
    Some(agent_id) => agent_id
    None =>
      match req.args.get("caller_id") {
        Some(agent_id) => agent_id
        None =>
          match req.args.get("sender_id") {
            Some(agent_id) => agent_id
            None => "unknown"
          }
      }
  }
}

///|
async fn dispatch_to_plugin(
  req : @types.Request,
  plugins_json : String?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> @types.Response {
  let json = match plugins_json {
    Some(value) => value
    None => return @types.Response::Err("tool not found: " + req.name)
  }
  let plugins = @plugin.parse_plugins_json(json)
  match @plugin.find_handler(plugins, req.name) {
    None => @types.Response::Err("tool not found: " + req.name)
    Some(plugin) => {
      let agent_id = plugin_request_agent_id(req)
      let request_json = @plugin.build_request({
        tool: req.name,
        args: req.args,
        agent_id,
        role: req.role.to_string(),
      })
      let resp_path = "/tmp/choir-plugin-" +
        sanitize_plugin_path_component(req.name) +
        "-" +
        sanitize_plugin_path_component(agent_id) +
        ".json"
      let cmd = @workspace.Command::{
        program: "sh",
        args: [
          "-c",
          "rm -f \"$3\" && printf '%s\\n' \"$2\" | timeout 10 sh -c \"$1\" > \"$3\" 2>/dev/null || true",
          "sh",
          plugin.command,
          request_json,
          resp_path,
        ],
        workdir: None,
      }
      ignore(
        runner([cmd]) catch {
          e => return @types.Response::Err(e.to_string())
        },
      )
      let resp_str = @sys.read_file(resp_path)
      match @plugin.parse_response(resp_str) {
        Ok(result) => result
        Err(e) => @types.Response::Err("plugin error: " + e)
      }
    }
  }
}

///|

///|
/// Resolve the zellij pane ID for a named tab by running list-panes.
/// Returns Some("terminal_N") if found, None otherwise.
pub async fn resolve_zellij_pane_id(
  session : String,
  tab_name : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> String? {
  let manifest = "/tmp/choir-pane-resolve-" + tab_name + ".json"
  let cmd = @workspace.Command::{
    program: "sh",
    args: [
      "-c", "zellij --session \"$1\" action list-panes --json -a -t -s > \"$2\" 2>/dev/null",
      "sh", session, manifest,
    ],
    workdir: None,
  }
  let statuses = runner([cmd]) catch { _ => return None }
  if statuses.length() > 0 && statuses[0] != 0 {
    return None
  }
  let content = @sys.read_file(manifest)
  ignore(
    runner([
      {
        program: "sh",
        args: ["-c", "rm -f \"$1\"", "sh", manifest],
        workdir: None,
      },
    ]) catch {
      _ => []
    },
  )
  if content == "" {
    return None
  }
  let json = @json.parse(content) catch { _ => return None }
  guard json is Array(panes) else { return None }
  for pane in panes {
    guard pane is Object(obj) else { continue }
    let is_plugin = match obj.get("is_plugin") {
      Some(True) => true
      _ => false
    }
    if is_plugin {
      continue
    }
    let pane_tab = match obj.get("tab_name") {
      Some(String(v)) => v
      _ => continue
    }
    if pane_tab != tab_name {
      continue
    }
    let pane_id = match obj.get("id") {
      Some(Number(n, ..)) => n.to_int()
      _ => continue
    }
    return Some("terminal_" + pane_id.to_string())
  }
  None
}

///|
fn resolve_home_path(path : String) -> String {
  if path.length() >= 2 && path[0] == '~' && path[1] == '/' {
    match @sys.getenv("HOME") {
      Some(home) => home + "/" + path[2:path.length()].to_string()
      None => path
    }
  } else {
    path
  }
}

///|
pub async fn verify_teams_delivery(
  inbox_path : String,
  message_json : String,
  fallback_target : String?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  interval_ms? : Int = 10000,
) -> Unit {
  let path = resolve_home_path(inbox_path)
  for i = 0; i < 3; i = i + 1 {
    @async.sleep(interval_ms)
    let content = @sys.read_file(path)
    if !content.contains(message_json) {
      return
    }
  }
  match fallback_target {
    Some(target_str) =>
      match @types.LocalTarget::parse(target_str) {
        Some(target) => {
          let cmd = @workspace.local_send_text(target, message_json)
          ignore(runner([cmd]) catch { _ => [] })
        }
        None => ()
      }
    None => ()
  }
}

///|
pub async fn execute_delivery(
  delivery : @message.DeliveryMethod,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> Result[Unit, String] {
  fn ensure_success(statuses : Array[Int]) -> Result[Unit, String] {
    if statuses.length() == 0 || statuses[0] == 0 {
      Ok(())
    } else {
      Err("delivery command failed with exit code " + statuses[0].to_string())
    }
  }
  fn teams_inbox_command(path : String, json : String) -> @workspace.Command {
    {
      program: "sh",
      args: [
        "-c",
        "mkdir -p \"$(dirname \"$2\")\" && printf '%s\\n' \"$1\" >> \"$2\"",
        "sh",
        json,
        resolve_home_path(path),
      ],
      workdir: Some("."),
    }
  }
  fn delivery_timestamp() -> String {
    @env.now().reinterpret_as_int64().to_string()
  }
  fn normalize_log_error(error : String) -> String {
    let buf = StringBuilder::new()
    for c in error {
      if c == '\n' || c == '\r' {
        buf.write_char(' ')
      } else {
        buf.write_char(c)
      }
    }
    buf.to_string()
  }
  fn log_delivery_retry(
    target : String,
    attempt : Int,
    delay_ms : Int,
    error : String,
  ) -> Unit {
    ignore(
      @sys.append_file_sync(
        ".choir/delivery.log",
        "[delivery-retry] ts_ms=" +
        delivery_timestamp() +
        " target=" +
        target +
        " attempt=" +
        attempt.to_string() +
        " delay_ms=" +
        delay_ms.to_string() +
        " error=" +
        normalize_log_error(error) +
        "\n",
      ),
    )
  }
  fn log_delivery_failure(target : String, error : String) -> Unit {
    ignore(
      @sys.append_file_sync(
        ".choir/delivery.log",
        "[delivery-failed] ts_ms=" +
        delivery_timestamp() +
        " target=" +
        target +
        " error=" +
        normalize_log_error(error) +
        "\n",
      ),
    )
  }
  async fn run_with_retries(
    cmd : @workspace.Command,
    target : String,
  ) -> Result[Unit, String] {
    let backoff_ms = [1000, 2000, 4000]
    let mut last_error = "unknown delivery error"
    for attempt = 0; attempt < 4; attempt = attempt + 1 {
      let mut run_threw = false
      let statuses = runner([cmd]) catch {
        e => {
          last_error = e.to_string()
          run_threw = true
          []
        }
      }
      let attempt_result = if run_threw {
        Err(last_error)
      } else {
        ensure_success(statuses)
      }
      match attempt_result {
        Ok(_) => return Ok(())
        Err(e) => last_error = e
      }
      if attempt < backoff_ms.length() {
        let retry_attempt = attempt + 1
        let delay = backoff_ms[attempt]
        log_delivery_retry(target, retry_attempt, delay, last_error)
        sleep_fn(delay)
      }
    }
    log_delivery_failure(target, last_error)
    Err(last_error)
  }
  match delivery {
    @message.DeliveryMethod::TeamsInbox(path, json, fallback_target~) => {
      let statuses = runner([teams_inbox_command(path, json)]) catch {
        e => return Err(e.to_string())
      }
      match ensure_success(statuses) {
        Ok(_) => {
          ignore(verify_teams_delivery(path, json, fallback_target, runner))
          Ok(())
        }
        Err(e) => Err(e)
      }
    }
    @message.DeliveryMethod::LocalTerminalInput(target, text) => {
      let cmd = @workspace.local_send_text(target, text)
      ignore(
        @sys.append_file_sync(
          ".choir/delivery.log",
          "[delivery] target=" +
          target.to_string() +
          " cmd=" +
          cmd.to_string() +
          "\n",
        ),
      )
      ignore(
        @sys.append_file_sync(
          ".choir/delivery.log",
          "[delivery] dispatch-with-retry target=" + target.to_string() + "\n",
        ),
      )
      run_with_retries(cmd, target.to_string())
    }
    @message.DeliveryMethod::TcpPush(_, _) => Ok(()) // Phase 2
    @message.DeliveryMethod::UdsHttp(sock_path, body) => {
      let result = @uds.http_post(sock_path, body)
      if result == 0 {
        Ok(())
      } else {
        Err("UDS HTTP post failed with code " + result.to_string())
      }
    }
  }
}

///|
/// Parse the JSON response from `gh api graphql` for unresolved review threads.
/// Returns (count, formatted_text). Each entry includes the thread ID so agents
/// can call resolve_review_thread to resolve specific threads.
pub fn parse_unresolved_threads_response(json_str : String) -> (Int, String) {
  let json = @json.parse(json_str) catch { _ => return (0, "") }
  guard json is Object(root) else { return (0, "") }
  let nodes = match root.get("data") {
    Some(Object(data)) =>
      match data.get("repository") {
        Some(Object(repo)) =>
          match repo.get("pullRequest") {
            Some(Object(pr)) =>
              match pr.get("reviewThreads") {
                Some(Object(rt)) =>
                  match rt.get("nodes") {
                    Some(Array(ns)) => ns
                    _ => return (0, "")
                  }
                _ => return (0, "")
              }
            _ => return (0, "")
          }
        _ => return (0, "")
      }
    _ => return (0, "")
  }
  let parts = StringBuilder::new()
  let mut count = 0
  for node in nodes {
    guard node is Object(thread) else { continue }
    let is_resolved = match thread.get("isResolved") {
      Some(True) => true
      _ => false
    }
    if is_resolved {
      continue
    }
    let thread_id = match thread.get("id") {
      Some(String(v)) => v
      _ => ""
    }
    let path = match thread.get("path") {
      Some(String(v)) => v
      _ => ""
    }
    let body = match thread.get("comments") {
      Some(Object(comments)) =>
        match comments.get("nodes") {
          Some(Array(comment_nodes)) =>
            if comment_nodes.length() > 0 {
              match comment_nodes[0] {
                Object(c) =>
                  match c.get("body") {
                    Some(String(v)) => v
                    _ => ""
                  }
                _ => ""
              }
            } else {
              ""
            }
          _ => ""
        }
      _ => ""
    }
    if count > 0 {
      parts.write_string("\n---\n")
    }
    if thread_id != "" {
      parts.write_string("[thread:" + thread_id + "] ")
    }
    if path != "" {
      parts.write_string("[" + path + "] ")
    }
    if body != "" {
      parts.write_string(body)
    } else {
      parts.write_string("(no body)")
    }
    count = count + 1
  }
  (count, parts.to_string())
}

///|
pub fn parse_gh_repo_view_output(json_str : String) -> (String, String)? {
  let json = @json.parse(json_str) catch { _ => return None }
  guard json is Object(root) else { return None }
  let owner = match root.get("owner") {
    Some(Object(owner_obj)) =>
      match owner_obj.get("login") {
        Some(String(v)) => v
        _ => return None
      }
    _ => return None
  }
  let repo = match root.get("name") {
    Some(String(v)) => v
    _ => return None
  }
  Some((owner, repo))
}

///|
async fn fetch_gh_repo_owner_name(project_dir : String) -> (String, String)? {
  let cmd : @workspace.Command = {
    program: "gh",
    args: ["repo", "view", "--json", "owner,name"],
    workdir: Some(project_dir),
  }
  let (exit_code, output) = capture_command_output(cmd)
  if exit_code != 0 || output.trim().to_string() == "" {
    return None
  }
  parse_gh_repo_view_output(output)
}

///|
/// Fetch unresolved review threads for a PR via GitHub GraphQL.
/// Returns (count, formatted_text_with_thread_ids).
/// Fails gracefully: returns (0, "") if gh is unavailable or the call fails.
/// Owner/repo are resolved explicitly via gh repo view to avoid relying on
/// {owner}/{repo} substitution inside the GraphQL query body.
async fn fetch_unresolved_review_threads(
  pr_number : Int,
  project_dir : String,
) -> (Int, String) {
  let (owner, repo) = match fetch_gh_repo_owner_name(project_dir) {
    Some(pair) => pair
    None => return (0, "")
  }
  let query = "query($owner: String!, $repo: String!, $pr: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { reviewThreads(first: 100) { nodes { id isResolved path comments(first: 1) { nodes { body } } } } } } }"
  let cmd : @workspace.Command = {
    program: "gh",
    args: [
      "api",
      "graphql",
      "-f",
      "query=" + query,
      "-F",
      "owner=" + owner,
      "-F",
      "repo=" + repo,
      "-F",
      "pr=" + pr_number.to_string(),
    ],
    workdir: Some(project_dir),
  }
  let (exit_code, output) = capture_command_output(cmd)
  if exit_code != 0 || output.trim().to_string() == "" {
    return (0, "")
  }
  parse_unresolved_threads_response(output)
}

///|
fn json_get_string(obj : Map[String, Json], key : String) -> String? {
  match obj.get(key) {
    Some(String(v)) => Some(v)
    _ => None
  }
}

///|
fn parse_task_file(content : String) -> Result[TaskFile, String] {
  let json = @json.parse(content) catch { _ => return Err("invalid task json") }
  guard json is Object(fields) else { return Err("invalid task json") }
  let id = match json_get_string(fields, "id") {
    Some(v) => v
    None => return Err("missing or invalid id")
  }
  let title = match json_get_string(fields, "title") {
    Some(v) => v
    None => return Err("missing or invalid title")
  }
  let status = match json_get_string(fields, "status") {
    Some(v) => v
    None => return Err("missing or invalid status")
  }
  let assignee = match json_get_string(fields, "assignee") {
    Some(v) => v
    None => return Err("missing or invalid assignee")
  }
  let notes = match json_get_string(fields, "notes") {
    Some(v) => v
    None => return Err("missing or invalid notes")
  }
  Ok({ id, title, status, assignee, notes })
}

///|
fn task_to_json(task : TaskFile) -> Json {
  {
    "id": task.id.to_json(),
    "title": task.title.to_json(),
    "status": task.status.to_json(),
    "assignee": task.assignee.to_json(),
    "notes": task.notes.to_json(),
  }.to_json()
}

///|
fn task_file_path(project_dir : String, id : String) -> String {
  project_dir + "/.choir/tasks/" + id + ".json"
}

///|
fn kv_file_path(project_dir : String, key : String) -> String {
  project_dir + "/.choir/kv/" + key
}

///|
fn task_list_manifest_path(project_dir : String) -> String {
  project_dir + "/.choir/.task-list.paths"
}

///|
fn kv_list_manifest_path(project_dir : String) -> String {
  project_dir + "/.choir/.kv-list.paths"
}

///|
fn read_task_file(
  project_dir : String,
  id : String,
) -> Result[TaskFile, String] {
  match validate_slug(id) {
    Err(e) => return Err("invalid id: " + e)
    Ok(_) => ()
  }
  let content = @sys.read_file(task_file_path(project_dir, id))
  if content == "" {
    return Err("task not found: " + id)
  }
  match parse_task_file(content) {
    Ok(task) => Ok(task)
    Err(e) => Err("invalid task file for " + id + ": " + e)
  }
}

///|
async fn list_task_files(
  project_dir : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Result[Array[String], String] {
  let manifest_path = task_list_manifest_path(project_dir)
  let list_cmd = @workspace.Command::{
    program: "sh",
    args: [
      "-c", "[ -d \"$1/.choir/tasks\" ] || exit 3; find \"$1/.choir/tasks\" -maxdepth 1 -type f -name '*.json' | sort > \"$2\"",
      "sh", project_dir, manifest_path,
    ],
    workdir: None,
  }
  let statuses = runner([list_cmd]) catch { e => return Err(e.to_string()) }
  if statuses.length() > 0 {
    let status = statuses[statuses.length() - 1]
    if status == 3 {
      return Ok([])
    }
    if status != 0 {
      return Err("command failed with status " + status.to_string())
    }
  }
  let content = @sys.read_file(manifest_path)
  let cleanup_cmd = @workspace.Command::{
    program: "sh",
    args: ["-c", "rm -f \"$1\"", "sh", manifest_path],
    workdir: None,
  }
  ignore(runner([cleanup_cmd]) catch { _ => [] })
  let paths = []
  if content == "" {
    return Ok(paths)
  }
  for line in content.split("\n") {
    let path = line.to_string().trim().to_string()
    if path != "" {
      paths.push(path)
    }
  }
  Ok(paths)
}

///|
async fn handle_task_list(
  project_dir : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> @types.Response {
  let task_paths = match list_task_files(project_dir, runner) {
    Ok(paths) => paths
    Err(e) => return @types.Response::Err(e)
  }
  let tasks : Array[Json] = []
  for path in task_paths {
    let content = @sys.read_file(path)
    if content == "" {
      return @types.Response::Err("failed to read task file: " + path)
    }
    let task = match parse_task_file(content) {
      Ok(value) => value
      Err(e) =>
        return @types.Response::Err("invalid task file at " + path + ": " + e)
    }
    tasks.push(task_to_json(task))
  }
  @types.Response::ok_values({
    "status": "ok".to_json(),
    "tasks": tasks.to_json(),
  })
}

///|
async fn handle_kv_list(
  project_dir : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> @types.Response {
  let manifest_path = kv_list_manifest_path(project_dir)
  let list_cmd = @workspace.Command::{
    program: "sh",
    args: [
      "-c", "[ -d \"$1/.choir/kv\" ] || exit 3; find \"$1/.choir/kv\" -type f | sort > \"$2\"",
      "sh", project_dir, manifest_path,
    ],
    workdir: None,
  }
  let statuses = runner([list_cmd]) catch {
    e => return @types.Response::Err(e.to_string())
  }
  if statuses.length() > 0 {
    let status = statuses[statuses.length() - 1]
    if status == 3 {
      return @types.Response::ok_values({
        "status": "ok".to_json(),
        "keys": ([] : Array[Json]).to_json(),
      })
    }
    if status != 0 {
      return @types.Response::Err(
        "command failed with status " + status.to_string(),
      )
    }
  }
  let content = @sys.read_file(manifest_path)
  let cleanup_cmd = @workspace.Command::{
    program: "sh",
    args: ["-c", "rm -f \"$1\"", "sh", manifest_path],
    workdir: None,
  }
  ignore(runner([cleanup_cmd]) catch { _ => [] })
  let prefix = project_dir + "/.choir/kv/"
  let keys : Array[Json] = []
  for line in content.split("\n") {
    let path = line.to_string().trim().to_string()
    if path == "" {
      continue
    }
    let actual_prefix = path[:prefix.length()].to_string()
    if actual_prefix != prefix {
      return @types.Response::Err("invalid kv file path: " + path)
    }
    let key = path[prefix.length():].to_string()
    keys.push(key.to_json())
  }
  @types.Response::ok_values({
    "status": "ok".to_json(),
    "keys": keys.to_json(),
  })
}

///|
test "parse_unresolved_threads_response returns only unresolved threads" {
  let json =
    #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_abc","isResolved":false,"path":"src/foo.mbt","comments":{"nodes":[{"body":"fix this"}]}},{"id":"PRRT_def","isResolved":true,"path":"src/bar.mbt","comments":{"nodes":[{"body":"already fixed"}]}}]}}}}}
  let (count, text) = parse_unresolved_threads_response(json)
  assert_eq(count, 1)
  assert_true(text.contains("PRRT_abc"))
  assert_true(text.contains("fix this"))
  assert_false(text.contains("already fixed"))
  assert_false(text.contains("PRRT_def"))
}

///|
test "parse_unresolved_threads_response empty on all resolved" {
  let json =
    #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_xyz","isResolved":true,"path":"src/foo.mbt","comments":{"nodes":[{"body":"done"}]}}]}}}}}
  let (count, text) = parse_unresolved_threads_response(json)
  assert_eq(count, 0)
  assert_eq(text, "")
}

///|
test "parse_unresolved_threads_response empty on parse error" {
  let (count, text) = parse_unresolved_threads_response("not json")
  assert_eq(count, 0)
  assert_eq(text, "")
}

///|
test "parse_gh_repo_view_output extracts owner and repo" {
  match
    parse_gh_repo_view_output(
      "{\"owner\":{\"login\":\"brickfrog\"},\"name\":\"choir\"}",
    ) {
    Some((owner, repo)) => {
      assert_eq(owner, "brickfrog")
      assert_eq(repo, "choir")
    }
    None => fail("expected owner/repo")
  }
}

///|
test "parse_gh_repo_view_output returns None on malformed json" {
  assert_eq(parse_gh_repo_view_output("{\"owner\":{},\"name\":1}"), None)
}
