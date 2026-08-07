# Model formats & conversion guide

*For developers / collaborators who want their YOLO detection model to run inside FaunaPulse.*

FaunaPulse runs its detector(s) **on the phone itself** (no internet, no server). That
constrains which model file formats work. This page explains what to share, how to
convert, and why the app does **not** run plain ONNX files.

## TL;DR (too long; didn’t read)

| You have | What to do |
|---|---|
| A PyTorch checkpoint (`.pt`) | **Best option.** Share the `.pt`, or run the one-line TFLite export below yourself. |
| A plain ONNX file (`.onnx`) | The app can NOT run it. Convert it (see below); or better, send the `.pt` it was exported from. |
| A TFLite file (`.tflite`) | Works as-is: Settings → AI → Model → Import… (or Download… from a URL). |
| An Ultralytics QNN export (`*_qnn.onnx`) | Works as-is, but **only on Snapdragon phones** (runs on the NPU chip). Niche, see below. |

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

The app's model picker accepts `*_qnn.onnx` through the same Import…
and Download… buttons as `.tflite`. When a QNN model cannot run on the phone,
the app shows an error dialog explaining why and automatically switches back to
a model that works (the previously loaded one, or the bundled MDV6 INT8 default).

## Converting: `.pt` → `.tflite` (the recommended route)

On any computer with Python, using the [Ultralytics package](https://docs.ultralytics.com/modes/export/):

```bash
pip install "ultralytics>=8.4.83"

# Recommended: ONE export, no dataset needed:
yolo export model=your_model.pt format=litert quantize=w8a32
```

This writes a `..._w8a32.tflite` file that imports straight into the app
(Settings → AI → Model → Import…, or Download… from a URL).

Why this is the recommended export (app support added in round 155):

- **No calibration dataset.** `w8a32` is "dynamic-range" quantization: the model's
  weights are stored as 8-bit integers while activations stay float32, so the
  exporter needs nothing but the `.pt` file.
- **Small and GPU-friendly.** It is the smallest format that still compiles on the
  phone-GPU delegate the app uses (this is Ultralytics' own default Android export).
- **Metadata included.** `format=litert` is a native Ultralytics export and embeds
  the class names and input size (the onnx2tf-based fallback below loses them).
- The app auto-detects this export's channel layout (NCHW `[1,3,H,W]`, different
  from the older exports' `[1,H,W,3]`), so `format=litert` and older
  `format=tflite` files both work in the same picker.

### Older / alternative exports (all still work)

```bash
# Float32 - no dataset needed, most accurate, largest/slowest:
yolo export model=your_model.pt format=tflite

# Float16 ("half") - no dataset needed, half the size:
yolo export model=your_model.pt format=tflite half=True

# Full INT8 - smallest & fastest on CPU, needs a calibration dataset (see below):
yolo export model=your_model.pt format=tflite int8=True data=your_data.yaml
```

Each `format=tflite` command writes a `..._saved_model/` folder containing the
`.tflite` file.

### Notes:

1. **Full INT8 specifically needs calibration images.** INT8 stores the model's
   numbers (weights AND activations) as 8-bit integers, and the exporter must see a
   few hundred *representative* images (your training/validation data) to choose the
   value ranges. Calibrating on unrelated images (e.g. generic COCO photos) can
   noticeably hurt accuracy.
2. **w8a32, fp32 and fp16 exports do not need calibration images**, just the `.pt` file.
3. An ONNX export is a float model too, and converting it wouldn't dodge anything.

#### Why full INT8 still matters (low-end phones)

On phones whose GPU can't run a given model, everything runs on the CPU, and there
full INT8 is faster than the float-activation formats (w8a32 included).
For example, measured in FaunaPulse on my slower test phone (Samsung Galaxy M12 class),
an INT8 YOLO26-nano model (see asset `yolo26n_int8.tflite` in 
[v0.3.5 of ultralytics/yolo-flutter-app](https://github.com/ultralytics/yolo-flutter-app/releases?page=2#release-v0.3.5)) 
allowed a 2-3 fps and that is already rather slow for accurate tracking. 
Therefore, on low-end or older phones, full INT8 might be the only practical option.

Nuance for stronger phones: whether a model runs on the GPU is decided by whether the
GPU backend can compile the model's operations *not* by its float precision. INT8 models
can and do run on the GPU too, and fp16 is perfectly fine there. So when in doubt,
export w8a32 plus a full-INT8 variant. The FaunaPulse app has a built-in benchmark
(Settings → AI → "Benchmark engines") that times them on the phone.

## Converting: `.onnx` → `.tflite` (when the `.pt` is truly unavailable)

Possible with [onnx2tf](https://github.com/PINTO0309/onnx2tf), the same tool
Ultralytics uses internally, but fussier than exporting from `.pt` (channel-layout
transposes, occasional unsupported operations, and the app expects the standard
Ultralytics YOLO output layout). Treat it as the fallback, not the plan:

```bash
pip install onnx2tf onnx onnx_graphsurgeon sng4onnx
onnx2tf -i your_model.onnx -o converted_model
```

Note that a float `.tflite` produced this way still lacks the Ultralytics metadata
(class names, input size) a native export embeds. The app copes (it reads the input
size from the tensor shape), but class names may be missing. One more reason to
prefer the `.pt` route.

## Quick checklist

1. Preferably share the `.pt`; otherwise run the exports yourself and share `.tflite`.
2. Export **w8a32** (`format=litert quantize=w8a32`, one command, no dataset). Add a
   full-INT8 variant (calibrated on your own data) when low-end phones matter.
3. Keep the input size modest (640 or smaller, e.g. 480/416/320 px) because preprocessing and
   inference cost scale with input size squared, and phones throttle with heat.
4. Only bother with `format=qnn` if it targets a specific Snapdragon phone.
