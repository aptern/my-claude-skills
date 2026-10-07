# my-claude-skills

Каталог плагинов Claude Code (plugin marketplace) агентства «НА ЦИФРАХ».
Название каталога для установки — **`nacifrah-skills`**.

| Плагин | Что внутри | Для кого |
|--------|-----------|----------|
| [`yandex-wordstat`](plugins/yandex-wordstat/) | Один скилл: спрос и семантика через Wordstat API (Yandex Cloud) | Для всех |
| `nacifrah-skills` | `yandex-webmaster`, `yandex-wordstat`, `scrapegraph-ai` | Личный набор автора: Вебмастер настроен на nacifrah.ru |

---

## Wordstat — установка в две команды

В Claude Code:

```
/plugin marketplace add aptern/my-claude-skills
/plugin install yandex-wordstat@nacifrah-skills
```

Дальше — доступ к API Яндекса, проверка и примеры запросов:
**[plugins/yandex-wordstat/README.md](plugins/yandex-wordstat/README.md)**.

### Квота Wordstat API

По умолчанию Яндекс даёт 100 запросов в час; квоту можно увеличить через поддержку
Yandex Cloud — у автора согласовано 2 000 в час. Скилл считает свои запросы и
держится лимита 100 в час; увеличенную квоту впишите в `config.json`:

```json
"rate_limit_per_hour": 2000
```

Подробно — в [config/README.md](plugins/yandex-wordstat/skills/yandex-wordstat/config/README.md#квота-и-лимит-запросов).
«До 2000 строк» в топе запросов — размер одного ответа, а не квота.

---

## Полный набор автора (`nacifrah-skills`)

```
/plugin marketplace add aptern/my-claude-skills
/plugin install nacifrah-skills@nacifrah-skills
```

Скиллы появятся как `nacifrah-skills:yandex-webmaster`, `nacifrah-skills:yandex-wordstat`,
`nacifrah-skills:scrapegraph-ai`. Ставить вместе с `yandex-wordstat` не нужно:
Wordstat в наборе уже есть.

### Настройка секретов

Секреты (`config/.env`, `config/config.json`, ключи, `cache/`, `.venv/`) в `.gitignore`
и в репозиторий не попадают.

Плагин ставится в `~/.claude/plugins/cache/nacifrah-skills/nacifrah-skills/<версия>/`.
При обновлении версии папка меняется, поэтому файлы, положенные внутрь, со старой
версией остаются в старой папке.

- **yandex-wordstat** — `config.json` кладите в `~/.config/yandex-wordstat/`
  (папка от версии не зависит). Формат и получение ключа — в
  [config/README.md](plugins/yandex-wordstat/skills/yandex-wordstat/config/README.md).
  Внутри плагина скилл лежит в `plugins/yandex-wordstat/skills/yandex-wordstat/`.
  Если квоту увеличили (у автора согласовано 2 000 в час), впишите своё значение:
  `"rate_limit_per_hour": 2000`. Без этой строки скилл ограничит себя квотой по
  умолчанию, 100 запросов в час.
  Если в версии 1.0.0 `config.json` лежал внутри папки плагина, скопируйте его в
  `~/.config/yandex-wordstat/`: новая версия старую папку не видит. Старый файл не
  удаляйте, пока его читают другие программы.
- **yandex-webmaster** — `skills/yandex-webmaster/config/.env` из `config/.env.example`,
  впишите `YANDEX_WEBMASTER_TOKEN`. Получить токен: `bash scripts/get_token.sh` (внутри скилла).
- **scrapegraph-ai** — `skills/scrapegraph-ai/config/.env` из `config/env.example`,
  впишите `OPENAI_API_KEY`. Затем окружение:
  `python3 -m venv .venv && .venv/bin/pip install -r <requirements>` (см. SKILL.md скилла)
  и браузер Playwright: `.venv/bin/playwright install chromium`.

После обновления `nacifrah-skills` секреты `yandex-webmaster` и `scrapegraph-ai` нужно
перенести из папки старой версии в новую.

---

## Устройство репозитория

```
.claude-plugin/marketplace.json      каталог: два плагина
.claude-plugin/plugin.json           плагин nacifrah-skills (корень репозитория)
skills/                              yandex-webmaster, scrapegraph-ai
plugins/yandex-wordstat/             отдельный плагин Wordstat
  .claude-plugin/plugin.json
  skills/yandex-wordstat/            сам скилл (одна копия на оба плагина)
  README.md, LICENSE (MIT, исходный автор — Александр Поляков)
```

`nacifrah-skills` подключает скилл Wordstat через `"skills": ["./plugins/yandex-wordstat/skills/"]`
в своём `plugin.json` — это дополнение к папке `skills/`, а не замена
([документация](https://code.claude.com/docs/en/plugins-reference)). Копий и символических
ссылок нет. Проверка: `claude plugin validate .`

---

## Сторонние скиллы и плагины (одним промтом)

Эти скиллы — не мои, ставятся из оригинальных источников. Вставьте блок ниже
одним сообщением в Claude Code — он выполнит шаги по порядку.

```
Установи на этой машине следующие плагины и скиллы Claude Code, по порядку, и в конце покажи /plugin и список скиллов для проверки:

1) superpowers (плагин, обязателен):
   /plugin marketplace add anthropics/claude-plugins-official
   /plugin install superpowers@claude-plugins-official

2) aaron-seo-geo (плагин, SEO/GEO):
   /plugin marketplace add https://github.com/aaron-he-zhu/seo-geo-claude-skills
   /plugin install aaron-seo-geo

3) claude-seo — пакет скиллов seo + seo-* (автор AgriciDaniel, MIT).
   Это НЕ плагин, а набор папок-скиллов. Склонируй репозиторий
   https://github.com/AgriciDaniel/claude-seo во временную папку и скопируй
   из него все скиллы (seo и все seo-*) в ~/.claude/skills/. Сначала прочитай
   README репозитория — там может быть свой установщик; если есть, используй его.

4) pptx (официальный скилл Anthropic для .pptx). Найди его в репозитории
   anthropics/skills (папка document-skills/pptx или skills/pptx) и скопируй
   папку pptx в ~/.claude/skills/pptx.

5) ui-ux-pro-max (community-скилл дизайна). Найди актуальный исходник скилла
   ui-ux-pro-max (GitHub) и скопируй папку в ~/.claude/skills/ui-ux-pro-max.
   Перед копированием сверь название скилла в его SKILL.md.

Для скиллов, которым нужны API-ключи/MCP-серверы, после установки выведи список
того, что осталось настроить (ключи, env, MCP-конфиг) — не вписывай ключи сам.
```

> По п. 4–5 точный адрес источника не гарантирован — промт просит Claude найти
> актуальный исходник и сверить имя скилла перед копированием.

---

## Что не входит и почему

- **frontend-design** — проектный скилл nacifrah.ru, лежит в git основного репозитория
  проекта (`.claude/skills/frontend-design`).
- **MCP-серверы, API-ключи, OAuth-токены** — зависят от машины, переносятся отдельно.
- **`settings.local.json` проекта** (разрешения) — копируется вручную при желании.
