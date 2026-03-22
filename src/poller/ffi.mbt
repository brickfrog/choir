///|
pub fn now_sec() -> Int64 {
  @env.now().reinterpret_as_int64() / 1000L
}
