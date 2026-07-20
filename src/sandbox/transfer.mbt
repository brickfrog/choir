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
