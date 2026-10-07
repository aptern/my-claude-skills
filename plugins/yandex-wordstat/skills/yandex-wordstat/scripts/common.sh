#!/bin/sh
# Common functions for Yandex Wordstat skill — dual backend (legacy + cloud)
#
# Public API (sourced by other scripts):
#   load_config            — picks backend, exports WORDSTAT_BACKEND, _DETECTED_VIA, _CLOUD_*
#   wordstat_request M P   — request to Wordstat API, always returns LEGACY-shaped JSON.
#                            Every HTTP attempt (retries included) first takes a slot
#                            from the client-side rate limiter (see "Rate limiter").
#   print_backend_info     — backend-aware diagnostic block (used by quota.sh)
#   print_rate_budget      — hourly request budget from the local counter (no API call)
#   die_with_help MSG      — structured error pointing user at config README
#   json_escape, format_number, json_value, json_string  — legacy helpers (unchanged)
#
# Backend dispatch:
#   - WORDSTAT_BACKEND=legacy → POST api.wordstat.yandex.net/v1/{method} (Bearer OAuth)
#   - WORDSTAT_BACKEND=cloud  → POST searchapi.api.cloud.yandex.net/v2/wordstat/{method}
#                              with IAM Bearer + folderId, response normalized back to legacy
#                              shape so existing parsers in callers don't change.
#
# Selection in load_config is STRUCTURAL ONLY — no network, no IAM preflight.
# IAM/network errors surface on the first wordstat_request call.

# Resolve directories. Use $0 because we're sourced from many shells (sh + bash).
# Tests can pre-set WORDSTAT_SCRIPT_DIR / WORDSTAT_SKILL_DIR / WORDSTAT_CONFIG_DIR
# to override the auto-resolution (POSIX sh has no portable way to get the path
# of a sourced script when $0 isn't reliable).
if [ -z "${WORDSTAT_SCRIPT_DIR:-}" ]; then
    WORDSTAT_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
if [ -z "${WORDSTAT_SKILL_DIR:-}" ]; then
    WORDSTAT_SKILL_DIR="$(cd "$WORDSTAT_SCRIPT_DIR/.." && pwd)"
fi

