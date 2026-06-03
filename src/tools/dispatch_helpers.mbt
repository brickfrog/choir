///|

///|
fn command_diagnostic_string(cmd : @workspace.Command) -> String {
  let base = cmd.program + " (" + cmd.args.length().to_string() + " args)"
  match cmd.workdir {
    Some(_) => base + " (cwd set)"
    None => base
  }
}

///|
pub fn command_failure_message_from_output(
  status : Int,
  cmd : @workspace.Command,
  output : String,
) -> String {
  let detail = output.trim().to_owned()
  let prefix = command_diagnostic_string(cmd) +
    " failed (exit " +
    status.to_string() +
    ")"
  if detail != "" {
    prefix + ": " + detail
  } else {
    prefix
  }
}

///|
pub async fn command_failure_message(
  status : Int,
  cmd : @workspace.Command,
  capture : async (@workspace.Command) -> (Int, String),
) -> String {
  let (_, output) = capture(cmd)
  command_failure_message_from_output(status, cmd, output)
}

///|
pub async fn run_strict(
  runner : async (Array[@workspace.Command]) -> Array[Int],
  cmds : Array[@workspace.Command],
  capture? : async (@workspace.Command) -> (Int, String) = capture_command_output,
  spawn_launch_bindings? : Array[SpawnLaunchCommandBinding] = [],
  record_spawn_launch_diagnostic? : (SpawnLaunchDiagnostic) -> Unit = fn(_) {
    ()
  },
) -> Result[Unit, @types.ChoirError] {
  let statuses = runner(cmds) catch {
    e => return Err(@types.ChoirError::transport_error(e.to_string()))
  }
  let spawn_launch_captured_outputs = record_spawn_launch_diagnostics_for_commands(
    spawn_launch_bindings, cmds, statuses, capture, record_spawn_launch_diagnostic,
  )
  for i = 0; i < statuses.length(); i = i + 1 {
    let status = statuses[i]
    if status != 0 {
      // Include merged stderr when available for a useful error message.
      let cmd = cmds[i]
      let msg = match spawn_launch_captured_outputs.get(i) {
        Some(output) => command_failure_message_from_output(status, cmd, output)
        None => command_failure_message(status, cmd, capture)
      }
      return Err(@types.ChoirError::transport_error(msg))
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
async fn capture_run_strict_failure_detail(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "false" {
    (7, "seed stderr")
  } else {
    (0, "")
  }
}

///|
async test "run_strict returns first failing command index and status" {
  let result = run_strict(
    runner_run_strict_first_failure,
    [
      { program: "true", args: [], workdir: None },
      { program: "false", args: [], workdir: None },
      { program: "false", args: [], workdir: None },
    ],
    capture=capture_run_strict_failure_detail,
  )
  match result {
    Ok(_) => fail("expected run_strict failure")
    Err(e) =>
      assert_true(e.message().contains("failed") && e.message().contains("7"))
  }
}

///|
async test "run_strict failure includes command argv exit code and captured stderr" {
  let result = run_strict(
    runner_run_strict_first_failure,
    [
      { program: "true", args: [], workdir: None },
      { program: "false", args: ["--seed", "with space"], workdir: None },
    ],
    capture=capture_run_strict_failure_detail,
  )
  match result {
    Ok(_) => fail("expected run_strict failure")
    Err(e) => {
      let msg = e.message()
      assert_true(msg.contains("false (2 args)"))
      assert_true(msg.contains("exit 7"))
      assert_true(msg.contains("seed stderr"))
      assert_false(msg.contains("with space"))
    }
  }
}

///|
async test "run_strict failure redacts argument bodies from diagnostics" {
  let secret = "tcp_auth_token=super-secret-token"
  let result = run_strict(
    runner_run_strict_first_failure,
    [
      { program: "true", args: [], workdir: None },
      { program: "write-config", args: ["--body", secret], workdir: None },
    ],
    capture=async fn(_cmd) {
      @async.sleep(0)
      (7, "write failed")
    },
  )
  match result {
    Ok(_) => fail("expected run_strict failure")
    Err(e) => {
      let msg = e.message()
      assert_true(msg.contains("write-config (2 args)"))
      assert_true(msg.contains("write failed"))
      assert_false(msg.contains(secret))
      assert_false(msg.contains("--body"))
    }
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
        role: req.role.to_wire_string(),
      })
      let (_exit, resp_str) = @exec.capture_plugin_shell_command(
        plugin.command,
        request_json,
        10,
      )
      match @plugin.parse_response(resp_str) {
        Ok(result) => result
        Err(e) => @types.Response::Err("plugin error: " + e)
      }
    }
  }
}

///|

