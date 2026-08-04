# choir

The executable, and the effectful half of the program.

```
src/main.rs   argv in, exit code out
src/sys.rs    every syscall Choir makes — process spawn, files, stdin
src/run.rs    the three waves, in order
```

`run.rs` holds no decisions. It calls into `choir-core` for every command line,
every script, every verdict, and every rendered row, then performs the syscalls
those answers imply. If you find yourself writing an `if` in here that changes
what the program *concludes* rather than what it *does*, it belongs in the core.

## The three waves

1. **work** — `n` provider jails, each with a writable copy of the repository
   and one credential. Networked through pasta.
2. **verify** — one jail per applicable patch, with no network flag at all: its
   own empty network namespace. This is where untrusted patches run.
3. **audit** — one more provider jail, read-only on the repo, after the table is
   already printed.

Each wave is one blocking `/bin/sh -c` that backgrounds its jails and `wait`s,
so a wave costs about its longest jail rather than the serial sum.

## Errors

Swallowed, deliberately and uniformly. A jail that produced nothing is a row in
the table, not an error: a missing credential surfaces as the provider printing
"not logged in" into its log, and an unresolved binary surfaces as nsjail exiting
255 with its own message as the jail's last line. Anything that can refuse to
start the run is the smallest version of the gate that killed v2.

## Testing

```sh
cargo test -p choir
```

`tests/sealed_jail.rs` runs a real `nsjail` — no provider, no quota — and checks
that a verify jail cannot reach `/home`, `/root`, `/mnt`, `/var` or
`/etc/shadow`, that `NoNewPrivs` is 1 and `CapEff` is empty, that exit statuses
reach their `.rc` files, and that three two-second jails finish in under four
seconds rather than six. Skipped with a notice when nsjail is not installed.
