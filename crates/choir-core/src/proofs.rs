//! Kani proof harnesses for the provable-properties catalogue.
//!
//! Compiled only under `cfg(kani)`, so the crate builds and tests normally
//! without Kani installed. Run with:
//!
//! ```text
//! cargo kani -p choir-core
//! ```
//!
//! These cover the three arithmetic properties whose failure mode in Rust is a
//! panic or a wrap that the Gleam original could not have — BEAM integers are
//! arbitrary-precision, so porting the same expressions verbatim would have
//! introduced real bugs. See `docs/spec.md` section 6.2.
//!
//! Kani verifies the absence of arithmetic overflow, division by zero, and
//! out-of-bounds access along every path it explores, so each harness asserts
//! the *semantic* property on top of those built-in checks.

use crate::config::rotation_slot;
use crate::report::{fill_width, kib_parts};

/// P-1: the rotation index is always a valid slot.
///
/// For every `index` — including `usize::MAX` — and every non-empty rotation,
/// the chosen slot is strictly below the rotation length. This is what makes
/// `Providers::at` total and its fallback arm unreachable.
#[kani::proof]
fn p1_rotation_slot_is_in_range() {
    let index: usize = kani::any();
    let len: usize = kani::any();
    kani::assume(len >= 1);

    let slot = rotation_slot(index, len);

    assert!(slot < len, "slot must index a real provider");
}

/// P-2: the KiB split never overflows and yields a real tenths digit.
///
/// The natural expression `bytes * 10 / 1024` overflows for `bytes` above
/// roughly `usize::MAX / 10`. Kani explores the whole `usize` domain, so this
/// passing means the overflow is genuinely gone rather than merely untested.
#[kani::proof]
fn p2_kib_parts_never_overflows() {
    let bytes: usize = kani::any();

    let (whole, frac) = kib_parts(bytes);

    assert!(frac < 10, "fractional part must be a single digit");
    assert!(whole <= bytes, "KiB count cannot exceed the byte count");
}

/// P-3: column padding never underflows.
///
/// `column - text_len` on `usize` wraps to about 18 quintillion when a value
/// overflows its column, and `" ".repeat` of that aborts the process. The
/// result must always be at least one space and never exceed the column width.
#[kani::proof]
fn p3_fill_width_never_underflows() {
    let text_len: usize = kani::any();
    let column: usize = kani::any();

    let fill = fill_width(text_len, column);

    assert!(fill >= 1, "columns must never run together");
    assert!(
        fill <= if column == 0 { 1 } else { column },
        "padding must not exceed the column"
    );
}
