#!/bin/sh
# Check Yandex Wordstat API connection (backend-aware) and the hourly request budget.
#
#   sh scripts/quota.sh            — live check: ONE real API request, then the budget
#   sh scripts/quota.sh --budget   — budget only, from the local counter: no API request,
#                                    no credentials needed

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

MODE="check"
while [ $# -gt 0 ]; do
    case $1 in
        --budget|-b) MODE="budget"; shift ;;
        --help|-h)
            echo "Usage: quota.sh [--budget]"
            echo ""
            echo "  (no options)   check the API connection with one real request, then show the budget"
            echo "  --budget, -b   show the hourly request budget only (local counter, no API request)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$MODE" = "budget" ]; then
    # .env may hold YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR; credentials are not needed here
    _load_env_file
    print_rate_budget
    exit 0
fi

load_config

echo "Checking Wordstat API connection (1 request)..."
echo ""

# Test with a simple regions request
response=$(wordstat_request "regions" '{"phrase":"тест"}')

if echo "$response" | grep -q '"regions"'; then
    echo "Wordstat API: OK"
    echo ""

    # Count regions in response
    region_count=$(echo "$response" | grep -o '"regionId"' | wc -l | tr -d ' ')
    echo "Test query 'тест' returned data for $region_count regions"
else
    case "$response" in
        *'local rate limit'*)
            # The skill's own counter refused: the API was not contacted at all
            echo "Проверка не выполнена: исчерпан часовой лимит скилла (запрос к API не отправлялся)."
            echo ""
            print_rate_budget
            exit 1
            ;;
    esac
    echo "Wordstat API: Error"
    echo "$response"
    exit 1
fi

echo ""
print_backend_info
echo ""
print_rate_budget
echo ""
echo "Token/credentials are valid and API is accessible."
