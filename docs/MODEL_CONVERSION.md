# Model formats & conversion guide

*For developers and collaborators who want their YOLO detection model to run in FaunaPulse.*

FaunaPulse runs its detectors **on the phone itself** (no internet, no server). That limits
which model file formats work. This page says what to share, how to convert, and why the app
does **not** run plain ONNX files.

## TL;DR (too long; didn’t read)

| You have | What to do |
|---|---|
| A PyTorch checkpoint (`.pt`) | **Best option.** Share the `.pt`, or run the one-line export in *Converting* below yourself. |
| A plain ONNX file (`.onnx`) | The app can NOT run it. Convert it (see below), or better, send the `.pt` it was made from. |
| A TFLite file (`.tflite`) | Works as it is: home screen Menu → Download & import models → Import model files… (or Download from a link…). |
| An Ultralytics QNN export (`*_qnn.onnx`) | Works as it is, but **only on Snapdragon phones** (it runs on the NPU chip) and only in the NPU edition of the app. Rarely needed, see below. |

The detector must be a plain detection model: the app refuses segmentation, pose and
rotated-box (OBB) exports at import.

**Name your files by the project's naming rule:**
`<model>_<input px>_<precision>.tflite`, for example `my-bees-yolo11n_640_fp16.tflite`. The rule
and its reasons are in [`tool/model_downloads/README.md`](../tool/model_downloads/README.md#naming-rule-round-276).
The app shows every file by its name; a model listed in `assets/model_downloads.json` (by the
`<model>` part) also shows its licence and source.

## Why the app doesn't run plain ONNX

On Linux computers or NVIDIA Jetson-type boards, ONNX (or TensorRT) is the usual format. On
Android the mature runtime is **LiteRT** (formerly TensorFlow Lite), used by FaunaPulse and the
Ultralytics Flutter plugin it is built on. We decided against a general ONNX Runtime path:

- **It would not be faster.** The file format does not change the model's maths. On the CPU,
  ONNX Runtime and LiteRT use the same acceleration library (XNNPACK), so the speed is about
  equal. On the phone's GPU, LiteRT's GPU path is the mature one; ONNX Runtime's Android GPU
  options are weaker (its NNAPI backend is deprecated, and NNAPI itself is
  [deprecated as of Android 15](https://developer.android.com/ndk/guides/neuralnetworks/migration-guide)).
  So a converted `.tflite` is as fast as the same model run as `.onnx`, or faster.
- **It would cost a lot.** A second engine means a second set of phone-specific bugs, a bigger
  APK, and duplicated logic (engine choice, GPU-crash fallback, benchmarking): too much upkeep
  for a research app.

## The ONE ONNX format that DOES work: `*_qnn.onnx` (Snapdragon NPU)

Ultralytics added a special Android path in
[yolo-flutter-app PR #526](https://github.com/ultralytics/yolo-flutter-app/pull/526)
(merged June 2026), and FaunaPulse includes it: a **QNN context-binary** export
(made with `yolo export format=qnn` and named `*_qnn.onnx`) runs on the **NPU**
(Neural Processing Unit, a dedicated AI chip) of Qualcomm Snapdragon phones, through the
ONNX Runtime QNN backend. This can be faster and cooler than the GPU or CPU.

Limits, and why it is not the default advice:

- It works only on **Snapdragon** phones; many low-cost phones use MediaTek or Exynos chips. On
  purpose there is no CPU fallback: on other chips the model does not load, and you must switch
  back to a `.tflite`.
- It runs only in the NPU edition of the app, which includes the QNN runtime. The normal
  edition leaves it out to stay small, and a `*_qnn.onnx` model fails to load there with a hint
  ([LEAN_QNN_PACKAGING.md](LEAN_QNN_PACKAGING.md)).
- It is compiled at export time for one Hexagon NPU generation and runs only on Snapdragon
  chips of that generation or newer. The target generation is usually in the file name (e.g.
  `yolo26n_v73_qnn.onnx`) and is stored in the file as `min_arch`. Approximate mapping: v68 = Snapdragon 888,
  v69 = 8 Gen 1, v73 = 8 Gen 2, v75 = 8 Gen 3, v79 and above = 8 Elite. Example (July 2026): the
  `yolo26n_v73_qnn.onnx` and `yolo26n_v81_qnn.onnx` files on the yolo-flutter-app v0.3.5
  release page cannot run on the Xiaomi 11T Pro test phone (Snapdragon 888, a v68 chip); ONNX
  Runtime fails with the unclear `ORT_INVALID_GRAPH ... Error code: 5005`. A QNN test on that
  phone would need an export for v68.
- Despite the `.onnx` extension, this is NOT a general ONNX file. A normal
  `yolo export format=onnx` file will not load.

The Download & import models screen (home screen: Menu, bottom left) takes `*_qnn.onnx` through
the same buttons as `.tflite`. When a QNN model cannot run on the phone, a dialog says why and
the app switches back to the model loaded before. With no model before, the camera runs without
a detection model (motion-triggered and time-lapse capture still work) until one is chosen.

## Converting

The conversion guide and the tools are in the separate repository
[fauna-pulse-models](https://github.com/valentinitnelav/fauna-pulse-models). Its
`docs/MODEL_CONVERSION.md` covers the recommended `.pt` → `.tflite` export, full INT8 with
calibration images, models other than YOLO, and the `.onnx` fallback; its `detector_export/`,
`classifier_export/` and `bioclip_export/` folders do the conversion with checks. The short
version, on any computer with Python (no GPU needed, also not for INT8):

```bash
pip install "ultralytics>=8.4.83"
yolo export model=your_model.pt format=litert quantize=w8a32
```
