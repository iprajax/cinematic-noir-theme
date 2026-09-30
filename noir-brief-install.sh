#!/usr/bin/env bash
#
# Noir Brief — a live panel on the desktop and the screen saver, in the
# Editorial Noir palette.
#
#   bash noir-brief-install.sh
#
# Installs into ~/Pictures/Editorial Noir/brief:
#   · brief.py     fetches weather, headlines and quotes; renders the page
#   · index.html   the animated page
#   · frame.html   the same page settled to one still
#   · 00-brief.jpg a snapshot of that still, in the noir folder
#
# Then, if swiftc is present, compiles NoirWall — a ~150-line desktop
# renderer that parks a WKWebView one level above the wallpaper and below
# your icons. No App Store, no third-party app. If swiftc is missing, the
# build falls back to repainting the wallpaper with the snapshot instead.
#
# Standard library Python only. No pip, no API keys.
#
# Uninstall:
#   launchctl bootout gui/$(id -u)/com.editorialnoir.noirbrief
#   launchctl bootout gui/$(id -u)/com.editorialnoir.noirwall
#   rm -rf ~/Pictures/"Editorial Noir"/brief ~/Applications/NoirWall.app \
#          ~/Library/LaunchAgents/com.editorialnoir.noir{brief,wall}.plist \
#          ~/Library/Application\ Support/"Noir Brief"

set -euo pipefail

NOIR="${HOME}/Pictures/Editorial Noir"
DIR="${NOIR}/brief"
APP="${HOME}/Applications/NoirWall.app"
BRIEF_LABEL="com.editorialnoir.noirbrief"
WALL_LABEL="com.editorialnoir.noirwall"
LA="${HOME}/Library/LaunchAgents"

# Personal overrides (weather location, etc.) — see noir.local.example.sh.
LOCAL_CFG="$(cd "$(dirname "$0")" && pwd)/noir.local.sh"
# shellcheck source=/dev/null
[[ -f "$LOCAL_CFG" ]] && source "$LOCAL_CFG"

say()  { printf '\033[38;5;180m›\033[0m %s\n' "$*"; }
warn() { printf '\033[38;5;209m!\033[0m %s\n' "$*"; }

[[ "$(uname -s)" == "Darwin" ]] || { warn "macOS only."; exit 1; }
PYBIN="$(command -v python3 || true)"
[[ -n "$PYBIN" ]] || { warn "python3 missing — run: xcode-select --install"; exit 1; }

say "Installing into ${DIR}"
mkdir -p "$DIR/fonts" "$LA"

say "Fetching the three fonts…"
GF="https://raw.githubusercontent.com/google/fonts/main/ofl"
curl -fsSL -o "$DIR/fonts/fraunces.ttf"   "$GF/fraunces/Fraunces%5BSOFT,WONK,opsz,wght%5D.ttf"
curl -fsSL -o "$DIR/fonts/newsreader.ttf" "$GF/newsreader/Newsreader%5Bopsz,wght%5D.ttf"
curl -fsSL -o "$DIR/fonts/plexmono.ttf"   "$GF/ibmplexmono/IBMPlexMono-Regular.ttf"

say "Writing the builder…"
cat > "$DIR/brief.py" <<'BRIEFPY'
#!/usr/bin/env python3
"""Noir Brief — weather, headlines and markets, rendered in Editorial Noir.

Writes two things on every run:
    index.html   the live page (Plash points at this)
    ../00-brief.jpg   a snapshot the screen saver picks up from the noir folder

Standard library only — no pip, no API keys, nothing to expire. Every network
call is allowed to fail; the last good payload is cached to brief-cache.json so
a flaky feed or an offline laptop degrades to stale data rather than a blank
panel.

    python3 brief.py            build once
    python3 brief.py --no-shot  skip the screenshot (faster, for iterating)
    python3 brief.py --mock     build from canned data, no network at all
"""

import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

# ----------------------------------------------------------------- config
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "brief-cache.json")
PAGE = os.path.join(HERE, "index.html")    # animated, for the renderer
FRAME = os.path.join(HERE, "frame.html")   # settled still, for the snapshot
SAVER = os.path.join(HERE, "saver.html")   # the screen saver: cinema, not a wallpaper
# The snapshot is rendered here, then published into the noir folder under a
# rotating name. Keeping the working file out of that folder means the screen
# saver never has a permanently-cached stale asset sitting next to the fresh one.
SHOT = os.path.join(HERE, "brief-frame.jpg")
PUBDIR = os.path.abspath(os.path.join(HERE, os.pardir))

# Weather location. The installer writes config.json from noir.local.sh, or
# from this Mac's time zone when that isn't set.
try:
    with open(os.path.join(HERE, "config.json")) as _f:
        _cfg = json.load(_f)
except (OSError, ValueError):
    _cfg = {}
CITY = _cfg.get("city", "London")
LAT, LON = float(_cfg.get("lat", 51.5072)), float(_cfg.get("lon", -0.1276))
TZ = _cfg.get("tz", "Europe/London")
LOCAL = ZoneInfo(TZ)

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")

# section key -> (display label, [(source name, feed url), ...])
#
# Tuned to the beats that were actually asked for. The generic "top stories"
# feeds are gone: they were what put World Tourism Day and a court story on a
# work desktop. Everything here is either a primary source (release notes,
# lab blogs, arXiv) or a trade that covers agentic commerce and payments.
FEEDS = {
    "ai": ("Research", [
        # a targeted arXiv query beats pulling all of cs.AI and hoping
        ("arXiv", "http://export.arxiv.org/api/query?search_query="
                  "abs:%22LLM+agent%22+OR+abs:%22tool+use%22+OR+abs:%22agentic%22"
                  "&sortBy=submittedDate&sortOrder=descending&max_results=20"),
        ("Hacker News", "https://hnrss.org/frontpage?points=150"),
        ("Simon Willison", "https://simonwillison.net/atom/everything/"),
        ("Hugging Face", "https://huggingface.co/blog/feed.xml"),
        # release notes are the highest signal-to-noise source there is
        ("MCP", "https://github.com/modelcontextprotocol/modelcontextprotocol/releases.atom"),
        ("llama.cpp", "https://github.com/ggml-org/llama.cpp/releases.atom"),
        ("vLLM", "https://github.com/vllm-project/vllm/releases.atom"),
        ("MLX", "https://github.com/ml-explore/mlx/releases.atom"),
    ]),
    "tech": ("Industry", [
        ("OpenAI", "https://openai.com/news/rss.xml"),
        ("DeepMind", "https://deepmind.google/blog/rss.xml"),
        ("The Verge", "https://www.theverge.com/rss/index.xml"),
        ("TechCrunch", "https://techcrunch.com/feed/"),
        ("Ars Technica", "https://feeds.arstechnica.com/arstechnica/index"),
    ]),
    "india": ("India", [
        ("ET Tech", "https://economictimes.indiatimes.com/tech/rssfeeds/13357270.cms"),
        ("Mint Tech", "https://www.livemint.com/rss/technology"),
        ("Business Standard", "https://www.business-standard.com/rss/technology-108.rss"),
    ]),
    "commerce": ("Commerce", [
        ("AdExchanger", "https://www.adexchanger.com/feed/"),
        ("Digiday", "https://digiday.com/feed/"),
        ("Marketing Dive", "https://www.marketingdive.com/feeds/news/"),
        ("PYMNTS", "https://www.pymnts.com/feed/"),
        ("Finextra", "https://www.finextra.com/rss/headlines.aspx"),
    ]),
}

MAXAGE = 48 * 3600        # nothing older than this reaches the screen, anywhere

# Relevance by source, not only by keyword. A llama.cpp release is titled
# "b4739" and an MCP spec bump is "2026-03-26" — no keyword list will ever
# catch those, yet they are exactly the beat. These sources are on-beat by
# definition, so everything they publish goes to the wire.
WATCH_SOURCES = {"MCP", "llama.cpp", "vLLM", "MLX", "OpenAI", "DeepMind",
                 "Hugging Face", "Simon Willison"}

# Anything matching these gets promoted out of its section into the Watch
# column at the top. Ordered loosely by how specific the term is.
WATCH = [
    "agentic commerce", "agentic payment", "agentic checkout", "agentic cart",
    "agent payments protocol", "agentic commerce protocol", "universal commerce",
    "ap2", "x402", "acp ", "ucp ", "machine customer", "shopping agent",
    "autonomous checkout", "agent-to-agent", "a2a protocol",
    "model context protocol", "mcp server", "tool use", "tool calling",
    "computer use", "browser agent", "multi-agent", "agent harness",
    "local model", "on-device", "edge inference", "quantization", "quantized",
    "distillation", "llama.cpp", "vllm", "sglang", "mlx",
    "multimodal", "any-to-any", "omni model", "vision language",
    "checkout api", "headless commerce", "conversational commerce",
]

MARKETS = [
    ("NIFTY 50", "yahoo", "%5ENSEI"),
    ("SENSEX", "yahoo", "%5EBSESN"),
    ("USD/INR", "yahoo", "USDINR%3DX"),
    ("BTC", "yahoo", "BTC-USD"),
]

WMO = {
    0: "clear", 1: "mostly clear", 2: "partly cloudy", 3: "overcast",
    45: "fog", 48: "rime fog", 51: "light drizzle", 53: "drizzle",
    55: "heavy drizzle", 61: "light rain", 63: "rain", 65: "heavy rain",
    71: "light snow", 73: "snow", 75: "heavy snow", 80: "showers",
    81: "showers", 82: "violent showers", 95: "thunderstorm",
    96: "thunderstorm, hail", 99: "thunderstorm, hail",
}

