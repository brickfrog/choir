///|
let native_git_max_tree_entries : Int = 100000

///|
let native_git_max_blob_bytes : Int = 64 * 1024 * 1024

///|
let native_git_max_aggregate_blob_bytes : Int = 1024 * 1024 * 1024

///|
let native_git_max_path_bytes : Int = 4095

///|
let native_git_max_path_component_bytes : Int = 255

///|
let native_git_max_aggregate_path_bytes : Int = 64 * 1024 * 1024

///|
let native_git_max_symlink_target_bytes : Int = 4095

///|
let native_git_max_aggregate_symlink_target_bytes : Int = 64 * 1024 * 1024

///|
let native_git_max_symlink_batch : Int = 1024

///|
let native_git_staging_timeout_ms : Int = 120000

///|
let native_git_staging_diagnostic_limit_bytes : Int = 1024 * 1024

///|
let native_git_manifest_capture_limit_bytes : Int = native_git_max_aggregate_path_bytes +
  128 * native_git_max_tree_entries

///|
priv struct NativeGitTreeEntry {
  path : String
  oid : String
  is_directory : Bool
  is_symlink : Bool
}

///|
priv struct NativeGitSymlinkObject {
  oid : String
  size : Int
}

///|
priv struct NativeGitTreeManifest {
  entries : Array[NativeGitTreeEntry]
  entries_by_path : Map[String, NativeGitTreeEntry]
  symlinks : Array[NativeGitTreeEntry]
  symlink_objects : Array[NativeGitSymlinkObject]
  aggregate_blob_bytes : Int
  aggregate_path_bytes : Int
}

///|
fn native_git_tree_unsafe() -> @types.ChoirError {
  native_git_workspace_error("tree manifest is unsafe")
}

///|
fn native_git_tree_limit_exceeded() -> @types.ChoirError {
  native_git_workspace_error("tree limit exceeded")
}

///|
fn native_git_checked_metadata_total(
  current : Int,
  addition : Int,
  maximum : Int,
) -> Int? {
  if current < 0 || addition < 0 || current > maximum - addition {
    None
  } else {
    Some(current + addition)
  }
}

///|
fn native_git_tree_entry_count_allowed(count : Int) -> Bool {
  count >= 0 && count <= native_git_max_tree_entries
}

///|
fn native_git_ascii_token(bytes : BytesView, start : Int, end : Int) -> String? {
  if start < 0 || end <= start || end > bytes.length() {
    return None
  }
  for index = start; index < end; index = index + 1 {
    if bytes[index].to_int() >= 128 {
      return None
    }
  }
  Some(@utf8.decode(bytes[start:end]) catch { _ => return None })
}

///|
fn native_git_ascii_fields(bytes : BytesView) -> Array[String]? {
  let fields : Array[String] = []
  let mut cursor = 0
  if bytes.length() == 0 || bytes[0] == (0x20 : Byte) {
    return None
  }
  while cursor < bytes.length() {
    let start = cursor
    while cursor < bytes.length() && bytes[cursor] != (0x20 : Byte) {
      cursor = cursor + 1
    }
    match native_git_ascii_token(bytes, start, cursor) {
      Some(value) => fields.push(value)
      None => return None
    }
    if cursor < bytes.length() {
      while cursor < bytes.length() && bytes[cursor] == (0x20 : Byte) {
        cursor = cursor + 1
      }
      if cursor == bytes.length() {
        return None
      }
    }
  }
  Some(fields)
}

///|
fn native_git_decimal(value : String) -> Int? {
  if value == "" {
    return None
  }
  let mut parsed = 0
  for index = 0; index < value.length(); index = index + 1 {
    let code = value[index].to_int()
    if code < '0'.to_int() || code > '9'.to_int() {
      return None
    }
    let digit = code - '0'.to_int()
    if parsed > (2147483647 - digit) / 10 {
      return None
    }
    parsed = parsed * 10 + digit
  }
  Some(parsed)
}

///|
fn native_git_valid_object_id(value : String, oid_length : Int) -> Bool {
  value.length() == oid_length && @git_integration.valid_hex_oid_text(value)
}

