# Choir

Choir runs one coding task N times in parallel. Each attempt gets its own throwaway
nsjail sandbox with its own copy of your repository, and runs a provider CLI — Claude
Code or Codex, on your own paid subscription — inside it. Each jail returns a patch.
Choir then applies each patch to a fresh copy of the repo and runs your test command
against it in a jail with no network namespace at all, and prints a table of which
patches passed. One more jail reads the repo and the patches and prints commentary.
Choir never modifies or deletes anything in your checkout: it writes one new directory
of patches and prints `git apply` lines for you to run yourself.

One command. No daemon, no config file, no state between runs.

## Why

I have a Claude subscription and a Codex subscription. Both bill by a rolling
five-hour window, and the windows are independent — time spent on one does not
consume the other. Running one agent at a time on my laptop uses half of what I pay
for, and it uses it in the least safe way available: the agent has my whole home
directory, every repository on the machine, my SSH keys, and both credentials.

Choir spends both subscriptions at once, and puts each agent in a jail that contains
one copy of one repository, one provider binary, one credential file, and the
read-only `/usr` your own commands already run from. Three attempts at the same bug
from two different models, tested against your own suite, in the time one attempt
would take.

## Install

Three things.

**1. nsjail.** It is a distro package. On Arch and derivatives it is in `extra`:

```sh
pacman -S nsjail
```

Verified against 3.6. You also need unprivileged user namespaces enabled
(`kernel.unprivileged_userns_clone=1`, which is the default on most desktop distros).
That is the entire requirement: nsjail is a single executable with no daemon, no image,
no kernel virtualisation and no state directory. It starts a jail in about 10 ms and
leaves nothing on disk when it exits.

There is nothing to configure, because the jail's toolchain is your toolchain: Choir
read-only bind-mounts the host's own `/usr`, so whatever runs your tests on the host
runs them in the jail. This is also the honest cost — see *The jail is not
reproducible* under Limits.

**2. A provider CLI, logged in.** `claude` and/or `codex`, authenticated the way you
normally use them — `claude auth status`, `codex login status`. Choir read-only mounts
the resolved binary and copies one credential file into each jail; it does not install
anything. If you drive `claude` through a shell function that injects a token, note
that Choir invokes the resolved binary directly and authenticates from the credential
file alone.

**3. Choir itself.** Gleam 1.18 on Erlang/OTP 29:

```sh
gleam export escript
```

That produces a single self-contained executable.

## Usage

```
choir "<instruction>" --test '<cmd>' [options]
```

| Flag | Default | Meaning |
| --- | --- | --- |
| *(positional)* | — | The instruction. Exactly one, passed verbatim to every work jail. |
| `--test '<cmd>'` | required | Your repository's own test command. Run inside a jail, against each patch. |
| `--repo <path>` | `.` | Repository to copy. Read only; Choir never writes inside it. |
| `-n <count>` | `2` | Work jails. Providers alternate, so the default is one of each. |
| `--providers <list>` | `claude,codex` | Comma-separated. The only accepted words are `claude` and `codex`; anything else is an error. `--providers claude` gives an all-Claude run. The audit jail takes the next index in the same rotation, which is why the example below audits with `codex`. |
| `--timeout <secs>` | `1200` | Per jail, passed straight to `nsjail --time_limit`. The kernel enforces it. |
| `--out <dir>` | `./choir-out` | Where patches are written. The only thing Choir leaves on disk. Relative to your current directory, so running from inside the repo puts it in your working tree. |

Exit code is 0 if at least one patch passed your test command, 1 otherwise.

Your working tree must be committed or stashed. Choir copies `--repo` as it stands,
and the patch it extracts is relative to `HEAD`, so uncommitted changes ship into every
jail, appear inside every patch, and then collide with themselves when the patch is
applied for testing. Every row will say `APPLY FAILED`. Choir does not check for this,
because a check that refuses to run is the shape of thing that killed the last two
versions of this program.

### Example

```
$ choir "the auth test is flaky under load — find and fix the real race" \
    --repo ~/proj --test 'pytest -q' -n 3

3 work jails: 0=claude 1=codex 2=claude; audit=codex; timeout 1200s
[work]   3 jails started
[verify] 2 jails started

JAIL PROVIDER  PATCH    TESTS         LAST LINE FROM PROVIDER
0    claude    4.1 KB   PASS          Replaced the double-checked flag with a lock in session.py.
1    codex     0 B      -             stream error: rate limit reached; resets 14:05
2    claude    6.8 KB   FAIL(1)       Rewrote the fixture to drive a fake clock.

  git apply /home/justin/proj/choir-out/0.patch

audit (codex — model commentary, unverified, no effect on the table above)
--------------------------------------------------------------------------
0.patch takes the lock around the refresh but still reads `expires_at`
outside it, so the narrow race remains on the read path. 2.patch changes
test timing rather than the code under test, which is why it fails.
```

