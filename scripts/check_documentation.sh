#!/bin/bash
#
# Checks canonical Markdown links and keeps README CLI documentation aligned
# with the public long options emitted by the built MoveBreak executable.

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="$REPOSITORY_ROOT/scripts/check_documentation.sh"

usage() {
    cat <<'EOF'
Usage: scripts/check_documentation.sh EXECUTABLE [options]
       scripts/check_documentation.sh --self-test

Options:
  --readme PATH       README used for links and CLI coverage (default: README.md)
  --architecture PATH Architecture document (default: ARCHITECTURE.md)
  --roadmap PATH      Roadmap document (default: ROADMAP.md)
  --agents PATH       Agent instructions (default: AGENTS.md)
  --self-test         Run deterministic success and failure fixtures
  -h, --help          Show this help
EOF
}

fail() {
    echo "documentation check failed: $*" >&2
    exit 1
}

run_self_test() {
    fixture_directory="$(mktemp -d "${TMPDIR:-/tmp}/movebreak-documentation-check.XXXXXX")"
    trap 'rm -rf "$fixture_directory"' EXIT

    mkdir -p "$fixture_directory/docs"
    printf '# Target\n' > "$fixture_directory/docs/target.md"
    printf '# Architecture\n' > "$fixture_directory/ARCHITECTURE.md"
    printf '# Roadmap\n' > "$fixture_directory/ROADMAP.md"
    printf '# Agents\n' > "$fixture_directory/AGENTS.md"
    printf '# README\n\n[Target](docs/target.md#section)\n\n`--help`\n`--status`\n' \
        > "$fixture_directory/README.md"
    cat > "$fixture_directory/movebreak" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--help" ]; then
    printf '  --help    Show help.\n  --status  Show status.\n'
fi
EOF
    chmod +x "$fixture_directory/movebreak"

    run_fixture() {
        "$SCRIPT_PATH" "$fixture_directory/movebreak" \
            --readme "$fixture_directory/README.md" \
            --architecture "$fixture_directory/ARCHITECTURE.md" \
            --roadmap "$fixture_directory/ROADMAP.md" \
            --agents "$fixture_directory/AGENTS.md"
    }

    run_fixture > /dev/null || fail "self-test success fixture did not pass"

    printf '# README\n\n[Missing](docs/missing.md)\n\n`--help`\n`--status`\n' \
        > "$fixture_directory/README.md"
    if run_fixture > "$fixture_directory/output" 2>&1; then
        fail "self-test broken-link fixture unexpectedly passed"
    fi
    grep -F "$fixture_directory/README.md: broken local link target: docs/missing.md" \
        "$fixture_directory/output" > /dev/null \
        || fail "self-test broken-link fixture did not produce an actionable error"

    printf '# README\n\n[Target](docs/target.md)\n\n`--help`\n' > "$fixture_directory/README.md"
    if run_fixture > "$fixture_directory/output" 2>&1; then
        fail "self-test missing-command fixture unexpectedly passed"
    fi
    grep -F 'public options missing from ' "$fixture_directory/output" > /dev/null \
        || fail "self-test missing-command fixture did not report CLI coverage"
    grep -Fx '  --status' "$fixture_directory/output" > /dev/null \
        || fail "self-test missing-command fixture did not identify --status"

    if "$SCRIPT_PATH" "$fixture_directory/missing" > "$fixture_directory/output" 2>&1; then
        fail "self-test missing-binary fixture unexpectedly passed"
    fi
    grep -F 'executable does not exist' "$fixture_directory/output" > /dev/null \
        || fail "self-test missing-binary fixture produced the wrong error"

    printf '#!/bin/bash\n' > "$fixture_directory/not-executable"
    chmod -x "$fixture_directory/not-executable"
    if "$SCRIPT_PATH" "$fixture_directory/not-executable" > "$fixture_directory/output" 2>&1; then
        fail "self-test unexecutable-binary fixture unexpectedly passed"
    fi
    grep -F 'is not executable' "$fixture_directory/output" > /dev/null \
        || fail "self-test unexecutable-binary fixture produced the wrong error"

    echo "Documentation check fixtures passed."
}

