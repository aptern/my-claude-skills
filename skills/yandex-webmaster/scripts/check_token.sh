#!/bin/bash
# Проверка токена: валидность (живой запрос к API) + предупреждение о сроке.
# Яндекс-токены живут ~1 год. Дата выпуска берётся из cache/token_saved.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# 1) Валидность — живой запрос
uid=$(wm_get "/user/" | jq -r '.user_id') || {
  echo "❌ Токен НЕвалиден или истёк. Перевыпустите: bash $SCRIPT_DIR/get_token.sh --client-id <CLIENT_ID>"
  exit 1
}
echo "✅ Токен рабочий (user_id: $uid)"

# 2) Срок жизни
META="$CACHE_DIR/token_saved"
if [[ -s "$META" ]]; then
  saved=$(cat "$META")
  echo "ℹ️  Токен сохранён: $saved"
  # возраст в днях (BSD/GNU)
  if saved_ts=$(date -j -f "%Y-%m-%d" "$saved" +%s 2>/dev/null); then :; \
  else saved_ts=$(date -d "$saved" +%s 2>/dev/null || echo ""); fi
  if [[ -n "$saved_ts" ]]; then
    now_ts=$(date +%s)
    age_days=$(( (now_ts - saved_ts) / 86400 ))
    echo "ℹ️  Возраст токена: $age_days дн."
    if (( age_days >= 330 )); then
      echo "⚠️  Токену больше 11 месяцев — скоро истечёт. Рекомендуется перевыпустить заранее."
    fi
  fi
else
  echo "ℹ️  Дата выпуска токена неизвестна (cache/token_saved отсутствует)."
fi
