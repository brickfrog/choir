///|
fn stop_run() -> Unit {
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(_root) {
      let config_content = @sys.read_file(".choir/config.toml")
      let config = match @config.parse_config(config_content) {
        Ok(cfg) => cfg
        Err(_) => @types.Config::default()
      }
      let session = config.terminal_session
      let purge = @env.args().contains("--purge")
      let pid_str = @sys.read_file(".choir/server.pid").trim().to_string()

      if pid_str != "" {
        @sys.write_stdout("Stopping server (PID \{pid_str})...\n")
        init_kill_server_pid_string(pid_str)
      }

      @sys.write_stdout("Killing session \{session}...\n")
      ignore(@exec.run(init_kill_session_command(session)) catch { _ => 0 })

      if purge {
        @sys.init_cleanup_purge_artifacts_native()
      } else {
        @sys.init_cleanup_runtime_artifacts_native()
      }
      @sys.write_stdout("Choir stopped.\n")
    })
  })
}

///|
/// Build release native, then start the UDS server — used only as the `watchexec`/`entr` child (see `dev_run`).
fn dev_reload_run() -> Unit {
  @async.run_async_main(async fn() {
    let st = @exec.run(@workspace.Command::{
      program: "moon",
      args: ["build", "--target", "native", "--release"],
      workdir: None,
    }) catch {
      _ => -1
    }
    if st != 0 {
      @sys.exit(st)
    }
  })
  serve_run()
}

///|
fn dev_run() -> Unit {
  @async.run_async_main(async fn() {
    let args = @env.args()
    let choir_exe = if args.length() >= 1 { args[0] } else { "choir" }
    match @exec.resolve_executable_in_path("watchexec") {
      Some(wx_path) => {
        let code = @exec.run(@exec.dev_watchexec_command(wx_path, choir_exe)) catch {
          _ => -1
        }
        @sys.exit(code)
      }
      None =>
        match @exec.resolve_executable_in_path("entr") {
          Some(entr_path) => {
            let code = @exec.run_dev_entr_watcher(entr_path, choir_exe) catch {
              _ => -1
            }
            @sys.exit(code)
          }
          None => {
            @sys.write_stdout(
              "choir dev: watchexec and entr not found, running without hot reload\n",
            )
            let st = @exec.run(@workspace.Command::{
              program: "moon",
              args: ["build", "--target", "native", "--release"],
              workdir: None,
            }) catch {
              _ => -1
            }
            if st != 0 {
              @sys.exit(st)
            }
            let st2 = @exec.run(@workspace.Command::{
              program: "choir",
              args: ["serve"],
              workdir: None,
            }) catch {
              _ => -1
            }
            @sys.exit(st2)
          }
        }
    }
  })
}

///|
fn reply_run() -> Unit {
  let args = @env.args()

  let mut id = ""
  let mut payload = ""
  let mut cancel = false
  let mut i = 2
  while i < args.length() {
    match args[i] {
      "--id" =>
        if i + 1 < args.length() {
          id = args[i + 1]
          i = i + 2
        } else {
          i = i + 1
        }
      "--payload" =>
        if i + 1 < args.length() {
          payload = args[i + 1]
          i = i + 2
        } else {
          i = i + 1
        }
      "--cancel" => {
        cancel = true
        i = i + 1
      }
      _ => i = i + 1
    }
  }

  if id == "" {
    @sys.write_stdout(
      "usage: choir reply --id <id> [--payload <json>] [--cancel]\n",
    )
    @sys.exit(1)
    return
  }

  let config_content = @sys.read_file(".choir/config.toml")
  let config = match @config.parse_config(config_content) {
    Ok(cfg) => cfg
    Err(_) => @types.Config::default()
  }

  let uds_fd = @uds.client_connect(config.listen_uds)
  if uds_fd < 0 {
    @sys.write_stdout(
      "error: cannot connect to server at \{config.listen_uds}\n",
    )
    @sys.exit(1)
    return
  }

  let reg_msg = "{\"method\":\"register\",\"role\":\"root\",\"name\":\"register\",\"args\":{\"agent_id\":\"system-reply\"}}\n"
  let reg_bytes = @utf8.encode(reg_msg)
  let mut written = 0
  while written < reg_bytes.length() {
    let n = @uds.write_bytes(
      uds_fd,
      reg_bytes,
      written,
      reg_bytes.length() - written,
    )
    if n <= 0 {
      break
    }
    written = written + n
  }

  let rbuf = FixedArray::make(1024, (0 : Byte))
  let _ = @uds.read_bytes(uds_fd, rbuf, 0, rbuf.length())

  let req_msg = {
      "method": "reply".to_json(),
      "role": "root".to_json(),
      "name": "reply".to_json(),
      "args": {
        "id": id.to_json(),
        "payload": payload.to_json(),
        "cancel": cancel.to_string().to_json(),
      }.to_json(),
    }
    .to_json()
    .stringify() +
    "\n"
  let req_bytes = @utf8.encode(req_msg)
  written = 0
  while written < req_bytes.length() {
    let n = @uds.write_bytes(
      uds_fd,
      req_bytes,
      written,
      req_bytes.length() - written,
    )
    if n <= 0 {
      break
    }
    written = written + n
  }

  let resp_buf = FixedArray::make(4096, (0 : Byte))
  let n = @uds.read_bytes(uds_fd, resp_buf, 0, resp_buf.length())
  if n > 0 {
    let resp = @utf8.decode_lossy(resp_buf.unsafe_reinterpret_as_bytes()[:n])
    @sys.write_stdout(resp + "\n")
  }

  @uds.close(uds_fd)
}

///|
fn watch_run() -> Unit {
  dev_run()
}
