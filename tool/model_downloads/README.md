# Model downloads: the list of every model the app knows (rounds 268, 276)

No model ships inside FaunaPulse. The **Download & import models** screen (home screen: Menu, bottom left) offers the
models listed in [`assets/model_downloads.json`](../../assets/model_downloads.json): a title,
one plain line on what each model is for, the size and the licence. One tap downloads a
detection model, or an identification model together with the name list chosen (a label pack
for BioCLIP, the class list for insectDCT). A model already on the phone is not downloaded
again: two BioCLIP name lists share one model.

Since round 276 the same file lists **every model the project knows**, also those not offered
for download (other input sizes, other networks). The (i) card of a file on the phone shows
its entry: what the model is for, its licence and its source. A file finds its
entry by its name (see the naming rule below); a file that is not in the list shows "not
known".

## Naming rule (round 276)

`<model>_<input px>_<precision>[_<extra>].<ext>`, for example `flatbug-n_640_fp16.tflite`,
`mdv6-yolov10c_256_int8.tflite`, `insectdct-cls-v7-eff2s_224_fp16.tflite`.

- Lower case. "-" joins words inside a part, "_" separates the parts. A dot only inside a
  version number (`bioclip-2.5`).
- `<model>` names one trained set of weights and is unique. It is the entry's `id` in the
  list, so every export of the same weights (other sizes, other precision) finds the same
  details: the part of the file name before its first "_".
- `<input px>`: the picture size the model takes (224, 256, 320, 640, 1024).
- `<precision>`: `int8`, `w8a32` (int8 weights, float activations), `fp16` or `fp32`.
- `<extra>`: only when two exports would otherwise get the same name, for example `e2e`
  (end-to-end output) or `5d` (the old BioCLIP export that phone GPUs cannot run).
- Name lists: a **class list** has exactly its classifier's name (`.fpack`); a **label pack**
  is `<model>_<list>_v<n>.fpack`, for example `bioclip-2_flower-visitors-32fam_v1.fpack`.
  A label pack belongs to every model file with the same first part.
- About 40 characters at most (without the extension).

The export tools write names by this rule (`tool/detector_export`, `tool/classifier_export`,
`tool/bioclip_export`). To check names: `python update_catalogue.py --names <files…>` lists
the files that do not follow the rule, or whose `<model>` is not an `id` in the list.

The app compares the `<model>` part loosely (upper and lower case, "-" and "." alike), so files
named before the rule (`MDV6-yolov10-c_int8_320.tflite`, `bioclip-25_image_fp16.tflite`) still
find their entry.

## Why separate files, not one zip per model

Model weights barely compress, unpacking a zip needs twice the space for a moment (2.5 GB for
BioCLIP 2.5) and a zip per name list would repeat the shared BioCLIP model. So every file is
a separate download, grouped by the catalogue, the way model hubs such as Hugging Face keep
models (separate files plus a list of what belongs together).

## Words (one name per thing)

| Word on the screens | In this list (`kind`) | File | What it is |
|---|---|---|---|
| detection model | `detection_model` | `.tflite`, `*_qnn.onnx` | finds animals and draws a box around each one |
| identification model | `identification_model` | `.tflite` | names what is inside each box, choosing from a name list |
| name list | (an entry of `name_lists`) | `.fpack` | the names an identification model chooses from; one of the two kinds below |
| class list | `class_list` | `.fpack`, same name as its classifier | the fixed classes of a classifier (insectDCT) |
| label pack | `label_pack` | `.fpack`, `<model>_<list>_v<n>` | names with their embeddings, for BioCLIP |

`.fpack` stands for **FaunaPulse pack**, the file format of both kinds of name list
(`tool/bioclip_export/fpack.py`); its header says `"kind": "class_list"` or `"label_pack"`
(files written before round 276: `"classes"`, or nothing for a label pack; the app reads both).
In the code, "pack" means such a file of either kind.

## The list file (format 3)

- `base_url`: where the files are; a file's link is `base_url` + its name. A file can carry
  its own `"url"` instead (for example a Hugging Face link, or a file in another release).
