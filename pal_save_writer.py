"""
Deletes a single key/entry from a Palworld PLAYER save file and writes it back,
safely, for the admin dashboard's Data Mine tab.

This is the FIRST save-mutating tool in the project -- everything else (pal_save_reader.py,
pal_team_reader.py, pal_egg_reader.py) is read-only. Correctness relies entirely on the
palworld_save_tools structural writer: we parse the save into its property tree, drop one
{key,value} entry from a MapProperty's value list, and re-serialize. GvasFile.write()
recomputes every map entry-count, every MapProperty size field, and every enclosing struct
size from the actual mutated bytes -- so we NEVER hand-edit a count or size, which is the
whole reason this can't corrupt the save the way raw byte-surgery through pal_save_reader.py
would (see /palworld-dataminer's "Nesting" notes on why sizes cascade).

Two hard safety properties, both enforced below before anything touches disk:
  1. Round-trip identity guard: read -> write must reproduce the ORIGINAL gvas bytes exactly
     BEFORE we mutate. If it doesn't (e.g. the save has a top-level SetProperty/UInt64Property
     that only has a reader monkeypatch, no writer counterpart), we abort and change nothing.
     This guarantees we only ever rewrite saves we can reproduce byte-for-byte.
  2. Atomic replace: we write to <guid>.sav.tmp, re-read+verify it, then os.replace() over the
     original. Any failure leaves the original untouched.

Compression note: no Oodle COMPRESSOR exists in this environment (ooz.pyd is decompress-only,
no oo2core DLL). The game writes players as PlM1 (Oodle); we can only re-emit PlZ (zlib) via
compress_gvas_to_sav. The game re-accepts a PlZ player save and rewrites native PlM on its
next autosave -- but this MUST be validated once against this server build before trusting the
feature (see the plan's Verification step 1). We keep the original save_type byte (0x31 for
players) so single/double-zlib matches the container the game expects.

Server must be STOPPED before running this -- a running server rewrites player .sav files every
~5s and on shutdown, clobbering any edit. The caller (/api/datamine-delete-key) hard-refuses
via Test-PrimaryServerRunning; this script does not re-check that itself.

Usage:
  python pal_save_writer.py <save_dir> delete-key  <player_guid> <property_name> <key>
  python pal_save_writer.py <save_dir> delete-keys <player_guid> <pairs_json_path>
    save_dir:        world folder (e.g. .../SaveGames/0/<GUID>)
    property_name:   one of ALLOWED_PROPERTIES below (per-player Name->Bool/Int maps only)
    key:             the map key to remove (matched case-insensitively)
    pairs_json_path: a JSON file {"keys":[{"property":..,"key":..}, ...]} for a BATCH delete --
                     every listed key is removed in a single re-serialize + atomic write (one
                     backup, one write), which is what the dashboard's multi-select delete uses.
  Output: JSON on stdout {"ok":true,...} on success; {"ok":false,"error":...} + exit 1 on any
          failure. A key that isn't present is reported per-key (removed:0), not a hard failure,
          as long as at least one key in the batch matched.
"""
import sys, os, io, json, struct, contextlib, zlib

# Reuse the exact 0.6 reader monkeypatches (SetProperty/UInt64Property/tolerant rawdata) the
# other readers install, so parsing here matches how the rest of the project reads these saves.
from pal_team_reader import _install_patches

try:
    import ooz
except ImportError:
    ooz = None

# Per-player .sav map fields only -- all plain NameProperty->Bool/Int maps that round-trip
# cleanly. DELIBERATELY excludes DestroyedWeapon: that is world-scoped (Level.sav), a much
# larger file with more property types and higher round-trip risk -- a separate future effort
# gated behind its own round-trip guard on Level.sav. Mirrors DATAMINE_PROPERTIES in
# pal_save_reader.py minus the world-scoped entry.
ALLOWED_PROPERTIES = {
    "NormalBossDefeatFlag",
    "RelicObtainForInstanceFlag",
    "NoteObtainForInstanceFlag",
    "FastTravelPointUnlockFlag",
    "TowerBossDefeatFlag",
    "PaldeckUnlockFlag",
    "PalCaptureBonusCount",
    "ItemPickupObtainForInstanceFlag",
}


def _fail(msg):
    print(json.dumps({"ok": False, "error": msg}, separators=(",", ":")))
    sys.exit(1)


