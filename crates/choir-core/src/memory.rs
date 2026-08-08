//! Memory admission and what a jail's cgroup recorded.
//!
//! Implements contract items C-49 … C-52 of `docs/spec.md`.
//!
//! Every decision here is arithmetic on plain integers, so the host module can
//! be a thin layer of `mkdir` and `write` over answers this crate already gave.
//! The split matters for one reason: admission runs *before the first provider
//! call*, and a refusal that costs nothing must be decidable without touching
//! the filesystem twice.

use core::fmt;

use crate::verdict::Verdict;

/// Whether Choir can bound a jail's memory, and on whose authority (C-49).
///
/// Three states rather than a boolean, because "unbounded" is two different
/// facts: a host that cannot enforce the limit, and an operator who chose to run
/// without one. The first is Choir's refusal; the second is a decision Choir was
/// told to make and must keep saying it made. A single `bool` would let the
/// second silently absorb the first, which is exactly the trust-model change
/// this type exists to keep visible.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MemoryState {
    /// Both `memory.max` and `memory.swap.max` were set and read back, through
    /// the same path a real jail uses.
    Enforced,
    /// Choir could not set them, so it refuses to start a provider (C-49).
    Unavailable,
    /// The operator passed `--allow-unbounded-memory`. The run proceeds and
    /// every final output says so.
    ExplicitlyUnbounded,
}

impl MemoryState {
    /// The word the run header and the table footer both use.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Enforced => "ENFORCED",
            Self::Unavailable => "UNAVAILABLE",
            Self::ExplicitlyUnbounded => "UNBOUNDED",
        }
    }

    /// Whether a provider may be started at all (C-49).
    #[must_use]
    pub const fn admits_provider(self) -> bool {
        !matches!(self, Self::Unavailable)
    }
}

impl fmt::Display for MemoryState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.label())
    }
}

/// The per-jail and whole-wave memory bounds, in MiB (C-50).
///
/// MiB rather than bytes because `--rlimit_as 32768` already made MiB this
/// program's unit for a memory limit, and a second unit in the same argument
/// vector is a bug waiting for someone to write `--memory 4096` meaning bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Budget {
    /// `memory.max` for one jail's cgroup.
    pub per_jail: usize,
    /// `memory.max` for the cgroup every jail of a wave sits under.
    pub wave: usize,
}

/// How many jails of `per_jail` MiB fit in a `wave` MiB budget (C-50).
///
/// Total: `per_jail == 0` yields zero rather than dividing by zero. No caller
/// can reach that — `--memory` is parsed as strictly positive — but the
/// arithmetic is what P-4 proves, and a proof of a partial function is worth
/// less than the function being total.
#[must_use]
pub const fn safe_jobs(wave: usize, per_jail: usize) -> usize {
    if per_jail == 0 {
        return 0;
    }
    wave / per_jail
}

/// The batch sizes `jails` jails run in at concurrency `jobs` (C-50).
///
/// Every requested jail appears in exactly one batch: the sizes sum to `jails`,
/// which is the arithmetic form of "Choir never reduces `-n`". Reported beside
/// each wave so the shape of a batched run is visible rather than inferred.
#[must_use]
pub fn batches(jails: usize, jobs: usize) -> Vec<usize> {
    if jails == 0 {
        return Vec::new();
    }
    let width = if jobs == 0 { jails } else { jobs };
    let mut out = Vec::with_capacity(jails / width + 1);
    let mut left = jails;
    while left > width {
        out.push(width);
        left -= width;
    }
    out.push(left);
    out
}

