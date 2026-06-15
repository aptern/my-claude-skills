#!/bin/bash
# Внешние ссылки на сайт.
#
#   links.sh           — динамика количества внешних ссылок + примеры доноров
#   links.sh --samples — только примеры внешних ссылок (до 100)
#   --from / --to YYYY-MM-DD — период истории (по умолчанию 30 дней)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SAMPLES_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --samples) SAMPLES_ONLY=1; shift ;;
    --from) DATE_FROM="$2"; shift 2 ;;
    --to) DATE_TO="$2"; shift 2 ;;
    *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
  esac
done

base=$(wm_host_base)

if [[ "$SAMPLES_ONLY" == "0" ]]; then
  echo "== Динамика внешних ссылок =="
  wm_get "$base/links/external/history/?date_from=$DATE_FROM&date_to=$DATE_TO&indicator=LINKS_TOTAL_COUNT" \
    | jq '.indicators.LINKS_TOTAL_COUNT | [.[] | {date: .date[0:10], links: .value}]'
fi

echo "== Примеры внешних ссылок =="
wm_get "$base/links/external/samples/?limit=100" \
  | jq '{count, links: [.links[] | {from: .source_url, to: .destination_url, discovered: .discovery_date}]}'
