"""
Reads Palworld player save files and returns JSON with per-player Pal capture counts.
Handles Palworld 0.6+ (PlM/Oodle) and earlier (PlZ/zlib) save formats.

Usage: python pal_save_reader.py <save_dir>
  save_dir: path to the world folder (e.g. .../SaveGames/0/<GUID>)
  Output:   JSON on stdout
"""
import sys, os, json, struct

try:
    import ooz
    HAS_OOZ = True
except ImportError:
    HAS_OOZ = False


def decompress_save(path):
    with open(path, "rb") as f:
        data = f.read()
    magic = data[8:11]
    if magic == b"PlM":
        if not HAS_OOZ:
            raise ImportError("pyooz required for Palworld 0.6+ saves: pip install pyooz")
        unc = struct.unpack_from("<I", data, 0)[0]
        return ooz.decompress(data[12:], unc)
    if magic == b"PlZ":
        import zlib
        return zlib.decompress(data[12:])
    raise ValueError(f"Unsupported save magic: {magic!r}")


def read_fstring(data, pos):
    length = struct.unpack_from("<i", data, pos)[0]
    pos += 4
    if length == 0:
        return "", pos
    if length < 0:
        bc = (-length) * 2
        return data[pos:pos + bc - 2].decode("utf-16-le", errors="replace"), pos + bc
    return data[pos:pos + length - 1].decode("ascii", errors="replace"), pos + length


def find_property(raw, name):
    needle = name.encode("ascii") + b"\x00"
    pos = 0
    while True:
        idx = raw.find(needle, pos)
        if idx == -1:
            return -1
        if idx >= 4 and struct.unpack_from("<I", raw, idx - 4)[0] == len(name) + 1:
            return idx - 4
        pos = idx + 1


def parse_name_bool_map(raw, pos):
    # Same header layout as parse_name_int_map but value is 1-byte BoolProperty
    pos += 8
    _, pos = read_fstring(raw, pos)  # key type ("NameProperty")
    _, pos = read_fstring(raw, pos)  # value type ("BoolProperty")
    pos += 5
    count = struct.unpack_from("<I", raw, pos)[0]
    pos += 4
    result = []
    for _ in range(count):
        name, pos = read_fstring(raw, pos)
        val = raw[pos]
        pos += 1
        if name and val:
            result.append(name.upper())
    return result


def parse_name_bool_map_full(raw, pos):
    """Same layout/position as parse_name_bool_map but returns EVERY entry (not just the
    true ones) as {uppercased_key: bool}. Used by diagnostic/snapshot tooling that needs to
    see a key flip false->true or appear for the first time, not just the current true set
    -- parse_name_bool_map alone can't distinguish "always was false" from "didn't exist"."""
    pos += 8
    _, pos = read_fstring(raw, pos)
    _, pos = read_fstring(raw, pos)
    pos += 5
    count = struct.unpack_from("<I", raw, pos)[0]
    pos += 4
    result = {}
    for _ in range(count):
        name, pos = read_fstring(raw, pos)
        val = raw[pos]
        pos += 1
        if name:
            result[name.upper()] = bool(val)
    return result


def parse_name_int_map(raw, pos):
    # Layout after property-name + type FStrings:
    #   8 bytes: data size
    #   FString: key type ("NameProperty")
    #   FString: value type ("IntProperty")
    #   5 bytes: padding/flags
    #   4 bytes: entry count
    #   count * (key FString + 4-byte int)
    pos += 8
    _, pos = read_fstring(raw, pos)  # key type
    _, pos = read_fstring(raw, pos)  # value type
    pos += 5
    count = struct.unpack_from("<I", raw, pos)[0]
    pos += 4
    result = {}
    for _ in range(count):
        name, pos = read_fstring(raw, pos)
        val = struct.unpack_from("<i", raw, pos)[0]
        pos += 4
        if name:
            result[name] = val
    return result


def parse_name_array(raw, pos):
    """ArrayProperty of NameProperty/StrProperty (e.g. CompletedQuestArray,
    UnlockedRecipeTechnologyNames): InnerType FString, 1-byte HasPropertyGuid, 4-byte count,
    then each element is its own back-to-back length-prefixed FString -- no per-element
    wrapper. Same header offset (+8) as parse_name_bool_map/parse_name_int_map, confirmed
    against real save bytes -- see /palworld-dataminer skill's decode_name_array note."""
    pos += 8
    _, pos = read_fstring(raw, pos)  # inner type ("NameProperty" or "StrProperty")
    pos += 1  # HasPropertyGuid
    count = struct.unpack_from("<I", raw, pos)[0]
    pos += 4
    result = []
    for _ in range(count):
        name, pos = read_fstring(raw, pos)
        if name:
            result.append(name)
    return result