/// The state a run proceeds in, and whether it proceeds at all (C-49).
///
/// The whole default-memory policy, in one total function over two booleans, so
/// that the host layer decides nothing: it answers "could the bound be enforced",
/// and this answers "then what". Fail-closed is the middle arm — an unenforceable
/// bound with no operator instruction is a refusal, because a host that lost the
/// controller did not thereby gain a trustworthy provider.
#[must_use]
pub const fn state(enforced: bool, allow_unbounded: bool) -> MemoryState {
    match (enforced, allow_unbounded) {
        (true, _) => MemoryState::Enforced,
        (false, true) => MemoryState::ExplicitlyUnbounded,
        (false, false) => MemoryState::Unavailable,
    }
}

/// The wave budget to use when `--wave-memory` was not given (C-50).
///
/// A sixteenth of the host, floored at 1 GiB, is kept back: Choir itself, the
/// `cp -a` of one repository copy per jail, `git apply`, and the page cache all
/// of that goes through are outside every jail's cgroup and inside the host's
/// memory. A budget equal to the whole host would bound the wave at exactly the
/// point where bounding it stops helping.
///
/// A host too small to spare one jail still gets one jail's worth rather than a
/// refusal. The operator chose `--memory`; a limit above physical memory is a
/// weaker bound than they may think, and `safe_jobs` of 1 is the strongest thing
/// left to do about it. It is printed either way.
#[must_use]
pub const fn default_wave_budget(host_mib: usize, per_jail_mib: usize) -> usize {
    let reserve = if host_mib / 16 > 1024 {
        host_mib / 16
    } else {
        1024
    };
    let budget = host_mib.saturating_sub(reserve);
    if budget < per_jail_mib {
        per_jail_mib
    } else {
        budget
    }
}

/// The cgroup directory for one jail, under the run's own `root` (C-49).
///
/// Named from the slot's last path component, which is already unique per run
/// (`w0`, `g1`, `b0`, …). Derived rather than passed: the host creates exactly the
/// directory [`crate::jail::prefix`] names, from the same rule, so there is no
/// arrangement in which a jail is placed in a cgroup nothing bounded.
#[must_use]
pub fn cgroup_dir(root: &str, slot: &str) -> String {
    let name = slot.rsplit('/').next().unwrap_or(slot);
    format!("{root}/{name}")
}

/// Why a run was refused before any provider was started (C-50).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BudgetError {
    /// Not even one jail fits in the wave budget.
    NoRoom {
        /// `--memory`, MiB.
        per_jail: usize,
        /// `--wave-memory`, MiB.
        wave: usize,
    },
    /// An explicit `--jobs` asked for more concurrency than the budget permits.
    ///
    /// Refused rather than lowered: Choir may choose a default, and must not
    /// rewrite a value the operator typed.
    Oversubscribed {
        /// What `--jobs` asked for.
        requested: usize,
        /// What the budget permits.
        safe: usize,
        /// `--memory`, MiB.
        per_jail: usize,
        /// `--wave-memory`, MiB.
        wave: usize,
    },
}

impl fmt::Display for BudgetError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoRoom { per_jail, wave } => write!(
                f,
                "WAVE MEMORY BUDGET TOO SMALL\n\n  \
                 Per-jail memory limit: {per_jail} MiB\n  \
                 Wave memory budget:    {wave} MiB\n\n\
                 Not one jail fits. Lower --memory or raise --wave-memory.\n\
                 No provider call was made."
            ),
            Self::Oversubscribed {
                requested,
                safe,
                per_jail,
                wave,
            } => write!(
                f,
                "WAVE MEMORY BUDGET EXCEEDED\n\n  \
                 Requested concurrency: {requested}\n  \
                 Safe concurrency:      {safe}\n  \
                 Per-jail memory limit: {per_jail} MiB\n  \
                 Wave memory budget:    {wave} MiB\n\n\
                 Lower --jobs or raise --wave-memory.\n\
                 No provider call was made."
            ),
        }
    }
}

