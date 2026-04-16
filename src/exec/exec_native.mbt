///|
/// Run the `entr` fallback for `choir dev` without `/bin/sh -c`: two native `find` invocations
/// (same argv as the former `(find …; find …) | entr …` pipeline), stdout streamed to `entr` stdin
/// (unbounded, matching the shell pipe); `entr` inherits the caller's stdout/stderr.
pub async fn run_dev_entr_watcher(
  entr_path : String,
  choir_exe : String,
) -> Int {
  let c1 = dev_entr_find_src_mbt_command()
  let c2 = dev_entr_find_toml_command()
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ => return -1
  }
  let entr = dev_entr_entr_command(entr_path, choir_exe)
  let pid = @process.spawn_orphan(entr.program, entr.args[:], stdin=stdin_read) catch {
    _ => {
      stdin_write.close()
      return -1
    }
  }
  run_find_and_pump_to(c1.program, c1.args, c1.workdir, stdin_write)
  run_find_and_pump_to(c2.program, c2.args, c2.workdir, stdin_write)
  stdin_write.close()
  @process.wait_pid(pid) catch {
    _ => -1
  }
}

///|
/// Read up to `max_bytes` from a pipe wired to process stdout (or stderr), close the reader,
/// and return the captured output as lossy UTF-8 plus the number of bytes read.
async fn drain_process_stdout(
  reader : @process.ReadFromProcess,
  max_bytes : Int,
) -> (String, Int) {
  let buf = FixedArray::make(max_bytes, (0 : Byte))
  let mut total = 0
  for ;; {
    if total >= buf.length() {
      break
    }
    let n = reader.read(buf, offset=total, max_len=buf.length() - total) catch {
      _ => 0
    }
    if n == 0 {
      break
    }
    total = total + n
  }
  reader.close()
  (@utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:total]), total)
}

///|
/// Stream one `find` stdout into `out` until EOF (no total size cap), then wait for the child.
async fn run_find_and_pump_to(
  program : String,
  args : Array[String],
  cwd : String?,
  out : @process.WriteToProcess,
) -> Unit {
  let (reader, writer) = @process.read_from_process() catch { _ => return }
  let pid = match cwd {
    Some(dir) =>
      @process.spawn_orphan(program, args[:], stdout=writer, cwd=dir) catch {
        _ => {
          reader.close()
          return
        }
      }
    None =>
      @process.spawn_orphan(program, args[:], stdout=writer) catch {
        _ => {
          reader.close()
          return
        }
      }
  }
  let buf = FixedArray::make(8192, (0 : Byte))
  for ;; {
    let n = reader.read(buf, offset=0, max_len=buf.length()) catch {
      _ => break
    }
    if n == 0 {
      break
    }
    let chunk = @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:n])
    ignore(out.write(chunk) catch { _ => () })
  }
  reader.close()
  ignore(@process.wait_pid(pid) catch { _ => -1 })
}

///|
/// Spawn `cmd` with argv (`program` + `args`) and optional `workdir`, redirecting stderr to the
/// same pipe as stdout (shell `2>&1` semantics). Capture up to 64KiB merged output, wait for exit.
/// Returns `(exit_code, output)`; negative `exit_code` means spawn/pipe/wait failure.
pub async fn capture_command_merged(cmd : @workspace.Command) -> (Int, String) {
  let (reader, writer) = @process.read_from_process() catch {
    _ => return (-1, "")
  }
  let prog = cmd.program
  let args = cmd.args[:]
  let pid = match cmd.workdir {
    Some(dir) =>
      @process.spawn_orphan(prog, args, stdout=writer, stderr=writer, cwd=dir) catch {
        _ => {
          reader.close()
          return (-1, "")
        }
      }
    None =>
      @process.spawn_orphan(prog, args, stdout=writer, stderr=writer) catch {
        _ => {
          reader.close()
          return (-1, "")
        }
      }
  }
  let (output, _) = drain_process_stdout(reader, 65536)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  (exit_code, output)
}

///|
/// Run `hook_path` as an executable (e.g. `*.sh` with shebang) with `stdin_body` written to stdin
/// (no trailing newline added; matches `printf '%s'` feeding a pipe). Stderr is merged into the
/// capture stream like shell `2>&1`. Returns `(exit_code, merged_output)`; negative `exit_code`
/// means spawn/pipe/wait failure.
pub async fn capture_hook_script_merged(
  hook_path : String,
  stdin_body : String,
  cwd : String?,
) -> (Int, String) {
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ => return (-1, "")
  }
  let (stdout_read, stdout_write) = @process.read_from_process() catch {
    _ => {
      stdin_write.close()
      return (-1, "")
    }
  }
  let argv : Array[String] = []
  let pid = match cwd {
    Some(dir) =>
      @process.spawn_orphan(
        hook_path,
        argv,
        stdin=stdin_read,
        stdout=stdout_write,
        stderr=stdout_write,
        cwd=dir,
      ) catch {
        _ => {
          stdin_write.close()
          stdout_read.close()
          return (-1, "")
        }
      }
    None =>
      @process.spawn_orphan(
        hook_path,
        argv,
        stdin=stdin_read,
        stdout=stdout_write,
        stderr=stdout_write,
      ) catch {
        _ => {
          stdin_write.close()
          stdout_read.close()
          return (-1, "")
        }
      }
  }
  ignore(stdin_write.write(stdin_body) catch { _ => () })
  stdin_write.close()
  let (output, _) = drain_process_stdout(stdout_read, 65536)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  (exit_code, output)
}

