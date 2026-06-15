---
name: scrapegraph-ai
description: |
  LLM-управляемый веб-скрапер на базе ScrapeGraphAI.
  Используй когда нужно: извлечь структурированные данные с произвольной
  веб-страницы по текстовому промпту, спарсить каталог/карточки/статьи,
  превратить HTML/локальный файл в JSON, обойти много страниц одной
  поисковой задачей, преобразовать страницу в чистый Markdown.
  Под капотом: OpenAI gpt-4o-mini (по умолчанию) + Playwright/Chromium.
  Triggers: scrapegraph, скрап, спарсить сайт, спарси страницу,
  извлечь данные с сайта, scrape url, web scraping.
---

# ScrapeGraphAI skill

Локальная установка ScrapeGraphAI с обёрткой-CLI, чтобы вызывать скрапер
напрямую из Claude Code.

## Расположение

- Skill root: `~/.claude/skills/scrapegraph-ai/`
- Python venv: `~/.claude/skills/scrapegraph-ai/.venv/`
- CLI wrapper: `~/.claude/skills/scrapegraph-ai/scrape`
- Config: `~/.claude/skills/scrapegraph-ai/config/.env`

## Первичная настройка (один раз)

1. Скопировать `config/env.example` → `config/.env`.
2. Вписать реальный `OPENAI_API_KEY=sk-...`.

Без ключа CLI завершится с явной ошибкой `OPENAI_API_KEY is not set`.

## Как вызывать

Через шелл-обёртку:

```bash
~/.claude/skills/scrapegraph-ai/scrape \
  --url "https://example.com/page" \
  --prompt "Извлеки все товары: name, price, sku" \
  --output result.json
```

Параметры:

| Флаг | Назначение | По умолчанию |
|------|-----------|--------------|
| `--url` | целевая страница или путь к локальному файлу | обяз. (кроме `--graph search`) |
| `--prompt` | что извлекать | обяз. |
| `--model` | модель OpenAI | `gpt-4o-mini` |
| `--graph` | тип графа: `smart` / `search` / `deep` / `markdownify` | `smart` |
| `--output` | путь для сохранения JSON | stdout |
| `--verbose` | подробный лог графа | off |

## Какой граф когда брать

- **smart** — одна страница, нужен JSON по промпту. Базовый случай.
- **search** — задаёшь только промпт, инструмент сам ищет URL'ы через
  DuckDuckGo и парсит топ. `--url` не требуется.
- **deep** — рекурсивно ходит по внутренним ссылкам, собирая ответ.
  Стоит дороже по токенам, использовать осознанно.
- **markdownify** — конвертирует страницу в чистый Markdown без LLM-разбора.

## Программное использование (если нужно из Python)

```python
import subprocess, json
out = subprocess.check_output([
    "/Users/artempozdnyakov/.claude/skills/scrapegraph-ai/scrape",
    "--url", url, "--prompt", prompt,
])
data = json.loads(out)
```

Или напрямую через venv:

```bash
~/.claude/skills/scrapegraph-ai/.venv/bin/python -c "
from scrapegraphai.graphs import SmartScraperGraph
g = SmartScraperGraph(prompt='...', source='https://...', config={
    'llm': {'api_key': '...', 'model': 'openai/gpt-4o-mini'},
})
print(g.run())
"
```

## Зависимости

- Python 3.13 (системный)
- scrapegraphai 2.1.x
- playwright 1.60 + Chromium headless shell
- langchain-openai, openai >= 2.x
- python-dotenv

Все живут изолированно в `.venv/`. Системный Python не трогается.

## Обновление

```bash
~/.claude/skills/scrapegraph-ai/.venv/bin/pip install -U scrapegraphai playwright
~/.claude/skills/scrapegraph-ai/.venv/bin/playwright install chromium
```

## Удаление

```bash
rm -rf ~/.claude/skills/scrapegraph-ai
```
