# gen_pal_icons.py
# Fetch the work-suitability + element icons the dashboard / public site uses, from paldb.cc's
# CDN (hotlinking is blocked, so a Referer header is required and the files are downloaded
# server-side into pal_icons\, then bundled by gen_public_site.ps1 into public\icons\).
#
#   work_00..work_12.webp  <- T_icon_palwork_NN.webp        (work suitability icons)
#   elem_00..elem_08.webp  <- T_prt_palstatus_element_NN.webp (element icons)
#
# The 9 passive-frame PNGs (passive_frame / passive_triangle / passive_pos_1-4 / passive_neg_1-3)
# are static UI chrome that never changes, so they ship committed in this repo's pal_icons\ -- this
# script leaves them alone and just warns if any are missing.
#
# Idempotent: only fetches files that are missing or empty. Pass --force to re-download.
#
#     python gen_pal_icons.py [--force]

import os, sys, urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, "pal_icons")
HEADERS = {"Referer": "https://paldb.cc/", "User-Agent": "Mozilla/5.0"}
FORCE = "--force" in sys.argv[1:]

JOBS = []
for n in range(13):
    JOBS.append(("work_%02d.webp" % n,
                 "https://cdn.paldb.cc/image/Pal/Texture/UI/InGame/T_icon_palwork_%02d.webp" % n))
for n in range(9):
    JOBS.append(("elem_%02d.webp" % n,
                 "https://cdn.paldb.cc/image/Pal/Texture/UI/Main_Menu/T_prt_palstatus_element_%02d.webp" % n))

PASSIVE_PNGS = ["passive_frame.png", "passive_triangle.png",
                "passive_pos_1.png", "passive_pos_2.png", "passive_pos_3.png", "passive_pos_4.png",
                "passive_neg_1.png", "passive_neg_2.png", "passive_neg_3.png"]


def fetch(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=60).read()


def main():
    os.makedirs(OUT, exist_ok=True)
    got = skipped = failed = 0
    for name, url in JOBS:
        dest = os.path.join(OUT, name)
        if not FORCE and os.path.isfile(dest) and os.path.getsize(dest) > 0:
            skipped += 1
            continue
        try:
            data = fetch(url)
            if not data:
                raise ValueError("empty response")
            with open(dest, "wb") as f:
                f.write(data)
            got += 1
            print("got  " + name)
        except Exception as e:
            failed += 1
            print("FAIL %s (%s)" % (name, e))
    print("\nicons: %d downloaded, %d skipped, %d failed -> %s" % (got, skipped, failed, OUT))

    missing = [f for f in PASSIVE_PNGS if not os.path.isfile(os.path.join(OUT, f))]
    if missing:
        print("WARNING: committed passive-frame PNGs missing from pal_icons\\: %s" % missing)
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