def parse_relic_by_type(raw):
    """Decode RelicObtainForInstanceFlagByType -> {GUID_UPPER: short_relic_type} for every
    COLLECTED (true) effigy across ALL relic types.

    This is the COMPREHENSIVE effigy store. The flat RelicObtainForInstanceFlag map that
    extract_effigy_data historically read holds ONLY EPalRelicType::CapturePower relics --
    confirmed 2026-07-13 by a controlled before/after save diff (picking up a GliderSpeed
    effigy appended solely to this by-type array + RelicPossessNumMap, never to the flat map;
    see /palworld-dataminer). Every non-CapturePower relic (MoveSpeed/JumpPower/SphereHoming/
    HungerReduction/GliderSpeed/...) lives ONLY here, so reading the flat map alone silently
    dropped them from effigy tracking.

    Layout (ArrayProperty of StructProperty, confirmed byte-exact): each element is a struct
    with a `Type` EnumProperty (value "EPalRelicType::<Kind>") followed by a `Flags`
    MapProperty (Name->Bool, the collected instance GUIDs of that type), terminated by "None".
    We bound the scan to the array's own declared byte size and walk Type/Flags markers in
    file order, so each Flags map is attributed to the Type that immediately precedes it.
    Returns short kinds ("CapturePower", "GliderSpeed", ...), the part after "EPalRelicType::".
    """
    pos = find_property(raw, "RelicObtainForInstanceFlagByType")
    if pos == -1:
        return {}
    _, p = read_fstring(raw, pos)   # property name
    _, p = read_fstring(raw, p)     # "ArrayProperty"
    size = struct.unpack_from("<q", raw, p)[0]
    p += 8
    end = min(len(raw), p + size + 32)  # +32 slack; bound keeps generic Type/Flags names local
    # FString length-prefixed markers: "Type"=len 5 (4+null), "Flags"=len 6 (5+null).
    TYPE_NEEDLE = b"\x05\x00\x00\x00Type\x00"
    FLAGS_NEEDLE = b"\x06\x00\x00\x00Flags\x00"
    out = {}
    cur_type = None
    scan = p
    while scan < end:
        t = raw.find(TYPE_NEEDLE, scan, end)
        f = raw.find(FLAGS_NEEDLE, scan, end)
        if t == -1 and f == -1:
            break
        if t != -1 and (f == -1 or t < f):
            q = t + len(TYPE_NEEDLE)
            _, q = read_fstring(raw, q)   # "EnumProperty"
            q += 8                        # int64 size
            _, q = read_fstring(raw, q)   # enum class ("EPalRelicType")
            q += 1                        # HasPropertyGuid
            val, q = read_fstring(raw, q)  # "EPalRelicType::<Kind>"
            cur_type = val.split("::")[-1] if val else None
            scan = q
        else:
            q = f + len(FLAGS_NEEDLE)
            _, q = read_fstring(raw, q)   # "MapProperty"
            entries = parse_name_bool_map_full(raw, q)  # {GUID_UPPER: bool}
            if cur_type:
                for guid, is_set in entries.items():
                    if is_set:
                        out[guid] = cur_type
            scan = f + len(FLAGS_NEEDLE)   # advance past this marker; next find gets next element
    return out


def collected_effigies(raw):
    """Uppercase GUID list of every collected effigy, unioning the comprehensive by-type store
    (all relic types) with the legacy flat CapturePower-only map. Flat is a subset of by-type
    in practice, but unioning is cheap and robust against an unusually old save. Given raw
    decompressed bytes so per-player callers that already decompressed don't do it twice."""
    result = set(parse_relic_by_type(raw).keys())
    pos = find_property(raw, "RelicObtainForInstanceFlag")
    if pos != -1:
        _, p = read_fstring(raw, pos)
        _, p = read_fstring(raw, p)
        result.update(parse_name_bool_map(raw, p))
    return sorted(result)


def extract_effigy_data(sav_path):
    """Return list of uppercase hex GUID strings for collected effigies, across ALL relic
    types (see collected_effigies / parse_relic_by_type)."""
    raw = decompress_save(sav_path)
    return collected_effigies(raw)


def extract_effigy_type_map(sav_path):
    """{GUID_UPPER: short_relic_type} for the world's effigies, derived from this save's
    RelicObtainForInstanceFlagByType. The world map is fixed, so a GUID's type is the same for
    every player -- callers merge these across all players to build a global GUID->type map."""
    raw = decompress_save(sav_path)
    return parse_relic_by_type(raw)


def extract_fast_travel_data(sav_path):
    """Return list of uppercase hex GUID strings for unlocked fast-travel points ("Eagle
    Statues"). FastTravelPointUnlockFlag is a Name->Bool map, same layout as
    RelicObtainForInstanceFlag/NoteObtainForInstanceFlag."""
    raw = decompress_save(sav_path)
    pos = find_property(raw, "FastTravelPointUnlockFlag")
    if pos == -1:
        return []
    _, p = read_fstring(raw, pos)
    _, p = read_fstring(raw, p)
    return parse_name_bool_map(raw, p)


