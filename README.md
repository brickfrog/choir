# Choir

Choir runs one coding task N times in parallel. Each attempt gets a throwaway nsjail sandbox. That sandbox holds one copy of your
repository, one credential, and one provider CLI: Claude Code or Codex, on your own paid
subscription. Each jail returns a patch.

Choir then tests every patch in a jail with no network at all: your test command on the
unpatched copy first, then on each patch. It prints a table of what passed, plus the
`git apply` lines for you to run yourself. One more jail reads the patches and prints
commentary.

Choir never writes inside your checkout. One command. No daemon, no configuration file, no
state between runs.

## Why

Claude and Codex bill on independent rolling five-hour windows, so time spent on one does not
consume the other. One agent at a time uses half of what I pay for. It also uses it in the least safe way
available. That agent holds my whole home directory, every repository on the machine, my SSH
keys, and both credentials.

Choir spends both subscriptions at once and puts each agent in a jail that holds one
repository and one token.

## Install

**1. nsjail and passt.** Both are distro packages, and you need unprivileged user namespaces
(`kernel.unprivileged_userns_clone=1`), which most desktop distros enable by default.

```sh
pacman -S nsjail passt
```

Measured against nsjail 3.6 and passt 2026_07_28. `passt` supplies `pasta`, which gives a jail
its own network namespace. Without `pasta`, a jail that needs the network runs in your host
namespace, where it can reach your loopback services and your X server.

**2. A provider CLI, logged in.** `claude`, `codex`, or both, authenticated the way you
normally do and checked with `claude auth status` or `codex login status`. Choir mounts the
resolved binary read-only and copies one credential file into each jail. It installs nothing,
and it authenticates from that file alone, so a shell function that injects a token never runs.

**3. Choir**, with Rust 1.85 or newer:

```sh
cargo build --release && install -m755 target/release/choir ~/.local/bin/choir
```

The result is one 387 KB executable linking `libc` and `libgcc_s`. No VM, no image, no
interpreter, no state directory. A jail starts in about 10 ms and leaves nothing behind.

