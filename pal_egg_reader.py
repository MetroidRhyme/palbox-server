"""Reads a Palworld world save and emits JSON describing every real Pal egg:
egg element/tier, the species it will hatch, whether it's an alpha (BOSS_), and the
owning player (via base map-object -> guild -> member).

Only eggs sitting in an actual container slot are "real". The save also accumulates
thousands of orphaned DynamicItemSaveData egg records (hatched/consumed eggs whose
dynamic data is never cleaned) plus a few orphaned containers (an egg in a container
that nothing references - unreachable in-game); both are reported as counts, not eggs.

Owner attribution: each storage MapObject's Model.RawData carries group_id_belong_to
at a fixed offset (bytes 48-64, before the variable transform field), which maps
through GroupSaveDataMap to the owning guild's members. The container that holds the
egg is linked to its MapObject via the ItemContainer concrete-model module.

Usage: python pal_egg_reader.py <save_dir>
  save_dir: world folder (e.g. .../SaveGames/0/<GUID>)
  Output:   JSON on stdout  { eggs:[...], summary:{...} }
"""
import sys, os, io, json, struct, contextlib, re, glob

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pal_team_reader import _install_patches, _decompress, read_players, _uid_le, _raw_bytes, _build_pal
from pal_save_reader import find_player_names_raw

# Element prefix in the egg item id -> element index used by the icons (elem_NN.webp).
_ELEM_IDX = {"Normal": 0, "Fire": 1, "Water": 2, "Electricity": 3, "Leaf": 4,
             "Dark": 5, "Dragon": 6, "Earth": 7, "Ice": 8}


def _gstr(B):
    """16 on-disk GUID bytes -> Palworld's GUID string (its non-standard swizzle)."""
    return ("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x" %
            (B[3], B[2], B[1], B[0], B[7], B[6], B[5], B[4],
             B[11], B[10], B[9], B[8], B[15], B[14], B[13], B[12]))


def _species_from_trailer(tr):
    """An egg dynamic item stores only its hatch species, as an FString in the
    trailer bytes: <4 bytes><FString species><FString 'None'>."""
    if not tr or len(tr) < 8:
        return None
    b = bytes(tr)
    ln = struct.unpack_from("<i", b, 4)[0]
    if 0 < ln < 64 and 8 + ln <= len(b):
        return b[8:8 + ln - 1].decode("ascii", "replace")
    return None


# ── Incubating eggs (eggs placed in incubators) ─────────────────────────────────
# Incubators are HatchingPalEgg (1 egg) and MultiHatchingPalEgg (large, up to ~10)
# map objects. An egg placed in an incubator stores its full future pal as a
# character in the incubator's ConcreteModel, AND keeps its egg item in the
# incubator's item container. When the egg finishes incubating (ready to hatch),
# its character is materialized in the ConcreteModel; so the count of characters in
# the ConcreteModel = the ready eggs, and any extra container eggs are still
# incubating. (Inferred: it matches the observed counts exactly; there is no
# reliable per-egg remaining-time field in this 0.6 save format, so we report
# ready / still-incubating rather than a countdown.)
_INCUBATOR_IDS = ("HatchingPalEgg", "MultiHatchingPalEgg")
_CHAR_ID_RE = re.compile(
    rb"CharacterID\x00\x0d\x00\x00\x00NameProperty\x00.{8,14}?([A-Z][A-Za-z0-9_]{2,40})\x00", re.S)


def parse_egg_char(blob):
    """Both an egg's dynamic-item trailer and a single incubator's ConcreteModel hold
    the full pre-rolled pal under a 'SaveParameter' property (PalIndividualCharacter
    SaveParameter: species, gender, IVs, passives, moves). Locate that property and
    parse from there - robust to the differing headers in front of it."""
    from palworld_save_tools.archive import FArchiveReader
    from palworld_save_tools import paltypes
    i = bytes(blob).find(b"\x0e\x00\x00\x00SaveParameter\x00")
    if i < 0:
        raise ValueError("no SaveParameter")
    r = FArchiveReader(bytes(blob)[i:], type_hints=paltypes.PALWORLD_TYPE_HINTS)
    return r.properties_until_end()["SaveParameter"]["value"]