///|
fn native_git_valid_manifest_path_bytes(path : BytesView) -> Bool {
  if path.length() == 0 ||
    path.length() > native_git_max_path_bytes ||
    path[0] == (0x2f : Byte) ||
    path[path.length() - 1] == (0x2f : Byte) {
    return false
  }
  let mut component_start = 0
  for index = 0; index <= path.length(); index = index + 1 {
    if index == path.length() || path[index] == (0x2f : Byte) {
      let length = index - component_start
      if length == 0 || length > native_git_max_path_component_bytes {
        return false
      }
      if length == 1 && path[component_start] == (0x2e : Byte) {
        return false
      }
      if length == 2 &&
        path[component_start] == (0x2e : Byte) &&
        path[component_start + 1] == (0x2e : Byte) {
        return false
      }
      component_start = index + 1
    }
  }
  true
}

///|
fn native_git_manifest_entry_kind(
  mode : String,
  object_type : String,
  size_field : String,
) -> (Bool, Bool, Int)? {
  match (mode, object_type, size_field) {
    ("040000", "tree", "-") => Some((true, false, 0))
    ("100644", "blob", size) =>
      match native_git_decimal(size) {
        Some(value) => Some((false, false, value))
        None => None
      }
    ("100755", "blob", size) =>
      match native_git_decimal(size) {
        Some(value) => Some((false, false, value))
        None => None
      }
    ("120000", "blob", size) =>
      match native_git_decimal(size) {
        Some(value) => Some((false, true, value))
        None => None
      }
    _ => None
  }
}

///|
fn native_git_path_components(path : String) -> Array[String] {
  let components : Array[String] = []
  for component in path.split("/") {
    components.push(component.to_owned())
  }
  components
}

///|
fn native_git_join_path_components(
  components : Array[String],
  length? : Int = components.length(),
) -> String {
  let builder = StringBuilder::new()
  for index = 0; index < length; index = index + 1 {
    if index > 0 {
      builder.write_char('/')
    }
    builder.write_string(components[index])
  }
  builder.to_string()
}

///|
fn native_git_validate_manifest_parents(
  entries : Map[String, NativeGitTreeEntry],
) -> Bool {
  for path in entries.keys() {
    let components = native_git_path_components(path)
    if components.length() > 1 {
      let parent = native_git_join_path_components(
        components,
        length=components.length() - 1,
      )
      match entries.get(parent) {
        Some(entry) if entry.is_directory => ()
        _ => return false
      }
    }
  }
  true
}