///|
/// Like [`capture_command_merged`], but only stdout is captured (stderr is not redirected to the
/// pipe). Matches shell `cmd >capture` without `2>&1` for JSON and other stdout-only protocols.
pub async fn capture_command_stdout(cmd : @workspace.Command) -> (Int, String) {
  let (reader, writer) = @process.read_from_process() catch {
    _ => return (-1, "")
  }
  let prog = cmd.program
  let args = cmd.args[:]
  let pid = match cmd.workdir {
    Some(dir) =>
      @process.spawn_orphan(prog, args, stdout=writer, cwd=dir) catch {
        _ => {
          reader.close()
          return (-1, "")
        }
      }
    None =>
      @process.spawn_orphan(prog, args, stdout=writer) catch {
        _ => {
          reader.close()
          return (-1, "")
        }
      }
  }
  let (output, _) = drain_process_stdout(reader, 65536)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  (exit_code, output)
}

///|
/// Run `plugin_command` under `timeout` (seconds), write `request_line` plus newline on stdin,
/// capture up to 64KiB of stdout (stderr discarded). When the command is a simple argv list
/// (no shell-only syntax), runs `timeout <sec> <argv...>` directly; otherwise falls back to
/// `timeout <sec> sh -c <plugin_command>`. See [`plugin_capture_uses_shell`].
pub async fn capture_plugin_shell_command(
  plugin_command : String,
  request_line : String,
  timeout_sec : Int,
) -> (Int, String) {
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ => return (-1, "")
  }
  let (stdout_read, stdout_write) = @process.read_from_process() catch {
    _ => {
      stdin_write.close()
      return (-1, "")
    }
  }
  let stderr_dest = @process.redirect_to_file("/dev/null") catch {
    _ => {
      stdin_write.close()
      stdout_read.close()
      return (-1, "")
    }
  }
  let parsed = parse_plugin_argv_line(plugin_command)
  let use_shell = plugin_capture_uses_shell(plugin_command)
  let timeout_args = if use_shell {
    return (-1, "")
  } else {
    match parsed {
      Some(words) => {
        let args : Array[String] = []
        args.push(timeout_sec.to_string())
        for w in words {
          args.push(w)
        }
        args
      }
      None => return (-1, "")
    }
  }
  let pid = @process.spawn_orphan(
    "timeout",
    timeout_args,
    stdin=stdin_read,
    stdout=stdout_write,
    stderr=stderr_dest,
  ) catch {
    _ => {
      stdin_write.close()
      stdout_read.close()
      return (-1, "")
    }
  }
  let line = request_line + "\n"
  ignore(stdin_write.write(line) catch { _ => () })
  stdin_write.close()
  let (output, _) = drain_process_stdout(stdout_read, 65536)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  (exit_code, output)
}

///|
/// Spawn `program` with `args`, capture stdout (up to 64KiB), wait for exit, return decoded output.
pub async fn capture_stdout(program : String, args : Array[String]) -> String {
  capture_stdout_with_cwd(program, args, None)
}

///|
/// Spawn `program` with `args` in `cwd`, capture stdout (up to 64KiB), wait for exit, return decoded output.
pub async fn capture_stdout_with_cwd(
  program : String,
  args : Array[String],
  cwd : String?,
) -> String {
  let (reader, writer) = @process.read_from_process() catch { _ => return "" }
  let pid = match cwd {
    Some(dir) =>
      @process.spawn_orphan(program, args[:], stdout=writer, cwd=dir) catch {
        _ => {
          reader.close()
          return ""
        }
      }
    None =>
      @process.spawn_orphan(program, args[:], stdout=writer) catch {
        _ => {
          reader.close()
          return ""
        }
      }
  }
  let (output, _) = drain_process_stdout(reader, 65536)
  ignore(@process.wait_pid(pid) catch { _ => -1 })
  output
}

///|
pub async fn run(cmd : @workspace.Command) -> Int {
  let native = @workspace.run_native_choir_file_command(cmd)
  if native >= 0 {
    return native
  }
  let native_rel = @workspace.run_native_workspace_rel_file_command(cmd)
  if native_rel >= 0 {
    return native_rel
  }
  let native_leaf_helpers = @workspace.run_native_leaf_helpers_command(cmd)
  if native_leaf_helpers >= 0 {
    return native_leaf_helpers
  }
  let native_wt_cleanup = @workspace.run_native_worktree_bootstrap_cleanup_command(
    cmd,
  )
  if native_wt_cleanup >= 0 {
    return native_wt_cleanup
  }
  let native_fetch = @workspace.run_native_git_fetch_origin_branch_best_effort_command(
    cmd,
  )
  if native_fetch >= 0 {
    return native_fetch
  }
  let prog = cmd.program
  let args = cmd.args[:]
  match cmd.workdir {
    Some(dir) => @process.run(prog, args, cwd=dir)
    None => @process.run(prog, args)
  }
}

///|
pub async fn run_sequence(cmds : Array[@workspace.Command]) -> Array[Int] {
  let results = []
  for cmd in cmds {
    let status = run(cmd)
    results.push(status)
    if status != 0 {
      return results
    }
  }
  results
}
