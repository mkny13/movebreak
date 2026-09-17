#!/bin/bash
# Repeat the already-built offline self-test and check its inventory, diagnostics, and timing.

set -euo pipefail

cd "$(dirname "$0")/.."

RUNS="${MOVEBREAK_HEALTH_RUNS:-5}"
TIMEOUT_SECONDS="${MOVEBREAK_HEALTH_TIMEOUT_SECONDS:-120}"
MAX_SLOWDOWN="${MOVEBREAK_HEALTH_MAX_SLOWDOWN:-3}"
GRACE_SECONDS="${MOVEBREAK_HEALTH_GRACE_SECONDS:-5}"
MAX_SECONDS="${MOVEBREAK_HEALTH_MAX_SECONDS:-}"
EXECUTABLE="${MOVEBREAK_HEALTH_EXECUTABLE:-./build/MoveBreak}"
EXPECTED_SUITES="${MOVEBREAK_HEALTH_EXPECTED_SUITES:-detection security persistence update}"

usage() {
    cat <<'EOF'
Usage: ./scripts/test_health.sh [options]

Options:
  --runs N                 Total runs, including the baseline (default: 5)
  --timeout SECONDS        Per-run wall-clock timeout (default: 120)
  --max-slowdown FACTOR    Allowed multiplier over baseline (default: 3)
  --grace-seconds SECONDS  Added to the relative timing limit (default: 5)
  --max-seconds SECONDS    Use an explicit total-time ceiling instead
  --executable PATH        Test an alternate executable (default: ./build/MoveBreak)
  -h, --help               Show this help

The matching MOVEBREAK_HEALTH_* environment variables provide the same overrides.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --runs) RUNS="${2:-}"; shift 2 ;;
        --timeout) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
        --max-slowdown) MAX_SLOWDOWN="${2:-}"; shift 2 ;;
        --grace-seconds) GRACE_SECONDS="${2:-}"; shift 2 ;;
        --max-seconds) MAX_SECONDS="${2:-}"; shift 2 ;;
        --executable) EXECUTABLE="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "test health: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

is_positive_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -gt 0 ] ;;
    esac
}

is_positive_number() {
    awk -v value="$1" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0) }'
}

is_nonnegative_number() {
    awk -v value="$1" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value >= 0) }'
}

if ! is_positive_integer "$RUNS" || [ "$RUNS" -lt 2 ]; then
    echo "test health: --runs must be an integer of at least 2" >&2
    exit 2
fi
if ! is_positive_integer "$TIMEOUT_SECONDS"; then
    echo "test health: --timeout must be a positive integer" >&2
    exit 2
fi
if ! is_positive_number "$MAX_SLOWDOWN" || ! is_nonnegative_number "$GRACE_SECONDS"; then
    echo "test health: slowdown must be positive and grace must be nonnegative" >&2
    exit 2
fi
if [ -n "$MAX_SECONDS" ] && ! is_positive_number "$MAX_SECONDS"; then
    echo "test health: --max-seconds must be a positive number" >&2
    exit 2
fi
if [ ! -x "$EXECUTABLE" ]; then
    echo "test health: executable not found: $EXECUTABLE" >&2
    echo "Build it first with ./scripts/build_app.sh." >&2
    exit 2
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/movebreak-test-health.XXXXXX")
cleanup() {
    case "$WORK_DIR" in
        "${TMPDIR:-/tmp}"/movebreak-test-health.*) rm -rf -- "$WORK_DIR" ;;
    esac
}
trap cleanup EXIT HUP INT TERM

fail_run() {
    run_number="$1"
    message="$2"
    echo "test health: FAIL run $run_number: $message" >&2
    if [ -s "$WORK_DIR/run-$run_number.stderr" ]; then
        echo "--- stderr ---" >&2
        sed -n '1,80p' "$WORK_DIR/run-$run_number.stderr" >&2
    fi
    if [ -s "$WORK_DIR/run-$run_number.stdout" ]; then
        echo "--- last 40 stdout lines ---" >&2
        tail -40 "$WORK_DIR/run-$run_number.stdout" >&2
    fi
    exit 1
}

baseline_inventory=""
baseline_elapsed=""
slowest_run=0
slowest_run_elapsed=0
slowest_suite=""
slowest_suite_elapsed=0

echo "Self-test health: $RUNS runs, ${TIMEOUT_SECONDS}s timeout, executable $EXECUTABLE"

