"""
Generate pal_names.json: internal-name -> in-game English display name maps for
Pal passive skills and active skills (moves), sourced from palcalc's db.json.

Run once (re-run after a Palworld update to refresh):
    python gen_pal_names.py
Writes C:\\PalWorldServer\\pal_names.json which pal_team_reader.py loads at runtime.
"""
import json, os, urllib.request

DB_URL = "https://raw.githubusercontent.com/tylercamp/palcalc/main/PalCalc.Model/db.json"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pal_names.json")


def main():
    req = urllib.request.Request(DB_URL, headers={"User-Agent": "Mozilla/5.0"})
    db = json.loads(urllib.request.urlopen(req, timeout=60).read())

    def build(section):
        out = {}
        for e in db.get(section, []):
            internal = e.get("InternalName")
            name = e.get("Name")
            if internal and name and name != "-":
                out[internal.lower()] = name
        return out

    data = {"passives": build("PassiveSkills"), "moves": build("ActiveSkills")}
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    print("wrote %s  (passives=%d, moves=%d)" % (OUT, len(data["passives"]), len(data["moves"])))


if __name__ == "__main__":
    main()
