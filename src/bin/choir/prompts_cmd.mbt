///|
pub(all) struct PromptDrift {
  display_name : String
  disk_path : String
  default_content : String
  disk_content : String
} derive(Debug, Eq)

///|
fn collect_prompt_drifts(
  project_dir : String,
  path_exists : (String) -> Bool,
  read_file : (String) -> String,
) -> Array[PromptDrift] {
  let out : Array[PromptDrift] = []
  for prompt in @prompts.all_prompt_names() {
    let disk_path = @prompts.prompt_path(prompt, project_dir)
    if path_exists(disk_path) {
      let disk_content = read_file(disk_path)
      let default_content = @prompts.default_prompt(prompt)
      if @prompts.detect_prompt_drift(Some(disk_content), default_content) {
        out.push({
          display_name: prompt_display_name(prompt),
          disk_path,
          default_content,
          disk_content,
        })
      }
    }
  }
  out
}

///|
fn prompt_display_name(prompt : @prompts.PromptName) -> String {
  let relative = @prompts.prompt_relative_path(prompt)
  let prefix = ".choir/prompts/"
  if relative.has_prefix(prefix) {
    relative[prefix.length():].to_owned()
  } else {
    relative
  }
}

///|
fn diff_lines(content : String) -> Array[String] {
  if content == "" {
    return []
  }
  let raw : Array[String] = []
  for part in content.split("\n") {
    raw.push(part.to_owned())
  }
  let lines : Array[String] = []
  let mut limit = raw.length()
  if content.has_suffix("\n") && limit > 0 {
    limit = limit - 1
  }
  for i = 0; i < limit; i = i + 1 {
    lines.push(raw[i])
  }
  lines
}

///|
/// Render a unified diff with common-prefix and common-suffix trimming.
/// Correctly handles the common drift shapes — single-line edit, insertion-
/// in-middle, append-at-end, delete-at-end, and trailing-newline-only
/// difference — by emitting context lines for the matching prefix/suffix
/// and -/+ lines only for the genuinely different middle hunk. For
/// multi-section drift (rare for prompts) this degrades to a single big
/// hunk rather than minimal LCS output; strictly better than a line-by-
/// line zip which mis-attributed every line after an insertion.
///
/// Trailing-newline-only difference (e.g. `"x\n"` vs `"x"`) cannot show in
/// the line arrays (both flatten to `["x"]`), so it gets a dedicated
/// hunk: the last line is emitted as -/+ pair and `\ No newline at end of
/// file` follows the side missing the terminator (matches GNU diff -u).
fn render_prompt_diff(
  display_name : String,
  default_content : String,
  disk_content : String,
) -> String {
  let defaults = diff_lines(default_content)
  let disk = diff_lines(disk_content)
  let default_trailing_nl = default_content.has_suffix("\n")
  let disk_trailing_nl = disk_content.has_suffix("\n")
  let out = StringBuilder::new()
  out.write_string("--- defaults/" + display_name + "\n")
  out.write_string("+++ disk/" + display_name + "\n")
  out.write_string("@@\n")
  let n = defaults.length()
  let m = disk.length()

  // Trailing-newline-only difference: line arrays match byte-for-byte but
  // `default_content != disk_content` (we're only called for drifted
  // files). Emit the last line as a -/+ pair with the no-newline marker
  // on the side that lacks the terminator.
  if n == m && default_trailing_nl != disk_trailing_nl {
    let mut all_match = true
    for i = 0; i < n; i = i + 1 {
      if defaults[i] != disk[i] {
        all_match = false
        break
      }
    }
    if all_match {
      for i = 0; i < n - 1; i = i + 1 {
        out.write_string(" " + defaults[i] + "\n")
      }
      if n > 0 {
        out.write_string("-" + defaults[n - 1] + "\n")
        if !default_trailing_nl {
          out.write_string("\\ No newline at end of file\n")
        }
        out.write_string("+" + disk[n - 1] + "\n")
        if !disk_trailing_nl {
          out.write_string("\\ No newline at end of file\n")
        }
      } else if !default_trailing_nl {
        out.write_string("\\ No newline at end of file (defaults)\n")
      } else {
        out.write_string("\\ No newline at end of file (disk)\n")
      }
      return out.to_string()
    }
  }

  let min_len = if n < m { n } else { m }
  let mut prefix = 0
  while prefix < min_len && defaults[prefix] == disk[prefix] {
    prefix = prefix + 1
  }
  let mut suffix = 0
  while suffix < min_len - prefix &&
        defaults[n - 1 - suffix] == disk[m - 1 - suffix] {
    suffix = suffix + 1
  }
  for i = 0; i < prefix; i = i + 1 {
    out.write_string(" " + defaults[i] + "\n")
  }
  for i = prefix; i < n - suffix; i = i + 1 {
    out.write_string("-" + defaults[i] + "\n")
  }
  // No-newline marker after the defaults middle hunk only when the LAST
  // emitted -line is also the file's last line.
  if !default_trailing_nl && suffix == 0 && n - suffix > prefix {
    out.write_string("\\ No newline at end of file\n")
  }
  for i = prefix; i < m - suffix; i = i + 1 {
    out.write_string("+" + disk[i] + "\n")
  }
  if !disk_trailing_nl && suffix == 0 && m - suffix > prefix {
    out.write_string("\\ No newline at end of file\n")
  }
  for i = n - suffix; i < n; i = i + 1 {
    out.write_string(" " + defaults[i] + "\n")
  }
  out.to_string()
}

