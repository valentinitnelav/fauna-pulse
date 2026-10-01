# Model downloads: the catalogue the app offers (round 268)

No model ships inside FaunaPulse. The **AI models** screen (home screen ⋮ menu) offers the
models listed in [`assets/model_downloads.json`](../../assets/model_downloads.json): a title,
one plain line on what each model is for, the size and the licence. One tap downloads a
detection model, or an identification model together with the name list chosen (a label pack
for BioCLIP, the class list for insectDCT). A model already on the phone is not downloaded
again: two BioCLIP name lists share one model.

## Why separate files, not one zip per model

Model weights barely compress, unpacking a zip needs twice the space for a moment (2.5 GB for
BioCLIP 2.5) and a zip per name list would repeat the shared BioCLIP model. So every file is
a separate download, grouped by the catalogue, the way model hubs such as Hugging Face keep
models (separate files plus a list of what belongs together).

## The catalogue file

- `base_url`: where the files are; a file's link is `base_url` + its name. A file can carry
  its own `"url"` instead (for example a Hugging Face link, or a file in another release).
- `detectors`: one `file` each. `identification`: a model `file` plus `lists`.
- `bytes` and `sha256`: the app shows the size and checks every download against the
  checksum. A file on the phone counts as present by its **name** only, so re-exported
  weights on the phone are not flagged.

## When weights change

1. Re-export, then refresh the sizes and checksums from the local files:
   `python tool/model_downloads/update_catalogue.py <files…>` (`--check` only reports).
2. Upload the files as GitHub release assets under exactly the names in the catalogue.
3. Do not replace a published file under the same link: app versions already installed would
   reject the new file (its checksum differs from the one they carry). Upload changed weights
   under a new file name or a new release tag and change the catalogue (`base_url`, or the
   file's own `"url"`), so old and new app versions both keep working.

## Files listed in round 268 (placeholder links, release `v0.8.0-alpha.1`)

| Catalogue name | Local file to upload |
|---|---|
| `MDV6-yolov10-c_int8_256.tflite` | `assets/models/custom/` (already uploaded) |
| `flatbug-n_640_fp16.tflite` | `tool/detector_export/out/` |
| `insectdct-v8-s_640_fp16.tflite` | `tool/detector_export/out/` |
| `insectdct-cls-v7_eff2s_fp16.tflite`, `.fpack` | `tool/classifier_export/out/` |
| `bioclip-2_image_fp16_4d.tflite` | `tool/bioclip_export/out/gpu4d/bioclip-2_image_fp16.tflite` (**rename**: the GPU export) |
| `bioclip2_pollinator_orders_europe_v1.fpack`, `bioclip2_flower_visitors_32fam_v1.fpack` | `tool/bioclip_export/out/` |
| `bioclip-25_image_fp16.tflite`, `bioclip25_*_v1.fpack` | `tool/bioclip_export/out/bioclip25/` |

GitHub release assets may be up to 2 GiB each; BioCLIP 2.5 (1.27 GB) fits. The licences are in
`docs/THIRD_PARTY_MODELS.md`.
