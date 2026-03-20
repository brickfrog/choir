#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-latest}"
MOON_HOME_DIR="${2:-${MOON_HOME:-$HOME/.moon}}"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    TARGET="linux-x86_64"
    ;;
  Darwin-arm64)
    TARGET="darwin-aarch64"
    ;;
  *)
    echo "unsupported platform: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

BASE_URL="https://cli.moonbitlang.com"
MOONBIT_URL="$BASE_URL/binaries/$VERSION/moonbit-$TARGET.tar.gz"
CORE_URL="$BASE_URL/cores/core-$VERSION.tar.gz"

mkdir -p "$MOON_HOME_DIR" "$MOON_HOME_DIR/lib"

moonbit_archive="$(mktemp)"
core_archive="$(mktemp)"
trap 'rm -f "$moonbit_archive" "$core_archive"' EXIT

curl --fail --location --silent --show-error "$MOONBIT_URL" -o "$moonbit_archive"
rm -rf "$MOON_HOME_DIR/bin" "$MOON_HOME_DIR/include" "$MOON_HOME_DIR/lib"
mkdir -p "$MOON_HOME_DIR/lib"
tar xf "$moonbit_archive" --directory "$MOON_HOME_DIR"

find "$MOON_HOME_DIR/bin" -type f -exec chmod +x {} +
if [ -f "$MOON_HOME_DIR/bin/internal/tcc" ]; then
  chmod +x "$MOON_HOME_DIR/bin/internal/tcc"
fi

curl --fail --location --silent --show-error "$CORE_URL" -o "$core_archive"
rm -rf "$MOON_HOME_DIR/lib/core"
tar xf "$core_archive" --directory "$MOON_HOME_DIR/lib"

PATH="$MOON_HOME_DIR/bin:$PATH" "$MOON_HOME_DIR/bin/moon" -C "$MOON_HOME_DIR/lib/core" bundle --warn-list -a --all
PATH="$MOON_HOME_DIR/bin:$PATH" "$MOON_HOME_DIR/bin/moon" -C "$MOON_HOME_DIR/lib/core" bundle --warn-list -a --target wasm-gc --quiet

echo "installed moonbit to $MOON_HOME_DIR"
