# Identify organisms (on-device taxonomic identification)

*Experimental since commit round 208*

FaunaPulse detects and tracks insects live. **Identification** is a separate, later step:
the saved photos of every tracked visit are cut to crops, each crop is turned into an
"embedding" (a list of numbers describing its content) by the [BioCLIP 2][bioclip] image tower, and
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
   **Share results (CSV file)** hands the per-visit table to another app (the same file
   stays in the session folder under `identification/`, so it can also be copied over USB). The session summary's
   Photos tab then shows each visit's identification under its photos.

**Re-score with this pack** repeats only the last step (seconds): the stored embeddings are
compared against a different label pack, e.g. a country-restricted one, without running
the model again.

**What a re-run recomputes (round 213).** The model output for every crop is stored in
`embeddings_<model>.jsonl/.bin`, keyed by photo, track id and box. "Continue / re-run" runs
the model only on crops without a stored vector (new photos, or crops that a lower
"smallest box" setting now admits) and then re-scores everything, which is why a re-run
on an unchanged session takes seconds. Confidence and "no organism" thresholds, the CSV
rank, the merge settings and the suspect flags are all applied at scoring, so changing them
never re-runs the model. The **crop margin** is the exception: it changes what the model
saw, but the stored vectors do not know it; when the margin differs from the one the stored
crops were cut with, Start asks whether to keep the stored crops (fast) or recompute all of
them (a full run). "Smallest box" and "crops per visit" only add or remove crops.

**Aligning with the detection data in R or Python.** Both sides share the same keys: the
session id (folder name) and the track id (`track_id` in `tracks_<pack>.csv`, `track_id`
inside the `detections` records of `session.jsonl`), and, per crop, the photo file name
(`src` in `tracks_<pack>.json` and `predictions_<pack>.jsonl`, `jpeg` in the log's
detection records) together with the box coordinates. A merged visit lists all its ids in
`merged_track_ids`. So a join on `track_id` (or on file name for per-crop work) lines up
detections, photos and identifications without any extra bookkeeping.

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

The table (round 214) is sortable by tapping a column header, has the rank in its own
column and a rank filter (e.g. only rows that reached species), and a row opens its visits
as a numbered list (No. is the row number; Track id is the tracker's id, which can jump;
in "All track ids" the taxon's rank has its own column since round 222). A table wider than
the screen scrolls sideways under a slider; in that list only the table moves, the text
above it stays. A visit's detail sheet shows the ladder as an aligned table with the
reported rank highlighted and the taxa below it (suggestions) in grey, the photo of the
best single view with its full file name on its own line, the
detector box (yellow) and the square crop given to the model (cyan; toggle, zoom), and the
crops table (side in pixels, weight, own best guess and, since round 222, that species'
family, order and class in one column each; round 220 had them as one "Taxonomic tree"
column); tapping a crop shows that photo. Long column names over short values (e.g.
"Species conf.") wrap onto two lines, with room for the sort arrow. Since round 221 each flag is shown where it applies, as an amber ⚠ line whose ⓘ
gives the reason with the actual values: `merged`, `short`, `low_det` and `suspect` under
the header (the numbers behind `short` / `low_det` turn amber), `path_conflict`, `weak_id`,
`unidentified` and `no_organism` under the ladder (the affected rows carry ⚠; the
path_conflict line names the rival taxon and why the ladder skips it), `single_crop` above
the crops table. A small grey "Flags in tracks CSV" line at the bottom lists the flags as
written to the CSV, with a dictionary.

One identification belongs to one **visit** (track id), combining all of that visit's
photos; the Photos tab of the session summary shows it under every photo of that track id.
It is not a per-photo answer (the per-crop guesses are in `predictions_<pack>.jsonl`).

**Vocabulary (rounds 215–216).** A **track id** is one tracked organism, what a pollination
ecologist calls a visit; the app says "track id" because it also serves birds, mammals or
other organisms. **Conf.** is the model's confidence that a track id belongs to a *taxon*:
the probabilities of all species under that taxon added up (a genus = the sum of its
species, a family = the sum of its genera, and so on; BioCLIP itself only scores species
names, FaunaPulse does the adding). **Species conf.** is the probability of *one* species
for *one* crop, with no summing. **Med. Conf.** (the taxon table on the results screen) is the
median of Conf. across the row's track ids, rounded to whole percent; the list that opens
from the row states the same median above its table so it can be checked. All Conf. values
at one rank, plus the "none of these" entries, add up to 100 %.

The crops table names the taxon in its confidence column ("Conf. Hymenoptera"), because a
crop's confidence for the reported taxon sits in the same row as that crop's top species and
was read as the species' probability (owner, track #19 of session_2: Hymenoptera 90 % with
per-crop values of 95 %, 90 %, 97 % … next to species names). Tapping a ladder row changes
the taxon the column shows; the track id's Conf. for that taxon is that column averaged with
the Species conf. column as weights, spelled out as a worked example in the info texts.

