# BoxLite runtime

Choir pins the BoxLite v0.9.7 CLI and runtime bundle separately. Two upstream
defects require checked-in corrections:

- BoxLite v0.9.7 locks `reflink-copy` 0.1.29. On Btrfs its jailer reflinks the
  runtime shim without preserving the executable mode, so a durable BoxLite
  home produces a `0644` shim and cannot boot a VM. The
  [CLI patch](../patches/boxlite-reflink-permissions.patch) advances only that
  dependency to 0.1.30, where upstream fixed permission preservation.
- The stock v0.9.7 shim's VMM seccomp profile traps `time(2)` on the currently
  supported host. The
  [runtime patch](../patches/boxlite-seccomp-time.patch) adds that syscall to
  the GNU and musl x86-64 profiles.

Build the corrected CLI from BoxLite tag `v0.9.7`, commit
`8803834036205cf2cac5cfca98bb3875812c897a`:

```sh
git apply /absolute/path/to/choir/patches/boxlite-reflink-permissions.patch
git submodule update --init --recursive
SKIP_GUEST_BUILD=1 cargo build --release --locked -p boxlite-cli
```

Build the corrected shim from BoxLite tag `v0.9.7`, commit
`8803834036205cf2cac5cfca98bb3875812c897a`:

```sh
git apply /absolute/path/to/choir/patches/boxlite-seccomp-time.patch
git submodule update --init --recursive
RUSTFLAGS='-C link-arg=-lbz2' cargo build --release -p boxlite-shim
```

These commands produce candidate artifacts, not proof of the admitted byte
identities. The v0.9.7 build embeds absolute source paths and
toolchain-generated build IDs. The qualified Linux CLI was built with Rust
1.98.0-nightly, Go 1.26.5, LLD 22.1.8, and GCC 16.1.1. The qualified Linux
shim retains its separately recorded toolchain identity. Preserve the admitted
CLI and complete six-file runtime together as the rollback and recovery unit.
A rebuild must pass the hash gates and the full live qualification suite before
it can replace those preserved bytes.

Create a dedicated runtime directory from the official v0.9.7 runtime bundle
and replace only `boxlite-shim` with the corrected build. For the documented
local installation, copy the admitted binary and directory beside Choir:

```sh
install -Dm755 /absolute/path/to/corrected-boxlite-v0.9.7 ~/.local/libexec/choir/boxlite
cp -a /absolute/path/to/corrected-runtime ~/.local/libexec/choir/boxlite-runtime
```

Development runs may instead select them explicitly with
`CHOIR_BOXLITE_BINARY` and `CHOIR_BOXLITE_RUNTIME_DIR`.

The qualification evidence records both checked-in patch hashes. Choir hashes
the CLI and all six runtime files before booting a guest. The accepted
identities are defined in `src/sandbox/boxlite_probe.mbt`; a missing or altered
runtime artifact blocks KVM execution.

The reusable API capability is never a process argument or credential file.
Choir launches `boxlite serve` with `BOXLITE_SERVE_API_KEY`, authenticates
remote BoxLite CLI calls with `BOXLITE_API_KEY`, and supplies direct curl
authorization through an inherited stdin pipe using `--header @-`. The
per-Take owner execution capability remains environment-only and scoped to its
owner-only Unix socket. Live qualification reads the server's `/proc` command
line and requires both authenticated success and unauthenticated rejection.
