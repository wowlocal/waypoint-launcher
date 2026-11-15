#!/usr/bin/env python3
"""Checks Waypoint's add-on index against the add-ons' own releases.

For each GitHub repo, reads the latest release.json through GitHub's web
download URL (no API quota), downloads the zip it names, and prints the
zip's top-level folders and the IDs in the main TOC. Use the output to fill
or re-check entries in Sources/WaypointCore/AddOns/AddOnIndex.swift.
Not shipped; needs only the Python standard library.

    tools/addon-index/check.py BigWigsMods/BigWigs DeadlyBossMods/DeadlyBossMods
"""
import io, json, re, sys, urllib.request, zipfile

KEYS = ("X-Curse-Project-ID", "X-Wago-ID", "X-WoWI-ID", "Title", "Author")

class FirstRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self.first = getattr(self, "first", None) or newurl
        return super().redirect_request(req, fp, code, msg, headers, newurl)

def get(url):
    """The body and the first redirect: github.com's own URL for the asset,
    which names the tag. The final URL is a signed CDN link."""
    handler = FirstRedirect()
    req = urllib.request.Request(url, headers={"User-Agent": "Waypoint add-on index check"})
    with urllib.request.build_opener(handler).open(req, timeout=60) as r:
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
    flavors = sorted({m["flavor"] for r in json.loads(body)["releases"] for m in r.get("metadata", [])})
    print(json.dumps({"repo": repo, "version": release.get("version"), "folders": folders, "main": main,
                      "flavors": flavors, **values}))

# "owner/repo=Folder" names the main folder when the shortest isn't it.
for arg in sys.argv[1:]:
    try:
        check(arg)
    except Exception as e:
        print(json.dumps({"repo": arg, "error": str(e)}))