def extract_item_pickup_data(sav_path):
    """Return list of uppercase hex GUID strings for world item-pickup instances this player has
    collected -- the schematic/blueprint chests inside locked buildings (and any other fixed-world
    item pickup). ItemPickupObtainForInstanceFlag is a Name->Bool map, same layout as
    RelicObtainForInstanceFlag/NoteObtainForInstanceFlag; per-player (each save records that
    player's own pickups of the shared world instances)."""
    raw = decompress_save(sav_path)
    pos = find_property(raw, "ItemPickupObtainForInstanceFlag")
    if pos == -1:
        return []
    _, p = read_fstring(raw, pos)
    _, p = read_fstring(raw, p)
    return parse_name_bool_map(raw, p)


def extract_tower_boss_data(sav_path):
    """Return list of uppercase "BOSS_BATTLE_NAME_<ZONE>" keys for defeated Tower raid
    bosses. TowerBossDefeatFlag is a Name->Bool map, same layout as
    FastTravelPointUnlockFlag/RelicObtainForInstanceFlag -- confirmed against a real
    decoded save snippet Anthony supplied 2026-07-07 (6 keys: DESERTBOSS/ELECTRICBOSS/
    FORESTBOSS/GRASSBOSS/SAKURAJIMABOSS/SNOWBOSS -- Feybreak Tower's key, if one exists,
    hasn't been seen yet). This appears to track normal-difficulty clears only; a
    separate hard-mode flag existed before the map-data consolidation but was lost and
    has not been re-identified yet -- see towers.json's bossKey field and the
    palbox-confirmed-locations skill."""
    raw = decompress_save(sav_path)
    pos = find_property(raw, "TowerBossDefeatFlag")
    if pos == -1:
        return []
    _, p = read_fstring(raw, pos)
    _, p = read_fstring(raw, p)
    return parse_name_bool_map(raw, p)


def extract_fugitive_data(sav_path):
    """Return the raw list of ALL true NormalBossDefeatFlag keys (uppercased), unfiltered --
    used to check whether a specific confirmed Wanted Fugitive key (syndicate_bosses.json /
    confirmed_locations.json) has been defeated. Unlike extract_bounty_data this doesn't
    resolve to a bounty species by suffix -- Wanted Fugitives are matched by exact key."""
    raw = decompress_save(sav_path)
    pos = find_property(raw, "NormalBossDefeatFlag")
    if pos == -1:
        return []
    _, p = read_fstring(raw, pos)
    _, p = read_fstring(raw, p)
    return parse_name_bool_map(raw, p)


def load_bounty_species():
    """Species codes tracked as "bounty bosses" -- the curated set of named legendary
    Alpha bosses in bounty_bosses.json (single fixed world location each, source: paldb's
    DT_PaldexDistributionData). Loaded from the file next to this script (not hardcoded
    here) so the species list and the map locations can never drift out of sync."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bounty_bosses.json")
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return [b["species"] for b in data if b.get("species")]
    except Exception:
        return []


def load_anonymous_boss_keys():
    """Exact NormalBossDefeatFlag key -> species, for anonymous zone-numbered field-alpha
    keys ("<zone>_<n>_<biome>_FBOSS_<n>") that carry no species suffix. The world map is
    fixed (not per-save), so once a specific key is confirmed (manually, by correlating a
    known spawn location to a defeat) it's a permanent match for every player/save on this
    server. Grows one entry at a time as Anthony supplies confirmed mappings -- see the
    palbox-bounty-tracker skill's "auto-detection limitation" section. Loaded from the file
    next to this script, matched keys uppercased same as parse_name_bool_map's output."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "anonymous_boss_keys.json")
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return {e["key"].upper(): e["species"] for e in data if e.get("key") and e.get("species")}
    except Exception:
        return {}


def load_excluded_boss_keys():
    """Exact NormalBossDefeatFlag keys to ignore entirely when matching bounty species --
    keys that suffix-match or anonymous-match a species but turned out to be unreliable
    (see excluded_boss_keys.json for the reason each was added). Checked in BOTH the
    suffix-match and the anonymous-key lookup, so an excluded key falls through to the raw
    "anonymous" bucket in extract_datamine_data instead of being misattributed to a
    species -- see the palbox-bounty-tracker skill's "OPEN QUESTION" note."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "excluded_boss_keys.json")
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return {e["key"].upper() for e in data if e.get("key")}
    except Exception:
        return set()


def _bounty_from_flags(flags):
    """Given an already-parsed NormalBossDefeatFlag list (uppercased true keys), return the
    list of bounty-boss species defeated. Split out of extract_bounty_data so playerall mode
    (which parses NormalBossDefeatFlag once and needs both the bounty view and the raw
    fugitive view of it) doesn't have to parse it twice."""
    flag_set = set(flags)
    excluded = load_excluded_boss_keys()
    defeated = []
    # Anonymous exact-key overrides take priority over suffix-matching, since a key can carry
    # a misleading suffix (e.g. "..._BOSS_FAIRYDRAGON" confirmed to actually be WeaselDragon) --
    # claiming it here first stops the suffix loop below from also misattributing it.
    claimed_keys = set()
    for key, species in load_anonymous_boss_keys().items():
        if key not in excluded and key in flag_set:
            if species not in defeated:
                defeated.append(species)
            claimed_keys.add(key)
    for species in load_bounty_species():
        suffix = "_BOSS_" + species.upper()
        if any(k.endswith(suffix) for k in flags if k not in excluded and k not in claimed_keys):
            defeated.append(species)
    return defeated


