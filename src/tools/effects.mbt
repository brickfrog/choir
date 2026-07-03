///|
/// Typed errors for the fork_wave execution path.
/// Variants carry structured data — callers match on the constructor,
/// not on substrings of a message.
pub(all) enum ForkWaveError {
  /// Working tree has uncommitted or staged changes.
  /// `output` is the raw `git status --porcelain` output.
  UncommittedChanges(output~ : String)
  /// Local commits exist that haven't been pushed.
  /// `output` is the raw `git log @{u}..HEAD` output.
  UnpushedCommits(output~ : String)
  /// Dirty paths outside scaffold_commit.paths exist before scaffold commit.
  ScaffoldCommitUnrelatedChanges(output~ : String)
  /// A scaffold_commit path has no working-tree/index change to commit.
  ScaffoldCommitPathUnchanged(path~ : String)
  /// A scaffold_commit git command exited with a non-zero status.
  ScaffoldCommandFailed(status~ : Int, failing_cmd~ : @workspace.Command?)
  /// Compensation after a successful scaffold commit failed; manual recovery
  /// is required because the parent branch may still contain the scaffold commit.
  ScaffoldCompensationFailed(
    pre_scaffold_sha~ : String,
    original_error~ : String,
    status~ : Int,
    failing_cmd~ : @workspace.Command?
  )
  /// HEAD is on a different branch than the requested parent_branch.
  /// scaffold_commit refuses to push: it would mutate the wrong branch.
  ScaffoldBranchMismatch(expected~ : String, actual~ : String)
  /// A spawn command exited with a non-zero status.
  CommandFailed(status~ : Int, failing_cmd~ : @workspace.Command?)
} derive(Debug, Eq)

///|
pub fn ForkWaveError::message(self : ForkWaveError) -> String {
  match self {
    UncommittedChanges(output~) =>
      "Working tree has uncommitted changes. Commit and push your scaffold work first, then call fork_wave.\n" +
      output.trim().to_owned()
    UnpushedCommits(output~) =>
      "Unpushed commits exist. Run 'git push' first, then call fork_wave.\n" +
      output.trim().to_owned()
    ScaffoldCommitUnrelatedChanges(output~) =>
      "scaffold_commit requires only scaffold paths to be dirty. Unrelated changes:\n" +
      output.trim().to_owned()
    ScaffoldCommitPathUnchanged(path~) =>
      "scaffold_commit path has no changes or does not exist: " + path
    ScaffoldCommandFailed(status~, ..) =>
      "scaffold_commit command failed with status " + status.to_string()
    ScaffoldCompensationFailed(pre_scaffold_sha~, original_error~, status~, ..) =>
      "scaffold_commit compensation failed after post-scaffold error (" +
      original_error +
      "). Manual recovery required: first inspect the remote parent branch and confirm no concurrent commits would be discarded; if the scaffold commit is still the only remote change to rewind, run `git reset --hard " +
      pre_scaffold_sha +
      "` and `git push --force-with-lease`. Do not force-push blindly: even force-with-lease can discard commits pushed after the scaffold. Compensation command failed with status " +
      status.to_string()
    ScaffoldBranchMismatch(expected~, actual~) =>
      "scaffold_commit refused: HEAD is on '" +
      actual +
      "' but parent_branch is '" +
      expected +
      "'. Check out '" +
      expected +
      "' before calling fork_wave with scaffold_commit."
    CommandFailed(status~, ..) =>
      "command failed with status " + status.to_string()
  }
}

///|
/// A description of side-effectful operations, parameterized by result type A.
///
/// Values of this type are pure data — no I/O occurs until fed to `interpret`.
/// This mirrors the exomonad pattern: Haskell yields effect descriptions,
/// Rust executes them. Here MoonBit yields `Eff[A]` trees, the async
/// interpreter executes them.
///
/// Usage:
///   let plan = fork_wave_plan(...)        // pure — no async, no IO
///   let resp = interpret(plan, runner~)   // async — executes the IO
pub(all) enum Eff[A] {
  /// Computation is complete.
  Pure(A)
  /// Capture stdout of a command, then continue with the result.
  GitCapture(
    program~ : String,
    args~ : Array[String],
    cont~ : (String) -> Eff[A]
  )
  /// Run a sequence of workspace commands, then continue with exit codes.
  RunCommands(cmds~ : Array[@workspace.Command], cont~ : (Array[Int]) -> Eff[A])
}