///|
fn sync_prompt_drifts(
  project_dir : String,
  drifts : Array[PromptDrift],
  now_unix_sec : Int64,
  create_dir_all : (String) -> Bool,
  write_file : (String, String) -> Bool,
) -> Result[Unit, @types.ChoirError] {
  for drift in drifts {
    let backup_dir = prompt_backup_dir(project_dir, drift.display_name)
    if !create_dir_all(backup_dir) {
      return Err(
        @types.ChoirError::workspace_error(
          "failed to create prompt backup directory " + backup_dir,
        ),
      )
    }
    let backup_path = prompt_backup_path(
      project_dir,
      drift.display_name,
      now_unix_sec,
    )
    if !write_file(backup_path, drift.disk_content) {
      return Err(
        @types.ChoirError::workspace_error(
          "failed to write prompt backup " + backup_path,
        ),
      )
    }
    if !write_file(drift.disk_path, drift.default_content) {
      return Err(
        @types.ChoirError::workspace_error(
          "failed to restore prompt " + drift.disk_path,
        ),
      )
    }
  }
  Ok(())
}

///|
pub fn prompts_cmd_run() -> Unit {
  let args = @env.args()
  if args.length() != 3 || args[2] == "--help" || args[2] == "-h" {
    prompts_cmd_usage()
    @sys.exit(if args.length() == 3 { 0 } else { 1 })
    return
  }
  let project_dir = @env.current_dir().unwrap_or(".")
  let drifts = collect_prompt_drifts(
    project_dir, @sys.path_exists, @sys.read_file,
  )
  match args[2] {
    "diff" => {
      for drift in drifts {
        @sys.write_stdout(
          render_prompt_diff(
            drift.display_name,
            drift.default_content,
            drift.disk_content,
          ),
        )
      }
      if drifts.length() > 0 {
        @sys.exit(1)
      }
    }
    "sync" => {
      let now_unix_sec = @env.now().reinterpret_as_int64() / 1000L
      match
        sync_prompt_drifts(
          project_dir, drifts, now_unix_sec, @sys.create_dir_all, @sys.write_file_sync,
        ) {
        Ok(_) => ()
        Err(e) => {
          @sys.write_stderr("error: " + e.message() + "\n")
          @sys.exit(1)
        }
      }
    }
    other => {
      @sys.write_stderr("error: unknown prompts subcommand: " + other + "\n")
      prompts_cmd_usage()
      @sys.exit(1)
    }
  }
}

///|
fn prompts_project_base(project_dir : String) -> String {
  if project_dir == "" {
    "."
  } else {
    project_dir
  }
}

///|
fn prompt_backup_dir(project_dir : String, display_name : String) -> String {
  let parts : Array[String] = []
  for part in display_name.split("/") {
    parts.push(part.to_owned())
  }
  let mut dir = prompts_project_base(project_dir) + "/.choir/prompts-backup"
  if parts.length() > 1 {
    for i = 0; i < parts.length() - 1; i = i + 1 {
      let part = parts[i]
      if part != "" {
        dir = dir + "/" + part
      }
    }
  }
  dir
}

///|
fn prompt_backup_path(
  project_dir : String,
  display_name : String,
  now_unix_sec : Int64,
) -> String {
  prompts_project_base(project_dir) +
  "/.choir/prompts-backup/" +
  display_name +
  "." +
  now_unix_sec.to_string() +
  ".bak"
}

///|
fn prompts_cmd_usage() -> Unit {
  @sys.write_stderr("usage: choir prompts <diff|sync>\n")
}

///|
test "collect_prompt_drifts reports only prompt files that differ from baked defaults" {
  let disk_path = "./.choir/prompts/skills/tl-stance.md"
  let disk_content = @prompts.default_prompt(@prompts.PromptName::TlStance) +
    "\n"
  let drifts = collect_prompt_drifts(".", fn(path) { path == disk_path }, fn(
    path,
  ) {
    if path == disk_path {
      disk_content
    } else {
      ""
    }
  })
  assert_eq(drifts.length(), 1)
  assert_eq(drifts[0].display_name, "skills/tl-stance.md")
  assert_eq(drifts[0].disk_path, disk_path)
  assert_eq(
    drifts[0].default_content,
    @prompts.default_prompt(@prompts.PromptName::TlStance),
  )
  assert_eq(drifts[0].disk_content, disk_content)
}

