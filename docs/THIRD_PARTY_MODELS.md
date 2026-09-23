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
they are not provided or endorsed by Imageomics. BioCLIP 2.5 Huge (ViT-H/14, MIT) can be
exported the same way (`--model bioclip-2.5`).

[bioclip2]: https://huggingface.co/imageomics/bioclip-2
