#!/usr/bin/env python3
"""ScrapeGraphAI CLI wrapper.

Usage:
    scrape.py --url <URL> --prompt "<prompt>" [--model gpt-4o-mini]
                [--graph smart|search|deep|markdownify] [--output file.json]
                [--config path/to/config.yaml]

Reads OPENAI_API_KEY from ~/.claude/skills/scrapegraph-ai/config/.env
or from environment.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from dotenv import load_dotenv

SKILL_DIR = Path(__file__).resolve().parent.parent
ENV_PATH = SKILL_DIR / "config" / ".env"
if ENV_PATH.exists():
    load_dotenv(ENV_PATH)


def build_graph(graph_kind: str, prompt: str, source: str, config: dict):
    if graph_kind == "smart":
        from scrapegraphai.graphs import SmartScraperGraph
        return SmartScraperGraph(prompt=prompt, source=source, config=config)
    if graph_kind == "search":
        from scrapegraphai.graphs import SearchGraph
        return SearchGraph(prompt=prompt, config=config)
    if graph_kind == "deep":
        from scrapegraphai.graphs import DeepScraperGraph
        return DeepScraperGraph(prompt=prompt, source=source, config=config)
    if graph_kind == "markdownify":
        from scrapegraphai.graphs import MarkdownScraperGraph
        return MarkdownScraperGraph(prompt=prompt, source=source, config=config)
    raise SystemExit(f"Unknown graph kind: {graph_kind}")


def main() -> int:
    p = argparse.ArgumentParser(description="ScrapeGraphAI CLI wrapper")
    p.add_argument("--url", help="Target URL (or local file). Not needed for graph=search")
    p.add_argument("--prompt", required=True, help="What to extract")
    p.add_argument("--model", default="gpt-4o-mini",
                   help="OpenAI model name (default: gpt-4o-mini)")
    p.add_argument("--graph", default="smart",
                   choices=["smart", "search", "deep", "markdownify"])
    p.add_argument("--output", help="Write JSON result here; default = stdout")
    p.add_argument("--headless", action="store_true", default=True)
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args()

    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        sys.stderr.write(
            "ERROR: OPENAI_API_KEY is not set. Add it to "
            f"{ENV_PATH} or export it in the shell.\n"
        )
        return 2

    config = {
        "llm": {
            "api_key": api_key,
            "model": f"openai/{args.model}",
        },
        "verbose": args.verbose,
        "headless": args.headless,
    }

    if args.graph != "search" and not args.url:
        sys.stderr.write("ERROR: --url is required for this graph kind.\n")
        return 2

    graph = build_graph(args.graph, args.prompt, args.url or "", config)
    result = graph.run()

    out = json.dumps(result, ensure_ascii=False, indent=2, default=str)
    if args.output:
        Path(args.output).write_text(out, encoding="utf-8")
        print(f"Saved to {args.output}")
    else:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