///|
fn parse_native_git_tree_manifest(
  bytes : Bytes,
  oid_length : Int,
) -> Result[NativeGitTreeManifest, @types.ChoirError] {
  if (oid_length != 40 && oid_length != 64) ||
    bytes.length() > native_git_manifest_capture_limit_bytes {
    return Err(native_git_tree_limit_exceeded())
  }
  let entries : Array[NativeGitTreeEntry] = []
  let entries_by_path : Map[String, NativeGitTreeEntry] = Map([])
  let symlinks : Array[NativeGitTreeEntry] = []
  let symlink_objects : Array[NativeGitSymlinkObject] = []
  let symlink_object_sizes : Map[String, Int] = Map([])
  let object_facts : Map[String, String] = Map([])
  let mut aggregate_blob_bytes = 0
  let mut aggregate_path_bytes = 0
  let mut aggregate_symlink_target_bytes = 0
  let mut cursor = 0
  while cursor < bytes.length() {
    if !native_git_tree_entry_count_allowed(entries.length() + 1) {
      return Err(native_git_tree_limit_exceeded())
    }
    let record_start = cursor
    while cursor < bytes.length() && bytes[cursor] != (0x00 : Byte) {
      cursor = cursor + 1
    }
    if cursor >= bytes.length() || cursor == record_start {
      return Err(native_git_tree_unsafe())
    }
    let record_end = cursor
    cursor = cursor + 1
    let mut tab = -1
    for index = record_start; index < record_end; index = index + 1 {
      if bytes[index] == (0x09 : Byte) {
        tab = index
        break
      }
    }
    if tab <= record_start || tab + 1 >= record_end {
      return Err(native_git_tree_unsafe())
    }
    let fields = match native_git_ascii_fields(bytes[record_start:tab]) {
      Some(value) => value
      None => return Err(native_git_tree_unsafe())
    }
    if fields.length() != 4 ||
      !native_git_valid_object_id(fields[2], oid_length) {
      return Err(native_git_tree_unsafe())
    }
    let (is_directory, is_symlink, size) = match
      native_git_manifest_entry_kind(fields[0], fields[1], fields[3]) {
      Some(value) => value
      None => return Err(native_git_tree_unsafe())
    }
    let object_fact = if is_directory {
      "tree"
    } else {
      "blob:" + size.to_string()
    }
    match object_facts.get(fields[2]) {
      Some(observed) if observed != object_fact =>
        return Err(native_git_tree_unsafe())
      Some(_) => ()
      None => object_facts[fields[2]] = object_fact
    }
    let raw_path = bytes[tab + 1:record_end]
    if !native_git_valid_manifest_path_bytes(raw_path) {
      return Err(native_git_tree_unsafe())
    }
    let path = @utf8.decode(raw_path) catch {
      _ => return Err(native_git_tree_unsafe())
    }
    if path == ".git" ||
      path.has_prefix(".git/") ||
      entries_by_path.get(path) is Some(_) {
      return Err(native_git_tree_unsafe())
    }
    if path == ".choir" && !is_directory {
      return Err(native_git_tree_unsafe())
    }
    aggregate_path_bytes = match
      native_git_checked_metadata_total(
        aggregate_path_bytes,
        raw_path.length(),
        native_git_max_aggregate_path_bytes,
      ) {
      Some(value) => value
      None => return Err(native_git_tree_limit_exceeded())
    }
    if !is_directory {
      if size > native_git_max_blob_bytes {
        return Err(native_git_tree_limit_exceeded())
      }
      aggregate_blob_bytes = match
        native_git_checked_metadata_total(
          aggregate_blob_bytes, size, native_git_max_aggregate_blob_bytes,
        ) {
        Some(value) => value
        None => return Err(native_git_tree_limit_exceeded())
      }
    }
    let entry : NativeGitTreeEntry = {
      path,
      oid: fields[2],
      is_directory,
      is_symlink,
    }
    entries.push(entry)
    entries_by_path[path] = entry
    if is_symlink {
      if size > native_git_max_symlink_target_bytes {
        return Err(native_git_tree_limit_exceeded())
      }
      aggregate_symlink_target_bytes = match
        native_git_checked_metadata_total(
          aggregate_symlink_target_bytes, size, native_git_max_aggregate_symlink_target_bytes,
        ) {
        Some(value) => value
        None => return Err(native_git_tree_limit_exceeded())
      }
      symlinks.push(entry)
      match symlink_object_sizes.get(entry.oid) {
        Some(observed_size) if observed_size != size =>
          return Err(native_git_tree_unsafe())
        Some(_) => ()
        None => {
          symlink_object_sizes[entry.oid] = size
          symlink_objects.push({ oid: entry.oid, size })
        }
      }
    }
  }
  if !native_git_validate_manifest_parents(entries_by_path) {
    return Err(native_git_tree_unsafe())
  }
  Ok({
    entries,
    entries_by_path,
    symlinks,
    symlink_objects,
    aggregate_blob_bytes,
    aggregate_path_bytes,
  })
}

///|
fn native_git_symlink_object_batches(
  objects : Array[NativeGitSymlinkObject],
) -> Array[Array[NativeGitSymlinkObject]] {
  let batches : Array[Array[NativeGitSymlinkObject]] = []
  let mut current : Array[NativeGitSymlinkObject] = []
  for object in objects {
    if current.length() == native_git_max_symlink_batch {
      batches.push(current)
      current = []
    }
    current.push(object)
  }
  if current.length() > 0 {
    batches.push(current)
  }
  batches
}

///|
fn native_git_cat_file_batch_stdin(
  objects : Array[NativeGitSymlinkObject],
) -> Bytes {
  let builder = StringBuilder::new()
  for object in objects {
    builder.write_string(object.oid)
    builder.write_char('\n')
  }
  @utf8.encode(builder.to_string())
}

///|
fn native_git_cat_file_batch_output_limit(
  objects : Array[NativeGitSymlinkObject],
) -> Int? {
  let mut limit = 0
  for object in objects {
    if object.size < 0 || limit > 2147483647 - object.size - 128 {
      return None
    }
    limit = limit + object.size + 128
  }
  Some(limit)
}

