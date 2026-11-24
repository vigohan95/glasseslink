"""Ask Claude (Anthropic Messages API) through the local proxy.

The API is only reachable through the system proxy (127.0.0.1:7897), so the
key and the proxy are read from the environment or from this file's siblings:

    setx ANTHROPIC_API_KEY   sk-ant-...
    setx HTTPS_PROXY         http://127.0.0.1:7897

Usage:
    python -P tools/ask_claude.py --model claude-fable-5-2 --max 1200 "question"
    python -P tools/ask_claude.py --file prompt.md --max 3000
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.anthropic.com/v1/messages"
DEFAULT_MODEL = "claude-opus-4-6"


def key() -> str:
    k = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if k:
        return k
    for p in ("anthropic.key", os.path.join(os.path.dirname(__file__), "anthropic.key")):
        if os.path.exists(p):
            with open(p, encoding="utf-8") as f:
                return f.read().strip()
    raise SystemExit("set ANTHROPIC_API_KEY or put the key in tools/anthropic.key")


def ask(prompt: str, model: str, max_tokens: int, system: str | None,
        effort: str = "low") -> dict:
    body = {
        "model": model,
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": prompt}],
        # These models think by default and will happily spend the whole budget doing it,
        # so ask for the cheapest adaptive effort unless the caller wants otherwise.
        "thinking": {"type": "adaptive"},
        "output_config": {"effort": effort},
    }
    if system:
        body["system"] = system
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        API,
        data=data,
        headers={
            "content-type": "application/json",
            "x-api-key": key(),
            "anthropic-version": "2023-06-01",
        },
        method="POST",
    )
    opener = urllib.request.build_opener()
    try:
        with opener.open(req, timeout=180) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        raise SystemExit("HTTP %s: %s" % (e.code, detail))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt", nargs="?", default="")
    ap.add_argument("--file")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--max", type=int, default=1200)
    ap.add_argument("--system", default=None)
    a = ap.parse_args()

    prompt = a.prompt
    if a.file:
        with open(a.file, encoding="utf-8") as f:
            prompt = f.read()
    if not prompt.strip():
        raise SystemExit("empty prompt")

    out = ask(prompt, a.model, a.max, a.system)
    for block in out.get("content", []):
        if block.get("type") == "text":
            print(block["text"])
    u = out.get("usage", {})
    print("\n--- usage: in=%s out=%s model=%s" % (u.get("input_tokens"), u.get("output_tokens"), out.get("model")),
          file=sys.stderr)


if __name__ == "__main__":
    main()
