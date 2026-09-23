#!/usr/bin/env python3
"""Export the BioCLIP image tower to a phone-runnable TFLite file (plus a manifest).

What this does, in plain words: BioCLIP is two networks, an image tower and a text
tower. The phone only needs the image tower (it turns a crop into a 768-number
"embedding"); the names are pre-computed on the PC by build_label_pack.py. This script
downloads the checkpoint from Hugging Face (about 1.7 GB for BioCLIP 2, 3.9 GB for
BioCLIP 2.5), wraps the image tower so the phone can feed plain RGB pixels in 0..1
(the CLIP colour normalisation and the final L2 normalisation are baked into the
graph), and converts it with litert-torch (formerly ai-edge-torch) to a .tflite file.

Precisions:
    fp32  plain conversion, ~1.2 GB for BioCLIP 2 (nothing quantised; slowest download)
    fp16  weights stored as 16-bit floats (ai-edge-quantizer "float casting"), ~0.6 GB,
          no measurable accuracy change, the GPU path's native format (DEFAULT)
    int8  dynamic-range quantisation (8-bit weights, float compute), ~0.3 GB, for the
          CPU path; a small accuracy cost that verify_parity.py measures

Converter: litert-torch >= 0.9 (formerly ai-edge-torch). It no longer needs TensorFlow;
the float32 graph comes out of litert-torch and the weight casting is done afterwards
with the ai-edge-quantizer package it depends on.

Usage (see README.md for the environment):
    python export_image_tower.py --model bioclip-2 --precision fp16 --out ./out
    python export_image_tower.py --model bioclip-2.5 --precision int8 --out ./out
    python export_image_tower.py --model bioclip-2 --onnx --out ./out   # extra .onnx

Output: <out>/<model>_image_<precision>.tflite and <same>.json (the manifest the app
and verify_parity.py read: dim, input size and layout, logit scale, sha256).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from datetime import date
from pathlib import Path

MODELS = {
    "bioclip-2": "hf-hub:imageomics/bioclip-2",
    "bioclip-2.5": "hf-hub:imageomics/bioclip-2.5-vith14",
    "bioclip-1": "hf-hub:imageomics/bioclip",
}
CLIP_MEAN = (0.48145466, 0.4578275, 0.40821073)
CLIP_STD = (0.26862954, 0.26130258, 0.27577711)
KEEP_FP32 = False


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build_tower(model_key: str):
    """Load the OpenCLIP model and wrap its image tower for export."""
    import torch
    import open_clip

    model, _, _ = open_clip.create_model_and_transforms(MODELS[model_key])
    model.eval()
    logit_scale = float(model.logit_scale.exp().item())

    class ImageTower(torch.nn.Module):
        def __init__(self, visual):
            super().__init__()
            self.visual = visual
            self.register_buffer("mean", torch.tensor(CLIP_MEAN).view(1, 3, 1, 1))
            self.register_buffer("std", torch.tensor(CLIP_STD).view(1, 3, 1, 1))

        def forward(self, x):
            # x: [1, 3, 224, 224] RGB in 0..1 (what the app's native side feeds).
            x = (x - self.mean) / self.std
            f = self.visual(x)
            return torch.nn.functional.normalize(f, dim=-1)

    tower = ImageTower(model.visual).eval()
    image_size = model.visual.image_size
    if isinstance(image_size, (tuple, list)):
        image_size = int(image_size[0])
    with torch.no_grad():
        dim = int(tower(torch.zeros(1, 3, image_size, image_size)).shape[-1])
    return tower, image_size, dim, logit_scale


def export_tflite(tower, image_size: int, precision: str, out_path: Path, lightweight: bool = False) -> None:
    """Convert with litert-torch (0.9+, no TensorFlow needed), then cast/quantise weights.

    litert-torch converts the PyTorch graph straight to a float32 .tflite. The fp16 and
    int8 variants are produced from that file with the bundled ai-edge-quantizer:
    fp16 = "float casting" of the weight tensors (FULLY_CONNECTED + CONV_2D, the only
    large tensors in a ViT), int8 = dynamic-range quantisation (int8 weights, float
    activations). The float32 intermediate is deleted afterwards unless it IS the target.
    """
    import torch

    try:
        import litert_torch as converter_lib  # new name (2025+)
    except ImportError:
        import ai_edge_torch as converter_lib  # old name of the same package

    sample = (torch.zeros(1, 3, image_size, image_size),)
    fp32_path = out_path if precision == "fp32" else out_path.with_name(
        out_path.name.replace(f"_{precision}.tflite", "_fp32.tflite"))
    t0 = time.time()
    if not fp32_path.exists():
        # Full constant folding (lightweight=False) matters: the memory-saving mode
        # leaves "weight × LayerNorm-gamma" products as runtime MULs of 700 MB of
        # constants, which the fp16/int8 cast cannot touch (found on the owner's PC:
        # the fp16 file came out LARGER than float32). Full folding needed ~7 GB RAM
        # and 74 s for BioCLIP 2.
        print("Converting with litert-torch (a few minutes, ~7 GB RAM for BioCLIP 2)...")
        try:
            edge = converter_lib.convert(tower, sample, lightweight_conversion=lightweight)
        except TypeError:  # older ai-edge-torch without the lightweight flag
            edge = converter_lib.convert(tower, sample)
        edge.export(str(fp32_path))
        del edge
        print(f"float32 TFLite written: {fp32_path} ({fp32_path.stat().st_size / 1e6:.0f} MB, "
              f"{time.time() - t0:.0f} s)")
    else:
        print(f"Reusing existing float32 TFLite: {fp32_path}")
    if precision == "fp32":
        return

    from ai_edge_quantizer import quantizer, recipe, recipe_manager, qtyping
    from ai_edge_quantizer.algorithm_manager import AlgorithmName
    from ai_edge_quantizer.utils import tfl_flatbuffer_utils

    # Workaround (ai-edge-quantizer 0.9.0 + flatbuffers 25.12): the flatbuffer object
    # API now yields tensor names as str, but the quantizer's transformations append
    # bytes suffixes (`tensor.name + b'_dequant'`). Normalise every name to bytes right
    # after the model is read; get_tensor_name() decodes bytes, so nothing else changes.
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

    # Same bug from the other side: transformations that CREATE tensors (e.g.
    # duplicate_tensor's f"{name}_duplicated") pass str names, and a later
    # dequant insertion on such a tensor fails. Encode names in the two creators.
    from ai_edge_quantizer.transformations import transformation_utils as _tu

    def _bytes_name(fn):
        def wrapped(*args, **kwargs):
            if isinstance(kwargs.get("tensor_name"), str):
                kwargs["tensor_name"] = kwargs["tensor_name"].encode("utf-8")
            elif args and isinstance(args[0], str):
                args = (args[0].encode("utf-8"),) + tuple(args[1:])
            return fn(*args, **kwargs)
        return wrapped

    _tu.add_new_activation_tensor = _bytes_name(_tu.add_new_activation_tensor)

    # duplicate_tensor builds its names with str f-strings and appends to them
    # afterwards, so it must run untouched; normalise the subgraph's names to
    # bytes once it is done.
    from ai_edge_quantizer.transformations import duplicate_tensor as _dup

    _orig_duplicate = _dup.duplicate_tensor

    def _duplicate_with_byte_names(transformation_input):
        info = _orig_duplicate(transformation_input)
        for t in transformation_input.subgraph.tensors:
            if isinstance(t.name, str):
                t.name = t.name.encode("utf-8")
        return info

    _dup.duplicate_tensor = _duplicate_with_byte_names

    if precision == "fp16":
        rp = recipe_manager.RecipeManager()
        for op in (qtyping.TFLOperationName.FULLY_CONNECTED, qtyping.TFLOperationName.CONV_2D):
            rp.add_weight_only_config(
                regex=".*", operation_name=op, num_bits=16,
                algorithm_key=AlgorithmName.FLOAT_CASTING,
            )
        quant_recipe = rp.get_quantization_recipe()
    else:  # int8 dynamic range
        quant_recipe = recipe.dynamic_wi8_afp32()
    t1 = time.time()
    print(f"Applying {precision} to the weights with ai-edge-quantizer...")
    q = quantizer.Quantizer(fp32_path, quant_recipe)
    result = q.quantize()
    result.export_model(out_path, overwrite=True)
    print(f"{precision} TFLite written: {out_path} ({out_path.stat().st_size / 1e6:.0f} MB, "
          f"{time.time() - t1:.0f} s)")
    if fp32_path != out_path and not KEEP_FP32:
        fp32_path.unlink()
        print(f"Removed the float32 intermediate {fp32_path.name} (use --keep-fp32 to keep it)")


def export_onnx(tower, image_size: int, out_path: Path) -> None:
    import torch

    torch.onnx.export(
        tower, torch.zeros(1, 3, image_size, image_size), str(out_path),
        input_names=["image"], output_names=["embedding"], opset_version=17,
    )
    print(f"ONNX written: {out_path} ({out_path.stat().st_size / 1e6:.0f} MB)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", choices=sorted(MODELS), default="bioclip-2")
    ap.add_argument("--precision", choices=["fp32", "fp16", "int8"], default="fp16")
    ap.add_argument("--out", type=Path, default=Path("out"))
    ap.add_argument("--onnx", action="store_true", help="also write an fp32 ONNX file (PC parity / fallback)")
    ap.add_argument("--skip-tflite", action="store_true", help="only the ONNX + manifest (debugging)")
    ap.add_argument("--keep-fp32", action="store_true", help="keep the float32 intermediate .tflite")
    ap.add_argument("--lightweight", action="store_true",
                    help="litert-torch's memory-saving conversion mode: only if the normal conversion runs out "
                         "of RAM; leaves weight×LayerNorm products unfolded, so fp16/int8 files stay large")
    args = ap.parse_args()
    global KEEP_FP32
    KEEP_FP32 = args.keep_fp32

    args.out.mkdir(parents=True, exist_ok=True)
    print(f"Loading {MODELS[args.model]} (downloads the checkpoint on first use)...")
    tower, image_size, dim, logit_scale = build_tower(args.model)
    print(f"image tower ready: input {image_size}x{image_size}, embedding dim {dim}, logit_scale {logit_scale:.2f}")

    stem = f"{args.model.replace('.', '')}_image_{args.precision}"
    tflite_path = args.out / f"{stem}.tflite"
    manifest = {
        "kind": "embedder",
        "model_id": args.model,
        "hf_repo": MODELS[args.model].replace("hf-hub:", ""),
        "dim": dim,
        "input_size": image_size,
        "input_layout": "NCHW",
        "input_range": "0..1 RGB (normalisation baked into the graph)",
        "output": "L2-normalised embedding",
        "logit_scale": logit_scale,
        "precision": args.precision,
        "exported": date.today().isoformat(),
        "license": "MIT (model weights, Imageomics)",
    }
    if args.onnx:
        onnx_path = args.out / f"{args.model.replace('.', '')}_image_fp32.onnx"
        export_onnx(tower, image_size, onnx_path)
        manifest["onnx_sha256"] = sha256_of(onnx_path)
    if not args.skip_tflite:
        export_tflite(tower, image_size, args.precision, tflite_path, lightweight=args.lightweight)
        manifest["file"] = tflite_path.name
        manifest["sha256"] = sha256_of(tflite_path)
        manifest["bytes"] = tflite_path.stat().st_size
    manifest_path = args.out / f"{stem}.json"
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print(f"Manifest written: {manifest_path}")
    print("Next: python verify_parity.py --tflite", tflite_path, "--images <folder of crops>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
