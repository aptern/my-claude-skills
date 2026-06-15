#!/bin/bash
# История ИКС (индекс качества сайта).
#   --from / --to YYYY-MM-DD — период (по умолчанию весь доступный)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) DATE_FROM="$2"; shift 2 ;;
    --to) DATE_TO="$2"; shift 2 ;;
    *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
  esac
done

base=$(wm_host_base)
wm_get "$base/sqi-history/?date_from=$DATE_FROM&date_to=$DATE_TO" \
  | jq '{points: [.points[] | {date: .date[0:10], sqi: .value}]} | if (.points|length)==0 then {points: [], note: "нет данных ИКС за период"} else . end'
