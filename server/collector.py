"""Сборщик анонимной статистики и отзывов «Суфлёра».

Один файл без зависимостей: стандартная библиотека Python и SQLite.
  POST /v1/usage     — счётчики за прошедшие дни (только от тех, кто разрешил отправку)
  POST /v1/feedback  — отзыв из приложения
  GET  /v1/health    — проверка, что сервер жив
  GET  /dashboard?t=<ключ> — сводка для владельца: сколько людей, активность по дням, отзывы

Данные лежат в /data/stats.sqlite, ключ доступа к сводке — в /data/token (создаётся при первом запуске).
"""

import html
import json
import os
import re
import secrets
import sqlite3
import threading
import time
import urllib.request
from datetime import date, datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DATA = os.environ.get("DATA", "/data")
DB = os.path.join(DATA, "stats.sqlite")
REPO = "madebyhidden/sufler"
MAX_BODY = 64 * 1024
DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")
KEY = re.compile(r"^[a-z_]{1,40}$")

os.makedirs(DATA, exist_ok=True)
TOKEN_FILE = os.path.join(DATA, "token")
if not os.path.exists(TOKEN_FILE):
    with open(TOKEN_FILE, "w") as f:
        f.write(secrets.token_urlsafe(24))
TOKEN = open(TOKEN_FILE).read().strip()

lock = threading.Lock()
db = sqlite3.connect(DB, check_same_thread=False)
db.executescript("""
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS installs(id TEXT PRIMARY KEY, app TEXT, version TEXT, os TEXT, memory_gb INTEGER, mode TEXT, first_seen TEXT, last_seen TEXT);
CREATE TABLE IF NOT EXISTS usage(install TEXT, day TEXT, key TEXT, value REAL, PRIMARY KEY(install, day, key));
CREATE TABLE IF NOT EXISTS feedback(id INTEGER PRIMARY KEY, received TEXT, kind TEXT, text TEXT, contact TEXT, app TEXT, version TEXT, os TEXT, memory_gb INTEGER, models TEXT, mode TEXT);
""")

# Простая защита от потока запросов: не больше 60 в минуту с одного адреса
hits: dict[str, list[float]] = {}


def allowed(ip: str) -> bool:
    now = time.time()
    with lock:
        recent = [t for t in hits.get(ip, []) if now - t < 60]
        recent.append(now)
        hits[ip] = recent
        if len(hits) > 5000:
            hits.clear()
        return len(recent) <= 60


def s(v, n: int) -> str:
    return str(v)[:n] if v is not None else ""


def save_usage(p: dict) -> None:
    install = s(p.get("install"), 64)
    if not re.match(r"^[A-Za-z0-9-]{8,64}$", install):
        raise ValueError("install")
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    app = s(p.get("app"), 16)
    with lock, db:
        db.execute("""INSERT INTO installs(id, app, version, os, memory_gb, mode, first_seen, last_seen) VALUES(?,?,?,?,?,?,?,?)
                      ON CONFLICT(id) DO UPDATE SET app=excluded.app, version=excluded.version, os=excluded.os,
                      memory_gb=excluded.memory_gb, mode=excluded.mode, last_seen=excluded.last_seen""",
                   (install, app, s(p.get("version"), 20), s(p.get("os"), 120), int(p.get("memory_gb") or 0), s(p.get("mode"), 20), now, now))
        for d in (p.get("days") or [])[:90]:
            day = s(d.get("day"), 10)
            if not DAY.match(day):
                continue
            for k, v in list((d.get("counters") or {}).items())[:40]:
                if KEY.match(k) and isinstance(v, (int, float)) and 0 <= v < 1e10:
                    # Повторная отправка того же дня не удваивает счётчик
                    db.execute("INSERT OR REPLACE INTO usage(install, day, key, value) VALUES(?,?,?,?)", (install, day, k, float(v)))


def save_feedback(p: dict) -> None:
    text = s(p.get("text"), 5000).strip()
    if len(text) < 3:
        raise ValueError("text")
    with lock, db:
        db.execute("INSERT INTO feedback(received, kind, text, contact, app, version, os, memory_gb, models, mode) VALUES(?,?,?,?,?,?,?,?,?,?)",
                   (datetime.now(timezone.utc).isoformat(timespec="seconds"), s(p.get("kind"), 20), text, s(p.get("contact"), 200),
                    s(p.get("app"), 16), s(p.get("version"), 20), s(p.get("os"), 120), int(p.get("memory_gb") or 0), s(p.get("models"), 300), s(p.get("mode"), 20)))


# Скачивания с GitHub: сколько раз брали каждую версию — видно и без согласия на статистику
downloads_cache = {"at": 0.0, "rows": []}


