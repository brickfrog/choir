///|
/// Persistent UDS client for the TUI. One connection, strictly sequential
/// request → read response → next (the daemon's line protocol gives no
/// frame correlation). All calls run inside pippa `Cmd::perform` callbacks
/// with bounded non-blocking reads — the render loop is never blocked for
/// more than `tui_client_read_deadline_ms`.
pub let tui_client_read_deadline_ms : Int = 1500

///|
pub(all) struct TuiClient {
  sock_path : String
  mut fd : Int
}

///|
pub fn TuiClient::new(sock_path : String) -> TuiClient {
  { sock_path, fd: -1 }
}

///|
pub fn TuiClient::is_connected(self : TuiClient) -> Bool {
  self.fd >= 0
}

///|
fn TuiClient::disconnect(self : TuiClient) -> Unit {
  if self.fd >= 0 {
    @uds.close(self.fd)
    self.fd = -1
  }
}

///|
fn TuiClient::ensure_connected(self : TuiClient) -> Bool {
  if self.fd >= 0 {
    return true
  }
  let fd = @uds.client_connect(self.sock_path)
  if fd < 0 {
    return false
  }
  if !@uds.set_nonblocking(fd) {
    @uds.close(fd)
    return false
  }
  self.fd = fd
  true
}

///|
fn TuiClient::write_all(self : TuiClient, line : String) -> Bool {
  let bytes = @utf8.encode(line[:])
  let mut offset = 0
  let deadline = @env.now().reinterpret_as_int64() +
    tui_client_read_deadline_ms.to_int64()
  while offset < bytes.length() {
    let written = @uds.write_bytes(
      self.fd,
      bytes,
      offset,
      bytes.length() - offset,
    )
    if written > 0 {
      offset = offset + written
    } else if written == 0 || @env.now().reinterpret_as_int64() > deadline {
      return false
    } else {
      // Transient EAGAIN-style failure on a non-blocking fd: yield briefly.
      @sys.sleep_milliseconds(2)
      if @env.now().reinterpret_as_int64() > deadline {
        return false
      }
    }
  }
  true
}

///|
fn TuiClient::read_line(self : TuiClient) -> String? {
  let collected : Array[Byte] = []
  let chunk = FixedArray::make(4096, (0 : Byte))
  let deadline = @env.now().reinterpret_as_int64() +
    tui_client_read_deadline_ms.to_int64()
  while true {
    let n = @uds.read_bytes_nonblocking(self.fd, chunk, 0, chunk.length())
    if n > 0 {
      for i = 0; i < n; i = i + 1 {
        collected.push(chunk[i])
      }
      if chunk[n - 1] == b'\n' {
        break
      }
    } else if n == 0 {
      // Peer closed the connection.
      return None
    } else {
      if @env.now().reinterpret_as_int64() > deadline {
        return None
      }
      @sys.sleep_milliseconds(5)
    }
  } nobreak {
    ()
  }
  Some(@utf8.decode_lossy(Bytes::from_array(collected[:])))
}

///|
/// One request/response exchange. Any failure tears the connection down so
/// the next call reconnects (reconnect always re-snapshots at the fold
/// level — no mid-stream state reconstruction).
pub fn TuiClient::request(
  self : TuiClient,
  req : @types.Request,
) -> Result[@types.Response, String] {
  if !self.ensure_connected() {
    return Err("daemon unreachable at " + self.sock_path)
  }
  let line = @transport.format_request(req) + "\n"
  if !self.write_all(line) {
    self.disconnect()
    return Err("write failed (daemon gone?)")
  }
  match self.read_line() {
    Some(response_line) =>
      match @transport.parse_response(response_line.trim().to_owned()) {
        Ok(resp) => Ok(resp)
        Err(message) => {
          self.disconnect()
          Err("bad response: " + message)
        }
      }
    None => {
      self.disconnect()
      Err("read failed (daemon gone?)")
    }
  }
}

///|
fn operator_request(
  name : String,
  args : Map[String, String],
) -> @types.Request {
  {
    req_method: "tools/call",
    role: @types.Role::Operator,
    name,
    args: @types.RequestArgs::new(args),
  }
}

///|
pub fn TuiClient::fetch_snapshot(
  self : TuiClient,
) -> Result[@types.TuiSnapshot, String] {
  match self.request(operator_request("tui_snapshot", {})) {
    Ok(resp) =>
      match resp.ok_payload() {
        Some(fields) =>
          match fields.get_json("snapshot") {
            Some(snapshot_json) =>
              match @types.parse_tui_snapshot_json(snapshot_json) {
                Ok(snapshot) => Ok(snapshot)
                Err(e) => Err("snapshot decode: " + e.message())
              }
            None => Err("snapshot missing from response")
          }
        None => Err(resp.error_message().unwrap_or("tui_snapshot failed"))
      }
    Err(message) => Err(message)
  }
}