# ------------------------------------------------------------------ net
def fetch(url, timeout=12, ua=None):
    """Never raises. Returns bytes or None."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": ua or UA,
                                                   "Accept": "*/*"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()
    except Exception as e:                                   # noqa: BLE001
        print(f"    · skipped {url.split('/')[2]}: {type(e).__name__}",
              file=sys.stderr)
        return None


def strip_tags(s):
    return re.sub(r"<[^>]+>", "", s or "").strip()


def parse_feed(raw, source):
    """RSS 2.0 and Atom, both. Returns [{title, link, source, ts}]."""
    if not raw:
        return []
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        return []
    items, ns = [], {"a": "http://www.w3.org/2005/Atom"}
    for node in root.iter():
        tag = node.tag.split("}")[-1]
        if tag not in ("item", "entry"):
            continue
        def txt(*names):
            for n in names:
                el = node.find(n) if "}" not in n else node.find(n, ns)
                if el is None:
                    el = node.find(f"a:{n}", ns)
                if el is not None and (el.text or el.get("href")):
                    return (el.text or el.get("href")).strip()
            return ""
        title = strip_tags(html.unescape(txt("title")))
        if not title:
            continue
        link = txt("link", "id")
        if not link:
            le = node.find("a:link", ns)
            link = le.get("href") if le is not None else ""
        when = txt("pubDate", "published", "updated", "date")
        items.append({"title": title, "link": link, "source": source,
                      "ts": parse_date(when)})
    return items


def parse_date(s):
    if not s:
        return 0
    for fmt in ("%a, %d %b %Y %H:%M:%S %z", "%a, %d %b %Y %H:%M:%S %Z",
                "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%SZ",
                "%Y-%m-%dT%H:%M:%S.%f%z"):
        try:
            d = datetime.strptime(s.strip().replace("GMT", "+0000"), fmt)
            if d.tzinfo is None:
                d = d.replace(tzinfo=timezone.utc)
            return d.timestamp()
        except ValueError:
            continue
    return 0


def weather():
    url = (f"https://api.open-meteo.com/v1/forecast?latitude={LAT}&longitude={LON}"
           "&current=temperature_2m,apparent_temperature,relative_humidity_2m,"
           "weather_code,wind_speed_10m"
           "&hourly=temperature_2m,precipitation_probability"
           "&daily=temperature_2m_max,temperature_2m_min,sunset"
           f"&timezone={TZ.replace('/', '%2F')}&forecast_days=2")
    raw = fetch(url)
    if not raw:
        return None
    try:
        d = json.loads(raw)
        cur, hourly, daily = d["current"], d["hourly"], d["daily"]
        now = datetime.now(LOCAL)
        idx = next((i for i, t in enumerate(hourly["time"])
                    if datetime.fromisoformat(t).hour >= now.hour
                    and t[:10] == now.strftime("%Y-%m-%d")), 0)
        span = slice(idx, idx + 12)
        return {
            "temp": round(cur["temperature_2m"]),
            "feels": round(cur["apparent_temperature"]),
            "humidity": cur["relative_humidity_2m"],
            "wind": round(cur["wind_speed_10m"]),
            "text": WMO.get(cur["weather_code"], "—"),
            "high": round(daily["temperature_2m_max"][0]),
            "low": round(daily["temperature_2m_min"][0]),
            "sunset": daily["sunset"][0][11:16],
            "hours": [{"t": t[11:13], "temp": round(v or 0), "rain": p or 0}
                      for t, v, p in zip(hourly["time"][span],
                                         hourly["temperature_2m"][span],
                                         hourly["precipitation_probability"][span])],
        }
    except Exception as e:                                   # noqa: BLE001
        print(f"    · weather parse failed: {e}", file=sys.stderr)
        return None


def markets():
    out = []
    for label, kind, sym in MARKETS:
        if kind != "yahoo":
            continue
        raw = fetch(f"https://query1.finance.yahoo.com/v8/finance/chart/{sym}"
                    "?range=5d&interval=1d",
                    ua="Mozilla/5.0")  # Yahoo 429s full browser UAs
        if not raw:
            continue
        try:
            m = json.loads(raw)["chart"]["result"][0]["meta"]
            price = m.get("regularMarketPrice")
            prev = m.get("chartPreviousClose") or m.get("previousClose")
            if price is None or not prev:
                continue
            pct = (price - prev) / prev * 100
            out.append({"label": label,
                        "value": f"{price:,.2f}" if price < 1000 else f"{price:,.0f}",
                        "pct": pct})
        except Exception:                                    # noqa: BLE001
            continue
    return out


# ------------------------------------------------------------- assembly
def is_watch(title, source=""):
    if source in WATCH_SOURCES:
        return True
    t = " " + title.lower() + " "
    return any(term in t for term in WATCH)


def gather():
    print("  fetching…", file=sys.stderr)
    sections, watch = {}, []
    seen_url, seen_title = set(), set()
    cutoff = time.time() - MAXAGE

    for key, (label, feeds) in FEEDS.items():
        items = []
        for name, url in feeds:
            items += parse_feed(fetch(url), name)
        items.sort(key=lambda x: x["ts"], reverse=True)
        kept = []
        for it in items:
            # A stale item is worse than no item: a 332-day-old post reached
            # the top of the screen because only the watch list was filtered.
            if it["ts"] and it["ts"] < cutoff:
                continue
            u = it.get("link", "")
            t = re.sub(r"\W+", "", it["title"].lower())[:80]
            if (u and u in seen_url) or t in seen_title:
                continue          # one story, one place on the page
            seen_url.add(u); seen_title.add(t)
            (watch if is_watch(it["title"], it["source"]) else kept).append(it)
        sections[key] = {"label": label, "items": kept[:6]}

    watch.sort(key=lambda x: x["ts"], reverse=True)
    # No padding. On a quiet day the wire says so; filling it with whatever
    # was newest is how tourism copy ended up under "ON THE WIRE".
    return {"built": time.time(), "watch": watch[:5],
            "sections": sections, "weather": weather(), "markets": markets()}


def mock():
    def item(t, s, age_h):
        return {"title": t, "link": "#", "source": s,
                "ts": time.time() - age_h * 3600}
    return {
        "built": time.time(),
        "watch": [
            item("Agentic checkout lands in three more storefronts as the protocol war narrows", "AdExchanger", 2),
            item("A2A and MCP converge: one registry for tools, one for agents", "Hacker News", 4),
            item("On-device 8B beats last year's frontier on tool-calling benchmarks", "arXiv cs.AI", 6),
            item("x402 micropayments see first production traffic at scale", "TechCrunch", 9),
            item("Machine customers now a line item in Indian retail forecasts", "Economic Times", 13),
            item("Quantization-aware distillation halves agent-harness latency", "arXiv cs.CL", 17),
            item("Conversational commerce pilots move from demo to revenue", "Digiday", 21),
        ],
        "sections": {
            "ai": {"label": "Research", "items": [
                item("Any-to-any omni models close the gap on speech", "arXiv cs.CL", 3),
                item("Sparse attention at million-token context, revisited", "arXiv cs.AI", 7),
                item("Why retrieval still beats longer windows for most work", "Hacker News", 11),
                item("A careful look at reward hacking in long-horizon tasks", "Google Research", 15),
                item("Speculative decoding on consumer silicon", "arXiv cs.AI", 19),
                item("Evaluating agents without a human in the loop", "Hacker News", 23)]},
            "tech": {"label": "Industry", "items": [
                item("The quiet consolidation of inference providers", "Ars Technica", 5),
                item("A new phone launch nobody asked for", "The Verge", 8),
                item("Chip supply loosens, prices do not", "TechCrunch", 12),
                item("Browser vendors ship agent permissions", "The Verge", 16),
                item("Open weights, closed data: the new default", "Ars Technica", 20),
                item("Another round for a coding-agent startup", "TechCrunch", 26)]},
            "india": {"label": "India", "items": [
                item("UPI volumes cross another record month", "Economic Times", 4),
                item("Office absorption up on GCC demand", "Mint", 9),
                item("Rupee steady as inflows offset oil", "Business Standard", 14),
                item("Quick-commerce margins finally turn", "Mint", 18),
                item("Telecom tariff revision expected this quarter", "Economic Times", 22),
                item("Data-centre buildout gets state incentives", "Business Standard", 28)]},
            "adtech": {"label": "Ad-tech", "items": [
                item("Retail media networks hit the measurement wall", "AdExchanger", 6),
                item("Publishers price agent traffic separately", "Digiday", 10),
                item("CTV supply paths get another audit", "Marketing Dive", 15),
                item("Identity resolution after the last cookie", "AdExchanger", 21),
                item("Creative automation budgets shift to agents", "Digiday", 25),
                item("Brand safety vendors add model provenance", "Marketing Dive", 30)]},
        },
        "weather": {"temp": 24, "feels": 25, "humidity": 71, "wind": 11,
                    "text": "partly cloudy", "high": 28, "low": 19,
                    "sunset": "18:22",
                    "hours": [{"t": f"{(14 + i) % 24:02d}",
                               "temp": 24 + [0, 1, 1, 0, -1, -2, -3, -3, -4, -4, -5, -5][i],
                               "rain": [10, 15, 25, 40, 35, 20, 10, 5, 5, 0, 0, 0][i]}
                              for i in range(12)]},
        "markets": [{"label": "NIFTY 50", "value": "24,836", "pct": 0.42},
                    {"label": "SENSEX", "value": "81,204", "pct": 0.31},
                    {"label": "USD/INR", "value": "88.41", "pct": -0.12},
                    {"label": "BTC", "value": "94,118", "pct": 1.87}],
    }


def merge_cache(fresh):
    """Keep the last good value for any part that came back empty."""
    try:
        with open(CACHE) as f:
            old = json.load(f)
    except Exception:                                        # noqa: BLE001
        old = {}
    if not fresh.get("watch") and old.get("watch"):
        fresh["watch"] = old["watch"]
    if fresh.get("weather") is None and old.get("weather"):
        fresh["weather"] = old["weather"]
        fresh["weather_stale"] = True
    if not fresh.get("markets") and old.get("markets"):
        fresh["markets"] = old["markets"]
    for k, sec in fresh.get("sections", {}).items():
        if not sec["items"] and old.get("sections", {}).get(k, {}).get("items"):
            sec["items"] = old["sections"][k]["items"]
    try:
        with open(CACHE, "w") as f:
            json.dump(fresh, f)
    except OSError:
        pass
    return fresh


# ------------------------------------------------------------- rendering
def ago(ts):
    if not ts:
        return ""
    mins = max(0, int((time.time() - ts) / 60))
    if mins < 60:
        return f"{mins}m"
    if mins < 60 * 48:
        return f"{mins // 60}h"
    return f"{mins // 1440}d"


def payload(d):
    """Everything the page needs, as one JSON blob. No clock, no date — the
    menu bar already has both, and a frozen clock on a wallpaper is worse
    than none."""
    def trim(items, n):
        return [{"t": i["title"], "s": i["source"], "a": ago(i["ts"]),
                 "u": i.get("link", "")}
                for i in items[:n]]

    secs = []
    for key in ("ai", "tech", "india", "commerce"):
        sec = d.get("sections", {}).get(key)
        if sec:
            secs.append({"k": key, "label": sec["label"],
                         "items": trim(sec["items"], 6),
                         "n": len(sec["items"])})
    w = d.get("weather") or {}
    return {
        "watch": trim(d.get("watch", []), 5),
        "sections": secs,
        "weather": {
            "temp": w.get("temp"), "text": w.get("text", ""),
            "feels": w.get("feels"), "high": w.get("high"), "low": w.get("low"),
            "humidity": w.get("humidity"), "wind": w.get("wind", 0),
            "sunset": w.get("sunset", ""),
            "hours": w.get("hours", []),
            "stale": bool(d.get("weather_stale")),
        } if w else None,
        "markets": d.get("markets", []),
        "built": datetime.now(LOCAL).strftime("%H:%M"),
    }


def render_wall(d, static=True):
    blob = json.dumps(payload(d), ensure_ascii=False)
    return (TEMPLATE
            .replace("/*__DATA__*/null", blob)
            .replace("/*__STATIC__*/false", "true" if static else "false"))


TEMPLATE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Noir Brief</title>
<style>
  @font-face { font-family:'Fraunces';   src:url('fonts/fraunces.ttf'); }
  @font-face { font-family:'Newsreader'; src:url('fonts/newsreader.ttf'); }
  @font-face { font-family:'PlexMono';   src:url('fonts/plexmono.ttf'); }

  :root{
    --base:#0D0C0B; --bone:#E8E2D8; --ember:#C66A42;
    --i1:rgba(232,226,216,.92); --i2:rgba(232,226,216,.52);
    --i3:rgba(232,226,216,.26); --rule:rgba(232,226,216,.10);
  }
  *{margin:0;padding:0;box-sizing:border-box}
  html,body{height:100%;overflow:hidden;background:var(--base)}
  body{ -webkit-font-smoothing:antialiased; color:var(--i1);
        font-family:'Newsreader',Georgia,serif; }

  /* the drawn layer: flow field + the day's headlines as a constellation */
  #field{position:fixed;inset:0;width:100%;height:100%;display:block}

  /* film grain, so this sits on the same surface as the wallpapers */
  #grain{position:fixed;inset:0;pointer-events:none;opacity:.55;
    background-image:url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='180' height='180'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='3'/><feColorMatrix type='saturate' values='0'/></filter><rect width='180' height='180' filter='url(%23n)' opacity='.06'/></svg>")}

  /* type lives in the left column; icons and Dock keep the rest */
  #col{position:fixed;left:5.5vw;top:8vh;width:36vw;
       display:flex;flex-direction:column;gap:3.4vh}

  .wx{display:flex;align-items:baseline;gap:1.1vw}
  .wx .t{font-family:'Fraunces',serif;font-weight:300;
         font-size:clamp(44px,5.2vw,104px);line-height:.9;letter-spacing:-.02em}
  .wx .t sup{font-size:.38em;vertical-align:super;color:var(--i3);
             margin-left:.06em}
  .wx .c{font-size:clamp(14px,1.25vw,26px);color:var(--i2);
         padding-bottom:.4em}
  .meta{font-family:'PlexMono',monospace;font-size:clamp(8px,.62vw,13px);
        letter-spacing:.16em;color:var(--i3);margin-top:1vh}

  h2{font-family:'PlexMono',monospace;font-weight:400;
     font-size:clamp(8px,.6vw,13px);letter-spacing:.42em;color:var(--ember);
     margin-bottom:1.6vh}
  .wire li{list-style:none;margin-bottom:1.5vh;max-width:34vw}
  .wire .h{font-size:clamp(14px,1.18vw,25px);line-height:1.3;color:var(--i1);
           display:block;text-decoration:none}
  /* inert while the layer is click-through; these only light up once the
     menu-bar toggle makes the desktop interactive */
  .wire .quiet{font-size:clamp(14px,1.18vw,25px);line-height:1.3;
               color:rgba(232,226,216,.34);font-style:italic;display:block}
  a{color:inherit;text-decoration:none}
  a:hover{color:var(--ember)}
  .wire .s{font-family:'PlexMono',monospace;font-size:clamp(7px,.54vw,12px);
           letter-spacing:.14em;color:var(--i3);display:block;margin-top:.4vh}

  #mk{position:fixed;left:5.5vw;bottom:7vh;display:flex;gap:2vw;
      font-family:'PlexMono',monospace}
  #mk div{display:flex;align-items:baseline;gap:.45vw}
  #mk .l{font-size:clamp(7px,.5vw,11px);letter-spacing:.22em;color:var(--i3)}
  #mk .v{font-size:clamp(10px,.8vw,17px);color:var(--i1)}
  #mk .p{font-size:clamp(7px,.55vw,12px)}
  .up{color:#8A9A6B}.dn{color:var(--ember)}

  /* cluster labels are drawn in the DOM so the type stays crisp */
  .clabel{position:fixed;font-family:'PlexMono',monospace;
          font-size:clamp(7px,.54vw,12px);letter-spacing:.3em;
          color:var(--i3);pointer-events:none;white-space:nowrap}
</style></head>
<body>
<canvas id="field"></canvas>
<div id="grain"></div>
<div id="col">
  <div id="wx"></div>
  <div class="wire"><h2>O N &nbsp;T H E &nbsp;W I R E</h2><ul id="wire"></ul></div>
</div>
<div id="mk"></div>

<script>
const D = /*__DATA__*/null;
const STATIC = /*__STATIC__*/false;

/* ---------- type ---------- */
const esc = s => String(s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));

if (D.weather && D.weather.temp != null) {
  const w = D.weather;
  document.getElementById('wx').innerHTML =
    `<div class="wx"><div class="t">${w.temp}<sup>°</sup></div>
     <div class="c">${esc(w.text)}</div></div>
     <div class="meta">FEELS ${w.feels}°&nbsp; ·&nbsp; ${w.high}°/${w.low}°&nbsp; ·&nbsp; ${w.humidity}%&nbsp; ·&nbsp; SUNSET ${esc(w.sunset)}${w.stale ? '&nbsp; ·&nbsp; STALE' : ''}</div>`;
}
const link = (i, cls) => i.u
  ? `<a class="${cls}" href="${esc(i.u)}">${esc(i.t)}</a>`
  : `<span class="${cls}">${esc(i.t)}</span>`;
document.getElementById('wire').innerHTML = D.watch.length
  ? D.watch.map(i => `<li>${link(i, 'h')}<span class="s">${esc(i.s)} · ${esc(i.a)}</span></li>`).join('')
  : `<li><span class="quiet">Quiet on the wire.</span>
       <span class="s">nothing on your beats in 48h</span></li>`;
document.getElementById('mk').innerHTML = D.markets.map(m =>
  `<div><span class="l">${esc(m.label)}</span><span class="v">${esc(m.value)}</span>
   <span class="p ${m.pct >= 0 ? 'up' : 'dn'}">${m.pct >= 0 ? '+' : ''}${m.pct.toFixed(2)}%</span></div>`).join('');

/* ---------- deterministic noise, so every machine draws the same frame ---------- */
let seed = 1337;
const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
const P = new Uint8Array(512);
{ const p = [...Array(256).keys()];
  for (let i = 255; i > 0; i--) { const j = (rnd() * (i + 1)) | 0; [p[i], p[j]] = [p[j], p[i]]; }
  for (let i = 0; i < 512; i++) P[i] = p[i & 255]; }
const fade = t => t * t * t * (t * (t * 6 - 15) + 10);
const grad = (h, x, y) => ((h & 1) ? -x : x) + ((h & 2) ? -y : y);
function noise(x, y) {
  const X = Math.floor(x) & 255, Y = Math.floor(y) & 255;
  x -= Math.floor(x); y -= Math.floor(y);
  const u = fade(x), v = fade(y);
  const a = P[X] + Y, b = P[X + 1] + Y;
  const lerp = (t, p, q) => p + t * (q - p);
  return lerp(v, lerp(u, grad(P[a], x, y), grad(P[b], x - 1, y)),
                 lerp(u, grad(P[a + 1], x, y - 1), grad(P[b + 1], x - 1, y - 1)));
}

/* ---------- the drawn layer ---------- */
const cv = document.getElementById('field'), cx = cv.getContext('2d', { alpha: false });
let W, H, DPR, parts = [], nodes = [], clusters = [];

/* The field's character comes from the actual weather and market state, so a
   still, clear, flat day genuinely looks different from a windy, volatile one. */
const wind = (D.weather && D.weather.wind) || 6;
const vol = D.markets.length
  ? D.markets.reduce((s, m) => s + Math.abs(m.pct), 0) / D.markets.length : 0.4;
const SPEED = (0.10 + Math.min(wind, 30) / 150) * 0.35;  // wallpaper: barely moving
const TURB = 0.9 + Math.min(vol, 3) * 0.5;
const warm = D.markets.length
  ? D.markets.filter(m => m.pct >= 0).length / D.markets.length : 0.5;

function layout() {
  DPR = Math.min(window.devicePixelRatio || 1, 2);
  W = cv.width = innerWidth * DPR; H = cv.height = innerHeight * DPR;
  cv.style.width = innerWidth + 'px'; cv.style.height = innerHeight + 'px';

  cx.fillStyle = '#0D0C0B'; cx.fillRect(0, 0, W, H);

  seed = 1337;
  parts = Array.from({ length: Math.round((W * H) / (DPR * DPR) / 1500) }, () => ({
    x: rnd() * W, y: rnd() * H, life: rnd() * 260,
  }));

  /* Headlines become a constellation: one loose cluster per section, out in
     the right-hand field where the type isn't. Radius tracks how much that
     section published; ember rings mark whatever hit the watchlist. */
  const cxs = [0.60, 0.80, 0.63, 0.86], cys = [0.26, 0.38, 0.68, 0.76];
  clusters = D.sections.map((s, i) => ({
    ...s, x: cxs[i % 4] * W, y: cys[i % 4] * H,
    r: (0.055 + Math.min(s.n, 8) / 90) * Math.min(W, H),
  }));
  nodes = [];
  clusters.forEach((c, ci) => {
    const count = Math.max(3, Math.min(c.n, 9));
    for (let k = 0; k < count; k++) {
      const a = rnd() * Math.PI * 2, rr = Math.sqrt(rnd()) * c.r;
      // newest items sit largest: the map reads as freshness, not decoration
      const fresh = 1 - k / Math.max(1, count - 1);
      nodes.push({ cx: c.x + Math.cos(a) * rr, cy: c.y + Math.sin(a) * rr,
                   r: (1.0 + fresh * 2.6) * DPR, ph: rnd() * 6.283,
                   sp: 0.25 + rnd() * 0.5, ci });
    }
  });
  D.watch.slice(0, 5).forEach((_, k) => { if (nodes[k * 3]) nodes[k * 3].watch = true; });

  document.querySelectorAll('.clabel').forEach(n => n.remove());
  clusters.forEach(c => {
    const lx = (c.x / DPR) + 'px', ly = ((c.y - c.r) / DPR - 30) + 'px';
    const l = document.createElement('div');
    l.className = 'clabel'; l.style.left = lx; l.style.top = ly;
    // label carries the count, so cluster size means something you can read
    l.textContent = c.label.toUpperCase().split('').join(' ') + '\u2002\u2002' + c.n;
    document.body.appendChild(l);
  });
}

function frame(t) {
  /* long trails: veil the canvas instead of clearing it */
  cx.fillStyle = 'rgba(13,12,11,0.070)'; cx.fillRect(0, 0, W, H);

  const sc = 0.0016 / DPR;
  cx.lineWidth = 0.6 * DPR;
  for (const p of parts) {
    const n = noise(p.x * sc, p.y * sc + t * 0.00004) * TURB;
    const a = n * Math.PI * 2.4;
    const nx = p.x + Math.cos(a) * SPEED * DPR * 9;
    const ny = p.y + Math.sin(a) * SPEED * DPR * 9;
    const heat = (noise(p.x * sc * 2.2, p.y * sc * 2.2) + 1) / 2;
    // ember is an accent: at most ~a fifth of the strokes, nudged by how
    // green the market is. The rest is bone at a whisper.
    cx.strokeStyle = heat < 0.08 + warm * 0.11
      ? 'rgba(198,106,66,0.13)' : 'rgba(232,226,216,0.085)';
    cx.beginPath(); cx.moveTo(p.x, p.y); cx.lineTo(nx, ny); cx.stroke();
    p.x = nx; p.y = ny;
    if (--p.life < 0 || p.x < 0 || p.x > W || p.y < 0 || p.y > H) {
      p.x = rnd() * W; p.y = rnd() * H; p.life = 180 + rnd() * 220;
    }
  }

  /* constellation: drifting nodes, joined to their nearest neighbours.
     No haloes — a soft radial blob reads as a smudge, an edge reads as
     structure. */
  for (const n of nodes) {
    n.x = n.cx + Math.cos(t * 0.00005 * n.sp + n.ph) * 11 * DPR;
    n.y = n.cy + Math.sin(t * 0.00004 * n.sp + n.ph) * 11 * DPR;
  }
  cx.lineWidth = 0.8 * DPR;
  for (let i = 0; i < nodes.length; i++) {
    for (let j = i + 1; j < nodes.length; j++) {
      if (nodes[i].ci !== nodes[j].ci) continue;
      const dx = nodes[i].x - nodes[j].x, dy = nodes[i].y - nodes[j].y;
      const d = Math.hypot(dx, dy), lim = clusters[nodes[i].ci].r * 0.95;
      if (d > lim) continue;
      cx.strokeStyle = `rgba(232,226,216,${(0.16 * (1 - d / lim)).toFixed(3)})`;
      cx.beginPath(); cx.moveTo(nodes[i].x, nodes[i].y);
      cx.lineTo(nodes[j].x, nodes[j].y); cx.stroke();
    }
  }
  for (const n of nodes) {
    if (n.watch) {
      cx.strokeStyle = 'rgba(198,106,66,0.60)'; cx.lineWidth = 1.2 * DPR;
      cx.beginPath(); cx.arc(n.x, n.y, n.r + 6 * DPR, 0, 6.283); cx.stroke();
      cx.fillStyle = 'rgba(198,106,66,0.90)';
    } else {
      cx.fillStyle = 'rgba(232,226,216,0.38)';
    }
    cx.beginPath(); cx.arc(n.x, n.y, n.r, 0, 6.283); cx.fill();
  }

  /* 12-hour temperature as a ridgeline along the base, with rain as a
     filled area beneath it. Ambient — the numbers are in the left column. */
  const hrs = (D.weather && D.weather.hours) || [];
  if (hrs.length > 1) {
    const x0 = 0, x1 = W, base = H * 0.998, amp = H * 0.030;
    const lo = Math.min(...hrs.map(h => h.temp)), hi = Math.max(...hrs.map(h => h.temp));
    const rg = (hi - lo) || 1;
    const pt = i => [x0 + (x1 - x0) * i / (hrs.length - 1),
                     base - ((hrs[i].temp - lo) / rg) * amp - amp * 0.3];
    cx.beginPath(); cx.moveTo(...pt(0));
    for (let i = 1; i < hrs.length; i++) {   // smooth, not a polyline of kinks
      const [px, py] = pt(i - 1), [qx, qy] = pt(i);
      cx.quadraticCurveTo(px, py, (px + qx) / 2, (py + qy) / 2);
    }
    cx.lineTo(...pt(hrs.length - 1));
    cx.strokeStyle = 'rgba(232,226,216,0.10)'; cx.lineWidth = 1.1 * DPR; cx.stroke();
    // stroke only — filling to the canvas edge made a hard wedge that read
    // as a rendering glitch rather than a horizon.
    const wet = hrs.reduce((s2, h) => s2 + h.rain, 0) / hrs.length;
    if (wet > 3) {                       // rain shows as a faint ember echo
      cx.strokeStyle = `rgba(198,106,66,${Math.min(0.14, wet / 500).toFixed(3)})`;
      cx.lineWidth = 3.5 * DPR; cx.stroke();
    }
  }
}

layout();
addEventListener('resize', layout);

if (STATIC) {
  /* One composed frame for the snapshot: run the simulation forward so the
     trails actually develop, then stop. Deterministic seed means the second
     Mac renders the identical image. */
  for (let i = 0; i < 1400; i++) frame(i * 16.7);
} else {
  let t0 = 0;
  (function loop(t) { frame(t); requestAnimationFrame(loop); })(t0);
}
</script>
</body></html>
"""




