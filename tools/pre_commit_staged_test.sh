#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

git init "$tmpdir" >/dev/null

mkdir -p "$tmpdir/.githooks" "$tmpdir/tools"
cp "$repo_root/.githooks/pre-commit" "$tmpdir/.githooks/pre-commit"
cp "$repo_root/tools/lint_canary.sh" "$tmpdir/tools/lint_canary.sh"
cp "$repo_root/moon.mod.json" "$tmpdir/moon.mod.json"

cat > "$tmpdir/staged.mbt" <<'EOF'
pub impl Show for Foo with output(self, logger) -> Unit { logger.write_string("ok") }
EOF

cat > "$tmpdir/unstaged.mbt" <<'EOF'
pub impl Show for Foo with output(self, logger) -> Unit { logger.write_string("ok") }
EOF

cp "$tmpdir/unstaged.mbt" "$tmpdir/unstaged.orig.mbt"

(cd "$tmpdir" && git add staged.mbt)
(
  cd "$tmpdir" &&
  bash .githooks/pre-commit
)

if ! cmp -s "$tmpdir/unstaged.mbt" "$tmpdir/unstaged.orig.mbt"; then
  echo "FAIL: unstaged.mbt was modified by pre-commit (expected byte-identical contents)."
  echo "  expected: $(cat "$tmpdir/unstaged.orig.mbt")"
  echo "  actual:   $(cat "$tmpdir/unstaged.mbt")"
  exit 1
fi

echo "OK: pre_commit_staged_test"
