#!/bin/sh
# Test the client-side rate limiter in common.sh: sliding-window counting,
# clock moved back, env/.env/config overrides, waiting vs refusing, HTTP 429
# handling, retries being counted, the old (legacy) API, an unwritable counter,
# the python3 and symlink lock fallbacks and the scripts' behaviour when the
# budget is used up. Fake clock (WORDSTAT_RATE_NOW) + fake sleep + fake curl:
# no network, no real waiting.

set -e

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SKILL_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
FIXTURES="$TESTS_DIR/fixtures"
ROOT="${TMPDIR:-/tmp}/wordstat_rate_test_$$"

cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT INT TERM
mkdir -p "$ROOT/bin"

NOW=1800000000
SLEEP_LOG="$ROOT/sleeps"
MOCK_DIR="$ROOT/mock"
STATE="$ROOT/state"
LOG="$STATE/calls.log"

# Isolated environment: nothing from the real config, state or quota settings
unset YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR YANDEX_WORDSTAT_RATE_LIMIT_PER_SECOND \
      YANDEX_WORDSTAT_RATE_MAX_WAIT YANDEX_WORDSTAT_STATE_DIR XDG_STATE_HOME \
      YANDEX_WORDSTAT_CONFIG_DIR YANDEX_WORDSTAT_BACKEND YANDEX_WORDSTAT_TOKEN \
      YANDEX_CLOUD_API_KEY WORDSTAT_RATE_LOCK WORDSTAT_RATE_MAX_LOOPS 2>/dev/null || true
WORDSTAT_SCRIPT_DIR="$SCRIPTS_DIR"
WORDSTAT_SKILL_DIR="$SKILL_DIR"
WORDSTAT_CONFIG_DIR="$ROOT/config"
WORDSTAT_CACHE_DIR="$ROOT/cache"
WORDSTAT_STATE_DIR="$STATE"
WORDSTAT_RATE_NOW="$NOW"
PATH="$ROOT/bin:$PATH"
export WORDSTAT_SCRIPT_DIR WORDSTAT_SKILL_DIR WORDSTAT_CONFIG_DIR WORDSTAT_CACHE_DIR \
       WORDSTAT_STATE_DIR WORDSTAT_RATE_NOW MOCK_DIR PATH

# shellcheck disable=SC1091
. "$SCRIPTS_DIR/common.sh"

# Fake sleep: log the duration and move the fake clock forward
_ws_sleep() {
    printf '%s\n' "$1" >> "$SLEEP_LOG"
    WORDSTAT_RATE_NOW=$((WORDSTAT_RATE_NOW + $1))
}

# Fake curl: counts calls, answers with the next status from $MOCK_DIR/statuses
# (the last one repeats) and the body from $MOCK_DIR/body_<status>.
cat > "$ROOT/bin/curl" <<'EOF'
#!/bin/sh
n=$(cat "$MOCK_DIR/count" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$MOCK_DIR/count"
out=""; fmt=""
while [ $# -gt 0 ]; do
    case $1 in
        -o) out="$2"; shift 2 ;;
        -w) fmt="$2"; shift 2 ;;
        *) shift ;;
    esac
done
status=$(sed -n "${n}p" "$MOCK_DIR/statuses")
[ -n "$status" ] || status=$(tail -n 1 "$MOCK_DIR/statuses")
if [ -n "$out" ]; then cat "$MOCK_DIR/body_$status" > "$out"; else cat "$MOCK_DIR/body_$status"; fi
[ -n "$fmt" ] && printf '%s' "$status"
exit 0
EOF
chmod +x "$ROOT/bin/curl"

reset() {
    rm -rf "$STATE" "$ROOT/config" "$MOCK_DIR" "$SLEEP_LOG"
    mkdir -p "$STATE" "$ROOT/config" "$MOCK_DIR"
    : > "$SLEEP_LOG"
    WORDSTAT_RATE_NOW="$NOW"
    WORDSTAT_BACKEND=""
    unset YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR YANDEX_WORDSTAT_RATE_LIMIT_PER_SECOND \
          YANDEX_WORDSTAT_RATE_MAX_WAIT WORDSTAT_RATE_LOCK WORDSTAT_RATE_MAX_LOOPS \
          YANDEX_WORDSTAT_TOKEN _ws_rl_hour_from_dotenv 2>/dev/null || true
}

