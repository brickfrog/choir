#!/usr/bin/env bash
set -euo pipefail

echo "→ moon test --target native --release"
moon test --target native --release \
  -p choir/src/config \
  -p choir/src/hooks \
  -p choir/src/io \
  -p choir/src/mcp \
  -p choir/src/message \
  -p choir/src/poller \
  -p choir/src/registry \
  -p choir/src/server \
  -p choir/src/tools \
  -p choir/src/transport \
  -p choir/src/workspace

