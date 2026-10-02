#!/usr/bin/env python3
"""Export the BioCLIP image tower to a phone-runnable TFLite file (plus a manifest).

What this does, in plain words: BioCLIP is two networks, an image tower and a text
tower. The phone only needs the image tower (it turns a crop into a 768-number
"embedding"); the names are pre-computed on the PC by build_label_pack.py. This script
downloads the checkpoint from Hugging Face (about 1.7 GB for BioCLIP 2, 3.9 GB for
BioCLIP 2.5), wraps the image tower so the phone can feed plain RGB pixels in 0..1
(the CLIP colour normalisation and the final L2 normalisation are baked into the
graph), and converts it with litert-torch (formerly ai-edge-torch) to a .tflite file.

Precisions (what quantisation is and what each costs: see quantise_tflite.py):
    fp32          plain conversion, ~1.2 GB for BioCLIP 2 (nothing quantised)
    fp16          weights stored as 16-bit floats, ~0.6 GB, same answers as PyTorch,
                  the phone GPU's native format (DEFAULT)
    int8          8-bit weights, and 8-bit maths on the CPU ("dynamic range"), ~0.3 GB;
                  on 30 test frames it changed the family on 6 unsure ones
    int8-weights  8-bit weights expanded to floats on loading, ~0.3 GB, float maths

Converter: litert-torch >= 0.9 (formerly ai-edge-torch). It no longer needs TensorFlow;
the float32 graph comes out of litert-torch and the weight casting is done afterwards
with the ai-edge-quantizer package it depends on.

Attention (round 242): by default every attention layer is exported as plain matrix
steps with at most 4-dimensional tensors (--attention 4d). PyTorch's own attention
passes the data through 5-dimensional tensors, which the phone's GPU engine cannot run
("RESHAPE ... bad input dims size"), so the whole model fell back to the CPU; the
maths and the weights are the same (verify_parity.py compares the two exports).
--attention torch keeps PyTorch's own layers (the export before round 242).

Usage (see README.md for the environment):
    python export_image_tower.py --model bioclip-2 --precision fp16 --out ./out
    python export_image_tower.py --model bioclip-2.5 --precision fp16 --out ./out
    python export_image_tower.py --model bioclip-2.5 --weights /path/to/open_clip_model.safetensors --out ./out
    python export_image_tower.py --model bioclip-2 --onnx --out ./out   # extra .onnx

Output: <out>/<model>_<input px>_<precision>.tflite and <same>.json (the manifest the app
and verify_parity.py read: dim, input size and layout, logit scale, sha256), named by the
rule in tool/model_downloads/README.md (round 276): bioclip-2_224_fp16.tflite,
bioclip-2.5_224_fp16.tflite; int8-weights is written "w8a32"; --attention torch adds "_5d".
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
# open_clip architecture of each model, for a checkpoint file already on disk (--weights)
ARCH = {"bioclip-2": "ViT-L-14", "bioclip-2.5": "ViT-H-14", "bioclip-1": "ViT-B-16"}
CLIP_MEAN = (0.48145466, 0.4578275, 0.40821073)
CLIP_STD = (0.26862954, 0.26130258, 0.27577711)
KEEP_FP32 = False


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_open_clip(model_key: str, weights: Path | None = None):
    """The OpenCLIP model: from Hugging Face (downloaded once into its cache), or from a
    checkpoint file already on disk (--weights; e.g. the InsectAI Model Zoo's copy), which
    avoids a second multi-GB download."""
    import open_clip

    if weights is None:
        model, _, _ = open_clip.create_model_and_transforms(MODELS[model_key])
    else:
        model, _, _ = open_clip.create_model_and_transforms(ARCH[model_key], pretrained=str(weights))
    return model.eval()


def four_dim_attention(mha):
    """nn.MultiheadAttention (self-attention, batch_first, no mask) as plain steps with
    tensors of at most 4 dimensions, with the same weights: the phone's GPU engine
    rejects PyTorch's 5-dimensional in-projection reshape. Same maths, so the embeddings
    agree to float rounding."""
    import torch

    class FourDimAttention(torch.nn.Module):
        def __init__(self):
            super().__init__()
            e, h = mha.embed_dim, mha.num_heads
            self.h, self.d = h, e // h
            self.scale = self.d ** -0.5
            w, b = mha.in_proj_weight.detach(), mha.in_proj_bias.detach()
            self.q, self.k, self.v = (torch.nn.Linear(e, e) for _ in range(3))
            for i, lin in enumerate((self.q, self.k, self.v)):
                lin.weight.data = w[i * e:(i + 1) * e].clone()
                lin.bias.data = b[i * e:(i + 1) * e].clone()
            self.out = mha.out_proj

        def forward(self, query, key=None, value=None, need_weights=False, attn_mask=None):
            # Self-attention only (the image tower passes the same tensor three times).
            assert attn_mask is None, "the image tower has no attention mask"
            n, t, e = query.shape
            q = self.q(query).reshape(n, t, self.h, self.d).permute(0, 2, 1, 3)  # [n, h, t, d]
            k = self.k(query).reshape(n, t, self.h, self.d).permute(0, 2, 3, 1)  # [n, h, d, t]
            v = self.v(query).reshape(n, t, self.h, self.d).permute(0, 2, 1, 3)  # [n, h, t, d]
            a = torch.softmax(torch.matmul(q * self.scale, k), dim=-1)            # [n, h, t, t]
            o = torch.matmul(a, v).permute(0, 2, 1, 3).reshape(n, t, e)
            return self.out(o), None

    return FourDimAttention()


def build_tower(model_key: str, attention: str = "4d", weights: Path | None = None):
    """Load the OpenCLIP model and wrap its image tower for export."""
    import torch

    model = load_open_clip(model_key, weights)
    logit_scale = float(model.logit_scale.exp().item())
    if attention == "4d":
        swapped = 0
        for block in model.visual.transformer.resblocks:
            attn = block.attn
            if isinstance(attn, torch.nn.MultiheadAttention):
                if not (attn.batch_first and attn._qkv_same_embed_dim and attn.bias_k is None):
                    raise SystemExit("unexpected attention layout; export with --attention torch")
                block.attn = four_dim_attention(attn).eval()
                swapped += 1
        print(f"attention: {swapped} layers as 4-dimensional steps (GPU-friendly)")

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


def precision_tag(precision: str) -> str:
    """The precision part of a file name (naming rule, round 276): weight-only int8 is
    "w8a32" (int8 weights, float activations), as for the detectors."""
    return "w8a32" if precision == "int8-weights" else precision


def export_tflite(tower, image_size: int, precision: str, out_path: Path, lightweight: bool = False) -> None:
    """Convert with litert-torch (0.9+, no TensorFlow needed), then quantise the weights.

    litert-torch converts the PyTorch graph straight to a float32 .tflite. The fp16 and
    int8 variants are made from that file by quantise_tflite.quantise (ai-edge-quantizer).
    The float32 intermediate is deleted afterwards unless it IS the target.
    """
    import torch

    try:
        import litert_torch as converter_lib  # new name (2025+)
    except ImportError:
        import ai_edge_torch as converter_lib  # old name of the same package

    sample = (torch.zeros(1, 3, image_size, image_size),)
    fp32_path = out_path if precision == "fp32" else out_path.with_name(
        out_path.name.replace(f"_{precision_tag(precision)}", "_fp32", 1))
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

    # The quantisation step itself (and why fp16 is the default) is explained in
    # quantise_tflite.py, which also works on other models' float32 .tflite files.
    from quantise_tflite import quantise

    quantise(fp32_path, out_path, precision)
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
    ap.add_argument("--precision", choices=["fp32", "fp16", "int8", "int8-weights"], default="fp16")
    ap.add_argument("--attention", choices=["4d", "torch"], default="4d",
                    help="4d (default): attention as steps of at most 4 dimensions, so phone GPUs can run "
                         "it; torch: PyTorch's own layers (exports before round 242)")
    ap.add_argument("--weights", type=Path, default=None,
                    help="checkpoint file already on disk (open_clip_model.safetensors) instead of the Hugging "
                         "Face download")
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
    print(f"Loading {args.weights or MODELS[args.model]} (a Hugging Face checkpoint is downloaded on first use)...")
    tower, image_size, dim, logit_scale = build_tower(args.model, args.attention, args.weights)
    print(f"image tower ready: input {image_size}x{image_size}, embedding dim {dim}, logit_scale {logit_scale:.2f}")

    stem = f"{args.model}_{image_size}_{precision_tag(args.precision)}{'_5d' if args.attention == 'torch' else ''}"
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
        "attention": args.attention,
        "exported": date.today().isoformat(),
        "license": "MIT (model weights, Imageomics)",
    }
    if args.onnx:
        onnx_path = args.out / f"{args.model}_{image_size}_fp32.onnx"
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
