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
import pathlib
import re

text = pathlib.Path("moon.mod").read_text(encoding="utf-8")
match = re.search(
    r'(?m)^[ \t]*version[ \t]*=[ \t]*"([^\n"]+)"(?:[ \t]*(?://.*)?)?$',
    text,
)
if not match:
    raise SystemExit('moon.mod is missing a version = "..." line')
print(match.group(1))
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
import pathlib
import re
import sys

version = sys.argv[1]
path = pathlib.Path("moon.mod")
text = path.read_text(encoding="utf-8")
updated, count = re.subn(
    r'(?m)^([ \t]*version[ \t]*=[ \t]*")[^\n"]*(")([ \t]*(?://.*)?)?$',
    rf'\g<1>{version}\g<2>\g<3>',
    text,
    count=1,
)
if count != 1:
    raise SystemExit('moon.mod is missing a version = "..." line')
path.write_text(updated, encoding="utf-8")
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

git add moon.mod CHANGELOG.md
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
