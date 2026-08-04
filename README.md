# Choir

Choir runs one coding task N times in parallel. Each attempt gets its own throwaway
BoxLite microVM with its own copy of your repository, and runs a provider CLI —
Claude Code or Codex, on your own paid subscription — inside it. Each box returns a
patch. Choir then applies each patch to a fresh copy of the repo and runs your test
command against it in a box with no network interface, and prints a table of which
patches passed. One more box reads the repo and the patches and prints commentary.
Choir never modifies or deletes anything in your checkout: it writes one new
directory of patches and prints `git apply` lines for you to run yourself.

One command. No daemon, no config file, no state between runs.

## Why

I have a Claude subscription and a Codex subscription. Both bill by a rolling
five-hour window, and the windows are independent — time spent on one does not
consume the other. Running one agent at a time on my laptop uses half of what I pay
for, and it uses it in the least safe way available: the agent has my whole home
directory, every repository on the machine, my SSH keys, and both credentials.

Choir spends both subscriptions at once, and puts each agent in a box that contains
one copy of one repository and nothing else. Three attempts at the same bug from two
different models, tested against your own suite, in the time one attempt would take.

## Install

Four things must be present.

**1. A patched BoxLite 0.9.7.** The published 0.9.7 release binary does not work.
Two defects have to be fixed and both patches are in this repo:

- `patches/boxlite-reflink-permissions.patch` — without it no box starts at all on a
  btrfs filesystem. The jailer reflinks its shim without the exec bit and every box
  dies with `bwrap: execvp .../boxlite-shim: Permission denied`.
- `patches/boxlite-seccomp-time.patch` — without it, `--network disabled` fails to
  start and `--allow-net` dies with SIGSEGV. Both are modes Choir requires. Default
  full networking works without this patch, so the defect is invisible until you try
  to restrict egress.

Against BoxLite tag `v0.9.7` (commit `8803834036205cf2cac5cfca98bb3875812c897a`):

```sh
git apply /path/to/choir/patches/boxlite-reflink-permissions.patch
SKIP_GUEST_BUILD=1 cargo build --release --locked -p boxlite-cli

git apply /path/to/choir/patches/boxlite-seccomp-time.patch
RUSTFLAGS='-C link-arg=-lbz2' cargo build --release -p boxlite-shim
```

Install the shim over `~/.local/share/boxlite/runtimes/v0.9.7/boxlite-shim`, and put
the CLI somewhere you can name. You pass its path to Choir explicitly with
`--boxlite`; Choir does not search `PATH`, because on a machine that has both, the
one on `PATH` is usually the broken one.

You also need `/dev/kvm` readable and unprivileged user namespaces enabled.

**2. A provider CLI, logged in.** `claude` and/or `codex`, authenticated the way you
normally use them — `claude auth status`, `codex login status`. Choir copies the
resolved binary and one credential file into each box; it does not install anything.

**3. A container image that fits your repository.** You name it with `--image`. It
must contain:

- everything your `--test` command needs to run,
- `git`, because the provider CLIs use it constantly and a network-restricted box
  cannot install it,
- glibc, if you use Claude Code — that binary is dynamically linked, so it will not
  run on Alpine. Codex is a static musl binary and runs on anything.

Possibly also `bubblewrap`. **This is one of the two things about Choir that have not
been verified** (the other is the Claude allow-net host list, under Safety). A real
authenticated Codex session was run inside a stock Alpine box:
login worked, tokens were billed, and it then could not read a single file, printing
`Codex could not find bubblewrap on PATH` and `the shell sandbox failed to start`,
and exiting 0 with an empty patch. Choir runs both providers with their own sandbox
disabled (`--dangerously-skip-permissions`,
`--dangerously-bypass-approvals-and-sandbox`), which *should* remove that dependency,
but nobody has yet run a billed session that proves it. If your boxes come back empty,
put `bubblewrap` in your image and try again — and if that is what fixes it, this
paragraph is wrong and the requirement above is unconditional.

A stock `alpine:latest` or `debian:stable-slim` will authenticate and run the CLI, and
then fail to do useful work because it has no `git`. Build one image for your project
once; Choir has no image pipeline and never will.

**4. Choir itself.** Gleam 1.18 on Erlang/OTP 29:

