# 05 - Data & assets (readers + scrapers)

This repo ships **code only** -- no game art and no scraped data tables. You regenerate them with
the included scripts. Nothing here is the game's binaries or save data.

## Save readers (parse the world save -> JSON)

Called by the dashboard with the world-save folder as the first argument
(`Pal\Saved\SaveGames\0\<WorldGUID>`):

| Script | Output |
|---|---|
| `pal_team_reader.py` | every captured Pal (species, IVs, moves, owner, location) + container `viewers` (used for per-player scoping on the public site) |
| `pal_egg_reader.py` | every real egg (storage / incubator / breeding farm / inventory) with its pre-rolled Pal + owner |
| `pal_save_reader.py` | per-player Pal capture counts (the Paldeck) |
| `save_health.py` | read-only save-bloat metrics |

These are heavy byte-scrapers of the save format -- **re-verify them after a PalWorld update**.

## Curated data tables (scraped)

These power the species detail popups, work/element chips, skill + passive popups, names, and the
effigy map. Regenerate them with:

```powershell
python .\gen_pal_names.py          # internal->display names (from palcalc db.json) -> pal_names.json
python .\gen_pal_assets.py         # Pal portrait PNGs + effigies.json (from palcalc + palworld-save-pal)
python .\gen_pal_icons.py          # work + element icons (paldb.cc) + procedurally-drawn passive chrome (needs Pillow) -> pal_icons\
python .\build_pal_species.py      # element/work/skills/base-stats per Pal (from paldb.cc) -> pal_species.json
python .\build_pal_skills.py       # active-skill power/cooldown/element/desc (paldb.cc) -> pal_skills.json
python .\build_pal_passives.py     # passive effect text + rating (paldb.cc) -> pal_passives.json
```

All of these are idempotent / re-runnable. The outputs are git-ignored (regenerated, third-party
derived).

### Regeneration order (bootstrap note)

`build_pal_species.py` needs the Pal list, which it reads from the generated `public\index.html`.
So the first time, run the dashboard once and generate the shell **before** the species scraper:

```
1. python gen_pal_names.py
2. python gen_pal_assets.py
3. & .\gen_public_site.ps1          # produces public\index.html (the Pal list)
4. python build_pal_species.py
5. python build_pal_skills.py
6. python build_pal_passives.py
```

(`build_pal_skills.py` / `build_pal_passives.py` scrape single paldb pages and don't need the
Pal list, so their order is flexible.)

## Icons (fully scripted)

`gen_pal_icons.py` fetches the work icons (`work_00`..`work_12`) and element icons
(`elem_00`..`elem_08`) from paldb.cc into `pal_icons\` (server-side, with the required
`Referer` header -- the CDN blocks hotlinking). The 9 passive-pill PNGs
(`passive_frame` / `passive_triangle` / `passive_pos_1-4` / `passive_neg_1-3`) are **drawn
procedurally** by the same script (`build_passives()`, needs Pillow) -- a beveled 9-slice frame,
a gray triangle-tessellation strip, and stacked chevron rank-arrows that the passive-pill CSS
tints at runtime. They are authored primitives, so no third-party art is committed. Everything in
`pal_icons\` is git-ignored (regenerated).

`gen_public_site.ps1` copies everything in `pal_icons\` into `public\icons\`; the dashboard
serves them from `/icons/`. No manual steps.

## Why "code only"?

Pal portraits are game-derived art (Pocketpair) and the data tables are third-party scrapes.
Rather than redistribute them, this repo ships the scripts so each user fetches them themselves,
keeping the repo small and clean. (The passive-pill chrome is no exception -- it's drawn from
scratch by `gen_pal_icons.py`, not extracted from anywhere.)

## Respect the source sites

The scrapers fetch from third-party services (paldb.cc, the palcalc db, palworld-save-pal) at
**your** discretion when you run them. Please respect each site's Terms of Service and rate limits:
run the scrapers sparingly (they're idempotent, so a one-time bootstrap is normally all you need),
and don't hammer them. The fetched data/art is the property of its respective owners and is not
redistributed by this repo.
