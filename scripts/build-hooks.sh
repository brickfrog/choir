#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
artifact="$repo_root/hooks/_build/wasm/release/build/src/src.wasm"
install_dir="$repo_root/.choir/hooks"
install_path="$install_dir/hook.wasm"

moon -C "$repo_root/hooks" build --target wasm --release

if [[ ! -f "$artifact" ]]; then
  echo "expected hooks wasm artifact missing: $artifact" >&2
  exit 1
fi

# .choir/ is gitignored runtime state, so each checkout materializes its own
# hook artifact before spawning contract-boundary hook-enabled leaves.
mkdir -p "$install_dir"
cp "$artifact" "$install_path"
echo "installed $install_path"