# ---------------------------------------------------------- the screen saver
def cards(d):
    """The screen saver is read from across a room, so it shows one thing at a
    time rather than everything at once. Weather, then the wire, then markets,
    then the sections — each its own card."""
    p = payload(d)
    out = []
    w = p.get("weather")
    if w and w.get("temp") is not None:
        out.append({"kind": "weather", "w": w})
    for i in p["watch"]:
        out.append({"kind": "story", "kicker": "ON THE WIRE", "ember": True,
                    "title": i["t"], "meta": f"{i['s']} · {i['a']}"})
    if p.get("markets"):
        out.append({"kind": "markets", "m": p["markets"]})
    ring = [(s["label"], i) for s in p["sections"] for i in s["items"][:4]]
    # interleave the sections so it doesn't read four Research cards in a row
    ring.sort(key=lambda x: x[1]["a"])
    for label, i in ring[:10]:
        out.append({"kind": "story", "kicker": label.upper(), "ember": False,
                    "title": i["t"], "meta": f"{i['s']} · {i['a']}"})
    return out


def render_saver(d):
    blob = json.dumps({"cards": cards(d),
                       "weather": payload(d).get("weather"),
                       "city": CITY.upper()}, ensure_ascii=False)
    return SAVER_TEMPLATE.replace("/*__DATA__*/null", blob)