def _install_writer_patches():
    """palworld_save_tools 0.24.0's FArchiveReader is monkeypatched by pal_team_reader
    (_install_patches) to READ 0.6-only types, but FArchiveWriter has no counterpart, so
    GvasFile.write() raises "Unknown property type: UInt64Property" on a real player save
    (confirmed: every player .sav on this server carries a nested UInt64Property). Add the
    symmetric writer: it mirrors the reader's `{"id": optional_guid(), "value": u64()}` shape
    exactly, so read->write reproduces the original bytes (verified byte-identical on all three
    live player saves). Declared size is 8 (the u64 payload; the optional-guid flag byte is
    written after and excluded from Size, same convention as IntProperty et al. above it).
    NOTE: SetProperty is NOT handled here on purpose -- the reader patch DISCARDS its body
    (byte_list(size) is consumed but not stored), so it can't be re-serialized. If a player
    save ever contains a top-level SetProperty, the round-trip guard in delete_key() will catch
    the mismatch and abort safely rather than emit a corrupt save."""
    from palworld_save_tools.archive import FArchiveWriter
    if getattr(FArchiveWriter, "_palbox_writer_patched", False):
        return
    _orig = FArchiveWriter.property_inner

    def patched(self, property_type, property):
        if property_type == "UInt64Property":
            self.optional_guid(property.get("id", None))
            self.u64(property["value"])
            return 8
        return _orig(self, property_type, property)

    FArchiveWriter.property_inner = patched
    FArchiveWriter._palbox_writer_patched = True


def _load_raw(path):
    """Return (uncompressed_gvas_bytes, save_type_byte). Handles PlM (Oodle, decompress-only)
    and PlZ (zlib). save_type is byte[11] (0x31 single / 0x32 double) -- preserved so we
    re-emit the same container flavor the game expects for this file."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 12:
        _fail("save file too small / not a Palworld save: %s" % path)
    unc = struct.unpack_from("<I", data, 0)[0]
    magic = data[8:11]
    save_type = data[11]
    if magic == b"PlM":
        if ooz is None:
            _fail("pyooz required to read Palworld 0.6+ (PlM) saves: pip install pyooz")
        return ooz.decompress(data[12:], unc), save_type
    if magic == b"PlZ":
        body = data[12:]
        raw = zlib.decompress(body)
        if save_type == 0x32:
            raw = zlib.decompress(raw)
        return raw, save_type
    _fail("unsupported save magic: %r" % magic)


def _find_map_property(node, target):
    """Recursively locate the MapProperty named `target` in a parsed gvas property tree.

    The structural library exposes exactly ONE real occurrence of each property (unlike the
    flat byte-scanner in pal_save_reader.py, whose nesting-blindness reports the same nested
    field several times -- see /palworld-dataminer). So the first match is THE map. We match a
    dict key equal to `target` whose value is a dict tagged type==MapProperty; StructProperty
    values (SaveData, RecordData, ...) are dicts we recurse into via their nested 'value' dict.
    """
    if isinstance(node, dict):
        for k, v in node.items():
            if k == target and isinstance(v, dict) and v.get("type") == "MapProperty":
                return v
        for v in node.values():
            found = _find_map_property(v, target)
            if found is not None:
                return found
    elif isinstance(node, list):
        for item in node:
            found = _find_map_property(item, target)
            if found is not None:
                return found
    return None


def _find_array_property(node, target):
    """Same as _find_map_property but for an ArrayProperty (mirrors its recursion)."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == target and isinstance(v, dict) and v.get("type") == "ArrayProperty":
                return v
        for v in node.values():
            found = _find_array_property(v, target)
            if found is not None:
                return found
    elif isinstance(node, list):
        for item in node:
            found = _find_array_property(item, target)
            if found is not None:
                return found
    return None


# RelicObtainForInstanceFlag (the flat, legacy Name->Bool map DATAMINE_PROPERTIES exposes) is
# NOT the game's authoritative store for CapturePower-type effigies -- RelicObtainForInstance-
# FlagByType is. Confirmed 2026-07-14 via a real before/after: deleting a key from ONLY the flat
# map left ByType untouched, and the very next time the player loaded into the world the game
# rebuilt the flat map from ByType, silently restoring the exact GUIDs that were just deleted
# (see /palworld-dataminer's "RelicObtainForInstanceFlagByType" section -- the flat map is always
# a subset of ByType's CapturePower entries). So a real delete has to remove the key from BOTH
# stores, or it just comes back on the next server start.
_RELIC_FLAT_PROPERTY = "RelicObtainForInstanceFlag"
_RELIC_BYTYPE_PROPERTY = "RelicObtainForInstanceFlagByType"
_RELIC_FLAT_TYPE = "CapturePower"


