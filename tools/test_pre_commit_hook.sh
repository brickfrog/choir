#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

tmp_root="$(mktemp -d)"
trap 'rm -rf -- "$tmp_root"' EXIT

repo="$tmp_root/repo"
bin="$tmp_root/bin"
mkdir -p "$repo" "$bin"

git_cmd() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git "$@"
}

sha256_file() {
  sha256sum "$1" | awk '{ print $1 }'
}

fail() {
  echo "FAIL: $*" >&2
  if [ -f "${commit_log:-}" ]; then
    echo "commit output:" >&2
    sed -n '1,120p' "$commit_log" >&2
  fi
  exit 1
}

git_cmd init -q "$repo"
cd "$repo"

git_cmd config user.email pre-commit-hook-test@example.invalid
git_cmd config user.name "Pre Commit Hook Test"

mkdir -p .githooks
cp "$PROJECT_DIR/.githooks/pre-commit" .githooks/pre-commit
chmod +x .githooks/pre-commit
git_cmd config core.hooksPath .githooks

cat > "$bin/moon" <<'MOON'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  fmt)
    shift
    if [ "${1:-}" = "--" ]; then
      shift
    fi
    for file in "$@"; do
      tmp="$(mktemp "${file}.moonfmt.XXXXXX")"
      dd if="$file" of="$tmp" bs=10 count=1 2>/dev/null || true
      mv "$tmp" "$file"
    done
    exit 0
    ;;
  check)
    if [ "${2:-}" = "--target" ] && [ "${3:-}" = "native" ]; then
      exit 1
    fi
    ;;
esac

echo "unexpected fake moon invocation: $*" >&2
exit 127
MOON
chmod +x "$bin/moon"

mkdir -p src
test_file="src/corrupt_me.mbt"
cat > "$test_file" <<'MBT'
pub fn meaning() -> Int {
  42
}

test "meaning" {
  inspect(meaning(), content="42")
}
MBT

pre_hash="$(sha256_file "$test_file")"
git_cmd add -- "$test_file"

commit_log="$tmp_root/commit.out"
set +e
PATH="$bin:$PATH" git_cmd commit -m test >"$commit_log" 2>&1
commit_status=$?
set -e

if [ "$commit_status" -eq 0 ]; then
  fail "git commit unexpectedly succeeded; fake moon check should make the hook fail"
fi

post_hash="$(sha256_file "$test_file")"
if [ "$post_hash" != "$pre_hash" ]; then
  fail "working tree corruption not restored: expected sha256 $pre_hash, got $post_hash"
fi

index_hash="$(git_cmd show ":$test_file" | sha256sum | awk '{ print $1 }')"
if [ "$index_hash" != "$pre_hash" ]; then
  fail "index corruption not restored: expected sha256 $pre_hash, got $index_hash"
fi

if ! grep -Fq "✗ moon fmt/check failed; restored 1 .mbt file(s) from pre-fmt snapshot" "$commit_log"; then
  fail "restore message was not printed by pre-commit hook"
fi

echo "PASS: pre-commit hook restored .mbt working tree and index after moon fmt/check failure"