SAVER_TEMPLATE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Noir Brief</title>
<style>
  @font-face { font-family:'Fraunces';   src:url('fonts/fraunces.ttf'); }
  @font-face { font-family:'Newsreader'; src:url('fonts/newsreader.ttf'); }
  @font-face { font-family:'PlexMono';   src:url('fonts/plexmono.ttf'); }

  :root{ --base:#0D0C0B; --bone:#E8E2D8; --ember:#C66A42; }
  *{margin:0;padding:0;box-sizing:border-box}
  html,body{height:100%;overflow:hidden;background:var(--base);cursor:none}
  body{font-family:'Newsreader',Georgia,serif;color:var(--bone);
       -webkit-font-smoothing:antialiased}

  #fx{position:fixed;inset:0;width:100%;height:100%;display:block}
  #scrim{position:fixed;inset:0;pointer-events:none;
    background:
      linear-gradient(100deg, rgba(13,12,11,.93) 0%, rgba(13,12,11,.82) 34%,
                              rgba(13,12,11,.30) 62%, rgba(13,12,11,0) 80%),
      linear-gradient(0deg,  rgba(13,12,11,.80) 0%, rgba(13,12,11,0) 34%)}

  /* the card: one idea, set large, left-anchored, read at distance */
  #stage{position:fixed;left:8vw;right:8vw;top:50%;transform:translateY(-58%);
         pointer-events:none}
  .card{position:absolute;left:0;right:0;opacity:0;
        transform:translateY(26px);
        transition:opacity .9s cubic-bezier(.22,1,.36,1),
                   transform .9s cubic-bezier(.22,1,.36,1)}
  .card.on{opacity:1;transform:translateY(0)}

  .kicker{font-family:'PlexMono',monospace;font-size:clamp(10px,.85vw,17px);
          letter-spacing:.46em;color:rgba(232,226,216,.40);margin-bottom:2.4vh}
  .kicker.ember{color:var(--ember)}
  .head{font-family:'Fraunces',Georgia,serif;font-weight:300;
        font-size:clamp(30px,3.9vw,86px);line-height:1.1;letter-spacing:-.015em;
        max-width:58vw}
  .head.long{font-size:clamp(24px,2.7vw,58px);line-height:1.16}
  .meta{font-family:'PlexMono',monospace;font-size:clamp(9px,.8vw,16px);
        letter-spacing:.24em;color:rgba(232,226,216,.34);margin-top:3vh}

  /* weather card */
  .big{font-family:'Fraunces',serif;font-weight:300;
       font-size:clamp(90px,13vw,290px);line-height:.84;letter-spacing:-.03em}
  .big sup{font-size:.30em;vertical-align:super;color:rgba(232,226,216,.34)}
  .cond{font-size:clamp(22px,2.4vw,54px);color:rgba(232,226,216,.68);
        margin-top:1.4vh}

  /* markets card */
  .mkrow{display:flex;gap:4.5vw;margin-top:1vh;flex-wrap:wrap}
  .mkcell .l{font-family:'PlexMono',monospace;font-size:clamp(9px,.78vw,16px);
             letter-spacing:.26em;color:rgba(232,226,216,.34)}
  .mkcell .v{font-family:'Fraunces',serif;font-weight:300;
             font-size:clamp(34px,4.2vw,92px);line-height:1.05;margin-top:.8vh}
  .mkcell .p{font-family:'PlexMono',monospace;font-size:clamp(11px,1vw,21px);
             letter-spacing:.1em}
  .up{color:#8A9A6B}.dn{color:var(--ember)}

  /* persistent HUD — someone walking past wants the time, not a headline */
  #hud{position:fixed;right:5vw;bottom:5vh;text-align:right}
  #clock{font-family:'Fraunces',serif;font-weight:300;
         font-size:clamp(30px,3.4vw,74px);line-height:1;letter-spacing:-.02em;
         color:rgba(232,226,216,.80)}
  #date{font-family:'PlexMono',monospace;font-size:clamp(9px,.72vw,15px);
        letter-spacing:.3em;color:rgba(232,226,216,.34);margin-top:1.2vh}
  #place{font-family:'PlexMono',monospace;font-size:clamp(8px,.62vw,13px);
         letter-spacing:.42em;color:rgba(232,226,216,.22);margin-top:.7vh}

  /* how far through the loop you are */
  #bar{position:fixed;left:8vw;bottom:5vh;width:26vw;height:1px;
       background:rgba(232,226,216,.10)}
  #bar i{display:block;height:100%;width:0;background:var(--ember);opacity:.65}
