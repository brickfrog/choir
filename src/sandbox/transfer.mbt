///|
pub(all) enum TransferEntryKind {
  TransferFile
  TransferDirectory
  TransferSymlink
  TransferHardlink
  TransferDevice
  TransferFifo
  TransferSocket
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct TransferEntry {
  path : String
  kind : TransferEntryKind
  size_bytes : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct TransferLimits {
  max_entries : Int
  max_total_bytes : Int64
  max_file_bytes : Int64
  max_depth : Int
  link_policy : TransferLinkPolicy
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum TransferLinkPolicy {
  TransferRejectLinks
  TransferAllowSymbolicLinks
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum TransferBlockReason {
  TransferInvalidLimits
  TransferEmptyPath
  TransferAbsolutePath(String)
  TransferTraversalPath(String)
  TransferEmptySegment(String)
  TransferBackslashPath(String)
  TransferControlCharacter(String)
  TransferNonPortablePath(String)
  TransferDuplicatePath(String)
  TransferUnsupportedEntryType(String, TransferEntryKind)
  TransferNegativeSize(String)
  TransferDirectoryHasContentSize(String)
  TransferLinkHasContentSize(String)
  TransferEntryLimitExceeded(Int, Int)
  TransferTotalBytesExceeded(Int64, Int64)
  TransferFileBytesExceeded(String, Int64, Int64)
  TransferDepthExceeded(String, Int, Int)
  TransferDestinationSymlink(String)
  TransferDestinationNotDirectory(String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub struct ValidatedTransferManifest {
  entries : Array[TransferEntry]
  total_bytes : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn ValidatedTransferManifest::entries(
  self : ValidatedTransferManifest,
) -> Array[TransferEntry] {
  self.entries.copy()
}

///|
pub fn ValidatedTransferManifest::total_bytes(
  self : ValidatedTransferManifest,
) -> Int64 {
  self.total_bytes
}

///|
pub(all) enum TransferManifestDecision {
  TransferManifestAccepted(ValidatedTransferManifest)
  TransferManifestRejected(TransferBlockReason)
} derive(Debug, Eq, ToJson, FromJson)

///|
fn transfer_listing_error(message : String) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "sandbox transfer archive listing is invalid: " + message,
  )
}

///|
fn transfer_listing_token(line : String, start : Int) -> (String, Int)? {
  let mut index = start
  while index < line.length() && line[index] == ' ' {
    index = index + 1
  }
  if index == line.length() {
    return None
  }
  let begin = index
  while index < line.length() && line[index] != ' ' {
    index = index + 1
  }
  Some((line[begin:index].to_owned(), index))
}

///|
fn transfer_listing_path(line : String, start : Int) -> String? {
  let mut index = start
  while index < line.length() && line[index] == ' ' {
    index = index + 1
  }
  if index == line.length() {
    None
  } else {
    Some(line[index:].to_owned())
  }
}

///|
fn transfer_listing_quoted_path(
  raw : String,
  kind : TransferEntryKind,
) -> Result[String, @types.ChoirError] {
  if raw.length() < 2 || raw[0] != '"' {
    return Err(transfer_listing_error("path is not C-quoted"))
  }
  let mut end = 1
  while end < raw.length() && raw[end] != '"' {
    // The transfer grammar rejects every name that GNU tar must escape. This
    // keeps the listing parser unambiguous without decoding attacker-controlled
    // C/octal escape sequences.
    if raw[end] == '\\' {
      return Err(transfer_listing_error("escaped path is not portable"))
    }
    end = end + 1
  }
  if end == raw.length() {
    return Err(transfer_listing_error("quoted path is unterminated"))
  }
  let trailing = raw[end + 1:].to_owned()
  match kind {
    TransferFile | TransferDirectory if trailing != "" =>
      return Err(transfer_listing_error("path has trailing fields"))
    TransferSymlink if !trailing.has_prefix(" -> \"") =>
      return Err(transfer_listing_error("symbolic link target is malformed"))
    TransferHardlink if !trailing.has_prefix(" link to \"") =>
      return Err(transfer_listing_error("hardlink target is malformed"))
    _ => ()
  }
  Ok(raw[1:end].to_owned())
}

///|
fn transfer_listing_entry(
  line : String,
) -> Result[TransferEntry?, @types.ChoirError] {
  let mode = match transfer_listing_token(line, 0) {
    Some(value) => value
    None => return Err(transfer_listing_error("mode is absent"))
  }
  let owner = match transfer_listing_token(line, mode.1) {
    Some(value) => value
    None => return Err(transfer_listing_error("owner is absent"))
  }
  let size = match transfer_listing_token(line, owner.1) {
    Some(value) => value
    None => return Err(transfer_listing_error("size is absent"))
  }
  let date = match transfer_listing_token(line, size.1) {
    Some(value) => value
    None => return Err(transfer_listing_error("date is absent"))
  }
  let time = match transfer_listing_token(line, date.1) {
    Some(value) => value
    None => return Err(transfer_listing_error("time is absent"))
  }
  let raw_path = match transfer_listing_path(line, time.1) {
    Some(value) => value
    None => return Err(transfer_listing_error("path is absent"))
  }
  if mode.0.length() != 10 || !owner.0.contains("/") {
    return Err(transfer_listing_error("fixed verbose fields are malformed"))
  }
  let size_bytes = @string.parse_int(size.0) catch {
    _ => return Err(transfer_listing_error("size is not decimal"))
  }
  if size_bytes < 0 {
    return Err(transfer_listing_error("size is negative"))
  }
  let kind = match mode.0[0] {
    '-' => TransferFile
    'd' => TransferDirectory
    'l' => TransferSymlink
    'h' => TransferHardlink
    'b' | 'c' => TransferDevice
    'p' => TransferFifo
    's' => TransferSocket
    _ => return Err(transfer_listing_error("entry type is unsupported"))
  }
  let path_with_root = match transfer_listing_quoted_path(raw_path, kind) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if path_with_root == "./" && kind == TransferDirectory {
    return Ok(None)
  }
  let mut path = if path_with_root.has_prefix("./") {
    path_with_root[2:].to_owned()
  } else {
    path_with_root
  }
  if kind == TransferDirectory && path.has_suffix("/") {
    path = path[:path.length() - 1].to_owned()
  }
  Ok(Some({ path, kind, size_bytes: size_bytes.to_int64() }))
}

///|
pub fn parse_transfer_archive_listing(
  listing : String,
) -> Result[Array[TransferEntry], @types.ChoirError] {
  let entries : Array[TransferEntry] = []
  for raw in listing.split("\n") {
    if raw != "" {
      match transfer_listing_entry(raw.to_owned()) {
        Ok(Some(entry)) => entries.push(entry)
        Ok(None) => ()
        Err(error) => return Err(error)
      }
    }
  }
  Ok(entries)
}

///|
pub fn repository_result_transfer_limits() -> TransferLimits {
  {
    max_entries: 32768,
    max_total_bytes: 536870912L,
    max_file_bytes: 134217728L,
    max_depth: 64,
    link_policy: TransferAllowSymbolicLinks,
  }
}

///|
fn transfer_path_decision(
  path : String,
  max_depth : Int,
) -> TransferBlockReason? {
  if path == "" {
    return Some(TransferEmptyPath)
  }
  if path.has_prefix("/") {
    return Some(TransferAbsolutePath(path))
  }
  if path.contains("\\") {
    return Some(TransferBackslashPath(path))
  }
  let segments = path.split("/").to_array()
  if segments.length() > max_depth {
    return Some(TransferDepthExceeded(path, segments.length(), max_depth))
  }
  for segment in segments {
    if segment == "" {
      return Some(TransferEmptySegment(path))
    }
    if segment == "." || segment == ".." {
      return Some(TransferTraversalPath(path))
    }
    for code_unit in segment {
      let code = code_unit.to_int()
      if code < 32 || code == 127 {
        return Some(TransferControlCharacter(path))
      }
      // The initial adapter deliberately admits a small, portable logical-root
      // grammar. Unicode is rejected rather than normalized inconsistently by
      // the host and guest filesystems.
      if code > 126 {
        return Some(TransferNonPortablePath(path))
      }
    }
  }
  None
}

///|
pub(all) enum TransferDestinationKind {
  TransferDestinationMissing
  TransferDestinationDirectory
  TransferDestinationSymlink
  TransferDestinationOther
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct TransferDestinationComponent {
  path : String
  kind : TransferDestinationKind
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn evaluate_transfer_manifest(
  entries : Array[TransferEntry],
  limits : TransferLimits,
) -> TransferManifestDecision {
  if limits.max_entries < 0 ||
    limits.max_total_bytes < 0L ||
    limits.max_file_bytes < 0L ||
    limits.max_depth <= 0 {
    return TransferManifestRejected(TransferInvalidLimits)
  }
  if entries.length() > limits.max_entries {
    return TransferManifestRejected(
      TransferEntryLimitExceeded(entries.length(), limits.max_entries),
    )
  }
  let seen : Map[String, Bool] = Map([])
  let accepted : Array[TransferEntry] = []
  let mut total = 0L
  for entry in entries {
    match transfer_path_decision(entry.path, limits.max_depth) {
      Some(reason) => return TransferManifestRejected(reason)
      None => ()
    }
    if seen.contains(entry.path) {
      return TransferManifestRejected(TransferDuplicatePath(entry.path))
    }
    seen[entry.path] = true
    match entry.kind {
      TransferFile => ()
      TransferDirectory =>
        if entry.size_bytes != 0L {
          return TransferManifestRejected(
            TransferDirectoryHasContentSize(entry.path),
          )
        }
      TransferSymlink if limits.link_policy == TransferAllowSymbolicLinks =>
        if entry.size_bytes != 0L {
          return TransferManifestRejected(
            TransferLinkHasContentSize(entry.path),
          )
        }
      kind =>
        return TransferManifestRejected(
          TransferUnsupportedEntryType(entry.path, kind),
        )
    }
    if entry.size_bytes < 0L {
      return TransferManifestRejected(TransferNegativeSize(entry.path))
    }
    if entry.size_bytes > limits.max_file_bytes {
      return TransferManifestRejected(
        TransferFileBytesExceeded(
          entry.path,
          entry.size_bytes,
          limits.max_file_bytes,
        ),
      )
    }
    total = total + entry.size_bytes
    if total > limits.max_total_bytes {
      return TransferManifestRejected(
        TransferTotalBytesExceeded(total, limits.max_total_bytes),
      )
    }
    accepted.push(entry)
  }
  TransferManifestAccepted({ entries: accepted, total_bytes: total })
}

///|
fn transfer_reason_label(reason : TransferBlockReason) -> String {
  match reason {
    TransferInvalidLimits => "invalid_limits"
    TransferEmptyPath => "empty_path"
    TransferAbsolutePath(_) => "absolute_path"
    TransferTraversalPath(_) => "traversal_path"
    TransferEmptySegment(_) => "empty_segment"
    TransferBackslashPath(_) => "backslash_path"
    TransferControlCharacter(_) => "control_character"
    TransferNonPortablePath(_) => "non_portable_path"
    TransferDuplicatePath(_) => "duplicate_path"
    TransferUnsupportedEntryType(_, _) => "unsupported_entry_type"
    TransferNegativeSize(_) => "negative_size"
    TransferDirectoryHasContentSize(_) => "directory_content_size"
    TransferLinkHasContentSize(_) => "link_content_size"
    TransferEntryLimitExceeded(_, _) => "entry_limit"
    TransferTotalBytesExceeded(_, _) => "total_bytes_limit"
    TransferFileBytesExceeded(_, _, _) => "file_bytes_limit"
    TransferDepthExceeded(_, _, _) => "depth_limit"
    TransferDestinationSymlink(_) => "destination_symlink"
    TransferDestinationNotDirectory(_) => "destination_not_directory"
  }
}

///|
pub fn validate_transfer_adoption_destination(
  components : Array[TransferDestinationComponent],
) -> Result[Unit, @types.ChoirError] {
  for component in components {
    match component.kind {
      TransferDestinationMissing | TransferDestinationDirectory => ()
      TransferDestinationSymlink =>
        return Err(
          @types.ChoirError::validation_error(
            "sandbox transfer rejected: " +
            transfer_reason_label(TransferDestinationSymlink(component.path)),
          ),
        )
      TransferDestinationOther =>
        return Err(
          @types.ChoirError::validation_error(
            "sandbox transfer rejected: " +
            transfer_reason_label(
              TransferDestinationNotDirectory(component.path),
            ),
          ),
        )
    }
  }
  Ok(())
}

///|
pub fn validate_transfer_manifest(
  entries : Array[TransferEntry],
  limits : TransferLimits,
) -> Result[ValidatedTransferManifest, @types.ChoirError] {
  match evaluate_transfer_manifest(entries, limits) {
    TransferManifestAccepted(manifest) => Ok(manifest)
    TransferManifestRejected(reason) =>
      Err(
        @types.ChoirError::validation_error(
          "sandbox transfer rejected: " + transfer_reason_label(reason),
        ),
      )
  }
}
