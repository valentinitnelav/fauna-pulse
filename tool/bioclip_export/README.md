# BioCLIP export tools: put BioCLIP 2 on the phone (PC side)

FaunaPulse's *Identify organisms* feature runs the BioCLIP 2 image tower on the phone.
The phone cannot read the original PyTorch checkpoint, so two files are prepared once
on a normal computer (no GPU needed) and copied to the phone:

| File | What it is | Size (BioCLIP 2) |
|---|---|---|
| `bioclip-2_image_fp16.tflite` | the image tower converted for the phone (fp16 weights) | 581 MiB |
| `<pack>.fpack` | a **label pack**: the names the model may choose from, their pre-computed embeddings, their taxonomy, plus six "none of these" entries (flower, leaf, shadow, debris, blurry, web) | 60 MiB for 32 flower-visitor families; up to ~430 MB for all Insecta + Arachnida |

Everything below was run end to end on 2026-09-20 (Ubuntu 24.04, Python 3.12, 15 GB RAM,
no GPU). Times and sizes are from that run.

## 0. What you need

- Python 3.11 or 3.12 (tested: 3.12.3). 3.13 is not yet supported by the converter.
- RAM: about 7 GB free during the conversion of BioCLIP 2 (BioCLIP 2.5 needs roughly twice).
- Disk: about 12 GB free in total: 4 GB for the Python packages (CPU build of PyTorch),
  1.7 GB for the BioCLIP 2 checkpoint, 2.8 GB for the TreeOfLife name embeddings (both
  downloaded once into `~/.cache/huggingface`), and 2 GB for the conversion outputs.
- Internet for the first run (Hugging Face downloads; no account or token needed).
- `adb` (Android platform tools) to copy files to the phone, or any USB file transfer.

## 1. Create the Python environment

```bash
cd fauna-pulse/tool/bioclip_export
python3 -m venv .venv
source .venv/bin/activate            # Windows: .venv\Scripts\activate
pip install --upgrade pip
pip install --extra-index-url https://download.pytorch.org/whl/cpu -r requirements.txt
```

The `--extra-index-url` makes pip take the CPU build of PyTorch (about 300 MB) instead
of the default CUDA build (about 3.5 GB); both give identical results here. To reproduce
the verified environment exactly, use the lock file instead:

```bash
pip install --extra-index-url https://download.pytorch.org/whl/cpu -r requirements-lock.txt
```

Note: `pip` keeps every downloaded wheel in its cache (`~/.cache/pip`, several GB after
this install). `pip cache purge` frees it once the install is done.

## 2. Export the image tower (about 2 minutes plus the download)

```bash
python export_image_tower.py --model bioclip-2 --precision fp16 --out ./out
```

What happens: the 1.7 GB checkpoint `imageomics/bioclip-2` is downloaded into the
Hugging Face cache (once); the image tower is wrapped so the phone can feed plain RGB
pixels in 0..1 (the colour normalisation and the final L2 normalisation are inside the
graph); `litert-torch` converts it to a float32 `.tflite` (1,216 MB, 74 s, about 7 GB
RAM); `ai-edge-quantizer` casts the weights to fp16 (609 MB, 6 s). Output:

```
out/bioclip-2_image_fp16.tflite   the model for the phone
out/bioclip-2_image_fp16.json     manifest: embedding size 768, input 224x224, logit scale 100, sha256
```

Options: `--precision int8` (dynamic-range int8, about 0.3 GB, for phones without a
usable GPU), `--precision fp32` (nothing cast, 1.2 GB; also runs on the phone),
`--keep-fp32` (keep the float32 intermediate, useful for `verify_parity.py`),
`--model bioclip-2.5` (ViT-H/14, 3.9 GB download, about 1.3 GB fp16, needs more RAM),
`--onnx` (additionally write an ONNX file).

Check the file before copying it anywhere:

```bash
python inspect_tflite.py out/bioclip-2_image_fp16.tflite
```

Expected: `FULLY_CONNECTED: {'fp16/int8 weights (dequantized)': 97}`, input
`serving_default_args_0 [1, 3, 224, 224]`, output `serving_default_output_0_output [1, 768]`.
If it says `weights computed at runtime (unfolded)`, the conversion ran in the
memory-saving mode (see Troubleshooting).

## 3. Build a label pack (about 5 minutes plus the download)

