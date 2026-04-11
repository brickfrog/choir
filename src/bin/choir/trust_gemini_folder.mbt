///|
fn trusted_folders_json(existing : String, workspace : String) -> String {
  let json = @json.parse(existing) catch { _ => return "{}" }
  let obj = match json {
    Object(m) => m
    _ => {}
  }
  obj.set(workspace, "TRUST_FOLDER".to_json())
  obj.to_json().stringify()
}

///|
fn trust_gemini_folder_run() -> Unit {
  let args = @env.args()
  if args.length() < 3 {
    @sys.write_stdout("usage: choir trust-gemini-folder <workspace>\n")
    @sys.exit(1)
    return
  }
  let home = match @sys.getenv("HOME") {
    Some(path) =>
      if path == "" {
        @sys.write_stdout("error: HOME is not set\n")
        @sys.exit(1)
        return
      } else {
        path
      }
    None => {
      @sys.write_stdout("error: HOME is not set\n")
      @sys.exit(1)
      return
    }
  }
  let gemini_dir = home + "/.gemini"
  let trusted_path = gemini_dir + "/trustedFolders.json"
  ignore(@sys.create_dir_all(gemini_dir))
  let content = @sys.read_file(trusted_path)
  let updated = trusted_folders_json(content, args[2])
  if @sys.write_file_sync(trusted_path, updated) {
    @sys.write_stdout("trusted " + args[2] + "\n")
    @sys.exit(0)
  } else {
    @sys.write_stdout("error: failed to write " + trusted_path + "\n")
    @sys.exit(1)
  }
}

///|
test "trusted_folders_json preserves existing paths and adds workspace" {
  let updated = trusted_folders_json(
    "{\"/existing\":\"TRUST_FOLDER\"}", "/new/worktree",
  )
  let json = @json.parse(updated) catch { _ => ().to_json() }
  guard json is Object(parsed) else { panic() }
  assert_eq(parsed.get("/existing"), Some("TRUST_FOLDER".to_json()))
  assert_eq(parsed.get("/new/worktree"), Some("TRUST_FOLDER".to_json()))
}
