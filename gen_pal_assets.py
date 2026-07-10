"""
Download a LOCAL copy of the external assets the dashboard depends on, so the Pal
Box / Paldeck / Effigy views keep working even if the upstream sources are
removed or changed:

  * Pal portrait PNGs  (paldb.cc's per-Pal icon art, converted from webp)
        -> C:\\PalWorldServer\\PalAssets\\Pals\\<DisplayName>.png
  * Effigy location data (oMaN-Rod/palworld-save-pal: data/json/effigies.json)
        -> C:\\PalWorldServer\\effigies.json

Portraits are sourced from paldb.cc's "/en/Pals" listing page (same site the rest of
the pipeline already trusts for species/skills/passives/maps), requiring a Referer
header. Requires Pillow (already a soft dependency of gen_pal_icons.py) to convert the
fetched webp to PNG. The 11 special non-dex Yakushima-event Pals aren't on that listing
page, so their portraits are left as whatever is already on disk.

Idempotent: re-running only fetches files that are missing or empty. Pass --force to
re-download everything (e.g. after a Palworld update added new Pals).

    python gen_pal_assets.py [--force]
"""
import os, re, sys, time, json, urllib.request

from PIL import Image
import io

ROOT = os.path.dirname(os.path.abspath(__file__))
PAL_DIR = os.path.join(ROOT, "PalAssets", "Pals")
EFFIGY_FILE = os.path.join(ROOT, "effigies.json")
PALS_LIST_URL = "https://paldb.cc/en/Pals"
EFFIGY_URL = "https://raw.githubusercontent.com/oMaN-Rod/palworld-save-pal/main/data/json/effigies.json"
HEADERS = {"Referer": "https://paldb.cc/", "User-Agent": "Mozilla/5.0"}
FORCE = "--force" in sys.argv[1:]


def _get(url, headers=None):
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers or {"User-Agent": "Mozilla/5.0"}), timeout=60).read()


def list_portraits():
    """Parse paldb.cc's Pals listing into (display name -> icon webp URL) for every
    numbered dex Pal (base forms and variants alike)."""
    html = _get(PALS_LIST_URL, HEADERS).decode("utf-8", "replace")
    out = {}
    for ch in html.split('<div class="col" data-filters=')[1:]:
        ch = ch[:8000]
        m_name = re.search(r'<a class="itemname"[^>]*href="[^"]+">([^<]+)</a>', ch)
        m_icon = re.search(r'<img[^>]*src="(https://cdn\.paldb\.cc/image/Pal/Texture/PalIcon/[^"]+)"', ch)
        if not (m_name and m_icon):
            continue
        display = m_name.group(1)
        if display not in out:
            out[display] = m_icon.group(1)
    return out


def download_portraits():
    os.makedirs(PAL_DIR, exist_ok=True)
    portraits = list_portraits()
    got = skipped = failed = 0
    for i, (display, icon_url) in enumerate(sorted(portraits.items()), 1):
        dest = os.path.join(PAL_DIR, display + ".png")
        if not FORCE and os.path.isfile(dest) and os.path.getsize(dest) > 0:
            skipped += 1
            continue
        try:
            webp_bytes = _get(icon_url, HEADERS)
            im = Image.open(io.BytesIO(webp_bytes)).convert("RGBA")
            im.save(dest, "PNG")
            got += 1
            time.sleep(0.1)  # be polite to the CDN
        except Exception as ex:
            failed += 1
            print("  ! failed %s: %s" % (display, ex))
    print("Portraits: %d downloaded, %d already present, %d failed (%d listed on paldb)"
          % (got, skipped, failed, len(portraits)))


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