///|
fn parse_native_git_cat_file_batch(
  bytes : Bytes,
  objects : Array[NativeGitSymlinkObject],
) -> Result[Map[String, String], @types.ChoirError] {
  let targets : Map[String, String] = Map([])
  let mut cursor = 0
  for expected in objects {
    let header_start = cursor
    while cursor < bytes.length() && bytes[cursor] != (0x0a : Byte) {
      cursor = cursor + 1
    }
    if cursor >= bytes.length() || cursor - header_start > 127 {
      return Err(native_git_tree_unsafe())
    }
    let fields = match native_git_ascii_fields(bytes[header_start:cursor]) {
      Some(value) => value
      None => return Err(native_git_tree_unsafe())
    }
    cursor = cursor + 1
    if fields.length() != 3 ||
      fields[0] != expected.oid ||
      fields[1] != "blob" ||
      native_git_decimal(fields[2]) != Some(expected.size) ||
      expected.size > bytes.length() - cursor {
      return Err(native_git_tree_unsafe())
    }
    let content = bytes[cursor:cursor + expected.size]
    cursor = cursor + expected.size
    if cursor >= bytes.length() || bytes[cursor] != (0x0a : Byte) {
      return Err(native_git_tree_unsafe())
    }
    cursor = cursor + 1
    for byte in content {
      if byte == (0x00 : Byte) {
        return Err(native_git_tree_unsafe())
      }
    }
    let target = @utf8.decode(content) catch {
      _ => return Err(native_git_tree_unsafe())
    }
    targets[expected.oid] = target
  }
  if cursor != bytes.length() {
    return Err(native_git_tree_unsafe())
  }
  Ok(targets)
}

///|
fn native_git_lexical_symlink_target(
  link_path : String,
  target : String,
) -> String? {
  let target_bytes = @utf8.encode(target)
  if target == "" ||
    target_bytes.length() > native_git_max_symlink_target_bytes ||
    target.has_prefix("/") ||
    target.has_suffix("/") ||
    target.contains("//") ||
    target.contains("\u{0000}") {
    return None
  }
  let base = native_git_path_components(link_path)
  ignore(base.pop())
  let mut saw_normal_target_component = false
  for raw_component in target.split("/") {
    let component = raw_component.to_owned()
    let component_bytes = @utf8.encode(component)
    if component == "" ||
      component == "." ||
      component_bytes.length() > native_git_max_path_component_bytes {
      return None
    }
    if component == ".." {
      if saw_normal_target_component || base.pop() is None {
        return None
      }
    } else {
      saw_normal_target_component = true
      base.push(component)
    }
  }
  if base.length() == 0 {
    return None
  }
  let resolved = native_git_join_path_components(base)
  if @utf8.encode(resolved).length() > native_git_max_path_bytes {
    None
  } else {
    Some(resolved)
  }
}

///|
priv enum NativeGitPathEvaluation {
  NativeGitPathResolved(String)
  NativeGitPathDepends(String, String)
  NativeGitPathUnsafe
}

///|
fn native_git_evaluate_resolved_path(
  path : String,
  entries : Map[String, NativeGitTreeEntry],
) -> NativeGitPathEvaluation {
  let components = native_git_path_components(path)
  let builder = StringBuilder::new()
  for index = 0; index < components.length(); index = index + 1 {
    if index > 0 {
      builder.write_char('/')
    }
    builder.write_string(components[index])
    let prefix = builder.to_string()
    match entries.get(prefix) {
      Some(entry) if entry.is_symlink => {
        let suffix_builder = StringBuilder::new()
        for suffix_index = index + 1
            suffix_index < components.length()
            suffix_index = suffix_index + 1 {
          suffix_builder.write_char('/')
          suffix_builder.write_string(components[suffix_index])
        }
        return NativeGitPathDepends(prefix, suffix_builder.to_string())
      }
      Some(entry) if index + 1 < components.length() && !entry.is_directory =>
        return NativeGitPathUnsafe
      Some(_) => ()
      None => return NativeGitPathUnsafe
    }
  }
  NativeGitPathResolved(path)
}