def extract_bounty_data(sav_path):
    """Return the list of bounty-boss species codes this player has defeated.

    NormalBossDefeatFlag (same NameProperty->BoolProperty map shape as effigies'
    RelicObtainForInstanceFlag) keys named legendary Alphas as
    "<zone>_<n>_<biome>_F_BOSS_<SPECIES>" (e.g. "1_10_PLAIN_F_BOSS_FAIRYDRAGON"). The same
    flag also carries many unrelated entries (generic numbered field-alpha spawns, human
    Syndicate/bandit "boss" fights) that we don't have location data for, so we only match
    keys whose suffix identifies one of our known bounty-boss species, plus any exact key
    confirmed in anonymous_boss_keys.json (see load_anonymous_boss_keys).
    """
    raw = decompress_save(sav_path)
    pos = find_property(raw, "NormalBossDefeatFlag")
    if pos == -1:
        return []
    _, p = read_fstring(raw, pos)
    _, p = read_fstring(raw, p)
    flags = parse_name_bool_map(raw, p)  # already-true, uppercased keys
    return _bounty_from_flags(flags)


def extract_datamine_data(sav_path):
    """One-pass bucketing of every NormalBossDefeatFlag key for the admin "Data Mine" tab,
    which shows all three categories side by side (bounty bosses have a static location
    roster; syndicate/anonymous do not, so they're just raw key lists):

      - bounty: species codes matched against bounty_bosses.json suffix ("_BOSS_<SPECIES>"),
        i.e. named legendary Alphas with a known fixed world location.
      - syndicate: raw "BOSS_*" human/NPC boss keys (Syndicate Tower fights etc.), no zone
        prefix, no location data.
      - anonymous: everything else -- zone-numbered field-alpha spawns ("<zone>_<n>_..._F_BOSS_
        <SPECIES>"/"_FBOSS_<n>") that didn't match a known bounty species suffix or a confirmed
        entry in anonymous_boss_keys.json. Species for these lives in the game's .pak assets,
        not the save (see the palbox-bounty-tracker skill's "auto-detection limitation"
        section) -- shown as raw keys only.

    Also returns the three account-wide PredatorDefeatCount/FixedDungeonClearCount/
    NormalDungeonClearCount stats, which live alongside this flag map but aren't tied to any
    specific boss key.
    """
    raw = decompress_save(sav_path)

    bounty, syndicate, anonymous = [], [], []
    pos = find_property(raw, "NormalBossDefeatFlag")
    if pos != -1:
        _, p = read_fstring(raw, pos)
        _, p = read_fstring(raw, p)
        flags = parse_name_bool_map(raw, p)
        excluded = load_excluded_boss_keys()
        matched_keys = set()
        # Anonymous exact-key overrides are claimed first -- same priority reasoning as
        # extract_bounty_data() above, so a mislabeled-suffix key (e.g. FairyDragon's suffix
        # actually meaning WeaselDragon) can't be double-attributed to both species.
        for key, species in load_anonymous_boss_keys().items():
            if key not in excluded and key in flags and key not in matched_keys:
                bounty.append(species)
                matched_keys.add(key)
        for species in load_bounty_species():
            suffix = "_BOSS_" + species.upper()
            for k in flags:
                if k in excluded or k in matched_keys:
                    continue
                if k.endswith(suffix):
                    bounty.append(species)
                    matched_keys.add(k)
                    break
        for k in flags:
            if k in matched_keys:
                continue
            if k.startswith("BOSS_"):
                syndicate.append(k)
            else:
                anonymous.append(k)

    def read_int_stat(name):
        sp = find_property(raw, name)
        if sp == -1:
            return 0
        _, q = read_fstring(raw, sp)
        _, q = read_fstring(raw, q)
        q += 9  # 8-byte size + 1-byte padding
        return struct.unpack_from("<i", raw, q)[0]

    return {
        "bounty": bounty,
        "syndicate": syndicate,
        "anonymous": anonymous,
        "predatorDefeatCount": read_int_stat("PredatorDefeatCount"),
        "fixedDungeonClearCount": read_int_stat("FixedDungeonClearCount"),
        "normalDungeonClearCount": read_int_stat("NormalDungeonClearCount"),
    }


