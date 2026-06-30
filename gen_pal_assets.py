"""
Download a LOCAL copy of the external assets the dashboard depends on, so the Pal
Box / Paldeck / Effigy views keep working even if the upstream GitHub projects are
removed or changed:

  * Pal portrait PNGs  (palcalc: PalCalc.UI/Resources/Pals/*.png)
        -> C:\\PalWorldServer\\PalAssets\\Pals\\<DisplayName>.png
  * Effigy location data (oMaN-Rod/palworld-save-pal: data/json/effigies.json)
        -> C:\\PalWorldServer\\effigies.json

Idempotent: re-running only fetches files that are missing or empty. Pass --force to
re-download everything (e.g. after a Palworld update added new Pals).

    python gen_pal_assets.py [--force]
"""
import os, sys, json, time, urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
PAL_DIR = os.path.join(ROOT, "PalAssets", "Pals")
EFFIGY_FILE = os.path.join(ROOT, "effigies.json")
PALS_API = "https://api.github.com/repos/tylercamp/palcalc/contents/PalCalc.UI/Resources/Pals?ref=main"
EFFIGY_URL = "https://raw.githubusercontent.com/oMaN-Rod/palworld-save-pal/main/data/json/effigies.json"
FORCE = "--force" in sys.argv[1:]


def _get(url, accept=None):
    headers = {"User-Agent": "Mozilla/5.0"}
    if accept:
        headers["Accept"] = accept
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60).read()


def download_portraits():
    os.makedirs(PAL_DIR, exist_ok=True)
    listing = json.loads(_get(PALS_API, "application/vnd.github+json"))
    pngs = [e for e in listing if e["name"].lower().endswith(".png")]
    got = skipped = failed = 0
    for e in pngs:
        dest = os.path.join(PAL_DIR, e["name"])
        if not FORCE and os.path.isfile(dest) and os.path.getsize(dest) > 0:
            skipped += 1
            continue
        try:
            data = _get(e["download_url"])
            with open(dest, "wb") as f:
                f.write(data)
            got += 1
            time.sleep(0.05)  # be polite to the CDN
        except Exception as ex:
            failed += 1
            print("  ! failed %s: %s" % (e["name"], ex))
    print("Portraits: %d downloaded, %d already present, %d failed (%d total)"
          % (got, skipped, failed, len(pngs)))


def download_effigies():
    if not FORCE and os.path.isfile(EFFIGY_FILE) and os.path.getsize(EFFIGY_FILE) > 0:
        print("Effigies: already present (%s)" % EFFIGY_FILE)
        return
    data = _get(EFFIGY_URL)
    json.loads(data)  # validate
    with open(EFFIGY_FILE, "wb") as f:
        f.write(data)
    print("Effigies: downloaded -> %s (%d bytes)" % (EFFIGY_FILE, len(data)))


if __name__ == "__main__":
    download_portraits()
    download_effigies()
