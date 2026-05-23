#!/usr/bin/env sh
set -eu

forbid_pattern='^[[:space:]]*(pub[[:space:]]+)?impl[[:space:]].*[[:space:]]with[[:space:]]+fn[[:space:]]'
trait_fn_pattern='^[[:space:]]*fn[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\\('
trait_start_pattern='^[[:space:]]*(pub[[:space:]]+)?trait[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*'

tmp_files="$(mktemp)"
trap 'rm -f "$tmp_files"' EXIT

if [ "$#" -gt 0 ]; then
  for f in "$@"; do
    echo "$f" >> "$tmp_files"
  done
else
for d in src hooks tests; do
  if [ -d "$d" ]; then
      find "$d" -type f -name '*.mbt' ! -path '*/fixtures/canary/*' >> "$tmp_files" 2>/dev/null
  fi
done
fi

status=0

while IFS= read -r file; do
  [ -z "$file" ] && continue
  [ -f "$file" ] || continue

  if grep -nH -E "$forbid_pattern" "$file"; then
    status=1
  fi

  if awk -v file="$file" -v trait_fn_pattern="$trait_fn_pattern" -v trait_start_pattern="$trait_start_pattern" '
      function count_char(text, ch, i, c, n) {
        n = 0
        for (i = 1; i <= length(text); i++) {
          c = substr(text, i, 1)
          if (c == ch) {
            n++
          }
        }
        return n
      }
      BEGIN {
        in_trait = 0
        trait_depth = 0
        has_match = 0
      }
      {
        line = $0

        if (in_trait && line ~ trait_fn_pattern) {
          print file ":" NR ":" line
          has_match = 1
        }

        if (!in_trait && line ~ trait_start_pattern) {
          in_trait = 1
        }

        if (in_trait) {
          opens = count_char(line, "{")
          closes = count_char(line, "}")
          trait_depth = trait_depth + opens - closes
          if (trait_depth <= 0) {
            in_trait = 0
            trait_depth = 0
          }
        }
      }
      END {
        if (has_match) {
          exit 1
        }
      }' "$file"; then
    :
  else
    if [ $? -ne 0 ]; then
      status=1
    fi
  fi
done < "$tmp_files"

exit "$status"
