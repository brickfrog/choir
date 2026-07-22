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

Create a dedicated runtime directory from the official v0.9.7 runtime bundle
and replace only `boxlite-shim` with the corrected build. For the documented
local installation, copy the admitted binary and directory beside Choir:

```sh
install -Dm755 /absolute/path/to/boxlite-v0.9.7 ~/.local/libexec/choir/boxlite
cp -a /absolute/path/to/corrected-runtime ~/.local/libexec/choir/boxlite-runtime
```

Development and conformance runs may instead select them explicitly with
`CHOIR_BOXLITE_BINARY` and `CHOIR_BOXLITE_RUNTIME_DIR`.

Choir hashes the CLI and all six runtime files before booting a guest. The
accepted identities are defined in `src/sandbox/boxlite_probe.mbt`; a missing
or altered file blocks the runtime before KVM execution.

Verify the installed bundle:

```sh
moon run --target native src/bin/choir_conformance -- sandbox --runtime boxlite --live
```
