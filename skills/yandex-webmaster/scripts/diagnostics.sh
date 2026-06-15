#!/bin/bash
# Диагностика сайта: проблемы и их состояние.
# По умолчанию показывает только активные (state=PRESENT).
# Флаг --all — все проверки (включая ABSENT/UNDEFINED).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SHOW_ALL=0
[[ "${1:-}" == "--all" ]] && SHOW_ALL=1

base=$(wm_host_base)
raw=$(wm_get "$base/diagnostics/")

if [[ "$SHOW_ALL" == "1" ]]; then
  echo "$raw" | jq '[.problems | to_entries[] | {
    problem: .key, severity: .value.severity,
    state: .value.state, last_update: .value.last_state_update
  }] | sort_by(.state != "PRESENT", .severity)'
else
  echo "$raw" | jq '[.problems | to_entries[]
    | select(.value.state == "PRESENT")
    | {problem: .key, severity: .value.severity, since: .value.last_state_update}]
    | sort_by(.severity)'
fi
