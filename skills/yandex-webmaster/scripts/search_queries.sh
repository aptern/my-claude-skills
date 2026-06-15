#!/bin/bash
# Поисковые запросы: показы, клики, CTR, средняя позиция.
#
# Использование:
#   search_queries.sh [--order TOTAL_SHOWS|TOTAL_CLICKS] [--limit N]
#                     [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--history]
#
#   (без флагов)   — топ запросов по показам за последние 30 дней
#   --history      — агрегированная динамика показов/кликов по дням
#   --device ALL|DESKTOP|MOBILE|TABLET  — фильтр по типу устройства (по умолчанию ALL)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ORDER="TOTAL_SHOWS"
LIMIT=30
DEVICE="ALL"
HISTORY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --order)  ORDER="$2"; shift 2 ;;
    --limit)  LIMIT="$2"; shift 2 ;;
    --from)   DATE_FROM="$2"; shift 2 ;;
    --to)     DATE_TO="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --history) HISTORY=1; shift ;;
    *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
  esac
done

base=$(wm_host_base)

if [[ "$HISTORY" == "1" ]]; then
  wm_get "$base/search-queries/all/history/?query_indicator=TOTAL_SHOWS&query_indicator=TOTAL_CLICKS&date_from=$DATE_FROM&date_to=$DATE_TO&device_type_indicator=$DEVICE" \
    | jq '{period: {from: "'"$DATE_FROM"'", to: "'"$DATE_TO"'"}, device: "'"$DEVICE"'",
        total_shows: ([.indicators.TOTAL_SHOWS[].value] | add),
        total_clicks: ([.indicators.TOTAL_CLICKS[].value] | add),
        daily: [range(0; (.indicators.TOTAL_SHOWS|length)) as $i
                | {date: .indicators.TOTAL_SHOWS[$i].date[0:10],
                   shows: .indicators.TOTAL_SHOWS[$i].value,
                   clicks: .indicators.TOTAL_CLICKS[$i].value}]}'
else
  wm_get "$base/search-queries/popular/?order_by=$ORDER&query_indicator=TOTAL_SHOWS&query_indicator=TOTAL_CLICKS&query_indicator=AVG_SHOW_POSITION&query_indicator=AVG_CLICK_POSITION&date_from=$DATE_FROM&date_to=$DATE_TO&device_type_indicator=$DEVICE&limit=$LIMIT" \
    | jq '{period: {from: .date_from, to: .date_to}, device: "'"$DEVICE"'", count,
        queries: [.queries[] | {
          query: .query_text,
          shows: .indicators.TOTAL_SHOWS,
          clicks: .indicators.TOTAL_CLICKS,
          ctr: (if (.indicators.TOTAL_SHOWS // 0) > 0
                then ((.indicators.TOTAL_CLICKS // 0) / .indicators.TOTAL_SHOWS * 100 | .*100|round|./100)
                else 0 end),
          avg_show_pos: .indicators.AVG_SHOW_POSITION,
          avg_click_pos: .indicators.AVG_CLICK_POSITION
        }]}'
fi