///|
fn validate_native_git_symlink_graph(
  manifest : NativeGitTreeManifest,
  object_targets : Map[String, String],
) -> Result[Unit, @types.ChoirError] {
  let initial_paths : Map[String, String] = Map([])
  for link in manifest.symlinks {
    let target = match object_targets.get(link.oid) {
      Some(value) => value
      None => return Err(native_git_tree_unsafe())
    }
    let initial = match native_git_lexical_symlink_target(link.path, target) {
      Some(value) => value
      None => return Err(native_git_tree_unsafe())
    }
    initial_paths[link.path] = initial
  }

  let colors : Map[String, Int] = Map([])
  let working : Map[String, String] = Map([])
  let resolved : Map[String, String] = Map([])
  for link in manifest.symlinks {
    if colors.get(link.path) == Some(2) {
      continue
    }
    let stack : Array[String] = [link.path]
    colors[link.path] = 1
    working[link.path] = initial_paths.get(link.path).unwrap()
    while stack.length() > 0 {
      let current = stack.last().unwrap()
      let candidate = working.get(current).unwrap()
      match
        native_git_evaluate_resolved_path(candidate, manifest.entries_by_path) {
        NativeGitPathUnsafe => return Err(native_git_tree_unsafe())
        NativeGitPathResolved(value) => {
          resolved[current] = value
          colors[current] = 2
          ignore(stack.pop())
        }
        NativeGitPathDepends(dependency, suffix) =>
          match colors.get(dependency) {
            Some(1) => return Err(native_git_tree_unsafe())
            Some(2) => {
              let next = resolved.get(dependency).unwrap() + suffix
              if @utf8.encode(next).length() > native_git_max_path_bytes {
                return Err(native_git_tree_unsafe())
              }
              working[current] = next
            }
            _ => {
              let dependency_initial = match initial_paths.get(dependency) {
                Some(value) => value
                None => return Err(native_git_tree_unsafe())
              }
              colors[dependency] = 1
              working[dependency] = dependency_initial
              stack.push(dependency)
            }
          }
      }
    }
  }
  Ok(())
}

///|
fn native_git_archive_ceiling(manifest : NativeGitTreeManifest) -> Int? {
  let native_file_size_max = 2147483647
  let mut total = manifest.aggregate_blob_bytes
  if manifest.aggregate_path_bytes > (native_file_size_max - 1 - total) / 2 {
    return None
  }
  total = total + manifest.aggregate_path_bytes * 2
  if manifest.entries.length() > (native_file_size_max - 1 - total) / 4096 {
    return None
  }
  total = total + manifest.entries.length() * 4096
  if total > native_file_size_max - 1 - 1024 * 1024 {
    return None
  }
  Some(total + 1024 * 1024)
}

///|
fn native_git_test_tree_record(
  mode : String,
  object_type : String,
  oid : String,
  size : String,
  path : String,
) -> String {
  mode + " " + object_type + " " + oid + " " + size + "\t" + path + "\u{0000}"
}

///|
fn native_git_test_manifest(
  records : Array[String],
) -> Result[NativeGitTreeManifest, @types.ChoirError] {
  let builder = StringBuilder::new()
  for record in records {
    builder.write_string(record)
  }
  parse_native_git_tree_manifest(@utf8.encode(builder.to_string()), 40)
}

///|
fn native_git_test_graph(
  records : Array[String],
  object_targets : Array[(String, String)],
) -> Bool {
  let manifest = match native_git_test_manifest(records) {
    Ok(value) => value
    Err(_) => return false
  }
  let targets : Map[String, String] = Map([])
  for pair in object_targets {
    targets[pair.0] = pair.1
  }
  validate_native_git_symlink_graph(manifest, targets) is Ok(_)
}

///|
fn native_git_test_append_bytes(buffer : Array[Byte], value : String) -> Unit {
  for byte in @utf8.encode(value) {
    buffer.push(byte)
  }
}

///|
fn native_git_test_cat_response(
  oid : String,
  object_type : String,
  declared_size : Int,
  content : Array[Byte],
  trailing? : Array[Byte] = [],
) -> Bytes {
  let bytes : Array[Byte] = []
  native_git_test_append_bytes(
    bytes,
    oid + " " + object_type + " " + declared_size.to_string() + "\n",
  )
  for byte in content {
    bytes.push(byte)
  }
  bytes.push((0x0a : Byte))
  for byte in trailing {
    bytes.push(byte)
  }
  Bytes::from_array(bytes)
}

