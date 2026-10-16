# Third-party model weights

## MegaDetector V6 (for detection)

FaunaPulse offers an unofficial TFLite conversion of the [MegaDetector V6][mgdet] variant `MDV6-yolov10-c`.

Original model: 

- Made by the Microsoft AI for Good Lab. Code and documentation: https://github.com/microsoft/MegaDetector (code: MIT); all variants and their licences: [MegaDetector Model Zoo][mdzoo].
- Original weights file: `MDV6-yolov10-c.pt` (md5 `1ecc38fbe462320ea33bf3c57e9e1561`, the checksum Zenodo lists for it) from the Zenodo deposit [Pytorch-wildlife-model-weights, version v22][ptwildznd] (the record PyTorch-Wildlife downloads it from; versions v24 to v27 hold the identical file).
- Detection categories: `animal`, `person`, `vehicle`.
- Model license: GNU Affero General Public License v3.0 (AGPL-3.0), the licence the authors give for `MDV6-yolov10-c` in the [MegaDetector Model Zoo][mdzoo].
- Please cite MegaDetector as its authors ask: https://microsoft.github.io/MegaDetector/cite/ (the references are also in the model card, see *Downloads offered in the app* below).

### Conversion / quantization for FaunaPulse deployment

The TFLite file distributed by FaunaPulse is an unofficial conversion of the original MegaDetector V6 weights and is not provided or endorsed by Microsoft.

The original PyTorch weights were converted with Ultralytics' own TFLite export (Ultralytics 8.3.235, `int8=True`, 256 x 256 px input).
In that Ultralytics version this gives 8-bit weights with the values between layers kept as 32-bit floats
(dynamic-range quantization, "w8a32"), not full INT8; Ultralytics names such a file "_int8". Ultralytics loads calibration pictures for its other INT8 files, but they do not change this one.
The file is published as `mdv6-yolov10c_256_w8a32.tflite`; the same bytes were `MDV6-yolov10-c_int8_256.tflite`
of the app's GitHub release v0.8.0-alpha.1.

The converted MegaDetector model file follows the license applicable to the original MegaDetector V6 model variant (AGPL-3.0). 
The FaunaPulse application is subject to the project's main LICENSE file.

[mgdet]: https://github.com/microsoft/MegaDetector
[mdzoo]: https://microsoft.github.io/MegaDetector/model_zoo/
[ptwildznd]: https://doi.org/10.5281/zenodo.15398270


## BioCLIP 2 (for identification)