///|
fn command_arg_value(args : Array[String], flag : String) -> String? {
  for i = 0; i + 1 < args.length(); i = i + 1 {
    if args[i] == flag {
      return Some(args[i + 1])
    }
  }
  None
}

///|
fn zellij_launch_action(cmd : @workspace.Command) -> String? {
  if cmd.program != "zellij" {
    return None
  }
  for arg in cmd.args {
    if arg == "new-tab" {
      return Some("new-tab")
    }
    if arg == "run" {
      return Some("run")
    }
  }
  None
}

///|
fn trace_zellij_launch_statuses(
  cmds : Array[@workspace.Command],
  statuses : Array[Int],
) -> Unit {
  for i = 0; i < cmds.length(); i = i + 1 {
    if i >= statuses.length() {
      continue
    }
    let cmd = cmds[i]
    match zellij_launch_action(cmd) {
      Some(action) => {
        let fields : Array[@moontrace.Field] = [
          @moontrace.field("event", "zellij_launch_command_exit"),
          @moontrace.field("action", action),
          @moontrace.field("status", statuses[i]),
          @moontrace.field("command_index", i),
          @moontrace.field("arg_count", cmd.args.length()),
        ]
        match command_arg_value(cmd.args, "--session") {
          Some(session) => fields.push(@moontrace.field("session", session))
          None => ()
        }
        match command_arg_value(cmd.args, "--name") {
          Some(name) => fields.push(@moontrace.field("name", name))
          None => ()
        }
        match command_arg_value(cmd.args, "--cwd") {
          Some(cwd) => fields.push(@moontrace.field("cwd", cwd))
          None => ()
        }
        @moontrace.info("zellij launch command exit", fields~)
      }
      None => ()
    }
  }
}

///|
/// Execute an `Eff[A]` tree by dispatching each effect to the provided
/// runners and threading results back through continuations.
///
/// This is the trampoline: unfold is building the Eff tree (pure),
/// fold is running it here (async).
pub async fn[A] interpret(
  m : Eff[A],
  git_capture~ : async (String, Array[String]) -> String,
  runner~ : async (Array[@workspace.Command]) -> Array[Int],
) -> A {
  match m {
    Pure(a) => a
    GitCapture(program~, args~, cont~) =>
      interpret(
        cont(git_capture(program, args) catch { _ => "" }),
        git_capture~,
        runner~,
      )
    RunCommands(cmds~, cont~) => {
      let statuses = runner(cmds) catch { _ => [] }
      trace_zellij_launch_statuses(cmds, statuses)
      interpret(cont(statuses), git_capture~, runner~)
    }
  }
}

///|
/// Pure description of what fork_wave needs to do.
///
/// Takes pre-computed values from the pure slug/command-building phase
/// and returns an effect tree describing the IO to perform.
/// The scaffold gate (git checks) and spawn are both encoded as effects —
/// no git or process calls happen here.
fn first_failed_command(
  cmds : Array[@workspace.Command],
  exit_codes : Array[Int],
) -> (Int, Int, @workspace.Command?) {
  let mut failed_idx = -1
  let mut failed_status = 0
  for i = 0; i < exit_codes.length(); i = i + 1 {
    if exit_codes[i] != 0 {
      failed_idx = i
      failed_status = exit_codes[i]
      break
    }
  }
  if failed_idx < 0 && exit_codes.length() < cmds.length() {
    failed_idx = exit_codes.length()
    failed_status = -1
  }
  let failing = if failed_idx >= 0 && failed_idx < cmds.length() {
    Some(cmds[failed_idx])
  } else {
    None
  }
  (failed_idx, failed_status, failing)
}

///|
test "first_failed_command treats missing statuses as failed command" {
  let cmds = [
    @workspace.Command::{ program: "true", args: [], workdir: None },
    @workspace.Command::{ program: "zellij", args: ["run"], workdir: None },
  ]
  let (idx, status, failing) = first_failed_command(cmds, [0])
  assert_eq(idx, 1)
  assert_eq(status, -1)
  @debug.assert_eq(failing, Some(cmds[1]))
}

