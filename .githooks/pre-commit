#!/usr/bin/env bash
set -euo pipefail

echo "→ moon fmt"
staged="$(git diff --cached --name-only)"
moon fmt

if [ -n "$staged" ]; then
  while IFS= read -r f; do
    if [ -e "$f" ] && ! git check-ignore -q "$f" 2>/dev/null; then
      git add -- "$f"
    fi
  done <<EOF
$staged
EOF
fi

echo "→ moon check --target native"
moon check --target native
