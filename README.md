# Choir

Choir runs one coding task N times in parallel. Each attempt gets its own throwaway
nsjail sandbox with its own copy of your repository. Inside that sandbox Choir runs a
provider CLI: Claude Code or Codex, on your own paid subscription. Each jail returns a
patch.

Choir then tests those patches. First it runs your test command on the unpatched base
copy. Then it applies each patch to a fresh copy and runs the command again. Both tests
run in a jail with no network namespace at all. Choir prints a table of which patches
passed. One more jail reads the repository and the patches and prints commentary.

Choir never changes or removes anything in your checkout. It writes one new directory of
patches. It prints `git apply` lines for you to run yourself.

One command. No daemon, no configuration file, no state between runs.

## Why

I have a Claude subscription and a Codex subscription. Both bill by a rolling five-hour
window. The windows are independent, so time spent on one does not consume the other.

One agent at a time on my laptop uses half of what I pay for. It also uses it in the
least safe way available. That agent has my whole home directory, every repository on
the machine, my SSH keys, and both credentials.

Choir spends both subscriptions at once. It puts each agent in a jail. That jail holds one
copy of one repository, one provider binary, one credential file, and the read-only
`/usr` your own commands already run from. You get three attempts at the same bug from
two different models, tested against your own suite, in the time one attempt takes.

## Install

You need three things.

**1. nsjail and passt.** Both are distro packages. On Arch and derivatives both are in
`extra`:

```sh
pacman -S nsjail passt
```

Choir is measured against nsjail 3.6 and passt 2026_07_28. `passt` supplies `pasta`, and
`pasta` gives a provider jail its own network namespace. Without `pasta`, a jail that
needs the network must run in your host's namespace. That exposes your loopback services
and your X server to the model.

You also need unprivileged user namespaces. Most desktop distros enable them by default
(`kernel.unprivileged_userns_clone=1`).

That is the entire requirement. nsjail is a single executable with no daemon, no image,
no kernel virtualization, and no state directory. It starts a jail in about 10 ms and
leaves nothing on disk when it exits.

Nothing needs configuration, because the jail's toolchain is your toolchain. Choir
bind-mounts the host's own `/usr` read-only, so whatever runs your tests on the host runs
them in the jail. This is also the honest cost. Read *The jail is not reproducible* under
Limits.

**2. A provider CLI, logged in.** You need `claude`, or `codex`, or both. Authenticate
them the way you normally do (`claude auth status`, `codex login status`). Choir mounts
the resolved binary read-only and copies one credential file into each jail. It installs
nothing.

NOTE: Choir runs the resolved binary directly and authenticates from the credential file
alone. A shell function that injects a token does not run.

**3. Choir itself.** You need Rust 1.85 or newer:

```sh
cargo build --release && install -m755 target/release/choir ~/.local/bin/choir
```

The result is one 387 KB executable that links `libc` and `libgcc_s` and nothing else.
Choir adds **no runtime dependency at all** to a host that already has nsjail, passt, and
a provider CLI. There is no VM, no interpreter, and no shared library you do not already
have.

`choir --help` prints the flag table below.

## Usage

```
choir "<instruction>" --test '<cmd>' [options]
choir -  --test '<cmd>' [options]   <<'EOF'
<instruction, as long as you like>
EOF
choir --help
```

Run Choir from inside the repository you want worked on. `--repo` defaults to `.`. An
instruction of `-` is read from stdin, because a paragraph does not belong in a shell
argument. Choir reads nothing else from stdin, so it never blocks and waits for input.

If you always pass the same `--test` for a project, use a shell alias:
`alias ct='choir --test "pytest -q"'`. Choir has no configuration file and will not grow
one.

