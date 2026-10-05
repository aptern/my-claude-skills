# Сопроводительный промт — развёртывание скиллов на новом сервере

Вставь весь текст ниже (от строки «=== НАЧАЛО ПРОМТА ===» до «=== КОНЕЦ ПРОМТА ===»)
одним сообщением в Claude Code на новом сервере.

В самый конец, в раздел «КЛЮЧИ», вставь содержимое `key.md`.

---

=== НАЧАЛО ПРОМТА ===

Ты разворачиваешь рабочее окружение Claude Code на новом сервере. Выполни все шаги
по порядку, в конце выведи `/plugin` и список доступных скиллов для проверки. Где нужны
ключи — бери их из раздела «КЛЮЧИ» в самом низу этого сообщения. Сам ключи не придумывай.

## Шаг 1. Мои собственные скиллы (плагин-маркетплейс)

```
/plugin marketplace add aptern/my-claude-skills
/plugin install nacifrah-skills@nacifrah-skills
```

Плагин `yandex-wordstat` отдельно НЕ ставь — Wordstat уже входит в `nacifrah-skills`.

После установки настрой каждый скилл (плагин лежит в
`~/.claude/plugins/cache/nacifrah-skills/nacifrah-skills/<версия>/`):

1. **yandex-webmaster** — в `skills/yandex-webmaster/` создай `config/.env` из
   `config/.env.example` и впиши `YANDEX_WEBMASTER_TOKEN` и `YANDEX_WEBMASTER_HOST`
   из раздела КЛЮЧИ.
2. **yandex-wordstat** — создай `~/.config/yandex-wordstat/config.json` по образцу
   `plugins/yandex-wordstat/skills/yandex-wordstat/config/config.example.json`,
   впиши `yandex_cloud_folder_id` и `auth.api_key` из раздела КЛЮЧИ, `chmod 600`.
   Проверь: `bash <папка плагина>/plugins/yandex-wordstat/skills/yandex-wordstat/scripts/quota.sh`.
3. **scrapegraph-ai** — в `skills/scrapegraph-ai/` создай `config/.env` из `config/env.example` и впиши
   `OPENAI_API_KEY` из раздела КЛЮЧИ. Затем подготовь Python-окружение:
   `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`
   (если requirements.txt нет — посмотри зависимости в SKILL.md), и установи браузер:
   `.venv/bin/playwright install chromium`.

## Шаг 2. superpowers (плагин, обязателен)

```
/plugin marketplace add anthropics/claude-plugins-official
/plugin install superpowers@claude-plugins-official
```

## Шаг 3. aaron-seo-geo (плагин, SEO/GEO)

```
/plugin marketplace add https://github.com/aaron-he-zhu/seo-geo-claude-skills
/plugin install aaron-seo-geo
```

## Шаг 4. claude-seo — пакет скиллов `seo` + `seo-*` (автор AgriciDaniel, MIT)

Это НЕ плагин, а набор папок-скиллов. Склонируй
https://github.com/AgriciDaniel/claude-seo во временную папку, прочитай его README
(там может быть свой установщик — используй его, если есть), иначе скопируй из репозитория
скилл `seo` и все скиллы `seo-*` в `~/.claude/skills/`.

## Шаг 5. pptx (официальный скилл Anthropic для .pptx)

Найди скилл `pptx` в репозитории `anthropics/skills` (обычно `document-skills/pptx`
или `skills/pptx`) и скопируй папку в `~/.claude/skills/pptx`.

## Шаг 6. ui-ux-pro-max (community-скилл дизайна)

Найди актуальный исходник скилла `ui-ux-pro-max` на GitHub, сверь имя в его SKILL.md
и скопируй папку в `~/.claude/skills/ui-ux-pro-max`.

## Шаг 7. Проверка

Выведи `/plugin` (superpowers, aaron-seo-geo, nacifrah-skills должны быть enabled) и
перечисли все доступные скиллы. Если каким-то скиллам нужны ключи/MCP, которых нет
в разделе КЛЮЧИ — просто перечисли, что осталось настроить.

---

## КЛЮЧИ

<!-- Вставь сюда содержимое key.md -->


=== КОНЕЦ ПРОМТА ===
