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


def extract_effigy_data(sav_path):
    """Return list of uppercase hex GUID strings for collected effigies."""
    raw = decompress_save(sav_path)
    pos = find_property(raw, "RelicObtainForInstanceFlag")
    if pos == -1:
        return []
    _, p = read_fstring(raw, pos)
    _, p = read_fstring(raw, p)
    return parse_name_bool_map(raw, p)


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


def extract_npc_data(sav_path):
    """Return list of uppercase hex GUID strings for NPCs the player has talked to at
    least once. NPCTalkCountMap is a Name->Int map (talk count per NPC instance), not a
    Name->Bool flag like Relic/Note/NormalBossDefeat -- so "collected" here means count > 0,
    parsed via parse_name_int_map rather than parse_name_bool_map."""
    raw = decompress_save(sav_path)
    pos = find_property(raw, "NPCTalkCountMap")
    if pos == -1:
        return []
    _, p = read_fstring(raw, pos)
    _, p = read_fstring(raw, p)
    counts = parse_name_int_map(raw, p)
    return [name.upper() for name, count in counts.items() if count > 0]


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


def find_player_names_raw(raw, player_guids):
    """Core logic behind find_player_names, operating on an ALREADY-DECOMPRESSED Level.sav
    buffer. Split out so a caller that already holds that buffer for another reason (e.g.
    pal_egg_reader.py, which GVAS-parses the same Level.sav) doesn't have to decompress it a
    second time just to resolve names -- decompression, not the byte-scan below, is the
    expensive part.

    Player NickName properties in Level.sav are preceded by the player's GUID
    bytes (first 4 bytes, little-endian) within ~1000 bytes. This locates
    names without needing a full GVAS parse.
    """
    # Build GUID -> 4-byte LE search pattern for each known player
    guid_patterns = {}
    for guid in player_guids:
        if len(guid) < 8:
            continue
        try:
            le_bytes = struct.pack("<I", int(guid[:8], 16))
            guid_patterns[le_bytes] = guid
        except ValueError:
            continue

    names = {}
    pos = 0
    needle = b"NickName\x00"
    while True:
        idx = raw.find(needle, pos)
        if idx == -1:
            break

        nick_fstr_start = idx - 4
        if nick_fstr_start < 0 or struct.unpack_from("<I", raw, nick_fstr_start)[0] != 9:
            pos = idx + 1
            continue

        # Read the NickName StrProperty value
        try:
            p = nick_fstr_start
            _, p = read_fstring(raw, p)   # "NickName"
            typ, p = read_fstring(raw, p) # type name
            if typ != "StrProperty":
                pos = idx + 1
                continue
            p += 9  # 8-byte size + 1-byte padding
            name, _ = read_fstring(raw, p)
        except Exception:
            pos = idx + 1
            continue

        if not name or len(name) > 64:
            pos = idx + 1
            continue

        # Player NickNames are in the early section of Level.sav; Pal NickNames
        # start much later (~2.4 MB in). Skip anything past 2 MB.
        if nick_fstr_start > 0x200000:
            break

        # Search the 1000 bytes before this NickName for known player GUIDs.
        # Pick the closest match (smallest distance) to avoid false positives
        # from other player GUIDs that appear further back in the window.
        search_start = max(0, nick_fstr_start - 1000)
        search_window = raw[search_start:nick_fstr_start]
        best_guid, best_dist = None, len(search_window) + 1
        for le_bytes, guid in guid_patterns.items():
            last_idx = search_window.rfind(le_bytes)
            if last_idx != -1:
                dist = len(search_window) - last_idx  # distance from NickName
                if dist < best_dist:
                    best_dist, best_guid = dist, guid
        if best_guid:
            names[best_guid] = name

        pos = idx + 1

    return names


def find_player_names(level_sav_path, player_guids):
    """Read Level.sav and return {guid: display_name} for known player GUIDs. See
    find_player_names_raw for the actual matching logic -- this just adds the
    decompress-from-path step for callers that don't already hold the buffer."""
    if not os.path.isfile(level_sav_path):
        return {}
    try:
        raw = decompress_save(level_sav_path)
    except Exception:
        return {}
    return find_player_names_raw(raw, player_guids)


def main():
    save_dir = sys.argv[1] if len(sys.argv) > 1 else \
        r"PATH\TO\Pal\Saved\SaveGames\0\<WorldGUID>"  # fallback for manual runs; the dashboard passes the real save folder as argv[1]

    # playerall mode: python pal_save_reader.py <save_dir> playerall <guid>
    # Emits effigies/notes/bounties/fugitives/npcs/eagles in ONE decompress instead of the
    # six separate process spawns build_public_data.ps1 used to make per player, per sync
    # tick, each re-decompressing the same small per-player .sav. bounties and fugitives
    # both come from the same NormalBossDefeatFlag map -- parsed once here and shared via
    # _bounty_from_flags, rather than two more independent decompresses of the same file
    # for the same underlying flag data. Output shapes match the six individual modes
    # exactly ({"guid":...,"collected":[...]} each) so the builder just splits this one
    # response into the same six files it always wrote.
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
            npcs = []
            npcs_pos = find_property(raw, "NPCTalkCountMap")
            if npcs_pos != -1:
                _, p = read_fstring(raw, npcs_pos)
                _, p = read_fstring(raw, p)
                counts = parse_name_int_map(raw, p)
                npcs = [name.upper() for name, count in counts.items() if count > 0]

            print(json.dumps({
                "guid": guid,
                "effigies": flags_for("RelicObtainForInstanceFlag"),
                "notes": flags_for("NoteObtainForInstanceFlag"),
                "bounties": _bounty_from_flags(boss_flags),
                "fugitives": boss_flags,
                "npcs": npcs,
                "eagles": flags_for("FastTravelPointUnlockFlag"),
            }, separators=(",", ":")))
        except Exception as e:
            print(json.dumps({"guid": guid, "effigies": [], "notes": [], "bounties": [],
                               "fugitives": [], "npcs": [], "eagles": [], "error": str(e)}))
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

    # npcs mode: python pal_save_reader.py <save_dir> npcs <guid>
    if len(sys.argv) > 2 and sys.argv[2] == "npcs":
        guid = sys.argv[3] if len(sys.argv) > 3 else ""
        sav_path = os.path.join(save_dir, "Players", guid + ".sav")
        if not os.path.isfile(sav_path):
            print(json.dumps({"error": f"Player save not found: {sav_path}"}))
            return
        try:
            collected = extract_npc_data(sav_path)
            print(json.dumps({"guid": guid, "collected": collected}, separators=(",", ":")))
        except Exception as e:
            print(json.dumps({"guid": guid, "collected": [], "error": str(e)}))
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

    # Resolve display names from Level.sav
    level_sav = os.path.join(save_dir, "Level.sav")
    guid_to_name = find_player_names(level_sav, guids)

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
