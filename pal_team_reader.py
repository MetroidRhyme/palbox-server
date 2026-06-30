"""
Reads a Palworld world save and emits JSON describing every captured Pal:
species, level, gender, IVs, souls/condenser rank, passives, moves, friendship,
owner, and physical location (party / palbox / base).

Handles Palworld 0.6+ (PlM/Oodle) saves. palworld-save-tools 0.24.0 cannot parse
0.6 saves out of the box (new SetProperty / UInt64Property top-level types and a
trailing-byte change in the per-character blob), so we monkeypatch three things:
  * character rawdata decoder: tolerate trailing bytes after the pal property tree
  * FArchiveReader.property: handle SetProperty (skip) and UInt64Property
  * keep only the CharacterSaveParameterMap custom decoder so the other 0.6-broken
    rawdata blobs (map_model, containers, base camps) fall back to plain byte arrays

Usage: python pal_team_reader.py <save_dir>
  save_dir: world folder (e.g. .../SaveGames/0/<GUID>)
  Output:   JSON on stdout  { players:[...], containers:{...}, pals:[...] }
"""
import sys, os, json, struct, glob

try:
    import ooz
except ImportError:
    ooz = None


# ── patches so palworld-save-tools 0.24.0 can read 0.6 saves ────────────────────
def _install_patches():
    from palworld_save_tools.rawdata import character as charmod
    from palworld_save_tools.archive import FArchiveReader

    def decode_bytes_tolerant(parent_reader, char_bytes):
        # 0.6 added trailing bytes after group_id; the pal property tree is all we
        # need, so read it and ignore whatever follows instead of asserting EOF.
        reader = parent_reader.internal_copy(bytes(char_bytes), debug=False)
        return {"object": reader.properties_until_end()}
    charmod.decode_bytes = decode_bytes_tolerant

    _orig = FArchiveReader.property

    def patched(self, type_name, size, path, nested_caller_path=""):
        # custom-decoded properties keep their original handling
        if path in self.custom_properties and (
            path is not nested_caller_path or nested_caller_path == ""
        ):
            return _orig(self, type_name, size, path, nested_caller_path)
        if type_name == "SetProperty":
            # element type FString + optional guid + `size` body bytes (skip body)
            self.fstring()
            self.optional_guid()
            self.byte_list(size)
            return {"value": None, "type": type_name}
        if type_name == "UInt64Property":
            return {"id": self.optional_guid(), "value": self.u64(), "type": type_name}
        return _orig(self, type_name, size, path, nested_caller_path)

    FArchiveReader.property = patched


def _decompress(path):
    with open(path, "rb") as f:
        data = f.read()
    magic = data[8:11]
    if magic == b"PlM":
        if ooz is None:
            raise ImportError("pyooz required for Palworld 0.6+ saves: pip install pyooz")
        return ooz.decompress(data[12:], struct.unpack_from("<I", data, 0)[0])
    if magic == b"PlZ":
        import zlib
        return zlib.decompress(data[12:])
    raise ValueError("Unsupported save magic: %r" % magic)


def _read_gvas(path, custom_props):
    import io, contextlib
    from palworld_save_tools.gvas import GvasFile
    from palworld_save_tools import paltypes
    raw = _decompress(path)
    # The library prints "Struct type ... not found" warnings to stdout (and some
    # to stderr); swallow both so only our JSON reaches stdout.
    sink = io.StringIO()
    with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
        gvas = GvasFile.read(raw, paltypes.PALWORLD_TYPE_HINTS, custom_props)
    return gvas


# ── scalar helpers (the parsed tree wraps everything in {value:..., type:...}) ──
def _scalar(prop):
    """Unwrap a parsed property to its underlying number/string/bool."""
    if prop is None:
        return None
    v = prop.get("value", prop) if isinstance(prop, dict) else prop
    # ByteProperty / EnumProperty nest one more {type,value}
    if isinstance(v, dict) and "value" in v and "type" in v and set(v.keys()) <= {"type", "value"}:
        v = v["value"]
    return v


def _int(prop, default=0):
    v = _scalar(prop)
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def _guid_prefix(guidlike):
    # Player UIds look like "0123abcd-0000-0000-0000-000000000000"; the 8-hex
    # prefix is the stable id used in save file names.
    if not guidlike:
        return ""
    return str(guidlike).replace("-", "")[:8].upper()


def _raw_bytes(rd):
    """Pull the byte payload out of an (uncustomized) ArrayProperty<Byte> value."""
    v = rd.get("value", rd) if isinstance(rd, dict) else rd
    if isinstance(v, dict) and "values" in v:
        v = v["values"]
    try:
        return bytes(v)
    except (TypeError, ValueError):
        return b""