# Every top-level save property known (per /palworld-dataminer's reverse-engineering) to
# hold enumerable per-key data -- the registry behind the admin dashboard's generic Data
# Mine key/property browser. "kind" picks the matching raw parser above. Extending this list
# is the ONLY step needed to expose a newly-decoded property in that browser -- no dashboard
# code changes required beyond mirroring the same (name, kind) pair in dashboard.html.
DATAMINE_PROPERTIES = [
    ("NormalBossDefeatFlag", "bool_map"),
    ("RelicObtainForInstanceFlag", "bool_map"),
    ("NoteObtainForInstanceFlag", "bool_map"),
    ("FastTravelPointUnlockFlag", "bool_map"),
    ("TowerBossDefeatFlag", "bool_map"),
    ("ItemPickupObtainForInstanceFlag", "bool_map"),
    ("PaldeckUnlockFlag", "bool_map"),
    ("PalCaptureBonusCount", "int_map"),
]


def extract_all_datamine_properties(sav_path):
    """Every DATAMINE_PROPERTIES entry for one player's save, keyed by property name --
    {"entries": {}} / {"entries": []} (empty, matching "kind") for any property not yet
    present in this particular save rather than omitting the key, so the dashboard can
    always rely on every registered property being present in the response."""
    raw = decompress_save(sav_path)
    out = {}
    for name, kind in DATAMINE_PROPERTIES:
        pos = find_property(raw, name)
        if pos == -1:
            out[name] = {"kind": kind, "entries": [] if kind == "name_array" else {}}
            continue
        _, p = read_fstring(raw, pos)
        _, p = read_fstring(raw, p)
        try:
            if kind == "bool_map":
                entries = parse_name_bool_map_full(raw, p)
            elif kind == "int_map":
                entries = parse_name_int_map(raw, p)
            else:
                entries = parse_name_array(raw, p)
        except Exception:
            entries = [] if kind == "name_array" else {}
        out[name] = {"kind": kind, "entries": entries}
    return out


def extract_fixed_weapon_destroyed(level_sav_path):
    """Uppercase-hex (no dashes) Guid strings for every entry in worldSaveData's
    FixedWeaponDestroySaveData.DestroyedWeapon array -- the save-side signal for a
    destroyed Feybreak SAM Site. World-scoped (Level.sav), NOT per-player -- unlike every
    other DATAMINE_PROPERTIES entry above, this doesn't exist in any player .sav at all.
    The property itself doesn't exist until the very first fixed weapon is ever destroyed
    on this world (append-only after that, same convention as every other collection flag
    in this file). Reverse-engineered via a before/after byte diff of Level.sav across a
    real destroy event (2026-07-09) -- see /palbox-confirmed-locations' SAM Site section.
    """
    if not os.path.isfile(level_sav_path):
        return []
    raw = decompress_save(level_sav_path)
    pos = find_property(raw, "FixedWeaponDestroySaveData")
    if pos == -1:
        return []
    _, p = read_fstring(raw, pos)          # property name
    typ, p = read_fstring(raw, p)          # "StructProperty"
    if typ != "StructProperty":
        return []
    size = struct.unpack_from("<i", raw, p)[0]
    p += 8                                  # Size (already read above) + ArrayIndex
    _, p = read_fstring(raw, p)             # StructName ("PalFixedWeaponDestroySaveData")
    p += 16                                 # struct GUID (metadata, always zero so far)
    p += 1                                  # HasPropertyGuid
    end = p + size

    keys = []
    while p < end:
        fname, p2 = read_fstring(raw, p)
        if not fname or fname == "None":
            break
        ftype, p2 = read_fstring(raw, p2)
        fsize, _farrayidx = struct.unpack_from("<ii", raw, p2)
        p2 += 8
        if ftype != "ArrayProperty":
            p = p2 + fsize
            continue
        innertype, p2 = read_fstring(raw, p2)
        p2 += 1                             # HasPropertyGuid
        count = struct.unpack_from("<I", raw, p2)[0]
        p2 += 4
        if innertype == "StructProperty" and count > 0:
            _, p2 = read_fstring(raw, p2)    # repeated element tag: name
            _, p2 = read_fstring(raw, p2)    # "StructProperty"
            elemsize = struct.unpack_from("<i", raw, p2)[0]
            p2 += 8
            elemstructname, p2 = read_fstring(raw, p2)
            p2 += 16                        # element struct GUID (metadata)
            p2 += 1                         # HasPropertyGuid
            # elemsize is the TOTAL raw payload for every element (16*count), not one
            # element's size -- confirmed live (2026-07-10): a 1-entry array showed
            # elemsize=16, but once a second SAM Site was destroyed the same day, the
            # real array showed elemsize=32. The original `elemsize == 16` check silently
            # skipped the whole read once count>1 (looked like a validation guard, was
            # actually only ever correct by coincidence for exactly one element), leaving
            # `p2` unadvanced and desyncing every property read after it for the rest of
            # the file -- surfaced as a wild out-of-bounds unpack_from offset.
            if elemstructname == "Guid" and elemsize == 16 * count:
                for _ in range(count):
                    a, b, c, d = struct.unpack_from("<IIII", raw, p2)
                    keys.append("%08X%08X%08X%08X" % (a, b, c, d))
                    p2 += 16
        p = p2
    return keys