///|
test "tree manifest count and metadata totals enforce exact boundaries" {
  assert_true(native_git_tree_entry_count_allowed(99999))
  assert_true(native_git_tree_entry_count_allowed(100000))
  assert_false(native_git_tree_entry_count_allowed(100001))
  assert_eq(
    native_git_checked_metadata_total(
      native_git_max_aggregate_blob_bytes - 1,
      0,
      native_git_max_aggregate_blob_bytes,
    ),
    Some(native_git_max_aggregate_blob_bytes - 1),
  )
  assert_eq(
    native_git_checked_metadata_total(
      native_git_max_aggregate_path_bytes - 1,
      0,
      native_git_max_aggregate_path_bytes,
    ),
    Some(native_git_max_aggregate_path_bytes - 1),
  )
  assert_eq(
    native_git_checked_metadata_total(
      native_git_max_aggregate_blob_bytes - 1,
      1,
      native_git_max_aggregate_blob_bytes,
    ),
    Some(native_git_max_aggregate_blob_bytes),
  )
  assert_eq(
    native_git_checked_metadata_total(
      native_git_max_aggregate_symlink_target_bytes - 1,
      1,
      native_git_max_aggregate_symlink_target_bytes,
    ),
    Some(native_git_max_aggregate_symlink_target_bytes),
  )
  assert_eq(
    native_git_checked_metadata_total(
      native_git_max_aggregate_blob_bytes, 1, native_git_max_aggregate_blob_bytes,
    ),
    None,
  )
  assert_eq(
    native_git_checked_metadata_total(
      native_git_max_aggregate_path_bytes - 1,
      1,
      native_git_max_aggregate_path_bytes,
    ),
    Some(native_git_max_aggregate_path_bytes),
  )
  assert_eq(
    native_git_checked_metadata_total(
      native_git_max_aggregate_path_bytes, 1, native_git_max_aggregate_path_bytes,
    ),
    None,
  )
  assert_eq(
    native_git_checked_metadata_total(
      native_git_max_aggregate_symlink_target_bytes, 1, native_git_max_aggregate_symlink_target_bytes,
    ),
    None,
  )
}

///|
test "tree manifest blob size accepts the ceiling and rejects overflow" {
  let oid = "a".repeat(40)
  for size in [native_git_max_blob_bytes - 1, native_git_max_blob_bytes] {
    assert_true(
      native_git_test_manifest([
        native_git_test_tree_record(
          "100644",
          "blob",
          oid,
          size.to_string(),
          "file",
        ),
      ])
      is Ok(_),
    )
  }
  assert_true(
    native_git_test_manifest([
      native_git_test_tree_record(
        "100644",
        "blob",
        oid,
        (native_git_max_blob_bytes + 1).to_string(),
        "file",
      ),
    ])
    is Err(_),
  )
  assert_true(
    native_git_test_manifest([
      native_git_test_tree_record(
        "100644", "blob", oid, "999999999999999999999", "file",
      ),
    ])
    is Err(_),
  )
}

///|
test "tree manifest permits only contracted modes and protects control paths" {
  let oid = "a".repeat(40)
  let tree_oid = "d".repeat(40)
  assert_true(
    native_git_test_manifest([
      native_git_test_tree_record("040000", "tree", tree_oid, "-", "dir"),
      native_git_test_tree_record("100644", "blob", oid, "1", "plain"),
      native_git_test_tree_record("100755", "blob", oid, "1", "exec"),
      native_git_test_tree_record("120000", "blob", oid, "1", "link"),
    ])
    is Ok(_),
  )
  for
    record in [
      native_git_test_tree_record("160000", "commit", oid, "-", "submodule"),
      native_git_test_tree_record("100664", "blob", oid, "1", "special"),
      native_git_test_tree_record("040000", "blob", oid, "-", "wrong"),
      native_git_test_tree_record("100644", "blob", oid, "1", ".git"),
      native_git_test_tree_record("040000", "tree", oid, "-", ".git"),
      native_git_test_tree_record("100644", "blob", oid, "1", ".choir"),
      native_git_test_tree_record("100755", "blob", oid, "1", ".choir"),
      native_git_test_tree_record("120000", "blob", oid, "1", ".choir"),
      native_git_test_tree_record("160000", "commit", oid, "-", ".choir"),
    ] {
    assert_true(native_git_test_manifest([record]) is Err(_))
  }
  assert_true(native_git_test_manifest([]) is Ok(_))
  assert_true(
    native_git_test_manifest([
      native_git_test_tree_record("040000", "tree", tree_oid, "-", ".choir"),
      native_git_test_tree_record(
        "100644", "blob", oid, "1", ".choir/config.toml",
      ),
    ])
    is Ok(_),
  )
  assert_true(
    native_git_test_manifest([
      native_git_test_tree_record("040000", "tree", oid, "-", ".git"),
      native_git_test_tree_record("100644", "blob", oid, "1", ".git/config"),
    ])
    is Err(_),
  )
  assert_true(
    native_git_test_manifest([
      native_git_test_tree_record("100644", "blob", oid, "1", "first"),
      native_git_test_tree_record("100755", "blob", oid, "2", "second"),
    ])
    is Err(_),
  )
  assert_true(
    native_git_test_manifest([
      native_git_test_tree_record("040000", "tree", oid, "-", "dir"),
      native_git_test_tree_record("100644", "blob", oid, "1", "file"),
    ])
    is Err(_),
  )
}

