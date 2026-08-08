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
use crate::memory::{admit, default_wave_budget, safe_jobs, Budget};
use crate::report::{fill_width, kib_parts, unit_parts};

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

/// P-2b: the generalised split never overflows, for every shift a label uses.
///
/// `size_label` reaches this with shifts 10, 20 and 30, and a refused patch can
/// carry any `usize` at all. Kani explores the whole domain at each shift.
#[kani::proof]
fn p2b_unit_parts_never_overflows() {
    let bytes: usize = kani::any();
    let shift: u32 = kani::any();
    kani::assume(shift >= 10 && shift <= 30);

    let (whole, frac) = unit_parts(bytes, shift);

    assert!(frac < 10, "fractional part must be a single digit");
    assert!(whole <= bytes, "unit count cannot exceed the byte count");
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

/// P-4: an admitted `--jobs` is exactly the one that was asked for.
///
/// C-50's rule about the operator's own request, over the whole `usize` domain of
/// both limits and the request: there is no admitted value other than `want`, so
/// no later edit can quietly turn a refusal into a reduction.
///
/// Stated as an implication from `Ok` rather than as a biconditional, and the
/// reason is a measured limit of the tool rather than a choice. Relating the
/// division `admit` performs to a second one in the harness — which is what "and
/// it refuses exactly when the budget is too small" needs — did not terminate in
/// 300 seconds, while either division alone verifies in one. The refusal side is
/// covered instead by an exhaustive grid in `memory::tests`, which is weaker and
/// says so.
#[kani::proof]
fn p4_an_admitted_request_is_never_lowered() {
    let per_jail: usize = kani::any();
    let wave: usize = kani::any();
    let want: usize = kani::any();

    if let Ok(jobs) = admit(Some(want), Budget { per_jail, wave }) {
        assert!(jobs == want, "an explicit request is kept exactly");
    }
}

/// P-4a: an admitted auto concurrency always runs at least one jail.
///
/// A zero would reach `chunks(0)`, which panics — the scheduler's one arithmetic
/// hazard, and the reason the call site carries a `max(1)` it should never need.
#[kani::proof]
fn p4a_auto_concurrency_is_never_zero() {
    let per_jail: usize = kani::any();
    let wave: usize = kani::any();

    if let Ok(jobs) = admit(None, Budget { per_jail, wave }) {
        assert!(jobs >= 1, "an admitted run must run something");
    }
}

/// P-4b: the default wave budget always admits at least one jail.
///
/// The expression subtracts a host reserve, so on a small host it is a
/// `saturating_sub` away from being a budget of zero — which would refuse every
/// run on exactly the machines least able to spare the memory. Kani explores every
/// host size against every per-jail limit.
#[kani::proof]
fn p4b_the_default_budget_always_admits_a_jail() {
    let host: usize = kani::any();
    let per_jail: usize = kani::any();
    kani::assume(per_jail >= 1);

    let budget = default_wave_budget(host, per_jail);

    assert!(
        safe_jobs(budget, per_jail) >= 1,
        "the default budget must never refuse the run it exists to size"
    );
}
