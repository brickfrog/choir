# choir dev sanity check — run `just --list` to see recipes.
#
# `just sanity` after self-dev work: it times the native test suite, then
# checks, rebuilds the release binary, and relaunches choir — one command.
# The timing on `moon test` is the cheap signal that a slow / badly-scoped
# test sneaked in (CLAUDE.md forbids shell-harness / temp-git tests): a sudden
# jump in wall time means a bad test landed. The recipe stops before the
# rebuild if any test fails or `moon check` warns, so problems surface before
# choir relaunches on top of them.

set shell := ["bash", "-uc"]

# List available recipes.
default:
    @just --list

# Time the native test suite — CI's gate (`moon test --target native`).
test:
    @echo ">>> moon test --target native (timed)"
    time moon test --target native

# Full sanity pass: timed tests -> moon check -> rebuild release binary -> relaunch choir.
sanity: test
    @echo ">>> moon check --target native"
    moon check --target native
    @echo ">>> rebuild release binary"
    moon build --target native --release
    @echo ">>> relaunch choir (choir init --recreate)"
    choir init --recreate