- `models`: one entry per model, with `id` (the `<model>` part of its file names, unique),
  `kind` (`detection_model` or `identification_model`), `title`, `purpose`, optional `note`,
  `licence` and `source` (the authors' page: a repository or a Hugging Face page).
  No citation field (round 277, owner): a citation changes (a preprint becomes a journal
  paper) and the authors keep theirs up to date on that page. The screen asks users to cite
  the original model from there.
- `file` (optional): the file offered for download. An entry without it is known but not
  offered (its files on the phone still show its details).
- `name_lists` (identification models): each with `kind` (`class_list` or `label_pack`),
  `title` and `file`, and its own `licence` and `source` when the names come from elsewhere
  (the TreeOfLife embeddings, CC0).
- `bytes` and `sha256`: the app shows the size and checks every download against the
  checksum. A file on the phone counts as present by its **name** only, so re-exported
  weights on the phone are not flagged.
- `uses` (round 278): the answers to the home screen's *What do you want to watch?*, in the
  order of the tiles. Each has `id`, `icon` (which drawing the tile shows: `pollinators`,
  `flat_surface`, `mammals_birds`; `widgets/watch_tiles.dart`), `title`, `setup` (one sentence
  on where to put the phone), `find` (the `id`s of the suggested detection models, the best
  first) and `name` (the suggested identification models, each `{"model": id, "list": file
  name}`; a classifier with one class list may leave out `list`). The first of `find` and of
  `name` are chosen for the user (round 279: "Chosen for you"; the others wait under *Choose
  other models*). The page shows the drawing `assets/images/setup_<icon>.png` when there is one
  (the side view and the phone screen with the yellow square; the round icon otherwise), and
  the home screen's step 2 shows `assets/images/roi_<icon>.png` (that phone screen alone) for
  the answer chosen last.
  Only offered entries count;
  a suggestion that names a model that is not offered, or a list it does not have, is left out
  (logged), and an answer with no detection model left is skipped. Change the suggestions here,
  without new code.

## When weights change

1. Re-export, then refresh the sizes and checksums from the local files:
   `python tool/model_downloads/update_catalogue.py <files…>` (`--check` only reports).
2. Upload the files as GitHub release assets under exactly the names in the catalogue.
3. Do not replace a published file under the same link: app versions already installed would
   reject the new file (its checksum differs from the one they carry). Upload changed weights
   under a new file name or a new release tag and change the catalogue (`base_url`, or the
   file's own `"url"`), so old and new app versions both keep working.

## Files offered since round 268 (release `v0.8.0-alpha.1`, names from before the naming rule)

| Catalogue name | Local file to upload |
|---|---|
| `MDV6-yolov10-c_int8_256.tflite` | `assets/models/custom/` (already uploaded) |
| `flatbug-n_640_fp16.tflite` | `tool/detector_export/out/` |
| `insectdct-v8-s_640_fp16.tflite` | `tool/detector_export/out/` |
| `insectdct-cls-v7_eff2s_fp16.tflite`, `.fpack` | `tool/classifier_export/out/` |
| `bioclip-2_image_fp16_4d.tflite` | `tool/bioclip_export/out/gpu4d/bioclip-2_image_fp16.tflite` (**rename**: the GPU export) |
| `bioclip2_pollinator_orders_europe_v1.fpack`, `bioclip2_flower_visitors_32fam_v1.fpack` | `tool/bioclip_export/out/` |
| `bioclip-25_image_fp16.tflite`, `bioclip25_*_v1.fpack` | `tool/bioclip_export/out/bioclip25/` |
| `bioclip-2_mammals-birds-world_v1.fpack` (round 278, named by the rule) | `tool/bioclip_export/out/` |

On 2026-10-02 only the MegaDetector file was online; the others answer "not found" (HTTP 404),
which the app shows in plain words, until they are uploaded.

GitHub release assets may be up to 2 GiB each; BioCLIP 2.5 (1.27 GB) fits. The licences are in
`docs/THIRD_PARTY_MODELS.md`.