# Config directory. Order:
#   1. WORDSTAT_CONFIG_DIR            — preset by tests (internal override)
#   2. YANDEX_WORDSTAT_CONFIG_DIR     — user override
#   3. <skill>/config/                — if it already holds config.json or .env
#                                       (manual install, existing setups)
#   4. ~/.config/yandex-wordstat/     — if the directory exists. Survives plugin
#                                       updates: a plugin installed via /plugin
#                                       lives in a versioned cache directory that
#                                       is replaced on every update.
#   5. <skill>/config/                — default (error messages point here)
if [ -z "${WORDSTAT_CONFIG_DIR:-}" ]; then
    _ws_user_cfg="${YANDEX_WORDSTAT_CONFIG_DIR:-}"
    if [ -n "$_ws_user_cfg" ]; then
        WORDSTAT_CONFIG_DIR="$_ws_user_cfg"
    elif [ -f "$WORDSTAT_SKILL_DIR/config/config.json" ] || [ -f "$WORDSTAT_SKILL_DIR/config/.env" ]; then
        WORDSTAT_CONFIG_DIR="$WORDSTAT_SKILL_DIR/config"
    elif [ -n "${HOME:-}${XDG_CONFIG_HOME:-}" ] && [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/yandex-wordstat" ]; then
        WORDSTAT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/yandex-wordstat"
    else
        WORDSTAT_CONFIG_DIR="$WORDSTAT_SKILL_DIR/config"
    fi
    unset _ws_user_cfg
fi
WORDSTAT_CACHE_DIR="${WORDSTAT_CACHE_DIR:-$WORDSTAT_SKILL_DIR/cache}"

WORDSTAT_LEGACY_API="https://api.wordstat.yandex.net/v1"
WORDSTAT_CLOUD_API="https://searchapi.api.cloud.yandex.net/v2/wordstat"
WORDSTAT_IAM_API="https://iam.api.cloud.yandex.net/iam/v1/tokens"
WORDSTAT_README_URL="https://github.com/aptern/my-claude-skills/blob/main/plugins/yandex-wordstat/README.md"

# Exported by load_config so callers and die_with_help can read them
WORDSTAT_BACKEND=""
WORDSTAT_BACKEND_DETECTED_VIA=""
WORDSTAT_CLOUD_FOLDER_ID=""
WORDSTAT_CLOUD_SA_KEY_PATH=""
WORDSTAT_CLOUD_OPENSSL_BIN=""

# ---------------------------------------------------------------------
# Error helper
# ---------------------------------------------------------------------

die_with_help() {
    _msg="$1"
    _extra="${2:-}"

    {
        printf '[wordstat] %s\n' "$_msg"
        if [ -n "$WORDSTAT_BACKEND" ]; then
            printf 'Backend: %s' "$WORDSTAT_BACKEND"
            [ -n "$WORDSTAT_BACKEND_DETECTED_VIA" ] && \
                printf ' (%s)' "$WORDSTAT_BACKEND_DETECTED_VIA"
            printf '\n'
        fi
        [ -n "$_extra" ] && printf '%s\n' "$_extra"
        printf '\n'
        printf 'Likely the plugin config needs updating. See:\n'
        printf '  %s\n\n' "$WORDSTAT_README_URL"
        printf 'Config dir in use: %s\n' "$WORDSTAT_CONFIG_DIR"
        printf '  (override: YANDEX_WORDSTAT_CONFIG_DIR; persistent default: ~/.config/yandex-wordstat/)\n\n'
        printf 'Quick checks:\n'
        printf '  - cloud mode:  config.json has yandex_cloud_folder_id and auth.api_key (or auth.service_account_key_file)?\n'
        if [ -n "$WORDSTAT_CLOUD_SA_KEY_PATH" ]; then
            printf '                 SA key file: %s\n' "$WORDSTAT_CLOUD_SA_KEY_PATH"
            printf '                 (resolved from auth.service_account_key_file) — present and readable?\n'
        else
            printf '                 SA key file from auth.service_account_key_file — present and readable?\n'
        fi
        printf "                 SA has role 'search-api.webSearch.user'?\n"
        printf '  - legacy mode: YANDEX_WORDSTAT_TOKEN still valid? (tokens expire after 1 year)\n'
        printf '  - to switch:   set YANDEX_WORDSTAT_BACKEND=legacy|cloud in config/.env\n'
    } >&2
    exit 1
}

# ---------------------------------------------------------------------
# Legacy helpers (kept for compatibility with bash callers)
# ---------------------------------------------------------------------

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

format_number() {
    printf "%'d" "$1" 2>/dev/null || echo "$1"
}

# Extract a numeric/literal JSON value (no string quoting)
json_value() {
    _jv_json="$1"; _jv_key="$2"
    printf '%s' "$_jv_json" | grep -o "\"$_jv_key\":[^,}]*" | head -1 | sed 's/.*://' | tr -d '"[:space:]'
}

# Extract a JSON string value
json_string() {
    _js_json="$1"; _js_key="$2"
    printf '%s' "$_js_json" | grep -o "\"$_js_key\":\"[^\"]*\"" | head -1 | sed 's/.*:"//' | tr -d '"'
}

# ---------------------------------------------------------------------
# Backend selection — load_config
# ---------------------------------------------------------------------

# Read .env if present (legacy creds + override). Sourced into current shell.
# Rate-limiter settings already set in the process environment win over .env, so
# a one-off `YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=50 sh scripts/...` is honoured
# even when .env holds 2000. Order: environment > .env > config.json > default.
_load_env_file() {
    _env_file="$WORDSTAT_CONFIG_DIR/.env"
    if [ -f "$_env_file" ]; then
        _le_h=${YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR:-__ws_unset__}
        _le_s=${YANDEX_WORDSTAT_RATE_LIMIT_PER_SECOND:-__ws_unset__}
        _le_w=${YANDEX_WORDSTAT_RATE_MAX_WAIT:-__ws_unset__}
        _le_d=${YANDEX_WORDSTAT_STATE_DIR:-__ws_unset__}
        # shellcheck disable=SC1090
        . "$_env_file"
        if [ "$_le_h" = __ws_unset__ ]; then
            [ -z "${YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR:-}" ] || _ws_rl_hour_from_dotenv=1
        else
            YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=$_le_h
        fi
        [ "$_le_s" = __ws_unset__ ] || YANDEX_WORDSTAT_RATE_LIMIT_PER_SECOND=$_le_s
        [ "$_le_w" = __ws_unset__ ] || YANDEX_WORDSTAT_RATE_MAX_WAIT=$_le_w
        [ "$_le_d" = __ws_unset__ ] || YANDEX_WORDSTAT_STATE_DIR=$_le_d
    fi
}

# Read a value from config.json. Usage: _cfg_get "key" or "auth.openssl_bin"
# Returns empty string on missing key, missing file, or parse error.
_cfg_get() {
    _cfg_file="$WORDSTAT_CONFIG_DIR/config.json"
    [ -f "$_cfg_file" ] || { echo ""; return 0; }
    _CFG_FILE="$_cfg_file" _CFG_KEY="$1" python3 - <<'PYEOF' 2>/dev/null
import json, os, sys
try:
    with open(os.environ["_CFG_FILE"]) as f:
        cfg = json.load(f)
except Exception:
    print("")
    sys.exit(0)
v = cfg
for part in os.environ["_CFG_KEY"].split("."):
    if isinstance(v, dict) and part in v:
        v = v[part]
    else:
        v = None
        break
print("" if v is None else v)
PYEOF
}

# Resolve a path: absolute as-is; "~/" expanded; relative resolved against the
# skill dir (historical behaviour), falling back to the config dir — so a key
# file can sit next to config.json in ~/.config/yandex-wordstat/.
_resolve_path() {
    _rp="$1"
    case "$_rp" in
        /*) printf '%s\n' "$_rp" ;;
        "~/"*) printf '%s/%s\n' "${HOME:-}" "${_rp#\~/}" ;;
        *)
            if [ ! -e "$WORDSTAT_SKILL_DIR/$_rp" ] && [ -e "$WORDSTAT_CONFIG_DIR/$_rp" ]; then
                printf '%s/%s\n' "$WORDSTAT_CONFIG_DIR" "$_rp"
            else
                printf '%s/%s\n' "$WORDSTAT_SKILL_DIR" "$_rp"
            fi
            ;;
    esac
}

# Detect cloud structural config. Sets WORDSTAT_CLOUD_* variables on success.
# Returns 0 if cloud is structurally configured, 1 if not, 2 if config.json is
# present but malformed (caller should die loudly).
_detect_cloud_config() {
    _cfg_file="$WORDSTAT_CONFIG_DIR/config.json"
    [ -f "$_cfg_file" ] || return 1

    _folder=$(_cfg_get yandex_cloud_folder_id)
    _sa_rel=$(_cfg_get auth.service_account_key_file)
    _ossl=$(_cfg_get auth.openssl_bin)
    _apikey=$(_cfg_get auth.api_key)
    [ -z "$_apikey" ] && _apikey="${YANDEX_CLOUD_API_KEY:-}"

    if [ -z "$_folder" ]; then
        WORDSTAT_BACKEND_DETECTED_VIA="cloud (config.json present but yandex_cloud_folder_id missing)"
        return 2
    fi

    if [ -n "$_apikey" ]; then
        WORDSTAT_CLOUD_FOLDER_ID="$_folder"
        WORDSTAT_CLOUD_API_KEY="$_apikey"
        WORDSTAT_CLOUD_SA_KEY_PATH=""
        WORDSTAT_CLOUD_OPENSSL_BIN="${_ossl:-openssl}"
        return 0
    fi

    if [ -z "$_sa_rel" ]; then
        WORDSTAT_BACKEND_DETECTED_VIA="cloud (config.json present but auth.service_account_key_file or auth.api_key missing)"
        return 2
    fi

    _sa_resolved=$(_resolve_path "$_sa_rel")
    if [ ! -r "$_sa_resolved" ]; then
        WORDSTAT_CLOUD_SA_KEY_PATH="$_sa_resolved"
        WORDSTAT_BACKEND_DETECTED_VIA="cloud (SA key file not found at resolved path)"
        return 2
    fi

    WORDSTAT_CLOUD_FOLDER_ID="$_folder"
    WORDSTAT_CLOUD_SA_KEY_PATH="$_sa_resolved"
    WORDSTAT_CLOUD_OPENSSL_BIN="${_ossl:-openssl}"
    WORDSTAT_CLOUD_API_KEY=""
    return 0
}

load_config() {
    _load_env_file

    # 1. Explicit override
    if [ -n "${YANDEX_WORDSTAT_BACKEND:-}" ]; then
        case "$YANDEX_WORDSTAT_BACKEND" in
            cloud)
                _rc=0
                _detect_cloud_config || _rc=$?
                if [ "$_rc" = "2" ]; then
                    WORDSTAT_BACKEND="cloud"
                    die_with_help "YANDEX_WORDSTAT_BACKEND=cloud but config is incomplete: $WORDSTAT_BACKEND_DETECTED_VIA"
                fi
                if [ "$_rc" = "1" ]; then
                    WORDSTAT_BACKEND="cloud"
                    die_with_help "YANDEX_WORDSTAT_BACKEND=cloud but $WORDSTAT_CONFIG_DIR/config.json is missing"
                fi
                WORDSTAT_BACKEND="cloud"
                WORDSTAT_BACKEND_DETECTED_VIA="explicit override"
                return 0
                ;;
            legacy)
                if [ -z "${YANDEX_WORDSTAT_TOKEN:-}" ]; then
                    WORDSTAT_BACKEND="legacy"
                    WORDSTAT_BACKEND_DETECTED_VIA="explicit override"
                    die_with_help "YANDEX_WORDSTAT_BACKEND=legacy but YANDEX_WORDSTAT_TOKEN is not set"
                fi
                WORDSTAT_BACKEND="legacy"
                WORDSTAT_BACKEND_DETECTED_VIA="explicit override"
                return 0
                ;;
            *)
                die_with_help "Invalid YANDEX_WORDSTAT_BACKEND='$YANDEX_WORDSTAT_BACKEND' (expected 'legacy' or 'cloud')"
                ;;
        esac
    fi

    # 2. Cloud structurally configured → cloud (cloud wins on tie)
    _rc=0
    _detect_cloud_config || _rc=$?
    if [ "$_rc" = "0" ]; then
        WORDSTAT_BACKEND="cloud"
        WORDSTAT_BACKEND_DETECTED_VIA="auto: config.json present"
        return 0
    fi
    if [ "$_rc" = "2" ]; then
        # Malformed cloud config → fail loudly, do NOT silently fall back
        WORDSTAT_BACKEND="cloud"
        die_with_help "$WORDSTAT_CONFIG_DIR/config.json present but invalid: $WORDSTAT_BACKEND_DETECTED_VIA"
    fi

    # 3. Legacy creds present → legacy
    if [ -n "${YANDEX_WORDSTAT_TOKEN:-}" ]; then
        WORDSTAT_BACKEND="legacy"
        WORDSTAT_BACKEND_DETECTED_VIA="auto: YANDEX_WORDSTAT_TOKEN set"
        return 0
    fi

    # 4. Nothing
    die_with_help "No Wordstat credentials found"
}

# ---------------------------------------------------------------------
# Backend info — used by quota.sh
# ---------------------------------------------------------------------

print_backend_info() {
    case "$WORDSTAT_BACKEND" in
        legacy)
            echo "Backend: legacy ($WORDSTAT_BACKEND_DETECTED_VIA)"
            echo ""
            echo "=== Endpoints ==="
            echo "  POST $WORDSTAT_LEGACY_API/topRequests"
            echo "  POST $WORDSTAT_LEGACY_API/dynamics"
            echo "  POST $WORDSTAT_LEGACY_API/regions"
            echo ""
            echo "=== API Limits ==="
            echo "  - Rate limit: 10 requests/second"
            echo "  - Daily quota: 1000 requests"
            echo "  - Local skill limit: rate_limit_per_hour (default 100/hour) applies here too;"
            echo "    to change it set YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR in .env"
            echo ""
            echo "Note: This API is deprecated for new users. Existing tokens still work."
            ;;
        cloud)
            echo "Backend: cloud ($WORDSTAT_BACKEND_DETECTED_VIA)"
            echo "  config:    $WORDSTAT_CONFIG_DIR"
            echo "  folder_id: $WORDSTAT_CLOUD_FOLDER_ID"
            if [ -n "${WORDSTAT_CLOUD_API_KEY:-}" ]; then
                _k="$WORDSTAT_CLOUD_API_KEY"
                echo "  auth:      Api-Key (last 4: ...${_k#"${_k%????}"})"
                unset _k
            else
                echo "  SA key:    $WORDSTAT_CLOUD_SA_KEY_PATH"
            fi
            echo ""
            echo "=== Endpoints ==="
            echo "  POST $WORDSTAT_CLOUD_API/topRequests"
            echo "  POST $WORDSTAT_CLOUD_API/dynamics"
            echo "  POST $WORDSTAT_CLOUD_API/regions"
            echo ""
            echo "=== API Limits ==="
            echo "  Квота считается на облако: по умолчанию Яндекс даёт 100 запросов в час"
            echo "  и 10 в секунду, дневного лимита нет. Квоту можно увеличить через поддержку"
            echo "  Yandex Cloud; тогда впишите её в config.json: \"rate_limit_per_hour\": <число>."
            echo "  Limits:  https://aistudio.yandex.ru/docs/ru/search-api/concepts/limits"
            echo "  Pricing: https://aistudio.yandex.ru/docs/ru/search-api/pricing"
            ;;
        *)
            echo "Backend: (not configured)"
            ;;
    esac
}

# ---------------------------------------------------------------------
# Rate limiter — client-side hourly sliding window + per-second cap
# ---------------------------------------------------------------------
#
# By default Yandex gives 100 Wordstat requests per hour and 10 per second per
# cloud; the hourly quota can be raised through Yandex Cloud support. Instead of
# running into HTTP 429, the skill counts its own calls in a small state file
# (one epoch timestamp per line) and takes a slot before EVERY HTTP attempt to
# the Wordstat API, retries included. IAM token requests are not counted.
#
# Settings. First match wins: process environment > the same variable in .env
# next to config.json > config.json key > default (see _load_env_file).
#   hourly limit   YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR   | config.json "rate_limit_per_hour"      | 100
#                  0 = do not limit per hour (calls are still counted)
#   per second     YANDEX_WORDSTAT_RATE_LIMIT_PER_SECOND | config.json "rate_limit_per_second"    | 10
#   max wait, s    YANDEX_WORDSTAT_RATE_MAX_WAIT         | config.json "rate_limit_max_wait_sec"  | 60
#   state dir      YANDEX_WORDSTAT_STATE_DIR | ${XDG_STATE_HOME:-~/.local/state}/yandex-wordstat
#
# Timestamps later than "now" (the clock was moved back) count as "now", so they
# leave the window within an hour instead of blocking for longer.
#
# If the state dir cannot be written, a warning goes to stderr and requests go
# out unlimited (the limiter never blocks work because of its own trouble).
#
# When the hourly budget is used up:
#   - the next slot frees within "max wait" → a note on stderr, sleep, continue;
#   - otherwise → an explanation in Russian on stderr, NO request is sent, and
#     wordstat_request prints a legacy-shape error JSON on stdout:
#       {"error":"local rate limit: ...","code":429,"retry_after":<s>}
#     so every caller takes its usual '"error"' branch and exits 1.
# HTTP 429 from Yandex is reported the same way (stderr text + error JSON).
#
# Concurrency: an exclusive flock(2) lock on calls.lock, taken by flock(1) when it
# is installed (Linux) or by python3 otherwise (macOS; python3 is required by the
# skill anyway). Only without both: an atomic symlink lock with age-based stale
# detection. Lock trouble never blocks a request.
#
# Test hooks: WORDSTAT_STATE_DIR (state dir), WORDSTAT_RATE_NOW (fake clock,
# epoch seconds), WORDSTAT_RATE_LOCK=flock|python|symlink (force a lock kind),
# WORDSTAT_RATE_MAX_LOOPS (attempts before giving up, default 1000); _ws_sleep
# may be redefined after sourcing.

WORDSTAT_RATE_DEFAULT_PER_HOUR=100
WORDSTAT_RATE_DEFAULT_PER_SECOND=10
WORDSTAT_RATE_DEFAULT_MAX_WAIT=60
WORDSTAT_RATE_WINDOW=3600

_ws_now() {
    if [ -n "${WORDSTAT_RATE_NOW:-}" ]; then
        printf '%s\n' "$WORDSTAT_RATE_NOW"
    else
        date +%s
    fi
}

_ws_sleep() {
    sleep "$1"
}

_ws_state_dir() {
    if [ -n "${WORDSTAT_STATE_DIR:-}" ]; then
        printf '%s\n' "$WORDSTAT_STATE_DIR"
    elif [ -n "${YANDEX_WORDSTAT_STATE_DIR:-}" ]; then
        printf '%s\n' "$YANDEX_WORDSTAT_STATE_DIR"
    elif [ -n "${XDG_STATE_HOME:-}" ]; then
        printf '%s/yandex-wordstat\n' "$XDG_STATE_HOME"
    elif [ -n "${HOME:-}" ]; then
        printf '%s/.local/state/yandex-wordstat\n' "$HOME"
    else
        printf '%s/state\n' "$WORDSTAT_CACHE_DIR"
    fi
}

_ws_is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# "<per_hour> <per_second> <max_wait>" from config.json, "-" for a missing key.
_cfg_rate_values() {
    _cfg_file="$WORDSTAT_CONFIG_DIR/config.json"
    if [ ! -f "$_cfg_file" ]; then
        echo "- - -"
        return 0
    fi
    _CFG_FILE="$_cfg_file" python3 - <<'PYEOF' 2>/dev/null || echo "- - -"
import json, os
try:
    with open(os.environ["_CFG_FILE"]) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
if not isinstance(cfg, dict):
    cfg = {}
out = []
for key in ("rate_limit_per_hour", "rate_limit_per_second", "rate_limit_max_wait_sec"):
    v = cfg.get(key)
    if v is None:
        out.append("-")
    elif isinstance(v, bool):
        out.append("invalid")
    elif isinstance(v, (int, float)) and float(v).is_integer():
        out.append(str(int(v)))
    else:
        s = "".join(str(v).split())  # "2 000" -> "2000"
        out.append(s or "-")
print(" ".join(out))
PYEOF
}

# Resolve limiter settings into _rl_per_hour, _rl_per_second, _rl_max_wait and
# _rl_hour_src (where the hourly limit came from). Dies on a malformed value.
_ws_rate_settings() {
    _rl_cfg=$(_cfg_rate_values)
    read -r _rl_cfg_h _rl_cfg_s _rl_cfg_w <<EOF
$_rl_cfg
EOF
    if [ -n "${YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR:-}" ]; then
        _rl_per_hour="$YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR"
        if [ "${_ws_rl_hour_from_dotenv:-}" = "1" ]; then
            _rl_hour_src=".env: YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR"
        else
            _rl_hour_src="переменная окружения YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR"
        fi
    elif [ "${_rl_cfg_h:--}" != "-" ]; then
        _rl_per_hour="$_rl_cfg_h"
        _rl_hour_src="config.json: rate_limit_per_hour"
    else
        _rl_per_hour="$WORDSTAT_RATE_DEFAULT_PER_HOUR"
        _rl_hour_src="по умолчанию"
    fi
    if [ -n "${YANDEX_WORDSTAT_RATE_LIMIT_PER_SECOND:-}" ]; then
        _rl_per_second="$YANDEX_WORDSTAT_RATE_LIMIT_PER_SECOND"
    elif [ "${_rl_cfg_s:--}" != "-" ]; then
        _rl_per_second="$_rl_cfg_s"
    else
        _rl_per_second="$WORDSTAT_RATE_DEFAULT_PER_SECOND"
    fi
    if [ -n "${YANDEX_WORDSTAT_RATE_MAX_WAIT:-}" ]; then
        _rl_max_wait="$YANDEX_WORDSTAT_RATE_MAX_WAIT"
    elif [ "${_rl_cfg_w:--}" != "-" ]; then
        _rl_max_wait="$_rl_cfg_w"
    else
        _rl_max_wait="$WORDSTAT_RATE_DEFAULT_MAX_WAIT"
    fi
    if ! _ws_is_uint "$_rl_per_hour"; then
        die_with_help "Неверный лимит запросов в час: '$_rl_per_hour' ($_rl_hour_src). Нужно целое число >= 0, например 100 или 2000."
    fi
    if ! _ws_is_uint "$_rl_per_second"; then
        die_with_help "Неверный лимит запросов в секунду: '$_rl_per_second' (rate_limit_per_second / YANDEX_WORDSTAT_RATE_LIMIT_PER_SECOND). Нужно целое число >= 0."
    fi
    if ! _ws_is_uint "$_rl_max_wait"; then
        die_with_help "Неверное время ожидания слота: '$_rl_max_wait' (rate_limit_max_wait_sec / YANDEX_WORDSTAT_RATE_MAX_WAIT). Нужно целое число секунд >= 0."
    fi
    return 0
}

# Run "$@" while holding the counter lock. Output of "$@" passes through.
_ws_with_lock() {
    _wl_dir=$(_ws_state_dir)
    _wl_kind="${WORDSTAT_RATE_LOCK:-}"
    if [ -z "$_wl_kind" ]; then
        if command -v flock >/dev/null 2>&1; then
            _wl_kind=flock
        elif command -v python3 >/dev/null 2>&1; then
            _wl_kind=python
        else
            _wl_kind=symlink
        fi
    fi
    case "$_wl_kind" in
        flock)
            (
                flock -w 10 9 2>/dev/null || :
                "$@"
            ) 9>>"$_wl_dir/calls.lock"
            return $?
            ;;
        python)
            # The same flock(2) lock that flock(1) takes. python3 locks the
            # inherited fd 9 and exits; the lock belongs to the open file, so it
            # stays held until this subshell closes fd 9. Gives up after 10 s,
            # like `flock -w 10`.
            (
                python3 -c 'import fcntl, signal, sys
signal.signal(signal.SIGALRM, lambda *a: sys.exit(1))
signal.alarm(10)
fcntl.flock(9, fcntl.LOCK_EX)' 2>/dev/null || :
                "$@"
            ) 9>>"$_wl_dir/calls.lock"
            return $?
            ;;
    esac
    # Last resort, only without both flock(1) and python3. `ln -s` is atomic and
    # exclusive, and the link target carries "<pid>:<epoch>" written in the same
    # step. A lock older than 10 s is stale (the critical section takes
    # milliseconds) and is removed. Known gap: that removal is check-then-rm, not
    # atomic. If the holder died and two or more processes wait, one of them can
    # remove the lock another has just taken; both then enter the critical
    # section and the hourly limit can be exceeded by one. A dead-PID check is
    # NOT used: a holder exits right after releasing, so a waiter that read its
    # PID would delete the next holder's fresh lock far more often.
    _wl_lock="$_wl_dir/calls.lock.ln"
    _wl_me="$$:$(_ws_now)"
    _wl_i=0
    while ! ln -s "$_wl_me" "$_wl_lock" 2>/dev/null; do
        _wl_i=$((_wl_i + 1))
        _wl_info=$(readlink "$_wl_lock" 2>/dev/null || :)
        _wl_t=${_wl_info#*:}
        if [ "$_wl_i" -lt 150 ] && [ -n "$_wl_info" ] && _ws_is_uint "$_wl_t"; then
            _wl_age=$(($(_ws_now) - _wl_t))
            [ "$_wl_age" -ge 0 ] || _wl_age=$((-_wl_age))
            if [ "$_wl_age" -gt 10 ]; then
                # take over only if the same stale holder still owns it
                if [ "$(readlink "$_wl_lock" 2>/dev/null || :)" = "$_wl_info" ]; then
                    rm -f "$_wl_lock"
                fi
                continue
            fi
        fi
        if [ "$_wl_i" -ge 150 ]; then
            # ~15 s without the lock: go on best-effort rather than block the request
            _wl_rc=0
            "$@" || _wl_rc=$?
            return $_wl_rc
        fi
        sleep 0.1 2>/dev/null || sleep 1
    done
    _wl_rc=0
    "$@" || _wl_rc=$?
    if [ "$(readlink "$_wl_lock" 2>/dev/null || :)" = "$_wl_me" ]; then
        rm -f "$_wl_lock"
    fi
    return $_wl_rc
}

# Critical section (call under _ws_with_lock): drop entries older than the
# window, decide, and record the call when it may go ahead.
# Args: per_hour per_second commit(1|0). per_hour/per_second 0 = no cap.
# Prints: "OK <used>" | "HOUR <wait_s> <used>" | "SEC <used>"  (<used> = before this call)
_ws_rate_try() {
    _rt_hour="$1"; _rt_sec="$2"; _rt_commit="$3"
    _rt_log="$(_ws_state_dir)/calls.log"
    _rt_tmp="$_rt_log.$$.tmp"
    _rt_now=$(_ws_now)
    : > "$_rt_tmp" 2>/dev/null || return 1
    _rt_stats="0 0"
    if [ -f "$_rt_log" ]; then
        # A timestamp later than now (clock moved back) is rewritten as now, so it
        # leaves the window within an hour. Values are copied as strings: some
        # awks print large numbers in exponent form.
        _rt_stats=$(awk -v now="$_rt_now" -v win="$WORDSTAT_RATE_WINDOW" -v out="$_rt_tmp" '
            $1 ~ /^[0-9]+$/ {
                t = $1
                if (t + 0 > now + 0) t = now
                if (t + 0 > now - win) {
                    printf "%s\n", t > out
                    n++
                    if (t + 0 >= now + 0) s++
                }
            }
            END { printf "%d %d\n", n, s }' "$_rt_log" 2>/dev/null) || _rt_stats="0 0"
    fi
    _rt_n=${_rt_stats% *}
    _rt_s=${_rt_stats#* }
    if [ "$_rt_hour" -gt 0 ] && [ "$_rt_n" -ge "$_rt_hour" ]; then
        # The slot frees when the (used - limit + 1)-th oldest call leaves the window
        _rt_k=$((_rt_n - _rt_hour + 1))
        _rt_t=$(sort -n "$_rt_tmp" | sed -n "${_rt_k}p")
        [ -n "$_rt_t" ] || _rt_t="$_rt_now"
        _rt_wait=$((_rt_t + WORDSTAT_RATE_WINDOW - _rt_now))
        [ "$_rt_wait" -ge 1 ] || _rt_wait=1
        _rt_res="HOUR $_rt_wait $_rt_n"
    elif [ "$_rt_sec" -gt 0 ] && [ "$_rt_s" -ge "$_rt_sec" ]; then
        _rt_res="SEC $_rt_n"
    else
        if [ "$_rt_commit" = "1" ]; then
            printf '%s\n' "$_rt_now" >> "$_rt_tmp"
        fi
        _rt_res="OK $_rt_n"
    fi
    mv -f "$_rt_tmp" "$_rt_log" 2>/dev/null || rm -f "$_rt_tmp"
    printf '%s\n' "$_rt_res"
}

# 1390 → "23 мин 10 с"
_ws_fmt_duration() {
    if [ "$1" -ge 60 ]; then
        printf '%d мин %d с' $(($1 / 60)) $(($1 % 60))
    else
        printf '%d с' "$1"
    fi
}

# epoch → local HH:MM (GNU date, then BSD/macOS date); empty if neither works
_ws_clock_at() {
    date -d "@$1" +%H:%M 2>/dev/null || date -r "$1" +%H:%M 2>/dev/null || :
}

_ws_rate_explain_exhausted() {
    _ee_used="$1"; _ee_wait="$2"
    _ee_at=$(_ws_clock_at $(($(_ws_now) + _ee_wait)))
    {
        printf '[wordstat] Исчерпан часовой лимит запросов к Wordstat: %s из %s за последние 60 минут.\n' "$_ee_used" "$_rl_per_hour"
        printf '  Запрос НЕ отправлен. Следующий можно будет сделать через %s' "$(_ws_fmt_duration "$_ee_wait")"
        if [ -n "$_ee_at" ]; then
            printf ' (около %s)' "$_ee_at"
        fi
        printf '.\n'
        printf '  Лимит скилла в час: %s (%s).\n' "$_rl_per_hour" "$_rl_hour_src"
        if [ "${WORDSTAT_BACKEND:-}" = "legacy" ]; then
            printf '  Старый Wordstat API (legacy): счётчик скилла действует и здесь, по умолчанию 100 запросов в час.\n'
        else
            printf '  По умолчанию Яндекс даёт 100 запросов в час; квоту можно увеличить через поддержку Yandex Cloud.\n'
        fi
        printf '  Что можно сделать:\n'
        printf '    - подождать и повторить; остаток бюджета: sh scripts/quota.sh --budget (без запроса к API);\n'
        printf '    - сократить план: меньше фраз, шире запросы, OR-группы (a|b|c) вместо отдельных вызовов;\n'
        if [ "${WORDSTAT_BACKEND:-}" = "legacy" ]; then
            printf '    - если ваша квота старого API больше, задайте её в .env: YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=<число>.\n'
            printf '      Папка настроек: %s\n' "$WORDSTAT_CONFIG_DIR"
        else
            printf '    - если квота в Yandex Cloud увеличена, впишите её в config.json: "rate_limit_per_hour": 2000\n'
            printf '      (или переменную YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR). Папка настроек: %s\n' "$WORDSTAT_CONFIG_DIR"
        fi
        printf '    - чтобы скрипт сам дожидался слота, задайте YANDEX_WORDSTAT_RATE_MAX_WAIT=<секунд> (сейчас %s).\n' "$_rl_max_wait"
        printf '  Счётчик запросов: %s/calls.log\n' "$(_ws_state_dir)"
    } >&2
}

# The counter cannot be written: say so once per call, then let the request go.
_ws_rate_warn_unenforced() {
    {
        printf '[wordstat] Нет записи в папку счётчика запросов %s — лимит %s в час не соблюдается.\n' \
            "$1" "$_rl_per_hour"
        printf '  Проверьте права на папку или задайте другую: YANDEX_WORDSTAT_STATE_DIR=<путь>.\n'
    } >&2
}

# Take one request slot (waits if allowed). Returns 0 when the call may go ahead,
# 1 when it must not (explanation already printed to stderr; _rl_last_reason,
# _rl_last_used and _rl_last_wait hold the details for _ws_rate_error_json).
_ws_rate_acquire() {
    _ws_rate_settings
    _rl_last_reason=""
    _ra_dir=$(_ws_state_dir)
    if ! (umask 077; mkdir -p "$_ra_dir") 2>/dev/null || [ ! -w "$_ra_dir" ]; then
        _ws_rate_warn_unenforced "$_ra_dir"
        return 0
    fi
    _ra_max_loops="${WORDSTAT_RATE_MAX_LOOPS:-1000}"
    _ra_waited=0
    _ra_loops=0
    while [ "$_ra_loops" -lt "$_ra_max_loops" ]; do
        _ra_loops=$((_ra_loops + 1))
        if ! _ra_res=$(_ws_with_lock _ws_rate_try "$_rl_per_hour" "$_rl_per_second" 1 2>/dev/null); then
            _ws_rate_warn_unenforced "$_ra_dir"
            return 0
        fi
        read -r _ra_kind _ra_a _ra_b <<EOF
$_ra_res
EOF
        case "$_ra_kind" in
            SEC)
                _ws_sleep 1
                ;;
            HOUR)
                if [ $((_ra_waited + _ra_a)) -le "$_rl_max_wait" ]; then
                    printf '[wordstat] Часовой лимит скилла (%s в час) исчерпан, свободный слот через %s — жду.\n' \
                        "$_rl_per_hour" "$(_ws_fmt_duration "$_ra_a")" >&2
                    _ws_sleep "$_ra_a"
                    _ra_waited=$((_ra_waited + _ra_a))
                else
                    _rl_last_reason="hour"
                    _rl_last_wait="$_ra_a"
                    _rl_last_used="$_ra_b"
                    _ws_rate_explain_exhausted "$_ra_b" "$_ra_a"
                    return 1
                fi
                ;;
            *)
                return 0
                ;;
        esac
    done
    # Still no slot after many attempts (e.g. the per-second check never clears):
    # do not send the request unrecorded.
    _rl_last_reason="stuck"
    _rl_last_wait=1
    {
        printf '[wordstat] Счётчик запросов не выдал слот за %s попыток — запрос НЕ отправлен.\n' "$_ra_loops"
        printf '  Проверьте системные часы и файл счётчика %s/calls.log, затем повторите.\n' "$_ra_dir"
    } >&2
    return 1
}

# Legacy-shape error JSON for a refused call (stdout).
_ws_rate_error_json() {
    if [ "${_rl_last_reason:-}" = "stuck" ]; then
        printf '{"error":"local rate limit: no free slot in the local request counter, request not sent","code":429,"retry_after":1}\n'
        return 0
    fi
    printf '{"error":"local rate limit: hourly quota of %s requests used up (%s in the last hour), retry in %s s","code":429,"retry_after":%s}\n' \
        "$_rl_per_hour" "${_rl_last_used:-?}" "${_rl_last_wait:-0}" "${_rl_last_wait:-0}"
}

# First N characters (not bytes) of a string, so a UTF-8 character is never cut.
# Args: N, string
_ws_head_chars() {
    printf '%s' "$2" | python3 -c 'import sys
n = int(sys.argv[1])
s = sys.stdin.buffer.read().decode("utf-8", "replace")[:n]
sys.stdout.buffer.write(s.encode("utf-8"))' "$1" 2>/dev/null \
        || printf '%s' "$2" | cut -c "1-$1"
}

# HTTP 429 from Yandex: explanation on stderr, legacy-shape error JSON on stdout.
# Args: kind (hour|second|unknown), raw response body
_ws_report_http_429() {
    _h4_kind="$1"; _h4_raw="$2"
    _h4_peek=$(_ws_with_lock _ws_rate_try 0 0 0 2>/dev/null) || _h4_peek="OK ?"
    _h4_used=${_h4_peek#OK }
    {
        case "$_h4_kind" in
            hour)   printf '[wordstat] Яндекс ответил 429: исчерпана почасовая квота Wordstat в облаке.\n' ;;
            second) printf '[wordstat] Яндекс ответил 429: слишком часто (больше 10 запросов в секунду), повторы не помогли.\n' ;;
            *)      printf '[wordstat] Яндекс ответил 429 (Too Many Requests): квота запросов исчерпана.\n' ;;
        esac
        printf '  По умолчанию Яндекс даёт 100 запросов в час и 10 в секунду; квоту можно увеличить через поддержку Yandex Cloud.\n'
        printf '  Счётчик скилла за последний час: %s, лимит %s (%s).\n' "$_h4_used" "${_rl_per_hour:-?}" "${_rl_hour_src:-?}"
        printf '  Если счётчик меньше квоты — тот же облачный каталог расходуют другие программы,\n'
        printf '  или rate_limit_per_hour в config.json больше квоты, реально выданной в Yandex Cloud.\n'
        printf '  Подождите (почасовое окно освобождается в течение часа) и повторите.\n'
        printf '  Ответ Яндекса: %s\n' "$(_ws_head_chars 300 "$_h4_raw")"
    } >&2
    case "$_h4_kind" in
        hour)   _h4_what="hourly quota exceeded" ;;
        second) _h4_what="per-second limit exceeded" ;;
        *)      _h4_what="quota exceeded" ;;
    esac
    printf '{"error":"HTTP 429 Too Many Requests: Wordstat %s","code":429}\n' "$_h4_what"
}

# Public: print the hourly budget from the local counter. Makes no API call.
print_rate_budget() {
    _ws_rate_settings
    _pb_dir=$(_ws_state_dir)
    (umask 077; mkdir -p "$_pb_dir") 2>/dev/null || :
    _pb_ok=1
    if [ ! -w "$_pb_dir" ] || ! _pb_peek=$(_ws_with_lock _ws_rate_try "$_rl_per_hour" 0 0 2>/dev/null); then
        _pb_peek="OK 0"
        _pb_ok=0
    fi
    read -r _pb_kind _pb_a _pb_b <<EOF
$_pb_peek
EOF
    if [ "$_pb_kind" = "HOUR" ]; then
        _pb_used="$_pb_b"
    else
        _pb_used="$_pb_a"
    fi
    echo "=== Бюджет запросов Wordstat (счётчик скилла, без запроса к API) ==="
    if [ "$_rl_per_hour" -gt 0 ]; then
        _pb_left=$((_rl_per_hour - _pb_used))
        [ "$_pb_left" -ge 0 ] || _pb_left=0
        echo "  Лимит:              $_rl_per_hour в час ($_rl_hour_src), $_rl_per_second в секунду"
        echo "  За последние 60 мин: $_pb_used"
        echo "  Осталось:           $_pb_left"
        if [ "$_pb_kind" = "HOUR" ]; then
            echo "  Следующий запрос:   через $(_ws_fmt_duration "$_pb_a")"
        fi
    else
        echo "  Лимит:              в час не ограничен (rate_limit_per_hour = 0), $_rl_per_second в секунду"
        echo "  За последние 60 мин: $_pb_used"
    fi
    echo "  Счётчик:            $_pb_dir/calls.log"
    if [ "$_pb_ok" = "0" ]; then
        echo "  Внимание: нет записи в папку счётчика — лимит не соблюдается, цифры выше неверны."
        echo "  Проверьте права на папку или задайте другую: YANDEX_WORDSTAT_STATE_DIR=<путь>."
    fi
    echo ""
    echo "  Учитываются только запросы скриптов этого скилла на этой машине."
    echo "  По умолчанию Яндекс даёт 100 запросов в час; квоту можно увеличить через поддержку"
    echo "  Yandex Cloud. Увеличенную квоту впишите в config.json: \"rate_limit_per_hour\": 2000"
}

# ---------------------------------------------------------------------
# IAM token — JWT PS256 with SA key (inline-copied from yandex-search-api)
# ---------------------------------------------------------------------

_make_secure_tmpdir() {
    _old_umask=$(umask)
    umask 077
    _td=$(mktemp -d "${TMPDIR:-/tmp}/wordstat_XXXXXX")
    umask "$_old_umask"
    echo "$_td"
}

_check_openssl() {
    _ossl="$1"
    if ! command -v "$_ossl" >/dev/null 2>&1; then
        die_with_help "openssl not found at '$_ossl'" \
            "Install OpenSSL 1.1.1+ or set auth.openssl_bin in config/config.json"
    fi
    _ossl_ver=$("$_ossl" version 2>/dev/null || true)
    case "$_ossl_ver" in
        LibreSSL*)
            die_with_help "LibreSSL detected ($_ossl_ver) — OpenSSL 1.1.1+ required for PS256" \
                "macOS users: brew install openssl@3 and set auth.openssl_bin to the homebrew path"
            ;;
        "OpenSSL 0."*|"OpenSSL 1.0."*)
            die_with_help "OpenSSL too old ($_ossl_ver), need 1.1.1+"
            ;;
    esac
}

_get_cached_iam_token() {
    _cf="$WORDSTAT_CACHE_DIR/iam_token.json"
    [ -f "$_cf" ] || return 0
    _CACHE_FILE="$_cf" python3 - <<'PYEOF' 2>/dev/null
import json, os, time
cf = os.environ["_CACHE_FILE"]
try:
    with open(cf) as f:
        d = json.load(f)
    exp = d.get("expires_at", 0)
    if exp - time.time() > 300:
        print(d["iam_token"])
except Exception:
    pass
PYEOF
}

_save_iam_token() {
    _tok="$1"
    _exp="$2"
    mkdir -p "$WORDSTAT_CACHE_DIR"
    _cf="$WORDSTAT_CACHE_DIR/iam_token.json"
    _old_umask=$(umask)
    umask 077
    _tmp="$WORDSTAT_CACHE_DIR/.iam_token_tmp_$$.json"
    _SAVE_TOKEN="$_tok" _SAVE_EXP="$_exp" _TMP_FILE="$_tmp" python3 - <<'PYEOF'
import json, os
d = {"iam_token": os.environ["_SAVE_TOKEN"], "expires_at": int(os.environ["_SAVE_EXP"])}
with open(os.environ["_TMP_FILE"], "w") as f:
    json.dump(d, f)
PYEOF
    mv "$_tmp" "$_cf"
    umask "$_old_umask"
}

# Issue a fresh IAM token from the SA key. Echoes token on stdout.
_iam_token_issue() {
    _check_openssl "$WORDSTAT_CLOUD_OPENSSL_BIN"

    if [ ! -r "$WORDSTAT_CLOUD_SA_KEY_PATH" ]; then
        die_with_help "Service account key file not readable: $WORDSTAT_CLOUD_SA_KEY_PATH"
    fi

    _tmp=$(_make_secure_tmpdir)
    # shellcheck disable=SC2064
    trap "rm -rf '$_tmp'" EXIT INT TERM

    # Build JWT header + payload, write key.pem and signing_input.txt
    _SA_KEY="$WORDSTAT_CLOUD_SA_KEY_PATH" _TMP="$_tmp" python3 - <<'PYEOF' || die_with_help "Failed to build JWT from SA key"
import json, base64, time, os, sys
sa_key_file = os.environ["_SA_KEY"]
tmp_dir = os.environ["_TMP"]
try:
    with open(sa_key_file) as f:
        sa = json.load(f)
    sa_id = sa["service_account_id"]
    key_id = sa["id"]
    private_key = sa["private_key"]
except Exception as e:
    print(f"SA key parse error: {e}", file=sys.stderr)
    sys.exit(1)

with open(os.path.join(tmp_dir, "key.pem"), "w") as f:
    f.write(private_key)

header = json.dumps({"typ": "JWT", "alg": "PS256", "kid": key_id}, separators=(",", ":"))
header_b64 = base64.urlsafe_b64encode(header.encode()).rstrip(b"=").decode()

now = int(time.time())
payload = json.dumps({
    "iss": sa_id,
    "aud": "https://iam.api.cloud.yandex.net/iam/v1/tokens",
    "iat": now,
    "exp": now + 3600,
}, separators=(",", ":"))
payload_b64 = base64.urlsafe_b64encode(payload.encode()).rstrip(b"=").decode()

signing_input = f"{header_b64}.{payload_b64}"
with open(os.path.join(tmp_dir, "signing_input.txt"), "w") as f:
    f.write(signing_input)
with open(os.path.join(tmp_dir, "header_payload.txt"), "w") as f:
    f.write(signing_input)
PYEOF

    "$WORDSTAT_CLOUD_OPENSSL_BIN" dgst -sha256 \
        -sigopt rsa_padding_mode:pss \
        -sigopt rsa_pss_saltlen:-1 \
        -sign "$_tmp/key.pem" \
        -out "$_tmp/signature.bin" \
        "$_tmp/signing_input.txt" 2>/dev/null \
        || die_with_help "openssl PS256 signing failed"

    _sig=$(python3 -c "
import base64, sys
with open('$_tmp/signature.bin', 'rb') as f:
    print(base64.urlsafe_b64encode(f.read()).rstrip(b'=').decode())
")
    _hp=$(cat "$_tmp/header_payload.txt")
    _jwt="${_hp}.${_sig}"

    _resp=$(curl -s -X POST "$WORDSTAT_IAM_API" \
        -H "Content-Type: application/json" \
        -d "{\"jwt\":\"$_jwt\"}")

    if [ -z "$_resp" ]; then
        die_with_help "Empty response from IAM API"
    fi

    # Parse token + expiry
    _result=$(printf '%s' "$_resp" | python3 -c "
import json, sys
from datetime import datetime
try:
    d = json.load(sys.stdin)
except Exception as e:
    print('PARSE_ERROR:' + str(e))
    sys.exit(0)
tok = d.get('iamToken', '')
exp_s = d.get('expiresAt', '')
if not tok:
    print('NO_TOKEN:' + json.dumps(d)[:300])
    sys.exit(0)
if exp_s:
    try:
        ts = datetime.fromisoformat(exp_s.replace('Z', '+00:00')).timestamp()
        exp = int(ts)
    except Exception:
        import time
        exp = int(time.time()) + 43200
else:
    import time
    exp = int(time.time()) + 43200
print(f'{tok}|{exp}')
")
    case "$_result" in
        PARSE_ERROR:*) die_with_help "IAM response parse error: ${_result#PARSE_ERROR:}" "Raw: $_resp" ;;
        NO_TOKEN:*)    die_with_help "IAM response missing iamToken" "${_result#NO_TOKEN:}" ;;
    esac

    _tok=$(printf '%s' "$_result" | cut -d'|' -f1)
    _exp=$(printf '%s' "$_result" | cut -d'|' -f2)
    _save_iam_token "$_tok" "$_exp"

    rm -rf "$_tmp"
    trap - EXIT INT TERM
    printf '%s' "$_tok"
}

_iam_token_get() {
    _cached=$(_get_cached_iam_token)
    if [ -n "$_cached" ]; then
        printf '%s' "$_cached"
        return 0
    fi
    _iam_token_issue
}

# ---------------------------------------------------------------------
# Request translation + response normalization (cloud ↔ legacy)
# ---------------------------------------------------------------------

# Translate legacy-shape params JSON → cloud request body JSON.
# Args: $1 = method (topRequests|dynamics|regions), $2 = legacy params JSON
# Output: cloud-shape JSON on stdout.
# Exits 1 with die_with_help on dynamics preflight failure.
_xlate_request() {
    _method="$1"
    _params="$2"
    _METHOD="$_method" _PARAMS="$_params" _FOLDER="$WORDSTAT_CLOUD_FOLDER_ID" \
    python3 - <<'PYEOF'
import json, os, re, sys

method = os.environ["_METHOD"]
params = json.loads(os.environ["_PARAMS"])
folder = os.environ["_FOLDER"]

DEVICE_MAP = {
    "all": "DEVICE_ALL",
    "desktop": "DEVICE_DESKTOP",
    "phone": "DEVICE_PHONE",
    "tablet": "DEVICE_TABLET",
}
PERIOD_MAP = {
    "monthly": "PERIOD_MONTHLY",
    "weekly": "PERIOD_WEEKLY",
    "daily": "PERIOD_DAILY",
}
REGION_TYPE_MAP = {
    "all": "REGION_ALL",
    "cities": "REGION_CITIES",
    "regions": "REGION_REGIONS",
}

def map_devices(d):
    if d is None:
        return ["DEVICE_ALL"]
    if isinstance(d, list):
        return [DEVICE_MAP.get(x, x) if isinstance(x, str) and not x.startswith("DEVICE_") else x for x in d]
    return [DEVICE_MAP.get(d, "DEVICE_ALL")]

def map_regions(r):
    if r is None:
        return None
    return [str(x) for x in r]

def to_rfc3339(d):
    # Accept either YYYY-MM-DD or already-RFC3339
    if not d:
        return d
    if "T" in d:
        return d
    return d + "T00:00:00Z"

if method == "topRequests":
    body = {"phrase": params["phrase"]}
    if "numPhrases" in params:
        body["numPhrases"] = str(params["numPhrases"])
    if "regions" in params:
        body["regions"] = map_regions(params["regions"])
    if "devices" in params:
        body["devices"] = map_devices(params["devices"])
    body["folderId"] = folder

elif method == "dynamics":
    # ---- Preflight: cloud only allows '+' operator at weekly/monthly ----
    period = params.get("period", "monthly")
    phrase = params.get("phrase", "")
    if period != "daily":
        # Token-boundary detection of operators that cloud rejects at non-daily.
        # Hyphen inside word (санкт-петербург, премиум-класс) MUST pass.
        # Token-leading -, !, or any of " ( | ) trigger the failure. + is allowed.
        bad_ops = []
        if re.search(r'(^|\s)-\S', phrase):
            bad_ops.append("- (minus-word)")
        if re.search(r'(^|\s)!\S', phrase):
            bad_ops.append("! (exact form)")
        if '"' in phrase:
            bad_ops.append('" (exact phrase)')
        if "(" in phrase or ")" in phrase or "|" in phrase:
            bad_ops.append("( | ) (grouping)")
        if bad_ops:
            print("PREFLIGHT_FAIL:" + ", ".join(bad_ops), file=sys.stderr)
            sys.exit(2)

    body = {
        "phrase": phrase,
        "period": PERIOD_MAP.get(period, period),
        "fromDate": to_rfc3339(params["fromDate"]),
    }
    if "toDate" in params and params["toDate"]:
        body["toDate"] = to_rfc3339(params["toDate"])
    if "regions" in params:
        body["regions"] = map_regions(params["regions"])
    if "devices" in params:
        body["devices"] = map_devices(params["devices"])
    body["folderId"] = folder

elif method == "regions":
    body = {"phrase": params["phrase"]}
    if "regionType" in params:
        body["region"] = REGION_TYPE_MAP.get(params["regionType"], params["regionType"])
    if "devices" in params:
        body["devices"] = map_devices(params["devices"])
    body["folderId"] = folder

else:
    print(f"UNKNOWN_METHOD:{method}", file=sys.stderr)
    sys.exit(2)

print(json.dumps(body, ensure_ascii=False))
PYEOF
}

# Normalize cloud response JSON → legacy shape JSON.
# Args: $1 = method, $2 = path to cloud response file (optional; if missing, spool stdin)
# Output: legacy-shape JSON on stdout
#
# Implementation note: cloud responses for topRequests --limit 2000 can be
# multi-MB. Passing through env var is unsafe (ARG_MAX / E2BIG). We use a file
# path. If the caller already has the response in a file (e.g. _cloud_request),
# pass it as $2 to skip the spool step.
_normalize_response() {
    _method="$1"
    _nr_owns_tmp=0
    if [ -n "${2:-}" ]; then
        _nr_tmp="$2"
    else
        _nr_tmp="${TMPDIR:-/tmp}/wordstat_norm_$$.json"
        cat > "$_nr_tmp"
        _nr_owns_tmp=1
    fi
    _METHOD="$_method" _RESP_FILE="$_nr_tmp" python3 - <<'PYEOF'
import json, os, sys
method = os.environ["_METHOD"]
try:
    with open(os.environ["_RESP_FILE"], "r", encoding="utf-8") as f:
        d = json.load(f)
except Exception as e:
    print(json.dumps({"error": f"Cloud response parse error: {e}"}))
    sys.exit(0)

# Translate cloud error JSON to legacy {"error": ...}
if "code" in d and "message" in d and "results" not in d and "topRequests" not in d:
    print(json.dumps({"error": d.get("message", "cloud error"), "code": d.get("code")}))
    sys.exit(0)

def to_int(v):
    if v is None:
        return 0
    try:
        return int(v)
    except (TypeError, ValueError):
        return v

if method == "topRequests":
    out = {}
    if "totalCount" in d:
        out["totalCount"] = to_int(d["totalCount"])
    out["topRequests"] = [
        {"phrase": r.get("phrase", ""), "count": to_int(r.get("count", 0))}
        for r in d.get("results", [])
    ]
    out["associations"] = [
        {"phrase": r.get("phrase", ""), "count": to_int(r.get("count", 0))}
        for r in d.get("associations", [])
    ]

elif method == "dynamics":
    out = {
        "data": [
            {
                "date": r.get("date", ""),
                "count": to_int(r.get("count", 0)),
                "share": r.get("share", 0),
            }
            for r in d.get("results", [])
        ]
    }

elif method == "regions":
    out = {
        "regions": [
            {
                "regionId": to_int(r.get("region", 0)),
                "count": to_int(r.get("count", 0)),
                "share": r.get("share", 0),
                "affinity": to_int(r.get("affinityIndex", r.get("affinity", 0))),
            }
            for r in d.get("results", [])
        ]
    }
else:
    out = d

# Compact separators — no spaces. Matches the legacy API JSON shape that
# existing grep/sed parsers in top_requests.sh, dynamics.sh, regions_stats.sh expect.
# E.g. "topRequests":[{"phrase":"...","count":123}] not "topRequests": [{"phrase": "...", "count": 123}]
print(json.dumps(out, ensure_ascii=False, separators=(",", ":")))
PYEOF
    [ "$_nr_owns_tmp" = "1" ] && rm -f "$_nr_tmp"
    return 0
}

# ---------------------------------------------------------------------
# wordstat_request — public dispatcher
# ---------------------------------------------------------------------

# Legacy backend: direct curl to api.wordstat.yandex.net/v1
_legacy_request() {
    _method="$1"
    _params="$2"
    if ! _ws_rate_acquire; then
        _ws_rate_error_json
        return 0
    fi
    curl -s -X POST "$WORDSTAT_LEGACY_API/$_method" \
        -H "Authorization: Bearer $YANDEX_WORDSTAT_TOKEN" \
        -H "Content-Type: application/json; charset=utf-8" \
        -H "Accept-Language: ru" \
        -d "$_params"
}

# Cloud backend: translate, sign, POST, normalize
_cloud_request() {
    _method="$1"
    _params="$2"

    # 1. Translate request
    _xlate_out=$(_xlate_request "$_method" "$_params" 2>&1)
    _xlate_rc=$?
    if [ "$_xlate_rc" != "0" ]; then
        case "$_xlate_out" in
            *PREFLIGHT_FAIL:*)
                _ops=${_xlate_out#*PREFLIGHT_FAIL:}
                die_with_help \
                    "Cloud Wordstat dynamics: at weekly/monthly granularity, only '+' operator is allowed. Found: $_ops" \
                    "Either switch --period to daily, or remove these operators from --phrase. See: https://aistudio.yandex.ru/docs/ru/search-api/operations/wordstat-getdynamics.html"
                ;;
            *UNKNOWN_METHOD:*)
                die_with_help "Unknown wordstat method: ${_xlate_out#*UNKNOWN_METHOD:}"
                ;;
            *)
                die_with_help "Request translation failed" "$_xlate_out"
                ;;
        esac
    fi
    _cloud_body="$_xlate_out"

    # 2. Get auth header (Api-Key shortcut, else IAM token via SA key)
    if [ -n "${WORDSTAT_CLOUD_API_KEY:-}" ]; then
        _auth_header="Api-Key $WORDSTAT_CLOUD_API_KEY"
        _auth_mode="apikey"
    else
        _tok=$(_iam_token_get)
        if [ -z "$_tok" ]; then
            die_with_help "Failed to obtain IAM token"
        fi
        _auth_header="Bearer $_tok"
        _auth_mode="iam"
    fi

    # 3. POST with retry on 5xx / per-second 429 and refresh on 401.
    #    Every attempt (retries included) first takes a rate-limiter slot.
    _attempt=0
    _max_attempts=3
    _backoff=2
    while [ "$_attempt" -lt "$_max_attempts" ]; do
        _attempt=$((_attempt + 1))
        if ! _ws_rate_acquire; then
            _ws_rate_error_json
            return 0
        fi
        _tmp=$(_make_secure_tmpdir)
        _resp_file="$_tmp/resp"
        _status=$(curl -s -o "$_resp_file" -w '%{http_code}' \
            -X POST "$WORDSTAT_CLOUD_API/$_method" \
            -H "Authorization: $_auth_header" \
            -H "Content-Type: application/json" \
            -d "$_cloud_body")

        case "$_status" in
            2[0-9][0-9])
                _normalize_response "$_method" "$_resp_file"
                rm -rf "$_tmp"
                return 0
                ;;
            401)
                # Refresh once and retry (only for IAM; Api-Key is static)
                if [ "$_auth_mode" = "iam" ] && [ "$_attempt" = "1" ]; then
                    rm -f "$WORDSTAT_CACHE_DIR/iam_token.json"
                    _tok=$(_iam_token_issue)
                    _auth_header="Bearer $_tok"
                    rm -rf "$_tmp"
                    continue
                fi
                _err=$(cat "$_resp_file" 2>/dev/null)
                rm -rf "$_tmp"
                if [ "$_auth_mode" = "apikey" ]; then
                    die_with_help "Cloud Wordstat 401 Unauthorized (API key rejected: check the key and its scope yc.search-api.execute)" "$_err"
                fi
                die_with_help "Cloud Wordstat 401 Unauthorized after token refresh" "$_err"
                ;;
            403)
                _err=$(cat "$_resp_file" 2>/dev/null)
                rm -rf "$_tmp"
                die_with_help "Cloud Wordstat 403 Forbidden" \
                    "Check that your service account has the role 'search-api.webSearch.user' on folder $WORDSTAT_CLOUD_FOLDER_ID. Raw: $_err"
                ;;
            429)
                _err=$(cat "$_resp_file" 2>/dev/null || :)
                rm -rf "$_tmp"
                # Hourly quota: retrying only burns attempts. Per-second throttling
                # (or an unrecognised body, once) is worth a backoff and a retry.
                case "$(printf '%s' "$_err" | LC_ALL=C tr '[:upper:]' '[:lower:]')" in
                    *hour*)           _kind429="hour" ;;
                    *second*|*rps*)   _kind429="second" ;;
                    *)                _kind429="unknown" ;;
                esac
                if [ "$_attempt" -lt "$_max_attempts" ] && \
                   { [ "$_kind429" = "second" ] || { [ "$_kind429" = "unknown" ] && [ "$_attempt" = "1" ]; }; }; then
                    _ws_sleep "$_backoff"
                    _backoff=$((_backoff * 2))
                    continue
                fi
                _ws_report_http_429 "$_kind429" "$_err"
                return 0
                ;;
            5[0-9][0-9]|000)
                if [ "$_attempt" -lt "$_max_attempts" ]; then
                    rm -rf "$_tmp"
                    _ws_sleep "$_backoff"
                    _backoff=$((_backoff * 2))
                    continue
                fi
                _err=$(cat "$_resp_file" 2>/dev/null)
                rm -rf "$_tmp"
                die_with_help "Cloud Wordstat $_status after $_max_attempts retries" "$_err"
                ;;
            *)
                _err=$(cat "$_resp_file" 2>/dev/null)
                rm -rf "$_tmp"
                die_with_help "Cloud Wordstat HTTP $_status" "$_err"
                ;;
        esac
    done
}

# Public entry point
wordstat_request() {
    _method="$1"
    _params="$2"

    if [ -z "$WORDSTAT_BACKEND" ]; then
        die_with_help "wordstat_request called before load_config"
    fi

    case "$WORDSTAT_BACKEND" in
        legacy) _legacy_request "$_method" "$_params" ;;
        cloud)  _cloud_request "$_method" "$_params" ;;
        *)      die_with_help "Unknown backend: $WORDSTAT_BACKEND" ;;
    esac
}
