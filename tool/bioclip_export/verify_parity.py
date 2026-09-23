#!/usr/bin/env python3
"""Check that the exported TFLite image tower matches the PyTorch model.

Why: a wrong resize, colour order or quantisation would silently lower accuracy on
the phone. This compares embeddings of real crops from both paths and reports the
cosine similarity (1.0 = identical direction). With a label pack it also reports
how often the two agree on the top family and species.

Usage:
    python verify_parity.py --tflite out/bioclip2_image_fp16.tflite --images ./crops [--pack out/x.fpack] [--limit 200]

Acceptance (plan section 7, Phase 0): mean cosine >= 0.99 and >= 95 % family agreement.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

from fpack import read_fpack

CLIP_MEAN = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)
CLIP_STD = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)


def load_rgb01(path: Path, size: int) -> np.ndarray:
    """pybioclip's TreeOfLife transform: direct resize to size x size (no centre crop)."""
    im = Image.open(path).convert("RGB").resize((size, size), Image.BILINEAR)
    return np.asarray(im, dtype=np.float32) / 255.0  # HWC 0..1


def torch_embed(model_key: str, images: list[np.ndarray]) -> np.ndarray:
    import torch
    import open_clip

    from export_image_tower import MODELS

    model, _, _ = open_clip.create_model_and_transforms(MODELS[model_key])
    model.eval()
    out = []
    with torch.no_grad():
        for hwc in images:
            x = torch.from_numpy(hwc).permute(2, 0, 1).unsqueeze(0)
            x = (x - torch.tensor(CLIP_MEAN).view(1, 3, 1, 1)) / torch.tensor(CLIP_STD).view(1, 3, 1, 1)
            f = model.encode_image(x)
            out.append(torch.nn.functional.normalize(f, dim=-1)[0].numpy())
    return np.stack(out)


def tflite_embed(tflite_path: Path, images: list[np.ndarray]) -> tuple[np.ndarray, float]:
    try:
        from ai_edge_litert.interpreter import Interpreter
    except ImportError:
        from tensorflow.lite import Interpreter  # type: ignore
    interp = Interpreter(model_path=str(tflite_path), num_threads=4)
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    outp = interp.get_output_details()[0]
    nchw = inp["shape"][1] == 3
    out, ms = [], []
    for hwc in images:
        x = hwc[None]
        if nchw:
            x = np.transpose(x, (0, 3, 1, 2))
        interp.set_tensor(inp["index"], x.astype(np.float32))
        t0 = time.time()
        interp.invoke()
        ms.append((time.time() - t0) * 1000)
        v = interp.get_tensor(outp["index"])[0].astype(np.float32)
        out.append(v / max(np.linalg.norm(v), 1e-9))
    return np.stack(out), float(np.median(ms))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tflite", type=Path, required=True)
    ap.add_argument("--images", type=Path, required=True, help="folder of crop images (jpg/png), searched recursively")
    ap.add_argument("--model", default=None, help="model key (default: read from the .json manifest next to the tflite)")
    ap.add_argument("--pack", type=Path, default=None, help="label pack to compare top-1 family/species agreement")
    ap.add_argument("--limit", type=int, default=200)
    args = ap.parse_args()

    manifest_path = args.tflite.with_suffix(".json")
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    model_key = args.model or manifest.get("model_id", "bioclip-2")
    size = int(manifest.get("input_size", 224))

    paths = sorted(p for p in args.images.rglob("*") if p.suffix.lower() in {".jpg", ".jpeg", ".png"})[: args.limit]
    if not paths:
        print("no images found", file=sys.stderr)
        return 2
    images = [load_rgb01(p, size) for p in paths]
    print(f"{len(images)} images, model {model_key}, input {size}")

    ref = torch_embed(model_key, images)
    got, med_ms = tflite_embed(args.tflite, images)
    cos = np.sum(ref * got, axis=1)
    print(f"cosine similarity: mean {cos.mean():.4f}  min {cos.min():.4f}  (tflite median {med_ms:.0f} ms/crop on this PC)")
    ok = cos.mean() >= 0.99
    if args.pack is not None:
        hdr, mat = read_fpack(args.pack)
        scale = float(hdr.get("logit_scale", 100.0))
        labels = hdr["labels"]
        def top(v):
            return int(np.argmax(mat @ v))
        fam = sum(labels[top(a)][4] == labels[top(b)][4] for a, b in zip(ref, got)) / len(ref)
        spe = sum(top(a) == top(b) for a, b in zip(ref, got)) / len(ref)
        print(f"top-1 agreement vs PyTorch: family {fam:.1%}  species {spe:.1%}  (pack {hdr['pack_id']}, scale {scale:.1f})")
        ok = ok and fam >= 0.95
    print("PARITY OK" if ok else "PARITY FAILED (see thresholds in the docstring)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