Rows are in jail order. Choir does not rank them, does not sort them, and does not pick
one. `PATCH` is a byte count and exists for one reason: to tell `0 B` from not-`0 B`.
`0 B` means that jail produced no diff — it may have been rate-limited, refused, hung,
or simply not solved the problem, and Choir does not know which. `TESTS` is `PASS`,
`FAIL(<code>)`, `APPLY FAILED` if the patch would not apply to a clean tree, or `-` if
there was no patch to test. A `0 B` patch is the only condition that skips a verify
jail, because there is nothing to apply, and it is the only condition under which Choir
skips anything at all.

`FAIL(137)` is the one ambiguous code. A jail killed by its `--timeout` exits 137, and
so does a test process the kernel's OOM killer picked, and so does a test suite that
exits 137 by itself. All three are failures and Choir does not claim to know which one
you got. It will not grow a mechanism to tell them apart.

Choir does not report progress inside a wave. A wave is one blocking call, so you get
one line when it starts and the finished rows when it ends. There is no elapsed-time
display and no progress bar; run it under `time` if you want one.

Every patch is written to `--out` before any test runs, so nothing Choir does can
discard work a provider actually produced.

## Safety

"Safe(ish)" means the limits are stated, not that there are none.

**A jail is not a virtual machine.** It is Linux namespaces plus rlimits plus
`no_new_privs`, on *your* kernel. There is no guest kernel and no hypervisor. The uid
mapping is identity, so a process in the jail runs as you: files it writes are owned by
you on the host. A kernel privilege-escalation bug or a namespace escape from inside a
jail lands on your whole account. Everything below is true, and none of it is a
hypervisor boundary.

**What the jail does protect.** There is no `--chroot`. The jail's root is an empty
16 MB tmpfs and only the mounts Choir names exist inside it. Verified on this machine
from inside a work jail: `/` contains exactly `bin cmd cred dev etc lib64 patches proc
prov repo tmp usr`; `/home`, `/mnt`, `/root`, `/var`, `/run` and `/home/<you>/.ssh` all
return *No such file or directory*; the only `/etc` entries are `passwd`, `group`,
`hosts`, `resolv.conf`, `ssl` and `ca-certificates`, so `/etc/shadow` does not exist
inside the jail; no other repository on the machine is reachable; `/proc` shows only
the jail's own handful of PIDs, so no host process is visible; `/usr` and `/etc` are
read-only and `mount -o remount,rw` fails with *must be superuser*; `NoNewPrivs` is 1
and `CapEff` is `0000000000000000`, so the setuid `sudo` visible in the read-only
`/usr` is inert. The scratch directory the jails write through is deleted before Choir
exits.

**The verify jail is genuinely sealed.** It gets no `-N`, which means nsjail's default:
its own empty network namespace. Verified: only `lo`, no route, no DNS, no TCP, no UDP,
and a service bound to the host's own `127.0.0.1` is unreachable. It sees no host
abstract unix sockets and cannot open your X display. That is the jail your untrusted
patch runs in.

**The work and audit jails have your entire network, and that is worse than it
sounds.** A subscription CLI has to reach its vendor, so those jails run with `-N`.
`-N` does not mean "restricted networking" — it disables the network namespace
entirely, so the jail is in *your host's* network namespace, verbatim. That gets you
three things at once, all verified from inside a work jail on this machine:

- The whole internet, with no allowlist of any kind. nsjail has no egress filter.
- Every service on your host's `127.0.0.1` and everything on your LAN. Local databases,
  local model servers, your router's admin page.
- Every **abstract unix socket** on the host, because those are scoped by the network
  namespace and not by the filesystem. On a desktop that includes your X server. From
  the exact work-jail command line, `xdpyinfo` opened display `:0` and `xwininfo -root
  -children` enumerated the host's open windows by title. `xdotool`, `import`, `scrot`
  and `curl` are all present in the read-only `/usr` that Choir mounts. A model can
  enumerate your open windows, screenshot your screen, and type into your X11
  applications.

Do not read that as "so the jail is pointless". The same command line still cannot see
your home directory, your SSH keys, or any repository other than the one you named.
But the network flag is the one deliberate hole in this design and it is a big one.

**There is no middle setting, and none is available to you unprivileged.** nsjail's
only other network facility is `--macvlan`, which fails with *Operation not permitted*
without root. `--use_pasta` would give a jail its own namespace with outbound NAT and
no host loopback — that would close both the loopback and the abstract-socket holes —
but `pasta` is not installed here and this has never been tested. It is one package
from the same repository nsjail came from. Until someone runs it, it is not a claim.

**The credential.** What you hand a jail is a full-account OAuth token with a refresh
token and no scoping, because neither vendor mints anything narrower. Anything in that
jail can read it. Choir copies it into a per-jail directory that dies with the scratch
directory, so a token the CLI refreshes inside a jail never lands in your real
`~/.claude` or `~/.codex`. What is **not** known: whether a refresh inside a jail
invalidates the copy on your host. OAuth refresh tokens commonly rotate, and Claude's
access token expires roughly every five hours, so a long run — or N jails refreshing at
once — could plausibly log you out on the host. Testing that means letting a jail
refresh against the vendor with a real credential, and nobody has done it.

