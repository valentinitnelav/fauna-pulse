#!/usr/bin/env python3
"""Quantise a float32 .tflite model: make its numbers smaller (fp16 or int8), and check the result.

Quantisation in plain words
---------------------------
A model is mostly a long list of numbers (its "weights"; BioCLIP 2's image tower has
about 300 million). A converter writes each one as a 32-bit float ("fp32", 4 bytes).
Quantising stores them with fewer bits. The model gets smaller, and some chips can then
compute faster, at the price of a little rounding. This script offers three kinds:

    fp16          weights as 16-bit floats: half the size. On a phone GPU the maths runs
                  in 16 bits anyway, so this is the GPU's natural format and costs little
                  or no accuracy. On a CPU the weights are expanded back to 32 bits when 
                  the model loads, so it is NOT faster there; only the file is smaller.
    int8          "dynamic-range" int8: weights as 8-bit integers (a quarter of the size),
                  and the CPU also turns the values flowing between layers (the
                  "activations") into 8-bit numbers on the fly and multiplies in 8 bits.
                  This is the kind that can make a CPU faster; how much depends on the
                  chip (phone CPUs with 8-bit dot-product instructions gain most). The
                  8-bit activations cost the most accuracy of the three.
    int8-weights  weights stored as 8-bit integers but expanded to floats when the model
                  loads, so the maths stays float: a quarter of the fp32 size, close to
                  fp16 accuracy, no speed change on a CPU.

Does quantising need a GPU? No. This script runs on any computer's CPU (the
slow part, converting PyTorch to .tflite, is done before it). Whether the quantised
model then runs faster depends on where it runs: fp16 helps a GPU, int8 can help a CPU.

Measured with BioCLIP 2 (ViT-L/14) on 30 frames of a bee, against the original PyTorch
model (round 250, verify_parity.py):

    kind          size     same family as the original
    fp32          1216 MB  (reference)
    fp16           609 MB  30 of 30 (cosine 1.0000)
    int8-weights   309 MB  29 of 30 (cosine 0.9995)
    int8           309 MB  24 of 30 (cosine 0.9969)

All int8 misses were frames where the original model itself was unsure (its top family
below 50 %). On a laptop CPU (Intel i5-8350U, 4 threads) all four took 1.0 to 2.0 s per
crop; int8 was at most about 20 % faster, less than the laptop's own run-to-run spread.
On the phone, fp16 on the GPU took 0.27 s per crop against 2.6 s on the CPU (Xiaomi test
phone, Snapdragon 888). The app therefore ships BioCLIP as fp16 and runs it on the GPU
where it can.

For YOLO detectors, use Ultralytics' own export instead (it quantises during the export
and keeps the class names in the file): see docs/MODEL_CONVERSION.md. This script is
for other models already converted to a float32 .tflite (for example a classifier or an
embedder converted with litert-torch, as export_image_tower.py does).

How to check a quantised model: compare its outputs with the float32 model on your own
images (for BioCLIP: verify_parity.py). `--check` below only compares on random input,
which catches a broken file but says little about accuracy on real images.

Usage:
    python quantise_tflite.py my_model_fp32.tflite --precision fp16
    python quantise_tflite.py my_model_fp32.tflite --precision int8 --out my_model_int8.tflite
    python quantise_tflite.py my_model_fp32.tflite --precision fp16 --check   # + compare and time

Tools: ai-edge-quantizer (Google's quantiser for LiteRT/TFLite files, installed with
litert-torch; see requirements.txt).
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

PRECISIONS = ("fp16", "int8", "int8-weights")


def _patch_quantizer_names() -> None:
    """Workaround for ai-edge-quantizer 0.9.0 + flatbuffers 25.12 (harmless with other versions).

    The flatbuffer reader now yields tensor names as text (str), but the quantiser adds
    byte suffixes to them (`tensor.name + b'_dequant'`), which fails with "can only
    concatenate str (not "bytes") to str". The three patches below turn every name into
    bytes: once after the model is read, and in the two places that create new tensors.
    """
    from ai_edge_quantizer.transformations import duplicate_tensor as _dup
    from ai_edge_quantizer.transformations import transformation_utils as _tu
    from ai_edge_quantizer.utils import tfl_flatbuffer_utils

    if getattr(tfl_flatbuffer_utils, "_faunapulse_patched", False):
        return
    _orig_read_model = tfl_flatbuffer_utils.read_model

    def _read_model_with_byte_names(model_src):
        model = _orig_read_model(model_src)
        for sg in model.subgraphs or []:
            if isinstance(sg.name, str):
                sg.name = sg.name.encode("utf-8")
            for t in sg.tensors or []:
                if isinstance(t.name, str):
                    t.name = t.name.encode("utf-8")
        return model

    tfl_flatbuffer_utils.read_model = _read_model_with_byte_names

    # Creators of new tensors (e.g. duplicate_tensor's f"{name}_duplicated") pass str names;
    # encode them in add_new_activation_tensor.
    def _bytes_name(fn):
        def wrapped(*args, **kwargs):
            if isinstance(kwargs.get("tensor_name"), str):
                kwargs["tensor_name"] = kwargs["tensor_name"].encode("utf-8")
            elif args and isinstance(args[0], str):
                args = (args[0].encode("utf-8"),) + tuple(args[1:])
            return fn(*args, **kwargs)
        return wrapped

    _tu.add_new_activation_tensor = _bytes_name(_tu.add_new_activation_tensor)

    # duplicate_tensor builds its names with str f-strings and appends to them afterwards,
    # so it must run untouched; normalise the subgraph's names to bytes once it is done.
    _orig_duplicate = _dup.duplicate_tensor

    def _duplicate_with_byte_names(transformation_input):
        info = _orig_duplicate(transformation_input)
        for t in transformation_input.subgraph.tensors:
            if isinstance(t.name, str):
                t.name = t.name.encode("utf-8")
        return info

    _dup.duplicate_tensor = _duplicate_with_byte_names
    tfl_flatbuffer_utils._faunapulse_patched = True


def quantise(fp32_path: Path, out_path: Path, precision: str) -> None:
    """Write a quantised copy of the float32 model `fp32_path` to `out_path`.

    A "recipe" tells ai-edge-quantizer which layers to change and how. All three recipes
    here touch only the weights of FULLY_CONNECTED (matrix multiply) and CONV_2D
    (convolution) layers, which hold nearly all the numbers of a vision model; small
    tensors (biases, LayerNorm scales) stay float32.
    """
    from ai_edge_quantizer import qtyping, quantizer, recipe, recipe_manager
    from ai_edge_quantizer.algorithm_manager import AlgorithmName

    if precision not in PRECISIONS:
        raise ValueError(f"precision must be one of {PRECISIONS}")
    _patch_quantizer_names()
    if precision == "fp16":
        # "Float casting": each weight rounded to the nearest 16-bit float.
        rp = recipe_manager.RecipeManager()
        for op in (qtyping.TFLOperationName.FULLY_CONNECTED, qtyping.TFLOperationName.CONV_2D):
            rp.add_weight_only_config(
                regex=".*", operation_name=op, num_bits=16,
                algorithm_key=AlgorithmName.FLOAT_CASTING,
            )
        quant_recipe = rp.get_quantization_recipe()
    elif precision == "int8":
        # Weights: 8-bit integers with one scale per output channel ("channel-wise", so a
        # channel with large weights does not coarsen the others). Activations: made 8-bit
        # by the CPU while the model runs (no calibration images needed).
        quant_recipe = recipe.dynamic_wi8_afp32()
    else:
        # Same 8-bit weights, but expanded back to floats when the model loads (float maths).
        quant_recipe = recipe.weight_only_wi8_afp32()
    t0 = time.time()
    print(f"Applying {precision} to the weights with ai-edge-quantizer...")
    result = quantizer.Quantizer(str(fp32_path), quant_recipe).quantize()
    result.export_model(str(out_path), overwrite=True)
    print(f"{precision} TFLite written: {out_path} ({out_path.stat().st_size / 1e6:.0f} MB, "
          f"{time.time() - t0:.0f} s)")


def check(fp32_path: Path, quantised_path: Path, runs: int = 3, threads: int = 4) -> None:
    """Quick sanity check on this computer's CPU: the same random input through both files.
    Prints how closely the outputs agree (cosine, 1 = same direction) and the time per run.
    Random input catches a broken file; accuracy needs real images (see the file comment)."""
    import numpy as np
    try:
        from ai_edge_litert.interpreter import Interpreter
    except ImportError:
        from tensorflow.lite import Interpreter  # type: ignore

    x = None
    outs = {}
    for path in (fp32_path, quantised_path):
        interp = Interpreter(model_path=str(path), num_threads=threads)
        interp.allocate_tensors()
        inp, outp = interp.get_input_details()[0], interp.get_output_details()[0]
        if x is None:
            x = np.random.default_rng(0).random(inp["shape"], dtype=np.float32)
        interp.set_tensor(inp["index"], x)
        interp.invoke()  # warm-up: the first run pays one-off set-up costs
        ms = []
        for _ in range(runs):
            interp.set_tensor(inp["index"], x)
            t0 = time.perf_counter()
            interp.invoke()
            ms.append((time.perf_counter() - t0) * 1000)
        outs[path] = interp.get_tensor(outp["index"]).astype(np.float64).ravel()
        print(f"{path.name}: {sorted(ms)[len(ms) // 2]:.0f} ms per run on this CPU ({threads} threads)")
        del interp
    a, b = outs[fp32_path], outs[quantised_path]
    cos = float(a @ b / max(np.linalg.norm(a) * np.linalg.norm(b), 1e-12))
    print(f"output agreement with the float32 model on random input: cosine {cos:.4f}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("model", type=Path, help="float32 .tflite file")
    ap.add_argument("--precision", choices=PRECISIONS, default="fp16")
    ap.add_argument("--out", type=Path, default=None,
                    help="output file (default: the input name with _fp32 replaced, or the precision appended)")
    ap.add_argument("--check", action="store_true", help="compare with the float32 file and time both on this CPU")
    args = ap.parse_args()
    out = args.out
    if out is None:
        tag = args.precision.replace("-", "_")
        stem = args.model.stem
        out = args.model.with_name(stem.replace("_fp32", f"_{tag}") if "_fp32" in stem else f"{stem}_{tag}")
        out = out.with_suffix(".tflite")
    quantise(args.model, out, args.precision)
    if args.check:
        check(args.model, out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