///|
pub(all) struct TuiEventsPage {
  events : Array[@types.TuiEventEnvelope]
  latest_seq : Int64
  stale : Bool
} derive(Debug, Eq)

///|
fn parse_tui_latest_seq(raw : String) -> Int64? {
  let trimmed = raw.trim().to_owned()
  if trimmed == "" {
    return None
  }
  let mut value = 0L
  let max_before_mul = 922337203685477580L
  for c in trimmed {
    if c < '0' || c > '9' {
      return None
    }
    let digit = (c.to_int() - '0'.to_int()).to_int64()
    if value > max_before_mul || (value == max_before_mul && digit > 7L) {
      return None
    }
    value = value * 10L + digit
  }
  Some(value)
}

///|
test "parse_tui_latest_seq rejects junk and overflow" {
  @debug.assert_eq(parse_tui_latest_seq("123"), Some(123L))
  @debug.assert_eq(parse_tui_latest_seq(" 7 "), Some(7L))
  @debug.assert_eq(parse_tui_latest_seq("1a2"), None)
  @debug.assert_eq(parse_tui_latest_seq(""), None)
  @debug.assert_eq(
    parse_tui_latest_seq("9223372036854775807"),
    Some(9223372036854775807L),
  )
  @debug.assert_eq(parse_tui_latest_seq("9223372036854775808"), None)
}

///|
pub fn TuiClient::fetch_events_since(
  self : TuiClient,
  cursor : Int64,
) -> Result[TuiEventsPage, String] {
  match
    self.request(
      operator_request("tui_events_since", { "seq": cursor.to_string() }),
    ) {
    Ok(resp) =>
      match resp.ok_payload() {
        Some(fields) => {
          let events : Array[@types.TuiEventEnvelope] = []
          match fields.get_json("events") {
            Some(Array(items)) =>
              for item in items {
                match @types.parse_tui_event_envelope_json(item) {
                  Ok(envelope) => events.push(envelope)
                  Err(e) => return Err("event decode: " + e.message())
                }
              }
            _ => return Err("events missing from response")
          }
          let latest_seq = match fields.get("latest_seq") {
            Some(raw) => parse_tui_latest_seq(raw).unwrap_or(cursor)
            None => cursor
          }
          let stale = fields.get_bool("stale").unwrap_or(false)
          Ok({ events, latest_seq, stale })
        }
        None => Err(resp.error_message().unwrap_or("tui_events_since failed"))
      }
    Err(message) => Err(message)
  }
}

///|
/// Operator action: merge a PR through the daemon's policy-gated merge_pr
/// path. Blocked/NeedsHuman decisions come back as the error string and are
/// surfaced in the status line — the TUI never pre-judges them.
pub fn TuiClient::send_merge(
  self : TuiClient,
  pr_number : Int,
) -> Result[String, String] {
  match
    self.request(
      operator_request("merge_pr", {
        "pr_number": pr_number.to_string(),
        "caller_id": "operator-tui",
      }),
    ) {
    Ok(resp) =>
      if resp.is_ok() {
        Ok("merge_pr #" + pr_number.to_string() + ": ok")
      } else {
        Err(
          "merge_pr #" +
          pr_number.to_string() +
          ": " +
          resp.error_message().unwrap_or("blocked"),
        )
      }
    Err(message) => Err(message)
  }
}

///|
pub fn TuiClient::send_suspend(
  self : TuiClient,
  agent_id : String,
) -> Result[String, String] {
  match
    self.request(
      operator_request("suspend", {
        "agent_id": agent_id,
        "caller_id": "operator-tui",
      }),
    ) {
    Ok(resp) =>
      if resp.is_ok() {
        Ok("suspend " + agent_id + ": ok")
      } else {
        Err(
          "suspend " +
          agent_id +
          ": " +
          resp.error_message().unwrap_or("refused"),
        )
      }
    Err(message) => Err(message)
  }
}

///|
pub fn TuiClient::send_resume(
  self : TuiClient,
  agent_id : String,
) -> Result[String, String] {
  match
    self.request(
      operator_request("resume", {
        "agent_id": agent_id,
        "caller_id": "operator-tui",
      }),
    ) {
    Ok(resp) =>
      if resp.is_ok() {
        Ok("resume " + agent_id + ": ok")
      } else {
        Err(
          "resume " +
          agent_id +
          ": " +
          resp.error_message().unwrap_or("refused"),
        )
      }
    Err(message) => Err(message)
  }
}
