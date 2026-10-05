#!/bin/sh
# Test that _xlate_request correctly transforms legacy params to cloud body.

set -e

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SKILL_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

WORDSTAT_SCRIPT_DIR="$SCRIPTS_DIR"
WORDSTAT_SKILL_DIR="$SKILL_DIR"
export WORDSTAT_SCRIPT_DIR WORDSTAT_SKILL_DIR
# shellcheck disable=SC1091
. "$SCRIPTS_DIR/common.sh"

# Set folder id for translation injection
WORDSTAT_CLOUD_FOLDER_ID="b1g-test-folder"

json_eq() {
    _a="$1"; _b="$2"
    _A="$_a" _B="$_b" python3 -c "
import json, os, sys
a = json.loads(os.environ['_A'])
b = json.loads(os.environ['_B'])
if a == b:
    sys.exit(0)
print(f'NEQ: actual={json.dumps(a, ensure_ascii=False)} expected={json.dumps(b, ensure_ascii=False)}')
sys.exit(1)
"
}

run_translate_test() {
    _method="$1"
    _params=$(cat "$FIXTURES/legacy-${_method}-params.json")
    _expected=$(cat "$FIXTURES/cloud-${_method}-request-expected.json")

    actual=$(_xlate_request "$_method" "$_params")
    if json_eq "$actual" "$_expected"; then
        echo "  ok: translate $_method"
    else
        echo "  FAIL: translate $_method"
        echo "    actual:   $actual"
        echo "    expected: $_expected"
        return 1
    fi
}

run_translate_test topRequests
run_translate_test dynamics
run_translate_test regions

echo "test_translate: all passed"
