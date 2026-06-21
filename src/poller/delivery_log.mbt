///|
pub fn delivery_log_timestamp(now_ms : Int64) -> String {
  let truncated_seconds = now_ms / 1000L
  let raw_ms = now_ms % 1000L
  let ms = if raw_ms < 0L { raw_ms + 1000L } else { raw_ms }
  let seconds = if raw_ms < 0L {
    truncated_seconds - 1L
  } else {
    truncated_seconds
  }
  let base = @tempo.DateTime::from_unix_seconds(seconds).format()
  let ms_text = if ms < 10L {
    "00" + ms.to_string()
  } else if ms < 100L {
    "0" + ms.to_string()
  } else {
    ms.to_string()
  }
  if base.has_suffix("Z") {
    base[0:base.length() - 1].to_owned() + "." + ms_text + "Z"
  } else {
    base + "." + ms_text
  }
}

///|
pub fn delivery_log_line(
  line : String,
  now_ms? : Int64 = @env.now().reinterpret_as_int64(),
) -> String {
  delivery_log_timestamp(now_ms) + " " + line + "\n"
}

///|
pub fn append_delivery_log_line(
  append_file : (String, String) -> Bool,
  project_dir : String,
  line : String,
  now_ms? : Int64 = @env.now().reinterpret_as_int64(),
) -> Bool {
  append_file(
    project_dir + "/.choir/logs/delivery.log",
    delivery_log_line(line, now_ms~),
  )
}
