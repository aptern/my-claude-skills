#!/bin/bash
# =====================================================================
# yandex-webmaster — общие хелперы
# Источник для всех остальных скриптов: source common.sh
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$SKILL_DIR/config"
ENV_FILE="$CONFIG_DIR/.env"
CACHE_DIR="$SKILL_DIR/cache"
API_BASE="https://api.webmaster.yandex.net/v4"

mkdir -p "$CACHE_DIR"

# --- зависимости ---
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq не установлен. Установите: brew install jq" >&2
  exit 1
fi

# --- загрузка .env ---
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

TOKEN="${YANDEX_WEBMASTER_TOKEN:-}"
if [[ -z "$TOKEN" || "$TOKEN" == "your_token_here" ]]; then
  echo "ERROR: YANDEX_WEBMASTER_TOKEN не задан в $ENV_FILE" >&2
  echo "Получите токен:  bash $SCRIPT_DIR/get_token.sh --client-id <CLIENT_ID>" >&2
  exit 1
fi

HOST_DOMAIN="${YANDEX_WEBMASTER_HOST:-nacifrah.ru}"

# --- работа с датами (BSD/macOS и GNU) ---
wm_date_ago() { # $1 = кол-во дней назад → YYYY-MM-DD
  if date -v-1d >/dev/null 2>&1; then
    date -v-"$1"d +%Y-%m-%d
  else
    date -d "-$1 day" +%Y-%m-%d
  fi
}
DATE_TO="${DATE_TO:-$(wm_date_ago 1)}"
DATE_FROM="${DATE_FROM:-$(wm_date_ago 30)}"

# --- базовый GET к API ---
# wm_get <path-с-query>  → печатает тело ответа, падает при HTTP != 200
wm_get() {
  local path="$1"
  local resp http body
  resp=$(curl -s -m 30 -w $'\n%{http_code}' \
    -H "Authorization: OAuth $TOKEN" \
    "$API_BASE$path")
  http="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [[ "$http" == "401" ]]; then
    echo "ERROR: HTTP 401 — токен невалиден или истёк. Перевыпустите: bash $SCRIPT_DIR/get_token.sh --client-id <CLIENT_ID>" >&2
    return 1
  fi
  if [[ "$http" != "200" ]]; then
    echo "ERROR: HTTP $http при запросе $path" >&2
    echo "$body" >&2
    return 1
  fi
  printf '%s' "$body"
}

# --- резолв user_id (кэшируется) ---
wm_user_id() {
  local cache="$CACHE_DIR/user_id"
  if [[ -s "$cache" ]]; then cat "$cache"; return; fi
  local uid
  uid=$(wm_get "/user/" | jq -r '.user_id')
  if [[ -z "$uid" || "$uid" == "null" ]]; then
    echo "ERROR: не удалось получить user_id" >&2; return 1
  fi
  echo "$uid" > "$cache"
  echo "$uid"
}

# --- резолв host_id (кэшируется); приоритет https-зеркала нужного домена ---
wm_host_id() {
  if [[ -n "${YANDEX_WEBMASTER_HOST_ID:-}" ]]; then echo "$YANDEX_WEBMASTER_HOST_ID"; return; fi
  local cache="$CACHE_DIR/host_id"
  if [[ -s "$cache" ]]; then cat "$cache"; return; fi
  local uid hid
  uid=$(wm_user_id)
  hid=$(wm_get "/user/$uid/hosts/" | jq -r --arg d "$HOST_DOMAIN" '
    [.hosts[] | select(.ascii_host_url | contains("//" + $d + "/"))]
    | (map(select(.host_id | startswith("https:"))) + .)
    | .[0].host_id // empty')
  if [[ -z "$hid" ]]; then
    echo "ERROR: домен $HOST_DOMAIN не найден среди подтверждённых сайтов (см. hosts.sh)" >&2
    return 1
  fi
  echo "$hid" > "$cache"
  echo "$hid"
}

# host_id с url-энкодингом двоеточий (для пути запроса)
wm_host_enc() { wm_host_id | sed 's/:/%3A/g'; }

# базовый префикс пути для хоста: /user/{uid}/hosts/{enc_host_id}
wm_host_base() {
  local uid hid
  uid=$(wm_user_id)
  hid=$(wm_host_enc)
  echo "/user/$uid/hosts/$hid"
}
