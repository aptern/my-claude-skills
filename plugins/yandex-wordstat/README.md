# Wordstat для Claude Code

Скилл для [Claude Code](https://code.claude.com/docs): Claude сам ходит в Wordstat
через официальный API Яндекса и разбирает спрос вместе с вами.

Что умеет:

- **Топ запросов и ассоциации** по фразе — до 2000 строк в ответе на один запрос
  (это размер выдачи, а не квота), выгрузка в CSV.
- **Динамика** спроса по дням, неделям или месяцам.
- **Регионы** — в каких городах и областях фразу ищут чаще всего (первые 30).
- **Поиск упущенного спроса** по XLSX-выгрузке кампании из Яндекс Директа: какие
  формулировки клиентов не покрыты текущими фразами групп.
- Перед тем как назвать запрос целевым, Claude уточняет регион и что вы продаёте,
  проверяет намерение по поисковой выдаче и показывает, что отбросил и почему.
- **Бережёт часовую квоту API**: считает свои запросы, заранее говорит, сколько их
  нужно на анализ, и не отправляет лишние, когда лимит исчерпан.

---

## Что нужно

- Claude Code в терминале или IDE.
- macOS или Linux; в системе — `bash`, `curl`, `python3`.
  На Windows — через WSL (не проверялось).
- Аккаунт Yandex Cloud с подключённым платёжным аккаунтом: запросы к Wordstat
  платные ([тарифы](https://aistudio.yandex.ru/docs/ru/search-api/pricing)).
- Для поиска упущенного спроса — [`uv`](https://docs.astral.sh/uv/) (ставит
  библиотеку для чтения XLSX сам).

---

## Установка

В Claude Code, двумя командами:

```
/plugin marketplace add aptern/my-claude-skills
/plugin install yandex-wordstat@nacifrah-skills
```

Затем перезапустите Claude Code или выполните `/reload-plugins`.

То же из обычного терминала:

```bash
claude plugin marketplace add aptern/my-claude-skills
claude plugin install yandex-wordstat@nacifrah-skills
```

`nacifrah-skills` — название каталога плагинов. В нём есть и одноимённый плагин
`nacifrah-skills` — это личный набор автора для его сайта, для Wordstat он не нужен.

### Вручную, без плагина

```bash
git clone https://github.com/aptern/my-claude-skills.git
mkdir -p ~/.claude/skills
cp -R my-claude-skills/plugins/yandex-wordstat/skills/yandex-wordstat ~/.claude/skills/
```

Скилл подхватится в следующей сессии Claude Code. Обновление — повторить
`git pull` и копирование.

---

## Доступ к Wordstat API

Коротко (подробно, с командами `yc` и вариантом через JSON-ключ — в
[skills/yandex-wordstat/config/README.md](skills/yandex-wordstat/config/README.md)):

1. [Консоль Yandex Cloud](https://console.yandex.cloud/) → войдите с Яндекс ID,
   подключите платёжный аккаунт.
2. Выберите каталог и скопируйте его ID (`b1g...`).
3. **Identity and Access Management → Сервисные аккаунты → Создать.** Назначьте
   аккаунту роль `search-api.webSearch.user` на этот каталог.
4. В сервисном аккаунте: **Создать новый ключ → Создать API-ключ**, область
   действия `yc.search-api.execute`. Скопируйте ключ — он показывается один раз.
5. Сохраните настройки:

   ```bash
   mkdir -p ~/.config/yandex-wordstat
   cat > ~/.config/yandex-wordstat/config.json <<'EOF'
   {
     "yandex_cloud_folder_id": "b1g_ваш_ID_каталога",
     "auth": { "api_key": "ваш_API-ключ" }
   }
   EOF
   chmod 600 ~/.config/yandex-wordstat/config.json
   ```

Папка `~/.config/yandex-wordstat/` не зависит от версии плагина, поэтому
настройки не пропадают при обновлении.

---

## Квота запросов

По умолчанию Яндекс даёт 100 запросов в час; квоту можно увеличить через поддержку
Yandex Cloud — у автора согласовано 2 000 в час. Плюс не больше 10 запросов в секунду,
дневного лимита нет.

Скилл считает свои запросы за последний час и держится лимита **100 в час**. Когда
лимит исчерпан, запрос не уходит: скрипт пишет, когда освободится слот (если ждать
меньше минуты — ждёт сам). Остаток без запроса к API: «Сколько осталось запросов
Wordstat в этом часе?» или `quota.sh --budget`.

Если вам увеличили квоту, добавьте строку в `config.json`:

```json
{
  "yandex_cloud_folder_id": "b1g_ваш_ID_каталога",
  "auth": { "api_key": "ваш_API-ключ" },
  "rate_limit_per_hour": 2000
}
```

Остальные настройки лимита (переменные окружения, ожидание слота) — в
[config/README.md](skills/yandex-wordstat/config/README.md#квота-и-лимит-запросов).

«До 2000 строк» в топе запросов — это размер одного ответа, а не квота: выгрузка
2000 строк стоит один запрос.

---

## Первая проверка

Попросите Claude: **«Проверь подключение к Wordstat»** — он запустит `scripts/quota.sh`.

Или сами:

```bash
# если ставили плагином
bash ~/.claude/plugins/cache/nacifrah-skills/yandex-wordstat/*/skills/yandex-wordstat/scripts/quota.sh
# если копировали вручную
bash ~/.claude/skills/yandex-wordstat/scripts/quota.sh
```

Должно быть `Wordstat API: OK`, а ниже — `config: …/.config/yandex-wordstat`
и остаток часового бюджета. Проверка делает один настоящий запрос; `quota.sh --budget`
показывает только остаток и в API не ходит.

---

## Примеры запросов

- «Собери спрос по фразе "дом из газобетона" в Санкт-Петербурге. Мы строим дома под ключ — раздели запросы на целевые и нецелевые.»
- «Покажи помесячную динамику запроса "купить квартиру в новостройке" по Петербургу с января 2025 года.»
- «В каких городах чаще всего ищут "каркасный дом"? Покажи первые 30 и подпиши названия городов.»
- «Выгрузи 1000 фраз по запросу "ремонт квартир" для Москвы в CSV (это один запрос к API) и сгруппируй их по смыслу.»
- «Вот выгрузка кампании из Директа: ~/Downloads/12345678.xlsx. Найди упущенный спрос по группам, начни с самой крупной.»

Claude сначала спросит регион и что именно вы продаёте — без этого
отделить целевые запросы от случайных нельзя.

---

## Если не работает

| Что видите | Что сделать |
|---|---|
| Claude не знает про Wordstat | `/plugin` → вкладка Installed: плагин должен быть включён. Затем `/reload-plugins` или перезапуск |
| `No Wordstat credentials found` | Нет `config.json`. Проверьте путь `~/.config/yandex-wordstat/config.json` |
| `Cloud Wordstat 401` | Ключ скопирован не полностью, отозван или создан без области `yc.search-api.execute` |
| `Cloud Wordstat 403` | У сервисного аккаунта нет роли `search-api.webSearch.user` на каталог, или в `config.json` ID другого каталога |
| `Исчерпан часовой лимит запросов к Wordstat` | Сработал счётчик скилла, запрос не отправлялся. Подождите время из сообщения. Если квота больше 100 в час — впишите `"rate_limit_per_hour"` в `config.json` |
| `Яндекс ответил 429` | Квоту облака исчерпал сам Яндекс: тот же каталог расходуют другие программы, или `rate_limit_per_hour` больше выданной квоты. По умолчанию Яндекс даёт 100 запросов в час; квоту можно увеличить через поддержку Yandex Cloud |
| `only '+' operator is allowed` | Для недельной и месячной динамики минус-слова, кавычки и `!` не работают. Уберите их или попросите дневную динамику |
| `uv: command not found` | Нужен только для упущенного спроса: [установите uv](https://docs.astral.sh/uv/getting-started/installation/) |

Обновить плагин: `claude plugin marketplace update nacifrah-skills`, затем
`claude plugin update yandex-wordstat@nacifrah-skills` и перезапуск.
Удалить: `claude plugin uninstall yandex-wordstat@nacifrah-skills`.

---

## Происхождение и лицензия

Скилл основан на `yandex-wordstat` Александра Полякова из репозитория
[artwist-polyakov/polyakov-claude-skills](https://github.com/artwist-polyakov/polyakov-claude-skills)
(версия от 09.04.2026, коммит `6acdf9c`), лицензия MIT — см. [LICENSE](LICENSE).

Изменения в этой сборке:

- вход по API-ключу сервисного аккаунта (`auth.api_key` или `YANDEX_CLOUD_API_KEY`);
- настройки в `~/.config/yandex-wordstat/`, чтобы переживать обновления плагина;
- описание квот и стоимости по текущей документации Яндекса;
- локальный счётчик запросов: скилл держится часовой квоты (по умолчанию 100 в час,
  настраивается `rate_limit_per_hour`) и планирует анализ под остаток;
- инструкция по настройке на русском.

У автора исходного скилла с тех пор вышли свои обновления с другим форматом настроек.
