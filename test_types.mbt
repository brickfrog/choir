///|
/// Test typealias syntax
typealias Int as UserId

///|
/// Test tuple-struct (newtype-like) syntax
struct Meters(Int)

///|
/// Test usage
fn test_types() -> Unit {
  let user_id : UserId = 42  // UserId is an alias for Int
  let distance : Meters = Meters(100)  // Meters wraps Int
  let raw_int : Int = distance.0  // Access wrapped value
  println(user_id)
  println(distance)
  println(raw_int)
}