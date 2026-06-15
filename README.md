# my-claude-skills

Личный набор скиллов Claude Code в формате plugin-маркетплейса.
Один `git`-репозиторий → одна команда установки на любом сервере/машине.

Содержит **3 собственных скилла**:

| Скилл | Назначение | Что нужно для работы |
|-------|-----------|----------------------|
| `yandex-webmaster` | SEO-данные nacifrah.ru через Yandex Webmaster API v4 | OAuth-токен в `config/.env` |
| `yandex-wordstat` | Спрос и семантика через Yandex Wordstat API | Yandex Cloud `folder_id` + `api_key` в `config/config.json` |
| `scrapegraph-ai` | LLM-управляемый веб-скрапер (OpenAI + Playwright) | `OPENAI_API_KEY` в `config/.env` + Python venv |

> Секреты (`config/.env`, `config/config.json`, `cache/`, `.venv/`) в `.gitignore` — в репозиторий **не попадают**. На новой машине их нужно заполнить заново (см. ниже).

---

## 1. Установка скиллов из этого репо (на сервере)

Замени `YOUR_GH` на свой GitHub-аккаунт.

```
/plugin marketplace add YOUR_GH/my-claude-skills
/plugin install nacifrah-skills
```

Проверка: `/plugin` → плагин `nacifrah-skills` должен быть `enabled`.
Скиллы появятся как `yandex-webmaster`, `yandex-wordstat`, `scrapegraph-ai`.

### Пост-настройка (заполнить секреты на сервере)

Плагин ставится в `~/.claude/plugins/cache/.../nacifrah-skills/`. Перейди в его `skills/<skill>/config/` и заполни:

- **yandex-webmaster:** скопируй `config/.env.example` → `config/.env`, впиши `YANDEX_WEBMASTER_TOKEN`.
  Получить токен: `bash scripts/get_token.sh` (внутри скилла).
- **yandex-wordstat:** скопируй `config/config.example.json` → `config/config.json`, впиши `yandex_cloud_folder_id` и `auth.api_key`.
- **scrapegraph-ai:** скопируй `config/env.example` → `config/.env`, впиши `OPENAI_API_KEY`.
  Затем создай окружение: `python3 -m venv .venv && .venv/bin/pip install -r <реквайрментс>` (см. SKILL.md скилла) и установи браузер Playwright: `.venv/bin/playwright install chromium`.

---

## 2. Установка сторонних скиллов и плагинов (одним промтом)

Эти скиллы — НЕ мои, ставятся из оригинальных источников. Вставь весь блок ниже
одним сообщением в Claude Code на сервере — он выполнит все шаги по порядку.

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

> ⚠️ По п.4–5 я не могу гарантировать точный URL источника — промт просит Claude
> найти актуальный исходник и сверить имя скилла перед копированием. Если знаешь
> точный репозиторий — подставь его в промт.

---

## 3. Что НЕ входит и почему

- **frontend-design** — проектный скилл nacifrah.ru, уже лежит в git основного репозитория проекта (`.claude/skills/frontend-design`). Приедет вместе с `git clone` проекта.
- **MCP-серверы, API-ключи, OAuth-токены** — машинно-зависимы, переносятся отдельно (см. пост-настройку).
- **`settings.local.json` проекта** (permissions) — не в этом репо; копируется вручную при желании.