///|
fn effects_test_field_value(
  fields : Array[@moontrace.Field],
  key : String,
) -> Json? {
  for field in fields {
    if field.key == key {
      return Some(field.value)
    }
  }
  None
}

///|
fn effects_event_has_field(
  event : @moontrace.Event,
  key : String,
  expected : Json,
) -> Bool {
  match effects_test_field_value(event.fields, key) {
    Some(value) => value == expected
    None => false
  }
}

///|
async test "interpret logs zellij launch exit status" {
  let events : Array[@moontrace.Event] = []
  @moontrace.set_subscriber(fn(event) { events.push(event) })
  let cmd = @workspace.Command::{
    program: "zellij",
    args: [
      "--session", "choir", "action", "new-tab", "--name", "leaf-a", "--cwd", "/repo/.choir/worktrees/leaf-a",
      "--", "env", "CHOIR_AGENT_ID=main.leaf-a", "codex",
    ],
    workdir: None,
  }
  let statuses = interpret(
    RunCommands(cmds=[cmd], cont=fn(values) { Pure(values) }),
    runner=async fn(_cmds) {
      @async.sleep(0)
      [0]
    },
    git_capture=async fn(_program, _args) {
      @async.sleep(0)
      ""
    },
  )
  @moontrace.clear_subscriber()
  @debug.assert_eq(statuses, [0])
  let mut found = false
  for event in events {
    if event.level == @moontrace.Level::Info &&
      event.message == "zellij launch command exit" &&
      effects_event_has_field(
        event,
        "event",
        String::to_json("zellij_launch_command_exit"),
      ) &&
      effects_event_has_field(event, "action", String::to_json("new-tab")) &&
      effects_event_has_field(event, "session", String::to_json("choir")) &&
      effects_event_has_field(event, "name", String::to_json("leaf-a")) &&
      effects_event_has_field(event, "status", Int::to_json(0)) {
      found = true
    }
  }
  assert_true(found)
}

///|
fn fork_wave_spawn_commands_phase(
  cmds : Array[@workspace.Command],
  spawned_count : Int,
  skipped_count : Int,
  agent_ids : String,
  skipped_ids : String,
) -> Eff[Result[@types.Response, ForkWaveError]] {
  if spawned_count == 0 && skipped_count > 0 {
    return Pure(
      Ok(
        @types.Response::ok_values({
          "status": String::to_json("already_running"),
          "count": Int::to_json(0),
          "skipped_ids": String::to_json(skipped_ids),
        }),
      ),
    )
  }
  RunCommands(cmds~, cont=fn(exit_codes) {
    let (failed_idx, failed_status, failing) = first_failed_command(
      cmds, exit_codes,
    )
    if failed_idx >= 0 {
      Pure(Err(CommandFailed(status=failed_status, failing_cmd=failing)))
    } else {
      let result : Map[String, Json] = {
        "status": String::to_json("spawned"),
        "count": Int::to_json(spawned_count),
        "agent_ids": String::to_json(agent_ids),
      }
      if skipped_count > 0 {
        result.set("skipped_ids", String::to_json(skipped_ids))
      }
      Pure(Ok(@types.Response::ok_values(result)))
    }
  })
}

///|
pub async fn fork_wave_capture_baseline_sha(
  project_dir : String,
  parent_branch : String,
  git_capture : async (String, Array[String]) -> String,
) -> String {
  let parent = parent_branch.trim().to_owned()
  if parent == "" {
    return ""
  }
  let out = git_capture("git", [
    "-C",
    project_dir,
    "rev-parse",
    "origin/" + parent,
  ]) catch {
    _ => ""
  }
  out.trim().to_owned()
}

///|
fn git_status_paths_in_status_line(line : String) -> Array[String] {
  if line.length() < 4 {
    return []
  }
  let payload = line[3:].to_owned()
  let arrow = " -> "
  match payload.find(arrow) {
    Some(idx) =>
      [payload[:idx].to_owned(), payload[idx + arrow.length():].to_owned()]
    None => [payload]
  }
}