def extract_player_data(sav_path):
    raw = decompress_save(sav_path)

    tribe_total = 0
    tcc_pos = find_property(raw, "TribeCaptureCount")
    if tcc_pos != -1:
        _, p = read_fstring(raw, tcc_pos)
        _, p = read_fstring(raw, p)
        p += 9  # 8-byte size + 1-byte padding
        tribe_total = struct.unpack_from("<i", raw, p)[0]

    counts = {}
    pcc_pos = find_property(raw, "PalCaptureCount")
    if pcc_pos != -1:
        _, p = read_fstring(raw, pcc_pos)
        _, p = read_fstring(raw, p)
        counts = parse_name_int_map(raw, p)

    return {"tribeCaptureCount": tribe_total, "counts": counts}


def main():
    save_dir = sys.argv[1] if len(sys.argv) > 1 else \
        r"PATH\TO\Pal\Saved\SaveGames\0\<WorldGUID>"  # fallback for manual runs; the dashboard passes the real save folder as argv[1]

    # playerall mode: python pal_save_reader.py <save_dir> playerall <guid>
    # Emits effigies/notes/bounties/fugitives/eagles in ONE decompress instead of the
    # five separate process spawns build_public_data.ps1 used to make per player, per sync
    # tick, each re-decompressing the same small per-player .sav. bounties and fugitives
    # both come from the same NormalBossDefeatFlag map -- parsed once here and shared via
    # _bounty_from_flags, rather than two more independent decompresses of the same file
    # for the same underlying flag data. Output shapes match the five individual modes
    # exactly ({"guid":...,"collected":[...]} each) so the builder just splits this one
    # response into the same five files it always wrote.
    if len(sys.argv) > 2 and sys.argv[2] == "playerall":
        guid = sys.argv[3] if len(sys.argv) > 3 else ""
        sav_path = os.path.join(save_dir, "Players", guid + ".sav")
        if not os.path.isfile(sav_path):
            print(json.dumps({"error": f"Player save not found: {sav_path}"}))
            return
        try:
            raw = decompress_save(sav_path)

            def flags_for(prop_name):
                pos = find_property(raw, prop_name)
                if pos == -1:
                    return []
                _, p = read_fstring(raw, pos)
                _, p = read_fstring(raw, p)
                return parse_name_bool_map(raw, p)

            boss_flags = flags_for("NormalBossDefeatFlag")

            print(json.dumps({
                "guid": guid,
                "effigies": collected_effigies(raw),
                "notes": flags_for("NoteObtainForInstanceFlag"),
                "bounties": _bounty_from_flags(boss_flags),
                "fugitives": boss_flags,
                "eagles": flags_for("FastTravelPointUnlockFlag"),
                "towerBosses": flags_for("TowerBossDefeatFlag"),
                "itemPickups": flags_for("ItemPickupObtainForInstanceFlag"),
            }, separators=(",", ":")))
        except Exception as e:
            print(json.dumps({"guid": guid, "effigies": [], "notes": [], "bounties": [],
                               "fugitives": [], "eagles": [], "towerBosses": [], "itemPickups": [], "error": str(e)}))
        return

    # effigies mode: python pal_save_reader.py <save_dir> effigies <guid>
    if len(sys.argv) > 2 and sys.argv[2] == "effigies":
        guid = sys.argv[3] if len(sys.argv) > 3 else ""
        sav_path = os.path.join(save_dir, "Players", guid + ".sav")
        if not os.path.isfile(sav_path):
            print(json.dumps({"error": f"Player save not found: {sav_path}"}))
            return
        try:
            collected = extract_effigy_data(sav_path)
            print(json.dumps({"guid": guid, "collected": collected}, separators=(",", ":")))
        except Exception as e:
            print(json.dumps({"guid": guid, "collected": [], "error": str(e)}))
        return

    # effigy-types mode: python pal_save_reader.py <save_dir> effigy-types [guid]
    # Emits the GUID->relic-type map from RelicObtainForInstanceFlagByType. World effigies are
    # fixed, so this map is player-independent; with no guid it merges the map across EVERY
    # player save in the world (so a type collected by any one of the Six is known globally).
    if len(sys.argv) > 2 and sys.argv[2] == "effigy-types":
        guid = sys.argv[3] if len(sys.argv) > 3 else ""
        try:
            type_map = {}
            if guid:
                sav_path = os.path.join(save_dir, "Players", guid + ".sav")
                if os.path.isfile(sav_path):
                    type_map = extract_effigy_type_map(sav_path)
            else:
                players_dir = os.path.join(save_dir, "Players")
                if os.path.isdir(players_dir):
                    for fn in os.listdir(players_dir):
                        if fn.endswith(".sav") and not fn.endswith("_dps.sav"):
                            try:
                                type_map.update(extract_effigy_type_map(os.path.join(players_dir, fn)))
                            except Exception:
                                pass  # a single unreadable player save shouldn't drop the rest
            print(json.dumps({"types": type_map}, separators=(",", ":")))
        except Exception as e:
            print(json.dumps({"types": {}, "error": str(e)}))
        return

    # itempickups mode: python pal_save_reader.py <save_dir> itempickups <guid>
    # Per-player collected world item-pickup instance GUIDs (schematic/blueprint chests etc.),
    # from ItemPickupObtainForInstanceFlag. Same shape as the effigies mode -- backs the Map
    # tab's /api/player-itempickups status polling.
    if len(sys.argv) > 2 and sys.argv[2] == "itempickups":
        guid = sys.argv[3] if len(sys.argv) > 3 else ""
        sav_path = os.path.join(save_dir, "Players", guid + ".sav")
        if not os.path.isfile(sav_path):
            print(json.dumps({"error": f"Player save not found: {sav_path}"}))
            return
        try:
            collected = extract_item_pickup_data(sav_path)
            print(json.dumps({"guid": guid, "collected": collected}, separators=(",", ":")))
        except Exception as e:
            print(json.dumps({"guid": guid, "collected": [], "error": str(e)}))
        return

    # bounties mode: python pal_save_reader.py <save_dir> bounties <guid>
    if len(sys.argv) > 2 and sys.argv[2] == "bounties":
        guid = sys.argv[3] if len(sys.argv) > 3 else ""
        sav_path = os.path.join(save_dir, "Players", guid + ".sav")
        if not os.path.isfile(sav_path):
            print(json.dumps({"error": f"Player save not found: {sav_path}"}))
            return
        try:
            collected = extract_bounty_data(sav_path)
            print(json.dumps({"guid": guid, "collected": collected}, separators=(",", ":")))
        except Exception as e:
            print(json.dumps({"guid": guid, "collected": [], "error": str(e)}))
        return

    # datamine mode: python pal_save_reader.py <save_dir> datamine <guid>
    if len(sys.argv) > 2 and sys.argv[2] == "datamine":
        guid = sys.argv[3] if len(sys.argv) > 3 else ""
        sav_path = os.path.join(save_dir, "Players", guid + ".sav")
        if not os.path.isfile(sav_path):
            print(json.dumps({"error": f"Player save not found: {sav_path}"}))
            return
        try:
            result = extract_datamine_data(sav_path)
            result["guid"] = guid
            print(json.dumps(result, separators=(",", ":")))
        except Exception as e:
            print(json.dumps({"guid": guid, "bounty": [], "syndicate": [], "anonymous": [], "error": str(e)}))
        return

    # notes mode: python pal_save_reader.py <save_dir> notes <guid>
    if len(sys.argv) > 2 and sys.argv[2] == "notes":
        guid = sys.argv[3] if len(sys.argv) > 3 else ""
        sav_path = os.path.join(save_dir, "Players", guid + ".sav")
        if not os.path.isfile(sav_path):
            print(json.dumps({"error": f"Player save not found: {sav_path}"}))
            return
        try:
            raw = decompress_save(sav_path)
            pos = find_property(raw, "NoteObtainForInstanceFlag")
            if pos == -1:
                print(json.dumps({"guid": guid, "collected": []}, separators=(",", ":")))
                return
            _, p = read_fstring(raw, pos)
            _, p = read_fstring(raw, p)
            collected = parse_name_bool_map(raw, p)
            print(json.dumps({"guid": guid, "collected": collected}, separators=(",", ":")))
        except Exception as e:
            print(json.dumps({"guid": guid, "collected": [], "error": str(e)}))
        return

    # fugitives mode: python pal_save_reader.py <save_dir> fugitives <guid>
    if len(sys.argv) > 2 and sys.argv[2] == "fugitives":
        guid = sys.argv[3] if len(sys.argv) > 3 else ""
        sav_path = os.path.join(save_dir, "Players", guid + ".sav")
        if not os.path.isfile(sav_path):
            print(json.dumps({"error": f"Player save not found: {sav_path}"}))
            return
        try:
            collected = extract_fugitive_data(sav_path)
            print(json.dumps({"guid": guid, "collected": collected}, separators=(",", ":")))
        except Exception as e:
            print(json.dumps({"guid": guid, "collected": [], "error": str(e)}))
        return

    # eagles mode: python pal_save_reader.py <save_dir> eagles <guid>
    if len(sys.argv) > 2 and sys.argv[2] == "eagles":
        guid = sys.argv[3] if len(sys.argv) > 3 else ""
        sav_path = os.path.join(save_dir, "Players", guid + ".sav")
        if not os.path.isfile(sav_path):
            print(json.dumps({"error": f"Player save not found: {sav_path}"}))
            return
        try:
            collected = extract_fast_travel_data(sav_path)
            print(json.dumps({"guid": guid, "collected": collected}, separators=(",", ":")))
        except Exception as e:
            print(json.dumps({"guid": guid, "collected": [], "error": str(e)}))
        return

    # towerbosses mode: python pal_save_reader.py <save_dir> towerbosses <guid>
    if len(sys.argv) > 2 and sys.argv[2] == "towerbosses":
        guid = sys.argv[3] if len(sys.argv) > 3 else ""
        sav_path = os.path.join(save_dir, "Players", guid + ".sav")
        if not os.path.isfile(sav_path):
            print(json.dumps({"error": f"Player save not found: {sav_path}"}))
            return
        try:
            collected = extract_tower_boss_data(sav_path)
            print(json.dumps({"guid": guid, "collected": collected}, separators=(",", ":")))
        except Exception as e:
            print(json.dumps({"guid": guid, "collected": [], "error": str(e)}))
        return

    # datamine-full mode: python pal_save_reader.py <save_dir> datamine-full <guid>
    # Every DATAMINE_PROPERTIES entry for one player -- backs the admin dashboard's generic
    # Data Mine key/property browser (see /palworld-dataminer skill). Also merges in
    # DestroyedWeapon (SAM Site), which is world-scoped (Level.sav) rather than per-player --
    # folded into every player's response here (rather than a separate fetch) so the existing
    # dmFullPlayers/dmAllKeysFor client-side machinery picks it up for free, the same way
    # every other registered property does.
    if len(sys.argv) > 2 and sys.argv[2] == "datamine-full":
        guid = sys.argv[3] if len(sys.argv) > 3 else ""
        sav_path = os.path.join(save_dir, "Players", guid + ".sav")
        if not os.path.isfile(sav_path):
            print(json.dumps({"error": f"Player save not found: {sav_path}"}))
            return
        try:
            properties = extract_all_datamine_properties(sav_path)
            try:
                destroyed = extract_fixed_weapon_destroyed(os.path.join(save_dir, "Level.sav"))
            except Exception:
                destroyed = []
            properties["DestroyedWeapon"] = {"kind": "name_array", "entries": destroyed}
            print(json.dumps({"guid": guid, "properties": properties}, separators=(",", ":")))
        except Exception as e:
            print(json.dumps({"guid": guid, "properties": {}, "error": str(e)}))
        return

    # destroyed-weapons mode: python pal_save_reader.py <save_dir> destroyed-weapons
    # World-scoped, no guid needed -- backs the Map tab's own "is this SAM Site destroyed"
    # status fetch, independent of the (heavier, per-player) Data Mine tab machinery above.
    if len(sys.argv) > 2 and sys.argv[2] == "destroyed-weapons":
        try:
            keys = extract_fixed_weapon_destroyed(os.path.join(save_dir, "Level.sav"))
            print(json.dumps({"keys": keys}, separators=(",", ":")))
        except Exception as e:
            print(json.dumps({"keys": [], "error": str(e)}))
        return

    players_dir = os.path.join(save_dir, "Players")
    if not os.path.isdir(players_dir):
        print(json.dumps({"error": f"Players dir not found: {players_dir}"}))
        return

    # Collect player GUIDs from save file names
    player_files = sorted(
        f for f in os.listdir(players_dir)
        if f.endswith(".sav") and "_dps" not in f
    )
    guids = [f.replace(".sav", "") for f in player_files]

    # Resolve display names from Level.sav. Structural (IsPlayer-checked) resolution,
    # not the find_player_names_raw byte-scan below -- that heuristic can misattribute a
    # player's own Pal's NickName to the player when the pal's owner-GUID bytes sit
    # closer to the pal's NickName property than the player's own NickName does (see
    # pal_team_reader.read_player_names' docstring; observed 2026-07-10 via a SamuraiDog
    # nicknamed "Pupperai"). This is the /api/paldeck fallback used only when the
    # PS1 layer's own live-REST/playtime name isn't available (e.g. player offline),
    # so it's worth getting right rather than relying on the caller to mask it.
    from pal_team_reader import read_player_names
    names_by_prefix = read_player_names(save_dir)
    guid_to_name = {g: names_by_prefix.get(g[:8].upper(), g[:8]) for g in guids}

    players = []
    for fname in player_files:
        guid = fname.replace(".sav", "")
        path = os.path.join(players_dir, fname)
        name = guid_to_name.get(guid, guid[:8])
        try:
            data = extract_player_data(path)
            players.append({
                "guid": guid,
                "name": name,
                "tribeCaptureCount": data["tribeCaptureCount"],
                "counts": data["counts"],
            })
        except Exception as e:
            players.append({"guid": guid, "name": name, "tribeCaptureCount": 0, "counts": {}, "error": str(e)})

    print(json.dumps({"players": players}, separators=(",", ":")))


if __name__ == "__main__":
    main()
