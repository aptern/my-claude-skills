#!/bin/sh
# Test load_config backend selection. Structural-only — no IAM, no network.

set -e

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# Helper: run load_config in a subshell with given setup; capture WORDSTAT_BACKEND.
# Each call uses a fresh transient skill dir under $TMPDIR.
run_selector() {
    _label="$1"; _config_setup="$2"; _override="$3"; _legacy_token="$4"

    _td="${TMPDIR:-/tmp}/wordstat_test_$$_$(printf '%s' "$_label" | tr ' /+' '___')"
    rm -rf "$_td"
    mkdir -p "$_td/config" "$_td/scripts" "$_td/cache"

    case "$_config_setup" in
        legacy_only)
            # No config.json; legacy creds come via env in subshell
            ;;
        cloud_only)
            cat > "$_td/config/config.json" <<EOF
{"yandex_cloud_folder_id":"b1g-test","auth":{"service_account_key_file":"config/sa_key.json"}}
EOF
            : > "$_td/config/sa_key.json"
            ;;
        both)
            cat > "$_td/config/config.json" <<EOF
{"yandex_cloud_folder_id":"b1g-test","auth":{"service_account_key_file":"config/sa_key.json"}}
EOF
            : > "$_td/config/sa_key.json"
            ;;
        malformed_cloud)
            # config.json present but key file missing
            cat > "$_td/config/config.json" <<EOF
{"yandex_cloud_folder_id":"b1g-test","auth":{"service_account_key_file":"config/missing.json"}}
EOF
            ;;
        empty)
            ;;
    esac

    _result=$(
        # Pre-set dir vars so common.sh doesn't try to resolve them via $0
        WORDSTAT_SCRIPT_DIR="$_td/scripts"
        WORDSTAT_SKILL_DIR="$_td"
        WORDSTAT_CONFIG_DIR="$_td/config"
        WORDSTAT_CACHE_DIR="$_td/cache"
        export WORDSTAT_SCRIPT_DIR WORDSTAT_SKILL_DIR WORDSTAT_CONFIG_DIR WORDSTAT_CACHE_DIR

        if [ -n "$_override" ]; then
            export YANDEX_WORDSTAT_BACKEND="$_override"
        else
            unset YANDEX_WORDSTAT_BACKEND 2>/dev/null || true
        fi
        if [ -n "$_legacy_token" ]; then
            export YANDEX_WORDSTAT_TOKEN="$_legacy_token"
        else
            unset YANDEX_WORDSTAT_TOKEN 2>/dev/null || true
        fi

        # shellcheck disable=SC1091
        . "$SCRIPTS_DIR/common.sh"

        # Run load_config in nested subshell so die_with_help's exit stays scoped.
        # Suppress set -e via `if` so we can read the exit code without aborting.
        if ( load_config ) >/dev/null 2>&1; then
            # Re-run in current shell to capture the exported WORDSTAT_BACKEND
            load_config 2>/dev/null
            printf 'BACKEND=%s\n' "$WORDSTAT_BACKEND"
        else
            printf 'DIE\n'
        fi
    )

    rm -rf "$_td"
    printf '%s' "$_result"
}

assert_backend() {
    _label="$1"; _result="$2"; _expected="$3"
    _backend=$(printf '%s' "$_result" | sed -n 's/^BACKEND=//p' | tail -n 1)
    if [ "$_backend" = "$_expected" ]; then
        echo "  ok: $_label → $_expected"
    else
        echo "  FAIL: $_label expected '$_expected' got '$_backend'"
        echo "    full output: $_result"
        exit 1
    fi
}

assert_die() {
    _label="$1"; _result="$2"
    case "$_result" in
        *DIE*) echo "  ok: $_label → DIE (expected)" ;;
        *)     echo "  FAIL: $_label expected DIE got: $_result"; exit 1 ;;
    esac
}

# 1. Legacy only → legacy
out=$(run_selector "legacy_only" "legacy_only" "" "test_token")
assert_backend "legacy only" "$out" "legacy"

# 2. Cloud only → cloud
out=$(run_selector "cloud_only" "cloud_only" "" "")
assert_backend "cloud only" "$out" "cloud"

# 3. Both → cloud (cloud wins on tie)
out=$(run_selector "both" "both" "" "test_token")
assert_backend "both → cloud wins" "$out" "cloud"

# 4. Both + override=legacy → legacy
out=$(run_selector "both_pin_legacy" "both" "legacy" "test_token")
assert_backend "both + override=legacy" "$out" "legacy"

# 5. Cloud only + override=legacy without token → DIE
out=$(run_selector "cloud_pin_legacy_no_token" "cloud_only" "legacy" "")
assert_die "override=legacy without token" "$out"

# 6. Empty → DIE
out=$(run_selector "empty" "empty" "" "")
assert_die "empty config" "$out"

# 7. Malformed cloud (config.json present, key file missing) → DIE
out=$(run_selector "malformed_cloud" "malformed_cloud" "" "")
assert_die "malformed cloud config" "$out"

# 8. Malformed cloud + legacy token → DIE (cloud config error takes precedence)
out=$(run_selector "malformed_cloud_with_legacy" "malformed_cloud" "" "test_token")
assert_die "malformed cloud with legacy token" "$out"

echo "test_selector: all passed"