# fill <count> <age_s>: <count> calls made <age_s> seconds before NOW
fill() {
    _f=0
    while [ "$_f" -lt "$1" ]; do
        echo $((NOW - $2)) >> "$LOG"
        _f=$((_f + 1))
    done
}

lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
curl_calls() { cat "$MOCK_DIR/count" 2>/dev/null || echo 0; }

check() {
    if [ "$2" = "$3" ]; then
        echo "  ok: $1"
    else
        echo "  FAIL: $1"
        echo "    want: $3"
        echo "    got:  $2"
        exit 1
    fi
}

contains() {
    case "$2" in
        *"$3"*) echo "  ok: $1" ;;
        *)
            echo "  FAIL: $1"
            echo "    expected to contain: $3"
            echo "    got: $2"
            exit 1
            ;;
    esac
}

use_cloud_mock() {
    WORDSTAT_BACKEND="cloud"
    WORDSTAT_CLOUD_FOLDER_ID="b1g-test-folder"
    WORDSTAT_CLOUD_API_KEY="TEST-KEY-0000"
}

# --- 1. Sliding window: entries older than one hour drop out ---------------
reset
fill 1 7200
fill 1 4000
fill 1 3600          # exactly one hour old → already outside the window
fill 2 3599
fill 3 10
check "peek counts only the last hour" "$(_ws_rate_try 100 10 0)" "OK 5"
check "old entries pruned from the state file" "$(lines "$LOG")" "5"
check "commit records the call" "$(_ws_rate_try 100 10 1)" "OK 5"
check "state file grows by one" "$(lines "$LOG")" "6"
check "recorded timestamp is now" "$(tail -n 1 "$LOG")" "$NOW"

# --- 2. Limit reached: wait time = when the oldest call leaves the window --
reset
fill 1 3000
fill 4 100
check "5/5 used → HOUR with wait 600 s" "$(_ws_rate_try 5 10 1)" "HOUR 600 5"
check "refused call is not recorded" "$(lines "$LOG")" "5"
# limit lowered below usage: wait for the (used - limit + 1)-th oldest
reset
fill 1 3500
fill 1 3400
fill 3 100
check "5 used, limit 4 → wait for the 2nd oldest" "$(_ws_rate_try 4 10 1)" "HOUR 200 5"

# --- 2b. Clock moved back: entries "from the future" count as now ----------
reset
fill 5 -7200         # recorded two hours ahead of the current clock
check "future entries: wait at most one hour" "$(_ws_rate_try 5 10 1)" "HOUR 3600 5"
check "future entries rewritten as now" "$(sort -u "$LOG")" "$NOW"
YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=5
out=$(print_rate_budget)
contains "budget with future entries: next slot within the hour" "$out" "через 60 мин 0 с"

# --- 3. Settings: default, config.json, env, .env, invalid -----------------
reset
_ws_rate_settings
check "default limit 100/h" "$_rl_per_hour|$_rl_per_second|$_rl_max_wait|$_rl_hour_src" "100|10|60|по умолчанию"

printf '%s\n' '{"rate_limit_per_hour": 2000, "rate_limit_per_second": 5, "rate_limit_max_wait_sec": 0}' > "$ROOT/config/config.json"
_ws_rate_settings
check "config.json overrides" "$_rl_per_hour|$_rl_per_second|$_rl_max_wait|$_rl_hour_src" "2000|5|0|config.json: rate_limit_per_hour"

printf '%s\n' '{"rate_limit_per_hour": "2 000"}' > "$ROOT/config/config.json"
_ws_rate_settings
check "config string \"2 000\" accepted" "$_rl_per_hour" "2000"

printf '%s\n' '{"rate_limit_per_hour": 2000}' > "$ROOT/config/config.json"
YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=7
_ws_rate_settings
check "env overrides config.json" "$_rl_per_hour|$_rl_hour_src" "7|переменная окружения YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR"
unset YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR

printf '%s\n' 'YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=55' 'YANDEX_WORDSTAT_RATE_MAX_WAIT=900' > "$ROOT/config/.env"
out=$(_load_env_file; _ws_rate_settings; printf '%s|%s|%s' "$_rl_per_hour" "$_rl_max_wait" "$_rl_hour_src")
check ".env next to config.json is honoured" "$out" "55|900|.env: YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR"
out=$(YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=50; YANDEX_WORDSTAT_RATE_MAX_WAIT=5
      _load_env_file; _ws_rate_settings
      printf '%s|%s|%s' "$_rl_per_hour" "$_rl_max_wait" "$_rl_hour_src")
