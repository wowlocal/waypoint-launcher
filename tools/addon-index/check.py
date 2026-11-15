#!/usr/bin/env python3
"""Checks Waypoint's add-on index against the add-ons' own releases.

For each GitHub repo, reads the latest release.json through GitHub's web
download URL (no API quota), downloads the zip it names, and prints the
zip's top-level folders and the IDs in the main TOC. Use the output to fill
or re-check entries in Sources/WaypointCore/AddOns/AddOnIndex.swift.
Not shipped; needs only the Python standard library.

    tools/addon-index/check.py BigWigsMods/BigWigs DeadlyBossMods/DeadlyBossMods
    tools/addon-index/check.py --all
"""
import io, json, re, subprocess, sys, urllib.request, zipfile

# Interface number ranges per game (WoWFlavor.swift).
RANGES = [(11300, 15999, "vanilla"), (16000, 19999, "forever"), (20500, 29999, "tbc"), (30400, 37999, "wrath"),
          (38000, 39999, "titan"), (40400, 49999, "cata"), (50500, 59999, "mists"), (60000, 999999, "mainline")]
LABELS = {"mainline": "mainline", "classic": "vanilla", "bcc": "tbc", "wrath": "wrath", "titan": "titan",
          "cata": "cata", "mists": "mists", "forever": "forever"}

# Each game's current interface number: a release counts for a game only
# when it's built for its current patch line (retail: the same major,
# 12.x; the classic games: the same major and minor, 1.15). Update these
# with each new patch line, as ReleaseManifest does from the game itself.
CURRENT = {"mainline": 120105, "vanilla": 11509, "forever": 16001, "tbc": 20506, "wrath": 30405,
           "titan": 38002, "cata": 40402, "mists": 50504}

def game(meta):
    interface = meta.get("interface")
    try:
        number = int(interface)
    except (TypeError, ValueError):
        return None
    for low, high, name in RANGES:
        if low <= number <= high:
            line = 10000 if name == "mainline" else 100
            return name if number // line == CURRENT[name] // line else None
    return None

def is_fork(repo):
    try:
        return json.loads(subprocess.check_output(["gh", "api", f"repos/{repo}", "--jq", "{fork,parent:.parent.full_name,stars:.stargazers_count,archived}"], text=True))
    except Exception as e:
        return {"error": str(e)}

KEYS = ("X-Curse-Project-ID", "X-Wago-ID", "X-WoWI-ID", "Title", "Author")

class FirstRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self.first = getattr(self, "first", None) or newurl
        return super().redirect_request(req, fp, code, msg, headers, newurl)

RELEASED = {}

def get(url):
    """The body and the first redirect: github.com's own URL for the asset,
    which names the tag. The final URL is a signed CDN link."""
    handler = FirstRedirect()
    req = urllib.request.Request(url, headers={"User-Agent": "Waypoint add-on index check"})
    with urllib.request.build_opener(handler).open(req, timeout=60) as r:
        RELEASED[url] = r.headers.get("Last-Modified")
        return getattr(handler, "first", None) or r.geturl(), r.read()

def toc_values(text):
    values = {}
    for line in text.splitlines():
        m = re.match(r"##\s*([^:]+?)\s*:\s*(.*)$", line)
        if m and m.group(1) in KEYS and m.group(1) not in values:
            values[m.group(1)] = re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", m.group(2)).strip()
    return values

def check(arg):
    repo, _, main = arg.partition("=")
    final, body = get(f"https://github.com/{repo}/releases/latest/download/release.json")
    release = next(r for r in json.loads(body)["releases"] if not r.get("nolib"))
    zip_url = final.rsplit("/", 1)[0] + "/" + release["filename"]
    _, data = get(zip_url)
    z = zipfile.ZipFile(io.BytesIO(data))
    folders = sorted({n.split("/")[0] for n in z.namelist() if "/" in n and not n.startswith("__MACOSX")})
    main = main or min(folders, key=len)
    tocs = sorted(n for n in z.namelist() if re.fullmatch(rf"{re.escape(main)}/{re.escape(main)}([_-]\w+)?\.toc", n, re.I))
    # Every TOC's values: a plain TOC can be a "client not supported" stub.
    values = {}
    for toc in tocs:
        for key, value in toc_values(z.read(toc).decode("utf-8-sig", "replace")).items():
            values.setdefault(key, value)
    flavors = sorted({game(m) for r in json.loads(body)["releases"] if not r.get("nolib") for m in r.get("metadata", [])} - {None})
    # No release in a year: not offered, whatever it says it supports.
    import email.utils, time
    released = RELEASED.get(f"https://github.com/{repo}/releases/latest/download/release.json")
    age = time.time() - email.utils.parsedate_to_datetime(released).timestamp() if released else None
    if age is not None and age > 365 * 86400:
        flavors = []
    print(json.dumps({"repo": repo, "version": release.get("version"), "released": released, "folders": folders, "main": main,
                      "flavors": flavors, "github": is_fork(repo), **values}))

def indexed():
    """Every GitHub entry of the index, as "owner/repo=MainFolder"."""
    import pathlib
    source = (pathlib.Path(__file__).resolve().parents[2] / "Sources/WaypointCore/AddOns/AddOnIndex.swift").read_text()
    return [f"{repo}={folder}" for repo, folder in
            re.findall(r'github\("[^"]*", "[^"]*", "([^"]+)", \["([^"]+)"', source)]

# "owner/repo=Folder" names the main folder when the shortest isn't it.
# --all: every entry in the index (run it now and then: a repository that
# stops publishing, or stops supporting a game, shows up here).
args = indexed() if sys.argv[1:] == ["--all"] else sys.argv[1:]
for arg in args:
    try:
        check(arg)
    except Exception as e:
        print(json.dumps({"repo": arg, "error": str(e)}))
