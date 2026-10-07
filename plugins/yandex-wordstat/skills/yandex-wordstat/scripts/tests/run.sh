#!/bin/sh
# Test runner for wordstat skill — POSIX sh, no network.
# Each test runs under $TEST_SHELL (default: sh). Run under both shells:
#   sh tests/run.sh && TEST_SHELL=bash sh tests/run.sh

set -e

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_SHELL="${TEST_SHELL:-sh}"
echo "Shell: $TEST_SHELL"

PASS=0
FAIL=0
FAILED_TESTS=""

for t in "$TESTS_DIR"/test_*.sh; do
    [ -f "$t" ] || continue
    name=$(basename "$t" .sh)
    printf '%s ... ' "$name"
    if "$TEST_SHELL" "$t" >/dev/null 2>&1; then
        printf 'PASS\n'
        PASS=$((PASS + 1))
    else
        printf 'FAIL\n'
        FAIL=$((FAIL + 1))
        FAILED_TESTS="$FAILED_TESTS $name"
        # Re-run with output for diagnosis
        echo "--- output of $name ---"
        "$TEST_SHELL" "$t" 2>&1 || true
        echo "--- end ---"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed: $FAILED_TESTS"
    exit 1
fi
exit 0