check "process environment wins over .env" "$out" "50|5|переменная окружения YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR"
rm -f "$ROOT/config/.env"

printf '%s\n' '{"rate_limit_per_hour": "сто"}' > "$ROOT/config/config.json"
if (_ws_rate_settings) >/dev/null 2>"$ROOT/err"; then
    echo "  FAIL: invalid limit must stop the script"; exit 1
fi
contains "invalid limit → clear error" "$(cat "$ROOT/err")" "Неверный лимит запросов в час: 'сто'"

printf '%s\n' '{"rate_limit_per_hour": -5}' > "$ROOT/config/config.json"
if (_ws_rate_settings) >/dev/null 2>&1; then
    echo "  FAIL: negative limit must stop the script"; exit 1
fi
echo "  ok: negative limit rejected"

# --- 4. Exhausted, long wait → refuse with a Russian explanation -----------
reset
YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=5
fill 1 3000
fill 4 100
if _ws_rate_acquire 2>"$ROOT/err"; then
    echo "  FAIL: acquire must refuse when the budget is used up"; exit 1
fi
err=$(cat "$ROOT/err")
contains "message: limit exhausted" "$err" "Исчерпан часовой лимит запросов к Wordstat: 5 из 5"
contains "message: wait time" "$err" "через 10 мин 0 с"
contains "message: default quota phrasing" "$err" "По умолчанию Яндекс даёт 100 запросов в час"
contains "message: how to raise the limit" "$err" '"rate_limit_per_hour": 2000'
check "no sleep for a long wait" "$(lines "$SLEEP_LOG")" "0"
check "refused call is not recorded" "$(lines "$LOG")" "5"
json=$(_ws_rate_error_json)
contains "error JSON has code 429" "$json" '"code":429'
contains "error JSON has retry_after" "$json" '"retry_after":600'

# --- 5. Exhausted, short wait → sleep, then go ahead -----------------------
reset
YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=5
fill 1 3590
fill 4 100
if ! _ws_rate_acquire 2>"$ROOT/err"; then
    echo "  FAIL: short wait must be absorbed"; cat "$ROOT/err"; exit 1
fi
check "slept exactly until the slot freed" "$(cat "$SLEEP_LOG")" "10"
contains "wait note on stderr" "$(cat "$ROOT/err")" "жду"
check "window after the wait: 4 old + 1 new" "$(lines "$LOG")" "5"

# max wait 0 → even a 10 s wait is refused
reset
YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=5
YANDEX_WORDSTAT_RATE_MAX_WAIT=0
fill 1 3590
fill 4 100
if _ws_rate_acquire 2>/dev/null; then
    echo "  FAIL: max wait 0 must refuse"; exit 1
fi
echo "  ok: max wait 0 refuses instead of sleeping"

# --- 6. Per-second cap -----------------------------------------------------
reset
fill 10 0
if ! _ws_rate_acquire 2>/dev/null; then
    echo "  FAIL: per-second cap must wait, not refuse"; exit 1
fi
check "10 calls this second → wait 1 s" "$(cat "$SLEEP_LOG")" "1"

# --- 7. Hourly limit 0 → no hourly cap, calls still counted ---------------
reset
YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=0
fill 500 100
if ! _ws_rate_acquire 2>/dev/null; then
    echo "  FAIL: limit 0 must not refuse"; exit 1
fi
check "limit 0: call recorded" "$(lines "$LOG")" "501"

# --- 7b. Counter folder not writable → warning, request goes, no raw errors -
reset
chmod 500 "$STATE"
if [ -w "$STATE" ]; then
    echo "  skip: unwritable counter folder — running as root"
else
    if ! _ws_rate_acquire 2>"$ROOT/err"; then
        chmod 700 "$STATE"
        echo "  FAIL: an unwritable counter must not block the request"; exit 1
    fi
    err=$(cat "$ROOT/err")
    contains "unwritable counter → explained" "$err" "Нет записи в папку счётчика запросов"
    contains "unwritable counter → says the limit is off" "$err" "лимит 100 в час не соблюдается"
    case "$err" in
        *"ermission denied"*|*"cannot create"*|*"an't create"*)
            chmod 700 "$STATE"
            echo "  FAIL: raw shell error leaked to stderr: $err"; exit 1 ;;
    esac
    echo "  ok: no raw shell errors"
    out=$(print_rate_budget 2>&1)
    contains "budget warns about the counter" "$out" "нет записи в папку счётчика"