def _container_meta(wsd):
    """Classify every egg-holding container by the map object that owns it.
    Returns (meta, single_pals):
      meta {container_id: {"kind","inst","ready"}}
        kind  "incubator" | "breedfarm" | "storage"
        inst  the owning map object's Model instance id (for per-owner numbering)
        ready materialized-character count (incubators only) = ready eggs
      single_pals {container_id: parsed pal} for single (HatchingPalEgg) incubators,
        whose egg item is minimal - the full pal lives in the ConcreteModel instead."""
    meta, single_pals = {}, {}
    quiet = io.StringIO()
    for o in wsd["MapObjectSaveData"]["value"]["values"]:
        mid = (o.get("MapObjectId", {}) or {}).get("value") or ""
        try:
            cm = bytes(o["ConcreteModel"]["value"]["RawData"]["value"]["values"])
            mods = o["ConcreteModel"]["value"]["ModuleMap"]["value"]
            model = bytes(o["Model"]["value"]["RawData"]["value"]["values"])
        except (KeyError, TypeError):
            continue
        cont_id = None
        for m in mods:
            if m["key"].endswith("ItemContainer"):
                try:
                    mcb = bytes(m["value"]["RawData"]["value"]["values"])
                except (KeyError, TypeError):
                    mcb = b""
                if len(mcb) >= 16:
                    cont_id = _gstr(mcb[:16])
                break
        if not cont_id:
            continue
        inst = _gstr(model[0:16]) if len(model) >= 16 else cont_id
        if mid in _INCUBATOR_IDS:
            ready = len(_CHAR_ID_RE.findall(cm))
            meta[cont_id] = {"kind": "incubator", "inst": inst, "ready": ready}
            if mid == "HatchingPalEgg" and ready:
                try:
                    with contextlib.redirect_stdout(quiet), contextlib.redirect_stderr(quiet):
                        single_pals[cont_id] = _build_pal(parse_egg_char(cm), "")
                except Exception:
                    pass
        elif mid == "BreedFarm" or mid.lower().startswith("palegg"):
            # Breeding farms produce eggs that sit on the pen as egg map objects. The
            # id is element-suffixed for elemental eggs (PalEgg_Fire, PalEgg_Water, ...)
            # but the Normal-element egg (e.g. Kingpaca) is just "Palegg" -- note the
            # lowercase 'egg'. Match case-insensitively so that Normal egg isn't missed
            # and mislabeled as Storage.
            meta[cont_id] = {"kind": "breedfarm", "inst": inst, "ready": 0}
        else:
            meta[cont_id] = {"kind": "storage", "inst": inst, "ready": 0}
    return meta, single_pals


def _inventory_containers(save_dir):
    """{container_id: player_prefix} for each player's personal inventory containers
    (read from the player saves), so eggs carried in a backpack show as 'Inventory'."""
    from palworld_save_tools.gvas import GvasFile
    from palworld_save_tools import paltypes
    out = {}
    pdir = os.path.join(save_dir, "Players")
    if not os.path.isdir(pdir):
        return out
    quiet = io.StringIO()
    for f in glob.glob(os.path.join(pdir, "*.sav")):
        if "_dps" in f:
            continue
        try:
            with contextlib.redirect_stdout(quiet), contextlib.redirect_stderr(quiet):
                g = GvasFile.read(_decompress(f), paltypes.PALWORLD_TYPE_HINTS,
                                  paltypes.PALWORLD_CUSTOM_PROPERTIES)
            sd = g.properties["SaveData"]["value"]
            uid = str(sd["PlayerUId"]["value"]).replace("-", "")[:8].upper()
            inv = (sd.get("inventoryInfo") or sd.get("InventoryInfo") or {}).get("value", {})
            for v in inv.values():
                try:
                    out[str(v["value"]["ID"]["value"])] = uid
                except (KeyError, TypeError):
                    pass
        except Exception:
            pass
    return out


# Fields copied from a parsed pal (via pal_team_reader._build_pal) onto the egg record,
# so the egg card + the shared pal-detail popup can render the pre-rolled pal.
_PAL_FIELDS = ("species", "isAlpha", "isLucky", "gender", "level", "hp",
               "ivHp", "ivShot", "ivDefense", "rank", "souls",
               "passives", "equipMoves", "masteredMoves")


# Location group ordering for the UI: incubators first, then breeding farm, storage,
# inventory, then anything orphaned.
_LOC_ORDER = {"incubator": 0, "breedfarm": 1, "storage": 2, "inventory": 3, "orphan": 4}