///|
fn fork_wave_clean_gate_ignored_beads_path(path : String) -> Bool {
  path.has_prefix(".beads/") && path.has_suffix(".jsonl")
}

///|
fn fork_wave_clean_gate_ignored_status_line(line : String) -> Bool {
  let paths = git_status_paths_in_status_line(line)
  if paths.length() == 0 {
    return false
  }
  for path in paths {
    if !fork_wave_clean_gate_ignored_beads_path(path) {
      return false
    }
  }
  true
}

///|
pub fn fork_wave_clean_gate_relevant_status(status_out : String) -> String {
  let lines : Array[String] = []
  for line in status_out.split("\n") {
    let owned = line.to_owned()
    if owned.trim() == "" || fork_wave_clean_gate_ignored_status_line(owned) {
      continue
    }
    lines.push(owned)
  }
  lines.join("\n")
}

///|
fn fork_wave_clean_gate_phase(
  project_dir : String,
  cmds : Array[@workspace.Command],
  spawned_count : Int,
  skipped_count : Int,
  agent_ids : String,
  skipped_ids : String,
) -> Eff[Result[@types.Response, ForkWaveError]] {
  GitCapture(program="git", args=["-C", project_dir, "status", "--porcelain"], cont=fn(
    status_out,
  ) {
    let relevant_status = fork_wave_clean_gate_relevant_status(status_out)
    if relevant_status.trim().to_owned() != "" {
      Pure(Err(UncommittedChanges(output=relevant_status.trim().to_owned())))
    } else {
      GitCapture(
        program="git",
        args=["-C", project_dir, "log", "--oneline", "@{u}..HEAD"],
        cont=fn(unpushed_out) {
          if unpushed_out.trim().to_owned() != "" {
            Pure(Err(UnpushedCommits(output=unpushed_out.trim().to_owned())))
          } else {
            fork_wave_spawn_commands_phase(
              cmds, spawned_count, skipped_count, agent_ids, skipped_ids,
            )
          }
        },
      )
    }
  })
}

///|
fn fork_wave_scaffold_commit_commands(
  project_dir : String,
  scaffold : ForkWaveScaffoldCommit,
) -> Array[@workspace.Command] {
  let add_args = ["-C", project_dir, "add", "--"]
  for path in scaffold.paths {
    add_args.push(path)
  }
  let commit_args = ["-C", project_dir, "commit", "-m", scaffold.message, "--"]
  for path in scaffold.paths {
    commit_args.push(path)
  }
  [
    @workspace.Command::{ program: "git", args: add_args, workdir: None },
    @workspace.Command::{ program: "git", args: commit_args, workdir: None },
    @workspace.Command::{
      program: "git",
      args: ["-C", project_dir, "push"],
      workdir: None,
    },
  ]
}

///|
pub fn fork_wave_scaffold_compensation_commands(
  project_dir : String,
  pre_scaffold_sha : String,
) -> Array[@workspace.Command] {
  [
    @workspace.Command::{
      program: "git",
      args: ["-C", project_dir, "reset", "--hard", pre_scaffold_sha],
      workdir: None,
    },
    @workspace.Command::{
      program: "git",
      args: ["-C", project_dir, "push", "--force-with-lease"],
      workdir: None,
    },
  ]
}

///|
fn fork_wave_compensate_scaffold_failure(
  project_dir : String,
  pre_scaffold_sha : String,
  original : ForkWaveError,
) -> Eff[Result[@types.Response, ForkWaveError]] {
  let compensation_cmds = fork_wave_scaffold_compensation_commands(
    project_dir, pre_scaffold_sha,
  )
  RunCommands(cmds=compensation_cmds, cont=fn(exit_codes) {
    let (failed_idx, failed_status, failing) = first_failed_command(
      compensation_cmds, exit_codes,
    )
    if failed_idx >= 0 {
      Pure(
        Err(
          ScaffoldCompensationFailed(
            pre_scaffold_sha~,
            original_error=original.message(),
            status=failed_status,
            failing_cmd=failing,
          ),
        ),
      )
    } else {
      Pure(Err(original))
    }
  })
}