The jail's toolchain is your host's `/usr`, bind-mounted read-only. That is what removes the
image requirement, and it is also the honest cost. Read *The jail is not reproducible* under
[Limits](#limits).

## Usage

```
choir "<instruction>" --test '<cmd>' [options]
choir -  --test '<cmd>' [options]   <<'EOF'
<instruction, as long as you like>
EOF
```

Run Choir from inside the repository you want worked on. An instruction of `-` reads from
stdin, because a paragraph does not belong in a shell argument. Choir reads nothing else from
stdin, so it never blocks and waits.

| Flag | Default | Meaning |
| --- | --- | --- |
| *(positional)* | — | The instruction. Exactly one, passed verbatim to every work jail. |
| `--test '<cmd>'` | required | Your test command, run inside a jail against the unpatched base and each patch. |
| `--repo <path>` | `.` | Repository to copy. Read only. |
| `-n <count>` | `2` | Work jails. Providers alternate, so the default is one of each. |
| `--providers <list>` | `claude,codex` | Comma-separated. Only `claude` and `codex` are accepted. The audit jail takes the next index in the same rotation. |
| `--timeout <secs>` | `1200` | Per jail, passed to `nsjail --time_limit`. The kernel enforces it. |
| `--out <dir>` | `./choir-out` | Patches as `<index>.patch`, beside `<index>.log` and `<index>.verify.log`. The only thing Choir leaves on disk. |
| `--cache <path>` | none | Repeatable. Mounts a host path read-only into every jail at its host path. Verify jails have no network, so this is the only way a dependency cache reaches one. |

Exit code is 0 if at least one patch passed your test command, otherwise 1.

Your working tree does not need to be committed. Choir copies `--repo` as it stands, including
uncommitted edits and untracked files, and commits that copy inside its own scratch directory.
That copy is the baseline every patch is a diff against, so no patch needs your history.

Choir then makes the copy a repository in its own right. Three shapes of `--repo` need this,
and all three are silent faults without it:

- A **symlink**. The copied link puts every jail's work in your real checkout.
- A **directory that is not a git repository**. Host `git` searches upward and can commit
  into an enclosing repository.
- A **nested repository**. It stages as a gitlink, so a model's edits inside it never reach
  the patch.

Choir has no configuration file and will not grow one. For a per-project `--test`, use an
alias: `alias ct='choir --test "pytest -q"'`.

### Disk

Choir copies your repository `1 + 2n` times, all at once. A 392 MB checkout at the default
`-n 2` is five copies, about 2 GB. It starts to matter when `(1 + 2n) × <repo size>`
approaches the size of whatever `TMPDIR` lives on, and a capped `tmpfs /tmp` is the common
case.

CAUTION: A copy that runs out of room fails silently, so the symptom is a strange result
rather than an error.

Point `TMPDIR` at the *same filesystem* as `--repo` to remove the question. A copy-on-write filesystem then shares extents instead of copying bytes. Measured on a
392 MB checkout: 0.22 s and 0 new bytes reflinked, against 0.35 s and 392 MB on tmpfs. The same *kind* of
filesystem is not enough — two separate btrfs volumes cannot share extents. Choir detects
none of this, because it never inspects the host.

## Reading the output

```
$ choir "the auth test is flaky under load — find and fix the real race" \
    --repo ~/proj --test 'pytest -q' -n 3

3 work jails: 0=claude 1=codex 2=claude; audit=codex; timeout 1200s
[work]   3 jails started
[verify] 3 jails started

baseline (--test on the unpatched tree, same sealed jail): FAIL(1)
JAIL PROVIDER  PATCH    EXIT  TESTS         LAST LINE FROM PROVIDER
0    claude    4.1 KB   0     PASS          Replaced the double-checked flag with a lock in session.py.
1    codex     0 B      1     -             stream error: rate limit reached; resets 14:05
2    claude    6.8 KB   0     FAIL(1)       Rewrote the fixture to drive a fake clock.

2 of 2 non-empty patches are byte-distinct

  git apply /home/justin/proj/choir-out/0.patch

audit (codex — model commentary, unverified, no effect on the table above)
--------------------------------------------------------------------------
0.patch takes the lock around the refresh but still reads `expires_at`
outside it, so the narrow race remains on the read path. 2.patch changes
test timing rather than the code under test, which is why it fails.
```

Rows are in jail order. Choir does not rank, sort, or pick one. `PATCH` is a byte count and
exists to tell `0 B` from not-`0 B`. `TESTS` holds `PASS`, `FAIL(<code>)`, `APPLY FAILED`, or
`-` when there was no patch to test. Only two conditions skip a verify jail: a `0 B` patch,
and a patch `git apply` rejects.

The `baseline` line runs the same command against the unpatched copy in the same sealed jail.
It is context only, and the three columns compose into a diagnosis:

| `baseline` | `PATCH` | `EXIT` | What it means |
| --- | --- | --- | --- |
| `PASS` | `0 B` | `0` | Already done. The model looked and correctly declined. |
| `PASS` | any | any | Whatever passes below proves nothing. |
| `FAIL` | `0 B` | `0` | The provider ran cleanly and wrote nothing. Read `<n>.log`. |
| `FAIL` | `0 B` | `137` | The deadline killed it mid-edit. Raise `--timeout`. |
| `FAIL` | `0 B` | `1` | Rate limit, auth error, or crash. `<n>.log` says which. |
| `FAIL` | non-empty | all `FAIL` | **Suspect your `--test`, not the patches.** If the baseline row failed the same way, the harness is what is broken. |
| `FAIL` | non-empty | mixed | The normal case. |

That second-from-last row is the expensive one. Before `--cache` existed, this repository
printed `FAIL` for every patch, because cargo cannot reach crates.io from a sealed jail.
Nothing on screen distinguished that from ten bad patches.

`FAIL(137)` stays ambiguous. A jail killed by its `--timeout`, a test the OOM killer picked,
and a suite that exits 137 by itself all look the same. Choir will not grow a mechanism to
tell them apart.

The distinct-patch line is the one that says whether you got what you paid for. N jails can
return the same patch N times, and then the run bought one attempt repeated. Choir compares
patch bytes directly, so identical means identical, and names the repeats:

```
1 of 3 non-empty patches are byte-distinct (jail 2 is identical to jail 0)
```

Zero-byte patches are not attempts, so Choir neither counts nor names them there.

Choir prints no progress inside a wave — a wave is one blocking call. Run it under `time` if
you want a clock. Every patch reaches `--out` before any test runs, so nothing Choir does can
discard work a provider produced.

## Patterns

**The patch does not have to be code.** Choir looks patch-shaped, so review work reads as
failure: a reviewer writes no diff and the row says `0 B`. Make the finding a file instead:
`"Write every finding to FINDINGS.md as file:line"`. Now the review *is* the patch, diffable,
three side by side. `--test` still proves the reviewer did not break the build.

**Divergence measures your instruction, not the models.** Attempts that come back structurally
different and all passing usually mean the instruction was ambiguous, and the diff between
them localizes the clause. Convergent patches mean `-n 3` bought one attempt three times.

**Convergence is a workflow, not a feature.** Choir keeps no state, so it cannot tell you an
adversary has stopped finding things. Run the review three times and compare the three
`FINDINGS.md`. What recurs is real, what appears once is usually noise, and a run that finds
nothing new is the signal to stop.

## Safety

"Safe(ish)" means the limits are stated, not that there are none. The measurements behind
every claim here are in [`docs/architecture.md`](docs/architecture.md).

**A jail is not a virtual machine.** It is Linux namespaces plus rlimits plus `no_new_privs`,
on *your* kernel. The uid mapping is identity, so a jailed process runs as you. A kernel
privilege-escalation bug or a namespace escape lands on your whole account.

**What it does protect.** There is no `--chroot`: the jail's root is an empty 16 MB tmpfs
holding only the mounts Choir names. Verified from inside a work jail: no `/home`, `/mnt`,
`/root`, `/var` or `/run`. No `~/.ssh`, no `/etc/shadow`, no other repository, and no host
process in `/proc`. `/usr` and `/etc` are read-only and refuse remounting. `NoNewPrivs` is 1
and `CapEff` is empty, so the setuid `sudo` in the mounted `/usr` is inert.

**The verify jail is sealed.** It takes no network flag at all, so it gets nsjail's default:
its own empty namespace. Inside it are one `lo` interface, no routing table, no `/cred`, no
`/prov`, and no resolver. Your host's `127.0.0.1` and your X server are both unreachable. A test asserts this
on every `cargo test`. That is the jail your untrusted patch runs in.

**Work and audit jails reach the whole internet, with no allowlist.** A subscription CLI has
to reach its vendor, and neither nsjail nor pasta filters egress. A model can send any host
anything it can read, including your repository and its own credential. That is the one
deliberate hole in this design. What pasta still closes is your host loopback and every host abstract unix socket. That
includes your X server, and with it screenshots and keystroke injection.

**The verify jail bounds no resources.** It inherits `--disable_rlimits` with no cgroup cap
behind it, so within its window an untrusted patch can fork-bomb, exhaust memory, or fill the
filesystem. The deadline is the only bound.

CAUTION: Lower `--timeout` when you test patches you have not read.

**`--cache` is a deliberate hole in the mount inventory.** Each cached path reappears inside *every* jail at its host path. `--cache ~/.cargo` puts a
`/home/<you>/.cargo` back into a tree that otherwise has no `/home`. The mount is read-only and carries no route out, but a
work jail has network, so treat anything you cache as readable by the model.

CAUTION: Cache dependency caches only. `~/.npmrc`, `~/.m2/settings.xml` and
`~/.docker/config.json` routinely hold registry tokens, and `~/.cargo/credentials.toml` exists
the moment you run `cargo login`.

**The credential is a full-account OAuth token** with a refresh token and no scoping, because
neither vendor mints anything narrower. Anything in the jail can read it. Choir copies it into a per-jail directory that dies with the scratch directory. A token the
CLI refreshes inside a jail therefore never lands in your real `~/.claude` or `~/.codex`. Not known: whether that refresh
invalidates the copy on your host. Refresh tokens commonly rotate, so a long run can log you
out.

**That lifetime holds only if Choir exits.** Each wave unlinks its credentials when it
returns, and the scratch directory goes at the end of the run. A Choir killed mid-wave does
neither and never sweeps on a later run, leaving a full-account token readable by anything
running as you. Choir prints the run directory on line 1 for exactly this reason.

WARNING: Remove that directory with `rm -rf`. Do not *trash* it. A file manager or a "safe
delete" alias moves it to `~/.local/share/Trash` or `/tmp/.Trash-$UID` and preserves the token
there. Measured: a trashed scratch directory still held a byte-identical copy of a live
`~/.codex/auth.json` sixteen hours later.

**Ctrl-C does not stop the jails.** POSIX requires a non-interactive shell to ignore SIGINT in commands it starts asynchronously.
Choir starts every jail that way, so the signal reaches Choir and not them. What saves you is `--timeout`. The kernel kills an abandoned jail and its whole process tree
on schedule, verified against a tree that traps and ignores TERM, INT and HUP. There is nothing to clean up afterward, but there is up to `--timeout` to wait.

**The provider runs with its own permission prompts disabled**, because one blocked on a
prompt burns quota and returns nothing. These flags are not optional: a provider's sandbox
cannot nest inside an nsjail, since `/proc` is read-only and writing `uid_map` fails. The
model has full control of its jail by design.

**The audit jail is one more language model**, with a work jail's network access. Its
commentary is prose, not a verdict and not a security review. It reads `/patches`, which the
work-jail models wrote, so a work jail can address it directly. That grants nothing new — the
audit jail already holds the same token and the same egress.

WARNING: Patches are untrusted code from a language model. Read them before you `git apply`.
Choir tests them in the sealed jail precisely so that running them does not require trusting
them.

**Not verified end to end:** that a real billed session can do useful work in these jails.
Both CLIs start and report a live subscription, but nobody has run a paid coding session. If
your jails come back empty, suspect that first.

**Against the status quo:** today that token runs on your host beside every repository you own
and your SSH keys. Choir shrinks the worst case to one token plus the one repository you
already handed to the model. That is the whole claim.

## Limits

Deliberate, permanent, and not a roadmap.

- **One instruction per run.** For two things, run Choir twice.
- **The jail is not reproducible.** Its toolchain is your host's `/usr`, so two machines will
  not produce the same jail. A `--test` needing a pyenv shim or `~/.cargo/bin` will not find
  it.
- **`sh` runs your `--test` string,** so the verdict is the last command's exit status.
  `pytest -q; echo done` passes unconditionally. Use `&&`, or a script.
- **Choir never picks a winner, and never applies a patch.** Your test command is a filter,
  not a ranking. Every ordering available is wrong somewhere obvious — "smallest diff" rewards
  deleting the failing test. You run the printed `git apply` line.
- **Choir does not know your build system.** `--test` is required, with no detection and no
  default. This is the single decision that keeps Choir from being a tool that only works on
  Choir.
- **Two providers, named in the source.** No provider interface, no way to register a third.
  Adding one is an edit by someone who has run the new CLI.
- **Choir writes one prompt.** Your instruction goes through verbatim. The only text Choir
  sends is the fixed sentence asking the audit jail to comment. No template, no system prompt.
- **No retries, no resume, no failover, no quota accounting.** A retry needs provider signals
  that are not reliable: Claude Code exits 0 and prints success when it did nothing and asked
  a question. Codex exposes no headless rate-limit signal at all.
- **No state between runs.** Re-running is a fresh run. Choir first removes the files this run
  will write, so it leaves absence rather than the previous run's bytes. Files from a wider
  earlier `-n` stay, so `-n 5` then `-n 2` strands `2.patch` through `4.patch`. Pass a
  different `--out` when that matters.
- **Patches are not composed.** Every jail starts from the same tree, so two patches touching
  one file can conflict when you apply the second.
- **There is no git identity inside a jail.** Your `~/.gitconfig` is not mounted, so a
  provider that tries to commit is refused and leaves the tree dirty. That is what patch
  extraction wants. A provider that configures an identity and commits anyway moves `HEAD`,
  and its patch comes back empty.
- **Choir cannot tell you why a jail failed.** Rate-limited, logged out, refused, wedged, and
  "did not solve it" all look the same from outside. You get the exit code and the last line.
- **No streaming, no daemon, no server, no MCP, no TUI, no subcommands, no config file.**
  Everything happens between your Enter key and the exit code.

## Building and verifying

Two crates, split on a purity boundary:

```
crates/choir-core   pure. argv -> Config, jail command lines, wave scripts, verdicts,
                    table rows. No I/O, no spawn, no clock. Zero third-party deps.
crates/choir        the effectful shell. Every syscall lives in sys.rs; run.rs is the
                    three waves in order.
```

The dependency runs one way, and the core cannot perform I/O because it cannot name it. That
is what makes the program's whole decision surface testable without a jail, a provider, or a
network.

```sh
cargo test --workspace                              # 90 tests
cargo clippy --workspace --all-targets -- -D warnings
cargo kani -p choir-core                            # 3 proof harnesses
```

`docs/spec.md` is the contract, and every test names the requirement it defends: `C-*`
behavioral, `E-*` edge case, `P-*` proved property, `N-*` non-functional. You can read a
failure back to the sentence it broke.

Three properties are **proved** rather than tested. They sit where porting arithmetic from
arbitrary-precision integers into wrapping `usize` introduces silent faults:

- the provider rotation index stays in range,
- the KiB split never overflows,
- and column padding never underflows.

Kani explores the entire `usize` domain for each.

The isolation claims are nsjail's, not Choir's, so `crates/choir/tests/sealed_jail.rs`
exercises them against a real jail rather than proving them. It skips with a notice when
nsjail is absent.
