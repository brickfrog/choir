///|
fn stop_run() -> Unit {
  let pid_text = @sys.read_file(".choir/run/server.pid").trim().to_owned()
  let pid = @string.parse_int(pid_text) catch { _ => 0 }
  if pid > 1 {
    @sys.write_stdout("Stopping choird (PID \{pid})...\n")
    @sys.kill_server_pid_sequence_best_effort(pid)
  }
  if @env.args().contains("--purge") {
    @sys.init_cleanup_purge_artifacts_native()
  } else {
    @sys.init_cleanup_runtime_artifacts_native()
  }
  @sys.write_stdout("Choir stopped.\n")
}

///|
fn reload_run() -> Unit {
  let config_content = @sys.read_file(".choir/config.toml")
  let local_content = @sys.read_file(".choir/config.local.toml")
  if config_content == "" {
    client_emit(@types.Response::Err("missing .choir/config.toml"))
    return
  }
  let config = match
    @config.parse_config(config_content, local_content=Some(local_content)) {
    Ok(cfg) => cfg
    Err(e) => {
      client_emit(@types.Response::Err(e.message()))
      return
    }
  }
  let binary_path = match @exec.reload_binary_path() {
    Ok(path) => path
    Err(e) => {
      client_emit(@types.Response::Err(e.message()))
      return
    }
  }
  let req : @types.Request = {
    req_method: "tools/call",
    role: @types.Role::TL,
    name: "server_reload",
    args: @types.RequestArgs::from_values({
      "binary_path": binary_path.to_json(),
    }),
  }
  match
    client_call_uds(
      @types.Role::TL,
      { ..config, agent_id: Some("root") },
      @types.LocalConfig::default(),
      req,
      register_if_needed=false,
    ) {
    Ok(resp) => client_emit(resp)
    Err(err) => client_emit(@types.Response::Err(err))
  }
}