run_number=1
while [ "$run_number" -le "$RUNS" ]; do
    stdout_file="$WORK_DIR/run-$run_number.stdout"
    stderr_file="$WORK_DIR/run-$run_number.stderr"
    timeout_file="$WORK_DIR/run-$run_number.timeout"

    "$EXECUTABLE" --self-test >"$stdout_file" 2>"$stderr_file" &
    test_pid=$!
    (
        sleep "$TIMEOUT_SECONDS"
        if kill -0 "$test_pid" 2>/dev/null; then
            : >"$timeout_file"
            kill -TERM "$test_pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$test_pid" 2>/dev/null || true
        fi
    ) &
    watchdog_pid=$!

    set +e
    wait "$test_pid"
    test_status=$?
    set -e
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    if [ -f "$timeout_file" ]; then
        fail_run "$run_number" "timed out after ${TIMEOUT_SECONDS}s (slow run, not a functional assertion failure)"
    fi
    if [ "$test_status" -ne 0 ]; then
        fail_run "$run_number" "self-test exited nonzero with status $test_status"
    fi
    if [ -s "$stderr_file" ]; then
        fail_run "$run_number" "unexpected stderr/runtime diagnostics"
    fi
    if grep -Eiq '(^|[^[:alpha:]])(warning:|fatal error:|runtime error:|resource warning|leak detected)' "$stdout_file"; then
        fail_run "$run_number" "unexpected warning text in stdout"
    fi

    inventory_file="$WORK_DIR/run-$run_number.inventory"
    sed -n 's/^SUMMARY suite=\([^ ]*\) cases=\([0-9][0-9]*\) failures=\([0-9][0-9]*\) elapsed=\([0-9][0-9.]*\)s$/\1 \2 \3 \4/p' \
        "$stdout_file" >"$inventory_file"
    actual_suites=$(awk '{ suites = suites (NR == 1 ? "" : " ") $1 } END { print suites }' "$inventory_file")
    suite_count=$(awk 'END { print NR + 0 }' "$inventory_file")
    expected_suite_count=$(printf '%s\n' "$EXPECTED_SUITES" | awk '{ print NF }')
    if [ "$actual_suites" != "$EXPECTED_SUITES" ] || [ "$suite_count" -ne "$expected_suite_count" ]; then
        fail_run "$run_number" "suite inventory mismatch (expected: $EXPECTED_SUITES; got: ${actual_suites:-none})"
    fi
    if awk '$3 != 0 { found = 1 } END { exit !found }' "$inventory_file"; then
        fail_run "$run_number" "a suite summary reported failures despite a zero exit status"
    fi

    total_line=$(sed -n 's/^SUMMARY total suites=\([0-9][0-9]*\) cases=\([0-9][0-9]*\) failures=\([0-9][0-9]*\) elapsed=\([0-9][0-9.]*\)s$/\1 \2 \3 \4/p' "$stdout_file")
    total_line_count=$(printf '%s\n' "$total_line" | awk 'NF { count += 1 } END { print count + 0 }')
    if [ "$total_line_count" -ne 1 ]; then
        fail_run "$run_number" "missing or duplicate complete-run summary"
    fi
    total_suites=$(printf '%s\n' "$total_line" | awk '{ print $1 }')
    total_cases=$(printf '%s\n' "$total_line" | awk '{ print $2 }')
    total_failures=$(printf '%s\n' "$total_line" | awk '{ print $3 }')
    total_elapsed=$(printf '%s\n' "$total_line" | awk '{ print $4 }')
    summed_cases=$(awk '{ cases += $2 } END { print cases + 0 }' "$inventory_file")
    if [ "$total_suites" -ne "$suite_count" ] || [ "$total_cases" -ne "$summed_cases" ] || [ "$total_failures" -ne 0 ]; then
        fail_run "$run_number" "complete-run summary does not match suite summaries"
    fi

    inventory=$(awk '{ print $1 " " $2 }' "$inventory_file")
    if [ "$run_number" -eq 1 ]; then
        baseline_inventory="$inventory"
        baseline_elapsed="$total_elapsed"
        if [ -n "$MAX_SECONDS" ]; then
            duration_limit="$MAX_SECONDS"
            limit_description="explicit ${MAX_SECONDS}s ceiling"
        else
            duration_limit=$(awk -v baseline="$baseline_elapsed" -v factor="$MAX_SLOWDOWN" -v grace="$GRACE_SECONDS" \
                'BEGIN { printf "%.3f", baseline * factor + grace }')
            limit_description="${MAX_SLOWDOWN}x baseline + ${GRACE_SECONDS}s grace"
        fi
        echo "  run 1/$RUNS baseline: ${total_cases} cases in ${total_elapsed}s; limit ${duration_limit}s ($limit_description)"
    else
        if [ "$inventory" != "$baseline_inventory" ]; then
            fail_run "$run_number" "suite/case inventory changed from baseline"
        fi
        if awk -v elapsed="$total_elapsed" -v limit="$duration_limit" 'BEGIN { exit !(elapsed > limit) }'; then
            fail_run "$run_number" "duration ${total_elapsed}s exceeded ${duration_limit}s limit ($limit_description)"
        fi
        echo "  run $run_number/$RUNS: ${total_cases} cases in ${total_elapsed}s"
    fi

    if awk -v current="$total_elapsed" -v slowest="$slowest_run_elapsed" 'BEGIN { exit !(current > slowest) }'; then
        slowest_run="$run_number"
        slowest_run_elapsed="$total_elapsed"
    fi
    while read -r suite_name suite_cases suite_failures suite_elapsed; do
        if awk -v current="$suite_elapsed" -v slowest="$slowest_suite_elapsed" 'BEGIN { exit !(current > slowest) }'; then
            slowest_suite="$suite_name (run $run_number)"
            slowest_suite_elapsed="$suite_elapsed"
        fi
    done <"$inventory_file"

    run_number=$((run_number + 1))
done

echo "Self-test health passed: $RUNS/$RUNS runs; stable inventory: $(printf '%s' "$baseline_inventory" | tr '\n' ', ' | sed 's/, $//')"
echo "Slowest run: $slowest_run (${slowest_run_elapsed}s); slowest suite: $slowest_suite (${slowest_suite_elapsed}s)"