def downloads() -> list:
    if time.time() - downloads_cache["at"] > 3600:
        try:
            req = urllib.request.Request(f"https://api.github.com/repos/{REPO}/releases?per_page=100", headers={"User-Agent": "sufler-stats"})
            rel = json.load(urllib.request.urlopen(req, timeout=10))
            rows = []
            for r in rel:
                n = sum(a.get("download_count", 0) for a in r.get("assets", []) if a["name"].endswith((".zip", ".dmg")))
                if n and r.get("tag_name") != "win-channel":
                    rows.append((r["tag_name"], n))
            downloads_cache.update(at=time.time(), rows=rows)
        except Exception:
            downloads_cache["at"] = time.time() - 3000
    return downloads_cache["rows"]


def bars(points: list, color: str, label: str) -> str:
    """Столбики за последние дни — простой SVG без внешних библиотек."""
    w, h, pad = 720, 140, 24
    top = max([v for _, v in points] + [1])
    bw = (w - pad) / max(1, len(points))
    out = [f'<svg viewBox="0 0 {w} {h + 22}" class="chart" role="img" aria-label="{html.escape(label)}">']
    for i, (d, v) in enumerate(points):
        bh = (h - 10) * v / top
        x = pad + i * bw
        out.append(f'<rect x="{x + 1:.1f}" y="{h - bh:.1f}" width="{max(1, bw - 2):.1f}" height="{bh:.1f}" rx="2" fill="{color}"><title>{d}: {v:g}</title></rect>')
        if i % 7 == 0:
            out.append(f'<text x="{x:.1f}" y="{h + 16}" class="ax">{d[5:]}</text>')
    out.append(f'<text x="0" y="12" class="ax">{top:g}</text></svg>')
    return "".join(out)


