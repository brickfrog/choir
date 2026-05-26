#!/usr/bin/env sh
set -eu

assert_exit() {
  file=$1
  expected=$2
  label=$3

  if tools/lint_canary.sh "$file"; then
    status=0
  else
    status=$?
  fi

  if [ "$status" -ne "$expected" ]; then
    echo "FAIL: $label (expected exit $expected, got $status)"
    exit 1
  fi
}

assert_exit tests/fixtures/canary/bad_impl.mbt 1 "bad_impl should fail"
assert_exit tests/fixtures/canary/bad_trait.mbt 1 "bad_trait should fail"
assert_exit tests/fixtures/canary/good.mbt 0 "good should pass"

split_brace_trait="$(mktemp)"
split_brace_trait_comment="$(mktemp)"
trap 'rm -f "$split_brace_trait" "$split_brace_trait_comment"' EXIT
cat > "$split_brace_trait" <<'EOF'
trait Bar
{
  fn baz(Self) -> Int
}
EOF
assert_exit "$split_brace_trait" 1 "split-brace trait should fail"

cat > "$split_brace_trait_comment" <<'EOF'
trait Bar
// docs mention } syntax
{
  fn baz(Self) -> Int
}
EOF
assert_exit "$split_brace_trait_comment" 1 "split-brace trait with pre-body close-brace comment should fail"

echo "OK: lint_canary_test"
