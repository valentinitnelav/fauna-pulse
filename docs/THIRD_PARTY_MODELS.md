# Third-party model weights

## MegaDetector V6 (for detection)

FaunaPulse can also use TFLite converted / quantized versions of a PyTorch [MegaDetector V6][mgdetv6] model.

Original model: 

- Official code repository: https://github.com/microsoft/MegaDetector, by Microsoft AI for Good Lab.
- Original weights file: `MDV6-yolov10-c.pt` (md5:1ecc38fbe462320ea33bf3c57e9e1561) downloaded from [Pytorch-wildlife-model-weights, v27][ptwildznd] archived on Zenodo.
- Detection categories: `animal`, `person`, `vehicle`.
- Model license: GNU Affero General Public License v3.0 (AGPL-3.0). See also "MDV6-yolov10-c" listed at https://github.com/microsoft/MegaDetector#model-variants

### Conversion / quantization for FaunaPulse deployment

The TFLite quantized files distributed by FaunaPulse are unofficial conversions of the original MegaDetector V6 weights and are not provided or endorsed by Microsoft.

The original PyTorch weights were converted for on-device inference with TensorFlow Lite. 
Available variants may include FP32, FP16 and INT8 quantization.

The INT8 conversion uses a representative calibration dataset selected to approximate FaunaPulse smartphone deployment conditions.

The converted MegaDetector model files follow the license applicable to the original MegaDetector V6 model variant (AGPL-3.0). 
The FaunaPulse application is subject to the project's main LICENSE file.

[mgdetv6]: https://github.com/microsoft/MegaDetector/releases/tag/megadetector-v6.0
[ptwildznd]: https://zenodo.org/records/15398270


## BioCLIP 2 (for identification)

FaunaPulse's "Identify organisms" feature runs the image tower of [BioCLIP 2][bioclip2]
(Imageomics, ViT-L/14 trained on TreeOfLife-200M) on the phone, converted with
`tool/bioclip_export/export_image_tower.py` to TFLite (fp16, int8 or fp32). The label
packs derive from the TreeOfLife-200M species text embeddings published by the same team.

- Model card: https://huggingface.co/imageomics/bioclip-2 — **MIT license**.
- Embeddings: https://huggingface.co/datasets/imageomics/TreeOfLife-200M (embeddings/) — CC0-1.0.
- Paper to cite: Gu, J., Stevens, S., Campolongo, E. G., et al. (2025). *BioCLIP 2: Emergent
  Properties from Scaling Hierarchical Contrastive Learning.* NeurIPS 2025. https://arxiv.org/abs/2505.23883
- Also consider to cite the original BioCLIP (Stevens et al., CVPR 2024) and OpenCLIP, as the model card suggests.

The converted files are unofficial conversions made by FaunaPulse maintainers and users on their own PCs;
they are not provided or endorsed by Imageomics. BioCLIP 2.5 Huge (ViT-H/14, MIT,
https://huggingface.co/imageomics/bioclip-2.5-vith14) is exported the same way
(`--model bioclip-2.5`; round 264, `docs/IDENTIFICATION.md`); its label packs come from
the BioCLIP 2.5 text embeddings in the same TreeOfLife-200M dataset (CC0-1.0).

[bioclip2]: https://huggingface.co/imageomics/bioclip-2


## flat-bug and insectDCT (optional detectors, converted on request)

`tool/detector_export/export_detector.py` converts these for the phone (round 264); they are
not bundled with the app. Weights as packaged by the InsectAI Model Zoo (Markoff and InsectAI
COST Action CA22129 contributors, 2026, https://github.com/InsectAI-COST-Action/insect-model-zoo).

- **flat-bug** (n, s; YOLOv8-seg, used here as box detectors): Svenning, Mougeot, Alison, Chevalier,
  Chavez Molina, Ong, Bjerge, Carrillo, Høye & Geissmann (2026). A general method for detection and segmentation of terrestrial arthropods in
  images. *Methods in Ecology and Evolution* 17(3), 727-739. https://doi.org/10.1111/2041-210x.70249
  Code https://github.com/darsa-group/flat-bug, MIT.
- **insectDCT v8-s** (YOLO11s): Bjerge, Wogram, Serra-Marin, Sakhiashvili & Høye
  (2026). InsectDCT: A generalized pipeline for detection, taxonomic classification, and tracking of
  insects in camera-trap recordings. bioRxiv. https://doi.org/10.64898/2026.07.07.736939
  Code https://github.com/kimbjerge/insectDCT, GPL-3.0.

Both were trained with Ultralytics (AGPL-3.0). Converted files are unofficial conversions, not
provided or endorsed by the authors.

**insectDCT hierarchical classifier V7** (`insectdct-cls-v7`; ConvNeXt-Base, EfficientNetV2-S
and ResNet50 versions; 104 classes on three levels): same authors, paper and licence (GPL-3.0)
as insectDCT above; weights as packaged by the InsectAI Model Zoo. Converted for the phone
with `tool/classifier_export/` (round 265); the Identify screen runs it since round 266
(EfficientNetV2-S version recommended). No converted file is bundled: users import the model
and its class list. The class list's taxonomy uses the TreeOfLife names that come with
BioCLIP 2.5 (Imageomics). The choice between its three networks follows the authors'
published per-class test results (insectDCT repository, `metrics/`, version 6).

## Downloads offered in the app (round 268)

No model ships inside FaunaPulse. The AI models screen offers the converted files listed in
`assets/model_downloads.json` (MegaDetector V6, flat-bug n, insectDCT v8-s, the insectDCT
classifier, BioCLIP 2 and 2.5 with their name lists), hosted as release assets of the
FaunaPulse repository. Each entry names its licence and source; the conversions are unofficial,
as described above. `tool/model_downloads/README.md` explains how the list is kept current.

