# BoxLite runtime

Choir pins the BoxLite v0.9.7 CLI and runtime bundle separately. The stock
v0.9.7 shim is not admitted on this host because its VMM seccomp profile traps
`time(2)`. [The checked-in patch](../patches/boxlite-seccomp-time.patch) adds
that syscall to the GNU and musl x86-64 profiles.

Build the corrected shim from the v0.9.7 source commit:

```sh
git apply /absolute/path/to/choir-v2/patches/boxlite-seccomp-time.patch
git submodule update --init --recursive
RUSTFLAGS='-C link-arg=-lbz2' cargo build --release -p boxlite-shim
```

Create a dedicated runtime directory from the official v0.9.7 runtime bundle,
replace only `boxlite-shim` with the corrected build, and set:

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

The current host installation is:

- CLI: `/home/justin/.local/bin/boxlite`
- runtime: `/home/justin/.local/share/choir/runtimes/boxlite-v0.9.7-seccomp-time`

