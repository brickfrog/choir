//! The host half of the memory bound: cgroup v2 directories Choir owns.
//!
//! Implements contract items C-49 … C-51 of `docs/spec.md`. Every decision is
//! [`choir_core::memory`]'s; every syscall is [`crate::sys`]'s. What is here is
//! the arrangement between them — which directory, in what order, and what is
//! read back before it is destroyed.
//!
//! The layout, per run:
//!
//! ```text
//! <delegated root>/choir.<pid>/          wave: memory.max = --wave-memory
//!                             /w0/       jail: memory.max = --memory
//!                                 /NSJAIL.<pid>   nsjail's own, removed by nsjail
//! ```
//!
//! Two levels because they answer different questions. The jail level stops one
//! runaway; the wave level stops the set of them, which is the limit that
//! actually protects a host running eight jails at once. And the jail level is
//! Choir's rather than nsjail's for one measured reason: nsjail deletes the
//! cgroup it makes as soon as the process ends, and C-51 needs the counters
//! after the wave.

use std::path::Path;

use choir_core::memory::{cgroup_dir, Events};

use crate::sys;

/// Where a cgroup v2 hierarchy is mounted on every systemd host.
const MOUNT: &str = "/sys/fs/cgroup";

/// One run's cgroup tree, removed when the run ends.
pub struct Tree {
    /// `<delegated root>/choir.<pid>`.
    root: String,
}

impl Tree {
    /// A handle on a tree `prepare` already built and verified.
    ///
    /// `Config::cgroup_root` is the only record that a run is bounded, and it is
    /// the same field [`choir_core::jail::prefix`] reads to emit the nsjail flag.
    /// Reconstructing the handle from it rather than threading one through every
    /// wave is what makes the two impossible to disagree: if the flag is on the
    /// command line, this directory is where the limit was written.
    pub fn at(root: &str) -> Self {
        Self {
            root: root.to_owned(),
        }
    }

    /// The directory per-jail cgroups are made under, for `Config::cgroup_root`.
    pub fn root(&self) -> &str {
        &self.root
    }

    /// Create one jail's cgroup and bound it (C-49).
    ///
    /// `memory.oom.group` makes the jail die as a unit. Without it the kernel
    /// picks one process, and a provider CLI that survives losing its own child
    /// reports a confused failure instead of a memory kill — which is precisely
    /// the ambiguity this whole path exists to remove.
    pub fn jail(&self, slot: &str, per_jail_mib: usize) {
        let dir = cgroup_dir(&self.root, slot);
        sys::mkdir_all(Path::new(&dir));
        // nsjail makes its own cgroup below this one, so this level must delegate
        // the controller down or nsjail's write fails and its placement is the
        // only thing that happens to work.
        write(&dir, "cgroup.subtree_control", "+memory");
        write(&dir, "memory.max", &mib(per_jail_mib));
        write(&dir, "memory.swap.max", "0");
        write(&dir, "memory.oom.group", "1");
    }

    /// Read what a jail's cgroup recorded, then destroy it (C-51).
    ///
    /// Read first, in this order, deliberately: the counters live in the
    /// directory, so a removal before the read is the evidence gone. Returns
    /// `None` when the cgroup is not there to read, which is the honest answer
    /// for a jail that never ran under one.
    pub fn collect(&self, slot: &str) -> Option<Events> {
        let dir = cgroup_dir(&self.root, slot);
        if !Path::new(&dir).exists() {
            return None;
        }
        let events = read_events(&dir);
        // nsjail removes its own child, but a jail killed mid-teardown can leave
        // it, and a non-empty parent cannot be removed.
        for child in nested(&dir) {
            sys::rmdir(&child);
        }
        sys::rmdir(&dir);
        events
    }

    /// Remove the run's own cgroup. Safe to call with jails already collected.
    pub fn destroy(&self) {
        for child in nested(&self.root) {
            for grandchild in nested(&child) {
                sys::rmdir(&grandchild);
            }
            sys::rmdir(&child);
        }
        sys::rmdir(&self.root);
    }
}

/// Build and verify a run's cgroup tree, or report why not (C-49).
///
/// The verification is the point. A cgroup v2 mount proves nothing: systemd can
/// deliver fewer controllers than a unit asked for, and a delegated controller
/// can be absent from `cgroup.subtree_control` for children, so every cheap test
/// — the mount exists, `user.delegate` is set, the file is writable — can pass on
/// a host where the limit does nothing. So this walks the same path a jail walks:
/// create the directories, set both limits, read both back, and only then say
/// yes.
///
/// Returns `None` having written nothing durable, so a refusal costs the caller
/// no cleanup.
pub fn prepare(per_jail_mib: usize, wave_mib: usize) -> Option<Tree> {
    prepare_at(&delegated_root()?, per_jail_mib, wave_mib)
}

