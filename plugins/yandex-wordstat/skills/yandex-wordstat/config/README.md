# Настройка скилла Yandex Wordstat

Скилл ходит в Wordstat через **Yandex Cloud Search API v2**
(`searchapi.api.cloud.yandex.net/v2/wordstat/*`). Нужны каталог в Yandex Cloud,
сервисный аккаунт с ролью `search-api.webSearch.user` и один из двух ключей:

| Способ входа | Что положить в `config.json` | Когда выбирать |
|---|---|---|
| **API-ключ** (проще) | `auth.api_key` | Почти всегда. Не нужен OpenSSL, работает на macOS «из коробки» |
| **Авторизованный JSON-ключ** | `auth.service_account_key_file` | Если в организации запрещены API-ключи. IAM-токен скрипты получают и обновляют сами |

Старый Wordstat API (`api.wordstat.yandex.net/v1`, OAuth-токен) новым пользователям
не выдают. Его поддержка в скрипте осталась только для тех, у кого токен уже есть
(раздел «Legacy» в конце).

---

## Где хранить настройки

Скрипты ищут `config.json` и `.env` в первом подходящем месте:

1. папка из переменной `YANDEX_WORDSTAT_CONFIG_DIR`, если она задана;
2. `config/` внутри скилла — если там уже лежит `config.json` или `.env`;
3. **`~/.config/yandex-wordstat/`** — рекомендуемое место;
4. иначе `config/` внутри скилла.

Почему `~/.config/yandex-wordstat/`: плагин, поставленный через `/plugin install`,
лежит в папке с номером версии (`~/.claude/plugins/cache/.../<версия>/`). При
обновлении плагина появляется новая папка, и файлы, положенные в старую, скилл
больше не видит. Папка в `~/.config` от обновлений не зависит.

`bash scripts/quota.sh` печатает строку `config:` — какая папка реально используется.

---

## Настройка через API-ключ (рекомендуется)

### Шаг 1. Каталог и платёжный аккаунт

