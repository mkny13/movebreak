#!/bin/bash
#
# Verifies that ARCHITECTURE.md inventories every tracked MoveBreak Swift source
# exactly once. An alternate Markdown file may be supplied for fixture testing.

set -euo pipefail

cd "$(dirname "$0")/.."

ARCHITECTURE_FILE="${1:-ARCHITECTURE.md}"
START_MARKER='<!-- architecture-module-inventory:start -->'
END_MARKER='<!-- architecture-module-inventory:end -->'

if [ ! -f "$ARCHITECTURE_FILE" ]; then
    echo "architecture inventory check failed: $ARCHITECTURE_FILE does not exist" >&2
    exit 1
fi

start_count="$(grep -Fxc "$START_MARKER" "$ARCHITECTURE_FILE" || true)"
end_count="$(grep -Fxc "$END_MARKER" "$ARCHITECTURE_FILE" || true)"

if [ "$start_count" -ne 1 ] || [ "$end_count" -ne 1 ]; then
    echo "architecture inventory check failed: expected exactly one start marker and one end marker in $ARCHITECTURE_FILE" >&2
    echo "  start marker count: $start_count ($START_MARKER)" >&2
    echo "  end marker count:   $end_count ($END_MARKER)" >&2
    exit 1
fi

start_line="$(grep -Fnx "$START_MARKER" "$ARCHITECTURE_FILE" | cut -d: -f1)"
end_line="$(grep -Fnx "$END_MARKER" "$ARCHITECTURE_FILE" | cut -d: -f1)"

if [ "$start_line" -ge "$end_line" ]; then
    echo "architecture inventory check failed: inventory markers are out of order in $ARCHITECTURE_FILE" >&2
    echo "  start marker line: $start_line" >&2
    echo "  end marker line:   $end_line" >&2
    exit 1
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/movebreak-architecture-check.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

expected="$temporary_directory/expected"
documented="$temporary_directory/documented"
documented_unique="$temporary_directory/documented-unique"
duplicates="$temporary_directory/duplicates"
missing="$temporary_directory/missing"
stale="$temporary_directory/stale"

LC_ALL=C git ls-files 'Sources/MoveBreak/*.swift' | LC_ALL=C sort > "$expected"
sed -n "$((start_line + 1)),$((end_line - 1))p" "$ARCHITECTURE_FILE" \
    | sed -n 's@.*](\(Sources/MoveBreak/[^)]*\.swift\)).*@\1@p' \
    | LC_ALL=C sort > "$documented"

LC_ALL=C uniq -d "$documented" > "$duplicates"
LC_ALL=C uniq "$documented" > "$documented_unique"
LC_ALL=C comm -23 "$expected" "$documented_unique" > "$missing"
LC_ALL=C comm -13 "$expected" "$documented_unique" > "$stale"

failed=0

if [ -s "$duplicates" ]; then
    echo "architecture inventory check failed: duplicate entries in $ARCHITECTURE_FILE:" >&2
    sed 's/^/  /' "$duplicates" >&2
    failed=1
fi

if [ -s "$missing" ]; then
    echo "architecture inventory check failed: tracked Swift sources missing from $ARCHITECTURE_FILE:" >&2
    sed 's/^/  /' "$missing" >&2
    failed=1
fi

if [ -s "$stale" ]; then
    echo "architecture inventory check failed: stale Swift source entries in $ARCHITECTURE_FILE:" >&2
    sed 's/^/  /' "$stale" >&2
    failed=1
fi

if [ "$failed" -ne 0 ]; then
    echo "Update the marked module inventory in ARCHITECTURE.md so each tracked Swift source appears exactly once." >&2
    exit 1
fi

echo "Architecture module inventory matches tracked Swift sources."
