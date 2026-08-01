///|
pub(all) struct NativeControlRoot {
  project_dir : String
  socket_path : String
}

///|
pub fn native_project_control_root(
  cwd : String,
  create : Bool,
  canonicalize? : (String) -> String? = @sys.realpath_native,
  prepare? : (String, Bool) -> Bool = @sys.prepare_control_root,
) -> Result[NativeControlRoot, @types.ChoirError] {
  let project = match canonicalize(cwd) {
    Some(value) if value.has_prefix("/") && value != "/" => value
    _ =>
      return Err(
        @types.ChoirError::workspace_error(
          "project control root is not canonical",
        ),
      )
  }
  if !prepare(project, create) {
    return Err(
      @types.ChoirError::policy_blocked(
        "project .choir control root is not owner-controlled",
      ),
    )
  }
  Ok({ project_dir: project, socket_path: project + "/.choir/run/server.sock" })
}

///|
pub fn append_native_control_log(
  root : NativeControlRoot,
  line : String,
  append? : (String, String) -> Bool = @sys.append_control_log,
) -> Result[Unit, @types.ChoirError] {
  if append(root.project_dir, line) {
    Ok(())
  } else {
    Err(@types.ChoirError::workspace_error("daemon log append failed"))
  }
}

///|
pub fn open_native_control_log(
  root : NativeControlRoot,
  open? : (String) -> Int = @sys.open_control_log,
) -> Result[Int, @types.ChoirError] {
  let fd = open(root.project_dir)
  if fd >= 0 {
    Ok(fd)
  } else {
    Err(
      @types.ChoirError::policy_blocked(
        "daemon log is not an owned regular file",
      ),
    )
  }
}