1. Откройте [консоль Yandex Cloud](https://console.yandex.cloud/) и войдите с Яндекс ID.
2. Подключите платёжный аккаунт — запросы к Wordstat платные
   ([тарифы](https://aistudio.yandex.ru/docs/ru/search-api/pricing); список регионов бесплатно).
3. Выберите или создайте **каталог** и скопируйте его ID (`b1g...`).

### Шаг 2. Сервисный аккаунт и роль

1. В каталоге: **Identity and Access Management → Сервисные аккаунты → Создать сервисный аккаунт**.
2. Имя — любое, например `wordstat-sa`.
3. Назначьте аккаунту роль **`search-api.webSearch.user`** на этот каталог.

### Шаг 3. API-ключ

1. Откройте сервисный аккаунт → **Создать новый ключ → Создать API-ключ**.
2. Область действия — **`yc.search-api.execute`** (укажите явно).
3. Скопируйте секретную часть ключа: консоль показывает её один раз.

То же через [CLI `yc`](https://yandex.cloud/ru/docs/cli/quickstart):

```bash
yc iam service-account create --name wordstat-sa
yc resource-manager folder add-access-binding <ID_каталога> \
  --role search-api.webSearch.user \
  --subject serviceAccount:<ID_сервисного_аккаунта>
yc iam api-key create --service-account-name wordstat-sa --scopes yc.search-api.execute
```

### Шаг 4. config.json

```bash
mkdir -p ~/.config/yandex-wordstat
chmod 700 ~/.config/yandex-wordstat
cat > ~/.config/yandex-wordstat/config.json <<'EOF'
{
  "yandex_cloud_folder_id": "b1g_ваш_ID_каталога",
  "auth": {
    "api_key": "ваш_API-ключ"
  }
}
EOF
chmod 600 ~/.config/yandex-wordstat/config.json
```

Шаблон того же файла — `config/config.example.json`. Вместо `auth.api_key` ключ
можно задать переменной `YANDEX_CLOUD_API_KEY` (в окружении или в `.env` рядом
с `config.json`).

### Шаг 5. Проверка

Из папки скилла:

```bash
bash scripts/quota.sh
```

Или попросите Claude: «Проверь подключение к Wordstat». Проверка делает один
настоящий запрос (распределение по регионам для слова «тест»). Успех выглядит так:

```
Wordstat API: OK
...
Backend: cloud (auto: config.json present)
  config:    /home/<вы>/.config/yandex-wordstat
  auth:      Api-Key (last 4: ...abcd)
```

---

## Вариант: авторизованный JSON-ключ (IAM)

Шаги 1–2 те же. Дальше:

1. Сервисный аккаунт → **Создать новый ключ → Создать авторизованный ключ** → скачайте JSON.
2. Сохраните его как `~/.config/yandex-wordstat/service_account_key.json`, `chmod 600`.
3. `config.json` (шаблон — `config/config.example.sa.json`):

   ```json
   {
     "yandex_cloud_folder_id": "b1g_ваш_ID_каталога",
     "auth": {
       "service_account_key_file": "service_account_key.json",
       "openssl_bin": "openssl"
     }
   }
   ```

Относительный путь к ключу ищется сначала от корня скилла, затем от папки с
`config.json`. Можно указать абсолютный путь или `~/...`.

Нужен OpenSSL 1.1.1+ (подпись JWT алгоритмом PS256). На macOS системный LibreSSL
не подходит: `brew install openssl@3` и `"openssl_bin": "/opt/homebrew/bin/openssl"`
(точный путь — `brew --prefix openssl`).

Если в `config.json` заданы оба способа, используется API-ключ.

---

## Dynamics: ограничение операторов

Метод `dynamics` (`scripts/dynamics.sh`) принимает все
[операторы Wordstat](https://yandex.ru/support/direct/keywords/symbols-and-operators.html)
**только при `--period daily`**. При `weekly` и `monthly` разрешён **только `+`** —
это ограничение Yandex Cloud
([документация](https://aistudio.yandex.ru/docs/ru/search-api/operations/wordstat-getdynamics.html)).
Скрипт проверяет фразу заранее и останавливается с понятной ошибкой, не тратя запрос.

| Фраза                  | daily | weekly / monthly |
|------------------------|-------|------------------|
| `юрист дтп`            | ✓     | ✓                |
| `юрист +по дтп`        | ✓     | ✓ (`+` разрешён) |
| `юрист -бесплатно`     | ✓     | ✗ (минус-слово)  |
| `"юрист дтп"`          | ✓     | ✗ (кавычки)      |
| `(юрист\|адвокат) дтп` | ✓     | ✗ (группировка)  |
| `!юрист`               | ✓     | ✗ (точная форма) |
| `санкт-петербург`      | ✓     | ✓ (дефис внутри слова) |
| `б/у дымоход`          | ✓     | ✓ (слэш)         |

---

## Квоты и стоимость

- 10 запросов в секунду и почасовая квота на облако; дневного лимита нет.
  По [документации](https://aistudio.yandex.ru/docs/ru/search-api/concepts/limits)
  на 05.10.2026 квота по умолчанию — 100 запросов в час; поднимается через поддержку.
- Каждый запуск `top_requests.sh`, `dynamics.sh`, `regions_stats.sh`, `quota.sh` — один платный
  запрос ([тарифы](https://aistudio.yandex.ru/docs/ru/search-api/pricing)).
  Запросы, завершившиеся ошибкой авторизации или сервера, не тарифицируются.

---

## Устранение ошибок

**`No Wordstat credentials found`** — скрипт не нашёл `config.json`. Посмотрите строку
`Config dir in use` в сообщении и положите файл туда или в `~/.config/yandex-wordstat/`.

**`... present but invalid: ... yandex_cloud_folder_id missing`** — не заполнен ID каталога.

**`... SA key file not found at resolved path`** — неверный путь в
`auth.service_account_key_file`. Укажите абсолютный путь.

**`Cloud Wordstat 401 Unauthorized`** — API-ключ отозван, скопирован не полностью или
создан без области `yc.search-api.execute`; для JSON-ключа — ключ повреждён или удалён.
Выпустите новый ключ.

**`Cloud Wordstat 403 Forbidden`** — у сервисного аккаунта нет роли
`search-api.webSearch.user` на этот каталог, либо в `config.json` указан ID другого каталога.

**`Cloud Wordstat HTTP 429`** — исчерпана почасовая квота. Подождите или попросите
поддержку Yandex Cloud увеличить квоту.

**`LibreSSL detected`** (macOS, только JSON-ключ) — см. выше про `openssl@3`
или перейдите на API-ключ.

**`Cloud Wordstat dynamics: ... only '+' operator is allowed`** — см. «Dynamics» выше.

---

## Legacy: старый OAuth API

Только для тех, у кого токен уже выдан. В `.env` в папке настроек:

```
YANDEX_WORDSTAT_TOKEN=ваш_токен
```

Если заданы и облачные настройки, и токен, используется облако. Принудительно
выбрать старый API: `YANDEX_WORDSTAT_BACKEND=legacy` в том же `.env`.
Получение токена по своему OAuth client_id: `bash scripts/get_token.sh --client-id <ID>`.
Срок жизни токена — 1 год.

---

## Ссылки

- [Wordstat в Search API](https://aistudio.yandex.ru/docs/ru/search-api/concepts/wordstat.html)
- [Квоты и лимиты](https://aistudio.yandex.ru/docs/ru/search-api/concepts/limits)
- [Тарифы](https://aistudio.yandex.ru/docs/ru/search-api/pricing)
- [Операторы Wordstat](https://yandex.ru/support/direct/keywords/symbols-and-operators.html)