///|
fn fork_wave_compensate_on_post_scaffold_error(
  post_scaffold : Eff[Result[@types.Response, ForkWaveError]],
  project_dir : String,
  pre_scaffold_sha : String,
) -> Eff[Result[@types.Response, ForkWaveError]] {
  match post_scaffold {
    Pure(Ok(resp)) => Pure(Ok(resp))
    Pure(Err(e)) =>
      fork_wave_compensate_scaffold_failure(project_dir, pre_scaffold_sha, e)
    GitCapture(program~, args~, cont~) =>
      GitCapture(program~, args~, cont=fn(output) {
        fork_wave_compensate_on_post_scaffold_error(
          cont(output),
          project_dir,
          pre_scaffold_sha,
        )
      })
    RunCommands(cmds~, cont~) =>
      RunCommands(cmds~, cont=fn(exit_codes) {
        fork_wave_compensate_on_post_scaffold_error(
          cont(exit_codes),
          project_dir,
          pre_scaffold_sha,
        )
      })
  }
}

///|
fn fork_wave_scaffold_commit_phase(
  project_dir : String,
  scaffold : ForkWaveScaffoldCommit,
  cmds : Array[@workspace.Command],
  spawned_count : Int,
  skipped_count : Int,
  agent_ids : String,
  skipped_ids : String,
  path_index : Int,
  pre_scaffold_sha : String,
) -> Eff[Result[@types.Response, ForkWaveError]] {
  if path_index >= scaffold.paths.length() {
    let scaffold_cmds = fork_wave_scaffold_commit_commands(
      project_dir, scaffold,
    )
    return RunCommands(cmds=scaffold_cmds, cont=fn(exit_codes) {
      let (failed_idx, failed_status, failing) = first_failed_command(
        scaffold_cmds, exit_codes,
      )
      if failed_idx >= 0 {
        Pure(
          Err(ScaffoldCommandFailed(status=failed_status, failing_cmd=failing)),
        )
      } else {
        fork_wave_compensate_on_post_scaffold_error(
          fork_wave_clean_gate_phase(
            project_dir, cmds, spawned_count, skipped_count, agent_ids, skipped_ids,
          ),
          project_dir,
          pre_scaffold_sha,
        )
      }
    })
  }
  let path = scaffold.paths[path_index]
  GitCapture(
    program="git",
    args=["-C", project_dir, "status", "--porcelain", "--", path],
    cont=fn(status_out) {
      if status_out.trim().to_owned() == "" {
        Pure(Err(ScaffoldCommitPathUnchanged(path~)))
      } else {
        fork_wave_scaffold_commit_phase(
          project_dir,
          scaffold,
          cmds,
          spawned_count,
          skipped_count,
          agent_ids,
          skipped_ids,
          path_index + 1,
          pre_scaffold_sha,
        )
      }
    },
  )
}

///|
/// Parse a `git status --porcelain` line and return the set of paths it
/// references. Rename/copy lines (`R` / `C` status) have the shape
/// `XY old -> new`; both `old` and `new` must be considered against
/// scaffold paths so a rename of a scaffold path isn't mis-flagged as
/// unrelated.
fn scaffold_preflight_paths_in_status_line(line : String) -> Array[String] {
  git_status_paths_in_status_line(line)
}

