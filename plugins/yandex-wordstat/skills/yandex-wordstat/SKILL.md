---
name: yandex-wordstat
description: |
  Анализ поискового спроса через Yandex Wordstat API.
  Используй когда нужно: исследовать спрос, семантическое ядро,
  частотность запросов, сезонность или региональный спрос.
  Топ запросов (до 2000 строк в одном ответе), ассоциации, динамика, экспорт CSV.
  Следит за часовой квотой API (по умолчанию 100 запросов в час).
  Поиск упущенного спроса: анализ XLSX-выгрузки из Яндекс Директ,
  сегментация фраз, расширение семантики, сравнение OR-запросов.
  Triggers: упущенный спрос.
---

# yandex-wordstat

Analyze search demand and keyword statistics using Yandex Wordstat API.

## Config

Скилл поддерживает два бэкенда:

- **`cloud`** (рекомендуется) — Wordstat в Yandex Cloud Search API v2. Нужен `config.json` с `yandex_cloud_folder_id` и одним из способов входа: `auth.api_key` (API-ключ сервисного аккаунта) или `auth.service_account_key_file` (авторизованный JSON-ключ, IAM-токен скрипты получают сами).
- **`legacy`** (deprecated) — старый Wordstat OAuth API. Нужен `YANDEX_WORDSTAT_TOKEN` в `.env`. Новым пользователям Яндекс его не выдаёт.

**Где лежат настройки** (первое подходящее):
1. `$YANDEX_WORDSTAT_CONFIG_DIR`, если переменная задана;
2. `config/` внутри скилла, если там уже есть `config.json` или `.env`;
3. `~/.config/yandex-wordstat/` — постоянное место, переживает обновления плагина;
4. иначе — `config/` внутри скилла.

`bash scripts/quota.sh` печатает, какая папка используется (`config:`).