The first pack for a phone test: 32 families of common flower visitors of temperate
Europe (bees, wasps, hoverflies and other flies, ladybirds and other beetles,
butterflies, bugs, lacewings, scorpionflies, crab, orb and jumping spiders), 38,570
species, 60 MiB:

```bash
python build_label_pack.py --model bioclip-2 --pack-id bioclip2_flower_visitors_32fam_v1 --out ./out \
  --families Apidae,Halictidae,Andrenidae,Megachilidae,Colletidae,Vespidae,Syrphidae,Muscidae,Calliphoridae,Sarcophagidae,Bombyliidae,Empididae,Conopidae,Stratiomyidae,Tachinidae,Coccinellidae,Oedemeridae,Cantharidae,Pieridae,Nymphalidae,Lycaenidae,Hesperiidae,Papilionidae,Zygaenidae,Sphingidae,Pentatomidae,Miridae,Panorpidae,Chrysopidae,Thomisidae,Araneidae,Salticidae
```

What happens: the TreeOfLife-200M name embeddings (`txt_emb_species.npy`, 2.66 GB, plus
a 92 MB json with the taxonomy) are downloaded once into the Hugging Face cache; the
rows of the requested families are kept (867,455 species in total; Insecta 264,036,
Arachnida 16,406); the six "none of these" prompts are embedded with the BioCLIP text
tower; everything is written as one `.fpack` file (format documented in `fpack.py`).

### 3b. Regional packs (GBIF occurrence lists)

`build_region_species_list.py` writes the species of chosen orders that GBIF has at
least 3 records for in a region (a GBIF continent or a set of countries). Restricting
the candidates to a regional GBIF species list is what BioCLIP's documentation
recommends ("Geo-Restricted Taxon List Predictions"); the API-based way of getting that
list and the TreeOfLife-to-GBIF key mapping (downloaded on first use) follow Max
Sittinger's `insect-detect-post`. One GBIF request per order and region, about 10 to
60 s each, no account needed:

```bash
python build_region_species_list.py --continent EUROPE   --orders Diptera,Hymenoptera,Coleoptera,Lepidoptera --out out/species_europe_pollinator_orders.csv
python build_label_pack.py --model bioclip-2 --classes Insecta   --species-csv out/species_europe_pollinator_orders.csv --pack-id bioclip2_pollinator_orders_europe_v1 --out ./out
```

Countries instead of a continent: `--countries DE,AT,CH,CZ,PL` (union). Any CSV with a
`species` column of "Genus epithet" names works as `--species-csv`, so a user-supplied
taxon list is the same one-liner.

### 3c. Packs built so far (2026-09-20)

| Pack id | Selection | Names | Size | Runs in the app today |
|---|---|---|---|---|
| `bioclip2_flower_visitors_32fam_v1` | 32 flower-visitor families, worldwide | 38,570 | 60 MB | yes |
| `bioclip2_pollinator_orders_europe_v1` | Diptera, Hymenoptera, Coleoptera, Lepidoptera with GBIF records in Europe | 35,260 | 57 MB | yes |
| `bioclip2_mammalia_world_v1` | class Mammalia, worldwide, camera-trap sink prompts (`--sink-set mammal`) | 5,999 | 9.4 MB | yes (for MegaDetector "animal" boxes) |
| `bioclip2_pollinator_orders_world_v1` | the four orders, worldwide | 204,620 | 318 MB | not yet (needs the native scorer of a later app round) |

Every pack ends with six "none of these" rows; `--sink-set arthropod` (default) uses
flower-scene prompts, `--sink-set mammal` camera-trap prompts, `--no-sink` none.

Other selections:

```bash
# whole classes (large: ~280k names, ~430 MB; needs the native scorer)
python build_label_pack.py --model bioclip-2 --classes Insecta,Arachnida --out ./out
# whole orders
python build_label_pack.py --model bioclip-2 --orders Diptera,Hymenoptera --out ./out
```

Keep packs under about 100,000 names for the current app version: it scores them in
pure Dart (about 50 ms per crop per 30,000 names) and holds the matrix in memory
(4 bytes per number). Larger packs are built the same way and wait for the native
scorer.

## 4. Verify the export (recommended, about 3 minutes)

```bash
python verify_parity.py --tflite out/bioclip-2_image_fp16.tflite --images /path/to/some/crops \
  --pack out/bioclip2_flower_visitors_32fam_v1.fpack --limit 50
```

