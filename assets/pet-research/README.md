# Kaddo desktop pet asset handoff

Checked 26 October 2026. Recommendation: start with Frakassets' orange cat at 32×32. It supplies idle, happy and sleeping body animations; thinking requires a runtime overlay or new artwork. The idle pose is upright, rather than seated. No candidate below supplies all four requested states unchanged.

## Sources and downloads

| Candidate | License | Grid / actual file layout | Download |
| --- | --- | --- | --- |
| [Frakassets Free Pets Pack](https://frakassets.itch.io/free-pets-pack) | CC BY 4.0; credit Frakassets and identify modifications | Selected cat: 32×32 cells; 384×512 PNG; 12 columns × 16 rows. Other supplied cell sizes: 16, 48, 64. | [Local original ZIP](downloads/free_pets_pack_frakassets.zip); [publisher download entry](https://frakassets.itch.io/free-pets-pack/purchase) |
| [LuizMelo Pet Cats Pack](https://luizmelo.itch.io/pet-cat-pack) | CC0; attribution optional | Cat-1 uses 50×50 cells, horizontal strips. Idle 500×50 (10 frames), Meow 200×50 (4), Sleeping1 and Sleeping2 each 50×50. | [Local original ZIP](downloads/luizmelo_pet_cats_pack.zip); [publisher download entry](https://luizmelo.itch.io/pet-cat-pack/purchase) |
| [Kenney Animal Pack](https://kenney.nl/assets/animal-pack) | CC0; attribution optional | Static heads, variable-size packed rectangles with XML coordinates. Atlases 1024×2048; e.g. square penguin PNG 256×256. No animation grid. Includes vector source files. | [Direct publisher ZIP](https://kenney.nl/media/pages/assets/animal-pack/480cf9f223-1677669996/kenney_animal-pack.zip); [local ZIP](downloads/kenney_animal-pack.zip) |
| [OpenGameArt Cute cat by limafresh](https://opengameart.org/content/cute-cat-32x32) | CC0 | Single 32×32 static image; drawing reference rather than an animation sheet. | [Direct PNG](https://opengameart.org/sites/default/files/cute_cat_0.png); [local PNG](downloads/oga_cute_cat.png) |

Itch.io generates file URLs through its download flow. The publisher links above are download entry pages, not permanent direct ZIP URLs. Original ZIPs are saved locally so the handoff has immediately usable downloads without expiring CDN links.

## Exact recommended animation mapping

Coordinates use the top-left origin and zero-based rows. These values are measured from the downloaded PNG and JSON, not inferred from a preview. Use `state-map.json` for frame rectangles and original per-frame durations.

| Workflow state | Source / row | Frames | Playback and required additions |
| --- | --- | ---: | --- |
| Idle / focusing | `Idle_South`, row 4, y=128 | 8 | Loop. Original timing is about 12 FPS; optionally slow after previewing. Upright idle with subtle motion. |
| Thinking | `Idle_South`, row 4, y=128 | 8 | Proposed adaptation: add three orbiting dots above the pet while local RAG inference is active. Overlay is a specification, not included artwork. |
| Celebrating / happy | `Happy_South`, row 0, y=0 | 6 | Play once on focus-timer or checklist completion, then restore the underlying idle/thinking state. |
| Sleeping | `Sleep_South`, row 8, y=256 | 12 | Loop for inactivity >600 seconds; optional separate Zzz text. System sleep suspends playback; update the state before suspend and restore on wake. |

Each row starts at x=0 and advances by 32 pixels. Happy uses columns 0–5, Idle 0–7, Sleep 0–11. Other cells in shorter rows are blank. Four directions occupy consecutive rows: South, East, North, West. Walk occupies rows 12–15. The source pivot is (16,27) in each 32×32 cell. Preserve that pivot and use nearest-neighbor scaling (e.g. 3× to 96×96 display pixels).

The selected image is `selected/frakassets/cat-orange_32px_scroller_outline_lit.png`; the adjacent JSON contains the original tags. `_shine`, `_shadow`, `_lines`, `_normal` and other variants remain available separately. The ZIP's README describes compositing. Use the lit sheet first; a desktop pet does not need an opaque scene background.

## Transparency verification

PNG pixels were decoded with Pillow. All 720 Frakassets PNGs, all 72 LuizMelo PNGs, and all 88 Kenney sprite/atlas PNGs have fully transparent pixels (alpha 0). Kenney's `Preview.png` and LuizMelo's `preview.png` are opaque previews and are excluded from usable sprites. The OGA cat is RGBA, 32×32, with alpha ranging from 0 to 255. The recommended cat also has alpha 0–255 and was visually inspected.

These are flattened PNGs with alpha, not editable multilayer PNG documents. Frakassets supplies separate aligned PNGs for optional effects and shadows. The selected files have no opaque rectangular background; naturally, the character's visible pixels are opaque or partially opaque.

`evidence/verification.json` records archive SHA-256 values and per-PNG dimensions, alpha extrema, and transparent-pixel counts. Publisher license files are preserved beside the selected assets. Original ZIPs are unchanged.

## CC0 fallback adaptation

LuizMelo Cat-1 supplies a seated pose and two static sleeping poses. Use Sitting with occasional Idle motion for focusing, Sitting plus orbiting dots for thinking, Meow plus a runtime hop/accent for celebration, and Sleeping1 with gentle breathing for sleeping. These additions are proposed runtime behavior, not supplied animation clips. The listed 20×14 cat size is artwork extent, not the 50×50 slicing grid.

Kenney and the OGA cat need new facial/pose animation artwork for the four states. They are useful open-license starting points, but are less complete than the animated packs.

## Attribution for the recommendation

Pet sprites by Frakassets — https://frakassets.itch.io/free-pets-pack — [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Identify Kaddo's changes if speed adjustments, overlays, recoloring, or other modifications are applied. The supplied license requires attribution; it is not CC0.