</style></head>
<body>
<canvas id="fx"></canvas>
<div id="scrim"></div>
<div id="stage"></div>
<div id="hud"><div id="clock">--:--</div><div id="date"></div><div id="place"></div></div>
<div id="bar"><i></i></div>

<script>
const D = /*__DATA__*/null;
const HOLD = 7200, FADE = 900;          // ms per card, ms of cross-dissolve

const esc = s => String(s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));

/* ---------------- cards ---------------- */
const stage = document.getElementById('stage');
function build(c) {
  const el = document.createElement('div');
  el.className = 'card';
  if (c.kind === 'story') {
    el.innerHTML = `<div class="kicker${c.ember ? ' ember' : ''}">${esc(c.kicker)}</div>
      <div class="head${c.title.length > 88 ? ' long' : ''}">${esc(c.title)}</div>
      <div class="meta">${esc(c.meta)}</div>`;
  } else if (c.kind === 'weather') {
    const w = c.w;
    el.innerHTML = `<div class="kicker">WEATHER</div>
      <div class="big">${w.temp}<sup>°</sup></div>
      <div class="cond">${esc(w.text)}</div>
      <div class="meta">FEELS ${w.feels}° · ${w.high}°/${w.low}° · ${w.humidity}% · SUNSET ${esc(w.sunset)}</div>`;
  } else {
    el.innerHTML = `<div class="kicker">MARKETS</div><div class="mkrow">` +
      c.m.map(m => `<div class="mkcell"><div class="l">${esc(m.label)}</div>
        <div class="v">${esc(m.value)}</div>
        <div class="p ${m.pct >= 0 ? 'up' : 'dn'}">${m.pct >= 0 ? '+' : ''}${m.pct.toFixed(2)}%</div></div>`).join('') +
      `</div>`;
  }
  stage.appendChild(el);
  return el;
}
const cards = D.cards.map(build);
let idx = -1, lastSwap = 0;
const barFill = document.querySelector('#bar i');

function advance(now) {
  if (idx >= 0) cards[idx].classList.remove('on');
  idx = (idx + 1) % cards.length;
  setTimeout(() => cards[idx].classList.add('on'), idx === 0 ? 40 : FADE * 0.45);
  lastSwap = now;
  surge = 1;                              // the field reacts to the cut
}

/* ---------------- clock ---------------- */
const MON = ['January','February','March','April','May','June','July',
             'August','September','October','November','December'];
const DAY = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
document.getElementById('place').textContent = D.city;
function tick() {
  const d = new Date();
  document.getElementById('clock').textContent =
    String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
  document.getElementById('date').textContent =
    `${DAY[d.getDay()].toUpperCase()}  ${d.getDate()} ${MON[d.getMonth()].toUpperCase()}`;
}
tick(); setInterval(tick, 1000);

/* ---------------- the field ----------------
   Drawn at half resolution into an offscreen buffer, then composited twice:
   once sharp, once blurred and additive. That is the bloom — and it costs a
   quarter of the fill rate of drawing it full size, which matters at 4K. */
const view = document.getElementById('fx'), vx = view.getContext('2d', { alpha: false });
const buf = document.createElement('canvas'), bx = buf.getContext('2d');
let W, H, BW, BH, DPR, parts = [], surge = 0, camera = 0, vign = null;

let seed = 20260927;
const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
const P = new Uint8Array(512);
{ const p = [...Array(256).keys()];
  for (let i = 255; i > 0; i--) { const j = (rnd() * (i + 1)) | 0; [p[i], p[j]] = [p[j], p[i]]; }
  for (let i = 0; i < 512; i++) P[i] = p[i & 255]; }
const fade = t => t * t * t * (t * (t * 6 - 15) + 10);
const grd = (h, x, y) => ((h & 1) ? -x : x) + ((h & 2) ? -y : y);
function noise(x, y) {
  const X = Math.floor(x) & 255, Y = Math.floor(y) & 255;
  x -= Math.floor(x); y -= Math.floor(y);
  const u = fade(x), v = fade(y), a = P[X] + Y, b = P[X + 1] + Y;
  const L = (t, p, q) => p + t * (q - p);
  return L(v, L(u, grd(P[a], x, y), grd(P[b], x - 1, y)),
              L(u, grd(P[a + 1], x, y - 1), grd(P[b + 1], x - 1, y - 1)));
}

function layout() {
  DPR = Math.min(window.devicePixelRatio || 1, 2);
  vign = null;
  W = view.width = innerWidth * DPR; H = view.height = innerHeight * DPR;
  view.style.width = innerWidth + 'px'; view.style.height = innerHeight + 'px';
  BW = buf.width = Math.round(W / 2); BH = buf.height = Math.round(H / 2);
  bx.fillStyle = '#0D0C0B'; bx.fillRect(0, 0, BW, BH);
  const n = Math.min(4200, Math.round(BW * BH / 420));
  parts = Array.from({ length: n }, () => ({
    x: rnd() * BW, y: rnd() * BH,
    z: 0.15 + rnd() * 0.85,              // depth drives speed, size and alpha
    life: 60 + rnd() * 400,
    hot: rnd() < 0.16,                   // ember is an accent, never the field
  }));
}

function field(t, dt) {
  surge *= Math.pow(0.90, dt / 16.7);    // the cut's energy decays away
  camera += dt * 0.000018;

  bx.globalCompositeOperation = 'source-over';
  bx.fillStyle = 'rgba(13,12,11,0.055)';
  bx.fillRect(0, 0, BW, BH);

  bx.globalCompositeOperation = 'lighter';
  const sc = 0.0022, boost = 1 + surge * 2.2;
  for (const p of parts) {
    const a = noise(p.x * sc + camera, p.y * sc - camera) * 2.6;
    const sp = (0.35 + p.z * 1.5) * boost;
    p.x += Math.cos(a * Math.PI) * sp;
    p.y += Math.sin(a * Math.PI) * sp;
    const al = (0.045 + p.z * 0.16) * (0.75 + surge * 0.8);
    bx.fillStyle = p.hot
      ? `rgba(198,106,66,${al * 1.35})` : `rgba(232,226,216,${al})`;
    const r = p.z * 2.1 + 0.55;
    bx.fillRect(p.x, p.y, r, r);
    if (--p.life < 0 || p.x < -20 || p.x > BW + 20 || p.y < -20 || p.y > BH + 20) {
      p.x = rnd() * BW; p.y = rnd() * BH; p.life = 60 + rnd() * 400;
    }
  }

  // a single slow arc, so the motion has something to be measured against
  bx.globalCompositeOperation = 'source-over';
  bx.strokeStyle = 'rgba(232,226,216,0.075)'; bx.lineWidth = 1.2;
  bx.beginPath();
  const cx0 = BW * 0.5, cy0 = BH * 1.32, rr = BH * 1.02;
  bx.arc(cx0, cy0, rr, Math.PI * 1.08 + camera * 0.5, Math.PI * 1.92 + camera * 0.5);
  bx.stroke();

  vx.globalCompositeOperation = 'source-over';
  vx.filter = 'none';
  vx.drawImage(buf, 0, 0, W, H);
  if (!vign) {
    vign = document.createElement('canvas');
    vign.width = W; vign.height = H;
    const g = vign.getContext('2d');
    const rg = g.createRadialGradient(W * 0.5, H * 0.5, Math.min(W, H) * 0.25,
                                      W * 0.5, H * 0.5, Math.max(W, H) * 0.72);
    rg.addColorStop(0, 'rgba(13,12,11,0)');
    rg.addColorStop(1, 'rgba(13,12,11,0.72)');
    g.fillStyle = rg; g.fillRect(0, 0, W, H);
  }
  if (BLOOM) {                            // additive blurred pass = bloom
    vx.globalCompositeOperation = 'lighter';
    vx.filter = 'blur(' + (10 * DPR) + 'px)';
    vx.globalAlpha = 0.55;
    vx.drawImage(buf, 0, 0, W, H);
    vx.globalAlpha = 1; vx.filter = 'none';
    vx.globalCompositeOperation = 'source-over';
  }
  vx.drawImage(vign, 0, 0);
}