def dashboard() -> str:
    today = date.today()
    days = [(today - timedelta(days=i)).isoformat() for i in range(59, -1, -1)]
    with lock:
        q = lambda sql, *a: db.execute(sql, a).fetchall()
        total = q("SELECT COUNT(*) FROM installs")[0][0]
        by_app = dict(q("SELECT app, COUNT(*) FROM installs GROUP BY app"))
        active = {d: n for d, n in q("SELECT day, COUNT(DISTINCT install) FROM usage WHERE day >= ? GROUP BY day", days[0])}
        newbies = {d: n for d, n in q("SELECT substr(first_seen,1,10), COUNT(*) FROM installs GROUP BY 1")}
        minutes = {d: v for d, v in q("SELECT day, SUM(value) FROM usage WHERE key='recorded_minutes' AND day >= ? GROUP BY day", days[0])}
        sums = dict(q("SELECT key, SUM(value) FROM usage GROUP BY key"))
        versions = q("SELECT app, version, COUNT(*) FROM installs GROUP BY app, version ORDER BY app, version DESC")
        def active_in(n):
            return q("SELECT COUNT(DISTINCT install) FROM usage WHERE day >= ?", (today - timedelta(days=n - 1)).isoformat())[0][0]
        a1, a7, a30 = active_in(1), active_in(7), active_in(30)
        fb = q("SELECT received, kind, text, contact, app, version, os, memory_gb, models, mode FROM feedback ORDER BY id DESC LIMIT 200")
    e = html.escape
    tiles = [
        ("Установок с согласием", total, " · ".join(f"{e(k or '?')}: {v}" for k, v in by_app.items())),
        ("Активны сегодня", a1, f"за 7 дней: {a7} · за 30 дней: {a30}"),
        ("Часов записи", round((sums.get("recorded_minutes") or 0) / 60, 1), f"встреч: {int(sums.get('meetings') or 0)}"),
        ("Слов расшифровано", int(sums.get("words") or 0), f"вопросов найдено: {int(sums.get('questions') or 0)}"),
        ("Токенов модели", int((sums.get("llm_in") or 0) + (sums.get("llm_out") or 0)), f"запросов: {int(sums.get('llm_requests') or 0)}"),
        ("Отзывов", len(fb), f"скачиваний всего: {sum(n for _, n in downloads())}"),
    ]
    kinds = {"idea": "💡 идея", "bug": "🐞 ошибка", "other": "💬 другое"}
    rows = "".join(
        f"<div class='fb'><div class='meta'>{e(r[0][:16].replace('T', ' '))} · {kinds.get(r[1], e(r[1]))} · {e(r[4])} {e(r[5])}"
        f"{' · ' + e(r[6]) if r[6] else ''}{' · ' + str(r[7]) + ' ГБ' if r[7] else ''}{' · ' + e(r[9]) if r[9] else ''}</div>"
        f"<div class='txt'>{e(r[2])}</div>{'<div class=contact>Связь: ' + e(r[3]) + '</div>' if r[3] else ''}</div>"
        for r in fb) or "<p class='muted'>Отзывов пока нет.</p>"
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Суфлёр — статистика</title><style>
:root{{--bg:#f3f4f8;--card:#fff;--ink:#1b1c22;--muted:#6b6f7b;--accent:#5c57eb;--line:#e6e7ee}}
@media (prefers-color-scheme:dark){{:root{{--bg:#151619;--card:#1f2025;--ink:#ececf1;--muted:#9a9db0;--line:#2c2e35}}}}
body{{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 -apple-system,Segoe UI,Roboto,sans-serif}}
main{{max-width:980px;margin:0 auto;padding:28px 16px 60px}}h1{{margin:0 0 4px;font-size:26px}}h2{{font-size:17px;margin:28px 0 10px}}
.muted{{color:var(--muted)}}.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:12px;margin-top:18px}}
.tile,.box,.fb{{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 16px}}
.tile .n{{font-size:28px;font-weight:650}}.tile .t{{color:var(--muted);font-size:13px}}.tile .s{{color:var(--muted);font-size:12px}}
.chart{{width:100%;height:auto}}.ax{{font-size:11px;fill:var(--muted)}}.fb{{margin-bottom:10px}}.fb .meta{{font-size:12px;color:var(--muted)}}
.fb .txt{{white-space:pre-wrap;margin-top:4px}}.contact{{font-size:13px;margin-top:6px;color:var(--accent)}}
table{{border-collapse:collapse;width:100%}}td{{padding:4px 8px;border-bottom:1px solid var(--line);font-size:14px}}
</style></head><body><main>
<h1>Суфлёр — статистика</h1><div class="muted">Только люди, разрешившие отправку анонимной статистики. Обновлено {datetime.now().strftime('%d.%m.%Y %H:%M')}.</div>
<div class="grid">{''.join(f"<div class='tile'><div class='t'>{e(t)}</div><div class='n'>{v:,}</div><div class='s'>{s_}</div></div>".replace(',', ' ') for t, v, s_ in tiles)}</div>
<h2>Активные установки по дням</h2><div class="box">{bars([(d, active.get(d, 0)) for d in days], '#5c57eb', 'Активные установки')}</div>
<h2>Минуты записи по дням</h2><div class="box">{bars([(d, round(minutes.get(d, 0))) for d in days], '#2ead5b', 'Минуты записи')}</div>
<h2>Новые установки по дням</h2><div class="box">{bars([(d, newbies.get(d, 0)) for d in days], '#f0932b', 'Новые установки')}</div>
<h2>Версии</h2><div class="box"><table>{''.join(f'<tr><td>{e(a or "?")}</td><td>{e(v)}</td><td>{n}</td></tr>' for a, v, n in versions) or '<tr><td class=muted>Пока нет данных</td></tr>'}</table></div>
<h2>Скачивания с GitHub</h2><div class="box"><table>{''.join(f'<tr><td>{e(t)}</td><td>{n}</td></tr>' for t, n in downloads()) or '<tr><td class=muted>Нет данных</td></tr>'}</table></div>
<h2>Отзывы</h2>{rows}
</main></body></html>"""


def local(h) -> bool:
    """Запрос пришёл напрямую из домашней сети, а не через прокси из интернета."""
    if h.headers.get("X-Forwarded-For") or h.headers.get("X-Real-IP"):
        return False
    ip = h.client_address[0]
    return ip.startswith(("192.168.", "10.", "127.")) or any(ip.startswith(f"172.{n}.") for n in range(16, 32))


class Handler(BaseHTTPRequestHandler):
    server_version = "sufler-stats"

    def ip(self) -> str:
        return self.headers.get("X-Real-IP") or self.headers.get("X-Forwarded-For", "").split(",")[0].strip() or self.client_address[0]

    def reply(self, code: int, body: str, kind: str = "application/json") -> None:
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", kind + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def route(self) -> str:
        # Через прокси на minijir.space адреса приходят с приставкой /sufler — убираем её
        p = urlparse(self.path).path
        return p[len("/sufler"):] if p.startswith("/sufler/") else p

    def do_GET(self):
        u = urlparse(self.path)
        u = u._replace(path=self.route())
        if u.path == "/v1/health":
            return self.reply(200, '{"ok":true}')
        if u.path == "/dashboard":
            # Сводка открывается только из домашней сети: из интернета её как будто нет
            if not local(self):
                return self.reply(404, '{"error":"not found"}')
            if not secrets.compare_digest(parse_qs(u.query).get("t", [""])[0], TOKEN):
                return self.reply(403, "нет доступа", "text/plain")
            return self.reply(200, dashboard(), "text/html")
        self.reply(404, '{"error":"not found"}')

    def do_POST(self):
        if not allowed(self.ip()):
            return self.reply(429, '{"error":"too many"}')
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > MAX_BODY:
            return self.reply(413, '{"error":"size"}')
        try:
            payload = json.loads(self.rfile.read(n))
            if self.route() == "/v1/usage":
                save_usage(payload)
            elif self.route() == "/v1/feedback":
                save_feedback(payload)
            else:
                return self.reply(404, '{"error":"not found"}')
        except Exception:
            return self.reply(400, '{"error":"bad request"}')
        self.reply(200, '{"ok":true}')

    def log_message(self, fmt, *args):
        # Адреса и тела запросов не пишем в журнал
        pass


if __name__ == "__main__":
    print("sufler-stats на порту 8080", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
