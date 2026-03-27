///|
/// StateMachine trait formalizing the lifecycle transition protocol.
///
/// MoonBit v0.8.3 does not support generic trait type parameters or polymorphic
/// trait methods, so `transition` cannot be expressed as a trait method with a
/// type-parameterized Event. Instead, each implementor exposes `transition` as
/// an inherent method wired to the existing free transition functions, while
/// the trait captures the two type-invariant methods.
pub trait StateMachine {
  machine_name(Self) -> String
  can_exit(Self) -> StopCheckResult
}