// Canvas filter is the one thing here that might be missing; without it we
// simply skip the bloom pass rather than drawing a doubled image.
const BLOOM = (() => {
  const c = document.createElement('canvas').getContext('2d');
  try { c.filter = 'blur(2px)'; return c.filter === 'blur(2px)'; } catch (e) { return false; }
})();

layout();
addEventListener('resize', layout);

let prev = 0;
requestAnimationFrame(function loop(t) {
  const dt = Math.min(64, t - prev); prev = t;
  if (!lastSwap || t - lastSwap > HOLD) advance(t);
  barFill.style.width = Math.min(100, (t - lastSwap) / HOLD * 100) + '%';
  field(t, dt);
  requestAnimationFrame(loop);
});
</script>
</body></html>
"""
# ------------------------------------------------------------- snapshot
CHROMES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    shutil.which("chromium") or "", shutil.which("chromium-browser") or "",
    shutil.which("google-chrome") or "",
]


def snapshot():
    chrome = next((c for c in CHROMES if c and os.path.exists(c)), None)
    if not chrome:
        print("    · no Chrome found — skipping the screen-saver snapshot",
              file=sys.stderr)
        return False
    png = SHOT.replace(".jpg", ".png")
    cmd = [chrome, "--headless", "--disable-gpu", "--hide-scrollbars",
           "--no-sandbox", "--force-device-scale-factor=2",
           "--window-size=1920,1200", f"--screenshot={png}",
           "--virtual-time-budget=4000", f"file://{FRAME}"]
    try:
        subprocess.run(cmd, check=True, capture_output=True, timeout=90)
    except Exception as e:                                   # noqa: BLE001
        print(f"    · snapshot failed: {e}", file=sys.stderr)
        return False
    # JPEG so it matches the rest of the folder and the saver loads it fast
    try:
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions",
                        "92", png, "--out", SHOT],
                       check=True, capture_output=True)
        os.remove(png)
    except Exception:                                        # noqa: BLE001
        os.replace(png, SHOT.replace(".jpg", ".png"))        # keep the PNG
    return True


WALLDIR = os.path.expanduser("~/Library/Application Support/Noir Brief")


def set_wallpaper():
    """Repaint the desktop with the frame we just rendered.

    macOS caches the desktop picture by path, so rewriting the same file
    changes nothing on screen. Alternating between two filenames defeats that
    cache without leaving a growing pile of images behind. Kept out of
    ~/Pictures so the screen saver, which reads that folder, never sees them.
    """
    if not os.path.exists(SHOT):
        return False
    os.makedirs(WALLDIR, exist_ok=True)
    a = os.path.join(WALLDIR, "wall-a.jpg")
    b = os.path.join(WALLDIR, "wall-b.jpg")
    # write to whichever slot is currently NOT on screen (the older one)
    ta = os.path.getmtime(a) if os.path.exists(a) else -1
    tb = os.path.getmtime(b) if os.path.exists(b) else -1
    target = a if ta <= tb else b
    shutil.copy2(SHOT, target)
    script = ('tell application "System Events" to tell every desktop '
              f'to set picture to {json.dumps(target)}')
    try:
        subprocess.run(["osascript", "-e", script], check=True,
                       capture_output=True, timeout=30)
        return True
    except subprocess.CalledProcessError as e:
        err = (e.stderr or b"").decode(errors="replace").strip()
        print(f"    · wallpaper refresh refused: {err}", file=sys.stderr)
        print("      (System Settings > Privacy & Security > Automation — "
              "allow this to control System Events)", file=sys.stderr)
        return False
    except Exception as e:                                   # noqa: BLE001
        print(f"    · wallpaper refresh failed: {e}", file=sys.stderr)
        return False


def rotate_shot():
    """Publish the frame under a fresh name and remove the previous one.

    The Photos screen saver caches by path: overwriting 00-brief.jpg leaves
    it serving the copy it cached when the folder was picked. A new filename
    each cycle is the one thing it cannot cache past.
    """
    folder = PUBDIR
    stamp = datetime.now(LOCAL).strftime("%H%M")
    fresh = os.path.join(folder, f"00-brief-{stamp}.jpg")
    try:
        shutil.copy2(SHOT, fresh)
    except OSError as e:
        print(f"    · could not publish {fresh}: {e}", file=sys.stderr)
        return
    for name in os.listdir(folder):
        if name.startswith("00-brief-") and name.endswith(".jpg") \
                and os.path.join(folder, name) != fresh:
            try:
                os.remove(os.path.join(folder, name))
            except OSError:
                pass
    print(f"  published {os.path.basename(fresh)}", file=sys.stderr)


# ----------------------------------------------------------------- main
def main():
    args = set(sys.argv[1:])
    os.makedirs(HERE, exist_ok=True)
    data = mock() if "--mock" in args else merge_cache(gather())
    # index.html animates (the desktop renderer loads it); frame.html settles
    # to one composed still, which is what the screen-saver snapshot needs.
    with open(PAGE, "w") as f:
        f.write(render_wall(data, static=False))
    with open(FRAME, "w") as f:
        f.write(render_wall(data, static=True))
    with open(SAVER, "w") as f:
        f.write(render_saver(data))
    # What the menu bar reads. Grouped, deduped by URL, with a one-line
    # summary at the top — the flat concatenation shipped duplicates,
    # because the wire list is itself backfilled from the sections.
    p = payload(data)
    seen, groups = set(), []

    def take(items, n):
        out = []
        for i in items:
            u = i.get("u")
            if not u or u in seen:
                continue
            seen.add(u)
            out.append({"title": i["t"], "url": u,
                        "source": i["s"], "age": i["a"]})
            if len(out) >= n:
                break
        return out

    wire = take(p["watch"], 5)
    if wire:
        groups.append({"label": "On the wire", "items": wire})
    for s in p["sections"]:
        got = take(s["items"], 4)
        if got:
            groups.append({"label": s["label"], "items": got})

    w, mk = p.get("weather"), p.get("markets", [])
    bits = []
    if w and w.get("temp") is not None:
        bits.append(f"{w['temp']}° {w['text']}")
    bits += [f"{m['label'].split()[0]} {m['pct']:+.2f}%" for m in mk[:3]]
    with open(os.path.join(HERE, "headlines.json"), "w") as f:
        json.dump({"summary": "   ·   ".join(bits), "groups": groups}, f)

    print(f"  wrote {PAGE}", file=sys.stderr)
    if "--no-shot" not in args and snapshot():
        print(f"  wrote {SHOT}", file=sys.stderr)
        rotate_shot()
        if "--no-wallpaper" not in args and set_wallpaper():
            print("  desktop repainted", file=sys.stderr)


if __name__ == "__main__":
    main()
BRIEFPY

# Location for the weather. Anything unset in noir.local.sh is derived from
# this Mac's time zone via the system zone table — no network lookup.
"$PYBIN" - "$DIR/config.json" "${NOIR_CITY:-}" "${NOIR_LAT:-}" "${NOIR_LON:-}" "${NOIR_TZ:-}" <<'PY'
import json, os, sys
out, city, lat, lon, tz = sys.argv[1:]
if not tz:
    real = os.path.realpath("/etc/localtime")
    tz = real.split("/zoneinfo/", 1)[1] if "/zoneinfo/" in real else "Europe/London"
if not (lat and lon):
    def deg(s):  # zone.tab: +DDMM[SS] latitude, +DDDMM[SS] longitude
        sign, s = (-1 if s[0] == "-" else 1), s[1:]
        d = 2 if len(s) % 2 == 0 else 3
        return sign * (int(s[:d]) + int(s[d:d + 2]) / 60 + int(s[d + 2:] or 0) / 3600)
    lat, lon = 51.5072, -0.1276
    try:
        for row in open("/usr/share/zoneinfo/zone.tab"):
            f = row.split("\t")
            if len(f) > 2 and f[2].strip() == tz:
                i = max(f[1].rfind("+"), f[1].rfind("-"))
                lat, lon = round(deg(f[1][:i]), 4), round(deg(f[1][i:]), 4)
                break
    except OSError:
        pass
city = city or tz.rsplit("/", 1)[-1].replace("_", " ")
json.dump({"city": city, "lat": float(lat), "lon": float(lon), "tz": tz}, open(out, "w"))
print(f"  weather for {city} ({float(lat):.2f}, {float(lon):.2f}, {tz})")
PY
chmod +x "$DIR/brief.py"

# ------------------------------------------------- the desktop renderer
WALL_OK=0
if command -v swiftc >/dev/null 2>&1; then
  say "Compiling NoirWall (the desktop renderer)…"
  SRC="$(mktemp -d)/NoirWall.swift"
  cat > "$SRC" <<'SWIFTSRC'
// NoirWall — renders a local HTML page at desktop level, behind your icons.
//
// The desktop layer is click-through by default, because a wallpaper that
// swallows clicks is a bug: every click on empty desktop to focus Finder
// would land on a headline instead. But a panel you can read and not act on
// is a dead end, so there are three ways out:
//
//   · a menu-bar list of the current headlines, always clickable
//   · "Make desktop clickable" — 20 seconds of interactivity, then it
//     reverts on its own
//   · a companion window with the same page, fully interactive
//
// Links always open in the default browser rather than navigating the
// wallpaper away from the brief.
//
//   swiftc -O -o NoirWall NoirWall.swift -framework Cocoa -framework WebKit
//   NoirWall <path-to-index.html> [reload-seconds]

import Cocoa
import WebKit

struct Headline: Decodable {
    let title: String; let url: String; let source: String; let age: String
}
struct Group: Decodable { let label: String; let items: [Headline] }
struct Brief: Decodable { let summary: String; let groups: [Group] }

final class Wall: NSObject, NSApplicationDelegate, WKNavigationDelegate, NSMenuDelegate {
    let pageURL: URL
    let reloadEvery: TimeInterval
    /// Menu-only: keep the headline list in the menu bar, paint nothing on the
    /// desktop. A wallpaper is visible exactly when you are between tasks and
    /// covered when you are working, so it is the wrong surface for reading.
    let menuOnly: Bool
    var windows: [NSWindow] = []
    var views: [WKWebView] = []
    var statusItem: NSStatusItem!
    var companion: NSWindow?
    var reloadTimer: Timer?
    var interactiveUntil: Timer?

    var headlinesURL: URL {
        pageURL.deletingLastPathComponent().appendingPathComponent("headlines.json")
    }

    init(page: URL, reload: TimeInterval, menuOnly: Bool) {
        self.pageURL = page
        self.reloadEvery = reload
        self.menuOnly = menuOnly
    }

    // MARK: - lifecycle

    func applicationDidFinishLaunching(_: Notification) {
        buildStatusItem()
        build()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.build() }

        reloadTimer = Timer.scheduledTimer(withTimeInterval: reloadEvery,
                                           repeats: true) { [weak self] _ in
            self?.reloadAll()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.reloadAll() }
    }

    func reloadAll() {
        views.forEach { $0.reload() }
        (companion?.contentView as? WKWebView)?.reload()
    }

    // MARK: - the desktop layer

    /// One window per screen, rebuilt whenever displays change so plugging in
    /// a monitor doesn't leave a dead window behind.
    func build() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll(); views.removeAll()
        if menuOnly { return }

        // Just above the wallpaper, still below the desktop icons.
        let level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

        for screen in NSScreen.screens {
            let web = makeWebView()
            let win = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                               backing: .buffered, defer: false, screen: screen)
            win.level = level
            win.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                      .ignoresCycle, .fullScreenNone]
            win.ignoresMouseEvents = true          // click-through by default
            win.isOpaque = true
            win.backgroundColor = NSColor(red: 13/255, green: 12/255,
                                          blue: 11/255, alpha: 1)
            win.hasShadow = false
            win.isReleasedWhenClosed = false
            win.contentView = web
            web.frame = win.contentView!.bounds
            win.orderFrontRegardless()
            load(web)
            windows.append(win); views.append(web)
        }
    }

    func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.suppressesIncrementalRendering = true
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")     // no white flash
        web.autoresizingMask = [.width, .height]
        return web
    }

    func load(_ web: WKWebView) {
        web.loadFileURL(pageURL,
                        allowingReadAccessTo: pageURL.deletingLastPathComponent())
    }

    /// A clicked headline opens in the browser — never navigates the
    /// wallpaper away from the brief.
    func webView(_ web: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated,
           let url = action.request.url, url.scheme?.hasPrefix("http") == true {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: - way out 1 & 2: the menu bar

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "circle.dotted",
                              accessibilityDescription: "Noir Brief")
            b.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt each time it opens, from the same headlines.json the page was
    /// rendered from — so the list is never staler than the wallpaper.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        var brief: Brief?
        if let data = try? Data(contentsOf: headlinesURL) {
            brief = try? JSONDecoder().decode(Brief.self, from: data)
        }

        if let summary = brief?.summary, !summary.isEmpty {
            menu.addItem(label(summary, size: 11, alpha: 0.75, tracking: 0.4))
            menu.addItem(.separator())
        }

        if let groups = brief?.groups, !groups.isEmpty {
            for (gi, g) in groups.enumerated() {
                if gi > 0 { menu.addItem(.separator()) }
                menu.addItem(label(g.label.uppercased(), size: 9.5,
                                   alpha: 0.42, tracking: 2.2))
                for h in g.items {
                    menu.addItem(headlineItem(h))
                }
            }
        } else {
            menu.addItem(label("No headlines yet", size: 12, alpha: 0.5, tracking: 0))
        }

        menu.addItem(.separator())
        if !menuOnly {
            let live = windows.first?.ignoresMouseEvents == false
            add(menu, live ? "Stop desktop clicks" : "Make desktop clickable (20s)",
                #selector(toggleInteractive), "")
        }
        add(menu, "Open in a window…", #selector(openCompanion), "")
        add(menu, "Reload", #selector(menuReload), "r")
        menu.addItem(.separator())
        add(menu, "Quit NoirWall", #selector(quit), "q")
    }

    /// A non-selectable caption — section rules and the summary line.
    func label(_ text: String, size: CGFloat, alpha: CGFloat,
               tracking: CGFloat) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha),
            .kern: tracking,
        ])
        return item
    }

    /// Headline in reading weight, source and age trailing in a quieter grey.
    /// Long titles are cut at a word boundary — letting AppKit middle-truncate
    /// a 120-character arXiv title turns it into nonsense.
    func headlineItem(_ h: Headline) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(openHeadline(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = h.url

        var title = h.title
        if title.count > 72 {
            let cut = title.prefix(72)
            let stop = cut.lastIndex(of: " ").map(cut.index(after:)) ?? cut.endIndex
            title = cut[..<stop].trimmingCharacters(in: .whitespaces) + "…"
        }

        let s = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.92),
        ])
        s.append(NSAttributedString(string: "   \(h.source) · \(h.age)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.6),
        ]))
        item.attributedTitle = s
        return item
    }

    func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String) {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
    }

    @objc func openHeadline(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let u = URL(string: s) {
            NSWorkspace.shared.open(u)
        }
    }

    @objc func menuReload() { reloadAll() }

    /// Twenty seconds of a clickable desktop, then back to click-through on
    /// its own — so a forgotten toggle can't leave the desktop broken.
    @objc func toggleInteractive() {
        interactiveUntil?.invalidate()
        let nowLive = windows.first?.ignoresMouseEvents == false
        setInteractive(!nowLive)
        if !nowLive {
            interactiveUntil = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) {
                [weak self] _ in self?.setInteractive(false)
            }
        }
    }

    func setInteractive(_ on: Bool) {
        windows.forEach { $0.ignoresMouseEvents = !on }
        if on { NSApp.activate(ignoringOtherApps: false) }
    }

    // MARK: - way out 3: the companion window

    @objc func openCompanion() {
        if let w = companion {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let web = makeWebView()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Noir Brief"
        w.titlebarAppearsTransparent = true
        w.backgroundColor = NSColor(red: 13/255, green: 12/255, blue: 11/255, alpha: 1)
        w.isReleasedWhenClosed = false
        w.contentView = web
        web.frame = w.contentView!.bounds
        load(web)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        companion = w
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write(
        "usage: NoirWall <path-to-index.html> [reload-seconds] [--menu-only]\n".data(using: .utf8)!)
    exit(2)
}
let pageArg = args.dropFirst().first { !$0.hasPrefix("--") } ?? ""
let page = URL(fileURLWithPath: (pageArg as NSString).expandingTildeInPath)
guard FileManager.default.fileExists(atPath: page.path) else {
    FileHandle.standardError.write(
        "NoirWall: no such page: \(page.path)\n".data(using: .utf8)!)
    exit(1)
}
let menuOnly = args.contains("--menu-only")
let positional = args.dropFirst().filter { !$0.hasPrefix("--") }
let reload = positional.count > 1 ? (TimeInterval(positional[positional.startIndex + 1]) ?? 300) : 300

let app = NSApplication.shared
app.setActivationPolicy(.accessory)        // menu-bar only, no dock icon
let wall = Wall(page: page, reload: reload, menuOnly: menuOnly)
app.delegate = wall
app.run()
SWIFTSRC
  mkdir -p "$APP/Contents/MacOS"
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NoirWall</string>
  <key>CFBundleExecutable</key><string>NoirWall</string>
  <key>CFBundleIdentifier</key><string>com.editorialnoir.noirwall</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
  if swiftc -O -o "$APP/Contents/MacOS/NoirWall" "$SRC" \
       -framework Cocoa -framework WebKit 2>"$DIR/build.log"; then
    codesign --force --sign - "$APP" 2>/dev/null || true
    WALL_OK=1
    say "Built ${APP}"
  else
    warn "NoirWall failed to compile — see ${DIR}/build.log"
    warn "Falling back to repainting the wallpaper with the snapshot."
  fi
else
  warn "swiftc not found (run: xcode-select --install) — skipping the renderer."
  warn "Falling back to repainting the wallpaper with the snapshot."
fi

# With the renderer running it owns the desktop, so the build should not also
# fight it by re-setting the wallpaper underneath.
if [[ $WALL_OK -eq 1 ]]; then BUILD_ARGS='<string>--no-wallpaper</string>'; else BUILD_ARGS=''; fi

# ------------------------------------------------- the screen saver bundle
SAVER_OK=0
SAVERDIR="${HOME}/Library/Screen Savers"
SAVERAPP="${SAVERDIR}/NoirSaver.saver"
if command -v swiftc >/dev/null 2>&1 && command -v xcrun >/dev/null 2>&1; then
  say "Compiling NoirSaver (the screen saver)…"
  SSRC="$(mktemp -d)/NoirSaver.swift"
  cat > "$SSRC" <<'SAVERSRC'
// NoirSaver — a real macOS screen saver that renders the live brief page.
//
// This is a legacy .saver bundle, which macOS still loads on 26 via the
// legacyScreenSaver host. Three things about that host will bite you and are
// handled below:
//
//   1. It reports document.visibilityState === 'hidden', which pauses
//      requestAnimationFrame and CSS transitions — the animation would
//      simply never run. A user script at document-start lies about it.
//   2. init(frame:isPreview:) is sometimes handed a zero rect, and the
//      bounds it later reports are in backing pixels rather than points,
//      so on a scaled display the web view lands off-screen.
//   3. The bundle is memory-mapped, so new code needs `killall
//      legacyScreenSaver` before it is picked up.
//
// Built by the installer with:
//   swiftc -emit-library -Xlinker -bundle -framework ScreenSaver …

import ScreenSaver
import WebKit
import AppKit

@objc(NoirSaverView)
public final class NoirSaverView: ScreenSaverView {

    private var web: WKWebView?
    private var inPreview = false      // ScreenSaverView already has `preview`
    private let page = URL(fileURLWithPath: "@@PAGE@@")
    private var usedFallback = false

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        inPreview = isPreview
        animationTimeInterval = 1.0 / 30.0          // the page drives itself
        if frame.width < 2 || frame.height < 2, let s = NSScreen.main?.frame.size {
            setFrameSize(s)                          // guard against the zero rect
        }
    }

    public required init?(coder: NSCoder) { super.init(coder: coder) }

    // MARK: - web view

    private func makeWeb() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()      // leave nothing behind
        cfg.suppressesIncrementalRendering = true

        let shim = """
        try {
          Object.defineProperty(Document.prototype, 'hidden', {
            configurable: true, get: function () { return false; } });
          Object.defineProperty(Document.prototype, 'visibilityState', {
            configurable: true, get: function () { return 'visible'; } });
        } catch (e) {}
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: shim, injectionTime: .atDocumentStart,
                         forMainFrameOnly: false))

        let v = WKWebView(frame: bounds, configuration: cfg)
        v.setValue(false, forKey: "drawsBackground")
        v.navigationDelegate = self
        return v                                     // no autoresizingMask: see layoutWeb()
    }

    /// The host hands us bounds in backing pixels. Clamping against the
    /// screen's frame — which is always in points — keeps the view on screen
    /// on a Retina or scaled display.
    private func layoutWeb() {
        guard let v = web else { return }
        var size = bounds.size
        if !inPreview, let screen = window?.screen?.frame.size {
            size = NSSize(width: min(size.width, screen.width),
                          height: min(size.height, screen.height))
        }
        v.frame = NSRect(origin: .zero, size: size)
    }

    private func loadPage() {
        guard let v = web else { return }
        let dir = page.deletingLastPathComponent()
        if FileManager.default.isReadableFile(atPath: page.path) {
            v.loadFileURL(page, allowingReadAccessTo: dir)
        } else {
            loadFallback()
        }
    }

    /// If the host's sandbox will not read the live page, show the copy that
    /// shipped inside the bundle rather than a black screen.
    private func loadFallback() {
        usedFallback = true
        guard let v = web,
              let res = Bundle(for: NoirSaverView.self)
                  .url(forResource: "saver", withExtension: "html") else { return }
        v.loadFileURL(res, allowingReadAccessTo: res.deletingLastPathComponent())
    }

    // MARK: - lifecycle

    public override func startAnimation() {
        super.startAnimation()
        if web == nil {
            let v = makeWeb()
            addSubview(v)
            web = v
        }
        layoutWeb()
        loadPage()
    }

    public override func stopAnimation() {
        super.stopAnimation()
        // System Settings previews leak web views otherwise.
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.removeFromSuperview()
        web = nil
    }

    public override func animateOneFrame() { /* the page animates itself */ }

    public override var hasConfigureSheet: Bool { false }
    public override var configureSheet: NSWindow? { nil }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); layoutWeb() }
    public override func layout() { super.layout(); layoutWeb() }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); layoutWeb()
    }
    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize); layoutWeb()
    }

    public override func draw(_ rect: NSRect) {
        NSColor(red: 13/255, green: 12/255, blue: 11/255, alpha: 1).setFill()
        rect.fill()
    }
}

