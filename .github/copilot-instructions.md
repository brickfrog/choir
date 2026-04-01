# Choir repository

Primary implementation language is MoonBit (files named `*.mbt`). Treat these as Rust-like systems code: explicit error handling, ADTs, and minimal shelling out on orchestration paths.

When reviewing pull requests, read `.mbt` diffs as normal source changes even if the language label is unfamiliar.

If the only changes are a small number of hunks inside a very large `*.mbt` file (for example `src/bin/choir/main.mbt`), review those hunks anyway. Do not treat “no reviewable files” as correct when the PR shows a real diff.
