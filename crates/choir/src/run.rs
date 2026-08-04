//! The three waves, in order.
//!
//! Wave 1 runs the providers, wave 2 tests their patches, wave 3 comments. Each
//! wave is one blocking shell-out that backgrounds its jails and waits, so a
//! wave costs about its longest jail rather than the serial sum (N-4).
//!
//! Every decision in here is delegated to `choir-core`; what remains is the
//! order things happen in and the syscalls that make them happen.

use std::path::Path;

use choir_core::config::{Config, Provider};
use choir_core::report::{self, Row};
use choir_core::verdict::{self, Verdict};
use choir_core::{jail, wave, Jail, AUDIT_PROMPT};

use crate::sys;

/// A staged attempt: either a verify jail to run, or a verdict already decided.
///
/// The two skip conditions (C-19, C-20) are the only branches in the program
/// that omit work, and both are mechanical facts about the patch.
enum Staged {
    /// The patch applied; this slot holds a tree to test.
    Ready(String),
    /// Nothing to test. Zero-byte patch, or one `git apply` rejected.
    Skipped(Verdict),
}

/// One attempt as it moves through the waves.
struct Attempt {
    index: usize,
    provider: Provider,
    bytes: usize,
    staged: Staged,
}

/// Scratch paths for one run.
struct Paths {
    /// The `mktemp -d`, deleted before we return.
    dir: String,
    /// Absolute `--out`, the only thing that survives.
    out: String,
}

impl Paths {
    fn slot(&self, kind: &str, index: usize) -> String {
        format!("{}/{kind}{index}", self.dir)
    }

    fn base_repo(&self) -> String {
        format!("{}/repo", self.dir)
    }

    fn patch(&self, index: usize) -> String {
        format!("{}/patches/{index}.patch", self.dir)
    }
}

/// Run the whole program. Returns the process exit status (0 if any patch passed).
pub fn execute(cfg: &Config) -> i32 {
    let paths = prepare(cfg);

    println!("run {}", paths.dir);
    println!("{}", cfg.banner());

    work_wave(cfg, &paths);
    let attempts = stage(cfg, &paths);
    verify_wave(cfg, &attempts);

    let rows = collect(&paths, &attempts);
    print_table(&rows, &paths.out);
    let passed = rows.iter().filter(|r| r.verdict.passed()).count();

    audit_wave(cfg, &paths);

    sys::remove_tree(&paths.dir);
    i32::from(passed == 0)
}

/// Build the scratch tree: one repo copy every jail is cloned from, the shared
/// patches directory, the output directory, and the resolv.conf pasta needs.
fn prepare(cfg: &Config) -> Paths {
    let dir = sys::make_run_dir();
    sys::copy_tree(&cfg.repo, &format!("{dir}/repo"));
    sys::mkdir_all(Path::new(&format!("{dir}/patches")));
    sys::mkdir_all(Path::new(&cfg.out));

    // The host's resolv.conf names 127.0.0.53, which inside a pasta namespace is
    // the jail's own empty loopback. One line naming pasta's gateway instead.
    sys::write_text(
        Path::new(&format!("{dir}/resolv.conf")),
        "nameserver 10.255.255.1\n",
    );

    Paths {
        out: sys::absolute(&cfg.out),
        dir,
    }
}

/// Lay out one jail slot: `tmp`, `cred` holding exactly one credential file, and
/// `cmd` holding the instruction or test command verbatim. Returns the resolved
/// provider binary to mount at `/prov/<name>`.
fn prep_slot(slot: &str, command: &str, provider: Provider) -> String {
    sys::mkdir_all(Path::new(&format!("{slot}/tmp")));
    sys::mkdir_all(Path::new(&format!("{slot}/cred")));
    sys::write_text(Path::new(&format!("{slot}/cmd")), command);

    let relative = provider.cred_file();
    let filename = Path::new(relative)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("credentials.json");
    sys::copy_file(
        Path::new(&format!("{}/{relative}", sys::home())),
        Path::new(&format!("{slot}/cred/{filename}")),
    );

    sys::resolve_binary(provider.name())
}

/// Wave 1: N provider jails, each with its own writable copy of the repository.
fn work_wave(cfg: &Config, paths: &Paths) {
    let jails: Vec<Jail> = cfg
        .plan()
        .into_iter()
        .map(|(index, provider)| {
            let slot = paths.slot("w", index);
            let binary = prep_slot(&slot, &cfg.instruction, provider);
            sys::copy_tree(&paths.base_repo(), &format!("{slot}/repo"));
            let mount = format!("-B {slot}/repo:/repo");
            let command = jail::provider(cfg.timeout, &paths.dir, &slot, &mount, &binary, provider);
            Jail::new(command, slot)
        })
        .collect();

    println!("[work]   {} jails started", jails.len());
    let _ = sys::sh(&wave::script(&jails));
}