def _egg_record(etype, pal, species_fallback, owner, oname, ready, egg_id,
                loc_kind, loc_name, inc_no):
    parts = etype.split("_") if etype else []
    element = parts[1] if len(parts) > 1 else ""
    try:
        tier = int(parts[2]) if len(parts) > 2 else 0
    except ValueError:
        tier = 0
    if pal:
        rec = {k: pal[k] for k in _PAL_FIELDS}
    else:
        sp = species_fallback or ""
        is_alpha = sp.lower().startswith("boss_")
        rec = {"species": sp[5:] if is_alpha else sp, "isAlpha": is_alpha, "isLucky": False,
               "gender": "", "level": 1, "hp": None, "ivHp": -1, "ivShot": -1,
               "ivDefense": -1, "rank": 1, "souls": {}, "passives": [],
               "equipMoves": [], "masteredMoves": []}
    rec.update({
        "eggId": egg_id, "eggType": etype, "element": element,
        "elementIdx": _ELEM_IDX.get(element, 0), "tier": tier, "nickname": "",
        "owner": owner or "", "ownerName": oname, "available": bool(owner),
        "incubating": loc_kind == "incubator", "ready": bool(ready),
        "locKind": loc_kind, "loc": loc_name, "incNo": inc_no,
        "locOrder": _LOC_ORDER.get(loc_kind, 5),
    })
    return rec


