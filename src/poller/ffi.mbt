///|
pub fn now_sec() -> Int64 {
  @env.now().to_int64() / 1000L
}
