# Detector export: put a YOLO insect detector on the phone (PC side)

FaunaPulse runs its insect detector on the phone as a LiteRT file (`.tflite`). This folder
turns an Ultralytics checkpoint (`.pt`), for example one of the detectors of the
[InsectAI Model Zoo](https://github.com/InsectAI-COST-Action/insect-model-zoo), into phone
files and checks that they give the same boxes as the original. For the formats themselves
(why `.tflite`, what the app accepts) see `docs/MODEL_CONVERSION.md`.

## 1. Environment

The same Python environment as `tool/bioclip_export` (it already holds the converter,
`litert-torch`, and the quantiser, `ai-edge-quantizer`), plus Ultralytics:

```bash
cd fauna-pulse/tool/bioclip_export
source .venv/bin/activate          # made as in tool/bioclip_export/README.md section 1
pip install -r ../detector_export/requirements.txt
cd ../detector_export
```

A separate environment works too: `python3 -m venv .venv`, then
`pip install --extra-index-url https://download.pytorch.org/whl/cpu -r requirements.txt`
(the CPU build of PyTorch is enough; no GPU is needed).

## 2. Export

```bash
python export_detector.py --weights /path/to/flat_bug_S.pt --name flatbug-s --imgsz 1024 640 \
    --check-images ~/InsectDetectApp/test_videos/frames_bumblebees_720p --out out
```

What happens, per model:

1. The checkpoint is copied into `out/` and described (task, classes, training input size).
2. **Segmentation models become box detectors.** flat-bug outlines every insect
   (instance segmentation). FaunaPulse only uses boxes, so the outline branch is removed:
   the box and class layers stay exactly as trained, the phone skips the outline work.
   The script checks that the original and the converted model give the same boxes.
3. One phone file per `--imgsz`, made by Ultralytics' own LiteRT export, with **fp16**
   weights (half the float32 size; the float32 file is cast by
   `../bioclip_export/quantise_tflite.py` and the Ultralytics metadata copied over).
   fp16 gives the same boxes as PyTorch and is the phone GPU's own format. `--quantize
   w8a32` (8-bit weights, Ultralytics' default Android export, a quarter of the size) is
   faster on a phone CPU but moved boxes near the threshold (see section 3).
4. Agreement check: every phone file against the PyTorch model on `--check-images`
   (boxes matched by overlap; missed/extra boxes, mean overlap, largest confidence
   difference, PC time per image). Two files of the same model should agree; this is not
   an accuracy test.
5. A `.json` manifest next to each file (source file and its sha256, sizes, check results).

Output names say model, input size and quantisation: `flatbug-s_1024_fp16.tflite`. Import
them in the app (home screen ⋮, Download & import models, Import model files…; detection models up to 30 MiB), then run
**Benchmark engines** there, or time several files at once with
`integration_test/detector_speed_check_test.dart` (instructions in its header).

### Input size

The model's cost grows with the square of the input size: 1024 px costs 2.6 times 640 px.
flat-bug was trained on 1024 px tiles; insectDCT v8 on whole 1920 px camera-trap pictures.
A model runs at any size that is a multiple of 32, but insects then appear at other pixel
sizes than in training. FaunaPulse feeds the square area of interest (ROI) around a flower,
which enlarges insects compared with a whole camera-trap picture, so a smaller size can
work; compare sizes on your own footage before choosing. Rule of thumb: 640 or less for
live detection, 1024 for analysing videos afterwards.

## 3. Models exported so far

Round 264 (2026-10-01), weights from the InsectAI Model Zoo, checked on the 32 frames of
`~/InsectDetectApp/test_videos/frames_bumblebees_720p` (confidence 0.25). Phone: Xiaomi
11T Pro (Snapdragon 888, Adreno 660 GPU), plugged in, `integration_test/detector_speed_check_test.dart`
(model time only, 10 runs after 3 warm-up runs; no camera, cropping or tracking).

| File | Size | Boxes vs PyTorch | Phone GPU | Phone CPU (2 threads) |
|---|---|---|---|---|
| `ArthroNat_flatbug_yolo11n_int8_640` (today's live model, for comparison) | 2.8 MiB | | 20 ms | 293 ms |
| `flatbug-n_640_fp16` | 5.4 MiB | 28 of 28, conf. within 0.006 | 19 ms | 653 ms |
| `flatbug-n_640_w8a32` | 2.9 MiB | 22 of 28 (6 lost near the threshold), conf. within 0.12 | 17 ms | 278 ms |
| `flatbug-n_1024_fp16` | 5.5 MiB | 40 of 40, conf. within 0.005 | 37 ms | 1.9 s |
| `flatbug-s_640_fp16` | 19.0 MiB | 18 of 18, conf. within 0.002 | 34 ms | 1.7 s |
| `flatbug-s_1024_fp16` | 19.2 MiB | 31 of 31, conf. within 0.002 | 71 ms | 5.0 s |
| `insectdct-v8s_640_fp16` | 18.3 MiB | 17 of 17, conf. within 0.001 | 34 ms | 1.6 s |
| `insectdct-v8s_1024_fp16` | 18.5 MiB | 22 of 22, conf. within 0.002 | 76 ms | 4.2 s |

- Every file compiled on the phone's GPU. On a single check picture the phone's boxes
  matched the PC's to within 0.003 of the picture size (GPU in 16-bit), so the app decodes
  these files correctly.
- Removing flat-bug's outline branch changed no box (40 of 40 and 31 of 31 identical,
  same confidences).
- On this phone's GPU even the "s" models at 1024 px take 70 to 80 ms per picture (about
  13 per second, model time only), fine for analysing videos afterwards and possibly for
  live use; at 640 px they take 34 ms. Long runs heat the phone, so check the frame rate
  over minutes before relying on it live. A phone without a usable GPU needs seconds per
  picture for these files (live use impossible there).
- On the CPU, w8a32 (8-bit maths) was 2.3 times faster than fp16 for flat-bug n; on the
  GPU the two are equal. So fp16 for GPU phones and for analysing afterwards; w8a32 or a
  calibrated int8 only where a phone must run on its CPU, after checking its boxes.
- The bundled check pictures are a YouTube clip: they show that files agree, not how well
  a model finds insects. Choose between models and sizes on your own field footage.

## 4. Making models smaller or faster: what exists

| Technique | What it does | Needs training? | Effect | Status here |
|---|---|---|---|---|
| **Lower input size** | fewer pixels per picture | no | cost falls with the square of the size (measured above: 1024 px about 2 to 3 times 640 px) | `--imgsz` |
| **fp16** | 16-bit weights | no | half the size, same boxes; the phone GPU computes in 16 bits anyway | default |
| **w8a32** (dynamic range) | 8-bit weights; on the CPU the values between layers are also turned into 8 bits on the fly | no | a quarter of the size; 2.3 times faster on the phone CPU for flat-bug n; boxes near the threshold moved | `--quantize w8a32` |
| **int8** (full, static) | 8-bit weights and maths with fixed ranges | no training, but a few hundred calibration pictures of your own | the usual choice for phone CPUs and NPUs; accuracy depends on the calibration pictures | `--quantize int8 --data`, not tried yet |
| **Head surgery** | remove outputs the app does not use | no | flat-bug: the outline branch skipped, boxes identical | automatic |
| **Smaller architecture** | n instead of s | yes (or use a published n) | about 3 times fewer operations; flat-bug publishes n | exported |
| **Pruning** | remove the channels that matter least, then fine-tune | yes: fine-tuning on the training data | removes part of the computation for a small loss only when fine-tuned afterwards; without it accuracy drops sharply | not done: needs the training data (flat-bug's is on Zenodo), a GPU and a new validation; tool: Torch-Pruning (Fang et al. 2023, DepGraph, CVPR) |
| **Knowledge distillation** | train a small "student" to copy a big "teacher" | yes | e.g. a nano model that behaves more like a small one | not done |
| **Token merging** (BioCLIP only) | merge similar image patches inside the transformer | no (works on a trained model) | Bolya et al. (2023, ICLR) report about twice the speed of large vision transformers for a small accuracy loss | not tried on BioCLIP or on a phone |

Practical order for FaunaPulse: pick the input size first (largest effect, free), then the
quantisation (free), and only then consider pruning or distillation, which need the
training data, a GPU and a new validation.

## Files

| File | Purpose |
|---|---|
| `export_detector.py` | `.pt` -> `.tflite` (+ manifest), segmentation -> boxes, agreement check |
| `requirements.txt` | Ultralytics on top of the `tool/bioclip_export` environment |
| `out/` | outputs (git-ignored) |

## Licences

Check each model's licence before sharing a converted file. flat-bug: MIT (Svenning et
al. 2026, Methods in Ecology and Evolution, https://doi.org/10.1111/2041-210x.70249).
insectDCT: GPL-3.0 (Bjerge et al. 2026, bioRxiv, https://doi.org/10.64898/2026.07.07.736939).
Both were trained with Ultralytics (AGPL-3.0). Packaging and download of the weights: the
InsectAI Model Zoo (Markoff and InsectAI COST Action CA22129 contributors, 2026).