```sh
gleam export escript
```

That produces a single self-contained executable.

## Usage

```
choir "<instruction>" --test '<cmd>' --image <ref> --boxlite <path> [options]
```

| Flag | Default | Meaning |
| --- | --- | --- |
| *(positional)* | — | The instruction. Exactly one, passed verbatim to every work box. |
| `--test '<cmd>'` | required | Your repository's own test command. Run inside a box, against each patch. |
| `--image <ref>` | required | Image every box boots from. |
| `--boxlite <path>` | required | Path to the patched BoxLite CLI. |
| `--repo <path>` | `.` | Repository to copy. Read only; Choir never writes inside it. |
| `-n <count>` | `2` | Work boxes. Providers alternate, so the default is one of each. |
| `--providers <list>` | `claude,codex` | Comma-separated. The only accepted words are `claude` and `codex`; anything else is an error. `--providers claude` gives an all-Claude run. |
| `--timeout <secs>` | `1200` | Per wave. Choir stops waiting after this; any box still pending is destroyed and its row says `TIMEOUT`. |
| `--out <dir>` | `./choir-out` | Where patches are written. The only thing Choir leaves on disk. Relative to your current directory, so running from inside the repo puts it in your working tree. |

Exit code is 0 if at least one patch passed your test command, 1 otherwise.

Your working tree must be committed or stashed. Choir copies `--repo` as it stands,
and the patch it extracts is relative to `HEAD`, so uncommitted changes ship into every
box, appear inside every patch, and then collide with themselves when the patch is
applied for testing. Every row will say `APPLY FAILED`. Choir does not check for this,
because a check that refuses to run is the shape of thing that killed the last two
versions of this program.

### Example

```
$ choir "the auth test is flaky under load — find and fix the real race" \
    --repo ~/proj --test 'pytest -q' --image proj-ci:latest \
    --boxlite ~/.local/libexec/choir/boxlite -n 3

3 work boxes: 0=claude 1=codex 2=claude; audit=codex; timeout 1200s
[work]   0 started  1 started  2 started
[work]   0 done(0)  1 done(1)  2 done(0)
[verify] 0 started  2 started
[verify] 0 done(0)  2 done(1)

BOX  PROVIDER  PATCH    TESTS         LAST LINE FROM PROVIDER
0    claude    4.1 KB   PASS          Replaced the double-checked flag with a lock in session.py.
1    codex     0 B      -             stream error: rate limit reached; resets 14:05
2    claude    6.8 KB   FAIL          Rewrote the fixture to drive a fake clock.

  git apply /home/justin/proj/choir-out/0.patch

audit (codex — model commentary, unverified, no effect on the table above)
--------------------------------------------------------------------------
0.patch takes the lock around the refresh but still reads `expires_at`
outside it, so the narrow race remains on the read path. 2.patch changes
test timing rather than the code under test, which is why it fails.
```

Rows are in box order. Choir does not rank them, does not sort them, and does not pick
one. `PATCH` is a byte count and exists for one reason: to tell `0 B` from not-`0 B`.
`0 B` means that box produced no diff — it may have been rate-limited, refused, hung,
or simply not solved the problem, and Choir does not know which. `TESTS` is `PASS`,
`FAIL`, `APPLY FAILED` if the patch would not apply to a clean tree, or `-` if there
was no patch to test.

Every patch is written to `--out` before any test runs, so nothing Choir does can
discard work a provider actually produced.

There is no elapsed-time display and no progress bar. Choir has no clock; run it under
`time` if you want one.

## Safety

"Safe(ish)" means the limits are stated, not that there are none.

**What the box does protect.** A provider running in a Choir box cannot read your
other repositories, your SSH keys, your host filesystem, or your host processes. It is
a microVM with its own kernel. Exactly three things are copied in: one copy of the
repository you named, one provider binary, and one credential file. Nothing is
bind-mounted, so there is no host path the guest can write through. The box that runs
your test command is created with `--network disabled`: verified on this runtime to
have `lo` and nothing else — no `eth0`, no route, no gateway, no reachable host
service.