///|
/// Preflight check before scaffold_commit runs git add/commit/push. Ensures:
/// (a) HEAD is on the requested parent branch (otherwise scaffold's push
///     could mutate the wrong branch entirely),
/// (b) the parent branch has no unpushed commits (otherwise scaffold's push
///     would silently ship pre-existing local work the operator hadn't
///     reviewed), and
/// (c) the working tree is clean OUTSIDE the scaffold paths (otherwise the
///     scaffold commit goes through but the post-scaffold clean_gate then
///     fails, leaving a pushed commit behind that's now hard to back out).
/// Dirty entries that match `scaffold.paths` (including the `new` side of a
/// rename) are expected and allowed — they're what the scaffold is going
/// to commit.
fn fork_wave_scaffold_preflight_phase(
  project_dir : String,
  scaffold : ForkWaveScaffoldCommit,
  cmds : Array[@workspace.Command],
  spawned_count : Int,
  skipped_count : Int,
  agent_ids : String,
  skipped_ids : String,
  parent_branch : String,
) -> Eff[Result[@types.Response, ForkWaveError]] {
  GitCapture(
    program="git",
    args=["-C", project_dir, "rev-parse", "--abbrev-ref", "HEAD"],
    cont=fn(head_out) {
      let head_branch = head_out.trim().to_owned()
      if head_branch != parent_branch {
        Pure(
          Err(
            ScaffoldBranchMismatch(expected=parent_branch, actual=head_branch),
          ),
        )
      } else {
        GitCapture(
          program="git",
          args=["-C", project_dir, "log", "--oneline", "@{u}..HEAD"],
          cont=fn(unpushed_out) {
            if unpushed_out.trim().to_owned() != "" {
              Pure(Err(UnpushedCommits(output=unpushed_out.trim().to_owned())))
            } else {
              GitCapture(
                program="git",
                args=["-C", project_dir, "status", "--porcelain"],
                cont=fn(status_out) {
                  let scaffold_paths : Map[String, Bool] = {}
                  for p in scaffold.paths {
                    scaffold_paths.set(p, true)
                  }
                  let unrelated : Array[String] = []
                  for line in status_out.split("\n") {
                    let trimmed = line.to_owned()
                    if trimmed.length() < 4 {
                      continue
                    }
                    let paths = scaffold_preflight_paths_in_status_line(trimmed)
                    let mut all_in_scaffold = true
                    for p in paths {
                      if !scaffold_paths.contains(p) {
                        all_in_scaffold = false
                        break
                      }
                    }
                    if !all_in_scaffold {
                      unrelated.push(trimmed)
                    }
                  }
                  if unrelated.length() > 0 {
                    Pure(
                      Err(
                        ScaffoldCommitUnrelatedChanges(
                          output=unrelated.join("\n"),
                        ),
                      ),
                    )
                  } else {
                    GitCapture(
                      program="git",
                      args=["-C", project_dir, "rev-parse", "HEAD"],
                      cont=fn(pre_scaffold_out) {
                        let pre_scaffold_sha = pre_scaffold_out
                          .trim()
                          .to_owned()
                        if pre_scaffold_sha == "" {
                          Pure(
                            Err(
                              ScaffoldCommandFailed(status=1, failing_cmd=None),
                            ),
                          )
                        } else {
                          fork_wave_scaffold_commit_phase(
                            project_dir, scaffold, cmds, spawned_count, skipped_count,
                            agent_ids, skipped_ids, 0, pre_scaffold_sha,
                          )
                        }
                      },
                    )
                  }
                },
              )
            }
          },
        )
      }
    },
  )
}

///|
pub fn fork_wave_plan(
  project_dir : String,
  cmds : Array[@workspace.Command],
  spawned_count : Int,
  skipped_count : Int,
  agent_ids : String,
  skipped_ids : String,
  scaffold_commit? : ForkWaveScaffoldCommit? = None,
  parent_branch? : String = "",
) -> Eff[Result[@types.Response, ForkWaveError]] {
  // Already-running short-circuit BEFORE any scaffold work: if every
  // requested leaf was deduped, fork_wave is a no-op and must not mutate
  // the parent branch. `fork_wave_spawn_commands_phase` already returns
  // the already_running response without running cmds; route there
  // directly when scaffold is present too, so a no-op fork_wave call
  // can't accidentally push a scaffold commit.
  if spawned_count == 0 && skipped_count > 0 {
    return fork_wave_spawn_commands_phase(
      cmds, spawned_count, skipped_count, agent_ids, skipped_ids,
    )
  }
  match scaffold_commit {
    None =>
      fork_wave_clean_gate_phase(
        project_dir, cmds, spawned_count, skipped_count, agent_ids, skipped_ids,
      )
    Some(scaffold) =>
      // Preflight before scaffold runs: no unpushed commits AND only the
      // scaffold paths are dirty. Without this, scaffold could push
      // pre-existing local work OR leave a pushed scaffold commit behind
      // when the post-scaffold clean_gate later fails.
      fork_wave_scaffold_preflight_phase(
        project_dir, scaffold, cmds, spawned_count, skipped_count, agent_ids, skipped_ids,
        parent_branch,
      )
  }
}
