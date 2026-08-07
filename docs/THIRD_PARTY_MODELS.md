# Third-party model weights

## MegaDetector V6

FaunaPulse can also use TFLite converted / quantized versions of a PyTorch [MegaDetector V6][mgdetv6] model.

Original model: 

- Official code repository: https://github.com/microsoft/MegaDetector, by Microsoft AI for Good Lab.
- Original weights file: `MDV6-yolov10-c.pt` (md5:1ecc38fbe462320ea33bf3c57e9e1561) downloaded from [Pytorch-wildlife-model-weights, v27][ptwildznd] archived on Zenodo.
- Detection categories: `animal`, `person`, `vehicle`.
- Model license: GNU Affero General Public License v3.0 (AGPL-3.0). See also "MDV6-yolov10-c" listed at https://github.com/microsoft/MegaDetector#model-variants

### FaunaPulse conversion / quantization

The TFLite quantized files distributed by FaunaPulse are unofficial conversions of the original MegaDetector V6 weights and are not provided or endorsed by Microsoft.

The original PyTorch weights were converted for on-device inference with TensorFlow Lite. 
Available variants may include FP32, FP16 and INT8 quantization.

The INT8 conversion uses a representative calibration dataset selected to approximate FaunaPulse smartphone deployment conditions.

The converted MegaDetector model files follow the license applicable to the original MegaDetector V6 model variant (AGPL-3.0). 
The FaunaPulse application is subject to the project's main LICENSE file.

<!-- 
Reference links: [id]: URL
These are links used throughout this file
-->

[mgdetv6]: https://github.com/microsoft/MegaDetector/releases/tag/megadetector-v6.0
[ptwildznd]: https://zenodo.org/records/15398270