| Flag | Default | Meaning |
| --- | --- | --- |
| *(positional)* | — | The instruction. Exactly one, passed verbatim to every work jail. |
| `--test '<cmd>'` | required | Your repository's own test command. Choir runs it inside a jail against the unpatched base and against each patch. |
| `--repo <path>` | `.` | Repository to copy. Read only. Choir never writes inside it. |
| `-n <count>` | `2` | Work jails. Providers alternate, so the default is one of each. |
| `--providers <list>` | `claude,codex` | Comma-separated. The only accepted words are `claude` and `codex`. Anything else is an error. `--providers claude` gives an all-Claude run. The audit jail takes the next index in the same rotation, which is why the example below audits with `codex`. |
| `--timeout <secs>` | `1200` | Per jail, passed straight to `nsjail --time_limit`. The kernel enforces it. |
| `--out <dir>` | `./choir-out` | Where Choir writes patches, as `<index>.patch`, beside each jail's log: `<index>.log` from the work jail and `<index>.verify.log` from the sealed one. This is the only thing Choir leaves on disk, and the only record of a run once the scratch tree is removed. The path is relative to your current directory, so running from inside the repository puts it in your working tree. |
| `--cache <path>` | none | Repeatable. Mounts a host path read-only into every jail, at the same path it has on the host, so a test command finds it where it already expects it. Verify jails have no network at all, so this is the only way a dependency cache reaches one. Without it, `cargo test` cannot resolve crates.io and Choir reports every patch as failing whatever it contains. The mount is read-only, never writable, and it brings no network with it. |

Choir resolves each `--cache` path before it uses it, and stops on two conditions. If the
resolved path does not exist, Choir prints `choir: --cache path does not exist: {path}`.
If the resolved path holds a `'` or a `:`, Choir prints `choir: --cache {raw}
resolves to {path}, which may not contain ' or :`. Those two characters have meaning
in the mount syntax and in the shell.

Exit code is 0 if at least one patch passed your test command. Otherwise it is 1.

Your working tree does not need to be committed. Choir copies `--repo` as it stands and
commits that copy inside its own scratch directory. The tree the jails receive is
therefore the baseline every patch is a diff against, including your uncommitted edits
and your untracked files. A patch holds what the model changed and nothing else. Choir
never writes to your own repository and never commits in it.

Choir then makes that copy a repository in its own right. Three shapes of `--repo` need
this, and all three are silent faults without it:

- **A symlink.** Choir copies the tree it points at. A copied link makes every jail's
  work land in your real checkout.
- **A directory that is not a git repository.** Choir initializes the copy. Otherwise
  host `git` searches upward out of the scratch tree and can commit into an enclosing
  repository.
- **A repository nested inside `--repo`.** Choir removes the nested `.git`. Otherwise
  `git add -A` stages that subtree as a gitlink, and a model's edits inside it never
  reach the patch.

None of this needs your history. Every patch is a diff against the tree the jail started
from.

Choir copies your repository `1 + 2n` times per run: once as the base, once per work
jail, and once per verify jail. All of them exist at once. On a roomy machine this is
usually nothing to think about. A 392 MB checkout at the default `-n 2` is five copies,
about 2 GB.

It starts to matter when `(1 + 2n) × <repo size>` approaches the size of whatever
`TMPDIR` lives on. A capped `tmpfs /tmp` is the common case, and a multi-gigabyte
checkout at `-n 4` clears it easily.

CAUTION: A copy that runs out of room fails silently. The jail then runs against a
partial tree, so the symptom is a strange result rather than an error.

Point `TMPDIR` at the *same filesystem* as `--repo` to remove the question. A
copy-on-write filesystem then shares extents instead of copying bytes. Measured on this
392 MB checkout:

```
$ TMPDIR=/mnt/data/tmp     0.22 s per copy, 0 bytes of new space (reflinked)
$ TMPDIR=/tmp   (tmpfs)    0.35 s per copy, 392 MB each
```

The same *kind* of filesystem is not enough. Two separate btrfs volumes cannot share
extents, and `cp` falls back to a full copy. Choir detects none of this, because it never
inspects the host.

### Example

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

Rows are in jail order. Choir does not rank them, does not sort them, and does not pick
one. `PATCH` is a byte count and exists for one reason: to tell `0 B` from not-`0 B`.