def _uid_le(prefix):
    # A player UId's first GUID component is its 8-hex prefix, serialized
    # little-endian in raw save blobs (e.g. "0123ABCD" -> bytes CD AB 23 01).
    try:
        return bytes.fromhex(prefix)[::-1]
    except ValueError:
        return b""


def _instance_seg1_le(instance_id):
    # First segment of a pal InstanceId, little-endian, as it appears in a guild's
    # raw blob (guilds list their members' character handle ids).
    try:
        return bytes.fromhex(str(instance_id).split("-")[0])[::-1]
    except ValueError:
        return b""


def read_guilds(gvas, player_prefixes):
    """The 0.6 GroupSaveData decoder fails, so each guild's RawData is left as raw
    bytes. We don't need the full structure: scan each blob for member player UIDs.
    Returns [{members:[prefix,...], blob:bytes}] for the substantial (guild) groups.
    """
    try:
        groups = gvas.properties["worldSaveData"]["value"]["GroupSaveDataMap"]["value"]
    except (KeyError, TypeError):
        return []
    out = []
    for entry in groups:
        blob = _raw_bytes(entry.get("value", {}).get("RawData", {}))
        if len(blob) < 100:   # skip tiny non-guild group stubs
            continue
        members = [p for p in player_prefixes if p and _uid_le(p) in blob]
        out.append({"members": members, "blob": blob})
    return out


def _fixedpoint_hp(prop):
    try:
        return int(prop["value"]["Value"]["value"])
    except (KeyError, TypeError):
        return None


def _enum_short(prop):
    v = _scalar(prop)
    if isinstance(v, str) and "::" in v:
        return v.split("::", 1)[1]
    return v


def _name_list(prop):
    try:
        return [str(x) for x in prop["value"]["values"]]
    except (KeyError, TypeError):
        return []


# ── internal name -> in-game display name (passives / moves) ───────────────────
def _load_names():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pal_names.json")
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return d.get("passives", {}), d.get("moves", {})
    except Exception:
        return {}, {}

_PASSIVE_NAMES, _MOVE_NAMES = _load_names()


def _humanize(s):
    """Fallback for skills not in pal_names.json: clean up the internal id."""
    import re
    s = re.sub(r"^Unique_[A-Za-z0-9]+_", "", s)
    s = re.sub(r"_PAL$", "", s, flags=re.I)
    s = re.sub(r"^PAL_", "", s, flags=re.I)
    s = s.replace("_", " ")
    s = re.sub(r"([a-z])([A-Z])", r"\1 \2", s)
    return re.sub(r"\s+", " ", s).strip()


def _display_passive(internal):
    return _PASSIVE_NAMES.get(internal.lower()) or _humanize(internal)


def _display_move(internal):
    # save stores e.g. "EPalWazaID::PowerShot"; strip the enum prefix first
    key = internal.split("::", 1)[-1]
    return _MOVE_NAMES.get(key.lower()) or _humanize(key)


# ── player saves give us party / palbox container ids per player ───────────────
def read_players(save_dir):
    players = []
    pdir = os.path.join(save_dir, "Players")
    if not os.path.isdir(pdir):
        return players
    from palworld_save_tools import paltypes
    for f in sorted(glob.glob(os.path.join(pdir, "*.sav"))):
        base = os.path.basename(f)
        if "_dps" in base:
            continue
        try:
            gvas = _read_gvas(f, paltypes.PALWORLD_CUSTOM_PROPERTIES)
            sd = gvas.properties["SaveData"]["value"]
            uid = sd["PlayerUId"]["value"]
            party = sd["OtomoCharacterContainerId"]["value"]["ID"]["value"]
            palbox = sd["PalStorageContainerId"]["value"]["ID"]["value"]
            players.append({
                "uid": str(uid),
                "prefix": _guid_prefix(uid),
                "party": str(party),
                "palbox": str(palbox),
            })
        except Exception as e:
            players.append({"uid": base.replace(".sav", ""), "prefix": base[:8].upper(),
                            "party": None, "palbox": None, "error": str(e)})
    return players