/// Extract one jail's patch host-side and write it before any verdict exists.
///
/// The jail's working tree *is* this host directory, so there is no copy-out and
/// the guest is never trusted to produce a diff. Writing the patch before
/// computing any verdict is what makes it structurally impossible for Choir to
/// discard work a provider actually produced.
fn extract(paths: &Paths, index: usize) -> usize {
    let repo = format!("{}/repo", paths.slot("w", index));
    let _ = sys::run("git", &["-C", &repo, "add", "-A"]);
    let (_, patch) = sys::run("git", &["-C", &repo, "diff", "--cached", "HEAD"]);

    sys::write_bytes(Path::new(&format!("{}/{index}.patch", paths.out)), &patch);
    sys::write_bytes(Path::new(&paths.patch(index)), &patch);
    patch.len()
}

/// Extract every patch, then build the tree each surviving patch will be tested
/// against. Applying host-side keeps "the patch does not apply" and "the tests
/// failed" from collapsing into one nonzero exit code.
fn stage(cfg: &Config, paths: &Paths) -> Vec<Attempt> {
    cfg.plan()
        .into_iter()
        .map(|(index, provider)| {
            let bytes = extract(paths, index);
            if bytes == 0 {
                return Attempt {
                    index,
                    provider,
                    bytes,
                    staged: Staged::Skipped(Verdict::NoPatch),
                };
            }

            let slot = paths.slot("v", index);
            let _ = prep_slot(&slot, &cfg.test_cmd, provider);
            sys::copy_tree(&paths.base_repo(), &format!("{slot}/repo"));

            let repo = format!("{slot}/repo");
            let (code, _) = sys::run("git", &["-C", &repo, "apply", &paths.patch(index)]);
            let staged = if code == 0 {
                Staged::Ready(slot)
            } else {
                Staged::Skipped(Verdict::ApplyFailed)
            };
            Attempt {
                index,
                provider,
                bytes,
                staged,
            }
        })
        .collect()
}

/// Wave 2: one sealed jail per applicable patch. No network flag at all.
fn verify_wave(cfg: &Config, attempts: &[Attempt]) {
    let jails: Vec<Jail> = attempts
        .iter()
        .filter_map(|a| match &a.staged {
            Staged::Ready(slot) => Some(Jail::new(jail::verify(cfg.timeout, slot), slot.clone())),
            Staged::Skipped(_) => None,
        })
        .collect();

    println!("[verify] {} jails started", jails.len());
    let _ = sys::sh(&wave::script(&jails));
}

/// Read each jail's verdict and log line into a renderable row.
fn collect(paths: &Paths, attempts: &[Attempt]) -> Vec<Row> {
    attempts
        .iter()
        .map(|a| {
            let verdict = match &a.staged {
                Staged::Ready(slot) => {
                    verdict::from_rc(&sys::read_text(Path::new(&format!("{slot}.rc"))))
                }
                Staged::Skipped(v) => *v,
            };
            let log = sys::read_text(Path::new(&format!("{}.log", paths.slot("w", a.index))));
            Row {
                index: a.index,
                provider: a.provider,
                bytes: a.bytes,
                verdict,
                last_line: report::last_line(&log),
            }
        })
        .collect()
}

/// The entire user interface: rows in jail order, then a `git apply` line per
/// passing patch. No ranking, no recommendation, no winner.
fn print_table(rows: &[Row], out_dir: &str) {
    println!("\n{}", report::HEADER);
    for entry in rows {
        println!("{}", report::row(entry));
    }
    println!();
    for line in report::apply_lines(rows, out_dir) {
        println!("{line}");
    }
}

/// Wave 3: one more model, reading the repo and the patches read-only.
///
/// It runs *after* the table is already on screen, which makes blocking
/// structurally impossible rather than merely forbidden.
fn audit_wave(cfg: &Config, paths: &Paths) {
    let provider = cfg.audit_provider();
    let slot = format!("{}/a", paths.dir);
    let binary = prep_slot(&slot, AUDIT_PROMPT, provider);
    let mount = format!("-R {}/repo:/repo", paths.dir);
    let command = jail::provider(cfg.timeout, &paths.dir, &slot, &mount, &binary, provider);
    let _ = sys::sh(&wave::script(&[Jail::new(command, slot.clone())]));

    let heading = report::audit_heading(provider);
    let rule = "-".repeat(heading.chars().count());
    println!("\n{heading}\n{rule}");
    println!(
        "{}",
        sys::read_text(Path::new(&format!("{slot}.log"))).trim()
    );
}
