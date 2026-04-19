///|
pub struct SkillDesc {
  name : String
  description : String
}

///|
pub fn SkillDesc::new(name : String, description : String) -> SkillDesc {
  { name, description }
}

///|
pub fn validate_skill_name(
  name : String,
  builtins : Array[String],
) -> Result[Unit, @types.ChoirError] {
  if name == "" {
    return Err(@types.ChoirError::validation_error("empty skill name"))
  }
  if name.contains("/") || name.contains("\\") || name == "." || name == ".." {
    return Err(@types.ChoirError::validation_error("invalid skill name"))
  }
  for b in builtins {
    if name == b {
      return Err(
        @types.ChoirError::validation_error(
          "user skill '" + name + "' clashes with builtin",
        ),
      )
    }
  }
  Ok(())
}

///|
pub fn render_skill_list(
  builtin : Array[SkillDesc],
  user : Array[SkillDesc],
) -> String {
  let buf = StringBuilder::new()
  buf.write_string("builtin:\n")
  for b in builtin {
    buf.write_string(
      "  " + pad_right(b.name, 10) + " — " + b.description + "\n",
    )
  }
  buf.write_string("user:\n")
  for u in user {
    buf.write_string(
      "  " + pad_right(u.name, 10) + " — " + u.description + "\n",
    )
  }
  buf.to_string()
}

///|
fn basename(path : String) -> String {
  let parts = path.split("/")
  let mut last = ""
  for p in parts {
    let ps = p.to_string()
    if ps != "" {
      last = ps
    }
  }
  last
}

///|
fn pad_right(s : String, width : Int) -> String {
  let mut res = s
  while res.length() < width {
    res = res + " "
  }
  res
}

///|
pub fn extract_description(content : String) -> String {
  let lines = content.split("\n")
  let mut in_frontmatter = false
  for line in lines {
    let trimmed = line.trim().to_string()
    if trimmed == "---" {
      if in_frontmatter {
        break
      } else {
        in_frontmatter = true
        continue
      }
    }
    if in_frontmatter && trimmed.has_prefix("description:") {
      let desc_len = "description:".length()
      let desc = trimmed[desc_len:].to_string().trim().to_string()
      if desc.has_prefix("\"") && desc.has_suffix("\"") && desc.length() >= 2 {
        return desc[1:desc.length() - 1].to_string()
      }
      if desc.has_prefix("'") && desc.has_suffix("'") && desc.length() >= 2 {
        return desc[1:desc.length() - 1].to_string()
      }
      return desc
    }
  }
  "<no description>"
}

///|
fn skill_help() -> Unit {
  @sys.write_stdout(
    (
      #|Usage: choir skill <add|list|remove>
      #|
      #|Commands:
      #|  add <dir>      Add a user skill from <dir>. The directory must contain a SKILL.md file.
      #|  list           List all built-in and user skills.
      #|  remove <name>  Remove the user skill <name>.
      #|
      #|Example:
      #|  choir skill add ./my-skill
      #|
    ),
  )
}

///|
fn skill_add(dir : String, skills_dir : String) -> Unit {
  let name = basename(dir)
  match validate_skill_name(name, ["audit", "decompose"]) {
    Ok(_) => ()
    Err(e) => {
      @sys.write_stderr("error: " + e.message() + "\n")
      @sys.exit(1)
      return
    }
  }
  let md_path = dir + "/SKILL.md"
  if !@sys.path_exists(md_path) {
    @sys.write_stderr("error: " + dir + " must contain SKILL.md\n")
    @sys.exit(1)
    return
  }
  let target = skills_dir + "/" + name
  ignore(@sys.rm_rf(target))
  if !@sys.copy_dir_recursive(dir, target) {
    @sys.write_stderr("error: failed to copy skill directory\n")
    @sys.exit(1)
    return
  }
}

///|
fn skill_list(skills_dir : String) -> Unit {
  let builtins : Array[SkillDesc] = [
    {
      name: "audit",
      description: "Spawn a Sarcasmotron worker to critically audit the current branch diff.",
    },
    {
      name: "decompose",
      description: "Crystallize a feature spec and create the integration branch.",
    },
  ]

  let user_skills : Array[SkillDesc] = []
  if @sys.path_entry_exists(skills_dir) {
    let entries = @sys.list_dir(skills_dir)
    entries.sort()
    for entry in entries {
      let skill_path = skills_dir + "/" + entry
      if @sys.path_entry_exists(skill_path) && !@sys.path_exists(skill_path) {
        let md_path = skill_path + "/SKILL.md"
        if @sys.path_exists(md_path) {
          let content = @sys.read_file(md_path)
          let desc = extract_description(content)
          user_skills.push({ name: entry, description: desc })
        } else {
          user_skills.push({ name: entry, description: "<missing SKILL.md>" })
        }
      }
    }
  }
  @sys.write_stdout(render_skill_list(builtins, user_skills))
}

///|
fn skill_remove(name : String, skills_dir : String) -> Unit {
  match validate_skill_name(name, ["audit", "decompose"]) {
    Ok(_) => ()
    Err(e) => {
      @sys.write_stderr("error: " + e.message() + "\n")
      @sys.exit(1)
      return
    }
  }
  let target = skills_dir + "/" + name
  if !@sys.path_entry_exists(target) {
    @sys.write_stderr("error: user skill '" + name + "' does not exist\n")
    @sys.exit(1)
    return
  }
  ignore(@sys.rm_rf(target))
}

///|
pub fn skill_subcommand_run() -> Unit {
  let args = @env.args()
  if args.length() < 3 {
    skill_help()
    @sys.exit(1)
    return
  }
  let cmd = args[2]
  if cmd == "--help" || cmd == "-h" {
    skill_help()
    return
  }
  let home = match @sys.getenv("HOME") {
    Some(h) => if h == "" { "" } else { h }
    None => ""
  }
  if home == "" {
    @sys.write_stderr("error: HOME is not set\n")
    @sys.exit(1)
    return
  }
  let skills_dir = match user_skills_dir_for(home) {
    Ok(dir) => dir
    Err(e) => {
      @sys.write_stderr("error: " + e.message() + "\n")
      @sys.exit(1)
      ""
    }
  }

  if cmd == "add" {
    if args.length() < 4 || args[3] == "--help" || args[3] == "-h" {
      @sys.write_stdout(
        (
          #|Usage: choir skill add <dir>
          #|
          #|  Add a user skill from <dir>. The directory must contain a SKILL.md file.
          #|
          #|Example:
          #|  choir skill add ./my-skill
          #|
        ),
      )
      if args.length() < 4 {
        @sys.exit(1)
      }
      return
    }
    skill_add(args[3], skills_dir)
  } else if cmd == "list" {
    if args.length() > 3 && (args[3] == "--help" || args[3] == "-h") {
      @sys.write_stdout(
        (
          #|Usage: choir skill list
          #|
          #|  List all built-in and user skills.
          #|
          #|Example:
          #|  choir skill list
          #|
        ),
      )
      return
    }
    skill_list(skills_dir)
  } else if cmd == "remove" {
    if args.length() < 4 || args[3] == "--help" || args[3] == "-h" {
      @sys.write_stdout(
        (
          #|Usage: choir skill remove <name>
          #|
          #|  Remove the user skill <name>.
          #|
          #|Example:
          #|  choir skill remove my-skill
          #|
        ),
      )
      if args.length() < 4 {
        @sys.exit(1)
      }
      return
    }
    skill_remove(args[3], skills_dir)
  } else {
    skill_help()
    @sys.exit(1)
  }
}
