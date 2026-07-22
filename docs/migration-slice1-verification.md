# Migration Slice 1 Verification

Recorded on 2026-07-21 for the contract, context, command-preparation, and
typed-finding implementation.

## Toolchain

```text
moon 0.1.20260713 (75c7e1f 2026-07-13)
moonc v0.10.4+2cc641edf (2026-07-15)
moonrun 0.1.20260713 (75c7e1f 2026-07-13)
Feature flags: rr_moon_mod, rr_moon_pkg
moonbitlang/quickcheck 0.14.0
```

The target matrix uses one compiler implementation and is drift detection, not
independent implementation evidence.

## Results

```text
moon fmt --check
  passed

moon check --target native
  passed with existing warnings and no errors

moon test src/command src/migration --target all
  wasm: 13 passed
  wasm-gc: 13 passed
  js: 13 passed
  native debug: 13 passed

moon test src/command src/migration --target native --release
  native release: 13 passed

CHOIR_TEST_NO_EXEC=1 moon test --target native
  395 passed

moon build src/bin/choir --target native
CHOIR_TEST_REAL_EXEC=1 moon test src/exec src/bin/choir --target native
  140 passed
```

The generated properties use an explicit `max_success=128` and
`max_size=32`. A failure reports QuickCheck replay state through the pinned
runner; a sound minimized case should be retained as a fixed fixture before the
implementation changes.
