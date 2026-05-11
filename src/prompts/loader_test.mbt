///|
fn prompt_test_tmpdir(name : String) -> String {
  "/tmp/choir-prompts-" +
  name +
  "-" +
  @sys.get_pid().to_string() +
  "-" +
  @env.now().reinterpret_as_int64().to_string()
}

///|
fn prompt_repo_root() -> String {
  let cwd = @env.current_dir().unwrap_or(".")
  let candidates = [cwd, cwd + "/..", cwd + "/../..", "."]
  for candidate in candidates {
    if @sys.path_exists(candidate + "/moon.mod.json") &&
      @sys.path_exists(candidate + "/.choir/prompts/skills/audit.md") {
      return candidate
    }
  }
  cwd
}

///|
test "load_prompt returns file contents when present" {
  let dir = prompt_test_tmpdir("file")
  ignore(@sys.rm_rf(dir))
  assert_true(@sys.create_dir_all(dir + "/.choir/prompts/skills"))
  assert_true(
    @sys.write_file_sync(
      dir + "/.choir/prompts/skills/audit.md",
      "local audit prompt\n",
    ),
  )

  assert_eq(load_prompt(PromptName::AuditSkill, dir), "local audit prompt\n")

  ignore(@sys.rm_rf(dir))
}

///|
test "load_prompt returns fallback when file is missing" {
  let dir = prompt_test_tmpdir("fallback")
  ignore(@sys.rm_rf(dir))
  assert_eq(
    load_prompt(PromptName::AuditSkill, dir),
    default_prompt(PromptName::AuditSkill),
  )
}

///|
test "fallback prompts match committed markdown byte for byte" {
  let root = prompt_repo_root()
  for name in all_prompt_names() {
    let path = root + "/" + prompt_relative_path(name)
    let disk = @sys.read_file(path)
    assert_true(disk != "")
    assert_eq(disk, default_prompt(name))
  }
}

///|
test "materialize_default_prompts writes missing files and preserves existing files" {
  let dir = prompt_test_tmpdir("materialize")
  ignore(@sys.rm_rf(dir))
  assert_true(@sys.create_dir_all(dir + "/.choir/prompts/skills"))
  let custom_path = dir + "/.choir/prompts/skills/audit.md"
  assert_true(@sys.write_file_sync(custom_path, "custom audit\n"))

  match materialize_default_prompts(dir) {
    Ok(_) => ()
    Err(e) => {
      fail("materialize_default_prompts failed: " + e.message())
      return
    }
  }

  assert_eq(@sys.read_file(custom_path), "custom audit\n")
  for name in all_prompt_names() {
    let path = prompt_path(name, dir)
    assert_true(@sys.path_exists(path))
    if name != PromptName::AuditSkill {
      assert_eq(@sys.read_file(path), default_prompt(name))
    }
  }

  ignore(@sys.rm_rf(dir))
}
