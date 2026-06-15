#!/bin/bash
# Получение OAuth-токена Яндекса с правами Вебмастера.
#
# ВАЖНО про scopes: токен получает те права, что включены в OAuth-приложении.
# Чтобы был доступ к Вебмастеру, в приложении (oauth.yandex.ru) должны быть
# включены права «Яндекс.Вебмастер» (webmaster:hostinfo, webmaster:verify).
# Если их нет — добавьте в настройках приложения и перевыпустите токен.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config"
CACHE_DIR="$SCRIPT_DIR/../cache"
ENV_FILE="$CONFIG_DIR/.env"
mkdir -p "$CACHE_DIR"

CLIENT_ID=""
CLIENT_SECRET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-id|-i) CLIENT_ID="$2"; shift 2 ;;
    --client-secret|-s) CLIENT_SECRET="$2"; shift 2 ;;
    *) echo "Неизвестный флаг: $1"; exit 1 ;;
  esac
done

if [[ -z "$CLIENT_ID" ]]; then
  echo "Использование: get_token.sh --client-id <ID> [--client-secret <SECRET>]"
  echo ""
  echo "Создать/настроить приложение: https://oauth.yandex.ru/client/new"
  echo "В правах приложения включите «Яндекс.Вебмастер»."
  exit 1
fi

echo "=== Получение OAuth-токена (Webmaster) ==="
echo ""

if [[ -z "$CLIENT_SECRET" ]]; then
  echo "Шаг 1. Откройте в браузере:"
  echo ""
  echo "  https://oauth.yandex.ru/authorize?response_type=token&client_id=$CLIENT_ID"
  echo ""
  echo "Шаг 2. Подтвердите доступ."
  echo "Шаг 3. Из адреса редиректа скопируйте значение access_token:"
  echo "  https://oauth.yandex.ru/verification_code#access_token=ТОКЕН&..."
  echo ""
  echo -n "Вставьте токен: "
  read -r TOKEN
else
  echo "Шаг 1. Откройте в браузере:"
  echo ""
  echo "  https://oauth.yandex.ru/authorize?response_type=code&client_id=$CLIENT_ID"
  echo ""
  echo "Шаг 2. Подтвердите доступ и скопируйте код."
  echo ""
  echo -n "Вставьте код подтверждения: "
  read -r AUTH_CODE
  RESPONSE=$(curl -s -X POST "https://oauth.yandex.ru/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=authorization_code" -d "code=$AUTH_CODE" \
    -d "client_id=$CLIENT_ID" -d "client_secret=$CLIENT_SECRET")
  TOKEN=$(echo "$RESPONSE" | grep -o '"access_token":"[^"]*"' | sed 's/"access_token":"//;s/"//')
  if [[ -z "$TOKEN" ]]; then echo "Ошибка получения токена:"; echo "$RESPONSE"; exit 1; fi
fi

[[ -z "$TOKEN" ]] && { echo "Токен не введён"; exit 1; }

# Сохранить в .env
if [[ -f "$ENV_FILE" ]] && grep -q "^YANDEX_WEBMASTER_TOKEN=" "$ENV_FILE"; then
  sed -i.bak "s|^YANDEX_WEBMASTER_TOKEN=.*|YANDEX_WEBMASTER_TOKEN=$TOKEN|" "$ENV_FILE"
  rm -f "$ENV_FILE.bak"
else
  echo "YANDEX_WEBMASTER_TOKEN=$TOKEN" >> "$ENV_FILE"
fi
# Запомнить дату выпуска (для предупреждений о сроке) и сбросить кэш id
date +%Y-%m-%d > "$CACHE_DIR/token_saved"
rm -f "$CACHE_DIR/user_id" "$CACHE_DIR/host_id"

echo ""
echo "Токен сохранён в $ENV_FILE"
echo "Проверяю..."
echo ""
bash "$SCRIPT_DIR/check_token.sh"
