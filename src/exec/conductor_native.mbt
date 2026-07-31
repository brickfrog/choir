///|
fn native_conductor_error(detail : String) -> @types.Response {
  @types.Response::err_text("native Conductor: " + detail)
}

///|
/// Refuse to launch the Conductor against a Claude whose advertised surface no
/// longer matches the launch it is about to receive.
pub async fn validate_native_conductor_surface(
  probe? : async (@harness.HarnessProbeProcess) -> Result[
    @harness.HarnessProbeCapture,
    @types.ChoirError,
  ] = capture_harness_probe,
) -> Result[Unit, @types.ChoirError] {
  let capture = match
    probe({
      surface: @harness.ProviderSurface::ClaudeCli,
      command: @harness.HarnessProbeCommand::ProbeMainHelp,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if capture.exit_code != 0 {
    return Err(
      @types.ChoirError::transport_error(
        "unqualified Conductor surface: claude --help exited with status " +
        capture.exit_code.to_string(),
      ),
    )
  }
  let findings = @harness.qualify_conductor_surface(
    capture.output,
    @harness.conductor_surface_flags(),
  )
  if @harness.conductor_surface_is_qualified(findings) {
    Ok(())
  } else {
    Err(
      @types.ChoirError::validation_error(
        findings
        .map(fn(finding) { @harness.conductor_surface_finding_text(finding) })
        .join("; "),
      ),
    )
  }
}

///|
pub async fn dispatch_native_conductor_request(
  project_dir : String,
  request : @types.Request,
  now? : Int64 = @env.now().reinterpret_as_int64() / 1000L,
  capture~ : async (@process_host.Command) -> (Int, String),
) -> @types.Response {
  if request.req_method != @types.WireMethod::WireToolsCall {
    return native_conductor_error("authenticated Conductor required")
  }
  if request.name.has_prefix("goal_") {
    @goal_host.dispatch_native_goal_request(project_dir, request, now, capture~)
  } else if request.name.has_prefix("task_") {
    @beads_host.dispatch_native_beads_request(project_dir, request, capture~)
  } else {
    native_conductor_error("unknown tool " + request.name)
  }
}