**Квота**: по умолчанию Яндекс даёт 100 запросов в час; квоту можно увеличить через поддержку Yandex Cloud — у автора согласовано 2 000 в час. Скилл сам считает свои запросы и не даёт превысить лимит из `config.json` → `"rate_limit_per_hour"` (по умолчанию 100). Как планировать работу под этот бюджет — раздел [«Квота и бюджет запросов»](#квота-и-бюджет-запросов).

**Auto-selection (cloud-first)**: cloud выигрывает на tie. Чтобы остаться на legacy явно — `YANDEX_WORDSTAT_BACKEND=legacy` в `.env`.

Полная инструкция по настройке и troubleshooting: [config/README.md](config/README.md).

**Миграция в облако**: удалите `YANDEX_WORDSTAT_TOKEN`, заполните `config.json` (API-ключ или JSON-ключ сервисного аккаунта). Команды и аргументы скриптов не меняются.

⚠️ **Cloud `dynamics` operator caveat**: при `--period weekly|monthly` cloud-бэкенд поддерживает только оператор `+`. Минус-слова, кавычки, группировки и точные формы работают только при `--period daily`. Скилл делает preflight-проверку и падает с понятной ошибкой до запроса. Подробнее — в README.

## Philosophy

1. **Skepticism to non-target demand** — high numbers don't mean quality traffic
2. **Creative semantic expansion** — think like a customer
3. **Always clarify region** — ask user for target region before analysis
4. **Show operators in reports** — include Wordstat operators for verification
5. **VERIFY INTENT via web search** — always check what people actually want to buy

## CRITICAL: Intent Verification

**Before marking ANY query as "target", verify intent via WebSearch!**

### The Problem

Query "каолиновая вата для дымохода" looks relevant for chimney seller, but:
- People search this to BUY COTTON WOOL, not chimneys
- They already HAVE a chimney and need insulation material
- This is NOT a target query for chimney sales!

### Verification Process

For every promising query, ASK YOURSELF:
1. **What does the person want to BUY?** (not just "what are they interested in")
2. **Will they buy OUR product from this search?**
3. **Or are they looking for something adjacent/complementary?**

### MANDATORY: Use WebSearch

**Always run WebSearch** to check:
```
WebSearch: "каолиновая вата для дымохода" что ищут покупатели
```

Look at search results:
- What products are shown?
- What questions do people ask?
- Is this informational or transactional intent?

### Red Flags (likely NOT target)

- Query contains "для [вашего продукта]" — they need ACCESSORY, not your product
- Query about materials/components — they DIY, not buy finished product
- Query has "своими руками", "как сделать" — informational, not buying
- Query about repair/maintenance — they already own it

### Examples

| Query | Looks like | Actually | Target? |
|-------|------------|----------|---------|
| каолиновая вата для дымохода | chimney buyer | cotton wool buyer | ❌ NO |
| дымоход купить | chimney buyer | chimney buyer | ✅ YES |
| утепление дымохода | chimney buyer | insulation DIYer | ❌ NO |
| дымоход сэндвич цена | chimney buyer | chimney buyer | ✅ YES |
| потерпевший дтп | lawyer client | news reader | ❌ NO |
| юрист после дтп | lawyer client | lawyer client | ✅ YES |

### Workflow Update

1. Find queries in Wordstat
2. **WebSearch each promising query to verify intent**
3. Mark as target ONLY if intent matches the sale
4. Report both target AND rejected queries with reasoning

## Workflow

### STOP! Before any analysis:

1. **ASK user about region and WAIT for answer:**
   ```
   "Для какого региона анализировать спрос?
   - Вся Россия (по умолчанию)
   - Москва и область
   - Конкретный город (какой?)"
   ```
   **НЕ ПРОДОЛЖАЙ пока пользователь не ответит!**

2. **ASK about business goal:**
   ```
   "Что именно вы продаёте/рекламируете?
   Это важно для фильтрации нецелевых запросов."
   ```

### After getting answers:

3. **Check the budget**: `bash scripts/quota.sh --budget` — бесплатно, без запроса к API.
   Живую проверку `bash scripts/quota.sh` (она тратит 1 запрос) делай только при первой
   настройке или после ошибки доступа.
4. **Estimate the number of API requests** for the plan and compare with what is left
   (see «Квота и бюджет запросов»). If the plan does not fit — tell the user BEFORE starting.
5. **Run analysis** using appropriate script
6. **Verify intent via WebSearch** for each promising query
7. **Present results** with target/non-target separation

## Scripts

### quota.sh
Hourly request budget and API connection check.
```bash
bash scripts/quota.sh --budget   # budget only: local counter, no API request, free
bash scripts/quota.sh            # live check: ONE real request, then backend info and budget
```

### top_requests.sh
Get top search phrases: up to 2000 result rows per call, CSV export.
Any `--limit` (1 or 2000) costs exactly one API request — rows are not the quota.
```bash
bash scripts/top_requests.sh \
  --phrase "юрист дтп" \
  --regions "213" \
  --devices "all"

# Extended: 500 results exported to CSV
bash scripts/top_requests.sh \
  --phrase "юрист дтп" \
  --limit 500 \
  --csv report.csv

# Max results with comma separator
bash scripts/top_requests.sh \
  --phrase "юрист дтп" \
  --limit 2000 \
  --csv full_report.csv \
  --sep ","
```

| Param | Required | Default | Values |
|-------|----------|---------|--------|
| `--phrase` | yes | - | text with operators |
| `--regions` | no | all | comma-separated IDs |
| `--devices` | no | all | all, desktop, phone, tablet |
| `--limit` | no | API default (50) | 1-2000 rows in the answer (API numPhrases; one request at any value) |
| `--csv` | no | - | path to output CSV file |
| `--sep` | no | ; | CSV separator (; for RU Excel) |

#### Result types: Top Requests vs Associations

The output contains two sections (both in stdout and CSV):

- **top** (`topRequests`) — queries that **contain the words** from your phrase, sorted by frequency. These are direct variations of the search query. Example: phrase "юрист дтп" → "юрист по дтп", "консультация юриста по дтп".
- **assoc** (`associations`) — queries **similar by meaning** but not necessarily containing the same words, sorted by similarity. These are semantically related searches. Example: phrase "юрист дтп" → "юридическая ответственность", "адвокат аварии".

**For analysis:** `top` results are your primary keyword pool. `assoc` results are useful for semantic expansion but often contain noise — always verify intent before including them.

#### CSV export details

CSV format: UTF-8 with BOM, columns: `n;phrase;impressions;type`.
When `--csv` is set, stdout shows first 20 rows per section; full data goes to file.

#### Working with large CSV exports

When `--limit` is set to a high value (e.g. 500-2000), use CSV export and read the file in chunks:
```bash
# Export 2000 rows (still one API request)
bash scripts/top_requests.sh --phrase "query" --limit 2000 --csv data.csv

# Read first 50 rows (header + data)
head -n 51 data.csv

# Read rows 51-100
tail -n +52 data.csv | head -50

# Count total rows
wc -l < data.csv

# Filter only associations
grep ";assoc$" data.csv
```

This approach lets the agent process large datasets without flooding stdout.

### dynamics.sh
Get search volume trends over time.
```bash
bash scripts/dynamics.sh \
  --phrase "юрист дтп" \
  --period "monthly" \
  --from-date "2025-01-01"
```

| Param | Required | Default | Values |
|-------|----------|---------|--------|
| `--phrase` | yes | - | text |
| `--period` | no | monthly | daily, weekly, monthly |
| `--from-date` | yes | - | YYYY-MM-DD |
| `--to-date` | no | today | YYYY-MM-DD |
| `--regions` | no | all | region IDs |
| `--devices` | no | all | all, desktop, phone, tablet |

### regions_stats.sh
Get regional distribution.
```bash
bash scripts/regions_stats.sh \
  --phrase "юрист дтп" \
  --region-type "cities"
```

| Param | Required | Default | Values |
|-------|----------|---------|--------|
| `--phrase` | yes | - | text |
| `--region-type` | no | all | cities, regions, all |
| `--devices` | no | all | all, desktop, phone, tablet |

### regions_tree.sh
Show common region IDs.
```bash
bash scripts/regions_tree.sh
```

### search_region.sh
Find region ID by name.
```bash
bash scripts/search_region.sh --name "Москва"
```

## Wordstat Operators

### Quotes `"query"`
Shows demand ONLY for this exact phrase (no additional words).

```
"юрист дтп" → "юрист дтп", "юристы дтп"
             but NOT "юрист по дтп"
```

### Exclamation `!word`
Fixes exact word form.

```
!юрист → "юрист по дтп", "юрист москва"
         but NOT "юристы", "юриста"
```

### Combination `"!word !word"`
Exact phrase + exact forms.

```
"!юрист !по !дтп" → only "юрист по дтп"
```

### Minus `-word`
Exclude queries with this word.

```
юрист дтп -бесплатно -консультация
```

### Grouping `(a|b|c)`
Multiple variants in one query.

```
(юрист|адвокат) дтп → combined demand
```

### Stop words
**Always fix prepositions with `!`:**

```
юрист !по дтп    ← correct
юрист по дтп     ← "по" ignored!
```

## Analysis Strategy

1. **Broad query**: `юрист дтп` — see total volume
2. **Narrow with quotes**: `"юрист дтп"` — exact phrase only
3. **Fix forms**: `"!юрист !по !дтп"` — exact match
4. **Clean with minus**: `юрист дтп -бесплатно -онлайн`
5. **Expand**: synonyms, related terms, client problems

## Popular Region IDs

| Region | ID |
|--------|-----|
| Россия | 225 |
| Москва | 213 |
| Москва и область | 1 |
| Санкт-Петербург | 2 |
| Екатеринбург | 54 |
| Новосибирск | 65 |
| Казань | 43 |

Run `bash scripts/regions_tree.sh` for full list.

## Квота и бюджет запросов

По умолчанию Яндекс даёт 100 запросов в час; квоту можно увеличить через поддержку Yandex Cloud — у автора согласовано 2 000 в час. Кроме часовой квоты — не больше 10 запросов в секунду; дневного лимита нет. Квота считается на облако. Запросы платные (кроме списка регионов): https://aistudio.yandex.ru/docs/ru/search-api/pricing. Лимиты: https://aistudio.yandex.ru/docs/ru/search-api/concepts/limits

«До 2000 строк» у `top_requests.sh --limit` — это размер одного ответа, а не квота: и `--limit 1`, и `--limit 2000` стоят один запрос.

### Как скилл бережёт квоту

Перед каждым запросом к API (и перед каждым повтором после 5xx / 429) скрипты берут слот у локального счётчика: скользящее окно 60 минут, файл `~/.local/state/yandex-wordstat/calls.log`.

- Лимит — `"rate_limit_per_hour"` в `config.json` (по умолчанию **100**). При увеличенной квоте впиши её туда, например `"rate_limit_per_hour": 2000`. Порядок, если значение задано в нескольких местах: переменная окружения `YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR` → она же строкой в `.env` рядом с `config.json` → `config.json` → 100. Откуда взят лимит — строка `Лимит:` в `quota.sh --budget`.
- Если до свободного слота не больше 60 секунд, скрипт ждёт сам (порог — `rate_limit_max_wait_sec` / `YANDEX_WORDSTAT_RATE_MAX_WAIT`).
- Иначе запрос **не отправляется**: в stderr — «Исчерпан часовой лимит запросов к Wordstat: N из N…» с временем до следующего слота, в stdout — `{"error":"local rate limit: …","code":429,"retry_after":<сек>}`, код выхода 1.
- Если Яндекс сам ответил 429 — скрипт пишет «Яндекс ответил 429…»: квоту облака расходует кто-то ещё (другие программы на том же каталоге) или лимит в `config.json` выше выданной квоты.

Счётчик видит только запросы этого скилла на этой машине.

### Сколько стоит каждый скрипт

| Скрипт | Запросов к API |
|---|---|
| `top_requests.sh` | 1 за вызов при любом `--limit` |
| `dynamics.sh` | 1 за вызов (несколько регионов через запятую — всё равно 1) |
| `regions_stats.sh` | 1 |
| `query_total.sh` | 1 |
| `quota.sh` | 1; `quota.sh --budget` — 0 |
| `regions_tree.sh`, `search_region.sh`, `missed_demand.py` | 0 |

Повтор после ошибки сервера или 429 «слишком часто» — ещё один запрос.

### Планирование под бюджет (обязательно)

1. **Перед анализом из нескольких фраз посчитай запросы**: фразы × отдельные регионы × методы. Пример: 8 фраз, топ + месячная динамика по Москве = 16 запросов. «Упущенный спрос»: минимум 2 запроса на группу (X и Y), плюс 1 на проверку мусора (шаг 8.1), плюс 1, если пришлось повторить без минус-фраз кампании.
2. **Узнай остаток**: `bash scripts/quota.sh --budget` → строка `Осталось:`.
3. **Назови пользователю оценку до запуска**: «План — около 16 запросов, в этом часе осталось 40».
4. **Если план больше остатка** — скажи об этом до первого запроса и предложи выбор: сократить и расставить приоритеты; укрупнить запросы; разбить работу по часам (скрипт показывает, когда освободится слот); если квота увеличена — вписать `rate_limit_per_hour` в `config.json`.
5. **Меньше запросов, но шире**:
   - один `top_requests.sh` по широкой фразе с `--limit 2000` даёт частотности до 2000 дочерних фраз — не запрашивай каждую из них отдельно;
   - суммарный спрос по группе синонимов — один OR-запрос `(a|b|c)`, а не по запросу на вариант;
   - «где ищут» — один `regions_stats.sh`, а не `top_requests.sh` по каждому городу;
   - динамику бери для 3–5 ключевых фраз, а не для всего ядра;
   - не повторяй уже сделанные запросы: сохраняй ответы (`--csv`, файлы) и переиспользуй их в сессии.
6. **Параллельные субагенты делят один часовой бюджет** (счётчик общий). Раздели остаток между ними до запуска.
7. **Получил «Исчерпан часовой лимит» или 429** — не повторяй в цикле. Остановись, покажи пользователю, что успели, сколько осталось и когда освободится слот.

### Настройки лимита

| Ключ в `config.json` | Переменная окружения | По умолчанию |
|---|---|---|
| `rate_limit_per_hour` | `YANDEX_WORDSTAT_RATE_LIMIT_PER_HOUR` | 100 (`0` — не ограничивать, только считать) |
| `rate_limit_per_second` | `YANDEX_WORDSTAT_RATE_LIMIT_PER_SECOND` | 10 |
| `rate_limit_max_wait_sec` | `YANDEX_WORDSTAT_RATE_MAX_WAIT` | 60 |
| — | `YANDEX_WORDSTAT_STATE_DIR` | `${XDG_STATE_HOME:-~/.local/state}/yandex-wordstat` |

## Example Session

```
User: Найди запросы для рекламы дымоходов

Claude: Для какого региона анализировать спрос?
        И уточните — вы продаёте готовые дымоходы или
        материалы для их изготовления/утепления?

User: Москва, продаём готовые сэндвич-дымоходы

Claude: [Запускает анализ для региона 213]

        Нашёл запросы. Проверяю интент через веб-поиск...

        ✅ ЦЕЛЕВЫЕ (покупают дымоходы):
        - "дымоход сэндвич купить" — 450 показов
        - "дымоход для бани цена" — 380 показов

        ❌ НЕ ЦЕЛЕВЫЕ (покупают другое):
        - "каолиновая вата для дымохода" — ищут утеплитель, не дымоход
        - "монтаж дымохода своими руками" — DIY, не покупатели
        - "чистка дымохода" — уже владеют, сервисный запрос
```

### Key Points

1. **ВСЕГДА спрашивай регион и жди ответа**
2. **ВСЕГДА уточняй что именно продаёт клиент**
3. **ВСЕГДА проверяй интент через WebSearch**
4. **Разделяй отчёт на целевые/нецелевые с объяснением**

## Расширенные сценарии

### Поиск упущенного спроса
Анализ рекламной кампании Яндекс Директ для нахождения фраз, не покрытых текущей семантикой.
Требования: XLSX-выгрузка из Яндекс Директ (лист «Тексты»).
Подробнее: [MISSED_DEMAND.md](references/MISSED_DEMAND.md)