/// [`prepare`], against a named base, so a test can hand it a directory that is
/// not a cgroup filesystem at all.
///
/// That test is the reason `placed` exists. Every other check here passes in a
/// plain directory — the `mkdir` works, the write works, and the read-back returns
/// what was just written, because a regular file remembers bytes. Only running a
/// jail and finding a charge on the cgroup can tell the difference, which is the
/// same lesson three of C-47's mutations taught: a control written to the wrong
/// place verifies perfectly against itself.
fn prepare_at(base: &str, per_jail_mib: usize, wave_mib: usize) -> Option<Tree> {
    sweep_stale(base);

    let root = format!("{base}/choir.{}", sys::pid());
    sys::mkdir_all(Path::new(&root));
    if !Path::new(&root).exists() {
        return None;
    }
    let tree = Tree { root };

    write(tree.root(), "cgroup.subtree_control", "+memory");
    write(tree.root(), "memory.max", &mib(wave_mib));
    write(tree.root(), "memory.swap.max", "0");
    // Read back rather than trust the write: `write_text` is silent by design,
    // and a controller that is delegated but not enabled for children accepts
    // the `mkdir` and then has no `memory.max` to write at all.
    if reads_back(tree.root(), "memory.max", &mib(wave_mib))
        && reads_back(tree.root(), "memory.swap.max", "0")
        && probe(&tree, per_jail_mib)
    {
        return Some(tree);
    }
    tree.destroy();
    None
}

/// The largest wave budget this host will actually honour, in MiB (C-50).
///
/// `min(host total, the delegated parent's own memory.max)`. The second term is
/// usually `max` on a systemd user session and finite inside a container or under
/// a `MemoryMax=` unit — and there it is the real ceiling, because a wave budget
/// above it would be bounded by something Choir did not set and cannot report.
///
/// `None` means no delegated cgroup at all, which is [`MemoryState::Unavailable`]
/// before any provider runs.
///
/// [`MemoryState::Unavailable`]: choir_core::memory::MemoryState::Unavailable
pub fn headroom_mib() -> Option<usize> {
    let base = delegated_root()?;
    let host = sys::host_memory_mib().unwrap_or(usize::MAX);
    let parent = read_u64(&base, "memory.max")
        .and_then(|bytes| usize::try_from(bytes >> 20).ok())
        .unwrap_or(usize::MAX);
    Some(host.min(parent))
}

/// Run one provider-free jail through the real configuration path (C-49).
///
/// `/usr/bin/true` under the same flags a work jail gets, in a cgroup made the
/// same way. This is the step that catches what a unit test of the writer cannot:
/// mutation-testing the first version of this module showed a limit correctly
/// written to a directory no jail was ever placed in, and every cheap probe still
/// said the host was fine.
fn probe(tree: &Tree, per_jail_mib: usize) -> bool {
    let slot = "probe";
    tree.jail(slot, per_jail_mib);
    let dir = cgroup_dir(tree.root(), slot);
    let ok = reads_back(&dir, "memory.max", &mib(per_jail_mib))
        && reads_back(&dir, "memory.swap.max", "0")
        && reads_back(&dir, "memory.oom.group", "1")
        && placed(&dir);
    tree.collect(slot);
    ok
}

/// Whether a jail actually lands inside `dir`, measured rather than assumed.
///
/// `memory.peak` on a cgroup that has never held a process is 0, and any real
/// process charges at least a page. nsjail deletes its own child cgroup on the
/// way out, so the child is gone by the time this reads — but the charge it made
/// is still this directory's high-water mark.
fn placed(dir: &str) -> bool {
    let cmd = format!(
        "nsjail -Mo -q -t 10 --use_cgroupv2 --cgroupv2_mount {} \
         --cgroup_mem_swap_max 0 -R /usr -R /lib64 -R /bin -R /etc/passwd \
         -R /etc/group -R /dev/null -E PATH=/usr/local/bin:/usr/bin \
         -- /usr/bin/true",
        choir_core::Quoted(dir)
    );
    let (code, _) = sys::sh(&cmd);
    code == 0 && read_u64(dir, "memory.peak").unwrap_or(0) > 0
}

