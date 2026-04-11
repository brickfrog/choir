///|
pub(all) struct KvStore {
  project_dir : String
}

///|
pub fn KvStore::new(project_dir : String) -> KvStore {
  { project_dir, }
}

///|
/// Same rules as historical `kv_set` / `kv_get` parsing in tools: avoids empty
/// keys, `.` / `..` segments, absolute-style paths, embedded `..`, and characters
/// outside the safe set.
pub fn validate_kv_storage_key(s : String) -> Result[Unit, @types.ChoirError] {
  if s == "" {
    return Err(@types.ChoirError::validation_error("key cannot be empty"))
  }
  if s == "." || s == ".." {
    return Err(@types.ChoirError::validation_error("key cannot be '.' or '..'"))
  }
  if s[0] == '/' {
    return Err(@types.ChoirError::validation_error("key cannot start with '/'"))
  }
  if s.contains("..") {
    return Err(@types.ChoirError::validation_error("key cannot contain '..'"))
  }
  for c in s {
    if !((c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' ||
      c == '/' ||
      c == '.') {
      return Err(
        @types.ChoirError::validation_error(
          "invalid character in key: " + c.to_string(),
        ),
      )
    }
  }
  Ok(())
}

///|
pub fn KvStore::get(self : KvStore, key : String) -> String? {
  match validate_kv_storage_key(key) {
    Err(_) => None
    Ok(_) => {
      let path = self.project_dir + "/.choir/kv/" + key
      let raw = @sys.read_file(path).trim().to_string()
      if raw == "" {
        None
      } else {
        Some(raw)
      }
    }
  }
}
