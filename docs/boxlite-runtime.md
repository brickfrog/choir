# BoxLite runtime

Choir pins the BoxLite v0.9.7 CLI and runtime bundle separately. The stock
v0.9.7 shim is not admitted because its VMM seccomp profile traps `time(2)` on
the currently supported host. [The checked-in patch](../patches/boxlite-seccomp-time.patch)
adds that syscall to the GNU and musl x86-64 profiles.

Build the corrected shim from BoxLite tag `v0.9.7`, commit
`8803834036205cf2cac5cfca98bb3875812c897a`:

```sh
git apply /absolute/path/to/choir/patches/boxlite-seccomp-time.patch
git submodule update --init --recursive
RUSTFLAGS='-C link-arg=-lbz2' cargo build --release -p boxlite-shim
```

Create a dedicated runtime directory from the official v0.9.7 runtime bundle,
replace only `boxlite-shim` with the corrected build, and set both variables
before starting `choird`:

```sh
export CHOIR_BOXLITE_BINARY=/absolute/path/to/boxlite-v0.9.7
export CHOIR_BOXLITE_RUNTIME_DIR=/absolute/path/to/corrected-runtime
```

Choir hashes the CLI and all six runtime files before booting a guest. The
accepted identities are defined in `src/sandbox/boxlite_probe.mbt`; a missing
or altered file blocks the runtime before KVM execution.

Verify the installed bundle:

```sh
moon run --target native src/bin/choir_conformance -- sandbox --runtime boxlite --live
```
