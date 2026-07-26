#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-${HOME:-}/.local}"
BOXLITE_BINARY="${BOXLITE_BINARY:-}"
BOXLITE_RUNTIME="${BOXLITE_RUNTIME:-}"

usage() {
  echo "usage: scripts/install-choir.sh [--prefix PREFIX] [BOXLITE_BINARY BOXLITE_RUNTIME]" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      [ "$#" -ge 2 ] || usage
      PREFIX="$2"
      shift 2
      ;;
    --prefix=*)
      PREFIX="${1#--prefix=}"
      shift
      ;;
    --help|-h)
      usage
      ;;
    --*)
      echo "unknown option: $1" >&2
      usage
      ;;
    *)
      if [ -z "$BOXLITE_BINARY" ]; then
        BOXLITE_BINARY="$1"
      elif [ -z "$BOXLITE_RUNTIME" ]; then
        BOXLITE_RUNTIME="$1"
      else
        echo "unexpected argument: $1" >&2
        usage
      fi
      shift
      ;;
  esac
done

if [ -z "$PREFIX" ]; then
  echo "install prefix must not be empty" >&2
  exit 1
fi
if [ -z "$BOXLITE_BINARY" ]; then
  echo "BoxLite binary is required (pass it as an argument or set BOXLITE_BINARY)" >&2
  exit 1
fi
if [ ! -f "$BOXLITE_BINARY" ] || [ ! -x "$BOXLITE_BINARY" ]; then
  echo "BoxLite binary is missing or not executable: $BOXLITE_BINARY" >&2
  exit 1
fi
if [ -z "$BOXLITE_RUNTIME" ]; then
  echo "BoxLite runtime directory is required (pass it as an argument or set BOXLITE_RUNTIME)" >&2
  exit 1
fi
if [ ! -d "$BOXLITE_RUNTIME" ]; then
  echo "BoxLite runtime path is missing or not a directory: $BOXLITE_RUNTIME" >&2
  exit 1
fi

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
SANDBOX_MCP="$SCRIPT_DIR/choir_sandbox_mcp.mjs"
BOXLITE_OWNER="$SCRIPT_DIR/choir_boxlite_owner.mjs"
BUILT_CHOIR="$REPO_ROOT/_build/native/release/build/src/bin/choir/choir.exe"

if [ ! -f "$SANDBOX_MCP" ]; then
  echo "required runtime asset is missing: $SANDBOX_MCP" >&2
  exit 1
fi
if [ ! -f "$BOXLITE_OWNER" ]; then
  echo "required runtime asset is missing: $BOXLITE_OWNER" >&2
  exit 1
fi

moon -C "$REPO_ROOT" build --target native --release

if [ ! -f "$BUILT_CHOIR" ]; then
  echo "native release build did not produce: $BUILT_CHOIR" >&2
  exit 1
fi

LIBEXEC_DIR="$PREFIX/libexec/choir"
BIN_DIR="$PREFIX/bin"
mkdir -p "$LIBEXEC_DIR" "$BIN_DIR"
install -m755 "$BUILT_CHOIR" "$LIBEXEC_DIR/choir"
install -m644 "$SANDBOX_MCP" "$LIBEXEC_DIR/choir_sandbox_mcp.mjs"
install -m644 "$BOXLITE_OWNER" "$LIBEXEC_DIR/choir_boxlite_owner.mjs"
install -m755 "$BOXLITE_BINARY" "$LIBEXEC_DIR/boxlite"
rm -rf "$LIBEXEC_DIR/boxlite-runtime"
cp -a "$BOXLITE_RUNTIME" "$LIBEXEC_DIR/boxlite-runtime"
ln -sfn ../libexec/choir/choir "$BIN_DIR/choir"

echo "installed choir to $PREFIX"
