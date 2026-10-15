#!/usr/bin/env python3
"""Usage numbers from the release files' download counts, for the README card.

    scripts/stats.py OUT_DIR        # GITHUB_TOKEN and GITHUB_REPOSITORY from the environment

The app downloads version.json on every update check, install.json once ever and month.json once a calendar month
(App/Support/Updates.swift), so summed over all releases their counts are checks, installs and monthly actives.
OUT_DIR (the `stats` branch) keeps history.csv, one row of running totals per day; this run adds or replaces today's
row, then writes stats.json, shields.io endpoint files and card.<lang>.svg.
"""
import csv, datetime, json, os, sys, urllib.request

LABELS = {
    "en": ("INSTALLS", "ACTIVE THIS MONTH", "DOWNLOADS"),
    "ko": ("설치", "이번 달 사용", "다운로드"),
    "ja": ("インストール", "今月のアクティブ", "ダウンロード"),
    "zh-CN": ("安装", "本月活跃", "下载"),
}
FIELDS = ["date", "installs", "months", "checks", "downloads"]


def releases(repo, token):
    page, out = 1, []
    while True:
        req = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases?per_page=100&page={page}",
                                     headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"})
        batch = json.load(urllib.request.urlopen(req))
        out += batch
        if len(batch) < 100:
            return out
        page += 1


def totals(rels):
    t = {"installs": 0, "months": 0, "checks": 0, "downloads": 0}
    for r in rels:
        for a in r["assets"]:
            key = {"install.json": "installs", "month.json": "months", "version.json": "checks"}.get(a["name"])
            if key:
                t[key] += a["download_count"]
            elif a["name"].endswith(".dmg"):
                t["downloads"] += a["download_count"]
    return t


def monthly_active(history, today):
    """month.json downloads since the last row of an earlier month (each install counts once a month)."""
    month = today[:7]
    before = [r for r in history if r["date"][:7] < month]
    base = int(before[-1]["months"]) if before else 0
    now = int(history[-1]["months"])
    return now - base


def short(n):
    return f"{n / 1000:.1f}k".replace(".0k", "k") if n >= 1000 else str(n)


def card(version, numbers, labels):
    cells = "".join(
        f'<text x="{x}" y="47" class="v">{short(n)}</text><text x="{x}" y="68" class="l">{label}</text>'
        for x, n, label in zip((228, 368, 528), numbers, labels))
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="660" height="96" viewBox="0 0 660 96">
<defs>
<linearGradient id="ring" x1="0" y1="0" x2="1" y2="1">
<stop offset="0" stop-color="#ff9f0a"/><stop offset=".3" stop-color="#ff375f"/><stop offset=".55" stop-color="#bf5af2"/>
<stop offset=".8" stop-color="#5e5ce6"/><stop offset="1" stop-color="#64d2ff"/></linearGradient>
<style>
text {{ font-family: -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Hiragino Sans", "PingFang SC", "Segoe UI", Helvetica, Arial, sans-serif; }}
.n {{ font-size: 20px; font-weight: 700; fill: #fff; }}
.s {{ font-size: 13px; fill: #9a9ca5; }}
.v {{ font-size: 26px; font-weight: 700; fill: #fff; }}
.l {{ font-size: 11px; font-weight: 600; fill: #9a9ca5; letter-spacing: .04em; }}
</style>
</defs>
<rect x="1.5" y="1.5" width="657" height="93" rx="22" fill="#141519" stroke="url(#ring)" stroke-width="2"/>
<circle cx="40" cy="48" r="9" fill="url(#ring)"/>
<text x="60" y="47" class="n">Mwoyeo</text>
<text x="60" y="68" class="s">{version}</text>
<line x1="204" y1="24" x2="204" y2="72" stroke="#2a2c33"/>
{cells}
</svg>
'''


def main():
    out = sys.argv[1]
    repo, token = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_TOKEN"]
    rels = [r for r in releases(repo, token) if not r["draft"]]
    t = totals(rels)
    today = datetime.date.today().isoformat()

    path = os.path.join(out, "history.csv")
    history = list(csv.DictReader(open(path))) if os.path.exists(path) else []
    history = [r for r in history if r["date"] != today] + [{"date": today, **{k: str(v) for k, v in t.items()}}]
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, FIELDS, lineterminator="\n")
        w.writeheader()
        w.writerows(history)

    latest = next((r for r in rels if not r["prerelease"]), None)
    version = latest["tag_name"] if latest else ""
    active = monthly_active(history, today)
    stats = {"version": version, "installs": t["installs"], "activeThisMonth": active,
             "downloads": t["downloads"], "checks": t["checks"], "updated": today}
    json.dump(stats, open(os.path.join(out, "stats.json"), "w"), indent=2)
    for name, label, n, color in [("installs", "installs", t["installs"], "ff375f"),
                                  ("active", "active this month", active, "bf5af2"),
                                  ("downloads", "downloads", t["downloads"], "ff9f0a")]:
        json.dump({"schemaVersion": 1, "label": label, "message": short(n), "color": color},
                  open(os.path.join(out, f"{name}.json"), "w"))
    for lang, labels in LABELS.items():
        with open(os.path.join(out, f"card.{lang}.svg"), "w") as f:
            f.write(card(version, (t["installs"], active, t["downloads"]), labels))
    print(json.dumps(stats))


if __name__ == "__main__":
    main()