def _relic_bytype_flags_map(properties, relic_type):
    """Return the Flags MapProperty dict for one EPalRelicType kind inside
    RelicObtainForInstanceFlagByType, or None if the array, or that type's element, isn't
    present in this save (e.g. an older save from before ByType existed, or a player who has
    never collected that relic type)."""
    arr = _find_array_property(properties, _RELIC_BYTYPE_PROPERTY)
    if arr is None:
        return None
    values = ((arr.get("value") or {}).get("values")) or []
    wanted = "EPalRelicType::" + relic_type
    for elem in values:
        if not isinstance(elem, dict):
            continue
        enum_val = (((elem.get("Type") or {}).get("value")) or {}).get("value")
        if enum_val == wanted:
            return elem.get("Flags")
    return None


def delete_keys(sav_path, pairs):
    """Delete every (property, key) in `pairs` from one player's save in a SINGLE re-serialize
    and atomic write -- so a bulk delete does exactly ONE round-trip/compress/replace, not N.
    `pairs` is a list of {"property":..., "key":...}. Each property must already be in
    ALLOWED_PROPERTIES (the caller validates; we assert again here as defence in depth).

    A key that isn't present is reported as removed:0 with a note, not a hard failure -- but if
    NOTHING at all matched across the whole batch, we abort and write nothing (no point rewriting
    an identical save, and it usually means the caller sent stale keys)."""
    from palworld_save_tools.gvas import GvasFile
    from palworld_save_tools.palsav import compress_gvas_to_sav
    from palworld_save_tools import paltypes

    if not os.path.isfile(sav_path):
        _fail("player save not found: %s" % sav_path)
    if not pairs:
        _fail("no keys given to delete")
    for pr in pairs:
        if pr.get("property") not in ALLOWED_PROPERTIES:
            _fail("property %r is not deletable" % pr.get("property"))
        if not pr.get("key"):
            _fail("a key was empty")

    raw, save_type = _load_raw(sav_path)

    _install_patches()
    _install_writer_patches()
    hints = paltypes.PALWORLD_TYPE_HINTS
    custom = paltypes.PALWORLD_CUSTOM_PROPERTIES

    # The library prints "Struct type ... not found" warnings to stdout/stderr; swallow both so
    # only our JSON reaches stdout (same technique pal_team_reader._read_gvas uses).
    sink = io.StringIO()
    try:
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            gvas = GvasFile.read(raw, hints, custom)
    except Exception as e:
        _fail("failed to parse save: %s" % e)

    # ---- Failsafe 1: round-trip identity guard (BEFORE any mutation) ----
    # If we can't reproduce the untouched save byte-for-byte, some property in it isn't
    # faithfully writable (e.g. a top-level SetProperty we can only skip on read). Refuse
    # rather than risk emitting a subtly-wrong save.
    try:
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            baseline = gvas.write(custom)
    except Exception as e:
        _fail("round-trip write failed, refusing to edit (unsupported property in this save): %s" % e)
    if baseline != raw:
        _fail("round-trip mismatch, refusing to edit: writer cannot reproduce this save "
              "byte-for-byte (unsupported/asymmetric property). No changes made.")

    # ---- Remove every requested key, tracking per-key outcome ----
    results = []
    total_removed = 0
    # Expected surviving state per (property, lowercased key) for the post-write verify below.
    to_verify = []
    # (relic_type, lowercased key) pairs mirrored into RelicObtainForInstanceFlagByType, verified
    # separately below since that store isn't a plain top-level MapProperty.
    to_verify_bytype = []
    for pr in pairs:
        prop = pr["property"]
        key = pr["key"]
        key_lc = str(key).lower()
        mapprop = _find_map_property(gvas.properties, prop)
        if mapprop is None or not isinstance(mapprop.get("value"), list):
            results.append({"property": prop, "key": key, "removed": 0, "note": "property not present"})
            continue
        entries = mapprop["value"]
        before = len(entries)
        # Keys can differ in case across maps (e.g. PaldeckUnlockFlag CHICKENPAL vs
        # PalCaptureCount ChickenPal -- see /palworld-dataminer casing gotchas); the UI sends
        # bool-map keys uppercased. Match case-insensitively against the save's actual key.
        kept = [e for e in entries if str(e.get("key")).lower() != key_lc]
        removed = before - len(kept)
        mapprop["value"] = kept  # live reference into gvas.properties -- mutation persists
        total_removed += removed
        note = "" if removed else "key not present"
        if removed and prop == _RELIC_FLAT_PROPERTY:
            flags = _relic_bytype_flags_map(gvas.properties, _RELIC_FLAT_TYPE)
            if flags is not None and isinstance(flags.get("value"), list):
                fb_entries = flags["value"]
                fb_kept = [e for e in fb_entries if str(e.get("key")).lower() != key_lc]
                fb_removed = len(fb_entries) - len(fb_kept)
                flags["value"] = fb_kept
                if fb_removed:
                    note = "also removed from " + _RELIC_BYTYPE_PROPERTY
                    to_verify_bytype.append(key_lc)
        results.append({"property": prop, "key": key, "removed": removed, "note": note})
        if removed:
            to_verify.append((prop, key_lc))

    if total_removed == 0:
        _fail("no matching keys found to delete; nothing written. details=%s"
              % json.dumps(results, separators=(",", ":")))

    # ---- Re-serialize + re-compress (once for the whole batch) ----
    try:
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            new_raw = gvas.write(custom)
    except Exception as e:
        _fail("failed to re-serialize edited save (no changes written): %s" % e)
    new_sav = compress_gvas_to_sav(new_raw, save_type)

    # ---- Failsafe 2: verify the emitted container re-reads correctly ----
    # Decompress what we're about to write and confirm (a) the compression round-trips and
    # (b) every key we removed is really gone in the re-parsed tree.
    try:
        check_raw = zlib.decompress(new_sav[12:])
        if save_type == 0x32:
            check_raw = zlib.decompress(check_raw)
        if check_raw != new_raw:
            _fail("post-write compression check failed (no changes written)")
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            gvas2 = GvasFile.read(check_raw, hints, custom)
        for prop, key_lc in to_verify:
            m2 = _find_map_property(gvas2.properties, prop)
            if m2 is None:
                _fail("post-write verify failed: %s vanished (no changes written)" % prop)
            if any(str(e.get("key")).lower() == key_lc for e in m2.get("value", [])):
                _fail("post-write verify failed: a key still present in %s (no changes written)" % prop)
        for key_lc in to_verify_bytype:
            flags2 = _relic_bytype_flags_map(gvas2.properties, _RELIC_FLAT_TYPE)
            if flags2 is not None and any(str(e.get("key")).lower() == key_lc
                                           for e in flags2.get("value", [])):
                _fail("post-write verify failed: a key still present in %s (no changes written)"
                      % _RELIC_BYTYPE_PROPERTY)
    except SystemExit:
        raise
    except Exception as e:
        _fail("post-write verify errored (no changes written): %s" % e)

    # ---- Atomic replace ----
    tmp_path = sav_path + ".tmp"
    try:
        with open(tmp_path, "wb") as f:
            f.write(new_sav)
        os.replace(tmp_path, sav_path)
    except Exception as e:
        try:
            if os.path.isfile(tmp_path):
                os.remove(tmp_path)
        except OSError:
            pass
        _fail("failed to write save file (original untouched): %s" % e)

    print(json.dumps({
        "ok": True,
        "removedTotal": total_removed,
        "results": results,
        "savePath": sav_path,
    }, separators=(",", ":")))


