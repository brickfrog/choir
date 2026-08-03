///|
/// One retained successful invocation of `read_audit_context`.
pub(all) struct AuditContextReadObservation {
  digest : Digest
  cursor : Int
  total : Int
  next_cursor : Int?
  eof : Bool
  succeeded : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Passively prove that provider-owned reads covered the exact immutable
/// artifact once, in order, without having this gate perform any read itself.
pub fn validate_audit_context_read_coverage(
  expected_digest : Digest,
  reads : Array[AuditContextReadObservation],
) -> Result[Int, @types.ChoirError] {
  if !expected_digest.is_valid() || reads.length() == 0 {
    return Err(
      @types.ChoirError::validation_error("audit context read protocol failed"),
    )
  }
  let total = reads[0].total
  if total < 0 {
    return Err(
      @types.ChoirError::validation_error("audit context read protocol failed"),
    )
  }
  let mut covered = 0
  let mut observed_eof = false
  for read in reads {
    if observed_eof ||
      !read.succeeded ||
      read.digest != expected_digest ||
      read.total != total ||
      read.cursor != covered ||
      read.cursor < 0 ||
      read.cursor > total {
      return Err(
        @types.ChoirError::validation_error(
          "audit context read protocol failed",
        ),
      )
    }
    match read.next_cursor {
      Some(next) => {
        if read.eof ||
          next <= read.cursor ||
          next > total ||
          next - read.cursor > 131072 {
          return Err(
            @types.ChoirError::validation_error(
              "audit context read protocol failed",
            ),
          )
        }
        covered = next
      }
      None => {
        if !read.eof || total - read.cursor > 131072 {
          return Err(
            @types.ChoirError::validation_error(
              "audit context read protocol failed",
            ),
          )
        }
        covered = total
        observed_eof = true
      }
    }
  }
  if !observed_eof || covered != total {
    Err(
      @types.ChoirError::validation_error("audit context read protocol failed"),
    )
  } else {
    Ok(total)
  }
}

///|
pub fn retained_audit_context_reads(
  events : Array[HarnessEventEnvelope],
) -> Array[AuditContextReadObservation] {
  let reads : Array[AuditContextReadObservation] = []
  for event in events {
    match event.kind {
      HarnessAuditContextReadFinished(_, read) => reads.push(read)
      _ => ()
    }
  }
  reads
}