def read_eggs(save_dir, resolve_names=True):
    _install_patches()
    # The item-container slot RawData is permission metadata whose decoder trips a
    # 0.6 EOF assert; we don't need it (the item lives in the slot struct), so keep
    # the raw bytes instead of decoding.
    import palworld_save_tools.rawdata.item_container_slots as slotmod
    slotmod.decode_bytes = lambda parent_reader, c_bytes: {"bytes": bytes(c_bytes)}
    from palworld_save_tools.gvas import GvasFile
    from palworld_save_tools import paltypes

    # Only these custom decoders; everything else (incl. the 0.6-broken MapObject
    # decoder) falls back to plain bytes so the parse still completes.
    ALL = paltypes.PALWORLD_CUSTOM_PROPERTIES
    want = [".worldSaveData.ItemContainerSaveData.Value.Slots.Slots.RawData",
            ".worldSaveData.ItemContainerSaveData.Value.RawData",
            ".worldSaveData.DynamicItemSaveData.DynamicItemSaveData.RawData"]
    custom = {k: ALL[k] for k in want if k in ALL}

    raw = _decompress(os.path.join(save_dir, "Level.sav"))
    sink = io.StringIO()
    with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
        gvas = GvasFile.read(raw, paltypes.PALWORLD_TYPE_HINTS, custom)
    wsd = gvas.properties["worldSaveData"]["value"]

    # container id -> ordered list of (egg type id, local id) for every egg slot,
    # and the set of local ids that are real (held) eggs.
    egg_by_cont = {}
    real_lids = set()
    for c in wsd["ItemContainerSaveData"]["value"]:
        cid = str(c["key"]["ID"]["value"])
        for s in c["value"]["Slots"]["value"]["values"]:
            b = s["RawData"]["value"]["bytes"]
            if b"PalEgg" not in b:
                continue
            slen = struct.unpack_from("<i", b, 8)[0]
            etype = b[12:12 + slen - 1].decode("ascii", "replace")
            lid = _gstr(b[12 + slen + 16:12 + slen + 32])   # skip created-world guid
            egg_by_cont.setdefault(cid, []).append((etype, lid))
            real_lids.add(lid)

    # Parse the full pre-rolled pal (species, gender, IVs, passives, moves) for each
    # real egg from its dynamic item; count all egg records (the rest are orphans).
    egg_pal = {}
    species_only = {}
    total_records = 0
    with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
        for e in wsd["DynamicItemSaveData"]["value"]["values"]:
            rd = e["RawData"]["value"]
            idd = rd.get("id", {})
            if str(idd.get("static_id", "")).startswith("PalEgg"):
                total_records += 1
            lid = idd.get("local_id_in_created_world")
            if not lid or str(lid) not in real_lids:
                continue
            lid = str(lid)
            tr = rd.get("trailer")
            species_only[lid] = _species_from_trailer(tr)
            try:
                egg_pal[lid] = _build_pal(parse_egg_char(tr), "")
            except Exception:
                egg_pal[lid] = None

    # Per-container: kind (incubator/breedfarm/storage) + single-incubator pals;
    # the owning guild group; and per-player personal inventory containers.
    meta, single_pals = _container_meta(wsd)
    inv_conts = _inventory_containers(save_dir)
    cont_group = {}
    for o in wsd["MapObjectSaveData"]["value"]["values"]:
        try:
            model = bytes(o["Model"]["value"]["RawData"]["value"]["values"])
        except (KeyError, TypeError):
            model = b""
        group = _gstr(model[48:64]) if len(model) >= 64 else None
        try:
            mods = o["ConcreteModel"]["value"]["ModuleMap"]["value"]
        except (KeyError, TypeError):
            mods = []
        for m in mods:
            if m["key"].endswith("ItemContainer"):
                try:
                    mb = bytes(m["value"]["RawData"]["value"]["values"])
                except (KeyError, TypeError):
                    mb = b""
                if len(mb) >= 16:
                    cont_group[_gstr(mb[:16])] = group
                break

    # group id -> first member player prefix (guilds are solo here, but this supports
    # multi-member). Resolve each player's in-game name (same NickName source the Pals
    # view uses) so owners show real names everywhere without live server state.
    # find_player_names_raw reuses the `raw` buffer decompressed above instead of
    # decompressing Level.sav a second time (find_player_names' own path-based form used
    # to do exactly that on every single call here). resolve_names=False (build_public_data
    # .ps1's builder passes this) skips the byte-scan entirely for a caller that already
    # has its own guid->name roster and would just overwrite these names anyway.
    prefixes = [p["prefix"] for p in read_players(save_dir)]
    if resolve_names:
        name_by_prefix = {pfx.upper(): nm for pfx, nm in find_player_names_raw(raw, prefixes).items()}
    else:
        name_by_prefix = {}
    group_owner = {}
    for entry in wsd["GroupSaveDataMap"]["value"]:
        blob = _raw_bytes(entry.get("value", {}).get("RawData", {}))
        mem = [pf for pf in prefixes if pf and _uid_le(pf) in blob]
        if mem:
            group_owner[str(entry["key"])] = mem[0]

    def owner_of(cid):
        return inv_conts.get(cid) or group_owner.get(cont_group.get(cid))

    # Number incubators per owner (stable by the incubator's Model instance id), so a
    # player's incubators read "Incubator 1", "Incubator 2", ...
    inc_number = {}
    by_owner = {}
    for cid in egg_by_cont:
        m = meta.get(cid)
        if m and m["kind"] == "incubator":
            by_owner.setdefault(owner_of(cid) or "", []).append((m["inst"], cid))
    for lst in by_owner.values():
        for n, (_inst, cid) in enumerate(sorted(lst), 1):
            inc_number[cid] = n

    eggs = []
    counts = {"incubator": 0, "breedfarm": 0, "storage": 0, "inventory": 0, "orphan": 0}
    ready_count = 0
    for cid, items in egg_by_cont.items():
        m = meta.get(cid)
        owner = owner_of(cid)
        oname = name_by_prefix.get((owner or "").upper(), "")
        kind = "inventory" if cid in inv_conts else (m["kind"] if m else "storage")
        if not owner and kind in ("storage", "orphan"):
            kind = "orphan"
        materialized = m["ready"] if m else 0
        inc_no = inc_number.get(cid, 0)
        loc_name = {"incubator": "Incubator " + str(inc_no), "breedfarm": "Breeding Farm",
                    "inventory": "Inventory", "orphan": "Unowned (ghost)"}.get(kind, "Storage")
        for idx, (etype, lid) in enumerate(items):
            ready = kind == "incubator" and idx < materialized
            pal = egg_pal.get(lid)
            # single-incubator egg items are minimal; use the ConcreteModel pal instead
            if kind == "incubator" and (not pal or pal["ivHp"] < 0) and cid in single_pals:
                pal = single_pals[cid]
            eggs.append(_egg_record(etype, pal, species_only.get(lid), owner, oname,
                                    ready, lid, kind, loc_name, inc_no))
            counts[kind] = counts.get(kind, 0) + 1
            if ready:
                ready_count += 1

    summary = {
        "totalRecords": total_records,
        "realEggs": len(eggs),
        "incubating": counts["incubator"],
        "incubatingReady": ready_count,
        "breedingFarm": counts["breedfarm"],
        "storageEggs": counts["storage"],
        "inventory": counts["inventory"],
        "available": sum(1 for e in eggs if e["available"]),
        "orphanContainerEggs": counts["orphan"],
        "orphanRecords": total_records - len(eggs),
    }
    players = [{"prefix": p, "name": name_by_prefix.get(p.upper(), p)} for p in prefixes]
    return {"eggs": eggs, "summary": summary, "players": players}


def main():
    save_dir = sys.argv[1] if len(sys.argv) > 1 else \
        r"PATH\TO\Pal\Saved\SaveGames\0\<WorldGUID>"  # fallback for manual runs; the dashboard passes the real save folder as argv[1]
    # --no-names: skip player-name resolution for a caller that already has its own
    # guid->name roster (build_public_data.ps1's builder, from pal_save_reader.py's own
    # default-mode call) and would just overwrite these names anyway.
    resolve_names = "--no-names" not in sys.argv[2:]
    try:
        out = read_eggs(save_dir, resolve_names=resolve_names)
    except Exception as e:
        print(json.dumps({"eggs": [], "summary": {}, "error": str(e)}))
        return
    print(json.dumps(out, separators=(",", ":")))


if __name__ == "__main__":
    main()