/// The nearest ancestor cgroup Choir may create children in.
///
/// Not our own cgroup: cgroup v2 forbids a directory from holding both processes
/// and controller-enabled children, and this process is in ours. So this climbs
/// from the parent of our own cgroup toward the mount root and takes the first
/// directory that accepts a child with a working `memory.max` — which lands on
/// `user@<uid>.service` or the session's `app.slice` on a systemd host, and finds
/// whatever the delegation boundary is anywhere else. Probing rather than
/// hardcoding the systemd path is what makes this answer for a container too.
fn delegated_root() -> Option<String> {
    let own = sys::read_text(Path::new("/proc/self/cgroup"));
    // `0::/user.slice/.../app.slice/foo.scope` — the v2 line is the one with an
    // empty controller list, and on a v2-only host it is the only line.
    let rel = own
        .lines()
        .find_map(|l| l.strip_prefix("0::"))?
        .trim()
        .to_owned();

    let mut dir = format!("{MOUNT}{rel}");
    while let Some(parent) = Path::new(&dir).parent().and_then(|p| p.to_str()) {
        if !parent.starts_with(MOUNT) || parent.len() < MOUNT.len() {
            return None;
        }
        if accepts_children(parent) {
            return Some(parent.to_owned());
        }
        if parent == MOUNT {
            return None;
        }
        dir = parent.to_owned();
    }
    None
}

/// Whether a candidate parent will really give a child a memory limit.
fn accepts_children(parent: &str) -> bool {
    let probe = format!("{parent}/choir.probe.{}", sys::pid());
    sys::mkdir_all(Path::new(&probe));
    let ok = Path::new(&probe).exists() && {
        write(&probe, "memory.max", &mib(64));
        reads_back(&probe, "memory.max", &mib(64))
    };
    sys::rmdir(&probe);
    ok
}

/// Remove `choir.<pid>` directories left by runs that are no longer alive.
///
/// A run killed between its wave and its cleanup leaves empty cgroups. They cost
/// almost nothing, and they accumulate, and one of them holding a stale
/// `memory.max` under the same parent is one more thing to explain later.
fn sweep_stale(base: &str) {
    for name in sys::dir_names(base) {
        let Some(pid) = name.strip_prefix("choir.") else {
            continue;
        };
        // `choir.probe.<pid>` is `accepts_children`'s own scratch, and parses as
        // no integer, so it is swept by the same rule that spares a live run.
        let dead = pid.parse::<u32>().map_or(true, |pid| !sys::pid_alive(pid));
        if dead {
            let tree = Tree {
                root: format!("{base}/{name}"),
            };
            tree.destroy();
        }
    }
}

/// The immediate child directories of a cgroup.
fn nested(dir: &str) -> Vec<String> {
    sys::dir_names(dir)
        .into_iter()
        .map(|name| format!("{dir}/{name}"))
        .filter(|p| Path::new(p).is_dir())
        .collect()
}

/// `memory.events.local` and `memory.peak`, as the counters C-51 classifies on.
fn read_events(dir: &str) -> Option<Events> {
    let text = sys::read_text(&Path::new(dir).join("memory.events.local"));
    if text.is_empty() {
        return None;
    }
    let field = |want: &str| -> u64 {
        text.lines()
            .find_map(|l| l.strip_prefix(want)?.trim().parse().ok())
            .unwrap_or(0)
    };
    Some(Events {
        max: field("max "),
        oom: field("oom "),
        oom_kill: field("oom_kill "),
        oom_group_kill: field("oom_group_kill "),
        peak: read_u64(dir, "memory.peak").unwrap_or(0),
    })
}

fn read_u64(dir: &str, file: &str) -> Option<u64> {
    sys::read_text(&Path::new(dir).join(file))
        .trim()
        .parse()
        .ok()
}

/// Write one cgroup control file.
fn write(dir: &str, file: &str, value: &str) {
    sys::write_text(&Path::new(dir).join(file), value);
}

/// Whether a control file holds exactly what was written to it.
fn reads_back(dir: &str, file: &str, want: &str) -> bool {
    sys::read_text(&Path::new(dir).join(file)).trim() == want
}