**How a track id's Conf. is computed (round 219).** Each crop is classified on its own for
the tables: the model turns the crop into a vector, compares it with every species name it
was given (cosine similarity times the pack's logit scale, divided by the calibration
temperature), turns the similarities into probabilities with a softmax, and the
probabilities of the species under a taxon are added up (the crop's own Conf. for that
taxon, the "Conf. <taxon>" column of the crops table). The track id's answer is NOT an
average of those per-crop values. Instead the crops' vectors themselves are averaged, each
crop weighted by its own top-1 probability (its Species conf.), crops whose top-1
probability is below the surest crop's divided by a factor (default 10) left out, and the
average, deliberately not re-normalised, is classified once in the same way. Averaging
before the softmax is the "Average Logit" rule that Dussert et al. (2025) found best
calibrated for camera-trap image sequences (their "Average Score", the average of per-image
probabilities, was systematically underconfident, which is what FaunaPulse did in rounds
217 and 218). Consequences: photos that agree reinforce each other, so a track id's Conf.
can exceed every single photo's value; photos that disagree pull the average apart and lower
every Conf.; a photo the model is far less sure about than its best photo carries no usable
information and is left out (marked "left out" in the crops table). Every number can be
recomputed off the phone with `tool/bioclip_export/reproduce_track_conf.py` from the stored
embeddings and the label pack.

**Validation status (honest).** The rule and its defaults have NOT been tested on
pollinator data. Origins: averaging before the softmax = Dussert et al. 2025 (European
mammals, 22 classes, five models, three test sets; they flag hierarchical and very-many-class
settings as future work); the certainty weights and the drop factor 10 = FaunaPulse choices
(the unweighted rule flattens to nothing with 38 000 candidate names); the threshold 0.6 =
owner's choice (0.7 to 0.8 are common in ecological studies, Whytock et al. 2021, Dussert et
al. 2025); the calibration temperature 1.0 = no calibration (Dussert: fit one temperature on
a labelled test set and keep it; the pack format carries the field). The planned check is
the owner's expert-labelled smartphone crops (Zenodo 10.5281/zenodo.15096610): accuracy per
rank, a fitted temperature, and a comparison of pooling rules on track ids with three or
more crops. Until then, treat Conf. as a model score with a known direction of bias
(sharper than the per-crop average) rather than a calibrated probability.

Two more numbers accompany Conf.: **Agree** = how many crops, judged alone, put their top
species under the taxon, shown as a share (Agree, "50 %") and a count (Crops agree, "5/10";
one column each since round 222); and, in the files, the
plain mean (`p_mean_<rank>`), the best single crop (`p_max_<rank>`) and the mean over the
agreeing crops (`p_agree_<rank>`, so that insect-detect-post's weighted probability =
`agree_<rank>` × `p_agree_<rank>`) for every rank, so other pooling rules can be compared in
R without re-scoring.

