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


def extract_bounty_data(sav_path):
    """Return the list of bounty-boss species codes this player has defeated.

    NormalBossDefeatFlag (same NameProperty->BoolProperty map shape as effigies'
    RelicObtainForInstanceFlag) keys named legendary Alphas as
    "<zone>_<n>_<biome>_F_BOSS_<SPECIES>" (e.g. "1_10_PLAIN_F_BOSS_FAIRYDRAGON"). The same
    flag also carries many unrelated entries (generic numbered field-alpha spawns, human
    Syndicate/bandit "boss" fights) that we don't have location data for, so we only match
    keys whose suffix identifies one of our known bounty-boss species.
    """
    raw = decompress_save(sav_path)
    pos = find_property(raw, "NormalBossDefeatFlag")
    if pos == -1:
        return []
    _, p = read_fstring(raw, pos)
    _, p = read_fstring(raw, p)
    flags = parse_name_bool_map(raw, p)  # already-true, uppercased keys
    defeated = []
    for species in load_bounty_species():
        suffix = "_BOSS_" + species.upper()
        if any(k.endswith(suffix) for k in flags):
            defeated.append(species)
    return defeated


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


def find_player_names(level_sav_path, player_guids):
    """Read Level.sav and return {guid: display_name} for known player GUIDs.

    Player NickName properties in Level.sav are preceded by the player's GUID
    bytes (first 4 bytes, little-endian) within ~1000 bytes. This locates
    names without needing a full GVAS parse.
    """
    if not os.path.isfile(level_sav_path):
        return {}

    try:
        raw = decompress_save(level_sav_path)
    except Exception:
        return {}

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


def main():
    save_dir = sys.argv[1] if len(sys.argv) > 1 else \
        r"PATH\TO\Pal\Saved\SaveGames\0\<WorldGUID>"  # fallback for manual runs; the dashboard passes the real save folder as argv[1]

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
