///|
fn should_skip_dir(name : String) -> Bool {
  name == "target" || name == ".mooncakes" || name == ".git" || name == ".choir"
}

///|
fn collect_source_files(dir : String, files : Array[String]) -> Unit {
  for entry in @sys.list_dir(dir) {
    if !should_skip_dir(entry) {
      let path = dir + "/" + entry
      if @sys.path_entry_exists(path) {
        if path.has_suffix(".mbt") {
          files.push(path)
        } else {
          collect_source_files(path, files)
        }
      }
    }
  }
}

///|
fn cli_files() -> Array[String] {
  let args = @env.args()
  let files : Array[String] = []
  if args.length() > 1 {
    for i = 1; i < args.length(); i = i + 1 {
      files.push(args[i])
    }
  } else {
    collect_source_files("src", files)
  }
  files
}

///|
fn render_finding(finding : @lint.LintFinding) -> String {
  "\{finding.file}:\{finding.loc}: \{finding.rule_id}: \{finding.message}\n"
}

///|
fn main {
  let files = cli_files()
  let mut failed = false
  for file in files {
    let source = @sys.read_file(file)
    match @lint.lint_source(file, source) {
      Ok(findings) =>
        for finding in findings {
          @sys.write_stderr(render_finding(finding))
          failed = true
        }
      Err(err) => {
        @sys.write_stderr(file + ": parse failed: " + err.message() + "\n")
        failed = true
      }
    }
  }
  if failed {
    @sys.exit(1)
  }
}