extension NoirSaverView: WKNavigationDelegate {
    public func webView(_ w: WKWebView, didFailProvisionalNavigation nav: WKNavigation!,
                        withError error: Error) {
        if !usedFallback { loadFallback() }
    }
}
SAVERSRC
  # the bundle cannot take arguments, so the page path is baked in
  python3 - "$SSRC" "$DIR/saver.html" <<'PY'
import sys
p, page = sys.argv[1], sys.argv[2]
s = open(p).read().replace("@@PAGE@@", page)
open(p, "w").write(s)
PY
  mkdir -p "${SAVERAPP}/Contents/MacOS" "${SAVERAPP}/Contents/Resources"
  cat > "${SAVERAPP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NoirSaver</string>
  <key>CFBundleExecutable</key><string>NoirSaver</string>
  <key>CFBundleIdentifier</key><string>com.editorialnoir.noirsaver</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>NSPrincipalClass</key><string>NoirSaverView</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
  if swiftc -O -target "$(uname -m)-apple-macos13.0" \
       -sdk "$(xcrun --show-sdk-path)" \
       -framework ScreenSaver -framework WebKit -framework AppKit \
       -emit-library -Xlinker -bundle -module-name NoirSaver \
       -o "${SAVERAPP}/Contents/MacOS/NoirSaver" "$SSRC" 2>"$DIR/saver-build.log"; then
    # a copy inside the bundle, in case the host sandbox will not read ~/Pictures
    cp -f "$DIR/saver.html" "${SAVERAPP}/Contents/Resources/saver.html" 2>/dev/null || true
    cp -Rf "$DIR/fonts" "${SAVERAPP}/Contents/Resources/" 2>/dev/null || true
    codesign --force --deep --sign - "${SAVERAPP}" 2>/dev/null || true
    killall legacyScreenSaver 2>/dev/null || true   # the bundle is mmap'd
    SAVER_OK=1
    say "Installed ${SAVERAPP}"
  else
    warn "NoirSaver failed to compile — see ${DIR}/saver-build.log"
    warn "The folder-based Photos screen saver still works as before."
  fi