fi
chmod 700 "$STATE"

# --- 7c. No slot after many attempts → refuse, do not send unrecorded ------
reset
fill 10 0
out=$(
    _ws_sleep() { :; }            # the clock never moves: per-second cap never clears
    WORDSTAT_RATE_MAX_LOOPS=3
    if _ws_rate_acquire 2>"$ROOT/err"; then echo "went"; else echo "refused"; _ws_rate_error_json; fi
)
contains "stuck limiter → refused" "$out" "refused"
contains "stuck limiter → error JSON with code 429" "$out" '"code":429'
contains "stuck limiter → explanation" "$(cat "$ROOT/err")" "запрос НЕ отправлен"
check "stuck limiter → nothing recorded" "$(lines "$LOG")" "10"

# --- 8. Symlink lock fallback (no flock), stale lock is taken over --------
reset
WORDSTAT_RATE_LOCK=symlink
ln -s "99999:$((NOW - 100))" "$STATE/calls.lock.ln"   # left behind 100 s ago
if ! _ws_rate_acquire 2>/dev/null; then
    echo "  FAIL: acquire with symlink lock"; exit 1
fi
check "symlink lock: stale lock taken over, call recorded" "$(lines "$LOG")" "1"
check "symlink lock: lock released" "$([ -L "$STATE/calls.lock.ln" ] && echo held || echo free)" "free"

# --- 9. wordstat_request refuses without touching the network -------------
reset
use_cloud_mock
YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=3
fill 3 100
echo 200 > "$MOCK_DIR/statuses"
cp "$FIXTURES/cloud-topRequests-response.json" "$MOCK_DIR/body_200"
out=$(wordstat_request topRequests '{"phrase":"тест"}' 2>"$ROOT/err")
contains "refused request → error JSON" "$out" '"error":"local rate limit'
contains "refused request → stderr explanation" "$(cat "$ROOT/err")" "Запрос НЕ отправлен"
check "refused request → curl not called" "$(curl_calls)" "0"

# --- 9b. Old API (legacy) goes through the same limiter --------------------
reset
WORDSTAT_BACKEND="legacy"
YANDEX_WORDSTAT_TOKEN="TEST-0000"
YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=3
fill 3 100
echo 200 > "$MOCK_DIR/statuses"
echo '{"topRequests":[]}' > "$MOCK_DIR/body_200"
out=$(wordstat_request topRequests '{"phrase":"тест"}' 2>"$ROOT/err")
contains "legacy refused → error JSON" "$out" '"code":429'
check "legacy refused → curl not called" "$(curl_calls)" "0"
contains "legacy refused → legacy wording" "$(cat "$ROOT/err")" "Старый Wordstat API (legacy)"
case "$(cat "$ROOT/err")" in
    *"Yandex Cloud"*) echo "  FAIL: legacy message must not send the user to Yandex Cloud"; exit 1 ;;
esac
echo "  ok: legacy message does not mention Yandex Cloud"
YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=4
out=$(wordstat_request topRequests '{"phrase":"тест"}' 2>/dev/null)
contains "legacy with budget → request goes out" "$out" '"topRequests"'
check "legacy with budget → one HTTP call" "$(curl_calls)" "1"
check "legacy with budget → call recorded" "$(lines "$LOG")" "4"

# --- 10. Every attempt is counted, retries included ------------------------
reset
use_cloud_mock
printf '503\n503\n200\n' > "$MOCK_DIR/statuses"
echo '{"code":14,"message":"unavailable"}' > "$MOCK_DIR/body_503"
cp "$FIXTURES/cloud-topRequests-response.json" "$MOCK_DIR/body_200"
wordstat_request topRequests '{"phrase":"тест"}' > "$ROOT/out" 2>"$ROOT/err"
contains "retried request succeeds" "$(cat "$ROOT/out")" '"topRequests"'
check "3 HTTP attempts" "$(curl_calls)" "3"
check "3 attempts recorded in the window" "$(lines "$LOG")" "3"
check "backoff goes through _ws_sleep" "$(tr '\n' ' ' < "$SLEEP_LOG")" "2 4 "