# ── the world save holds every Pal instance ────────────────────────────────────
def read_pals(save_dir):
    from palworld_save_tools import paltypes
    only_char = {
        ".worldSaveData.CharacterSaveParameterMap.Value.RawData":
            paltypes.PALWORLD_CUSTOM_PROPERTIES[".worldSaveData.CharacterSaveParameterMap.Value.RawData"]
    }
    gvas = _read_gvas(os.path.join(save_dir, "Level.sav"), only_char)
    chars = gvas.properties["worldSaveData"]["value"]["CharacterSaveParameterMap"]["value"]

    pals = []
    player_names = {}   # uid-prefix -> nickname (from the in-world player records)
    for entry in chars:
        try:
            sp = entry["value"]["RawData"]["value"]["object"]["SaveParameter"]["value"]
        except (KeyError, TypeError):
            continue

        if sp.get("IsPlayer", {}).get("value"):
            uid = entry.get("key", {}).get("PlayerUId", {}).get("value")
            nm = _scalar(sp.get("NickName")) or _scalar(sp.get("FilteredNickName"))
            if uid and nm:
                player_names[_guid_prefix(uid)] = str(nm)
            continue

        pal = _build_pal(sp, entry.get("key", {}).get("InstanceId", {}).get("value", ""))
        if pal:
            pals.append(pal)

    # The same gvas also carries GroupSaveDataMap (as raw bytes) -- return it so the
    # caller can attribute base camps to guilds without re-parsing Level.sav.
    return pals, player_names, gvas


# EPalWorkSuitability enum (in the save) -> the work-suitability name the dashboard uses.
_WORK_SUIT = {
    "EmitFlame": "Kindling", "Watering": "Watering", "Seeding": "Planting",
    "GenerateElectricity": "Generating Electricity", "Handcraft": "Handiwork",
    "Collection": "Gathering", "Deforest": "Lumbering", "Mining": "Mining",
    "OilExtraction": "Crude oil extraction", "ProduceMedicine": "Medicine Production",
    "Cool": "Cooling", "Transport": "Transporting", "MonsterFarm": "Farming",
}


def _work_add(sp):
    """Per-pal work-suitability boosts from work-suitability-up items, stored in
    GotWorkSuitabilityAddRankList as {WorkSuitability enum, Rank}. Returns
    { dashboard-work-name: +levels }. The separate 4-star condensation bonus is NOT
    stored here (the save only records Rank); the client derives it from `rank`."""
    out = {}
    lst = sp.get("GotWorkSuitabilityAddRankList")
    try:
        vals = lst["value"]["values"]
    except (KeyError, TypeError):
        return out
    for it in vals:
        try:
            enum = str(it["WorkSuitability"]["value"]["value"]).split("::")[-1]
            rank = int(it["Rank"]["value"])
        except (KeyError, TypeError, ValueError):
            continue
        name = _WORK_SUIT.get(enum)
        if name and rank > 0:
            out[name] = out.get(name, 0) + rank
    return out


def _build_pal(sp, instance_id):
    """Turn one SaveParameter value dict into our flat pal record (None if empty)."""
    cid = _scalar(sp.get("CharacterID"))
    if not cid or str(cid) == "None":
        return None
    cid = str(cid)
    is_alpha = cid.lower().startswith("boss_")
    species = cid[5:] if is_alpha else cid

    try:
        slot = sp["SlotId"]["value"]
        container = slot["ContainerId"]["value"]["ID"]["value"]
        slot_index = _int(slot.get("SlotIndex"))
    except (KeyError, TypeError):
        container, slot_index = None, None

    souls = {}
    for k, lbl in (("Rank_HP", "hp"), ("Rank_Attack", "attack"),
                   ("Rank_Defence", "defense"), ("Rank_CraftSpeed", "craft")):
        if k in sp and _int(sp[k]) > 0:
            souls[lbl] = _int(sp[k])

    owner = sp.get("OwnerPlayerUId", {})
    owner_uid = _scalar(owner) if owner else None

    return {
        "instanceId": str(instance_id or ""),
        "species": species,
        "isAlpha": is_alpha,
        "isLucky": bool(sp.get("IsRarePal", {}).get("value")),
        "nickname": _scalar(sp.get("NickName")) or "",
        "gender": _enum_short(sp.get("Gender")) or "",
        "level": _int(sp.get("Level"), 1),
        "exp": _int(sp.get("Exp")),
        "hp": _fixedpoint_hp(sp.get("Hp")) if "Hp" in sp else None,
        "ivHp": _int(sp.get("Talent_HP"), -1),
        "ivShot": _int(sp.get("Talent_Shot"), -1),
        "ivDefense": _int(sp.get("Talent_Defense"), -1),
        "rank": _int(sp.get("Rank"), 1) if "Rank" in sp else 1,
        "workAdd": _work_add(sp),
        "souls": souls,
        "passives": [_display_passive(m) for m in _name_list(sp.get("PassiveSkillList"))],
        "equipMoves": [_display_move(m) for m in _name_list(sp.get("EquipWaza"))],
        "masteredMoves": [_display_move(m) for m in _name_list(sp.get("MasteredWaza"))],
        "friendship": _int(sp.get("FriendshipPoint")) if "FriendshipPoint" in sp else None,
        "sanity": (lambda v: round(v, 1) if isinstance(v, (int, float)) else None)(_scalar(sp.get("SanityValue"))),
        "sick": "WorkerSick" in sp,
        "ownerPrefix": _guid_prefix(owner_uid) if owner_uid else "",
        "container": str(container) if container else "",
        "slotIndex": slot_index,
    }