Compares the phone model with the original PyTorch model on your images: cosine
similarity of the embeddings and top-1 agreement at family and species level with the
pack. Expected `PARITY OK` with mean cosine >= 0.99 (measured: 1.0000 for fp16 and
fp32) and family agreement >= 95 % (measured: 100 %). Any folder of insect photos or
crops works (jpg/png, searched recursively).

## 5. Copy the files to the phone and import them

```bash
adb push out/bioclip-2_image_fp16.tflite /sdcard/Download/
adb push out/bioclip2_flower_visitors_32fam_v1.fpack /sdcard/Download/
```

(or copy them over USB / a file manager into the phone's Downloads folder). Then in
FaunaPulse: home screen, gear menu of a session, **Identify organisms**, *Import model…*
and *Import label pack…*. The app copies both files into its private storage; the
Downloads copies can be deleted afterwards. `docs/IDENTIFICATION.md` explains the run and
the results.

## Why the full model on the phone, and not a distilled one (for now)

Distillation (training a small "student" network / model to imitate the BioCLIP image tower - the "teacher")
was considered and is deliberately not used yet.

The reasoning:

- FaunaPulse is aimed to use identification **after** recording, in bulk, on a 
  plugged-in phone (e.g. overnight session). Speed is not the main goal there, accuracy is. 
  The "teacher" (the full BioCLIP 2 image tower, ~600 MiB fp16) is the accuracy ceiling
  and needs no training data.
- Published "students" lose fidelity, mostly at species level: 
  - the [BioCLIP 2.5 to FastViT-SA12 student][nate_distill] of Nate Hamilton (24 MB,
  label-free MobileCLIP-style recipe) agrees with its teacher on 71.7 % of top-1 and
  88.8 % of top-5 answers on plants; 
  - the "ConvNeXt-tiny+KD" student model of [Gardiner et al.][gardiner_2025]
  (ICCVW 2025, 101 moth species) reaches 64.7 % top-1 target accuracy with no 
  field labels against 88.3 % for BioCLIP 2 (Table 1 in manuscript), 
  and needs about 50% data mix with expert-labelled field data to catch up.
  Those authors recommend BioCLIP 2 itself when compute allows and labelled field data
  are scarce, which is mostly FaunaPulse situation (at least for now).

If it becomes a goal, the path is ready because the app is model-agnostic (any `.tflite` that maps
RGB to an embedding in a pack's space, declared in the manifest). So a student model
distilled from **BioCLIP 2** can be used (keeping the 768-dimension text space, so the packs stay
valid). The label-free recipe of [Nate Hamilton][nate_distill] (MIT; cache teacher
embeddings of insect images and of FaunaPulse's own crops, train a FastViT-class
student with a cosine loss) applies unchanged; export with
`export_image_tower.py` (timm models convert the same way) and check agreement with
the teacher on real crops with `verify_parity.py`.
Vasu et al. (2024) MobileCLIP, presents the distillation recipe.

A related, non-distillation idea worth keeping in mind
is a small insect-versus-background head trained on stored embeddings, as in
https://github.com/lollogiro/zero-shot-insect-detection (the app's "none of these"
rows are the zero-shot version of it).

References:

> Gardiner, R. J., Mougeot, G., Rowlands, S., Simmons, B. I., Helsing, F., & Høye, T. T. (2025, October). Bridging Domain Gaps for Fine-Grained Moth Classification Through Expert-Informed Adaptation and Foundation Model Priors. In 2025 IEEE/CVF International Conference on Computer Vision Workshops (ICCVW) (pp. 5169-5174). IEEE. https://doi.org/10.1109/ICCVW69036.2025.00538;

> Vasu, P. K. A., Pouransari, H., Faghri, F., Vemulapalli, R., & Tuzel, O. (2024, June). Mobileclip: Fast image-text models through multi-modal reinforced training. In 2024 IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR) (pp. 15963-15974). IEEE. https://doi.org/10.1109/CVPR52733.2024.01511

[nate_distill]: https://github.com/CrazedCoderNate/bioclip-mobile-distill
[gardiner_2025]: https://doi.org/10.1109/ICCVW69036.2025.00538

## Troubleshooting

- `ModuleNotFoundError: No module named 'tensorflow'`: an old copy of the script;
  the current one does not use TensorFlow (litert-torch 0.9+ plus ai-edge-quantizer).
- `TypeError: can only concatenate str (not "bytes") to str` inside ai-edge-quantizer:
  a text/bytes mismatch between ai-edge-quantizer 0.9.0 and flatbuffers 25.12. The
  script works around it (tensor names are normalised before the cast). If it still
  appears with newer versions, use `--precision fp32`.