# --- 11. HTTP 429 hourly quota → no retry, clear message, error JSON ------
reset
use_cloud_mock
echo 429 > "$MOCK_DIR/statuses"
echo '{"code":8,"message":"wordstatRequestsPerHour.rate rate quota limit exceed"}' > "$MOCK_DIR/body_429"
wordstat_request topRequests '{"phrase":"тест"}' > "$ROOT/out" 2>"$ROOT/err"
contains "429 → error JSON with code" "$(cat "$ROOT/out")" '"code":429'
contains "429 → explanation" "$(cat "$ROOT/err")" "исчерпана почасовая квота Wordstat"
contains "429 → default quota phrasing" "$(cat "$ROOT/err")" "По умолчанию Яндекс даёт 100 запросов в час"
contains "429 → error JSON names the hourly quota" "$(cat "$ROOT/out")" "Wordstat hourly quota exceeded"
check "429 hourly → no retry" "$(curl_calls)" "1"

# unrecognised 429 body: one retry, then a plain message; long body cut by characters
reset
use_cloud_mock
echo 429 > "$MOCK_DIR/statuses"
python3 -c 'import sys
sys.stdout.buffer.write(("{\"message\":\"" + "ж" * 400 + "\"}\n").encode("utf-8"))' > "$MOCK_DIR/body_429"
wordstat_request topRequests '{"phrase":"тест"}' > "$ROOT/out" 2>"$ROOT/err"
check "429 unknown → one retry" "$(curl_calls)" "2"
check "429 unknown → error JSON" "$(cat "$ROOT/out")" '{"error":"HTTP 429 Too Many Requests: Wordstat quota exceeded","code":429}'
# strict UTF-8 decode fails (empty output) if a character was cut in half
body_len=$(grep 'Ответ Яндекса: ' "$ROOT/err" | python3 -c 'import sys
line = sys.stdin.buffer.read().decode("utf-8").rstrip("\n")
print(len(line.split(": ", 1)[1]))' 2>/dev/null || :)
check "429 body cut to 300 characters, valid UTF-8" "$body_len" "300"

# --- 12. HTTP 429 per-second → backoff and retry ---------------------------
reset
use_cloud_mock
printf '429\n200\n' > "$MOCK_DIR/statuses"
echo '{"code":8,"message":"too many requests per second"}' > "$MOCK_DIR/body_429"
cp "$FIXTURES/cloud-topRequests-response.json" "$MOCK_DIR/body_200"
wordstat_request topRequests '{"phrase":"тест"}' > "$ROOT/out" 2>"$ROOT/err"
contains "429 per-second → retried and succeeded" "$(cat "$ROOT/out")" '"topRequests"'
check "429 per-second → 2 attempts counted" "$(lines "$LOG")" "2"

# --- 13. Scripts end-to-end: budget used up → exit 1, error on stdout ------
reset
printf '%s\n' '{"yandex_cloud_folder_id":"b1g-test","auth":{"api_key":"TEST-KEY-0000"},"rate_limit_per_hour":3}' \
    > "$ROOT/config/config.json"
fill 3 100
echo 200 > "$MOCK_DIR/statuses"
cp "$FIXTURES/cloud-topRequests-response.json" "$MOCK_DIR/body_200"

rc=0
sh "$SCRIPTS_DIR/top_requests.sh" --phrase "тест" > "$ROOT/out" 2>"$ROOT/err" || rc=$?
check "top_requests.sh exits 1" "$rc" "1"
contains "top_requests.sh prints the error" "$(cat "$ROOT/out")" '"code":429'
contains "top_requests.sh explains on stderr" "$(cat "$ROOT/err")" "Исчерпан часовой лимит"

rc=0
bash "$SCRIPTS_DIR/dynamics.sh" --phrase "тест" --from-date 2025-01-01 > "$ROOT/out" 2>"$ROOT/err" || rc=$?
check "dynamics.sh exits 1" "$rc" "1"
contains "dynamics.sh prints the error" "$(cat "$ROOT/out")" "rate limit"

rc=0
bash "$SCRIPTS_DIR/regions_stats.sh" --phrase "тест" > "$ROOT/out" 2>"$ROOT/err" || rc=$?
check "regions_stats.sh exits 1" "$rc" "1"

# missed demand: query_total.sh → missed_demand.py query-total. A uv shim runs
# the script with plain python3 (query-total does not import openpyxl), so the
# test needs neither uv nor network.
cat > "$ROOT/bin/uv" <<'EOF'
#!/bin/sh
[ "$1" = "run" ] && [ "$2" = "--script" ] || exit 99
shift 2
exec python3 "$@"
EOF
chmod +x "$ROOT/bin/uv"
rc=0
sh "$SCRIPTS_DIR/query_total.sh" --phrase "тест" > "$ROOT/out" 2>"$ROOT/err" || rc=$?
rm -f "$ROOT/bin/uv"
check "query_total.sh exits 1" "$rc" "1"
contains "query_total.sh prints the error" "$(cat "$ROOT/out")" 'local rate limit'
contains "query_total.sh explains on stderr" "$(cat "$ROOT/err")" "Исчерпан часовой лимит"
check "scripts made no HTTP calls" "$(curl_calls)" "0"

# quota.sh without options: the counter refuses → says so, shows the budget
rc=0
sh "$SCRIPTS_DIR/quota.sh" > "$ROOT/out" 2>"$ROOT/err" || rc=$?
check "quota.sh exits 1 when the budget is used up" "$rc" "1"
contains "quota.sh: check not run, API not contacted" "$(cat "$ROOT/out")" "Проверка не выполнена: исчерпан часовой лимит скилла"
contains "quota.sh: budget shown" "$(cat "$ROOT/out")" "Осталось:           0"
if grep -q 'Wordstat API: Error' "$ROOT/out"; then
    echo "  FAIL: a local refusal must not look like a broken API"; exit 1
fi
echo "  ok: no 'Wordstat API: Error' on a local refusal"
check "quota.sh made no HTTP call" "$(curl_calls)" "0"

# quota.sh --budget: no API call, shows what is left
out=$(sh "$SCRIPTS_DIR/quota.sh" --budget)
contains "budget: limit from config.json" "$out" "3 в час (config.json: rate_limit_per_hour)"
contains "budget: nothing left" "$out" "Осталось:           0"
contains "budget: next slot" "$out" "через 58 мин 20 с"
check "quota.sh --budget made no HTTP call" "$(curl_calls)" "0"

# .env beats config.json, a one-off environment variable beats .env
printf '%s\n' 'YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=2000' > "$ROOT/config/.env"
out=$(sh "$SCRIPTS_DIR/quota.sh" --budget)
contains "budget: limit from .env" "$out" "2000 в час (.env: YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR)"
out=$(YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=50 sh "$SCRIPTS_DIR/quota.sh" --budget)
contains "budget: one-off env var wins over .env" "$out" "50 в час (переменная окружения YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR)"
rm -f "$ROOT/config/.env"

# quota.sh --budget works without any credentials
reset
fill 37 60
out=$(sh "$SCRIPTS_DIR/quota.sh" --budget)
contains "budget without config: default 100/h" "$out" "100 в час (по умолчанию)"
contains "budget without config: 63 left" "$out" "Осталось:           63"

# --- 14. Concurrency: 20 parallel processes, limit 10 → exactly 10 go ahead -
race() {
    _label="$1"
    reset
    WORDSTAT_RATE_LOCK="$_label"
    export WORDSTAT_RATE_LOCK
    YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR=10
    YANDEX_WORDSTAT_RATE_LIMIT_PER_SECOND=0
    YANDEX_WORDSTAT_RATE_MAX_WAIT=0
    export YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR YANDEX_WORDSTAT_RATE_LIMIT_PER_SECOND YANDEX_WORDSTAT_RATE_MAX_WAIT
    _r=0
    while [ "$_r" -lt 20 ]; do
        "${TEST_SHELL:-sh}" -c '. "$WORDSTAT_SCRIPT_DIR/common.sh"
               if _ws_rate_acquire 2>/dev/null; then echo ok; else echo no; fi' >> "$ROOT/race_$_label" &
        _r=$((_r + 1))
    done
    wait
    check "race ($_label lock): 10 of 20 go ahead" "$(grep -c '^ok$' "$ROOT/race_$_label")" "10"
    check "race ($_label lock): 10 calls recorded" "$(lines "$LOG")" "10"
    unset YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR YANDEX_WORDSTAT_RATE_LIMIT_PER_SECOND \
          YANDEX_WORDSTAT_RATE_MAX_WAIT WORDSTAT_RATE_LOCK
}
if command -v flock >/dev/null 2>&1; then
    race flock
else
    echo "  skip: race (flock lock) — flock not installed"
fi
race python          # what macOS uses: flock(2) via python3
race symlink

echo "test_rate_limit: all passed"