**What it does not protect.** The boxes that run a provider — the N work boxes and the
audit box — have network access, because a subscription CLI has to reach its vendor to
authenticate. They are created with `--allow-net` restricted to that provider's API hosts.
Only the Codex list has ever carried a real authenticated session; if Claude Code cannot log
in, its own error is what you will see in the table. That restriction is a guardrail and not
a boundary:

- UDP egress is not filtered at all. A box restricted to `api.anthropic.com` can send
  and receive UDP with any host on the internet.
- The DNS sinkhole is bypassed by asking a different resolver. Blocked names resolve
  normally when queried against `9.9.9.9` directly, which is also a working
  exfiltration channel on its own.
- Anything listening on your host's `127.0.0.1` is reachable from inside a networked
  box at `192.168.127.254`. Local databases, local model servers, and anything else
  bound to loopback are exposed for the life of the run.

The credential you hand a box is a full-account OAuth token with a refresh token and
no scoping — neither vendor offers a narrower one. Anything running in that box can
read it and use it until the box is destroyed.

If you Ctrl-C Choir, or it crashes, or you close the terminal, it never gets to destroy
its boxes and they stay up with that credential inside them. `boxlite rm -f -a` removes
them. Choir will not do this for you at startup: a sweeper cannot tell an abandoned box
from one belonging to a Choir you are running in another terminal.

The provider runs with its own permission prompts disabled, because a provider blocked
on a prompt burns your quota and returns nothing. The model has full control of the
guest. The box is the only thing between it and your machine, which is why the box has
to be real.

Patches are untrusted code from a language model. Read them before `git apply`. Choir
runs your test command against them inside a network-disabled box precisely so that
executing them does not require trusting them.

The audit box is one more language model, with the same network access as a work box.
Its commentary is prose printed after the results, it has no verdict, and it is not a
security review.

**Against the status quo:** today that same token runs on your host, beside every
repository you own and your SSH keys. Choir shrinks the worst case to one token plus
the one repository you already handed to the model. That is the whole claim.

## Limits

Deliberate, permanent, and not a roadmap:

- **One instruction per run.** If you want two things done, run Choir twice.
- **Choir never picks a winner.** Your test command is a filter, not a ranking. Every
  ordering available to Choir is wrong somewhere obvious — "smallest diff" rewards
  deleting the failing test.
- **Choir never applies a patch.** There is no `--apply` flag and no code path that
  writes inside `--repo`. You run the printed `git apply` line.
- **Choir does not know your build system.** `--test` and `--image` are required flags
  with no detection and no defaults. This is the single decision that keeps Choir from
  being a tool that only works on Choir.
- **Two providers, named in the source.** `claude` and `codex` are two literal
  command lines. There is no provider interface and no way to register a third; adding
  one is an edit to those two lines by someone who has run the new CLI.
- **Choir writes one prompt.** The instruction is yours and goes through verbatim. The
  only text Choir itself sends to a model is the fixed sentence that asks the audit box
  to comment. There is no prompt library, no template, and no system prompt.
- **No retries, no resume, no failover.** A box that produced nothing is a row in the
  table. The provider signals that would be needed to route a retry are not reliable:
  Claude Code exits 0 reporting success when it did nothing and asked a question.
- **No quota accounting.** Codex exposes no headless rate-limit signal at all. Choir
  launches what you asked for and reports what came back.
- **No state between runs.** No database, no cache, no session resume, no manifest.
  Re-running is a fresh run — and re-running with the same `--out` overwrites the previous
  run's `N.patch`. Choir does not version, timestamp, or refuse. Pass a different `--out`.
- **Patches are not composed.** Every box starts from the same `HEAD`. Two patches
  touching the same file may conflict, and git will tell you when you apply the second.
- **Choir cannot tell you why a box failed.** Rate-limited, logged out, refused,
  wedged, and "did not solve it" all look the same from outside: no patch. You get the
  exit code and the provider's last line of output.
- **No streaming.** Output is captured in the box and reported at the end.
- **No daemon, no server, no MCP, no TUI, no subcommands, no config file.** Everything
  happens between your Enter key and the exit code.

`docs/goal.md` says Choir spawns "N network-disabled BoxLite microVMs". It cannot: a
subscription CLI has to authenticate, and BoxLite's `--allow-net` is explicitly
incompatible with `--network disabled`. Only the verify boxes are network-disabled.
See the end of `docs/architecture.md`.
