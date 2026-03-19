///|
fn index_of(str : String, sub : String, start? : Int = 0) -> Int {
  let str_len = str.length()
  let sub_len = sub.length()
  if sub_len == 0 {
    return start
  }
  for i = start; i <= str_len - sub_len; i = i + 1 {
    let mut match_found = true
    for j = 0; j < sub_len; j = j + 1 {
      if str[i + j] != sub[j] {
        match_found = false
        break
      }
    }
    if match_found {
      return i
    }
  }
  -1
}

///|
fn index_of_quote_end(str : String, start : Int) -> Int {
  for i = start; i < str.length(); i = i + 1 {
    if str[i] == '"' && (i == 0 || str[i - 1] != '\\') {
      return i
    }
  }
  -1
}

///|
fn skip_json_ws(s : String, start : Int) -> Int {
  let mut i = start
  while i < s.length() &&
        (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t') {
    i = i + 1
  }
  i
}

///|
fn find_json_string_field(
  data : String,
  field : String,
  start? : Int = 0,
) -> (String, Int)? {
  let field_name = "\"" + field + "\""
  let start_idx = index_of(data, field_name, start~)
  if start_idx == -1 {
    return None
  }
  let colon_idx = index_of(data, ":", start=start_idx + field_name.length())
  if colon_idx == -1 {
    return None
  }
  let value_start = skip_json_ws(data, colon_idx + 1)
  if value_start >= data.length() || data[value_start] != '"' {
    return None
  }
  let value_end = index_of_quote_end(data, value_start + 1)
  if value_end == -1 {
    return None
  }
  Some(
    (
      data[value_start + 1:value_end].to_string() catch {
        _ => ""
      },
      value_end + 1,
    ),
  )
}

///|
fn parse_review_state(data : String) -> ReviewState {
  let mut start = 0
  let mut review = ReviewState::None_
  for {
    match find_json_string_field(data, "state", start~) {
      Some((value, next_start)) => {
        match value {
          "APPROVED" => review = ReviewState::Approved
          "CHANGES_REQUESTED" => review = ReviewState::ChangesRequested
          _ => ()
        }
        start = next_start
      }
      None => break
    }
  }
  review
}

///|
fn parse_head_ref_oid(data : String) -> String {
  match find_json_string_field(data, "headRefOid") {
    Some((value, _)) => value
    None => ""
  }
}

///|
fn parse_review_bodies(data : String) -> String {
  let bodies : Array[String] = []
  let mut start = 0
  for {
    match find_json_string_field(data, "body", start~) {
      Some((value, next_start)) => {
        if value != "" {
          bodies.push(value)
        }
        start = next_start
      }
      None => break
    }
  }
  bodies.join("\n---\n")
}

///|
fn parse_ci_failed(data : String) -> Bool {
  index_of(data, "\"FAILURE\"") != -1 || index_of(data, "\"ERROR\"") != -1
}

///|
pub fn parse_gh_pr_view_output(
  data : String,
) -> (ReviewState, String, Bool, String) {
  (
    parse_review_state(data),
    parse_head_ref_oid(data),
    parse_ci_failed(data),
    parse_review_bodies(data),
  )
}

///|
async fn gh_poll_pr(pr_number : Int) -> (ReviewState, String, Bool, String) {
  let (read_end, write_end) = @pipe.pipe() catch {
    _ => return (None_, "", false, "")
  }
  let exit_code = @process.run(
    @utf8.encode("gh"),
    [
      @utf8.encode("pr"),
      @utf8.encode("view"),
      @utf8.encode(pr_number.to_string()),
      @utf8.encode("--json"),
      @utf8.encode("reviews,headRefOid,statusCheckRollup"),
    ],
    stdout=write_end,
  ) catch {
    _ => -1
  }
  let buf = FixedArray::make(65536, (0 : Byte))
  let mut total = 0
  for {
    if total >= buf.length() {
      break
    }
    let n = read_end.read(buf, offset=total, max_len=buf.length() - total) catch {
      _ => 0
    }
    if n == 0 {
      break
    }
    total = total + n
  }
  read_end.close()
  if exit_code != 0 {
    return (None_, "", false, "")
  }
  let output = @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:total])
  parse_gh_pr_view_output(output)
}
