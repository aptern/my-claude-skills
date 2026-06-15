#!/bin/bash
# Страницы, выпавшие из поиска, и события индекса.
#
#   excluded.sh           — последние события (появление/выпадение из поиска)
#   excluded.sh --removed — только выпавшие из поиска (REMOVED_FROM_SEARCH) + причина
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

REMOVED=0
[[ "${1:-}" == "--removed" ]] && REMOVED=1

base=$(wm_host_base)
raw=$(wm_get "$base/search-urls/events/samples/?limit=100")

if [[ "$REMOVED" == "1" ]]; then
  echo "$raw" | jq '{count, removed: [.samples[]
    | select(.event == "REMOVED_FROM_SEARCH")
    | {url, title, event_date: .event_date[0:10],
       reason: .excluded_url_status, bad_http_status, target_url}]}'
else
  echo "$raw" | jq '{count, events: [.samples[]
    | {url, title, event, event_date: .event_date[0:10],
       reason: .excluded_url_status, bad_http_status}]}'
fi