The `baseline` line above the table prints the same command against the unpatched
base copy, in the same sealed verify jail. It is context only. Choir does not use it to rank,
gate, skip, or alter any patch or verdict.

`0 B` means that jail produced no diff. That jail was rate-limited, or refused, or hung, or it did not solve the
problem. Choir does not know which. `TESTS` holds one of four values:

- `PASS`.
- `FAIL(<code>)`.
- `APPLY FAILED`, when the patch does not apply to a clean tree.
- `-`, when there was no patch to test.

Two conditions skip a verify jail and there are no others. A `0 B` patch, because there
is nothing to apply. A patch that `git apply` rejects, because Choir never built the
tree to test it against. Both are mechanical facts about the patch, not judgments
about it.

The line under the rows is the one thing that says whether you got what you paid for.
Choir's whole premise is that N independent attempts are worth buying. N jails can easily
return the same patch N times. When they do, the run bought one attempt repeated, and the
next task of that kind wants a smaller `-n`. Choir compares the patch bytes directly, so
identical means identical, and names the repeats:

```
1 of 3 non-empty patches are byte-distinct (jail 2 is identical to jail 0)
```

Zero-byte patches are not attempts, so Choir neither counts nor names them. `0 B` in the
table already names them. The line is absent when the run produced fewer than two
non-empty patches, because then there is nothing to compare. Like `PATCH`, it is a fact
about the run. It does not rank, sort, reorder, skip a jail, or change any patch or
verdict.

The three columns compose. The combinations are worth learning, because most of them
diagnose *your* setup rather than the models:

| `baseline` | `PATCH` | `EXIT` | What it means |
| --- | --- | --- | --- |
| `PASS` | `0 B` | `0` | The task was already done. The model looked and correctly declined. |
| `PASS` | any | any | Whatever passes below proves nothing. The tests passed before the patch too. |
| `FAIL` | `0 B` | `0` | The provider ran cleanly and chose to write nothing. Read `<n>.log`. |
| `FAIL` | `0 B` | `137` | The deadline killed it mid-edit. Raise `--timeout`. |
| `FAIL` | `0 B` | `1` | The provider itself errored: a rate limit, an auth error, or a crash. `<n>.log` says which. |
| `FAIL` | non-empty | all `FAIL` | **Suspect your `--test`, not the patches.** A command that cannot run sealed fails every patch identically. Compare against the baseline row. If that row failed the same way, the harness is what is broken. |
| `FAIL` | non-empty | mixed | The normal case. The table is telling you what it looks like it is telling you. |

That second-from-last row is the expensive one. Before `--cache` existed, this repository
printed `FAIL` for every patch, because cargo did not reach crates.io from a verify
jail. Nothing on screen distinguished that from ten bad patches. The baseline row exists
so that a failure states its own cause.

`FAIL(137)` is the one ambiguous code. A jail killed by its `--timeout` exits 137. So
does a test process the kernel's OOM killer picked. So does a test suite that exits 137
by itself. All three are failures, and Choir does not claim to know which one you got. It
will not grow a mechanism to tell them apart.

Choir does not print progress inside a wave. A wave is one blocking call, so you get one
line when it starts and the finished rows when it ends. There is no elapsed-time counter
and no progress bar. Run Choir under `time` if you want one.

Choir writes every patch to `--out` before any test runs, so nothing Choir does can
discard work a provider actually produced.

## Patterns

Nothing here is a feature. These are consequences of the design that the flag table does
not make obvious.

**The patch does not have to be code.** Choir looks patch-shaped, so review work looks
like failure. A reviewer writes no diff, the row reads `0 B`, and the finding survives
only as a log. Make the finding a file instead:

```
$ choir "Attack crates/choir/src/run.rs. Assume the model in the jail is hostile.
Write every finding to FINDINGS.md as file:line, the concrete input, and the
observable consequence. Do not change any other file." \
    --test 'cargo test --workspace' -n 3
```

Now the review *is* the patch. It is non-empty and diffable, and you get three of them
side by side. `--test` still proves that the reviewer did not break the build. Each jail is a genuine context reset, with no shared history and no chance to
anchor on a sibling's answer.

