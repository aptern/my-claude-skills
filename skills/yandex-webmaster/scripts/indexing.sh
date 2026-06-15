#!/bin/bash
# Индексирование: обход робота по HTTP-статусам + страницы в поиске.
#
#   indexing.sh            — динамика обхода (2xx/3xx/4xx/5xx) + история страниц в поиске
#   indexing.sh --samples  — примеры страниц, находящихся в поиске
#   --from / --to YYYY-MM-DD — период (по умолчанию 30 дней)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SAMPLES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --samples) SAMPLES=1; shift ;;
    --from) DATE_FROM="$2"; shift 2 ;;
    --to) DATE_TO="$2"; shift 2 ;;
    *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
  esac
done

base=$(wm_host_base)

if [[ "$SAMPLES" == "1" ]]; then
  wm_get "$base/search-urls/in-search/samples/?limit=100" \
    | jq '{in_search_count: .count,
        samples: [.samples[] | {url, title, last_access}]}'
else
  echo "== Обход роботом (по HTTP-статусам) =="
  wm_get "$base/indexing/history/?date_from=$DATE_FROM&date_to=$DATE_TO&indexing_indicator=HTTP_2XX&indexing_indicator=HTTP_3XX&indexing_indicator=HTTP_4XX&indexing_indicator=HTTP_5XX" \
    | jq '.indicators | to_entries | map({status: .key, total: ([.value[].value] | add)})'
  echo "== Страниц в поиске (история) =="
  wm_get "$base/search-urls/in-search/history/?date_from=$DATE_FROM&date_to=$DATE_TO" \
    | jq '.history | [.[] | {date: .date[0:10], pages: .value}]'
fi