///|
/// Parse JSON from `zellij action list-panes --json -a -t -s` and return the first non-plugin
/// pane ID for `tab_name` as `terminal_N`, or None.
fn parse_zellij_tab_terminal_target_json(
  content : String,
  tab_name : String,
) -> String? {
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
/// Resolve the zellij pane ID for a named tab by running list-panes.
/// Returns Some("terminal_N") if found, None otherwise.
pub async fn resolve_zellij_tab_terminal_target(
  session : String,
  tab_name : String,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> String? {
  let cmd : @workspace.Command = {
    program: "zellij",
    args: [
      "--session", session, "action", "list-panes", "--json", "-a", "-t", "-s",
    ],
    workdir: None,
  }
  let (exit_code, content) = capture(cmd)
  if exit_code != 0 {
    return None
  }
  parse_zellij_tab_terminal_target_json(content, tab_name)
}

///|
fn resolve_home_path(path : String) -> String {
  if path.length() >= 2 && path[0] == '~' && path[1] == '/' {
    match @sys.getenv("HOME") {
      Some(home) => home + "/" + path[2:path.length()].to_owned()
      None => path
    }
  } else {
    path
  }
}

///|
/// Parent directory of `path` (POSIX `dirname` semantics for typical paths).
fn path_dirname(path : String) -> String {
  if path.length() == 0 {
    return "."
  }
  let mut end = path.length()
  while end > 1 && path[end - 1] == '/' {
    end = end - 1
  }
  let trimmed = path[:end].to_owned()
  if trimmed == "/" {
    return "/"
  }
  let mut last_slash = -1
  for i = 0; i < trimmed.length(); i = i + 1 {
    if trimmed[i] == '/' {
      last_slash = i
    }
  }
  if last_slash < 0 {
    return "."
  }
  if last_slash == 0 {
    return "/"
  }
  let mut d_end = last_slash
  while d_end > 1 && trimmed[d_end - 1] == '/' {
    d_end = d_end - 1
  }
  trimmed[:d_end].to_owned()
}

///|
fn teams_inbox_write(
  path : String,
  json : String,
) -> Result[Unit, @types.ChoirError] {
  let resolved = resolve_home_path(path)
  let dir = path_dirname(resolved)
  if !@sys.create_dir_all(dir) {
    return Err(
      @types.ChoirError::workspace_error(
        "failed to create teams inbox directory: " + dir,
      ),
    )
  }
  let line = json + "\n"
  if !@sys.append_file_sync(resolved, line) {
    return Err(
      @types.ChoirError::workspace_error(
        "failed to append to teams inbox file: " + resolved,
      ),
    )
  }
  Ok(())
}

///|
pub async fn verify_teams_delivery(
  inbox_path : String,
  message_json : String,
  fallback_target : String?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  sleep_fn? : async (Int) -> Unit = @async.sleep,
  interval_ms? : Int = 10000,
) -> Unit {
  let path = resolve_home_path(inbox_path)
  for i = 0; i < 3; i = i + 1 {
    sleep_fn(interval_ms)
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
  project_dir? : String = ".",
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> Result[Unit, @types.ChoirError] {
  fn ensure_success(
    statuses : Array[Int],
    cmd : @workspace.Command,
  ) -> Result[Unit, @types.ChoirError] {
    if statuses.length() == 0 || statuses[0] == 0 {
      Ok(())
    } else {
      Err(
        @types.ChoirError::transport_error(
          "delivery command failed (exit " +
          statuses[0].to_string() +
          "): " +
          cmd.to_string(),
        ),
      )
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
  let log_path = project_dir + "/.choir/delivery.log"
  fn log_delivery_retry(
    target : String,
    attempt : Int,
    delay_ms : Int,
    error : String,
  ) -> Unit {
    ignore(
      @sys.append_file_sync(
        log_path,
        @poller.delivery_log_line(
          "[delivery-retry] ts_ms=" +
          delivery_timestamp() +
          " target=" +
          target +
          " attempt=" +
          attempt.to_string() +
          " delay_ms=" +
          delay_ms.to_string() +
          " error=" +
          normalize_log_error(error),
        ),
      ),
    )
  }
  fn log_delivery_failure(target : String, error : String) -> Unit {
    ignore(
      @sys.append_file_sync(
        log_path,
        @poller.delivery_log_line(
          "[delivery-failed] ts_ms=" +
          delivery_timestamp() +
          " target=" +
          target +
          " error=" +
          normalize_log_error(error),
        ),
      ),
    )
  }
  fn log_delivery_success(target : String) -> Unit {
    ignore(
      @sys.append_file_sync(
        log_path,
        @poller.delivery_log_line(
          "[delivery-success] ts_ms=" +
          delivery_timestamp() +
          " target=" +
          target,
        ),
      ),
    )
  }
  async fn run_with_retries(
    cmd : @workspace.Command,
    target : String,
  ) -> Result[Unit, @types.ChoirError] {
    let backoff_ms = [1000, 2000, 4000]
    let mut last_error = @types.ChoirError::transport_error(
      "unknown delivery error",
    )
    for attempt = 0; attempt < 4; attempt = attempt + 1 {
      let mut run_threw = false
      let statuses = runner([cmd]) catch {
        e => {
          last_error = @types.ChoirError::transport_error(e.to_string())
          run_threw = true
          []
        }
      }
      let attempt_result = if run_threw {
        Err(last_error)
      } else {
        ensure_success(statuses, cmd)
      }
      match attempt_result {
        Ok(_) => {
          log_delivery_success(target)
          return Ok(())
        }
        Err(e) => last_error = e
      }
      if attempt < backoff_ms.length() {
        let retry_attempt = attempt + 1
        let delay = backoff_ms[attempt]
        log_delivery_retry(target, retry_attempt, delay, last_error.message())
        sleep_fn(delay)
      }
    }
    log_delivery_failure(target, last_error.message())
    Err(last_error)
  }
  match delivery {
    @message.DeliveryMethod::TeamsInbox(path, json, fallback_target~) =>
      match teams_inbox_write(path, json) {
        Ok(_) => {
          ignore(
            verify_teams_delivery(
              path,
              json,
              fallback_target,
              runner,
              sleep_fn~,
            ),
          )
          log_delivery_success("teams:" + path)
          Ok(())
        }
        Err(e) => Err(e)
      }
    @message.DeliveryMethod::LocalTerminalInput(target, text) => {
      let cmd = @workspace.local_send_text(target, text)
      ignore(
        @sys.append_file_sync(
          log_path,
          @poller.delivery_log_line(
            "[delivery] target=" +
            target.to_string() +
            " cmd=" +
            cmd.to_string(),
          ),
        ),
      )
      ignore(
        @sys.append_file_sync(
          log_path,
          @poller.delivery_log_line(
            "[delivery] dispatch-with-retry target=" + target.to_string(),
          ),
        ),
      )
      run_with_retries(cmd, target.to_string())
    }
    @message.DeliveryMethod::TcpPush(_, _) => Ok(()) // Phase 2
    @message.DeliveryMethod::UdsHttp(sock_path, body) => {
      let result = @uds.http_post(sock_path, body)
      if result == 0 {
        log_delivery_success("uds:" + sock_path)
        Ok(())
      } else {
        Err(
          @types.ChoirError::transport_error(
            "UDS HTTP post failed with code " + result.to_string(),
          ),
        )
      }
    }
  }
}

///|

///|
/// Parse the JSON response from `gh api graphql` for unresolved review threads.
/// `None` means the response shape was not the expected reviewThreads snapshot;
/// `Some([])` means GitHub returned a valid empty thread list.
pub fn parse_review_thread_refs_response(
  json_str : String,
) -> Array[@poller.ReviewThreadRef]? {
  let json = @json.parse(json_str) catch { _ => return None }
  guard json is Object(root) else { return None }
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
                    _ => return None
                  }
                _ => return None
              }
            _ => return None
          }
        _ => return None
      }
    _ => return None
  }
  let refs : Array[@poller.ReviewThreadRef] = []
  for node in nodes {
    guard node is Object(thread) else { return None }
    let is_resolved = match thread.get("isResolved") {
      Some(True) => true
      Some(False) => false
      _ => return None
    }
    if is_resolved {
      continue
    }
    let id = match thread.get("id") {
      Some(String(v)) => v
      _ => return None
    }
    let is_outdated = match thread.get("isOutdated") {
      Some(True) => true
      Some(False) => false
      _ => return None
    }
    let author_login = review_thread_first_comment_author_login(thread)
    if id != "" {
      refs.push({ id, is_outdated, author_login })
    }
  }
  Some(refs)
}

///|
pub(all) struct PrReviewCommitTimestamps {
  latest_review_at : String?
  latest_commit_at : String?
} derive(Debug, Eq)

///|
fn iso8601_parse_n_digits(s : String, off : Int, count : Int) -> Int64? {
  if off < 0 || count < 0 || off + count > s.length() {
    return None
  }
  let mut v = 0L
  for k = 0; k < count; k = k + 1 {
    let c = s[off + k].to_int()
    if c < 0x30 || c > 0x39 {
      return None
    }
    v = v * 10L + (c - 0x30).to_int64()
  }
  Some(v)
}

///|
fn iso8601_has_char_at(s : String, off : Int, code : Int) -> Bool {
  off >= 0 && off < s.length() && s[off].to_int() == code
}

///|
fn iso8601_is_leap_year(year : Int64) -> Bool {
  (year % 4L == 0L && year % 100L != 0L) || year % 400L == 0L
}

///|
fn iso8601_days_in_month(year : Int64, month : Int64) -> Int64 {
  if month == 2L {
    if iso8601_is_leap_year(year) {
      29L
    } else {
      28L
    }
  } else if month == 4L || month == 6L || month == 9L || month == 11L {
    30L
  } else {
    31L
  }
}

///|
fn iso8601_has_utc_suffix(s : String) -> Bool {
  let len = s.length()
  if len == 20 {
    return iso8601_has_char_at(s, 19, 0x5a)
  }
  if len < 22 {
    return false
  }
  if !iso8601_has_char_at(s, 19, 0x2e) || !iso8601_has_char_at(s, len - 1, 0x5a) {
    return false
  }
  for i = 20; i < len - 1; i = i + 1 {
    let c = s[i].to_int()
    if c < 0x30 || c > 0x39 {
      return false
    }
  }
  true
}

///|
pub fn iso8601_to_epoch_seconds(s : String) -> Int64? {
  if s.length() < 20 {
    return None
  }
  if !iso8601_has_char_at(s, 4, 0x2d) ||
    !iso8601_has_char_at(s, 7, 0x2d) ||
    !iso8601_has_char_at(s, 10, 0x54) ||
    !iso8601_has_char_at(s, 13, 0x3a) ||
    !iso8601_has_char_at(s, 16, 0x3a) ||
    !iso8601_has_utc_suffix(s) {
    return None
  }
  let year = match iso8601_parse_n_digits(s, 0, 4) {
    Some(v) => v
    None => return None
  }
  let month = match iso8601_parse_n_digits(s, 5, 2) {
    Some(v) => v
    None => return None
  }
  let day = match iso8601_parse_n_digits(s, 8, 2) {
    Some(v) => v
    None => return None
  }
  let hour = match iso8601_parse_n_digits(s, 11, 2) {
    Some(v) => v
    None => return None
  }
  let minute = match iso8601_parse_n_digits(s, 14, 2) {
    Some(v) => v
    None => return None
  }
  let second = match iso8601_parse_n_digits(s, 17, 2) {
    Some(v) => v
    None => return None
  }
  if month < 1L || month > 12L {
    return None
  }
  if day < 1L || day > iso8601_days_in_month(year, month) {
    return None
  }
  if hour > 23L || minute > 59L || second > 59L {
    return None
  }
  // Days from civil - Howard Hinnant's algorithm. Inputs in proleptic
  // Gregorian; output is days since 1970-01-01.
  let y = if month <= 2L { year - 1L } else { year }
  let era = if y >= 0L { y / 400L } else { (y - 399L) / 400L }
  let yoe = y - era * 400L
  let m_adj = if month > 2L { month - 3L } else { month + 9L }
  let doy = (153L * m_adj + 2L) / 5L + day - 1L
  let doe = yoe * 365L + yoe / 4L - yoe / 100L + doy
  let days = era * 146097L + doe - 719468L
  Some(days * 86400L + hour * 3600L + minute * 60L + second)
}

///|
pub fn parse_pr_review_commit_timestamps_response(
  json_str : String,
) -> PrReviewCommitTimestamps? {
  let json = @json.parse(json_str) catch { _ => return None }
  guard json is Object(root) else { return None }
  let pr = match root.get("data") {
    Some(Object(data)) =>
      match data.get("repository") {
        Some(Object(repo)) =>
          match repo.get("pullRequest") {
            Some(Object(pr)) => pr
            _ => return None
          }
        _ => return None
      }
    _ => return None
  }
  let latest_review_at = match pr.get("latestReviews") {
    Some(Object(reviews)) =>
      match reviews.get("nodes") {
        Some(Array(nodes)) =>
          if nodes.length() == 0 {
            None
          } else {
            match nodes[0] {
              Object(review) =>
                match review.get("submittedAt") {
                  Some(String(value)) => Some(value)
                  _ => return None
                }
              _ => return None
            }
          }
        _ => return None
      }
    _ => return None
  }
  let latest_commit_at = match pr.get("commits") {
    Some(Object(commits)) =>
      match commits.get("nodes") {
        Some(Array(nodes)) =>
          if nodes.length() == 0 {
            None
          } else {
            match nodes[nodes.length() - 1] {
              Object(node) =>
                match node.get("commit") {
                  Some(Object(commit)) =>
                    match commit.get("pushedDate") {
                      Some(String(value)) =>
                        if value != "" {
                          Some(value)
                        } else {
                          match commit.get("committedDate") {
                            Some(String(committed)) => Some(committed)
                            _ => return None
                          }
                        }
                      _ =>
                        match commit.get("committedDate") {
                          Some(String(committed)) => Some(committed)
                          _ => return None
                        }
                    }
                  _ => return None
                }
              _ => return None
            }
          }
        _ => return None
      }
    _ => return None
  }
  Some({ latest_review_at, latest_commit_at })
}

///|
fn review_thread_first_comment_author_login(
  thread : Map[String, Json],
) -> String {
  match thread.get("comments") {
    Some(Object(comments)) =>
      match comments.get("nodes") {
        Some(Array(nodes)) =>
          if nodes.length() == 0 {
            ""
          } else {
            match nodes[0] {
              Object(comment) =>
                match comment.get("author") {
                  Some(Object(author)) =>
                    match author.get("login") {
                      Some(String(v)) => v
                      _ => ""
                    }
                  _ => ""
                }
              _ => ""
            }
          }
        _ => ""
      }
    _ => ""
  }
}

///|
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
pub async fn fetch_gh_repo_owner_name(
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> (String, String)? {
  let cmd : @workspace.Command = {
    program: "gh",
    args: ["repo", "view", "--json", "owner,name"],
    workdir: Some(project_dir),
  }
  let (exit_code, output) = capture(cmd)
  if exit_code != 0 || output.trim().to_owned() == "" {
    return None
  }
  parse_gh_repo_view_output(output)
}

///|
pub fn bounded_gh_command(
  project_dir : String,
  gh_args : Array[String],
) -> @workspace.Command {
  @workspace.bounded_gh_command(project_dir, gh_args)
}

///|
async fn fetch_gh_repo_owner_name_bounded(
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> (String, String)? {
  let cmd = bounded_gh_command(project_dir, [
    "repo", "view", "--json", "owner,name",
  ])
  let (exit_code, output) = capture(cmd)
  if exit_code != 0 || output.trim().to_owned() == "" {
    return None
  }
  parse_gh_repo_view_output(output)
}

///|
/// Fetch inline code review comments for a PR.
/// Returns (count, formatted_text).
/// Resolves owner/repo explicitly via gh repo view.
pub async fn fetch_inline_comments(
  pr_number : Int,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> (Int, String) {
  let (owner, repo) = match fetch_gh_repo_owner_name(project_dir, capture) {
    Some(pair) => pair
    None => return (0, "")
  }
  let cmd : @workspace.Command = {
    program: "gh",
    args: [
      "api",
      "repos/" +
      owner +
      "/" +
      repo +
      "/pulls/" +
      pr_number.to_string() +
      "/comments",
      "--jq",
      "[.[] | {path, body}]",
    ],
    workdir: Some(project_dir),
  }
  let (exit_code, output) = capture(cmd)
  if exit_code != 0 {
    return (0, "")
  }
  let trimmed = output.trim().to_owned()
  if trimmed == "" || trimmed == "[]" {
    return (0, "")
  }
  let json = @json.parse(trimmed) catch { _ => return (0, "") }
  let arr = match json {
    Array(items) => items
    _ => return (0, "")
  }
  let parts = StringBuilder::new()
  let mut count = 0
  for item in arr {
    match item {
      Object(c) => {
        let path = match c.get("path") {
          Some(String(v)) => v
          _ => ""
        }
        let body = match c.get("body") {
          Some(String(v)) => v
          _ => ""
        }
        if body != "" {
          if count > 0 {
            parts.write_string("\n---\n")
          }
          if path != "" {
            parts.write_string("[")
            parts.write_string(path)
            parts.write_string("] ")
          }
          parts.write_string(body)
          count = count + 1
        }
      }
      _ => ()
    }
  }
  (count, parts.to_string())
}

///|
/// Returned as the formatted body when `gh` cannot resolve owner/repo or the
/// GraphQL thread query fails (fail-closed path).
pub let review_thread_fetch_failed_marker : String = "[thread-fetch-failed: treating as unresolved]"

///|
/// Fetch unresolved review threads for a PR via GitHub GraphQL, given a
/// pre-resolved `(owner, repo)` pair. Prefer this variant when making
/// multiple calls in a single snapshot (e.g. `wave_state`) so `gh repo view`
/// is invoked once rather than once per PR.
pub async fn fetch_unresolved_review_threads_with_repo(
  pr_number : Int,
  owner : String,
  repo : String,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> (Int, String) {
  let query = "query($owner: String!, $repo: String!, $pr: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { reviewThreads(first: 100) { nodes { id isResolved isOutdated path comments(first: 1) { nodes { body } } } } } } }"
  let cmd = bounded_gh_command(project_dir, [
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
  ])
  let (exit_code, output) = capture(cmd)
  if exit_code != 0 || output.trim().to_owned() == "" {
    return (1, review_thread_fetch_failed_marker)
  }
  parse_unresolved_threads_response(output)
}

///|
pub async fn fetch_unresolved_review_thread_refs_with_repo(
  pr_number : Int,
  owner : String,
  repo : String,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Array[@poller.ReviewThreadRef]? {
  let query = "query($owner: String!, $repo: String!, $pr: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { reviewThreads(first: 100) { nodes { id isResolved isOutdated comments(first: 1) { nodes { author { login } } } } } } } }"
  let cmd = bounded_gh_command(project_dir, [
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
  ])
  let (exit_code, output) = capture(cmd)
  if exit_code != 0 || output.trim().to_owned() == "" {
    return None
  }
  parse_review_thread_refs_response(output)
}

///|
pub async fn fetch_pr_review_commit_timestamps_with_repo(
  pr_number : Int,
  owner : String,
  repo : String,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> PrReviewCommitTimestamps? {
  let query = "query($owner: String!, $repo: String!, $pr: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { latestReviews(first: 1) { nodes { submittedAt } } commits(last: 1) { nodes { commit { pushedDate committedDate } } } } } } }"
  let cmd = bounded_gh_command(project_dir, [
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
  ])
  let (exit_code, output) = capture(cmd)
  if exit_code != 0 || output.trim().to_owned() == "" {
    return None
  }
  parse_pr_review_commit_timestamps_response(output)
}

///|
pub async fn fetch_pr_review_commit_timestamps(
  pr_number : Int,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> PrReviewCommitTimestamps? {
  let (owner, repo) = match
    fetch_gh_repo_owner_name_bounded(project_dir, capture) {
    Some(pair) => pair
    None => return None
  }
  fetch_pr_review_commit_timestamps_with_repo(
    pr_number, owner, repo, project_dir, capture,
  )
}

///|
pub async fn fetch_unresolved_review_thread_refs(
  pr_number : Int,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Array[@poller.ReviewThreadRef]? {
  let (owner, repo) = match
    fetch_gh_repo_owner_name_bounded(project_dir, capture) {
    Some(pair) => pair
    None => return None
  }
  fetch_unresolved_review_thread_refs_with_repo(
    pr_number, owner, repo, project_dir, capture,
  )
}

///|
/// Fetch unresolved review threads for a PR via GitHub GraphQL.
/// Returns `(count, formatted_text_with_thread_ids)`.
/// On the fail-closed paths above, returns `(1, review_thread_fetch_failed_marker)`.
/// Owner/repo are resolved via `gh repo view`.
pub async fn fetch_unresolved_review_threads(
  pr_number : Int,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> (Int, String) {
  let (owner, repo) = match
    fetch_gh_repo_owner_name_bounded(project_dir, capture) {
    Some(pair) => pair
    None => return (1, review_thread_fetch_failed_marker)
  }
  fetch_unresolved_review_threads_with_repo(
    pr_number, owner, repo, project_dir, capture,
  )
}

///|
fn task_status_from_beads(
  status : String,
) -> Result[@types.TaskStatus, @types.ChoirError] {
  match status {
    "open" | "todo" => Ok(@types.TaskStatus::Todo)
    "in_progress" => Ok(@types.TaskStatus::InProgress)
    "closed" | "done" => Ok(@types.TaskStatus::Done)
    _ =>
      Err(
        @types.ChoirError::validation_error(
          "missing or invalid status: " + status,
        ),
      )
  }
}

///|
fn task_status_to_beads(status : @types.TaskStatus) -> String {
  match status {
    Todo => "open"
    InProgress => "in_progress"
    Done => "closed"
  }
}

///|
fn parse_beads_issue_object(
  fields : Map[String, Json],
) -> Result[TaskFile, @types.ChoirError] {
  let id = match @types.json_field_string(fields, "id") {
    Some(v) => v
    None =>
      return Err(@types.ChoirError::validation_error("missing or invalid id"))
  }
  let title = match @types.json_field_string(fields, "title") {
    Some(v) => v
    None =>
      return Err(
        @types.ChoirError::validation_error("missing or invalid title"),
      )
  }
  let status_str = match @types.json_field_string(fields, "status") {
    Some(v) => v
    None =>
      return Err(
        @types.ChoirError::validation_error("missing or invalid status"),
      )
  }
  let status = match task_status_from_beads(status_str) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let assignee = @types.json_field_string(fields, "assignee").unwrap_or("")
  let notes = @types.json_field_string(fields, "notes").unwrap_or("")
  Ok({ id, title, status, assignee, notes })
}

///|
fn parse_beads_issue_json_array(
  content : String,
) -> Result[Array[TaskFile], @types.ChoirError] {
  let json = @json.parse(content) catch {
    _ => return Err(@types.ChoirError::validation_error("invalid beads json"))
  }
  guard json is Array(items) else {
    return Err(@types.ChoirError::validation_error("invalid beads json"))
  }
  let tasks : Array[TaskFile] = []
  for item in items {
    guard item is Object(fields) else {
      return Err(@types.ChoirError::validation_error("invalid beads issue"))
    }
    match parse_beads_issue_object(fields) {
      Ok(task) => tasks.push(task)
      Err(e) => return Err(e)
    }
  }
  Ok(tasks)
}

///|
fn parse_beads_issue_json_single(
  content : String,
) -> Result[TaskFile, @types.ChoirError] {
  let json = @json.parse(content) catch {
    _ => return Err(@types.ChoirError::validation_error("invalid beads json"))
  }
  match json {
    Object(fields) => parse_beads_issue_object(fields)
    Array(items) => {
      if items.length() == 0 {
        return Err(@types.ChoirError::validation_error("task not found"))
      }
      match items[0] {
        Object(fields) => parse_beads_issue_object(fields)
        _ => Err(@types.ChoirError::validation_error("invalid beads issue"))
      }
    }
    _ => Err(@types.ChoirError::validation_error("invalid beads json"))
  }
}

///|
fn task_to_json(task : TaskFile) -> Json {
  {
    "id": task.id.to_json(),
    "title": task.title.to_json(),
    "status": task.status.to_wire_string().to_json(),
    "assignee": task.assignee.to_json(),
    "notes": task.notes.to_json(),
  }.to_json()
}

///|
fn kv_file_path(project_dir : String, key : String) -> String {
  project_dir + "/.choir/kv/" + key
}

///|
/// Lexicographic sort (stable; matches GNU `sort` for typical ASCII paths).
fn sort_strings_lex(paths : Array[String]) -> Unit {
  paths.mut_view().stable_sort()
}

///|
fn beads_error(command : String, exit_code : Int, output : String) -> String {
  let detail = output.trim().to_owned()
  if detail == "" {
    "bd " + command + " failed with status " + exit_code.to_string()
  } else {
    "bd " +
    command +
    " failed with status " +
    exit_code.to_string() +
    ": " +
    detail
  }
}

///|
async fn capture_beads_json(
  project_dir : String,
  command : String,
  args : Array[String],
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[String, @types.ChoirError] {
  let (exit_code, output) = capture({
    program: "bd",
    args,
    workdir: Some(project_dir),
  })
  if exit_code != 0 {
    return Err(
      @types.ChoirError::transport_error(
        beads_error(command, exit_code, output),
      ),
    )
  }
  Ok(output)
}

///|
async fn handle_task_list(
  project_dir : String,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> @types.Response {
  let output = match
    capture_beads_json(
      project_dir,
      "list",
      ["list", "--json", "--all"],
      capture,
    ) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  let parsed = match parse_beads_issue_json_array(output) {
    Ok(tasks) => tasks
    Err(e) => return @types.Response::Err(e.message())
  }
  let tasks : Array[Json] = []
  for task in parsed {
    tasks.push(task_to_json(task))
  }
  @types.Response::ok_values({
    "status": "ok".to_json(),
    "tasks": tasks.to_json(),
  })
}

///|
async fn handle_task_get(
  project_dir : String,
  id : String,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> @types.Response {
  let output = match
    capture_beads_json(project_dir, "show", ["show", id, "--json"], capture) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  match parse_beads_issue_json_single(output) {
    Ok(task) =>
      @types.Response::ok_values({
        "status": String::to_json("ok"),
        "task": task_to_json(task),
      })
    Err(e) => @types.Response::Err(e.message())
  }
}

///|
async fn handle_task_create(
  project_dir : String,
  task_args : TaskCreateArgs,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> @types.Response {
  let existing = capture({
    program: "bd",
    args: ["show", task_args.id, "--json"],
    workdir: Some(project_dir),
  })
  if existing.0 == 0 {
    return match parse_beads_issue_json_single(existing.1) {
      Ok(task) =>
        @types.Response::ok_values({
          "status": String::to_json("ok"),
          "created": Bool::to_json(false),
          "task": task_to_json(task),
        })
      Err(e) => @types.Response::Err(e.message())
    }
  }
  let create_args : Array[String] = [
    "create",
    task_args.title,
    "--id",
    task_args.id,
    "--force",
    "--type",
    "task",
    "--priority",
    "2",
    "--json",
  ]
  if task_args.assignee != "" {
    create_args.push("--assignee")
    create_args.push(task_args.assignee)
  }
  if task_args.notes != "" {
    create_args.push("--notes")
    create_args.push(task_args.notes)
  }
  let created_output = match
    capture_beads_json(project_dir, "create", create_args, capture) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  let task = match parse_beads_issue_json_single(created_output) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  let final_task = if task_args.status == @types.TaskStatus::Todo {
    task
  } else {
    let update_args = [
      "update",
      task_args.id,
      "--status",
      task_status_to_beads(task_args.status),
      "--json",
    ]
    let updated_output = match
      capture_beads_json(project_dir, "update", update_args, capture) {
      Ok(value) => value
      Err(e) => return @types.Response::Err(e.message())
    }
    match parse_beads_issue_json_single(updated_output) {
      Ok(value) => value
      Err(e) => return @types.Response::Err(e.message())
    }
  }
  @types.Response::ok_values({
    "status": String::to_json("ok"),
    "created": Bool::to_json(true),
    "task": task_to_json(final_task),
  })
}

///|
async fn handle_task_update(
  project_dir : String,
  update_args : TaskUpdateArgs,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> @types.Response {
  if update_args.status is None &&
    update_args.assignee is None &&
    update_args.notes is None {
    return handle_task_get(project_dir, update_args.id, capture~)
  }
  let args : Array[String] = ["update", update_args.id]
  match update_args.status {
    Some(status) => {
      args.push("--status")
      args.push(task_status_to_beads(status))
    }
    None => ()
  }
  match update_args.assignee {
    Some(assignee) => {
      args.push("--assignee")
      args.push(assignee)
    }
    None => ()
  }
  match update_args.notes {
    Some(notes) => {
      args.push("--notes")
      args.push(notes)
    }
    None => ()
  }
  args.push("--json")
  let output = match capture_beads_json(project_dir, "update", args, capture) {
    Ok(value) => value
    Err(e) => return @types.Response::Err(e.message())
  }
  match parse_beads_issue_json_single(output) {
    Ok(task) =>
      @types.Response::ok_values({
        "status": String::to_json("ok"),
        "task": task_to_json(task),
      })
    Err(e) => @types.Response::Err(e.message())
  }
}

///|
async fn handle_kv_list(
  project_dir : String,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> @types.Response {
  let kv_dir = project_dir + "/.choir/kv"
  let test_cmd : @workspace.Command = {
    program: "test",
    args: ["-d", kv_dir],
    workdir: None,
  }
  let (test_status, _) = capture(test_cmd)
  if test_status != 0 {
    return @types.Response::ok_values({
      "status": "ok".to_json(),
      "keys": ([] : Array[Json]).to_json(),
    })
  }
  let find_cmd : @workspace.Command = {
    program: "find",
    args: [kv_dir, "-type", "f"],
    workdir: None,
  }
  let (find_status, output) = capture(find_cmd)
  if find_status != 0 {
    return @types.Response::Err(
      "command failed with status " + find_status.to_string(),
    )
  }
  let prefix = project_dir + "/.choir/kv/"
  let paths : Array[String] = []
  for line in output.split("\n") {
    let path = line.to_owned().trim().to_owned()
    if path == "" {
      continue
    }
    paths.push(path)
  }
  sort_strings_lex(paths)
  let keys : Array[Json] = []
  for path in paths {
    let actual_prefix = path[:prefix.length()].to_owned()
    if actual_prefix != prefix {
      return @types.Response::Err("invalid kv file path: " + path)
    }
    let key = path[prefix.length():].to_owned()
    keys.push(key.to_json())
  }
  @types.Response::ok_values({
    "status": "ok".to_json(),
    "keys": keys.to_json(),
  })
}

///|
test "parse_zellij_tab_terminal_target_json matches tab and returns terminal id" {
  let json =
    #|[{"id":3,"tab_name":"leaf-1","is_plugin":false},{"id":9,"tab_name":"other","is_plugin":false}]
  match parse_zellij_tab_terminal_target_json(json, "leaf-1") {
    Some(s) => assert_eq(s, "terminal_3")
    None => fail("expected pane")
  }
}

///|
test "parse_zellij_tab_terminal_target_json skips plugin panes" {
  let json =
    #|[{"id":1,"tab_name":"leaf-1","is_plugin":true},{"id":2,"tab_name":"leaf-1","is_plugin":false}]
  match parse_zellij_tab_terminal_target_json(json, "leaf-1") {
    Some(s) => assert_eq(s, "terminal_2")
    None => fail("expected non-plugin pane")
  }
}

///|
test "parse_zellij_tab_terminal_target_json returns None when tab missing" {
  @debug.assert_eq(
    parse_zellij_tab_terminal_target_json(
      "[{\"id\":1,\"tab_name\":\"x\",\"is_plugin\":false}]", "missing",
    ),
    None,
  )
}

///|
async fn mock_zellij_pane_ok(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  if cmd.program != "zellij" {
    return (-1, "")
  }
  assert_eq(cmd.args[1], "choir")
  (0, "[{\"id\":7,\"tab_name\":\"slug-a\",\"is_plugin\":false}]")
}

///|
async test "resolve_zellij_tab_terminal_target uses zellij argv and capture" {
  match
    resolve_zellij_tab_terminal_target(
      "choir",
      "slug-a",
      capture=mock_zellij_pane_ok,
    ) {
    Some(s) => assert_eq(s, "terminal_7")
    None => fail("expected pane id")
  }
}

///|
async fn mock_zellij_nonzero(_cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  (1, "[{\"id\":1,\"tab_name\":\"x\",\"is_plugin\":false}]")
}

///|
async test "resolve_zellij_tab_terminal_target returns None when zellij exits non-zero" {
  @debug.assert_eq(
    resolve_zellij_tab_terminal_target(
      "choir",
      "x",
      capture=mock_zellij_nonzero,
    ),
    None,
  )
}

///|
test "path_dirname matches posix dirname" {
  assert_eq(path_dirname("/a/b/c"), "/a/b")
  assert_eq(path_dirname("/a/b"), "/a")
  assert_eq(path_dirname("/a"), "/")
  assert_eq(path_dirname("a/b/c"), "a/b")
  assert_eq(path_dirname("a/b"), "a")
  assert_eq(path_dirname("a"), ".")
  assert_eq(path_dirname("/"), "/")
}

///|
test "teams_inbox_write creates parent and appends json line" {
  let base = "/tmp/choir-teams-inbox-native-" +
    @sys.get_pid().to_string() +
    "/agent"
  let path = base + "/inboxes/default.json"
  let json = "{\"from\":\"x\",\"content\":\"y\",\"status\":\"z\"}"
  match teams_inbox_write(path, json) {
    Ok(_) => ()
    Err(e) => fail(e.message())
  }
  let got = @sys.read_file(path)
  assert_true(got.contains(json))
  assert_true(got.has_suffix("\n"))
  ignore(@sys.delete_file_sync(path))
}

///|
test "sort_strings_lex orders paths lexicographically" {
  let paths = ["b", "a", "c"]
  sort_strings_lex(paths)
  assert_eq(paths.length(), 3)
  assert_eq(paths[0], "a")
  assert_eq(paths[1], "b")
  assert_eq(paths[2], "c")
}

///|
async fn mock_beads_list_capture(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  assert_eq(cmd.program, "bd")
  @debug.assert_eq(cmd.args, ["list", "--json", "--all"])
  @debug.assert_eq(cmd.workdir, Some("/proj"))
  let output =
    #|[
    #|  {"id":"choir-a","title":"A","status":"open","assignee":"claude","notes":"n"},
    #|  {"id":"choir-b","title":"B","status":"closed"}
    #|]
  (0, output)
}

///|
async test "handle_task_list reads Beads JSON through capture" {
  match handle_task_list("/proj", capture=mock_beads_list_capture) {
    @types.Response::Ok(fields) =>
      match fields.get_json("tasks") {
        Some(Array(tasks)) => {
          assert_eq(tasks.length(), 2)
          match tasks[0] {
            Object(task) => {
              @debug.assert_eq(
                @types.json_field_string(task, "id"),
                Some("choir-a"),
              )
              @debug.assert_eq(
                @types.json_field_string(task, "status"),
                Some("todo"),
              )
              @debug.assert_eq(
                @types.json_field_string(task, "assignee"),
                Some("claude"),
              )
              @debug.assert_eq(
                @types.json_field_string(task, "notes"),
                Some("n"),
              )
            }
            _ => fail("expected task object")
          }
          match tasks[1] {
            Object(task) =>
              @debug.assert_eq(
                @types.json_field_string(task, "status"),
                Some("done"),
              )
            _ => fail("expected task object")
          }
        }
        _ => fail("expected tasks array")
      }
    @types.Response::Err(e) => fail(e)
  }
}

///|
async fn mock_beads_create_capture(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  assert_eq(cmd.program, "bd")
  @debug.assert_eq(cmd.workdir, Some("/proj"))
  if cmd.args == ["show", "local-task", "--json"] {
    return (1, "{\"error\":\"not found\"}")
  }
  @debug.assert_eq(cmd.args, [
    "create", "Local task", "--id", "local-task", "--force", "--type", "task", "--priority",
    "2", "--json", "--assignee", "codex", "--notes", "details",
  ])
  let output =
    #|{"id":"local-task","title":"Local task","status":"open","assignee":"codex","notes":"details"}
  (0, output)
}

///|
async test "handle_task_create creates explicit Beads id with force" {
  match
    handle_task_create(
      "/proj",
      {
        id: "local-task",
        title: "Local task",
        status: @types.TaskStatus::Todo,
        assignee: "codex",
        notes: "details",
      },
      capture=mock_beads_create_capture,
    ) {
    @types.Response::Ok(fields) => {
      @debug.assert_eq(fields.get_bool("created"), Some(true))
      match fields.get_json("task") {
        Some(Object(task)) =>
          @debug.assert_eq(
            @types.json_field_string(task, "id"),
            Some("local-task"),
          )
        _ => fail("expected task")
      }
    }
    @types.Response::Err(e) => fail(e)
  }
}

///|
async fn mock_beads_create_in_progress_capture(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  assert_eq(cmd.program, "bd")
  @debug.assert_eq(cmd.workdir, Some("/proj"))
  if cmd.args == ["show", "progress-task", "--json"] {
    return (1, "")
  }
  if cmd.args ==
    [
      "create", "Progress task", "--id", "progress-task", "--force", "--type", "task",
      "--priority", "2", "--json", "--notes", "details",
    ] {
    let output =
      #|{"id":"progress-task","title":"Progress task","status":"open","notes":"details"}
    return (0, output)
  }
  @debug.assert_eq(cmd.args, [
    "update", "progress-task", "--status", "in_progress", "--json",
  ])
  let output =
    #|[{"id":"progress-task","title":"Progress task","status":"in_progress","notes":"details"}]
  (0, output)
}

///|
async test "handle_task_create updates new Beads task to in_progress" {
  match
    handle_task_create(
      "/proj",
      {
        id: "progress-task",
        title: "Progress task",
        status: @types.TaskStatus::InProgress,
        assignee: "",
        notes: "details",
      },
      capture=mock_beads_create_in_progress_capture,
    ) {
    @types.Response::Ok(fields) => {
      @debug.assert_eq(fields.get_bool("created"), Some(true))
      match fields.get_json("task") {
        Some(Object(task)) => {
          @debug.assert_eq(
            @types.json_field_string(task, "id"),
            Some("progress-task"),
          )
          @debug.assert_eq(
            @types.json_field_string(task, "status"),
            Some("in_progress"),
          )
        }
        _ => fail("expected task")
      }
    }
    @types.Response::Err(e) => fail(e)
  }
}

///|
async fn poison_beads_dispatch_capture(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  let poisoned_output =
    #|Warning: auto-export: git add failed: exit status 1
    #|{"id":"progress-task","title":"Progress task","status":"in_progress","notes":"details"}
  if cmd.program == "bd" {
    return (0, poisoned_output)
  }
  (0, "")
}

///|
async test "dispatch_call routes task_create Beads commands through bd_capture" {
  let call = ToolCall::{
    role: @types.Role::TL,
    name: "task_create",
    args: {
      "id": "progress-task",
      "title": "Progress task",
      "status": "in_progress",
      "notes": "details",
    },
  }
  match
    dispatch_call(
      call,
      project_dir="/proj",
      capture=poison_beads_dispatch_capture,
      bd_capture=mock_beads_create_in_progress_capture,
    ) {
    @types.Response::Ok(fields) => {
      @debug.assert_eq(fields.get_bool("created"), Some(true))
      match fields.get_json("task") {
        Some(Object(task)) => {
          @debug.assert_eq(
            @types.json_field_string(task, "id"),
            Some("progress-task"),
          )
          @debug.assert_eq(
            @types.json_field_string(task, "status"),
            Some("in_progress"),
          )
        }
        _ => fail("expected task")
      }
    }
    @types.Response::Err(e) => fail(e)
  }
}

///|
async fn fail_on_beads_dispatch_capture(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "bd" {
    fail("bd command used default capture: " + cmd.to_string())
  }
  (0, "")
}

///|
async fn clean_beads_show_capture(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  assert_eq(cmd.program, "bd")
  @debug.assert_eq(cmd.workdir, Some("/proj"))
  @debug.assert_eq(cmd.args, ["show", "shown-task", "--json"])
  let output =
    #|{"id":"shown-task","title":"Shown task","status":"in_progress","assignee":"codex","notes":"visible"}
  (0, output)
}

///|
async test "dispatch_call routes task_get Beads commands through bd_capture" {
  let call = ToolCall::{
    role: @types.Role::TL,
    name: "task_get",
    args: { "id": "shown-task" },
  }
  match
    dispatch_call(
      call,
      project_dir="/proj",
      capture=fail_on_beads_dispatch_capture,
      bd_capture=clean_beads_show_capture,
    ) {
    @types.Response::Ok(fields) =>
      match fields.get_json("task") {
        Some(Object(task)) => {
          @debug.assert_eq(
            @types.json_field_string(task, "id"),
            Some("shown-task"),
          )
          @debug.assert_eq(
            @types.json_field_string(task, "title"),
            Some("Shown task"),
          )
          @debug.assert_eq(
            @types.json_field_string(task, "status"),
            Some("in_progress"),
          )
          @debug.assert_eq(
            @types.json_field_string(task, "assignee"),
            Some("codex"),
          )
          @debug.assert_eq(
            @types.json_field_string(task, "notes"),
            Some("visible"),
          )
        }
        _ => fail("expected task")
      }
    @types.Response::Err(e) => fail(e)
  }
}

///|
async fn mock_beads_update_capture(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  assert_eq(cmd.program, "bd")
  @debug.assert_eq(cmd.workdir, Some("/proj"))
  @debug.assert_eq(cmd.args, [
    "update", "choir-a", "--status", "closed", "--assignee", "claude", "--notes",
    "merged", "--json",
  ])
  let output =
    #|[{"id":"choir-a","title":"A","status":"closed","assignee":"claude","notes":"merged"}]
  (0, output)
}

///|
async test "handle_task_update maps done to Beads closed" {
  match
    handle_task_update(
      "/proj",
      {
        id: "choir-a",
        status: Some(@types.TaskStatus::Done),
        assignee: Some("claude"),
        notes: Some("merged"),
      },
      capture=mock_beads_update_capture,
    ) {
    @types.Response::Ok(fields) =>
      match fields.get_json("task") {
        Some(Object(task)) =>
          @debug.assert_eq(
            @types.json_field_string(task, "status"),
            Some("done"),
          )
        _ => fail("expected task")
      }
    @types.Response::Err(e) => fail(e)
  }
}

///|
async fn mock_kv_list_capture(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "test" {
    @debug.assert_eq(cmd.args, ["-d", "/p/.choir/kv"])
    return (0, "")
  }
  if cmd.program == "find" {
    @debug.assert_eq(cmd.args, ["/p/.choir/kv", "-type", "f"])
    return (0, "/p/.choir/kv/b\n/p/.choir/kv/a\n")
  }
  (-1, "")
}

///|
async test "handle_kv_list uses test and find argv and sorts keys" {
  match handle_kv_list("/p", capture=mock_kv_list_capture) {
    @types.Response::Ok(fields) =>
      match fields.get_json("keys") {
        Some(Array(ks)) => {
          assert_eq(ks.length(), 2)
          match (ks[0], ks[1]) {
            (String(a), String(b)) => {
              assert_eq(a, "a")
              assert_eq(b, "b")
            }
            _ => fail("expected string keys")
          }
        }
        _ => fail("expected keys array")
      }
    @types.Response::Err(e) => fail(e)
  }
}

///|
async fn mock_inline_comments_two_items(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "gh" && cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"brickfrog\"},\"name\":\"choir\"}")
  }
  (
    0, "[{\"path\":\"src/foo.mbt\",\"body\":\"please fix\"},{\"path\":\"\",\"body\":\"general comment\"}]",
  )
}

///|
async test "fetch_inline_comments parses two comments" {
  let (count, text) = fetch_inline_comments(
    7, "/repo", mock_inline_comments_two_items,
  )
  assert_eq(count, 2)
  assert_true(text.contains("please fix"))
  assert_true(text.contains("general comment"))
  assert_true(text.contains("[src/foo.mbt]"))
}

///|
async fn mock_inline_comments_empty_arr(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "gh" && cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"brickfrog\"},\"name\":\"choir\"}")
  }
  (0, "[]")
}

///|
async test "fetch_inline_comments returns zero for empty array" {
  let (count, text) = fetch_inline_comments(
    1, "/repo", mock_inline_comments_empty_arr,
  )
  assert_eq(count, 0)
  assert_eq(text, "")
}

///|
async fn mock_inline_comments_gh_failure(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "gh" && cmd.args.contains("repo") {
    return (0, "{\"owner\":{\"login\":\"brickfrog\"},\"name\":\"choir\"}")
  }
  (1, "gh: error fetching")
}

///|
async test "fetch_inline_comments returns zero on non-zero exit" {
  let (count, _) = fetch_inline_comments(
    99, "/repo", mock_inline_comments_gh_failure,
  )
  assert_eq(count, 0)
}
