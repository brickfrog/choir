///|
/// A Bead identity admitted for use at the `bd` process boundary.
///
/// The value is intentionally not normalized. Callers that receive an
/// identifier over a tool surface must either pass the exact admitted text to
/// `bd` or reject it.
pub struct BeadCliIdentifier(String) derive(Debug, Eq)

///|
fn bead_cli_identifier_ascii_alphanumeric(character : Char) -> Bool {
  (character >= 'a' && character <= 'z') ||
  (character >= 'A' && character <= 'Z') ||
  (character >= '0' && character <= '9')
}

///|
/// Admit the deliberately small identifier grammar supported at the Beads CLI
/// boundary. The error omits the rejected value so control characters and
/// other hostile input cannot be reflected into diagnostics.
pub fn BeadCliIdentifier::try_parse(
  value : String,
) -> Result[BeadCliIdentifier, @types.ChoirError] {
  let characters = value.to_array()
  if characters.length() == 0 || characters.length() > 160 {
    return Err(
      @types.ChoirError::validation_error("invalid Bead CLI identifier"),
    )
  }
  for index, character in characters {
    let valid = bead_cli_identifier_ascii_alphanumeric(character) ||
      (
        index > 0 &&
        (
          character == '-' ||
          character == '_' ||
          character == '.' ||
          character == ':'
        )
      )
    if !valid {
      return Err(
        @types.ChoirError::validation_error("invalid Bead CLI identifier"),
      )
    }
  }
  Ok(BeadCliIdentifier(value))
}

///|
/// Return the exact identifier admitted by `try_parse`.
pub fn BeadCliIdentifier::text(self : BeadCliIdentifier) -> String {
  self.0
}
