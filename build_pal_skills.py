# build_pal_skills.py
# One-time (re-runnable) scraper that builds pal_skills.json -- per active-skill
# metadata the save / species data does NOT carry: element, power, cooldown (CT),
# inflicted status effect, and the in-game description.
#
# Source: paldb.cc's single Active_Skills listing page (same site the dashboard already
# trusts for maps / spawns / species). Every skill is one <div class="card itemPopup
# activeSkill"> block; all fields (incl. the description) live on that one page, so no
# per-skill page fetches are needed. Requires a Referer header.
#
# Output: pal_skills.json keyed by the skill's DISPLAY name (e.g. "Fire Ball"), which is
# the same name the save's equipMoves/masteredMoves and the species learnsets use, so the
# dashboard joins it directly.
#
# Usage:  python build_pal_skills.py

import json, re, os, urllib.request

OUT = os.path.join(os.path.dirname(__file__), "pal_skills.json")
URL = "https://paldb.cc/en/Active_Skills"
HEADERS = {"Referer": "https://paldb.cc/", "User-Agent": "Mozilla/5.0"}

# paldb element_color_NN -> element name (matches ELEM_NAMES in the dashboard).
ELEM = {"00": "Normal", "01": "Fire", "02": "Water", "03": "Electricity", "04": "Leaf",
        "05": "Dark", "06": "Dragon", "07": "Earth", "08": "Ice"}


def strip_tags(s):
    s = re.sub(r"<[^>]+>", " ", s)
    s = s.replace("&amp;", "&").replace("&#39;", "'").replace("&quot;", '"')
    s = re.sub(r"\s+", " ", s)
    return s.strip()


def parse(html):
    out = {}
    # Each skill is one card; split on the card marker and parse each chunk.
    chunks = html.split('card itemPopup activeSkill')
    for ch in chunks[1:]:
        ch = ch[:4000]  # a card is well under this; avoids bleeding into the next one
        m = re.search(r'class="element_color_(\d+)"[^>]*>([^<]+)</a>', ch)
        if not m:
            continue
        elem = ELEM.get(m.group(1), "Normal")
        name = strip_tags(m.group(2))
        if not name or name in out:
            continue
        # Cooldown: the CoolTime icon is immediately followed by ": <span>NN</span>".
        ct = re.search(r'PalSkillCoolTime[^>]*>[^<]*</[^>]*>\s*:?\s*<span[^>]*>(\d+)</span>', ch)
        if not ct:
            ct = re.search(r'CoolTime.*?<span[^>]*>(\d+)</span>', ch, re.S)
        power = re.search(r'Power:\s*<span[^>]*>(\d+)</span>', ch)
        agg = re.search(r'Aggregate:</span>\s*<span[^>]*>([^<]+)</span>\s*<div[^>]*>([^<]*)</div>', ch)
        body = re.search(r'<div class="card-body">(.*?)</div>', ch, re.S)
        rec = {
            "element": elem,
            "power": int(power.group(1)) if power else None,
            "cooldown": int(ct.group(1)) if ct else None,
        }
        if agg:
            rec["status"] = strip_tags(agg.group(1))
            av = strip_tags(agg.group(2))
            if av:
                rec["statusValue"] = av
        if body:
            rec["desc"] = strip_tags(body.group(1))[:400]
        out[name] = rec
    return out


def main():
    req = urllib.request.Request(URL, headers=HEADERS)
    html = urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace")
    skills = parse(html)
    json.dump(skills, open(OUT, "w", encoding="utf-8"), ensure_ascii=True, indent=0)
    print("wrote %d skills -> %s" % (len(skills), OUT))
    # Spot-check a few well-known skills.
    for n in ["Fire Ball", "Power Shot", "Sand Tornado", "Power Bomb", "Spine Vine"]:
        if n in skills:
            print("  %-16s %s" % (n, skills[n]))
        else:
            print("  %-16s MISSING" % n)


if __name__ == "__main__":
    main()