**Divergence measures your instruction, not the models.** Independent attempts at one
instruction can come back structurally different and all passing. The usual reading is
that one model is better. Usually the instruction was ambiguous, and the diff between the
patches localizes the clause that was underspecified. Convergent patches mean the task
was unambiguous, and that `-n 3` bought you one attempt three times.

Read the spread before you read the winner. The distinct-patch line under the table prints the extreme
case of that spread, where two attempts came back byte-identical.

**Convergence is a workflow, not a feature.** Choir keeps no state between runs, so it
cannot tell you that an adversary has stopped finding things. You can. Run the review
above three times and compare the three `FINDINGS.md`. Findings that recur across
independent runs are real.

Findings that appear once are usually noise. A run that finds
nothing new is the signal to stop. The comparison material survives because Choir copies
every jail's log to `--out`. Git and your own eyes hold that state, and nothing in Choir
needs to.

## Safety

"Safe(ish)" means the limits are stated, not that there are none.

**A jail is not a virtual machine.** It is Linux namespaces plus rlimits plus
`no_new_privs`, on *your* kernel. There is no guest kernel and no hypervisor. The uid
mapping is identity, so a process in the jail runs as you, and files it writes are owned
by you on the host. A kernel privilege-escalation bug or a namespace escape from inside a
jail lands on your whole account. Everything below is true, and none of it is a
hypervisor boundary.

**What the jail does protect.** There is no `--chroot`. The jail's root is an empty
16 MB tmpfs, and only the mounts Choir names exist inside it. Measured on this machine
from inside a work jail:

- `/` holds exactly `bin cmd cred dev etc lib64 patches proc prov repo tmp usr`.
- `/home`, `/mnt`, `/root`, `/var`, `/run` and `/home/<you>/.ssh` all return *No such
  file or directory*.
- The only `/etc` entries are `passwd`, `group`, `hosts`, `resolv.conf`, `ssl` and
  `ca-certificates`, so `/etc/shadow` does not exist inside the jail.
- No other repository on the machine is reachable.
- `/proc` holds only the jail's own handful of PIDs, so no host process is visible.
- `/usr` and `/etc` are read-only, and `mount -o remount,rw` fails with *must be
  superuser*.
- `NoNewPrivs` is 1 and `CapEff` is `0000000000000000`, so the setuid `sudo` visible in
  the read-only `/usr` is inert.

Choir removes the scratch directory the jails write through before it exits.

**`--cache` is a deliberate hole in that inventory.** Each path you cache reappears
inside *every* jail at its host path. `--cache ~/.cargo` puts a `/home/<you>/.cargo` back
into a tree that otherwise has no `/home` at all. The mount is read-only, so a jail
cannot corrupt what it shares. A work jail has network, so treat anything you cache as
readable by the model and by any code the model runs.

CAUTION: Cache dependency caches only. Do not cache a directory that sits beside
credentials. `~/.npmrc`, `~/.m2/settings.xml` and `~/.docker/config.json` routinely hold
registry tokens, and `~/.cargo/credentials.toml` exists the moment you run `cargo login`.

The verify jail keeps its empty network namespace either way, so a cache reaches it
without carrying a route out.