/// The concurrency a request is admitted at (C-50).
///
/// `-n` is deliberately not an argument. The jail count is not an input to this
/// decision, which is the type-level form of C-50: admission bounds how many
/// jails run *together*, and never how many run.
///
/// # Errors
/// [`BudgetError::NoRoom`] when nothing fits, and
/// [`BudgetError::Oversubscribed`] when an explicit `--jobs` exceeds the budget.
pub const fn admit(requested: Option<usize>, budget: Budget) -> Result<usize, BudgetError> {
    let safe = safe_jobs(budget.wave, budget.per_jail);
    if safe == 0 {
        return Err(BudgetError::NoRoom {
            per_jail: budget.per_jail,
            wave: budget.wave,
        });
    }
    match requested {
        // Auto. Choir picks the widest the budget allows; each wave's own jail
        // count is what actually bounds a batch, so this is a ceiling and not a
        // target.
        None => Ok(safe),
        Some(jobs) if jobs > safe => Err(BudgetError::Oversubscribed {
            requested: jobs,
            safe,
            per_jail: budget.per_jail,
            wave: budget.wave,
        }),
        Some(jobs) => Ok(jobs),
    }
}

/// What one jail's cgroup recorded before Choir removed it (C-51).
///
/// Read from `memory.events.local` and `memory.peak`, which count events against
/// *this* cgroup's own limit rather than a descendant's. nsjail nests its own
/// cgroup inside the one Choir made, so the limit Choir set is the binding one
/// and these counters are the jail's own.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Events {
    /// Times allocation was throttled at the limit.
    pub max: u64,
    /// Times the cgroup's OOM handler ran.
    pub oom: u64,
    /// Processes the OOM killer ended individually.
    pub oom_kill: u64,
    /// Times the whole cgroup was killed as a unit by `memory.oom.group`.
    pub oom_group_kill: u64,
    /// High-water mark of charged memory, in bytes.
    pub peak: u64,
}

impl Events {
    /// Whether the kernel ended this jail for exceeding its limit (C-51).
    ///
    /// Both counters, because `memory.oom.group` changes which one moves:
    /// Choir sets it so a jail dies as a unit rather than losing one process and
    /// carrying on, and the kernel then increments `oom_group_kill` while
    /// `oom_kill` stays at zero. Measured. Reading `oom_kill` alone — the
    /// obvious choice, and the one first written here — classified every group
    /// kill as an ordinary failure.
    #[must_use]
    pub const fn killed(self) -> bool {
        self.oom_kill > 0 || self.oom_group_kill > 0
    }

    /// Whether the jail reached its limit without being killed for it (C-51).
    ///
    /// Not a verdict. A suite that touched its ceiling, had a page reclaimed and
    /// then passed has passed, and the row says so; this is the fact that
    /// explains an otherwise unexplained slowdown, and the reason to raise
    /// `--memory` before believing the next run's timing.
    #[must_use]
    pub const fn pressed(self) -> bool {
        (self.max > 0 || self.oom > 0) && !self.killed()
    }
}

