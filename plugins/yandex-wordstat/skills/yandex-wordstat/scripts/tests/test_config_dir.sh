#!/bin/sh
# Test config directory selection (skill config/ vs ~/.config/yandex-wordstat
# vs YANDEX_WORDSTAT_CONFIG_DIR) and Api-Key detection. No network.

set -e

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
ROOT="${TMPDIR:-/tmp}/wordstat_cfgdir_test_$$"

cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT INT TERM

# Print "<config dir>|<backend>|<api key>|<sa key path>" or "DIE".
# Args: label, setup function name, optional YANDEX_WORDSTAT_CONFIG_DIR value
probe() {
    _label="$1"; _setup="$2"; _override_dir="$3"
    _td="$ROOT/$_label"
    rm -rf "$_td"
    mkdir -p "$_td/skill/config" "$_td/skill/scripts" "$_td/skill/cache" "$_td/home"
    "$_setup" "$_td"
    (
        HOME="$_td/home"
        unset XDG_CONFIG_HOME YANDEX_WORDSTAT_BACKEND YANDEX_WORDSTAT_TOKEN \
              YANDEX_CLOUD_API_KEY WORDSTAT_CONFIG_DIR 2>/dev/null || true
        if [ -n "$_override_dir" ]; then
            YANDEX_WORDSTAT_CONFIG_DIR="$_override_dir"
            export YANDEX_WORDSTAT_CONFIG_DIR
        else
            unset YANDEX_WORDSTAT_CONFIG_DIR 2>/dev/null || true
        fi
        WORDSTAT_SCRIPT_DIR="$_td/skill/scripts"
        WORDSTAT_SKILL_DIR="$_td/skill"
        WORDSTAT_CACHE_DIR="$_td/skill/cache"
        export HOME WORDSTAT_SCRIPT_DIR WORDSTAT_SKILL_DIR WORDSTAT_CACHE_DIR
        # shellcheck disable=SC1091
        . "$SCRIPTS_DIR/common.sh"
        if ( load_config ) >/dev/null 2>&1; then
            load_config 2>/dev/null
            printf '%s|%s|%s|%s\n' "$WORDSTAT_CONFIG_DIR" "$WORDSTAT_BACKEND" \
                "${WORDSTAT_CLOUD_API_KEY:-}" "${WORDSTAT_CLOUD_SA_KEY_PATH:-}"
        else
            printf 'DIE|%s\n' "$WORDSTAT_CONFIG_DIR"
        fi
    )
}

check() {
    _label="$1"; _got="$2"; _want="$3"
    if [ "$_got" = "$_want" ]; then
        echo "  ok: $_label"
    else
        echo "  FAIL: $_label"
        echo "    want: $_want"
        echo "    got:  $_got"
        exit 1
    fi
}

APIKEY_JSON='{"yandex_cloud_folder_id":"b1g-test","auth":{"api_key":"TEST-KEY-1234"}}'

# 1. Config in ~/.config/yandex-wordstat (persistent location), skill config/ empty
setup_user_dir() {
    mkdir -p "$1/home/.config/yandex-wordstat"
    printf '%s\n' "$APIKEY_JSON" > "$1/home/.config/yandex-wordstat/config.json"
}
out=$(probe user_dir setup_user_dir "")
check "~/.config/yandex-wordstat is used when skill config/ is empty" \
    "$out" "$ROOT/user_dir/home/.config/yandex-wordstat|cloud|TEST-KEY-1234|"

# 2. Skill config/ has config.json → it wins over ~/.config (backward compatible)
setup_both_dirs() {
    setup_user_dir "$1"
    printf '%s\n' '{"yandex_cloud_folder_id":"b1g-skill","auth":{"api_key":"SKILL-KEY"}}' \
        > "$1/skill/config/config.json"
}
out=$(probe both_dirs setup_both_dirs "")
check "skill config/ with config.json wins" \
    "$out" "$ROOT/both_dirs/skill/config|cloud|SKILL-KEY|"

# 3. Explicit YANDEX_WORDSTAT_CONFIG_DIR wins over both
setup_custom_dir() {
    setup_both_dirs "$1"
    mkdir -p "$1/custom"
    printf '%s\n' '{"yandex_cloud_folder_id":"b1g-custom","auth":{"api_key":"CUSTOM-KEY"}}' \
        > "$1/custom/config.json"
}
out=$(probe custom_dir setup_custom_dir "$ROOT/custom_dir/custom")
check "YANDEX_WORDSTAT_CONFIG_DIR override wins" \
    "$out" "$ROOT/custom_dir/custom|cloud|CUSTOM-KEY|"

# 4. Service-account key next to config.json in ~/.config resolves by bare name
setup_user_sa() {
    mkdir -p "$1/home/.config/yandex-wordstat"
    printf '%s\n' '{"yandex_cloud_folder_id":"b1g-test","auth":{"service_account_key_file":"service_account_key.json"}}' \
        > "$1/home/.config/yandex-wordstat/config.json"
    : > "$1/home/.config/yandex-wordstat/service_account_key.json"
}
out=$(probe user_sa setup_user_sa "")
check "SA key file resolves relative to config dir" \
    "$out" "$ROOT/user_sa/home/.config/yandex-wordstat|cloud||$ROOT/user_sa/home/.config/yandex-wordstat/service_account_key.json"

# 5. Nothing anywhere → DIE, error points at skill config/
setup_nothing() { :; }
out=$(probe nothing setup_nothing "")
check "no config anywhere → DIE" "$out" "DIE|$ROOT/nothing/skill/config"

# 6. Api key from YANDEX_CLOUD_API_KEY in .env inside ~/.config/yandex-wordstat
setup_env_key() {
    mkdir -p "$1/home/.config/yandex-wordstat"
    printf '%s\n' '{"yandex_cloud_folder_id":"b1g-test","auth":{}}' \
        > "$1/home/.config/yandex-wordstat/config.json"
    printf '%s\n' 'YANDEX_CLOUD_API_KEY=ENV-KEY-5678' > "$1/home/.config/yandex-wordstat/.env"
}
out=$(probe env_key setup_env_key "")
check "api key from .env in config dir" \
    "$out" "$ROOT/env_key/home/.config/yandex-wordstat|cloud|ENV-KEY-5678|"

echo "test_config_dir: all passed"