Each track id gets a **ladder**: the taxon chosen at every rank on a consistent path from
kingdom to species, with its Conf. and Agree. The **identified rank** is the deepest rung
whose Conf. reaches the confidence threshold (default 0.6 since round 217); the headline is
that rung's taxon, or "unidentified" (no taxonomic rank reached the threshold, not even
kingdom; in a pack of animals only this means the "none of these" entries took a large share
but not more than the "No organism" threshold) or "no organism" (the "none of these" entries
took more than that threshold). Species names below the threshold are still shown, as
suggestions to verify. The **best single photo** is the crop whose own top species has the
highest Species conf., i.e. the photo the model is surest about on its own; the track id's
sheet names it, its species and confidence, the crop number and how many photos name the
same species, and opens the photo view on it.

Worked examples from the owner's phone (2026-09-22, computed with the rule used until
round 216; under round 219 track #19 reads Apidae 86 %, Bombus 54 %, B. impatiens 50 %,
track #10 B. impatiens 88 % from its one counted crop) that motivated this vocabulary: a
1.7-second track with four crops whose predicted species had Conf. 8 %, 5 %, 2 % and 3 %
(two of them spiders) was reported as Insecta with Conf. 83 %: the combined vector's
probability lies mostly on insect names, thousands of them, none individually likely; the
four Conf. values are single names from four different distributions and are not meant to
add up to anything. A 35-second bumblebee track with seven crops was Bombus at Conf. 99 %
while its best species row read *Bombus cingulatus* 13 %: the genus collects the mass of all
Bombus species (cingulatus 13 %, hypnorum, vestalis, ...), and the crops' own predicted
species (vestalis 30 %, cingulatus 17 %, dahlbomii 12 %, ...) are each that crop's single
best name.

**Why a short visit can have several photos and a long one only seven.** Time is the span
from the first to the last detector frame of the track id (the detector runs several frames
per second, so a 35-s visit had 152 frames). Photos are saved on the photo schedule, by
default one per second during the first 10 s of a visit, and every photo that another insect
triggered while this one was in view also yields a crop for it. So a 1.7-s track in a
crowded scene got four crops from other insects' photos, and a 35-s bumblebee got seven
photos in its first ten seconds and none afterwards. Both are as designed.

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
3. **Score each crop:** the vector is compared with every name in the pack (cosine
   similarity × the model's scale, softmax); species masses are summed up the taxonomy.
4. **Combine:** the crops' vectors are averaged, each crop weighted by its own top-1
   probability, crops below the surest crop's top-1 divided by the drop factor left out
   (round 219; no image-quality weights); the average is scored once and species masses
   summed up the taxonomy; the ladder is walked top-down on those pooled masses, and Agree
   is counted from the per-crop best guesses. A track id is `path_conflict` when at some rank the
   taxon with the most mass overall is not a child of the ladder's taxon one rank up: the
   chosen branch's mass is spread over several sub-taxa while another branch's smaller mass
   sits mostly in one (round 221: that rival is kept per ladder row and exported as
   `rival_*`; with `tau` >= 0.5 it can only happen below the reported rank). The unit-length average is
   also the vector the merge check compares.
5. **Export the alternatives:** per rank the plain mean (`p_mean_<rank>`), the best single
   crop (`p_max_<rank>`), the agreeing-crops mean (`p_agree_<rank>`) and the agreement share
   (`agree_<rank>`), plus every crop's own values and its `counted` flag in
   `crops_<pack>.csv`.

## Settings (Identify screen → Advanced)

See `SETTINGS_REFERENCE.md` → "Identification". Defaults come from the literature,
from BioCLIP's documentation and from the `insect-detect-post` pipeline; all are logged
in the `identify_start` record.
Settings are saved as you change them (round 210).

**GPU and CPU threads, honestly (round 211).** The GPU switch is real: it asks LiteRT to
compile the model for the phone's GPU, the same path the live detector uses (verified for
the YOLO detectors). For the BioCLIP image tower it has NOT been verified to work on any
phone: on the owner's Xiaomi the GPU compile fails and the app falls back to the CPU. Since
round 211 the reason is shown on the screen after loading (and in the "Last run" card)
instead of only in logcat. The thread count is passed to the CPU engine's (XNNPACK)
thread pool, so it does change how the matrix maths is spread; whether more threads are
faster on a given phone is an empirical question. **Test speed** (Run section) loads the
model with the current settings, embeds 8 of the session's own crops after a warm-up and
reports seconds per crop, so GPU on/off and thread counts can be compared in a minute
each; the app does not claim a speed it has not measured.