/// MiB as the byte count a cgroup control file takes.
///
/// Saturating: a `--memory` large enough to overflow becomes "no limit expressible
/// here", which `reads_back` then refuses, so an absurd value is a refusal rather
/// than a wrapped-around small limit.
fn mib(mib: usize) -> String {
    (mib as u64).saturating_mul(1024 * 1024).to_string()
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::{prepare_at, Tree};
    use choir_core::memory::cgroup_dir;
    use std::path::Path;

    /// C-49: a directory that is not a cgroup filesystem is refused.
    ///
    /// Every cheap check passes there — this is exactly the host that must not be
    /// reported as bounded, and the only thing that catches it is having run a
    /// jail through the arrangement and looked for the charge.
    #[test]
    fn c49_a_plain_directory_is_not_a_memory_control() {
        let base = std::env::temp_dir().join(format!("choir-cgtest-{}", std::process::id()));
        std::fs::create_dir_all(&base).expect("base");
        let base_s = base.to_str().expect("utf8").to_owned();

        assert!(
            prepare_at(&base_s, 512, 4096).is_none(),
            "a plain directory remembers every byte written to it and enforces none of them"
        );
        // And here, in one assertion, is why reading the value back is not enough
        // on its own: the limit is still sitting there, byte for byte as written,
        // in a directory that enforces nothing whatsoever. Every check but the one
        // that runs a jail agrees this host is bounded.
        let probe = format!("{base_s}/choir.{}/probe", std::process::id());
        let wrote = |file: &str| {
            std::fs::read_to_string(format!("{probe}/{file}"))
                .unwrap_or_else(|_| panic!("{file} was never written"))
                .trim()
                .to_owned()
        };
        assert_eq!(
            wrote("memory.max"),
            (512_u64 * 1024 * 1024).to_string(),
            "the limit was written and read back perfectly, and bounds nothing"
        );
        // The line that makes the limit real. Measured before any of this was
        // written: under `memory.max` alone, a 2 GiB allocation in a 1 GiB cgroup
        // survives by swapping, on a host with 62 GiB of swap. The cap without
        // this is a cap in name.
        assert_eq!(
            wrote("memory.swap.max"),
            "0",
            "swap must be denied, not capped"
        );
        // And the jail dies as a unit rather than losing one process, which is
        // what makes `oom_group_kill` the counter C-51 reads.
        assert_eq!(wrote("memory.oom.group"), "1");
        // Nothing here is removable either -- `rmdir` will not take a directory
        // holding a regular file -- which is itself the difference from a cgroup
        // filesystem, where the control files are the kernel's and hold nothing.
        assert!(Path::new(&probe).exists());
        std::fs::remove_dir_all(&base).ok();
    }

    /// C-51: the counters a real kernel wrote, parsed as the verdict reads them.
    ///
    /// The bytes are copied from a measured run: a 2 GiB allocation under a 1 GiB
    /// cap, with `memory.oom.group` set. Note where the 1 is -- `oom_group_kill`,
    /// while `oom_kill` stays 0. Classifying on `oom_kill` alone, which is the
    /// obvious reading and the one this module first shipped, calls that jail an
    /// ordinary failure.
    #[test]
    fn c51_a_group_kill_is_read_off_the_counters_the_kernel_moved() {
        let base = std::env::temp_dir().join(format!("choir-cgev-{}", std::process::id()));
        let tree = Tree::at(base.to_str().expect("utf8"));
        let dir = cgroup_dir(tree.root(), "/run/w0");
        std::fs::create_dir_all(&dir).expect("dir");
        std::fs::write(
            format!("{dir}/memory.events.local"),
            "low 0\nhigh 0\nmax 40\noom 1\noom_kill 0\noom_group_kill 1\nsock_throttled 0\n",
        )
        .expect("events");
        std::fs::write(format!("{dir}/memory.peak"), "1073741824\n").expect("peak");

        let events = tree.collect("/run/w0").expect("counters");
        assert_eq!(events.max, 40);
        assert_eq!(events.oom, 1, "`oom_kill 0` must not be read as `oom`");
        assert_eq!(events.oom_kill, 0);
        assert_eq!(events.oom_group_kill, 1);
        assert_eq!(events.peak, 1_073_741_824);
        assert!(events.killed(), "a group kill is a kill");

        std::fs::remove_dir_all(&base).ok();
    }

    /// C-51: the counters are read from the directory Choir bounded, and the
    /// removal happens after the read. A cgroup that is not there to read is
    /// `None` rather than a zeroed record that would read as "no pressure".
    #[test]
    fn c51_an_absent_cgroup_reports_nothing_rather_than_zero() {
        let base = std::env::temp_dir().join(format!("choir-cgabs-{}", std::process::id()));
        std::fs::create_dir_all(&base).expect("base");
        let tree = Tree::at(base.to_str().expect("utf8"));

        assert_eq!(tree.collect("/run/w0"), None);
        assert!(!Path::new(&cgroup_dir(tree.root(), "/run/w0")).exists());
        std::fs::remove_dir_all(&base).ok();
    }
}