///|
test "tree manifest validates path bytes components parents and UTF-8" {
  let component = "a".repeat(255)
  assert_true(native_git_valid_manifest_path_bytes(@utf8.encode(component)))
  assert_false(
    native_git_valid_manifest_path_bytes(@utf8.encode("a".repeat(256))),
  )
  let components = Array::make(16, component)
  let maximum_path = native_git_join_path_components(components)
  assert_eq(@utf8.encode(maximum_path).length(), 4095)
  assert_true(native_git_valid_manifest_path_bytes(@utf8.encode(maximum_path)))
  for path in ["", "/absolute", "trailing/", "a//b", "a/./b", "a/../b"] {
    assert_false(native_git_valid_manifest_path_bytes(@utf8.encode(path)))
  }
  let oid = "a".repeat(40)
  assert_true(
    native_git_test_manifest([
      native_git_test_tree_record("100644", "blob", oid, "1", "café"),
    ])
    is Ok(_),
  )
  assert_true(
    native_git_test_manifest([
      native_git_test_tree_record("100644", "blob", oid, "1", "file"),
      native_git_test_tree_record("100644", "blob", oid, "1", "file/child"),
    ])
    is Err(_),
  )
  let invalid : Array[Byte] = []
  native_git_test_append_bytes(invalid, "100644 blob " + oid + " 1\t")
  invalid.push((0xff : Byte))
  invalid.push((0x00 : Byte))
  assert_true(
    parse_native_git_tree_manifest(Bytes::from_array(invalid), 40) is Err(_),
  )
}

///|
test "cat-file batches preserve framing and reject corrupt object responses" {
  let first = "a".repeat(40)
  let second = "b".repeat(40)
  let objects : Array[NativeGitSymlinkObject] = [
    { oid: first, size: 3 },
    { oid: second, size: 1 },
  ]
  let bytes : Array[Byte] = []
  native_git_test_append_bytes(bytes, first + " blob 3\n")
  native_git_test_append_bytes(bytes, "x\ny\n")
  native_git_test_append_bytes(bytes, second + " blob 1\n")
  native_git_test_append_bytes(bytes, "z\n")
  let parsed = parse_native_git_cat_file_batch(
    Bytes::from_array(bytes),
    objects,
  ).unwrap()
  assert_eq(parsed.get(first), Some("x\ny"))
  assert_eq(parsed.get(second), Some("z"))
  assert_true(
    parse_native_git_cat_file_batch(
      native_git_test_cat_response(second, "blob", 3, [
        (0x61 : Byte),
        (0x62 : Byte),
        (0x63 : Byte),
      ]),
      [{ oid: first, size: 3 }],
    )
    is Err(_),
  )
  assert_true(
    parse_native_git_cat_file_batch(
      native_git_test_cat_response(first, "tree", 1, [(0x61 : Byte)]),
      [{ oid: first, size: 1 }],
    )
    is Err(_),
  )
  assert_true(
    parse_native_git_cat_file_batch(
      native_git_test_cat_response(first, "blob", 2, [(0x61 : Byte)]),
      [{ oid: first, size: 1 }],
    )
    is Err(_),
  )
  assert_true(
    parse_native_git_cat_file_batch(
      native_git_test_cat_response(first, "blob", 2, [(0x61 : Byte)]),
      [{ oid: first, size: 2 }],
    )
    is Err(_),
  )
  assert_true(
    parse_native_git_cat_file_batch(
      native_git_test_cat_response(first, "blob", 1, [(0x00 : Byte)]),
      [{ oid: first, size: 1 }],
    )
    is Err(_),
  )
  assert_true(
    parse_native_git_cat_file_batch(
      native_git_test_cat_response(first, "blob", 1, [(0xff : Byte)]),
      [{ oid: first, size: 1 }],
    )
    is Err(_),
  )
  assert_true(
    parse_native_git_cat_file_batch(
      native_git_test_cat_response(first, "blob", 1, [(0x61 : Byte)], trailing=[
        (0x78 : Byte),
      ]),
      [{ oid: first, size: 1 }],
    )
    is Err(_),
  )
}

