#!/usr/bin/env bash
set -euo pipefail

# Asserts .githooks/pre-commit's moon fmt step only touches STAGED .mbt files.
# Three sub-tests:
#   sub1     — Stage one of two .mbt files in a fake project; verify the
#              unstaged file is byte-identical after the hook runs.
#   sub_meta — Same fixture but with the BUGGY (bare `moon fmt`) hook; assert
#              the unstaged file DOES get rewritten. Proves sub1's assertion
#              has teeth — without this the test could pass against any
#              fixture moon fmt happens to not walk.
#   sub2     — Stage only a non-.mbt file; verify the hook logs the skip
#              message and leaves unstaged .mbt untouched.
#
# The fixture mirrors a real MoonBit project layout (moon.mod.json + src/
# package) so `moon fmt` actually has something to walk — a flat directory
# without moon.pkg.json is a no-op and would let the bug pass undetected.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Deliberately unformatted: moon fmt will rewrite the spacing and the
# `with fn` rejection isn't relevant here — any rewrite means the file
# changed.
make_fixture() {
  local dir="$1"
  git init "$dir" >/dev/null
  mkdir -p "$dir/.githooks" "$dir/tools" "$dir/src"
  cp "$repo_root/.githooks/pre-commit" "$dir/.githooks/pre-commit"
  cp "$repo_root/tools/lint_canary.sh" "$dir/tools/lint_canary.sh"
  cat > "$dir/moon.mod.json" <<'EOF'
{"name":"fixture","version":"0.1.0"}
EOF
  cat > "$dir/src/moon.pkg.json" <<'EOF'
{"name":"fixture"}
EOF
}

# --- Sub-test 1: staged .mbt is allowed to be reformatted; unstaged is not. ---
sub1="$tmpdir/sub1"
make_fixture "$sub1"

cat > "$sub1/src/staged.mbt" <<'EOF'
pub fn   staged_demo(a:Int,b:Int)->Int{a+b}
EOF
cat > "$sub1/src/unstaged.mbt" <<'EOF'
pub fn   unstaged_demo(a:Int,b:Int)->Int{a+b}
EOF
cp "$sub1/src/unstaged.mbt" "$sub1/unstaged.orig"

(cd "$sub1" && git add src/staged.mbt src/moon.pkg.json moon.mod.json)
(cd "$sub1" && bash .githooks/pre-commit)

if ! cmp -s "$sub1/src/unstaged.mbt" "$sub1/unstaged.orig"; then
  echo "FAIL [sub1]: unstaged.mbt was modified by pre-commit."
  echo "  expected: $(cat "$sub1/unstaged.orig")"
  echo "  actual:   $(cat "$sub1/src/unstaged.mbt")"
  exit 1
fi

# --- Meta-test: prove the fixture HAS teeth by re-running with the bare-fmt
# regression and asserting it DOES corrupt the unstaged file. If this passes,
# the fixture has signal — the main hook's filtering is what's protecting us.
sub_meta="$tmpdir/sub_meta"
make_fixture "$sub_meta"
# Overwrite hook with the buggy version (bare `moon fmt`, no filtering).
cat > "$sub_meta/.githooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
moon fmt
EOF
chmod +x "$sub_meta/.githooks/pre-commit"

cat > "$sub_meta/src/staged.mbt" <<'EOF'
pub fn   staged_demo(a:Int,b:Int)->Int{a+b}
EOF
cat > "$sub_meta/src/unstaged.mbt" <<'EOF'
pub fn   unstaged_demo(a:Int,b:Int)->Int{a+b}
EOF
cp "$sub_meta/src/unstaged.mbt" "$sub_meta/unstaged.orig"

(cd "$sub_meta" && git add src/staged.mbt src/moon.pkg.json moon.mod.json)
(cd "$sub_meta" && bash .githooks/pre-commit)

if cmp -s "$sub_meta/src/unstaged.mbt" "$sub_meta/unstaged.orig"; then
  echo "FAIL [sub_meta]: regression fixture was supposed to corrupt unstaged.mbt"
  echo "  but it didn't — fixture has no teeth. Real test in sub1 may also be vacuous."
  exit 1
fi

# --- Sub-test 2: no .mbt staged → skip moon fmt. ---
sub2="$tmpdir/sub2"
make_fixture "$sub2"

cat > "$sub2/README.md" <<'EOF'
not a mbt file
EOF
cat > "$sub2/src/unstaged.mbt" <<'EOF'
pub fn   unstaged_demo(a:Int,b:Int)->Int{a+b}
EOF
cp "$sub2/src/unstaged.mbt" "$sub2/unstaged.orig"

(cd "$sub2" && git add README.md src/moon.pkg.json moon.mod.json)
sub2_output="$(cd "$sub2" && bash .githooks/pre-commit 2>&1)"

if ! echo "$sub2_output" | grep -q "no staged .mbt files; skipping"; then
  echo "FAIL [sub2]: hook did not log the no-mbt-skip message."
  echo "  output: $sub2_output"
  exit 1
fi
if ! cmp -s "$sub2/src/unstaged.mbt" "$sub2/unstaged.orig"; then
  echo "FAIL [sub2]: unstaged.mbt was modified even though no .mbt was staged."
  exit 1
fi

echo "OK: pre_commit_staged_test (sub1 + sub_meta + sub2)"
