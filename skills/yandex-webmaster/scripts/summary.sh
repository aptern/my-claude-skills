#!/bin/bash
# Единый SEO-срез сайта: сводка + активные проблемы + индекс + топ-запросы + ссылки.
# Выводит читаемый дайджест. Для глубокого разбора используйте отдельные скрипты.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

base=$(wm_host_base)
host=$(wm_host_id)

echo "════════════════════════════════════════════════"
echo " SEO-срез: $host"
echo " Период запросов: $DATE_FROM … $DATE_TO"
echo "════════════════════════════════════════════════"

echo
echo "── Сводка ──"
wm_get "$base/summary/" | jq -r '
  "ИКС: \(.sqi)",
  "Страниц в поиске: \(.searchable_pages_count)",
  "Исключено страниц: \(.excluded_pages_count)",
  "Проблем сайта: \(.site_problems | to_entries | map("\(.key)=\(.value)") | join(", ") // "нет")"'

echo
echo "── Активные проблемы (state=PRESENT) ──"
wm_get "$base/diagnostics/" | jq -r '
  [.problems | to_entries[] | select(.value.state=="PRESENT")] as $p
  | if ($p|length)==0 then "нет активных проблем ✅"
    else ($p[] | "[\(.value.severity)] \(.key)  (с \(.value.last_state_update[0:10]))") end'

echo
echo "── Страниц в поиске (последние точки) ──"
wm_get "$base/search-urls/in-search/history/?date_from=$DATE_FROM&date_to=$DATE_TO" \
  | jq -r '.history[-3:][]? | "\(.date[0:10]): \(.value)"'

echo
echo "── Запросы за период (агрегат) ──"
wm_get "$base/search-queries/all/history/?query_indicator=TOTAL_SHOWS&query_indicator=TOTAL_CLICKS&date_from=$DATE_FROM&date_to=$DATE_TO" \
  | jq -r '"Показы: \([.indicators.TOTAL_SHOWS[].value]|add)  Клики: \([.indicators.TOTAL_CLICKS[].value]|add)"'

echo
echo "── Топ-10 запросов по показам ──"
wm_get "$base/search-queries/popular/?order_by=TOTAL_SHOWS&query_indicator=TOTAL_SHOWS&query_indicator=TOTAL_CLICKS&query_indicator=AVG_SHOW_POSITION&date_from=$DATE_FROM&date_to=$DATE_TO&limit=10" \
  | jq -r '.queries[] | "\(.indicators.TOTAL_SHOWS|floor) показ. · \(.indicators.TOTAL_CLICKS|floor) клик. · поз.\(.indicators.AVG_SHOW_POSITION|.*10|round|./10) — \(.query_text)"'

echo
echo "── Внешние ссылки ──"
wm_get "$base/links/external/samples/?limit=100" | jq -r '"Всего доноров (примеры): \(.count)"'

echo
echo "════════════════════════════════════════════════"
echo " Детали: diagnostics.sh --all | search_queries.sh | indexing.sh | excluded.sh --removed | links.sh | sqi.sh"
