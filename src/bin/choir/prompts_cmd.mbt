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
fn render_prompt_diff(
  display_name : String,
  default_content : String,
  disk_content : String,
) -> String {
  let defaults = diff_lines(default_content)
  let disk = diff_lines(disk_content)
  let out = StringBuilder::new()
  out.write_string("--- defaults/" + display_name + "\n")
  out.write_string("+++ disk/" + display_name + "\n")
  out.write_string("@@\n")
  let shared = if defaults.length() < disk.length() {
    defaults.length()
  } else {
    disk.length()
  }
  for i = 0; i < shared; i = i + 1 {
    let default_line = defaults[i]
    let disk_line = disk[i]
    if default_line == disk_line {
      out.write_string(" " + default_line + "\n")
    } else {
      out.write_string("-" + default_line + "\n")
      out.write_string("+" + disk_line + "\n")
    }
  }
  if defaults.length() > shared {
    for i = shared; i < defaults.length(); i = i + 1 {
      out.write_string("-" + defaults[i] + "\n")
    }
  }
  if disk.length() > shared {
    for i = shared; i < disk.length(); i = i + 1 {
      out.write_string("+" + disk[i] + "\n")
    }
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
test "render_prompt_diff uses defaults and disk headers with changed lines" {
  let rendered = render_prompt_diff(
    "skills/tl-stance.md", "alpha\nbeta\n", "alpha\nbeta\n\n",
  )
  assert_true(rendered.contains("--- defaults/skills/tl-stance.md\n"))
  assert_true(rendered.contains("+++ disk/skills/tl-stance.md\n"))
  assert_true(rendered.contains("@@\n"))
  assert_true(rendered.contains("+\n"))
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
