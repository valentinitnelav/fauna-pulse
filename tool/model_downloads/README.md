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
`mdv6-yolov10c_256_w8a32.tflite`, `insectdct-cls-v7-eff2s_224_fp16.tflite`.

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

The export tools write names by this rule (`detector_export`, `classifier_export`,
`bioclip_export` of [fauna-pulse-models](https://github.com/valentinitnelav/fauna-pulse-models)). To check names: `python update_catalogue.py --names <files…>` lists
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
(`bioclip_export/fpack.py` of fauna-pulse-models); its header says `"kind": "class_list"` or `"label_pack"`
(files written before round 276: `"classes"`, or nothing for a label pack; the app reads both).
In the code, "pack" means such a file of either kind.

## The list file (format 3)

- `base_url`: a file without its own `"url"` is at `base_url` + its name. Today every offered
  file carries its own `"url"` (a Hugging Face link pinned to one upload), so no file uses it.
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
  on where to put the phone), `find` (the `id`s of the suggested detection models, in the order
  to suggest them) and `name` (the suggested identification models, each `{"model": id, "list": file
  name}`; a classifier with one class list may leave out `list`). The first of `find` and of
  `name` are the page's *Suggested AI models* (the others wait under *Choose other models*; the
  page of the answer used last opens with the models in use instead). For naming, BioCLIP 2
  with the name list that fits the answer comes first in every answer. The page shows the drawing `assets/images/setup_<icon>.png` when there is one
  (the side view and the phone screen with the yellow square; the round icon otherwise), and
  the home screen's step 2 shows `assets/images/roi_<icon>.png` (that phone screen alone) for
  the answer chosen last. A model needs an entry here only to be offered for download or
  suggested: every model already on the phone (imported, such as one's own trained detector, or
  suggested for another answer) is listed on these pages under *Other models on this phone*
  (round 281), its details read from the file itself.
  Only offered entries count;
  a suggestion that names a model that is not offered, or a list it does not have, is left out
  (logged), and an answer with no detection model left is skipped. Change the suggestions here,
  without new code.

## When weights change

1. Re-export, then refresh the sizes and checksums from the local files:
   `python tool/model_downloads/update_catalogue.py <files…>` (`--check` only reports).
2. Publish the files on Hugging Face with `publish/publish_hf.py` of fauna-pulse-models
   (it checks them against this list first), then take the published names and the links
   pinned to the upload commit (`https://huggingface.co/<owner>/<repo>/resolve/<commit>/<file>`)
   into the list (round 312):
   `python tool/model_downloads/update_catalogue.py --urls ~/fauna-pulse-models/publish/published.json`
   (`--check` only reports). Files are matched by SHA-256, so a file published under a new
   name keeps its entry; the command lists the old names that tests and docs still use.
3. Never replace a published file: app versions already installed carry its link and its
   checksum. Publish changed weights under a new file name (the model cards say so too) and
   run `--urls` again, so old and new app versions both keep working.

## Where the files are (round 314)

The offered files are on Hugging Face, one repository per model family on
https://huggingface.co/Valen-Peregrine (`mdv6-tflite`, `flatbug-tflite`, `insectdct-v8-tflite`,
`insectdct-cls-v7-tflite`, `bioclip-2-tflite`, `bioclip-2.5-tflite`). Each repository has a
model card (where the weights come from, licence, how the file was converted, how to cite the
original model) and the licence text of the original model (`LICENSE`). The collection
https://huggingface.co/collections/Valen-Peregrine/faunapulse links them all; the cards' sources are in `hf_cards/` of
fauna-pulse-models.
The links in the list are pinned to the upload commit and were taken with `--urls` (step 2
above). All six repositories were made public on 2026-10-16. A download that fails with "This
link is not public (HTTP 401)" means that a repository was made private again or that the link
names a repository that does not exist.

- The MegaDetector file of release `v0.8.0-alpha.1` (`MDV6-yolov10-c_int8_256.tflite`, the
  same bytes as `mdv6-yolov10c_256_w8a32.tflite`) stays online. Development builds from round
  268 to round 313 (never released) download it from there, and the model card names it. The
  released v0.8.0-alpha.1 carries the same file inside its APK.

A model in the list that is not offered (for example ArthroNat n) has no model card: its
`licence` and `source` here are taken from the authors' pages.