/// Reclassify a verdict the jail's own memory limit explains (C-51).
///
/// Exit 137 alone could not say this. It covers Choir's deadline (already split
/// out as [`Verdict::Timeout`] from a clock Choir owns), the host OOM killer, the
/// cgroup OOM killer, and a suite that exits 137 by itself. The cgroup counters
/// separate the third from the rest as a fact rather than a guess, so `MEMORY`
/// is a measured verdict in the same sense `TIMEOUT` is.
///
/// Only a verdict that did not pass is reclassified. `memory.oom.group` kills the
/// jail as a unit, so a pass beside a kill event is not a state the kernel
/// produces — and if it ever were, the tests reported their own result and that
/// result stands. Choir does not overturn a suite's own answer with an
/// observation about the room it ran in.
#[must_use]
pub const fn explained_by_memory(verdict: Verdict, events: Option<Events>) -> Verdict {
    match events {
        Some(ev) if ev.killed() && !verdict.passed() => Verdict::MemoryKill,
        _ => verdict,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn c50_safe_jobs_divides_the_budget() {
        assert_eq!(safe_jobs(12288, 4096), 3);
        assert_eq!(safe_jobs(12287, 4096), 2);
        assert_eq!(safe_jobs(4095, 4096), 0);
    }

    #[test]
    fn c50_a_zero_per_jail_limit_fits_nothing() {
        assert_eq!(safe_jobs(65536, 0), 0);
    }

    #[test]
    fn c50_auto_concurrency_takes_the_whole_budget() {
        let budget = Budget {
            per_jail: 4096,
            wave: 16384,
        };
        assert_eq!(admit(None, budget), Ok(4));
    }

    #[test]
    fn c50_an_explicit_request_within_budget_is_kept_exactly() {
        let budget = Budget {
            per_jail: 4096,
            wave: 16384,
        };
        assert_eq!(admit(Some(2), budget), Ok(2));
    }

    #[test]
    fn c50_an_explicit_request_over_budget_is_refused() {
        let budget = Budget {
            per_jail: 4096,
            wave: 8192,
        };
        assert_eq!(
            admit(Some(8), budget),
            Err(BudgetError::Oversubscribed {
                requested: 8,
                safe: 2,
                per_jail: 4096,
                wave: 8192,
            })
        );
    }

    #[test]
    fn c50_a_budget_with_no_room_refuses_before_any_call() {
        let budget = Budget {
            per_jail: 4096,
            wave: 2048,
        };
        assert!(matches!(
            admit(None, budget),
            Err(BudgetError::NoRoom { .. })
        ));
    }

    /// C-50: admission over a grid, since the proof cannot reach this shape.
    ///
    /// P-4 proves that an admitted request is the one that was asked for. The
    /// other half -- that a request is admitted exactly when it fits -- needs the
    /// solver to relate two symbolic divisions and does not terminate. This walks
    /// the arithmetic directly instead: for every budget and request in the grid,
    /// the answer is `Ok(want)` when it fits and an error when it does not, and
    /// never a third thing.
    #[test]
    fn c50_admission_is_exact_across_a_grid() {
        for per_jail in [1_usize, 3, 512, 4096] {
            for wave in (0..40).map(|k| k * 1024) {
                let budget = Budget { per_jail, wave };
                let safe = wave / per_jail;
                for want in 0..24_usize {
                    match admit(Some(want), budget) {
                        Ok(jobs) => {
                            assert_eq!(jobs, want, "kept exactly: {per_jail}/{wave}/{want}");
                            assert!(
                                want <= safe,
                                "admitted over budget: {per_jail}/{wave}/{want}"
                            );
                            assert!(safe >= 1);
                        }
                        Err(BudgetError::NoRoom { .. }) => assert_eq!(safe, 0),
                        Err(BudgetError::Oversubscribed { safe: got, .. }) => {
                            assert_eq!(got, safe);
                            assert!(
                                want > safe,
                                "refused within budget: {per_jail}/{wave}/{want}"
                            );
                        }
                    }
                }
                match admit(None, budget) {
                    Ok(jobs) => assert_eq!(jobs, safe, "auto takes the whole budget"),
                    Err(_) => assert_eq!(safe, 0),
                }
            }
        }
    }

    /// C-50: the point of batching. Every requested jail runs.
    #[test]
    fn c50_batches_account_for_every_jail() {
        assert_eq!(batches(8, 3), vec![3, 3, 2]);
        assert_eq!(batches(3, 3), vec![3]);
        assert_eq!(batches(2, 15), vec![2]);
        assert_eq!(batches(0, 4), Vec::<usize>::new());
        for jails in 0..40_usize {
            for jobs in 1..12_usize {
                assert_eq!(
                    batches(jails, jobs).iter().sum::<usize>(),
                    jails,
                    "no jail may be dropped: {jails} at {jobs}"
                );
            }
        }
    }

    #[test]
    fn c50_zero_concurrency_still_runs_every_jail_once() {
        assert_eq!(batches(5, 0), vec![5]);
    }

    #[test]
    fn c51_a_group_kill_counts_as_a_kill() {
        let ev = Events {
            oom_group_kill: 1,
            ..Events::default()
        };
        assert!(ev.killed(), "oom.group moves oom_group_kill, not oom_kill");
        assert!(!ev.pressed());
    }

    #[test]
    fn c51_pressure_without_a_kill_is_not_a_kill() {
        let ev = Events {
            max: 40,
            ..Events::default()
        };
        assert!(!ev.killed());
        assert!(ev.pressed());
    }

    #[test]
    fn c51_a_kill_explains_a_failure() {
        let ev = Some(Events {
            oom_group_kill: 1,
            ..Events::default()
        });
        assert_eq!(
            explained_by_memory(Verdict::Fail(137), ev),
            Verdict::MemoryKill
        );
    }

    /// C-51: Choir never overturns the suite's own answer.
    #[test]
    fn c51_a_pass_is_never_reclassified() {
        let ev = Some(Events {
            oom_group_kill: 1,
            ..Events::default()
        });
        assert_eq!(explained_by_memory(Verdict::Pass, ev), Verdict::Pass);
    }

    #[test]
    fn c51_no_events_change_nothing() {
        assert_eq!(
            explained_by_memory(Verdict::Fail(137), None),
            Verdict::Fail(137)
        );
        assert_eq!(
            explained_by_memory(Verdict::Fail(137), Some(Events::default())),
            Verdict::Fail(137)
        );
    }

    #[test]
    fn c50_the_default_budget_keeps_a_host_reserve() {
        // 64 GiB host: a sixteenth held back, the rest available to a wave.
        assert_eq!(default_wave_budget(65536, 4096), 65536 - 4096);
        // Small host: the 1 GiB floor rather than a sixteenth of very little.
        assert_eq!(default_wave_budget(8192, 2048), 8192 - 1024);
    }

    /// C-50: a host too small to spare a jail runs them one at a time.
    #[test]
    fn c50_a_tiny_host_still_admits_one_jail() {
        let budget = default_wave_budget(2048, 4096);
        assert_eq!(budget, 4096);
        assert_eq!(safe_jobs(budget, 4096), 1);
    }

    #[test]
    fn c50_an_unknown_host_size_still_admits_one_jail() {
        assert_eq!(safe_jobs(default_wave_budget(0, 4096), 4096), 1);
    }

    #[test]
    fn c49_a_jail_cgroup_is_named_from_its_slot() {
        assert_eq!(
            cgroup_dir("/sys/fs/cgroup/x/choir.7", "/tmp/run-a/w0"),
            "/sys/fs/cgroup/x/choir.7/w0"
        );
        // No path separator: the slot is already its own name.
        assert_eq!(cgroup_dir("/cg", "w0"), "/cg/w0");
    }

    /// C-49: the default is to refuse, and only an explicit override changes it.
    #[test]
    fn c49_the_policy_is_fail_closed() {
        assert_eq!(state(true, false), MemoryState::Enforced);
        assert_eq!(state(true, true), MemoryState::Enforced);
        assert_eq!(state(false, false), MemoryState::Unavailable);
        assert_eq!(state(false, true), MemoryState::ExplicitlyUnbounded);
        // The override may never make an unenforced run look enforced: that is
        // the difference between accepting a risk and hiding one.
        assert!(!state(false, false).admits_provider());
        assert!(state(false, true).admits_provider());
        for allow in [false, true] {
            assert_ne!(state(false, allow), MemoryState::Enforced);
        }
    }

    #[test]
    fn c49_only_unavailable_stops_a_provider() {
        assert!(MemoryState::Enforced.admits_provider());
        assert!(MemoryState::ExplicitlyUnbounded.admits_provider());
        assert!(!MemoryState::Unavailable.admits_provider());
    }
}
