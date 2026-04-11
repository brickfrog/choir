///|
pub(all) struct KvStore {
  project_dir : String
}

///|
pub fn KvStore::new(project_dir : String) -> KvStore {
  { project_dir, }
}

///|
/// Flat single-segment keys for `.choir/kv/{key}` (no `/` — no subdirectories).
/// Rejects: empty string; bare `.`; leading `/`; any substring `..`; any
/// character outside `[a-zA-Z0-9._-]`.
pub fn validate_kv_storage_key(s : String) -> Result[Unit, @types.ChoirError] {
  if s == "" {
    return Err(@types.ChoirError::validation_error("key cannot be empty"))
  }
  if s == "." {
    return Err(@types.ChoirError::validation_error("key cannot be '.'"))
  }
  if s[0] == '/' {
    return Err(@types.ChoirError::validation_error("key cannot start with '/'"))
  }
  if s.contains("..") {
    return Err(@types.ChoirError::validation_error("key cannot contain '..'"))
  }
  if s.contains("/") {
    return Err(
      @types.ChoirError::validation_error(
        "KV keys must be flat single-segment names (no '/' characters)",
      ),
    )
  }
  for c in s {
    if !((c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' ||
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
/// Reads `.choir/kv/{key}` after validation. Returns [`None`] when the file is
/// missing or the trimmed contents are empty.
///
/// A key that fails [`validate_kv_storage_key`] is a **programmer error** for
/// this API: the process aborts after writing to stderr (invalid keys must not
/// be passed here; validate at the call site if input is untrusted).
///
/// **Trim vs `kv_get` tool:** [`KvStore::get`] trims for internal gate
/// comparisons; the `kv_get` MCP tool returns raw bytes so agents see the exact
/// stored value.
pub fn KvStore::get(self : KvStore, key : String) -> String? {
  match validate_kv_storage_key(key) {
    Err(_) => {
      @sys.write_stderr("KvStore::get called with invalid key: " + key + "\n")
      panic()
    }
    Ok(_) => {
      let path = self.project_dir + "/.choir/kv/" + key
      // @sys.read_file returns "" for missing/unreadable files (see sys/io.mbt); None is returned for empty result.
      // KvStore::get trims for internal gate comparisons; kv_get returns raw contents (see dispatch.mbt).
      let raw = @sys.read_file(path).trim().to_string()
      if raw == "" {
        None
      } else {
        Some(raw)
      }
    }
  }
}