if [ "${1:-}" = "--self-test" ]; then
    if [ "$#" -ne 1 ]; then
        echo "documentation check failed: --self-test does not accept other arguments" >&2
        usage >&2
        exit 2
    fi
    run_self_test
    exit 0
fi

if [ "$#" -eq 0 ]; then
    echo "documentation check failed: an executable argument is required" >&2
    usage >&2
    exit 2
fi

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
fi

EXECUTABLE="$1"
shift
README_FILE="README.md"
ARCHITECTURE_FILE="ARCHITECTURE.md"
ROADMAP_FILE="ROADMAP.md"
AGENTS_FILE="AGENTS.md"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --readme|--architecture|--roadmap|--agents)
            if [ "$#" -lt 2 ]; then
                echo "documentation check failed: $1 requires a path" >&2
                usage >&2
                exit 2
            fi
            case "$1" in
                --readme) README_FILE="$2" ;;
                --architecture) ARCHITECTURE_FILE="$2" ;;
                --roadmap) ROADMAP_FILE="$2" ;;
                --agents) AGENTS_FILE="$2" ;;
            esac
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "documentation check failed: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

cd "$REPOSITORY_ROOT"

if [ ! -e "$EXECUTABLE" ]; then
    fail "executable does not exist: $EXECUTABLE"
fi
if [ ! -f "$EXECUTABLE" ] || [ ! -x "$EXECUTABLE" ]; then
    fail "MoveBreak path is not executable: $EXECUTABLE"
fi

documents=("$README_FILE" "$ARCHITECTURE_FILE" "$ROADMAP_FILE" "$AGENTS_FILE")
for document in "${documents[@]}"; do
    if [ ! -f "$document" ]; then
        fail "documentation input does not exist: $document"
    fi
done

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/movebreak-documentation-check.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT
links_file="$temporary_directory/links"
missing_options="$temporary_directory/missing-options"
failed=0

for document in "${documents[@]}"; do
    # Images are intentionally outside this check. Extract ordinary inline Markdown links;
    # canonical docs use this form for local references.
    sed -E 's/!\[[^]]*\]\([^)]*\)//g' "$document" \
        | grep -Eo '\[[^][]+\]\([^)]*\)' \
        | sed -E 's/^[^(]*\((.*)\)$/\1/' > "$links_file" || true

    while IFS= read -r raw_target; do
        target="$raw_target"
        case "$target" in
            \<*\>) target="${target#<}"; target="${target%>}" ;;
        esac
        case "$target" in
            ''|\#*|http://*|https://*|mailto:*|data:*) continue ;;
        esac

        # Fragments and queries do not affect whether the local filesystem target exists.
        filesystem_target="${target%%#*}"
        filesystem_target="${filesystem_target%%\?*}"
        if [ -z "$filesystem_target" ]; then
            continue
        fi
        document_directory="$(dirname "$document")"
        if [ ! -e "$document_directory/$filesystem_target" ]; then
            echo "documentation check failed: $document: broken local link target: $raw_target" >&2
            failed=1
        fi
    done < "$links_file"
done

if ! help_output="$("$EXECUTABLE" --help 2>&1)"; then
    echo "documentation check failed: could not capture --help from $EXECUTABLE" >&2
    failed=1
    help_output=""
fi

printf '%s\n' "$help_output" \
    | grep -Eo -- '--[a-z][a-z0-9-]*' \
    | LC_ALL=C sort -u \
    | while IFS= read -r option; do
        if ! grep -F -- "$option" "$README_FILE" > /dev/null; then
            printf '%s\n' "$option"
        fi
    done > "$missing_options" || true

if [ -s "$missing_options" ]; then
    echo "documentation check failed: public options missing from $README_FILE:" >&2
    sed 's/^/  /' "$missing_options" >&2
    failed=1
fi

if [ "$failed" -ne 0 ]; then
    exit 1
fi

echo "Documentation links and public CLI coverage are current."
