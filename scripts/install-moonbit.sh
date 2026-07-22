#!/usr/bin/env bash
set -euo pipefail

PINNED_VERSION="0.10.4+2cc641edf+75c7e1f"
VERSION="${1:-$PINNED_VERSION}"
MOON_HOME_DIR="${2:-${MOON_HOME:-$HOME/.moon}}"

if [ "$VERSION" != "$PINNED_VERSION" ]; then
  echo "unsupported MoonBit version: $VERSION (expected $PINNED_VERSION)" >&2
  exit 1
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    TARGET="linux-x86_64"
    MOONBIT_SHA256="31b7fc5cc78657964a6d545792ecd7fb8eed51b97c7431a17458b58734303381"
    ;;
  Darwin-arm64)
    TARGET="darwin-aarch64"
    MOONBIT_SHA256="9f949682cfbf438b7aa9ca93d44fe462dd6c522d89b0b9bd39f87dabf8d86551"
    ;;
  *)
    echo "unsupported platform: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

CORE_SHA256="03ad55b99f3e431f3cb81b4e2bb28bb98173304e4a1b18a891ea027cabba5d1c"
RELEASE_TAG="v${VERSION//+/%2B}"
BASE_URL="https://github.com/moonbit-community/moonbit-overlay/releases/download/$RELEASE_TAG"
MOONBIT_URL="$BASE_URL/moonbit-$TARGET.tar.gz"
CORE_URL="$BASE_URL/moonbit-core.tar.gz"

mkdir -p "$MOON_HOME_DIR" "$MOON_HOME_DIR/lib"

moonbit_archive="$(mktemp)"
core_archive="$(mktemp)"
trap 'rm -f "$moonbit_archive" "$core_archive"' EXIT

curl --fail --location --silent --show-error "$MOONBIT_URL" -o "$moonbit_archive"
curl --fail --location --silent --show-error "$CORE_URL" -o "$core_archive"

archive_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

actual_moonbit_sha256="$(archive_sha256 "$moonbit_archive")"
actual_core_sha256="$(archive_sha256 "$core_archive")"
if [ "$actual_moonbit_sha256" != "$MOONBIT_SHA256" ]; then
  echo "MoonBit archive SHA-256 mismatch: expected $MOONBIT_SHA256, got $actual_moonbit_sha256" >&2
  exit 1
fi
if [ "$actual_core_sha256" != "$CORE_SHA256" ]; then
  echo "MoonBit core SHA-256 mismatch: expected $CORE_SHA256, got $actual_core_sha256" >&2
  exit 1
fi

rm -rf "$MOON_HOME_DIR/bin" "$MOON_HOME_DIR/include" "$MOON_HOME_DIR/lib"
mkdir -p "$MOON_HOME_DIR/lib"
tar xf "$moonbit_archive" --directory "$MOON_HOME_DIR"

find "$MOON_HOME_DIR/bin" -type f -exec chmod +x {} +
if [ -f "$MOON_HOME_DIR/bin/internal/tcc" ]; then
  chmod +x "$MOON_HOME_DIR/bin/internal/tcc"
fi

tar xf "$core_archive" --directory "$MOON_HOME_DIR/lib"

PATH="$MOON_HOME_DIR/bin:$PATH" "$MOON_HOME_DIR/bin/moon" -C "$MOON_HOME_DIR/lib/core" bundle --warn-list -a --all
PATH="$MOON_HOME_DIR/bin:$PATH" "$MOON_HOME_DIR/bin/moon" -C "$MOON_HOME_DIR/lib/core" bundle --warn-list -a --target wasm-gc --quiet

echo "installed moonbit to $MOON_HOME_DIR"