**If you Ctrl-C Choir, the jails keep running.** They are started through an Erlang
port, which puts them in a different session from Choir itself, so a terminal's SIGINT
does not reach them — verified: after Ctrl-C, and again after `kill -9` on Choir, the
jails were still alive with the credential inside. What saves you is `--timeout`: every
jail carries `nsjail --time_limit`, the kernel enforces it, and an abandoned jail kills
itself and its entire process tree when it expires. Verified against a process tree
that traps and ignores TERM, INT and HUP: dead on schedule, zero survivors, and nsjail
leaves 0 bytes on disk. So there is no cleanup command because there is nothing to
clean, but there *is* something to wait for — up to `--timeout`, which defaults to 20
minutes. Lower it if that window bothers you.

**The provider runs with its own permission prompts disabled**
(`--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox`),
because a provider blocked on a prompt burns your quota and returns nothing. These are
not optional here: a provider's own sandbox cannot nest inside an nsjail, because
`/proc` is read-only in the jail and writing `uid_map` fails. The model has full
control of the jail by design.

**Not verified end to end:** that a real billed provider session can do useful work
inside these jails. Both CLIs start inside the exact command lines below and report a
live subscription (`{"loggedIn": true, "subscriptionType": "max"}`, `Logged in using
ChatGPT`), but no paid coding session has been run. If your jails come back empty, that
is the first thing to suspect.

Patches are untrusted code from a language model. Read them before `git apply`. Choir
runs your test command against them inside the sealed verify jail precisely so that
executing them does not require trusting them.

The audit jail is one more language model, with the same network access as a work jail.
Its commentary is prose printed after the results, it has no verdict, and it is not a
security review.

**Against the status quo:** today that same token runs on your host, beside every
repository you own and your SSH keys. Choir shrinks the worst case to one token plus
the one repository you already handed to the model. That is the whole claim.

## Limits

Deliberate, permanent, and not a roadmap:

- **One instruction per run.** If you want two things done, run Choir twice.
- **The jail is not reproducible.** Its toolchain is your host's `/usr`, bind-mounted
  read-only. That is what deletes the image requirement, and it means two machines will
  not produce the same jail. A `--test` command that needs a pyenv shim, `~/.cargo/bin`,
  or anything else outside `/usr` will not find it.
- **Your `--test` string is run by `sh`,** so the verdict is the exit status of its last
  command. `pytest -q; echo done` reports `PASS` unconditionally. Use `&&`, or a script.
- **Choir never picks a winner.** Your test command is a filter, not a ranking. Every
  ordering available to Choir is wrong somewhere obvious — "smallest diff" rewards
  deleting the failing test.
- **Choir never applies a patch.** There is no `--apply` flag and no code path that
  writes inside `--repo`. You run the printed `git apply` line.
- **Choir does not know your build system.** `--test` is a required flag with no
  detection and no default. This is the single decision that keeps Choir from being a
  tool that only works on Choir.
- **Two providers, named in the source.** `claude` and `codex` are two literal command
  lines. There is no provider interface and no way to register a third; adding one is an
  edit to those two lines by someone who has run the new CLI.
- **Choir writes one prompt.** The instruction is yours and goes through verbatim. The
  only text Choir itself sends to a model is the fixed sentence that asks the audit jail
  to comment. There is no prompt library, no template, and no system prompt.
- **No retries, no resume, no failover.** A jail that produced nothing is a row in the
  table. The provider signals that would be needed to route a retry are not reliable:
  Claude Code exits 0 reporting success when it did nothing and asked a question.
- **No quota accounting.** Codex exposes no headless rate-limit signal at all. Choir
  launches what you asked for and reports what came back.
- **No state between runs.** No database, no cache, no session resume, no manifest.
  Re-running is a fresh run — and re-running with the same `--out` overwrites the previous
  run's `N.patch`. Choir does not version, timestamp, or refuse. Pass a different `--out`.
- **Patches are not composed.** Every jail starts from the same `HEAD`. Two patches
  touching the same file may conflict, and git will tell you when you apply the second.
- **The repository is copied once, plus once per work jail and once per patch tested.**
  The audit jail gets the base copy read-only, so it costs nothing. Measured: 9.3 s per
  copy of a 4.9 GB checkout on btrfs/NVMe — five copies, about a minute, at `-n 2`.
  `cp -a --reflink=auto` measured no faster and is not used.
- **There is no git identity inside a jail.** Your `~/.gitconfig` is not mounted, so a
  provider that tries to `git commit` is refused with *unable to auto-detect email
  address* and leaves the tree dirty — exactly what patch extraction wants. If a provider
  configures an identity and commits anyway, `HEAD` moves and its patch comes back empty.
- **Choir cannot tell you why a jail failed.** Rate-limited, logged out, refused,
  wedged, and "did not solve it" all look the same from outside: no patch. You get the
  exit code and the provider's last line of output.
- **No streaming.** Output is captured per jail and reported at the end of the wave.
- **No daemon, no server, no MCP, no TUI, no subcommands, no config file.** Everything
  happens between your Enter key and the exit code.
