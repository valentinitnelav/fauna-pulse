# Model formats & conversion guide

*For developers / collaborators who want their YOLO detection model to run inside FaunaPulse.*

FaunaPulse runs its detector(s) **on the phone itself** (no internet, no server). That
constrains which model file formats work. This page explains what to share, how to
convert, and why the app does **not** run plain ONNX files.

## TL;DR (too long; didn’t read)

| You have | What to do |
|---|---|
| A PyTorch checkpoint (`.pt`) | **Best option.** Share the `.pt`, or run the one-line export in *Converting* below yourself. |
| A plain ONNX file (`.onnx`) | The app can NOT run it. Convert it (see below); or better, send the `.pt` it was exported from. |
| A TFLite file (`.tflite`) | Works as-is: home screen Menu → Download & import models → Import model files… (or Download from a link…). |
| An Ultralytics QNN export (`*_qnn.onnx`) | Works as-is, but **only on Snapdragon phones** (runs on the NPU chip). Niche, see below. |

**Name your files by the project's naming rule** (round 276):
`<model>_<input px>_<precision>.tflite`, for example `my-bees-yolo11n_640_fp16.tflite`. The rule
and its reasons are in [`tool/model_downloads/README.md`](../tool/model_downloads/README.md#naming-rule-round-276).
The app shows every file by its name; a model listed in `assets/model_downloads.json` (by the
`<model>` part) also shows its licence and source.

## Why the app doesn't run plain ONNX

If you deploy models on Linux boxes or NVIDIA Jetson-style microcomputers, ONNX (or
TensorRT) is the natural format. Android is a different ecosystem: the mature on-device
runtime is **LiteRT** (formerly TensorFlow Lite), and that is what FaunaPulse uses (and the
Ultralytics Flutter plugin it is built on).

We looked into adding a general ONNX Runtime path and decided against it:

- **It would not be faster.** The file format doesn't change the model's math. On the
  CPU, ONNX Runtime and LiteRT sit on the same acceleration library (XNNPACK) - roughly
  equal speed. On the phone's GPU, LiteRT's GPU delegate is the mature path; ONNX
  Runtime's Android GPU options are weaker (its NNAPI backend is deprecated, and NNAPI
  itself is [deprecated as of Android 15](https://developer.android.com/ndk/guides/neuralnetworks/migration-guide)).
  So a converted `.tflite` is as fast or faster than the same model run as `.onnx`.
- **It would cost a lot.** A second inference engine in the app means a second set of
  device-specific bugs, a bigger APK, and duplicated logic (engine selection, GPU-crash
  fallback, benchmarking). This is heavy maintenance for a research app at this point.

## The ONE ONNX format that DOES work: `*_qnn.onnx` (Snapdragon NPU)

Ultralytics added a special Android path in
[yolo-flutter-app PR #526](https://github.com/ultralytics/yolo-flutter-app/pull/526)
(merged June 2026), and FaunaPulse includes it: a **QNN context-binary** export
(produced with `yolo export format=qnn` and named `*_qnn.onnx`) runs on the **NPU**
(Neural Processing Unit, a dedicated AI chip) of Qualcomm Snapdragon phones, via the
ONNX Runtime QNN backend. This can be faster and cooler than GPU/CPU.

Caveats, and why it's not the default recommendation:

- It only works on **Snapdragon** phones (At the time of testing this,
  my Xiaomi primary test phone qualifies; many budget phones use MediaTek/Exynos chips and do not). 
  There is deliberately no CPU fallback. On other hardware the model simply refuses
  to load and you must switch back to a `.tflite`.
- It is precompiled for a specific Hexagon NPU architecture at export time, and it
  only runs on Snapdragon chips of that architecture generation or newer. The
  target generation is usually in the file name (e.g. `yolo26n_v73_qnn.onnx`) and
  embedded in the file as `min_arch`. Approximate mapping: v68 = Snapdragon 888
  generation, v69 = 8 Gen 1, v73 = 8 Gen 2, v75 = 8 Gen 3, v79 and above = 8 Elite.
  Real-world example (July 2026): the `yolo26n_v73_qnn.onnx` / `yolo26n_v81_qnn.onnx`
  assets on the yolo-flutter-app v0.3.5 release page cannot run on my Snapdragon 888
  test phone (a v68 chip); ONNX Runtime fails with a cryptic
  `ORT_INVALID_GRAPH ... Error code: 5005`. Testing QNN on that phone would need an
  export targeting v68.
- Despite the `.onnx` extension, this is NOT a general ONNX file. A normal
  `yolo export format=onnx` file will not load.

The Download & import models screen (home screen: Menu, bottom left) accepts `*_qnn.onnx` through the same Import model
files… and Download from a link… buttons as `.tflite`. When a QNN model cannot run on the phone,
the app shows an error dialog explaining why and automatically switches back to
the previously loaded model. When there is none, the camera keeps running without a detection
model (motion-triggered and time-lapse capture still work) until another one is chosen.

## Converting

The conversion guide and the tools moved to the separate repository
[fauna-pulse-models](https://github.com/valentinitnelav/fauna-pulse-models) (round 311). Its `docs/MODEL_CONVERSION.md`
covers the recommended `.pt` → `.tflite` export, full INT8 with calibration images, models
other than YOLO and the `.onnx` fallback; its `detector_export/`, `classifier_export/` and
`bioclip_export/` folders do the conversion with checks. The short version, on any computer
with Python (no GPU needed, also not for INT8):

```bash
pip install "ultralytics>=8.4.83"
yolo export model=your_model.pt format=litert quantize=w8a32
```