- The fp16 file is larger than the float32 one, or `inspect_tflite.py` reports
  "weights computed at runtime": the conversion ran with `--lightweight`, which leaves
  the LayerNorm-scale products of 48 weight matrices unfolded. Delete the float32 file
  in `out/` and run again without `--lightweight`.
- Out of memory during conversion: close other programs (about 7 GB free RAM is needed
  for BioCLIP 2). `--lightweight` is the last resort (see the previous point).
- Disk: keep about 2 GB free during a run (float32 intermediate plus output).
  `pip cache purge` frees the wheels pip downloaded; the Hugging Face cache
  (`~/.cache/huggingface`) can be deleted after the export (it is re-downloaded on the
  next run).
- Slow PC inference in `verify_parity.py` (about 1 s per crop for fp16, 4 s for
  float32) is normal; it only affects the check, not the phone.

## Files in this folder

| File | Purpose |
|---|---|
| `export_image_tower.py` | checkpoint -> `.tflite` (+ manifest) |
| `build_label_pack.py` | TreeOfLife embeddings + filters + sink rows -> `.fpack` |
| `fpack.py` | the pack container format (also writes the app's test fixture) |
| `build_region_species_list.py` | GBIF occurrence facets + TreeOfLife-to-GBIF mapping -> regional species CSV |
| `verify_parity.py` | PyTorch vs `.tflite` comparison on real images |
| `inspect_tflite.py` | ops, constant sizes and weight layout of a `.tflite` |
| `requirements.txt`, `requirements-lock.txt` | packages (ranges / exact verified versions) |
| `catalog.example.json` | example of the download catalogue the app will read (model + pack entries with URL, size, sha256) |
| `out/`, `.venv/` | outputs and the environment (git-ignored) |

## Attribution of methods and data used here

Two sources are credited for different things; please keep both when citing.

**From BioCLIP / pybioclip (Imageomics; model MIT, embeddings CC0, code MIT):**
- zero-shot identification from a hierarchical taxonomic name list, and the
  TreeOfLife-200M name embeddings the packs are cut from (Stevens et al. 2024; Gu et al. 2025);
- the label-subset mechanism the packs implement (pybioclip's `--subset` /
  `create_taxa_filter` / `apply_filter` over precomputed name embeddings);
- the softmax with the model's logit scale and the roll-up of species probabilities to
  higher ranks (pybioclip's `predict` and `format_grouped_probs`);
- the recommendation to restrict candidates to a regional GBIF or Map of Life species
  list ("Geo-Restricted Taxon List Predictions", https://imageomics.github.io/pybioclip/geo-restricted-taxa/).

**From Max Sittinger's `insect-detect-post` (AGPL-3.0; Sittinger, M. 2026, Zenodo
https://doi.org/10.5281/zenodo.21822140), re-implemented in our own code:**
- the API-based way of building the regional list (GBIF occurrence facets, minimum 3
  records) and his TreeOfLife-to-GBIF key mapping (`tol_gbif_taxon_keys_Arthropoda.csv`,
  downloaded from his release, not redistributed);
- the per-visit CSV column names (`pred`, `pred_prob_weighted`, `pred_prob_mean`,
  `track_imgs`, `pred_imgs`, `bioclip_<rank>`) of his `_classified_final.csv`, so both
  tools' outputs can be analysed with the same scripts; the app's fusion rule itself
  differs (quality-weighted mean embedding, plan section 11.3);
- the square-on-the-longer-side crop rule (`make_bbox_square()`); FaunaPulse adds a
  margin and pads at photo edges instead of shifting the square.

**Precedent, not origin:** the "none of these" rows follow the common practice of
explicit background classes, as in the `none_*` classes of the Insect Detect
classification dataset (Sittinger, Uhler & Pink 2023, https://doi.org/10.5281/zenodo.8325384).

**Data:** GBIF occurrence facets and backbone taxonomy, https://www.gbif.org.

## Licenses and citation

Model weights: BioCLIP 2 by Imageomics, MIT. Name embeddings: TreeOfLife-200M,
CC0-1.0. 

Important note - the converted files are unofficial conversions, not provided or
endorsed by Imageomics.  

If you use these models, even if they were adapted for smartphone usage with FaunaPulse, 
please note the citation suggestions of the BioCLIP2 model card on Hugging Face at
https://huggingface.co/imageomics/bioclip-2#citation

See also `docs/THIRD_PARTY_MODELS.md`.
