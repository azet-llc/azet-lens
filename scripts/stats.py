#!/usr/bin/env python3
"""Usage numbers from the release files' download counts, for the README badges.

    scripts/stats.py OUT_DIR        # GITHUB_TOKEN and GITHUB_REPOSITORY from the environment

The app downloads version.json on every update check, install.json once ever and month.json once a calendar month
(App/Support/Updates.swift), so summed over all releases their counts are checks, installs and monthly actives.
OUT_DIR (the `stats` branch) keeps history.csv, one row of running totals per day; this run adds or replaces today's
row, then writes stats.json and the shields.io endpoint files the README badges read.
"""
import csv, datetime, json, os, sys, urllib.request

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
        # Releases from before the app counted itself (no install.json): their disk image downloads stand in for
        # installs. Someone who upgrades from one is counted again when the new version counts its install.
        if not any(a["name"] == "install.json" for a in r["assets"]):
            t["installs"] += sum(a["download_count"] for a in r["assets"] if a["name"].endswith(".dmg"))
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
    for name, label, n, color in [("installs", "installs", t["installs"], "e0457b"),
                                  ("active", "active this month", active, "bf5af2"),
                                  ("downloads", "downloads", t["downloads"], "ff375f")]:
        json.dump({"schemaVersion": 1, "label": label, "message": short(n), "color": color},
                  open(os.path.join(out, f"{name}.json"), "w"))
    print(json.dumps(stats))


if __name__ == "__main__":
    main()