FaunaPulse's "Identify organisms" feature runs the image tower of [BioCLIP 2][bioclip2]
(Imageomics, ViT-L/14 trained on TreeOfLife-200M) on the phone, converted with
`bioclip_export/export_image_tower.py` of [fauna-pulse-models](https://github.com/valentinitnelav/fauna-pulse-models) to TFLite (fp16, int8 or fp32). The published
file, `bioclip-2_224_fp16.tflite`, is the fp16 export whose attention uses tensors of at most four
dimensions, so that phone GPUs can run it. The label packs derive from the TreeOfLife-200M species
text embeddings published by the same team.

- Model card: https://huggingface.co/imageomics/bioclip-2 (**MIT license**). Source weights:
  `open_clip_model.safetensors` of imageomics/bioclip-2 at commit 2957b32 (SHA-256
  `b7b2bf6fbc95799e42630e394cf95803892ab447c1a8ab629dbc82fbeaf7dfef`).
- Embeddings: https://huggingface.co/datasets/imageomics/TreeOfLife-200M (embeddings/), CC0-1.0. The
  common names in it come from the GBIF Backbone Taxonomy (CC BY 4.0): please credit GBIF when you
  reuse them.
- The Europe label pack's species list: a regional GBIF species list, as the pybioclip docs
  recommend (Imageomics, "Geo-Restricted Taxon List Predictions"), built from GBIF.org occurrence
  counts as in `insect-detect-post` (Sittinger 2026, https://doi.org/10.5281/zenodo.21822140):
  its GBIF query and its TreeOfLife-to-GBIF key table (re-implemented; the table is not
  redistributed).
- Paper to cite: Gu, J., Stevens, S., Campolongo, E. G., et al. (2025). *BioCLIP 2: Emergent
  Properties from Scaling Hierarchical Contrastive Learning.* NeurIPS 2025.
  https://doi.org/10.52202/085713-3436 (preprint https://arxiv.org/abs/2505.23883). The model card
  also asks to cite the model itself: Gu et al. (2025). BioCLIP 2 (Version 1.0.0). Hugging Face.
  https://doi.org/10.57967/hf/5765
- Also consider to cite the original BioCLIP (Stevens et al., CVPR 2024) and OpenCLIP, as the model card suggests.

The converted files are unofficial conversions; they are not provided or endorsed by Imageomics.
BioCLIP 2.5 Huge (ViT-H/14, MIT,
https://huggingface.co/imageomics/bioclip-2.5-vith14) is exported the same way
(`--model bioclip-2.5`; round 264, `docs/IDENTIFICATION.md`); its label packs come from
the BioCLIP 2.5 text embeddings in the same TreeOfLife-200M dataset (CC0-1.0).

[bioclip2]: https://huggingface.co/imageomics/bioclip-2


## flat-bug and insectDCT (insect detectors)

`detector_export/export_detector.py` of [fauna-pulse-models](https://github.com/valentinitnelav/fauna-pulse-models) converts these for the phone (round 264); they are
not bundled with the app. The source weights are the authors' own files, downloaded from the
authors' links below.

- **flat-bug** (n, s; YOLOv8-seg, used here as box detectors): Svenning, Mougeot, Alison, Chevalier,
  Chavez Molina, Ong, Bjerge, Carrillo, Høye & Geissmann (2026). A general method for detection and segmentation of terrestrial arthropods in
  images. *Methods in Ecology and Evolution* 17(3), 727-739. https://doi.org/10.1111/2041-210x.70249
  Code https://github.com/darsa-group/flat-bug, MIT. Source weights: `flat_bug_N.pt` (SHA-256
  `e54eb199fb8397f70dc36aca4727b92836fb7f56b11f8544be60f54c13d273c0`) and `flat_bug_S.pt` (SHA-256
  `b410d2c902c8975f6c8263ee74871e618e55d670f86cf49ad49869de9a9ccc03`) from the authors' model store
  at Aarhus University (https://anon.erda.au.dk/cgi-sid/ls.py?share_id=Bb0CR1FHG6&current_dir=models),
  the same files the `flat-bug` package downloads. N and S are the 2024 models of the paper; the
  authors' newer default `flat_bug_M_v2.pt` is not converted.
- **insectDCT detector v8** (YOLO11s; "v8" is the authors' detection dataset version 8, not YOLOv8;
  the authors call the model `insects8Color11s`): Bjerge, Wogram, Serra-Marin, Sakhiashvili, Jepsen & Høye
  (2026). InsectDCT: A generalized pipeline for detection, taxonomic classification, and tracking of
  insects in camera-trap recordings. bioRxiv. https://doi.org/10.64898/2026.07.07.736939
  Code and trained models https://github.com/kimbjerge/insectDCT, GPL-3.0. Source weights:
  `runs/detect/insects8Color11s/weights/best.pt` of that repository at commit e459ae8 (SHA-256
  `719ff88f1b8c9dc57ef0fed5e741adc12900a4c3e93c31f9a3c071379947e4ac`).

Both were trained with Ultralytics (AGPL-3.0). Converted files are unofficial conversions, not
provided or endorsed by the authors.

- **ArthroNat n** (YOLO11n, 640 px; trained on the ArthroNat and flat-bug pictures; not offered
  for download, listed so that converted files show their details): Remy, Carlier, Massol,
  Kacimi, Chaine & Cauchoix (2026). Towards a general Detector of terrestrial Arthropods in
  Natural backgrounds. bioRxiv. https://doi.org/10.64898/2026.05.06.723207
  Weights https://huggingface.co/edgaremy/arthropod-detector (AGPL-3.0, as listed by the model
  card's licence tag); code and dataset
  https://github.com/edgaremy/arthropod-detection-dataset (MIT).

**insectDCT hierarchical classifier V7** (`insectdct-cls-v7`; ConvNeXt-Base, EfficientNetV2-S
and ResNet50 versions; 104 classes on three levels): same authors, paper and licence (GPL-3.0)
as insectDCT above. Source weights: `HierarchicalClassifier_EFF2S_V7.pth` (SHA-256
`520deb4e8f3a58f717ff86b9dadaee67a72e84186b306d43ce5cd814d3178afc`) from the authors' zip
`HierarchicalClassifierV7_31032026.zip`, which the insectDCT README links on Google Drive
(https://drive.google.com/file/d/15oGWBgp3S08k8VK0r2qzMC65uUBFvsPh/view). Converted for the phone
with `classifier_export/` of fauna-pulse-models (round 265); the Identify screen runs it since round 266
(EfficientNetV2-S version recommended). No converted file is bundled: users download or import the model
and its class list. The class list's taxonomy uses the TreeOfLife names that come with
BioCLIP 2.5 (Imageomics). The choice between its three networks follows the authors'
published per-class test results (insectDCT repository, `metrics/`, version 6).

## Downloads offered in the app (round 268)

No model ships inside FaunaPulse. The Download & import models screen offers the converted files listed in
`assets/model_downloads.json`:

- detection: `flatbug-n_640_fp16.tflite` and `flatbug-s_640_fp16.tflite` (flat-bug n and s; for
  insects the app suggests flat-bug n first, then flat-bug s and insectDCT),
  `insectdct-v8s_640_fp16.tflite` (insectDCT) and `mdv6-yolov10c_256_w8a32.tflite` (MegaDetector V6);
- identification: `insectdct-cls-v7-eff2s_224_fp16.tflite` with its class list (the `.fpack` of the
  same name); `bioclip-2_224_fp16.tflite` with the label packs
  `bioclip-2_pollinator-orders-europe_v1.fpack`, `bioclip-2_flower-visitors-32fam_v1.fpack` and
  `bioclip-2_mammals-birds-world_v1.fpack`; `bioclip-2.5_224_fp16.tflite` (BioCLIP 2.5) with
  `bioclip-2.5_pollinator-orders-europe_v1.fpack` and `bioclip-2.5_flower-visitors-32fam_v1.fpack`.

These phone conversions are published on Hugging Face, account
[Valen-Peregrine](https://huggingface.co/Valen-Peregrine), one repository per model family:
[mdv6-tflite](https://huggingface.co/Valen-Peregrine/mdv6-tflite),
[flatbug-tflite](https://huggingface.co/Valen-Peregrine/flatbug-tflite),
[insectdct-v8-tflite](https://huggingface.co/Valen-Peregrine/insectdct-v8-tflite),
[insectdct-cls-v7-tflite](https://huggingface.co/Valen-Peregrine/insectdct-cls-v7-tflite),
[bioclip-2-tflite](https://huggingface.co/Valen-Peregrine/bioclip-2-tflite) and
[bioclip-2.5-tflite](https://huggingface.co/Valen-Peregrine/bioclip-2.5-tflite). Each repository
holds a model card (original authors, source weights and their checksums, how the file was
converted, licence, how to cite; the flat-bug and insectDCT cards also report a check against the
original model) and a copy of the original model's licence text (`LICENSE`). The app downloads
each file from a link pinned to one commit of its repository and checks its SHA-256. Each entry of the list names its licence and source; the
conversions are unofficial, as described above. `tool/model_downloads/README.md` explains how
the list is kept current.
Since round 276 the same list also names the models that are not offered (other sizes and
networks) with their licence and source, taken from this page; the app shows them in the (i)
card of each file. Since round 277 the screen also says that most models were made by other
research teams and only adapted for phones, that each keeps its creators' licence, and asks
users to cite the original model as its authors ask on its source page (the list holds no
citations, since they change and the authors keep theirs current).