**The verify jail is genuinely sealed.** It gets no network flag at all, which means
nsjail's default: its own empty network namespace. A test asserts this on every `cargo
test`. It has exactly one interface and that interface is `lo`, an empty routing table,
no `/cred`, no `/prov`, no `/patches`, no `/etc/resolv.conf`, and no `/sys`. A service bound to the host's own `127.0.0.1` is unreachable.

The jail sees no host abstract unix sockets, and it cannot open your X display. That is the jail your untrusted patch runs
in.

**What the verify jail does not bound is resources.** It shares the common prefix, so it
inherits `--disable_rlimits`, and no cgroup cap replaces it. Inside its `--timeout`
window an untrusted patch can fork-bomb, exhaust memory, or fill the filesystem. Its log
is redirected by the *host* shell, so log growth is not jailed at all. The deadline is
the only bound.

CAUTION: Lower `--timeout` when you test patches you have not read.

**The work and audit jails reach the whole internet, with no allowlist.** A subscription
CLI has to reach its vendor, so those jails get networking through `--use_pasta`: their
own network namespace with user-mode outbound NAT. nsjail has no egress filter, and pasta
does not add one. A model in a work jail can reach any host on the internet and send it
anything it can read. That includes the contents of the repository you handed it and the
credential you handed it.

**What pasta does close.** Both are measured from the exact work-jail command line on
this machine:

- Your host's `127.0.0.1`. A host listener that a `-N` jail reached, printing
  `HOST-LOOPBACK-REACHED`, is `Connection refused` under pasta. Local databases, local
  model servers, and anything else bound to loopback are out of reach.
- Every **abstract unix socket** on the host. The network namespace scopes these, not the
  filesystem. On a desktop that includes your X server. Under `-N`, `xdpyinfo` opened display `:0`. Then
  `xwininfo -root -children` listed host windows by title. `xdotool`, `import` and
  `scrot` are all present in the read-only `/usr` Choir mounts. That
  is screenshots and keystroke injection. Under pasta the same command gives *unable to
  open display ":0"*.

The cost is DNS. The host's `/etc/resolv.conf` names `127.0.0.53`, which inside a pasta
namespace is the jail's own empty loopback. Choir therefore writes a one-line
`resolv.conf` naming pasta's gateway and mounts that instead. That is enough for `curl` and for anything that uses Node's resolver, which covers
both provider CLIs.

It is not enough for glibc's NSS path. `/etc/nsswitch.conf` is not mounted, so `getent` fails in
the jail whichever nameserver you name. A tool that resolves through pure NSS will not
work in a Choir jail until that file is mounted.

Reachability is otherwise identical. `api.anthropic.com` and `api.openai.com` return the
same status codes under pasta as under `-N`. There is no startup race: twelve consecutive
jails connected with no delay before the first request.

Do not read the remaining hole as "so the jail is pointless". A work jail still cannot
see your home directory, your SSH keys, your host loopback, or your X server. It
cannot see any repository other than the one you named. Egress is unrestricted, and that is the one
deliberate hole left in this design.

**`--macvlan` is the only other network facility and it needs root.** It fails with
*Operation not permitted* unprivileged. Nothing available here filters egress by host.

**The credential.** What you hand a jail is a full-account OAuth token with a refresh
token and no scoping, because neither vendor mints anything narrower. Anything in that
jail can read it. Choir copies it into a per-jail directory that dies with the scratch
directory. A token the CLI refreshes inside a jail therefore never lands in your real
`~/.claude` or `~/.codex`.

What is **not** known: whether a refresh inside a jail invalidates the copy on your host.
OAuth refresh tokens commonly rotate, and Claude's access token expires roughly every
five hours. A long run, or N jails refreshing at once, can therefore log you out on the
host. Testing that means letting a jail refresh against the vendor with a real
credential, and nobody has done it.

**"Dies with the scratch directory" holds only if Choir exits.** Each wave unlinks its
jails' credential copies as soon as it returns, and the scratch directory goes at the end
of `execute`. A Choir killed mid-wave does neither, and by design it never sweeps on a
later run. What is left behind is a full-account OAuth token, readable by anything
running as you, until you remove it. That is why Choir prints the run directory on line
1.

WARNING: Remove that directory with `rm -rf`. Do not *trash* it. A file manager or a
"safe delete" wrapper moves the directory to `~/.local/share/Trash` or `/tmp/.Trash-$UID`
and preserves the token there indefinitely. Measured: a scratch directory trashed rather
than removed still held a byte-identical copy of a live `~/.codex/auth.json` sixteen
hours later.

**If you Ctrl-C Choir, the jails keep running.** The reason is not the obvious one. POSIX requires a non-interactive shell to set SIGINT and SIGQUIT to *ignored* for
any command it starts asynchronously. Choir starts every jail as `( nsjail … ) &`
inside one `sh -c`. nsjail inherits that disposition, so a terminal's Ctrl-C reaches
Choir and not the jails. Measured on this machine: a command backgrounded inside `sh -c`
carries `SigIgn: 0000000001000006`, which is bits 0x2 and 0x4, SIGINT and SIGQUIT.

What saves you is `--timeout`. Every jail carries `nsjail --time_limit`, the kernel
enforces it, and an abandoned jail kills itself and its entire process tree when the
deadline expires. Measured against a process tree that traps and ignores TERM, INT and
HUP: dead on schedule, zero survivors, and nsjail leaves 0 bytes on disk. So there is
nothing to clean up after the jails. There *is* something to wait for, up to `--timeout`,
which defaults to 20 minutes. If that window bothers you, lower it.

**Choir's own cleanup does not survive Ctrl-C, though.** Choir removes the scratch
directory on the last line of a normal run. A Choir killed mid-run therefore leaves
it behind. It holds one copy of the OAuth credential for each jail still in flight.

 Choir unlinks each jail's credential the moment its wave returns. That shrinks the
window to the time a jail actually uses the token. A Ctrl-C during a wave still strands the copies that belong
to that wave.

They are mode 0600 inside a `mktemp -d` that is 0700, so this is persistence, not
disclosure. Remove the run directory that Choir printed on its first
line.

**The provider runs with its own permission prompts disabled**
(`--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox`), because
a provider blocked on a prompt burns your quota and returns nothing. These flags are not
optional here. A provider's own sandbox cannot nest inside an nsjail, because `/proc` is
read-only in the jail and writing `uid_map` fails. The model has full control of the jail
by design.

**Not verified end to end:** that a real billed provider session can do useful work
inside these jails. Both CLIs start inside the exact command lines below and print a
live subscription (`{"loggedIn": true, "subscriptionType": "max"}`, `Logged in using
ChatGPT`), but nobody has run a paid coding session. If your jails come back empty, that
is the first thing to suspect.

WARNING: Patches are untrusted code from a language model. Read them before you run `git
apply`. Choir runs your test command against them inside the sealed verify jail precisely
so that running them does not require trusting them.

The audit jail is one more language model, with the same network access as a work jail.
Its commentary is prose printed after the results. It has no verdict, and it is not a security review.

It also reads `/patches`, which is text written by the work-jail models. A work jail
can therefore address the audit model directly through its own patch. The audit jail
holds the same token and the same egress the work jails already have, so this grants
nothing new. It is a channel between models that the isolation story otherwise does not
mention.

**Against the status quo:** today that same token runs on your host, beside every
repository you own and your SSH keys. Choir shrinks the worst case to one token plus the
one repository you already handed to the model. That is the whole claim.

## Limits

Deliberate, permanent, and not a roadmap:

- **One instruction per run.** If you want two things done, run Choir twice.
- **The jail is not reproducible.** Its toolchain is your host's `/usr`, bind-mounted
  read-only. That is what removes the image requirement, and it means two machines will
  not produce the same jail. A `--test` command that needs a pyenv shim, `~/.cargo/bin`,
  or anything else outside `/usr` will not find it.
- **`sh` runs your `--test` string,** so the verdict is the exit status of its last
  command. `pytest -q; echo done` prints `PASS` unconditionally. Use `&&`, or a script.
- **Choir never picks a winner.** Your test command is a filter, not a ranking. Every
  ordering available to Choir is wrong somewhere obvious. "Smallest diff" rewards
  removing the failing test.
- **Choir never applies a patch.** There is no `--apply` flag and no code path that
  writes inside `--repo`. You run the printed `git apply` line.
- **Choir does not know your build system.** `--test` is a required flag with no
  detection and no default. This is the single decision that keeps Choir from being a
  tool that only works on Choir.
- **Two providers, named in the source.** `claude` and `codex` are two literal command
  lines. There is no provider interface and no way to register a third. Adding one is an
  edit to those two lines by someone who has run the new CLI.
- **Choir writes one prompt.** The instruction is yours and goes through verbatim. The
  only text Choir itself sends to a model is the fixed sentence that asks the audit jail
  to comment. There is no prompt library, no template, and no system prompt.
- **No retries, no resume, no failover.** A jail that produced nothing is a row in the
  table. A retry needs provider signals that are not reliable. Claude Code exits 0 and
  prints success when it did nothing and asked a question.
- **No quota accounting.** Codex exposes no headless rate-limit signal at all. Choir
  starts what you asked for and prints what came back.
- **No state between runs.** No database, no cache, no session resume, no manifest.
  Re-running is a fresh run. Before the work starts, Choir removes the files this run
  will write: `0.patch` to `<n-1>.patch`, and their logs. A run that writes nothing
  therefore leaves absence rather than the previous run's bytes. Files from a wider
  earlier `-n` stay, so `-n 5` followed by `-n 2` leaves `2.patch`, `3.patch` and
  `4.patch` in place. When that matters, pass a different `--out`.
- **Patches are not composed.** Every jail starts from the same `HEAD`. Two patches that
  touch the same file can conflict, and git will tell you when you apply the second.
- **Choir copies the repository once, plus once per work jail and once per patch tested.**
  The audit jail gets the base copy read-only, so it costs nothing. Measured: 9.3 s per
  copy of a 4.9 GB checkout on btrfs/NVMe, so five copies take about a minute at `-n 2`.
  `cp -a --reflink=auto` measured no faster and is not used.
- **There is no git identity inside a jail.** Your `~/.gitconfig` is not mounted, so a
  provider that tries to `git commit` is refused with *unable to auto-detect email
  address* and leaves the tree dirty. That is exactly what patch extraction wants. If a
  provider configures an identity and commits anyway, `HEAD` moves and its patch comes
  back empty.
- **Choir cannot tell you why a jail failed.** Rate-limited, logged out, refused, wedged,
  and "did not solve it" all look the same from outside: no patch. You get the exit code
  and the provider's last line of output.
- **No streaming.** Choir captures output per jail and prints it at the end of the wave.
- **No daemon, no server, no MCP, no TUI, no subcommands, no configuration file.**
  Everything happens between your Enter key and the exit code.

## Building and verifying

Choir is a two-crate Cargo workspace split on a purity boundary:

```
crates/choir-core   pure. argv -> Config, jail command lines, wave scripts,
                    verdicts, table rows. No I/O, no process spawn, no clock.
                    Zero third-party build dependencies.
