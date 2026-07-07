# gen_pal_icons.py
# Fetch the work-suitability + element icons the dashboard / public site uses, from paldb.cc's
# CDN (hotlinking is blocked, so a Referer header is required and the files are downloaded
# server-side into pal_icons\, then bundled by gen_public_site.ps1 into public\icons\).
#
#   work_00..work_12.webp  <- T_icon_palwork_NN.webp        (work suitability icons)
#   elem_00..elem_08.webp  <- T_prt_palstatus_element_NN.webp (element icons)
#
# The 9 passive-pill PNGs (passive_frame / passive_triangle / passive_pos_1-4 / passive_neg_1-3)
# are simple grayscale UI chrome (a beveled frame, a triangle-tessellation strip, and stacked
# chevron "rank" arrows) that the passive-pill CSS tints at runtime. Rather than redistribute any
# third-party art, this script DRAWS them procedurally with Pillow -- they are authored primitives,
# so nothing game-owned ships in the repo. See build_passives().
#
# Idempotent: only fetches/draws files that are missing or empty. Pass --force to rebuild.
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

# Map-marker compass icons (Bounty/Field Boss, Eagle Statue, Tower). These were briefly
# hotlinked straight from cdn.paldb.cc in dashboard.html's marker builders -- works from some
# desktop browsers but 403s wherever the Referer header gets stripped or rewritten (notably
# common on mobile browsers), so the icons silently failed to load on phones. Bundling them
# here like every other paldb asset fixes that for good.
JOBS.append(("compass_bounty.webp",
             "https://cdn.paldb.cc/image/Pal/Texture/UI/InGame/T_icon_compass_Bounty.webp"))
JOBS.append(("compass_eagle.webp",
             "https://cdn.paldb.cc/image/Pal/Texture/UI/InGame/T_icon_compass_FTtower.webp"))
JOBS.append(("compass_tower.webp",
             "https://cdn.paldb.cc/image/Pal/Texture/UI/InGame/T_icon_compass_tower.webp"))

PASSIVE_PNGS = ["passive_frame.png", "passive_triangle.png",
                "passive_pos_1.png", "passive_pos_2.png", "passive_pos_3.png", "passive_pos_4.png",
                "passive_neg_1.png", "passive_neg_2.png", "passive_neg_3.png"]


def fetch(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=60).read()


# ---- Procedurally-drawn passive-pill chrome (authored primitives, no third-party art) ----
# All white/grayscale; the passive-pill CSS tints and 9-slices them at runtime. Arrows are drawn
# 4x-supersampled then LANCZOS-downscaled so the edges anti-alias like the originals.
_SS = 4
_WH = (255, 255, 255, 255)


def _caret(draw, xm, ay, up, w=17, h=7, tv=5, tip=3):
    # One bold "notched" chevron (a caret) centered on x=xm, apex at y=ay. The notch (inner apex
    # at ay+tv) is what keeps stacked carets visually separate instead of merging into a blob.
    L, R = xm - w / 2.0, xm + w / 2.0
    if up:
        pts = [(L, ay + h), (xm, ay), (R, ay + h), (R - tip, ay + h), (xm, ay + tv), (L + tip, ay + h)]
    else:
        pts = [(L, ay), (xm, ay + h), (R, ay), (R - tip, ay), (xm, ay + h - tv), (L + tip, ay)]
    draw.polygon([(x * _SS, y * _SS) for x, y in pts], fill=_WH)


def _arrow(Image, ImageDraw, n, up=True, plus=False):
    # n stacked chevrons (pos = up, neg = down); pos_4 adds n=3 plus a small "+" beneath.
    big = Image.new("RGBA", (24 * _SS, 24 * _SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    sp = 6 if plus else 7                      # tighter stack when we also need room for the "+"
    top = (24 - (sp * (n - 1) + 8)) // 2 - (3 if plus else 0)
    for i in range(n):
        _caret(d, 11.5, top + i * sp, up)
    if plus:
        d.rectangle([11 * _SS, 18 * _SS, 13 * _SS, 23 * _SS], fill=_WH)
        d.rectangle([9 * _SS, 19 * _SS, 15 * _SS, 21 * _SS], fill=_WH)
    return big.resize((24, 24), Image.LANCZOS)


def _frame(Image):
    # 216x36 beveled border used as a 6px 9-slice: outer 4px cream ring + a 2px faint band, then a
    # fully transparent center (border-image 'fill' draws nothing there). Colors sampled 1:1 from
    # the source so the pill border is unchanged.
    im = Image.new("RGBA", (216, 36), (0, 0, 0, 0))
    px = im.load()
    for y in range(36):
        for x in range(216):
            dd = min(x, y, 215 - x, 35 - y)
            if dd < 4:
                px[x, y] = (230, 231, 223, 255)
            elif dd < 6:
                px[x, y] = (247, 247, 247, 77)
    return im


def _triangle(Image, ImageDraw):
    # 264x32 gray triangle-tessellation tile. In the CSS it sits under a near-opaque dark gradient
    # (barely visible texture), so an even zig-zag of gray triangles reproduces the effect.
    big = Image.new("RGB", (264 * _SS, 32 * _SS), (128, 128, 128))
    d = ImageDraw.Draw(big)
    grays = [178, 148, 120, 93, 160, 110, 74, 140, 100, 181, 130, 152]
    half, k, x = 22, 0, 0
    while x < 264 + half:
        pts = [(x, 32), (x + half, 0), (x + 2 * half, 32)] if k % 2 == 0 \
            else [(x, 0), (x + half, 32), (x + 2 * half, 0)]
        g = grays[k % len(grays)]
        d.polygon([(a * _SS, b * _SS) for a, b in pts], fill=(g, g, g))
        k += 1
        x += half
    return big.resize((264, 32), Image.LANCZOS)


def build_passives():
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("SKIP passive icons: Pillow not installed (pip install Pillow)")
        return 0
    imgs = {
        "passive_pos_1.png": _arrow(Image, ImageDraw, 1),
        "passive_pos_2.png": _arrow(Image, ImageDraw, 2),
        "passive_pos_3.png": _arrow(Image, ImageDraw, 3),
        "passive_pos_4.png": _arrow(Image, ImageDraw, 3, plus=True),
        "passive_neg_1.png": _arrow(Image, ImageDraw, 1, up=False),
        "passive_neg_2.png": _arrow(Image, ImageDraw, 2, up=False),
        "passive_neg_3.png": _arrow(Image, ImageDraw, 3, up=False),
        "passive_frame.png": _frame(Image),
        "passive_triangle.png": _triangle(Image, ImageDraw),
    }
    built = 0
    for name, im in imgs.items():
        dest = os.path.join(OUT, name)
        if not FORCE and os.path.isfile(dest) and os.path.getsize(dest) > 0:
            continue
        im.save(dest)
        built += 1
        print("drew " + name)
    return built


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

    drew = build_passives()
    print("passive chrome: %d drawn" % drew)
    missing = [f for f in PASSIVE_PNGS if not os.path.isfile(os.path.join(OUT, f))]
    if missing:
        print("WARNING: passive PNGs missing from pal_icons\\: %s" % missing)
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
