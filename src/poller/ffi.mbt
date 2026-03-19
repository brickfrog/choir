///|
extern "C" fn now_sec_ffi() -> Int64 = "choir_now_sec"

///|
pub fn now_sec() -> Int64 {
  now_sec_ffi()
}