def read_dps(save_dir, seen_ids):
    """Read each player's Dimensional Pal Storage (<UID>_dps.sav).

    The bulk of a player's stored Pals can live here (the in-world Level.sav only
    keeps a subset). Layout: one top-level `SaveParameterArray` (ArrayProperty of
    structs); each element is {SaveParameter, InstanceId}. Most slots are empty.
    These share the player's PalStorageContainerId, so they fold into the palbox.
    `seen_ids` dedups against pals already found in Level.sav.
    """
    from palworld_save_tools import paltypes
    pals = []
    pdir = os.path.join(save_dir, "Players")
    if not os.path.isdir(pdir):
        return pals
    for f in sorted(glob.glob(os.path.join(pdir, "*_dps.sav"))):
        try:
            gvas = _read_gvas(f, paltypes.PALWORLD_CUSTOM_PROPERTIES)
            arr = gvas.properties["SaveParameterArray"]["value"]["values"]
        except Exception:
            continue
        for el in arr:
            try:
                sp = el["SaveParameter"]["value"]
                iid = el.get("InstanceId", {}).get("value", "")
            except (KeyError, TypeError):
                continue
            if str(iid) in seen_ids:
                continue
            pal = _build_pal(sp, iid)
            if pal:
                seen_ids.add(pal["instanceId"])
                pals.append(pal)
    return pals


def main():
    _install_patches()
    save_dir = sys.argv[1] if len(sys.argv) > 1 else \
        r"PATH\TO\Pal\Saved\SaveGames\0\<WorldGUID>"  # fallback for manual runs; the dashboard passes the real save folder as argv[1]

    players = read_players(save_dir)
    pals, world_names, gvas = read_pals(save_dir)

    # Fold in each player's Dimensional Pal Storage (_dps.sav), deduped by InstanceId
    # against what Level.sav already gave us.
    seen_ids = {p["instanceId"] for p in pals if p["instanceId"]}
    pals.extend(read_dps(save_dir, seen_ids))

    # Merge player display names discovered in Level.sav onto the player records.
    for p in players:
        p["name"] = world_names.get(p["prefix"], p["prefix"])

    # Build container -> label/type/owner. Party & palbox come from player saves;
    # everything else with pals in it is a base camp, numbered by first appearance.
    containers = {}
    for p in players:
        if p.get("party"):
            containers[p["party"]] = {"type": "party", "ownerPrefix": p["prefix"],
                                      "label": p["name"] + " - Party"}
        if p.get("palbox"):
            containers[p["palbox"]] = {"type": "palbox", "ownerPrefix": p["prefix"],
                                       "label": p["name"] + " - Palbox"}
    base_no = 0
    seen_bases = {}
    for pal in pals:
        cid = pal["container"]
        if not cid or cid in containers:
            continue
        if cid not in seen_bases:
            base_no += 1
            seen_bases[cid] = base_no
            containers[cid] = {"type": "base", "ownerPrefix": "",
                               "label": "Base " + str(base_no)}

    # attach a per-pal location label + type for convenience
    for pal in pals:
        c = containers.get(pal["container"])
        pal["locationType"] = c["type"] if c else "unknown"
        pal["location"] = c["label"] if c else "Unknown"

    # count pals per container
    for cid, c in containers.items():
        c["count"] = sum(1 for pal in pals if pal["container"] == cid)

    # Who may VIEW each container's pals:
    #   party / palbox -> just the owning player
    #   base camp      -> every member of the guild that owns it. Bases are guild
    #                     property with no per-pal owner, so we attribute a base to a
    #                     guild by matching its pals' InstanceIds against each guild's
    #                     raw blob (which lists the guild's character handle ids).
    guilds = read_guilds(gvas, [p["prefix"] for p in players])
    pals_by_container = {}
    for pal in pals:
        pals_by_container.setdefault(pal["container"], []).append(pal["instanceId"])
    for cid, c in containers.items():
        if c["type"] in ("party", "palbox"):
            c["viewers"] = [c["ownerPrefix"]] if c["ownerPrefix"] else []
        elif c["type"] == "base":
            sample = [i for i in pals_by_container.get(cid, [])[:8] if i]
            owner = next((g for g in guilds
                          if any(_instance_seg1_le(i) in g["blob"] for i in sample)), None)
            c["viewers"] = owner["members"] if owner else []
        else:
            c["viewers"] = []

    out = {
        "players": [{"prefix": p["prefix"], "name": p["name"]} for p in players],
        "containers": containers,
        "pals": pals,
    }
    print(json.dumps(out, separators=(",", ":"), default=str))


if __name__ == "__main__":
    main()
