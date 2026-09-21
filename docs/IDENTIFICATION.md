# Identify organisms (on-device taxonomic identification)

*Experimental since round 208. For field users who want a taxon per visit, and for
collaborators who prepare the model files.*

FaunaPulse detects and tracks insects live. **Identification** is a separate, later step:
the saved photos of every tracked visit are cut to crops, each crop is turned into an
"embedding" (a list of numbers describing its content) by the BioCLIP image tower, and
the crops of one track id are combined into one answer with a confidence per taxonomic
rank (order, family, genus, species). Everything runs on the phone; nothing is uploaded.
It is meant for bulk processing after a day of recording, with the phone plugged in.

Background and design: `BIOCLIP_ON_DEVICE_PLAN.md` (owner's notes, outside this repo).

## What you need

| File | What it is | Size | Made with |
|---|---|---|---|
| `bioclip2_image_fp16.tflite` | the BioCLIP 2 image tower, converted for the phone | ~0.6 GB (fp16), ~0.3 GB (int8) | `tool/bioclip_export/export_image_tower.py` |
| `<pack>.fpack` | a **label pack**: the names the model may choose from, their embeddings, their taxonomy, plus "none of these" entries (flower, leaf, shadow, …) | tens of MB (a list of families) to ~430 MB (all Insecta + Arachnida; slow to score in this version) | `tool/bioclip_export/build_label_pack.py` |

Both are built once on a PC (`tool/bioclip_export/README.md` has the commands; a
normal laptop without GPU is fine) and copied to the phone (USB, or `adb push … /sdcard/Download/`).
In the app: session gear menu → **Identify organisms** → *Import model…* / *Import label pack…*.
The files are copied into private app storage (Android/data is not used), so the copies in
Downloads can be deleted afterwards.

Model weights: BioCLIP 2 by Imageomics (MIT). Name embeddings: TreeOfLife-200M (CC0).
Please cite Gu et al. (2025), *BioCLIP 2: Emergent Properties from Scaling Hierarchical
Contrastive Learning*, NeurIPS, when publishing results (see `THIRD_PARTY_MODELS.md`).

## Running it

1. Open a session's gear menu (home screen) or its summary → Photos tab → **Identify organisms**.
2. Pick the model and the label pack. The screen shows how many crops will be processed
   (one per photo per tracked insect, capped per visit) and, after the first run on this
   phone, a time estimate.
3. Plug the phone in and tap **Start**. Progress shows crops done, elapsed time, the
   estimated remainder and the battery temperature. The run pauses by itself above the
   temperature limit (default 40 °C) and resumes 3 °C lower. **Cancel** keeps everything
   done so far; **Continue** resumes where it stopped (the files are append-only).
4. When finished, **View results** shows a table with one row per taxon (visits, total
   time, median confidence); tap a row for its visits and a visit for its full ladder.
   **Share CSV** hands the per-visit table to another app. The session summary's
   Photos tab then shows each visit's identification under its photos.

**Re-score with this pack** repeats only the last step (seconds): the stored embeddings are
compared against a different label pack, e.g. a country-restricted one, without running
the model again.

No-AI sessions (motion / time-lapse) have no track ids. Run "Run AI on photos" first; the
post-hoc boxes are then identified one by one (no per-visit combination).

## Reading the results

The results screen aggregates per taxon. **As identified** (default) makes one row per
answer at the rank the model was sure about: visits identified only to the genus *Bombus*
are one row, visits identified to *Bombus terrestris* another. Choosing **Order**,
**Family**, **Genus** or **Species** counts every visit under its taxon at that rank; visits
the model did not resolve that deep land in a "not resolved to ..." row. *Time* adds up the
visits' durations, *Conf.* is the median confidence of the row's visits. The same numbers
can be reproduced from `tracks_<pack>.csv` (`bioclip_<rank>` / `p_<rank>` columns).

One identification belongs to one **visit** (track id), combining all of that visit's
photos; the Photos tab of the session summary shows it under every photo of that track id.
It is not a per-photo answer (the per-crop guesses are in `predictions_<pack>.jsonl`).

Each visit gets a **ladder**: the taxon chosen at every rank on a consistent path from
kingdom to species, with the model's probability mass for it and the share of crops
whose own best guess agrees. The **identified rank** is the deepest rung whose mass reaches
the confidence threshold (default 0.8); the headline is that rung's taxon, or
"unidentified" (not even the class is sure) or "no organism" (the "none of these" entries
won). Species names below the threshold are still shown, as suggestions to verify.

The percentages are *model confidence*, not measured accuracy: a calibration
temperature can be fitted later on labelled crops and stored in the label pack. Until
then, treat 90 % at family rank as "very likely" and species-level answers as leads.

## Files (in `<session>/identification/`)

| File | Content |
|---|---|
| `embeddings_<model>.jsonl` + `.bin` | one record + one float32 vector per crop (`row` = vector index); `identify_start` / `identify_end` records with the run's settings and timing |
| `predictions_<pack>.jsonl` | per crop: the most probable names with probabilities |
| `tracks_<pack>.json` | per visit: ladder, crops with weights, best single view, flags |
| `tracks_<pack>.csv` | one row per visit; the column dictionary is in `README_identification.txt` next to it; the first columns match the `_final.csv` of Max Sittinger's `insect-detect-post` |
| `summary_<pack>.json` | counts for the results screen and the home badge |

`DATA_GUIDE.md` §7 documents the records and columns.

## How the answer is computed (plain language)

1. **Crop:** a square on the box's longer side plus a 15 % margin per side, padded with a
   neutral colour where it leaves the photo, resized to the model input (224 px). Boxes
   under 48 px are skipped as too small. For high-res photos the in-sync `_live.jpg`
   companion is used (the logged boxes were observed on that frame).
2. **Embed:** the model turns each crop into a unit vector. Stored, so re-scoring is free.
3. **Combine:** the vectors of one track id are averaged with quality weights (larger,
   sharper, more confidently detected, less padded crops count more) and re-normalised.
4. **Score:** the average is compared with every name in the pack (cosine similarity ×
   the model's scale, softmax), species masses are summed up the taxonomy, the ladder is
   walked top-down, and support is counted from the per-crop best guesses.
5. **Cross-check:** the weighted mean of the per-crop probabilities must agree at the
   chosen rank; if not, the visit is flagged `rule_conflict`. A visit is `path_conflict`
   when the best taxon at some rank is not a child of the best taxon above it.

## Settings (Identify screen → Advanced)

See `SETTINGS_REFERENCE.md` → "Identification". Defaults come from the literature,
from BioCLIP's documentation and from the `insect-detect-post` pipeline; all are logged
in the `identify_start` record.

## Attribution

From BioCLIP and pybioclip (Imageomics): the model and the TreeOfLife-200M name
embeddings, zero-shot identification from hierarchical taxonomic names, the label-subset
mechanism the packs implement (`--subset` / `apply_filter`), the softmax with the
model's logit scale, the roll-up of species probabilities to higher ranks, and the
recommendation to restrict candidates to a regional GBIF species list ("Geo-Restricted
Taxon List Predictions" in the pybioclip docs). Cite Stevens et al. (2024) and Gu et al.
(2025), see `THIRD_PARTY_MODELS.md`.

From Max Sittinger's `insect-detect-post` (AGPL-3.0; Sittinger, M. 2026, Zenodo
https://doi.org/10.5281/zenodo.21822140), re-implemented in FaunaPulse's own code with
no lines copied: the API-based construction of the regional list (GBIF occurrence
facets) and his TreeOfLife-to-GBIF key mapping, the per-visit CSV column names of his
`_classified_final.csv`, and the square-crop rule of his `make_bbox_square()`. The
"none of these" rows follow common practice, with the `none_*` classes of his
classification dataset (Zenodo https://doi.org/10.5281/zenodo.8325384) as the precedent
for insect crops. The combination of crops per visit (quality-weighted mean embedding,
ladder, support) is FaunaPulse's own.

## Troubleshooting

- *"Could not compile on GPU / falling back to CPU"* in logcat: normal for some phones;
  the CPU path is slower but gives the same numbers. The int8 export is the CPU-friendly
  variant.
- *The model load fails outright:* the phone has too little free RAM for the file (fp16
  needs ~1 GB free, BioCLIP 2.5 ~2 GB) or the export is broken; run `verify_parity.py`
  on the PC.
- *Every visit comes out "no organism":* the pack has no rows for the animals in the
  photos (e.g. an orders-only test pack); build a wider pack.
- *Everything is "unidentified":* the confidence threshold is high for this pack size;
  lower it in Advanced, or check the crops (very small boxes give weak embeddings).
- Scoring a large pack (> 100 k names) takes a while per crop in this version; use a
  country or order-restricted pack for speed.
