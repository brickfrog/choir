///|
pub(all) struct DirectTakeCommand {
  surface : @control.ProviderSurfaceId
  instruction : String
  mutation_declaration : @control.MutationDeclaration
  verification_arguments : Array[String]
  verification_timeout_ms : Int64
  apply : Bool
} derive(Debug, Eq)

///|
fn direct_take_cli_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("choir take: " + detail)
}

///|
fn direct_take_provider(
  value : String,
) -> Result[@control.ProviderSurfaceId, @types.ChoirError] {
  match value {
    "claude" => Ok(@control.ProviderSurfaceId::ClaudeSubscriptionCli)
    "codex" => Ok(@control.ProviderSurfaceId::CodexSubscriptionCli)
    _ => Err(direct_take_cli_error("provider must be claude or codex"))
  }
}

///|
fn direct_take_verification_arguments(
  value : String,
) -> Result[Array[String], @types.ChoirError] {
  let arguments : Array[String] = []
  for raw in value.split(" ") {
    let argument = raw.to_owned().trim().to_owned()
    if argument != "" {
      arguments.push(argument)
    }
  }
  if arguments.length() == 0 || arguments.length() > 94 {
    return Err(
      direct_take_cli_error("verification must contain bounded Moon arguments"),
    )
  }
  let mut bytes = 0
  for argument in arguments {
    bytes = bytes + @utf8.encode(argument).length()
    if argument.contains("\u{00}") ||
      argument == "--target-dir" ||
      argument.has_prefix("--target-dir=") {
      return Err(
        direct_take_cli_error(
          "verification contains an invalid or Choir-controlled argument",
        ),
      )
    }
  }
  if bytes > 8192 || arguments[0] == "moon" || arguments[0].has_suffix("/moon") {
    return Err(
      direct_take_cli_error(
        "verification must start with a Moon subcommand, not the executable",
      ),
    )
  }
  Ok(arguments)
}

///|
fn direct_take_instruction(
  arguments : Array[String],
  start : Int,
) -> Result[String, @types.ChoirError] {
  let words : Array[String] = []
  for index = start; index < arguments.length(); index = index + 1 {
    words.push(arguments[index])
  }
  let instruction = words.join(" ").trim().to_owned()
  let bytes = @utf8.encode(instruction)
  if bytes.length() == 0 ||
    bytes.length() > 8192 ||
    instruction.contains("\u{00}") {
    Err(direct_take_cli_error("instruction is empty or exceeds 8192 bytes"))
  } else {
    Ok(instruction)
  }
}

///|
/// Parse the daemon-free Take surface. Choosing a provider is explicit because
/// dispatch spends that subscription's allowance; omission never silently
/// selects a paid surface. The first positional argument begins the instruction
/// and consumes the remainder, so ordinary prompts do not need one flag per
/// word. Use `--` when an instruction itself begins with a dash.
pub fn parse_direct_take_command(
  arguments : Array[String],
) -> Result[DirectTakeCommand, @types.ChoirError] {
  let mut surface : @control.ProviderSurfaceId? = None
  let scopes : Array[@control.RepoPath] = []
  let mut verification_arguments : Array[String]? = None
  let mut verification_timeout_ms = 120000L
  let mut timeout_seen = false
  let mut apply = false
  let mut index = 0
  let mut instruction_start = -1
  while index < arguments.length() {
    let argument = arguments[index]
    if argument == "--" {
      instruction_start = index + 1
      break
    }
    if !argument.has_prefix("-") {
      instruction_start = index
      break
    }
    match argument {
      "--provider" => {
        if surface is Some(_) || index + 1 >= arguments.length() {
          return Err(
            direct_take_cli_error("provider is missing or specified twice"),
          )
        }
        surface = Some(
          match direct_take_provider(arguments[index + 1]) {
            Ok(value) => value
            Err(error) => return Err(error)
          },
        )
        index = index + 2
      }
      "--scope" => {
        if index + 1 >= arguments.length() || scopes.length() >= 64 {
          return Err(
            direct_take_cli_error("scope is missing or exceeds 64 paths"),
          )
        }
        let path = @control.RepoPath(arguments[index + 1])
        match @control.validate_repo_path(path, fn(_) { true }) {
          Ok(_) => ()
          Err(_) => return Err(direct_take_cli_error("scope path is invalid"))
        }
        if scopes.contains(path) {
          return Err(direct_take_cli_error("scope path is duplicated"))
        }
        scopes.push(path)
        index = index + 2
      }
      "--verify" => {
        if verification_arguments is Some(_) || index + 1 >= arguments.length() {
          return Err(
            direct_take_cli_error("verification is missing or specified twice"),
          )
        }
        verification_arguments = Some(
          match direct_take_verification_arguments(arguments[index + 1]) {
            Ok(value) => value
            Err(error) => return Err(error)
          },
        )
        index = index + 2
      }
      "--verify-timeout-ms" => {
        if timeout_seen || index + 1 >= arguments.length() {
          return Err(
            direct_take_cli_error(
              "verification timeout is missing or specified twice",
            ),
          )
        }
        verification_timeout_ms = @string.parse_int64(arguments[index + 1]) catch {
          _ =>
            return Err(
              direct_take_cli_error("verification timeout must be an integer"),
            )
        }
        if verification_timeout_ms <= 0L || verification_timeout_ms > 600000L {
          return Err(
            direct_take_cli_error(
              "verification timeout must be between 1 and 600000 milliseconds",
            ),
          )
        }
        timeout_seen = true
        index = index + 2
      }
      "--apply" => {
        if apply {
          return Err(direct_take_cli_error("--apply is specified twice"))
        }
        apply = true
        index = index + 1
      }
      _ => return Err(direct_take_cli_error("unknown option: " + argument))
    }
  }
  let selected_surface = match surface {
    Some(value) => value
    None => return Err(direct_take_cli_error("--provider is required"))
  }
  if instruction_start < 0 || instruction_start >= arguments.length() {
    return Err(direct_take_cli_error("instruction is required"))
  }
  let instruction = match
    direct_take_instruction(arguments, instruction_start) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let claims : Array[@control.MutationClaim] = []
  if scopes.length() == 0 {
    claims.push(@control.MutationClaim::RepositoryWide)
  } else {
    for path in scopes {
      claims.push(@control.MutationClaim::PathTree(path))
    }
  }
  Ok({
    surface: selected_surface,
    instruction,
    mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration(
      claims,
    ),
    verification_arguments: verification_arguments.unwrap_or([
      "test", "--target", "native",
    ]),
    verification_timeout_ms,
    apply,
  })
}