///|
test "symlink targets enforce normalized bounded relative spellings" {
  assert_eq(
    native_git_lexical_symlink_target("AGENTS.md", "CLAUDE.md"),
    Some("CLAUDE.md"),
  )
  assert_eq(
    native_git_lexical_symlink_target("dir/AGENTS.md", "../CLAUDE.md"),
    Some("CLAUDE.md"),
  )
  for
    target in [
      "", "/absolute", "../escape", "a//b", "a/./b", "sub/../file", "file/",
    ] {
    assert_eq(native_git_lexical_symlink_target("link", target), None)
  }
  assert_eq(native_git_lexical_symlink_target("link", "a".repeat(256)), None)
  let components = Array::make(16, "a".repeat(255))
  let maximum_target = native_git_join_path_components(components)
  assert_eq(@utf8.encode(maximum_target).length(), 4095)
  assert_eq(
    native_git_lexical_symlink_target("link", maximum_target),
    Some(maximum_target),
  )
}

///|
test "symlink graph preserves repository links and resolves nested links" {
  let file_oid = "a".repeat(40)
  let agents_oid = "b".repeat(40)
  let nested_oid = "c".repeat(40)
  let tree_oid = "d".repeat(40)
  assert_true(
    native_git_test_graph(
      [
        native_git_test_tree_record(
          "100644", "blob", file_oid, "1", "CLAUDE.md",
        ),
        native_git_test_tree_record(
          "120000", "blob", agents_oid, "9", "AGENTS.md",
        ),
      ],
      [(agents_oid, "CLAUDE.md")],
    ),
  )
  assert_true(
    native_git_test_graph(
      [
        native_git_test_tree_record("040000", "tree", tree_oid, "-", "dir"),
        native_git_test_tree_record(
          "120000", "blob", agents_oid, "12", "dir/AGENTS.md",
        ),
        native_git_test_tree_record(
          "100644", "blob", file_oid, "1", "CLAUDE.md",
        ),
      ],
      [(agents_oid, "../CLAUDE.md")],
    ),
  )
  assert_true(
    native_git_test_graph(
      [
        native_git_test_tree_record("040000", "tree", tree_oid, "-", "real"),
        native_git_test_tree_record(
          "100644", "blob", file_oid, "1", "real/file",
        ),
        native_git_test_tree_record("120000", "blob", agents_oid, "4", "alias"),
        native_git_test_tree_record(
          "120000", "blob", nested_oid, "10", "through",
        ),
      ],
      [(agents_oid, "real"), (nested_oid, "alias/file")],
    ),
  )
}

///|
test "symlink graph rejects dangling cycles escapes and invalid prefixes" {
  let file_oid = "a".repeat(40)
  let first_oid = "b".repeat(40)
  let second_oid = "c".repeat(40)
  let base_file = native_git_test_tree_record(
    "100644", "blob", file_oid, "1", "file",
  )
  for target in ["missing", "/absolute", "../escape", "sub/../file"] {
    assert_false(
      native_git_test_graph(
        [
          base_file,
          native_git_test_tree_record(
            "120000",
            "blob",
            first_oid,
            target.length().to_string(),
            "link",
          ),
        ],
        [(first_oid, target)],
      ),
    )
  }
  assert_false(
    native_git_test_graph(
      [native_git_test_tree_record("120000", "blob", first_oid, "4", "self")],
      [(first_oid, "self")],
    ),
  )
  assert_false(
    native_git_test_graph(
      [
        native_git_test_tree_record("120000", "blob", first_oid, "1", "a"),
        native_git_test_tree_record("120000", "blob", second_oid, "1", "b"),
      ],
      [(first_oid, "b"), (second_oid, "a")],
    ),
  )
  assert_false(
    native_git_test_graph(
      [native_git_test_tree_record("120000", "blob", first_oid, "7", "prefix")],
      [(first_oid, "prefix/x")],
    ),
  )
  assert_false(
    native_git_test_graph(
      [
        base_file,
        native_git_test_tree_record("120000", "blob", first_oid, "10", "link"),
      ],
      [(first_oid, "file/child")],
    ),
  )
}
