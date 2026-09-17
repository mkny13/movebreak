#!/bin/bash
#
# Keeps automatically loaded repository agent context canonical and bounded.
# Alternate paths and limits support isolated failure-fixture testing.

set -euo pipefail

cd "$(dirname "$0")/.."

AGENTS_FILE="AGENTS.md"
CLAUDE_FILE="CLAUDE.md"
DESIGN_FILE=""
MAX_BYTES="4096"

usage() {
    cat <<'EOF'
Usage: scripts/check_agent_context.sh [options]

Options:
  --agents PATH      Agent instruction file (default: AGENTS.md)
  --claude PATH      Claude pointer file (default: CLAUDE.md)
  --design PATH      Supplied design-document path to reject if it exists
  --max-bytes COUNT  Maximum AGENTS file size in bytes (default: 4096)
  -h, --help         Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --agents|--claude|--design|--max-bytes)
            if [ "$#" -lt 2 ]; then
                echo "agent context check failed: $1 requires a value" >&2
                usage >&2
                exit 2
            fi
            case "$1" in
                --agents) AGENTS_FILE="$2" ;;
                --claude) CLAUDE_FILE="$2" ;;
                --design) DESIGN_FILE="$2" ;;
                --max-bytes) MAX_BYTES="$2" ;;
            esac
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "agent context check failed: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$MAX_BYTES" in
    ''|*[!0-9]*|0)
        echo "agent context check failed: --max-bytes must be a positive integer" >&2
        exit 2
        ;;
esac

failed=0

if [ ! -f "$AGENTS_FILE" ]; then
    echo "agent context check failed: $AGENTS_FILE does not exist" >&2
    failed=1
else
    agents_bytes="$(wc -c < "$AGENTS_FILE" | tr -d '[:space:]')"
    if [ "$agents_bytes" -gt "$MAX_BYTES" ]; then
        echo "agent context check failed: $AGENTS_FILE is $agents_bytes bytes; the limit is $MAX_BYTES bytes" >&2
        echo "  Move user guidance to README.md, runtime decisions to ARCHITECTURE.md, and future plans to ROADMAP.md." >&2
        failed=1
    fi
fi

if [ ! -f "$CLAUDE_FILE" ]; then
    echo "agent context check failed: $CLAUDE_FILE does not exist" >&2
    failed=1
else
    expected_pointer="$(mktemp "${TMPDIR:-/tmp}/movebreak-claude-pointer.XXXXXX")"
    trap 'rm -f "$expected_pointer"' EXIT
    printf '@AGENTS.md\n' > "$expected_pointer"
    if ! cmp -s "$expected_pointer" "$CLAUDE_FILE"; then
        echo "agent context check failed: $CLAUDE_FILE must contain exactly one line: @AGENTS.md" >&2
        echo "  Keep repository instructions in AGENTS.md instead of duplicating them in $CLAUDE_FILE." >&2
        failed=1
    fi
fi

if [ -n "$DESIGN_FILE" ]; then
    if [ -e "$DESIGN_FILE" ]; then
        echo "agent context check failed: design document found at $DESIGN_FILE" >&2
        echo "  Put durable decisions in ARCHITECTURE.md and future plans in ROADMAP.md; do not add DESIGN.md." >&2
        failed=1
    fi
elif git ls-files --error-unmatch -- DESIGN.md >/dev/null 2>&1; then
    echo "agent context check failed: tracked DESIGN.md is not allowed" >&2
    echo "  Put durable decisions in ARCHITECTURE.md and future plans in ROADMAP.md; do not add DESIGN.md." >&2
    failed=1
fi

if [ "$failed" -ne 0 ]; then
    exit 1
fi

echo "Agent context is canonical and within the $MAX_BYTES-byte limit."
