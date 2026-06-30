# build_pal_species.py
# One-time (re-runnable) scraper that builds pal_species.json -- the curated
# species-level data the save does NOT contain: element type(s), work suitability
# levels, partner skill, learnable active skills, and base stat ranges.
#
# Source: paldb.cc per-pal pages (same site the dashboard already trusts for maps /
# spawns). Pages require a Referer header. Each page's stats are a flat key/value
# table (<div>KEY</div> <div>VALUE</div>); the "Code" field is the in-game internal
# name, which we key the output by so it joins directly to the save's species names.
#
# NOTE: paldb does not expose the in-game Paldeck flavor description, so that field is
# intentionally absent here -- it needs a different source.
#
# Usage:
#   python build_pal_species.py            # scrape every pal in PAL_LIST
#   python build_pal_species.py Lamball Foxparks Mossanda_Lux   # just these slugs (test)

import json, re, sys, time, urllib.parse, urllib.request, os

INDEX_HTML = os.path.join(os.path.dirname(__file__), "public", "index.html")
OUT = os.path.join(os.path.dirname(__file__), "pal_species.json")
HEADERS = {"Referer": "https://paldb.cc/", "User-Agent": "Mozilla/5.0"}

WORK_TYPES = ["Kindling", "Watering", "Planting", "Generating_Electricity",
              "Handiwork", "Gathering", "Lumbering", "Mining",
              "Medicine_Production", "Cooling", "Transporting", "Farming"]


def fetch(slug):
    url = "https://paldb.cc/en/" + urllib.parse.quote(slug)
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def kv_pairs(html):
    """Flat <div>KEY</div> <div>VALUE</div> stat rows. Returns list (ordered, keeps
    the first form's values first)."""
    rows = re.findall(r'border-bottom">\s*<div>([^<]+)</div>\s*<div>(.*?)</div>', html, re.S)
    return [(k.strip(), re.sub(r'<[^>]+>', '', v).strip()) for k, v in rows]


def first(pairs, key):
    for k, v in pairs:
        if k == key:
            return v
    return None


def clean_num_range(s):
    """'3100 &ndash; 3782' -> [3100, 3782]; '441' -> [441, 441]; '' -> None."""
    if not s:
        return None
    nums = re.findall(r'\d[\d,]*', s.replace('&ndash;', '-'))
    nums = [int(n.replace(',', '')) for n in nums]
    if not nums:
        return None
    return [nums[0], nums[-1]]


def parse_work(html):
    """First level seen per work type (the primary form is listed first)."""
    out = {}
    for m in re.finditer(r'href="(' + "|".join(WORK_TYPES) + r')"[^>]*>.*?<span[^>]*>Lv</span>(\d+)', html, re.S):
        wt, lv = m.group(1), int(m.group(2))
        wt = wt.replace('_', ' ')
        if wt not in out:
            out[wt] = lv
    return out


def parse_partner_skill(html):
    # The body card reads: ...Partner Skill</span>: <NAME> ... <description prose> ...
    # There are decoy matches (the nav dropdown and an empty duplicate header), so scan
    # all occurrences and take the first whose name (text right after the colon) is real.
    for m in re.finditer(r'common_coop_action"[^>]*>\s*Partner Skill\s*</span>\s*:?\s*([^<]*)', html):
        name = re.sub(r'\s+', ' ', m.group(1)).strip()
        if not name:
            continue
        # Description: prose that follows, tags stripped. Cut at the skill-effect table
        # ("Lv." rows) that comes after the sentence(s).
        seg = html[m.end():m.end() + 700]
        text = re.sub(r'<[^>]+>', ' ', seg)
        text = re.sub(r'\s+', ' ', text).strip()
        text = text.split('<')[0]              # drop any tag truncated at the window edge
        text = re.split(r'\s+Lv\.', text)[0].strip()   # stop before the skill-effect table
        return {"name": name, "text": text[:240]}
    return None


def parse_active_skills(html):
    """Learnable active skills: 'Lv. N <a ... href="SkillPage">Skill Name</a>'."""
    out = []
    seen = set()
    for m in re.finditer(r'Lv\.?\s*(\d+)\s*<a[^>]*href="([^"]+)"[^>]*>([^<]+)</a>', html):
        lv = int(m.group(1))
        name = re.sub(r'\s+', ' ', m.group(3)).strip()
        if name and name not in seen:
            seen.add(name)
            out.append({"name": name, "level": lv})
    return out


def parse_pal(html):
    pairs = kv_pairs(html)
    if not pairs:
        return None
    types = [t for t in [first(pairs, 'ElementType1'), first(pairs, 'ElementType2')] if t]
    rec = {
        "code": first(pairs, 'Code'),
        "types": types,
        "work": parse_work(html),
        "stats": {
            "hp": clean_num_range(first(pairs, 'Health')),
            "attack": clean_num_range(first(pairs, 'Attack')),
            "defense": clean_num_range(first(pairs, 'Defense')),
            "rarity": first(pairs, 'Rarity'),
            "size": first(pairs, 'Size'),
        },
        "partnerSkill": parse_partner_skill(html),
        "activeSkills": parse_active_skills(html),
    }
    return rec


def load_pal_list():
    html = open(INDEX_HTML, encoding="utf-8").read()
    # entries look like: [1,'SheepBall','Lamball',false],
    out = []
    for m in re.finditer(r"\[(\d+),'([^']+)','([^']+)',(true|false)\]", html):
        out.append({"no": int(m.group(1)), "internal": m.group(2),
                    "display": m.group(3), "variant": m.group(4) == "true"})
    return out


def main():
    args = sys.argv[1:]
    if args:
        targets = [{"internal": None, "display": a.replace('_', ' '), "slug": a} for a in args]
    else:
        pals = load_pal_list()
        targets = [{"internal": p["internal"], "display": p["display"],
                    "slug": p["display"].replace(' ', '_')} for p in pals]

    # Arg mode is a targeted backfill -> merge into the existing file instead of
    # overwriting the full table.
    out = {}
    if args and os.path.exists(OUT):
        out = json.load(open(OUT, encoding="utf-8"))
    fails = []
    for i, t in enumerate(targets):
        try:
            html = fetch(t["slug"])
            rec = parse_pal(html)
            if not rec:
                fails.append((t["slug"], "no data")); continue
            key = t["internal"] or rec.get("code") or t["slug"]
            # cross-check: warn if paldb's Code disagrees with our internal name
            if t["internal"] and rec.get("code") and rec["code"] != t["internal"]:
                rec["_codeMismatch"] = rec["code"]
            out[key] = rec
            print("[%d/%d] %-22s types=%s work=%d skills=%d" % (
                i + 1, len(targets), key, rec["types"], len(rec["work"]), len(rec["activeSkills"])))
        except Exception as e:
            fails.append((t["slug"], str(e)))
            print("[%d/%d] %-22s FAIL %s" % (i + 1, len(targets), t["slug"], e))
        time.sleep(0.4)  # be polite

    json.dump(out, open(OUT, "w", encoding="utf-8"), ensure_ascii=True, indent=0)
    print("\nwrote %d species -> %s" % (len(out), OUT))
    if fails:
        print("FAILURES (%d): %s" % (len(fails), fails[:20]))


if __name__ == "__main__":
    main()