Two defaults worth knowing: **smallest box 48 px** because the model looks at every crop
at 224 px, so a smaller box is enlarged more than 4 times and is mostly blur; **crops per
visit 10** keeps a visit's ten LARGEST boxes when it has more photos (the photo count per
visit comes from the session's photo schedule: AI-mode default one photo per second for
10 s, so the cap rarely removes anything and only bounds the runtime of long bursts).

**Merge consecutive visits** (off by default, round 210): the tracker sometimes loses an
insect for a moment and gives it a new track id. When on, a track id that starts within
the set gap (default 3 s, the same as the live tracker's occlusion buffer; longer gaps risk
joining two individuals of one species, which the appearance check cannot tell apart) after the previous one ended is joined to it when three checks pass (round 212):
a compatible identification (same taxon at the shallower of the two identified ranks, e.g.
Apidae then Bombus); a similar appearance, i.e. the cosine similarity of the two visits'
combined image embeddings is at least the threshold (default 0.85; this is the strong
signal, "the model sees the same animal"); and a similar mean box side relative to the
ROI (default within 50 % of the larger one; a loose guard, 100 % disables it). Position
continuity is deliberately not used: within its buffer the tracker handles it, and after
a real loss the insect may re-enter the ROI anywhere. The union of the crops is then
identified again. Track ids that overlap in time are never joined (two insects at once
are two visits). The outputs carry `track_ids` (JSON) / `merged_track_ids` (CSV,
semicolon list), the `merged` flag, and the summary counts `visits_merged` and
`tracks_before_merge`.

**Suspect visits** (round 212, flags only): very short track ids are often false
detections, and a weak identification makes that more likely. A tracked visit is flagged
`short` when its duration is below 2 s OR it has fewer than 3 detector frames, `low_det`
when the mean detector confidence is below 0.2, `weak_id` when the probability at ORDER
rank is below 0.5, and `suspect` when it is short AND (low_det OR weak_id OR "no
organism"). All four thresholds are settings. Nothing is deleted: the results table hides
suspect visits behind a switch, the Photos tab marks them, and the CSV keeps every row
with `n_detections` and a 0/1 `suspect` column so the thresholds can be checked on your
own data in R. The duration and detector-confidence criteria follow the optional track
filter of the `insect-detect-post` software (Sittinger (2026), Software for post-processing of data captured with the Insect Detect camera trap, v1.0.0, Zenodo, doi:10.5281/zenodo.21822140; `metadata.filter_tracks`, defaults
`min_dur_s: 2`, `min_det_conf: 0.2`, adopted here on purpose so the two pipelines agree;
that software is the post-processing companion of the Insect Detect camera trap,
Sittinger et al. 2024, PLOS ONE 19(4): e0295474); the
identification-strength criterion and the AND rule are FaunaPulse additions. Bjerge et
al. (2022, Remote Sensing in Ecology and Conservation) instead removed stationary
detections repeating at the same position, which is a tracker-side idea for later.

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
for insect crops. The pooling of crops per track id follows the "Average Logit" rule of
Dussert et al. (2025, Remote Sensing in Ecology and Conservation 11:88-99) with FaunaPulse's
certainty weights, drop rule, ladder and agreement columns; Kittler et al. (1998, IEEE TPAMI
20:226-239) is the theoretical reason for averaging rather than multiplying evidence from
correlated views. The result differs from Sittinger's pipeline: in
insect-detect-post `pred_prob_weighted` is the mean probability of the images that voted
for the winning candidate times the share of images that voted for it, and
`pred_prob_mean` the mean over those voting images (`metadata_processor.py`); FaunaPulse
keeps the column names so the same scripts read both outputs, with its own formulas.

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


<!-- 
Reference links: [id]: URL
These are links used throughout this file
-->

[bioclip]: https://imageomics.github.io/bioclip-ecosystem/index.html