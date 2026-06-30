"""Report Palworld world-save bloat metrics as JSON (read-only; never writes saves).

Used by Maintenance-PalWorldServer.ps1 to log save health and warn on bloat.
Reports decompressed Level.sav size and the DynamicItemSaveData entry count - the
dominant source of save bloat (consumed eggs/items whose dynamic records are never
cleaned up). Most of these are orphaned: with no safe in-place cleaner for the 0.6
(PlM/Oodle) save format, this surfaces the trend instead of editing the save.

Usage: python save_health.py <world_dir>
  world_dir: folder containing Level.sav (e.g. .../SaveGames/0/<GUID>)
  Output:    one JSON object on stdout
"""
import sys, os, json, struct, re

# Reuse the proven decompressor from the existing reader.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pal_save_reader import decompress_save


def egg_item_count(raw):
    """Count PalEgg dynamic items (each carries an egg type + hatch species)."""
    pat = re.compile(
        rb"[\x0c-\x20]\x00\x00\x00PalEgg_[A-Za-z0-9_]+\x00\x00\x00\x00\x00.\x00\x00\x00"
        rb"[A-Za-z0-9_]+\x00\x05\x00\x00\x00None", re.S)
    return sum(1 for _ in pat.finditer(raw))


def main():
    world_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    level = os.path.join(world_dir, "Level.sav")
    out = {"worldDir": world_dir}
    try:
        out["levelDiskBytes"] = os.path.getsize(level)
        raw = decompress_save(level)
        out["levelDecompBytes"] = len(raw)
        out["eggItems"] = egg_item_count(raw)
        # Largest dimensional-pal-storage file (the other common bloat source).
        pdir = os.path.join(world_dir, "Players")
        dps = 0
        if os.path.isdir(pdir):
            for f in os.listdir(pdir):
                if f.endswith("_dps.sav"):
                    dps = max(dps, os.path.getsize(os.path.join(pdir, f)))
        out["maxDpsDiskBytes"] = dps
        out["ok"] = True
    except Exception as e:
        out["ok"] = False
        out["error"] = str(e)
    print(json.dumps(out, separators=(",", ":")))


if __name__ == "__main__":
    main()