///|
test "render_prompt_diff emits headers with trailing-blank-line insertion" {
  let rendered = render_prompt_diff(
    "skills/tl-stance.md", "alpha\nbeta\n", "alpha\nbeta\n\n",
  )
  assert_eq(
    rendered,
    "--- defaults/skills/tl-stance.md\n" +
    "+++ disk/skills/tl-stance.md\n" +
    "@@\n" +
    " alpha\n" +
    " beta\n" +
    "+\n",
  )
}

///|
test "render_prompt_diff handles insertion in middle without misattributing context" {
  // Bare line-by-line zip mis-attributes every line after the insertion
  // as removed+added. Prefix/suffix trim must keep b/c/d as unchanged
  // context and only mark x as inserted.
  let rendered = render_prompt_diff(
    "skills/tl-stance.md", "a\nb\nc\nd\n", "a\nx\nb\nc\nd\n",
  )
  assert_eq(
    rendered,
    "--- defaults/skills/tl-stance.md\n" +
    "+++ disk/skills/tl-stance.md\n" +
    "@@\n" +
    " a\n" +
    "+x\n" +
    " b\n" +
    " c\n" +
    " d\n",
  )
}

///|
test "render_prompt_diff handles single-line edit as a clean -/+ hunk" {
  let rendered = render_prompt_diff(
    "skills/tl-stance.md", "a\nold\nc\n", "a\nnew\nc\n",
  )
  assert_eq(
    rendered,
    "--- defaults/skills/tl-stance.md\n" +
    "+++ disk/skills/tl-stance.md\n" +
    "@@\n" +
    " a\n" +
    "-old\n" +
    "+new\n" +
    " c\n",
  )
}

///|
test "render_prompt_diff marks trailing-newline removal with no-newline marker" {
  // Operator saved tl-stance.md without a final newline. The line arrays
  // are identical (both ["default"]), but the bytes differ. Without the
  // dedicated trailing-newline hunk this case rendered an empty diff
  // body while the CLI still exited non-zero — drift detected, no
  // explanation visible to the operator.
  let rendered = render_prompt_diff(
    "skills/tl-stance.md", "default\n", "default",
  )
  assert_eq(
    rendered,
    "--- defaults/skills/tl-stance.md\n" +
    "+++ disk/skills/tl-stance.md\n" +
    "@@\n" +
    "-default\n" +
    "+default\n" +
    "\\ No newline at end of file\n",
  )
}

///|
test "render_prompt_diff marks trailing-newline addition with no-newline marker" {
  // Mirror of the above: defaults lack newline, disk added one.
  let rendered = render_prompt_diff(
    "skills/tl-stance.md", "default", "default\n",
  )
  assert_eq(
    rendered,
    "--- defaults/skills/tl-stance.md\n" +
    "+++ disk/skills/tl-stance.md\n" +
    "@@\n" +
    "-default\n" +
    "\\ No newline at end of file\n" +
    "+default\n",
  )
}

///|
test "render_prompt_diff handles deletion in middle" {
  let rendered = render_prompt_diff(
    "skills/tl-stance.md", "a\nb\nc\nd\n", "a\nc\nd\n",
  )
  assert_eq(
    rendered,
    "--- defaults/skills/tl-stance.md\n" +
    "+++ disk/skills/tl-stance.md\n" +
    "@@\n" +
    " a\n" +
    "-b\n" +
    " c\n" +
    " d\n",
  )
}

///|
test "sync_prompt_drifts writes backup before restoring default content" {
  let writes : Array[String] = []
  let created : Array[String] = []
  let drift : PromptDrift = {
    display_name: "skills/tl-stance.md",
    disk_path: "./.choir/prompts/skills/tl-stance.md",
    default_content: "default\n",
    disk_content: "edited\n",
  }
  let result = sync_prompt_drifts(
    ".",
    [drift],
    123L,
    fn(path) {
      created.push(path)
      true
    },
    fn(path, content) {
      writes.push(path + "=" + content)
      true
    },
  )
  guard result is Ok(_) else { fail("sync should succeed") }
  assert_eq(created, ["./.choir/prompts-backup/skills"])
  assert_eq(writes.length(), 2)
  assert_eq(
    writes[0],
    "./.choir/prompts-backup/skills/tl-stance.md.123.bak=edited\n",
  )
  assert_eq(writes[1], "./.choir/prompts/skills/tl-stance.md=default\n")
}
