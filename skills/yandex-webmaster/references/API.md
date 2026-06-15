# Yandex Webmaster API v4 — шпаргалка

База: `https://api.webmaster.yandex.net/v4`
Авторизация: заголовок `Authorization: OAuth <token>`
В пути `host_id` кодируется: `https:nacifrah.ru:443` → `https%3Anacifrah.ru%3A443`

## Базовые

| Метод | Назначение |
|---|---|
| `GET /user/` | → `{user_id}` |
| `GET /user/{uid}/hosts/` | список подтверждённых сайтов + `host_id`, `main_mirror` |
| `GET /user/{uid}/hosts/{hid}/summary/` | ИКС, кол-во страниц в поиске/исключённых, счётчик проблем |

## Диагностика

`GET …/{hid}/diagnostics/` → `{problems: {CODE: {severity, state, last_state_update}}}`

- **severity**: `FATAL` > `CRITICAL` > `POSSIBLE_PROBLEM` > `RECOMMENDATION`
- **state**: `PRESENT` (активна), `ABSENT` (нет), `UNDEFINED` (не проверено)

Частые коды: `SSL_CERTIFICATE_ERROR`, `DISALLOWED_IN_ROBOTS`, `MAIN_PAGE_ERROR`,
`URL_ALERT_4XX`/`5XX`, `SLOW_AVG_RESPONSE_TIME`, `DOCUMENTS_MISSING_TITLE`,
`DOCUMENTS_MISSING_DESCRIPTION`, `DUPLICATE_PAGES`, `NO_SITEMAPS`,
`SOFT_404`, `NO_METRIKA_COUNTER*`, `NOT_MOBILE_FRIENDLY`, `FAVICON_*`.

## Поисковые запросы

`GET …/{hid}/search-queries/popular/` — топ запросов.
Параметры: `order_by`=`TOTAL_SHOWS|TOTAL_CLICKS`; `query_indicator` (повторяемый) =
`TOTAL_SHOWS|TOTAL_CLICKS|AVG_SHOW_POSITION|AVG_CLICK_POSITION`;
`date_from`, `date_to`; `device_type_indicator`=`ALL|DESKTOP|MOBILE|TABLET`;
`limit` (≤500), `offset`.
→ `{count, queries:[{query_id, query_text, indicators:{…}}], date_from, date_to}`

`GET …/{hid}/search-queries/all/history/` — агрегированная динамика по дням.
Параметры: `query_indicator` (повторяемый), `date_from`, `date_to`, `device_type_indicator`.
→ `{indicators:{TOTAL_SHOWS:[{date,value}], TOTAL_CLICKS:[…]}}`

> Позиция: чем меньше число, тем выше в выдаче. CTR считаем сами = clicks/shows.

## Индексирование

`GET …/{hid}/indexing/history/` — обход роботом по HTTP-статусам.
Параметры: `indexing_indicator` (повторяемый) = `HTTP_2XX|HTTP_3XX|HTTP_4XX|HTTP_5XX`,
`date_from`, `date_to`. → `{indicators:{HTTP_2XX:[{date,value}], …}}`

`GET …/{hid}/search-urls/in-search/history/` — кол-во страниц в поиске по датам.
→ `{history:[{date, value}]}`

`GET …/{hid}/search-urls/in-search/samples/?limit=N` — примеры страниц в поиске.
→ `{count, samples:[{url, title, last_access}]}`

## События индекса (появление / выпадение)

`GET …/{hid}/search-urls/events/samples/?limit=N`
→ `{count, samples:[{url, title, event, event_date, excluded_url_status, bad_http_status, target_url}]}`
- **event**: `APPEARED_IN_SEARCH` | `REMOVED_FROM_SEARCH`
- **excluded_url_status** — причина исключения (для выпавших).

## Внешние ссылки

`GET …/{hid}/links/external/history/?indicator=LINKS_TOTAL_COUNT&date_from=&date_to=`
→ `{indicators:{LINKS_TOTAL_COUNT:[{date, value}]}}`

`GET …/{hid}/links/external/samples/?limit=N`
→ `{count, links:[{source_url, destination_url, discovery_date, source_last_access_date}]}`

## ИКС

`GET …/{hid}/sqi-history/?date_from=&date_to=` → `{points:[{date, value}]}` (может быть пусто).

## Прочее (не обёрнуто скриптами, при необходимости — вручную)

- `…/{hid}/sitemaps/` — список карт сайта
- `…/{hid}/recommended-queries/` — рекомендованные запросы
- `…/{hid}/turbo/…` — Турбо-страницы
- `…/{hid}/important-urls/` — мониторинг важных URL
- `…/{hid}/recrawl/queue/` — переобход страниц (POST)

Полная документация: https://yandex.ru/dev/webmaster/doc/dg/concepts/about.html
