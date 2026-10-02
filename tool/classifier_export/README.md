# Classifier export: insectDCT's hierarchical classifier on the phone (PC side)

**Status:** round 265 made and checked the phone files and timed them on the Xiaomi test
phone; since round 266 the Identify screen runs them (section 5). Recommended file:
`insectdct-cls-v7-eff2s_224_fp16.tflite` with its class list `insectdct-cls-v7-eff2s_224_fp16.fpack`
(section 3, *Which network*). Import both on the Download & import models screen (home screen ⋮ menu);
choosing the model on the Identify screen chooses its class list.

insectDCT's classifier V7 (Bjerge et al. 2026; `insectdct-cls-v7` in the
[InsectAI Model Zoo](https://github.com/InsectAI-COST-Action/insect-model-zoo)) names an insect
crop at three levels at once:

- level 1, 19 groups, e.g. `Hymenoptera_bees`, `Hymenoptera_nobees`, `Diptera`;
- level 2, 41 groups, mostly families;
- level 3, 104 classes: species, genera and coarser leftovers ("Coleoptera" = other beetles).

It is one network with three output layers ("heads"), one per level, trained on 224 x 224
camera-trap crops of flower visitors. The V7 download holds three versions of that network:
ConvNeXt-Base (the zoo's choice), EfficientNetV2-S and ResNet50, each with its own
per-class thresholds.

## 1. Environment

The `tool/bioclip_export` environment (converter and quantiser), plus pandas for
insectDCT's own code:

```bash
cd fauna-pulse/tool/bioclip_export && source .venv/bin/activate
pip install -r ../classifier_export/requirements.txt
cd ../classifier_export
```

Weights and insectDCT's code come from the InsectAI Model Zoo download: the folder
`insectdct-cls-v7/` holds `HierarchicalClassifierV7.zip` (unpacked into `unpacked/`) and
insectDCT's code in `upstream/common/`. That code (GPL-3.0) is used where it is, never copied
into this repository.

## 2. Export and check

```bash
python export_insectdct_cls.py --zoo-dir /path/to/weights/insectdct-cls-v7 --backbone cnb \
    --check-images ~/InsectDetectApp/test_videos/crops_bumblebees_720p_square
```

`--backbone cnb | eff2s | res` (ConvNeXt-Base, EfficientNetV2-S, ResNet50),
`--precision fp16` (default) `| fp32 | int8`. What happens:

1. insectDCT's own code builds the network and loads the V7 weights. (It would first download
   ImageNet starting weights that the V7 weights replace anyway; the script skips that
   download, like the zoo's wrapper does.)
2. The phone file `out/insectdct-cls-v7-<backbone>_224_fp16.tflite`: input one 224 x 224 RGB crop
   in 0..1 (insectDCT uses no further colour normalisation), output the 164 raw scores of the
   three heads one after the other (19 + 41 + 104). Converted with litert-torch; fp16 weights
   by `../bioclip_export/quantise_tflite.py`. A `.json` manifest lists the classes of every
   head, the source file and its sha256. Next to it the **class list**
   `insectdct-cls-v7-<backbone>_224_fp16.fpack` (round 266, 14 kB): the app's label pack for this
   model, without name vectors (the model scores its own classes). One row per level-3 class
   with kingdom ... species from the taxonomy table (section 4), its own name and its place
   in each head; `Vegetation` is the "none of these" row. Written by `fpack.write_class_list`
   (`tool/bioclip_export/fpack.py`); its size field is the model's output length (164), so the
   app refuses a wrong pairing. A corrected taxonomy table only needs a new class list
   (rerun the script; the phone file is reused) and *Re-score with this pack* on the phone.
   **GPU fixes.** Two of the plain conversions were refused by the Xiaomi's GPU. The script
   rewrites the two spots with the same arithmetic (the scores stay identical, difference 0.0
   in PyTorch on all 34 check crops); the same kind of rewrite made BioCLIP run on phone GPUs
   (`four_dim_attention`, round 242):
   - *ConvNeXt, last two layers:* the average over the 7 x 7 grid came out of the converter
     with a GATHER_ND step, which phone GPUs cannot run, so the GPU refused the whole file.
     Now: the mean over height and width, then a layer norm of the 1024 numbers. The file then
     compiles on the GPU, but see section 3.
   - *ResNet50, max pooling:* it pads with minus infinity (PADV2), which the GPU refused
     ("src has wrong size"). The pooling follows a ReLU (every value 0 or more), so padding
     with 0 gives the same maximum: zero padding, then pooling without padding.
3. With `--check-images`: every picture is classified by insectDCT's own decision code
   (`makePrediction`, called the way the zoo calls it) twice: with the original network, and
   with the phone file in its place. Same crop preparation, same per-class thresholds; only
   the network differs. Next to that, two candidate rules for FaunaPulse (section 5) on the
   phone file's scores. Two files of the same network should agree; this is not an accuracy
   test.

The taxonomy table (section 4) was drafted with
`--draft-taxa /path/to/txt_emb_bioclip-2.5-vith14.json` (the TreeOfLife names list that comes
with BioCLIP 2.5 in the zoo) and then checked by eye.

## 3. Results (round 265, 2026-10-01)

Check pictures: the 34 crops of `~/InsectDetectApp/test_videos/crops_bumblebees_720p_square`
(a YouTube clip; fit for "do the files agree" and timing, not for accuracy).

| Network | Phone file (fp16) | insectDCT's own answer, phone file vs original | FaunaPulse rule (section 5), phone file vs original | Largest score difference |
|---|---|---|---|---|
| ConvNeXt-Base (`cnb`) | 171 MiB | 34 of 34 identical | 34 of 34 same taxon | 0.008 |
| EfficientNetV2-S (`eff2s`) | 42 MiB | 34 of 34 identical | 34 of 34 same taxon | 0.03 |
| ResNet50 (`res`) | 51 MiB | 34 of 34 identical | 34 of 34 same taxon | 0.05 |

On the Xiaomi test phone (Xiaomi 11T Pro, Snapdragon 888, plugged in), with
`integration_test/bioclip_gpu_check_test.dart --dart-define=MODEL=insectdct-cls` (files copied
into the app's `files/identification/models/`; model time per crop after a warm-up, 6 crops;
the GPU is kept only when its result on a fixed test picture matches the CPU's, cosine 0.995
or more):

| Network | Phone GPU | Phone CPU (2 threads) | GPU vs CPU agreement |
|---|---|---|---|
| ConvNeXt-Base | not usable (wrong numbers, see below) | **0.7 s per crop** | 0.034 |
| EfficientNetV2-S | **0.02 s per crop** (load 1.5 s) | 0.13 s per crop | 0.9998 |
| ResNet50 | **0.02 s per crop** (load 2.1 s) | 0.17 s per crop | 0.99999 |

For comparison, BioCLIP 2 takes 0.27 s per crop on this phone's GPU and 2.6 s on its CPU,
BioCLIP 2.5 5.5 s on the CPU. All three insectDCT files pass the app's memory guard for the
GPU even on the 3.9 GB Samsung test phone (ConvNeXt needs about 0.8 GB to set up there).

- *ConvNeXt on the GPU:* after the GATHER_ND fix the file compiles on the GPU, but the GPU's
  scores have nothing to do with the CPU's (cosine 0.034 on the test picture), so the app's
  GPU check sends it to the CPU, as designed. The cause is not found. Not 16-bit overflow in
  its layer norms: on 12 check crops, values there reach about 200 (squared differences up
  to 42,000, below the 16-bit limit of 65,504), and dividing every layer norm's input by 32
  (exact, same scores) changed nothing on the phone. Finding it would take a layer-by-layer
  comparison on the phone. EfficientNetV2-S and ResNet50 run on the GPU with the same 104
  classes, about 35 times faster than ConvNeXt on the CPU, but they are different networks
  with their own answers (next point).
- The three networks often disagree with each other on this clip, mostly on unclear crops
  (several show plant parts or a blurred flower, not a clear insect). Which network names
  this project's pollinators best can only be decided on labelled crops (for example the
  owner's expert-labelled Zenodo crops), not here.
- With the "mean of 3 levels" rule (section 5), insectDCT's ConvNeXt file named the same
  taxon as insectDCT's own rule on 30 of the 31 crops that insectDCT's rule named (the 31st,
  *Bombus terrestris*, stopped at the genus *Bombus*), and gave an order or class (e.g.
  Hymenoptera, Insecta) on the 3 crops where insectDCT's rule said "Unsure". Using the
  level-3 head alone gave higher confidences (1.00 instead of 0.95 for *Bombus*) and an order
  where the mean rule stopped at class.

### Which network (round 266)

All three run with the same class list format; the authors' published test results decide
(insectDCT repository, `metrics/*V6_ClassScoresTest.csv`; version 6, the predecessor of V7
with 128 px crops, the newest with per-network results; F1 = the balance of precision and
recall, 1 = perfect):

| Network | Level 1 F1 (class average / all crops) | Level 2 | Level 3 | Phone |
|---|---|---|---|---|
| ConvNeXt-Base | 0.90 / 0.95 | 0.84 / 0.94 | 0.76 / 0.92 | CPU only, 0.7 s per crop |
| EfficientNetV2-S | 0.86 / 0.93 | 0.80 / 0.92 | 0.73 / 0.90 | GPU 0.02 s per crop |
| ResNet50 | 0.83 / 0.91 | 0.78 / 0.91 | 0.69 / 0.88 | GPU 0.02 s per crop |

EfficientNetV2-S is ahead of ResNet50 at every level and on 19 of 24 flower-visitor classes
compared (e.g. *Apis mellifera* 0.95 vs 0.92, `Apoidea small` 0.83 vs 0.79, Diptera at level 2
0.91 vs 0.87), and the insectDCT README calls it the "faster model, lesser accurate than
ConvNextBase". Both run equally fast on the Xiaomi's GPU, so EfficientNetV2-S is the
recommended file; ConvNeXt-Base remains the most accurate choice where 0.7 s per crop on the
CPU is acceptable (overnight runs).

In the app (round 266, Xiaomi, `bioclip_gpu_check_test.dart --dart-define=MODEL=insectdct-cls-v7_eff2s
--dart-define=SESSION=bumblebee-2`): the session's one track ID (3 crops) came out as *Bombus*
(genus) at 95 % on the GPU and on the CPU, own class `Bombus` 84 %; GPU and CPU scores agree
to cosine 0.9999; 0.02 s per crop on the GPU, 0.15 s on the CPU.

## 4. Taxonomy table: `taxa/insectdct-cls-v7.csv`

One row per level-3 class: the class, its level-2 and level-1 groups in insectDCT, then
kingdom ... species (epithet only, as in FaunaPulse label packs) and a note. The taxonomy
comes from the TreeOfLife names list BioCLIP uses, so BioCLIP and insectDCT answers share one
taxonomy; names that are not taxa come from a short hand-made list in the script (idea from
the zoo's conversion of insectDCT names for Camtrap DP):

- spelling: `Aranaea` -> Araneae, `Formidicidae` -> Formicidae, `Hesperidae` -> Hesperiidae,
  `Milipedes` -> Diplopoda;
- groups without a rank here end at the nearest rank above them: `Apoidea small`,
  `Apoidea striped`, ..., `Hymenoptera_bees` -> order Hymenoptera (bees; Apoidea is a
  superfamily), `Satyrinae_fw`, `Fritillaries` -> family Nymphalidae, `Moths` -> order
  Lepidoptera, `Larvae` -> class Insecta, `Herpetofauna` -> phylum Chordata,
  `Slugs`, `Snails` -> class Gastropoda;
- `Vegetation` -> not an organism (FaunaPulse's "no organism");
- classes with the suffix `_fw` (insectDCT keeps them apart) get their taxon's lineage;
- *Argynnis pandora* and *Lasiommata megera* are not in the TreeOfLife names (listed there
  under other names): kingdom to genus from their genus.

Where insectDCT's own levels differ from the taxonomy, the table follows the taxonomy:
*Iphiclides podalirius* and *Parnassius mnemosyne* are Papilionidae (insectDCT's level 2
files them under Pieridae). insectDCT's levels are still used for its own scoring (section 5);
only the names shown follow the table.

## 5. How it fits the app (design round 265, built round 266)

**Two kinds of identification models.** BioCLIP is an *embedding* model: it turns a crop into
numbers that the app compares with the names of a label pack, so any list of names works.
insectDCT is a *fixed-class* classifier: it gives one score per class it was trained on, and
its classes cannot change without new training.

**What the InsectAI Model Zoo harmonises.** Per box it writes one taxon, its rank and a score
(plus, for BioCLIP, the best name at each rank), and converts insectDCT's class names into
scientific names for Camtrap DP. Each model keeps its own rule, per picture. It does not put
the three levels into one taxonomy, nor combine the crops of one track ID. FaunaPulse's
results already hold more (a name and a probability at every rank, per track ID), so
FaunaPulse keeps its own form and borrows the zoo's name conversion (section 4).

**How it works** (files: `label_pack.dart` class lists, `track_fusion.dart` scoring,
`identification_store.dart` outputs, `Embedder.kt` raw output, `identification_screen.dart`
pairing; tests share the fixture `test/fauna_pulse/fixtures/tiny_classes.fpack` written by
`fpack.py`, so the app and `fpack.class_probabilities` compute the same numbers).

1. *A class list in place of a label pack.* The same `.fpack` file type, without name
   vectors: one row per level-3 class with kingdom ... species from the table, the model's
   own class name, and its place in each head; `Vegetation` as a "none of these" row. The
   export script writes it from the table. It is named like the model file
   (`insectdct-cls-v7-eff2s_224_fp16.fpack` next to the `.tflite`), so choosing the model on the
   Identify screen chooses it. Before a run the screen refuses a class list of another model,
   and after loading the model it compares the pack's size field (the model's output length,
   164) with the model's. The app stores each crop's raw scores, so a corrected table only
   needs a new class list and *Re-score with this pack*, not a new run.
2. *Raw scores.* The phone code scales BioCLIP's output to length 1; a classifier is loaded
   with `normalize: false` and its scores are used as they are. The GPU check now compares
   GPU and CPU with the vectors' lengths, so it works for both.
3. *One probability per class ("mean of 3 levels").* Each head's scores become
   probabilities; a level-3 class scores the mean of the log-probabilities of itself, its
   level-2 group and its level-1 group, so it only scores high when the three levels agree,
   and three heads do not count as three independent votes. The 104 scores then go through
   one more softmax. (Alternative checked above: the level-3 head alone.)
4. *Everything after that is the existing pipeline, unchanged:* probabilities rolled up
   through the taxonomy (a family's mass = the sum of its classes), the crops of a track ID
   combined by the certainty-weighted average of their scores (the "Average Logit" rule
   already used for BioCLIP, Dussert et al. 2025), the ladder from kingdom to species, the
   identified rank (deepest rank with at least 0.6), "no organism" when Vegetation wins, the
   per-taxon table and every file. Classes coarser than species simply end the ladder
   earlier: `Bombus` adds to the genus *Bombus*, `Coleoptera` to the order, `Apoidea small`
   to the order Hymenoptera.
5. *The model's own class beside the taxonomy:* per track ID its most probable own class
   (`model_class` in the files, *Model's own class* on the track ID's sheet; per crop
   `top1_class`), because some of its distinctions have no rank here (`Apoidea small` = a bee,
   not just Hymenoptera).
6. *Not built:* insectDCT's own answer per crop (its per-class thresholds) as an extra
   column, so results could be compared with the zoo and the paper.

**Several models on one session.** The app already keeps results per model and per label
pack (`embeddings_<model>`, `tracks_<pack>`, `summary_<pack>`), so one session can be
identified with BioCLIP 2, BioCLIP 2.5 and insectDCT one after another without losing
anything. The results screen opens only the newest results, so a chooser (or a side-by-side
view) is needed to compare them. ISIR or Camtrap DP export (the zoo's formats) would be a
later step.

**What a future classifier needs.** (a) A `.tflite`: one RGB crop in 0..1 in (its own colour
normalisation inside the file), the raw scores of all its heads one after another out; (b) a
taxonomy table like section 4; (c) for a hierarchical model, the parent group of each finest
class at every level. A flat classifier is the case with one head.

**Before relying on it:** check the rule and the 0.6 threshold on labelled crops (a fixed-class
model's probabilities are scaled differently from BioCLIP's, so the threshold may need its own
value), and check that the app's crop preparation matches insectDCT's (it pads crops at the
photo edge with black, FaunaPulse with a grey; the resize methods differ slightly).

## Files

| File | Purpose |
|---|---|
| `export_insectdct_cls.py` | `.pth` -> `.tflite` + manifest + class list (`.fpack`); check against insectDCT's own code; `--draft-taxa` |
| `taxa/insectdct-cls-v7.csv` | level-3 class -> kingdom ... species (drafted by the script, checked by eye) |
| `requirements.txt` | pandas on top of the `tool/bioclip_export` environment |
| `out/` | outputs (git-ignored) |

## Licences

insectDCT (code and weights): GPL-3.0. Bjerge, Wogram, Serra-Marin, Sakhiashvili & Høye
(2026). InsectDCT: A generalized pipeline for detection, taxonomic classification, and
tracking of insects in camera-trap recordings. bioRxiv.
https://doi.org/10.64898/2026.07.07.736939, code https://github.com/kimbjerge/insectDCT.
Converted files are unofficial conversions, not provided or endorsed by the authors; check the
licence before sharing them. Packaging and download: the InsectAI Model Zoo (Markoff and
InsectAI COST Action CA22129 contributors, 2026). TreeOfLife names: Imageomics (BioCLIP 2.5).