def main():
    # Two forms:
    #   python pal_save_writer.py <save_dir> delete-key  <player_guid> <property> <key>
    #   python pal_save_writer.py <save_dir> delete-keys <player_guid> <pairs_json_path>
    # delete-keys reads a JSON file {"keys":[{"property":..,"key":..}, ...]} (also accepts a bare
    # list, or a single {property,key} object) -- the batch path the dashboard uses so a
    # multi-select delete is one backup + one atomic write.
    if len(sys.argv) < 4:
        _fail("usage: pal_save_writer.py <save_dir> delete-key|delete-keys <player_guid> ...")
    save_dir, mode, guid = sys.argv[1], sys.argv[2], sys.argv[3]
    if not guid:
        _fail("player_guid is required")
    sav_path = os.path.join(save_dir, "Players", guid + ".sav")

    if mode == "delete-key":
        if len(sys.argv) < 6:
            _fail("usage: pal_save_writer.py <save_dir> delete-key <player_guid> <property> <key>")
        prop, key = sys.argv[4], sys.argv[5]
        delete_keys(sav_path, [{"property": prop, "key": key}])
        return

    if mode == "delete-keys":
        if len(sys.argv) < 5:
            _fail("usage: pal_save_writer.py <save_dir> delete-keys <player_guid> <pairs_json_path>")
        try:
            # utf-8-sig so a BOM the PowerShell caller may prepend (Set-Content -Encoding UTF8
            # writes one under PS 5.1) is stripped transparently; decodes BOM-less UTF-8 too.
            with open(sys.argv[4], encoding="utf-8-sig") as f:
                data = json.load(f)
        except Exception as e:
            _fail("could not read pairs json: %s" % e)
        if isinstance(data, dict):
            pairs = data.get("keys", data if "property" in data else [])
            if isinstance(pairs, dict):
                pairs = [pairs]
        else:
            pairs = data
        if not isinstance(pairs, list) or not pairs:
            _fail("pairs json contained no keys")
        delete_keys(sav_path, pairs)
        return

    _fail("unknown mode %r (expected delete-key or delete-keys)" % mode)


if __name__ == "__main__":
    main()