crates/choir        the effectful shell. Every syscall in the program lives
                    in sys.rs; run.rs is the three waves in order.
```

The dependency runs one way. The core cannot perform I/O because it cannot name it. That
is what makes the whole decision surface of the program testable without a jail, a
provider, or a network. It is also what makes the program provable in the places where
Rust's fixed-width integers can bite.

```sh
cargo test --workspace                              # 90 tests
cargo clippy --workspace --all-targets -- -D warnings
cargo kani -p choir-core                            # 3 proof harnesses
```

`docs/spec.md` is the contract. Every test names the requirement it defends: `C-*`
behavioral, `E-*` edge case, `P-*` proved property, `N-*` non-functional. You can read a
failure back to the sentence it broke.

Three properties are **proved** rather than tested. They are the places where porting
arithmetic from a language with arbitrary-precision integers into one with wrapping
`usize` silently introduces faults. The provider rotation index is always in range, the
KiB split never overflows, and column padding never underflows. Kani explores the entire
`usize` domain for each.

The isolation claims in *Safety* are nsjail's, not Choir's, so tests exercise them rather
than prove them. `crates/choir/tests/sealed_jail.rs` runs a real verify jail. It asserts
that `/home`, `/root`, `/mnt`, `/var` and `/etc/shadow` are unreachable. It asserts
that `NoNewPrivs` is 1 and `CapEff` is empty. It also asserts that three two-second
jails finish in under four seconds rather than six. Those tests skip with a notice when nsjail is absent.
