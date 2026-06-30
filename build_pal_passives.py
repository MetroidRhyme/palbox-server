# build_pal_passives.py
# One-time (re-runnable) scraper that builds pal_passives.json -- the effect text for each
# passive skill, which the save / dashboard does NOT carry (the dashboard only knows each
# passive's rating tier, from PASSIVE_TIER). Powers the tap-a-passive detail popup.
#
# Source: paldb.cc's single Passive_Skills listing page. Each passive is one card:
#   <div class="passive-rankN ...">NAME</div> ... <div class="p-2"><div>EFFECT</div> ...pal icons>
# The effect prose sits in the p-2 block before the list of pals that have it innately.
#
# Output: pal_passives.json keyed by the passive's DISPLAY name (e.g. "Brave"), matching the
# names the save's p.passives and PASSIVE_TIER use, so the dashboard joins it directly.
#
# Usage:  python build_pal_passives.py

import json, re, os, urllib.request

OUT = os.path.join(os.path.dirname(__file__), "pal_passives.json")
URL = "https://paldb.cc/en/Passive_Skills"
HEADERS = {"Referer": "https://paldb.cc/", "User-Agent": "Mozilla/5.0"}


def strip_tags(s):
    s = re.sub(r"<br\s*/?>", " / ", s, flags=re.I)
    s = re.sub(r"<[^>]+>", " ", s)
    s = s.replace("&amp;", "&").replace("&#39;", "'").replace("&quot;", '"')
    s = s.replace("&lt;", "<").replace("&gt;", ">").replace("&nbsp;", " ")
    s = re.sub(r"\s+", " ", s)
    return s.strip()


def parse(html):
    out = {}
    # Each passive card carries one "passive-rankN">NAME" header (negatives use rank-N); split
    # on that to chunk them.
    parts = re.split(r'class="passive-rank(-?\d+)[^"]*"[^>]*>', html)
    # parts = [pre, rank1, after1, rank2, after2, ...]
    for i in range(1, len(parts) - 1, 2):
        rank = int(parts[i])
        after = parts[i + 1]
        nm = re.match(r'\s*([^<]+?)\s*</div>', after)
        if not nm:
            continue
        name = strip_tags(nm.group(1))
        if not name or name in out:
            continue
        # Effect prose: the p-2 body, cut before the innate-pal icon links (href="PalName").
        body = re.search(r'<div class="p-2">(.*?)</div>\s*</div>\s*</div>', after, re.S)
        effect = ""
        if body:
            seg = body.group(1)
            seg = re.split(r'<a\b|href="', seg)[0]
            effect = strip_tags(seg)
        rec = {"rank": rank}
        if effect:
            rec["effect"] = effect[:300]
        out[name] = rec
    return out


def main():
    req = urllib.request.Request(URL, headers=HEADERS)
    html = urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace")
    passives = parse(html)
    json.dump(passives, open(OUT, "w", encoding="utf-8"), ensure_ascii=True, indent=0)
    print("wrote %d passives -> %s" % (len(passives), OUT))
    for n in ["Brave", "Legend", "Ferocious", "Brittle", "Lucky", "Swift"]:
        print("  %-14s %s" % (n, passives.get(n, "MISSING")))


if __name__ == "__main__":
    main()