else
  warn "swiftc/xcrun missing — skipping the screen saver bundle."
fi

say "First build — fetching live data…"
if [[ $WALL_OK -eq 1 ]]; then
  "$PYBIN" "$DIR/brief.py" --no-wallpaper || warn "the first build hit errors; see above"
else
  "$PYBIN" "$DIR/brief.py" || warn "the first build hit errors; see above"
fi

say "Scheduling a rebuild every 15 minutes…"
cat > "${LA}/${BRIEF_LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${BRIEF_LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>${PYBIN}</string><string>${DIR}/brief.py</string>${BUILD_ARGS}</array>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${DIR}/brief.log</string>
  <key>StandardErrorPath</key><string>${DIR}/brief.log</string>
</dict></plist>
PLIST
# bootout is async: wait for the old job to be gone before bootstrapping,
# else bootstrap fails with "5: Input/output error". Then start it for real.
reload_agent() {
  local label="$1" plist="$2" dom="gui/$(id -u)" i
  launchctl bootout "${dom}/${label}" 2>/dev/null || true
  for i in {1..50}; do
    launchctl print "${dom}/${label}" >/dev/null 2>&1 || break
    sleep 0.1
  done
  launchctl bootstrap "${dom}" "${plist}"
  launchctl kickstart "${dom}/${label}" 2>/dev/null || true
}
reload_agent "${BRIEF_LABEL}" "${LA}/${BRIEF_LABEL}.plist"

if [[ $WALL_OK -eq 1 ]]; then
  say "Starting the renderer at login…"
  cat > "${LA}/${WALL_LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${WALL_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${APP}/Contents/MacOS/NoirWall</string>
    <string>${DIR}/index.html</string>
    <string>300</string>
    <string>--menu-only</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${DIR}/wall.log</string>
  <key>StandardErrorPath</key><string>${DIR}/wall.log</string>
</dict></plist>
PLIST
  reload_agent "${WALL_LABEL}" "${LA}/${WALL_LABEL}.plist"
fi

say "Checking that the schedule actually took…"
sleep 3
if launchctl print "gui/$(id -u)/${BRIEF_LABEL}" >/dev/null 2>&1; then
  say "Rebuild agent is loaded."
else
  warn "The rebuild agent did NOT load. Run this and send me the output:"
  warn "  launchctl print gui/\$(id -u)/${BRIEF_LABEL}"
fi

cat <<EOF

  Done.

  Screen saver   $(if [[ $SAVER_OK -eq 1 ]]; then
                    echo "NoirSaver is installed — a real animated screen saver, not a"
                    echo "                 slideshow. Pick it once: System Settings ▸ Screen Saver ▸"
                    echo "                 Other ▸ NoirSaver. Cards cycle every 7s with a live clock."
                  else
                    echo "Falling back to the Photos saver over the noir folder."
                  fi)

  Desktop        $(if [[ $WALL_OK -eq 1 ]]; then
                    echo "Your own wallpaper, untouched. Headlines live in the menu-bar"
                    echo "                 dot — grouped, deduped, click one to open it — or in a real"
                    echo "                 window from the same menu. A wallpaper is covered when you"
                    echo "                 work and visible when you are not reading, so it is the"
                    echo "                 wrong surface for headlines."
                  else
                    echo "The wallpaper is repainted with each snapshot. If the first"
                    echo "                 run said \"wallpaper refresh refused\", allow it under"
                    echo "                 System Settings ▸ Privacy & Security ▸ Automation."
                  fi)

  Logs           ${DIR}/brief.log$(if [[ $WALL_OK -eq 1 ]]; then echo "  and  ${DIR}/wall.log"; fi)
  Rebuild now    python3 "${DIR}/brief.py"
  Preview        python3 "${DIR}/brief.py" --mock

  Tuning: FEEDS and WATCH are plain lists at the top of brief.py. The drawn
  layer is the <script> block at the bottom of the TEMPLATE in the same file.

EOF
