#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release.sh [major|minor|patch|VERSION] [--no-push]

Examples:
  scripts/release.sh patch
  scripts/release.sh 0.2.0
  scripts/release.sh minor --no-push
EOF
}

bump_part="${1:-patch}"
push_changes=1

for arg in "$@"; do
  case "$arg" in
    --no-push)
      push_changes=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
  esac
done

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "working tree must be clean before cutting a release" >&2
  exit 1
fi

current_version="$(
  python3 - <<'PY'
import json
with open("moon.mod.json", "r", encoding="utf-8") as f:
    print(json.load(f)["version"])
PY
)"

next_version="$(
  python3 - "$current_version" "$bump_part" <<'PY'
import re
import sys

current = sys.argv[1]
requested = sys.argv[2]
m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", current)
if not m:
    raise SystemExit(f"invalid current version: {current}")
major, minor, patch = map(int, m.groups())

if requested == "major":
    major += 1
    minor = 0
    patch = 0
    print(f"{major}.{minor}.{patch}")
elif requested == "minor":
    minor += 1
    patch = 0
    print(f"{major}.{minor}.{patch}")
elif requested == "patch":
    patch += 1
    print(f"{major}.{minor}.{patch}")
elif re.fullmatch(r"\d+\.\d+\.\d+", requested):
    print(requested)
else:
    raise SystemExit(f"invalid release target: {requested}")
PY
)"

release_date="$(date -u +%F)"

python3 - "$next_version" <<'PY'
import json
import sys

version = sys.argv[1]
with open("moon.mod.json", "r", encoding="utf-8") as f:
    data = json.load(f)
data["version"] = version
with open("moon.mod.json", "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

python3 - "$next_version" "$release_date" <<'PY'
import pathlib
import sys

version = sys.argv[1]
release_date = sys.argv[2]
path = pathlib.Path("CHANGELOG.md")
text = path.read_text(encoding="utf-8")
needle = "## Unreleased\n"
entry = f"## Unreleased\n\n## {version} - {release_date}\n\n- Release cut.\n"
if needle not in text:
    raise SystemExit("CHANGELOG.md is missing '## Unreleased'")
path.write_text(text.replace(needle, entry, 1), encoding="utf-8")
PY

git add moon.mod.json CHANGELOG.md
git commit -m "release: v${next_version}"
git tag -a "v${next_version}" -m "v${next_version}"

if [ "$push_changes" -eq 1 ]; then
  git push
  git push origin "v${next_version}"
else
  echo "created commit and tag locally:"
  echo "  release: v${next_version}"
  echo "  v${next_version}"
fi
