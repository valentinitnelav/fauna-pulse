#!/usr/bin/env python3
"""Prepare a YOLO insect detector (.pt) for FaunaPulse: one or more phone files (.tflite).

What this does, in plain words:
  1. Copies the checkpoint into --out and reports what it is (task, classes, training size).
  2. Segmentation models (e.g. flat-bug, which also outlines each insect) become plain box
     detectors: FaunaPulse only uses boxes, so the outline branch is removed ("head surgery").
     The box and class layers are untouched, so the boxes are the same (checked in step 4);
     the phone skips the outline work (about a third of flat-bug's compute at 1024 px).
  3. Exports with Ultralytics' own LiteRT export, once per --imgsz (input size in pixels).
     Default: fp16 weights (half the size of float32; the Ultralytics float32 file is
     cast by ../bioclip_export/quantise_tflite.py and its metadata copied over). fp16 gives
     the same boxes as PyTorch on the CPU and is the phone GPU's own format. w8a32 (8-bit
     weights, Ultralytics' default Android export) is a quarter of the size but changed
     boxes near the threshold: flat-bug n at 640 px lost 6 of 28 boxes (round 264).
  4. Checks every phone file against the PyTorch model on --check-images (any photos): the
     same boxes should come out (matched by overlap), with nearly the same confidences.
     This is an agreement check between two files of the SAME model, not an accuracy test.
  5. Writes <file>.json next to each .tflite: source, sha256, sizes, check results.

Why several input sizes: the model's cost grows with the square of the input size
(1024 px costs 2.6x 640 px). Live detection on the phone needs speed (640 or less);
analysing videos afterwards can afford 1024. A model trained at a larger size (insectDCT
v8: 1920 px on whole camera-trap pictures) still runs at a smaller size, but insects then
look larger in pixels than in training; FaunaPulse feeds the square area of interest
(ROI) around a flower, which enlarges insects anyway. Compare sizes on your own footage.

Usage (environment: see README.md in this folder):
    python export_detector.py --weights flat_bug_S.pt --name flatbug-s --imgsz 1024 640 \
        --check-images ../../../test_videos/frames_bumblebees_720p --out out
    python export_detector.py --weights insects8Color11s.pt --name insectdct-v8-s --imgsz 1024 640 ...
    # full 8-bit (weights and maths, fastest on phone CPUs) needs calibration images:
    python export_detector.py --weights my.pt --name my --imgsz 640 --quantize int8 --data my_data.yaml

Output: <out>/<name>_<imgsz>_<quantize>.tflite (+ .json), e.g. flatbug-s_1024_fp16.tflite.
FaunaPulse imports .tflite files of up to 30 MiB (Settings -> AI -> Model -> Import...).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import time
import zipfile
from datetime import date
from pathlib import Path

APP_MAX_BYTES = 30 * 1024 * 1024  # kMaxTfliteModelBytes in lib/fauna_pulse/models/model_file_security.dart
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png"}


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def describe(ckpt: dict) -> dict:
    m = ckpt.get("model") or ckpt.get("ema")
    args = ckpt.get("train_args") or {}
    return {
        "head": type(m.model[-1]).__name__,
        "task": args.get("task") or getattr(m, "task", None),
        "classes": dict(getattr(m, "names", {}) or {}),
        "train_imgsz": args.get("imgsz"),
        "params_millions": round(sum(p.numel() for p in m.parameters()) / 1e6, 2),
        "ultralytics_version": ckpt.get("version"),
    }


def to_box_detector(src: Path, dst: Path) -> None:
    """Segmentation checkpoint -> box-only checkpoint (same weights for boxes and classes).

    Ultralytics' Segment head is its Detect head plus a mask branch (cv4 = mask coefficients per
    box, proto = mask prototypes at 1/4 resolution). Switching the head's class to Detect makes
    it run only the shared box/class layers; the mask layers are deleted so they are not saved.
    """
    import torch
    from ultralytics.nn.modules.head import Detect, Segment

    ckpt = torch.load(src, map_location="cpu", weights_only=False)
    for key in ("model", "ema"):
        m = ckpt.get(key)
        if m is None:
            continue
        head = m.model[-1]
        if not isinstance(head, Segment) or getattr(head, "end2end", False):
            raise SystemExit(f"{src.name}: only standard Segment heads can be converted (got {type(head).__name__})")
        head.__class__ = Detect
        for name in ("cv4", "proto", "one2one_cv4"):
            if hasattr(head, name):
                delattr(head, name)
        m.task = "detect"
        if isinstance(getattr(m, "args", None), dict):
            m.args["task"] = "detect"
        if isinstance(getattr(m, "yaml", None), dict):
            last = m.yaml["head"][-1]
            last[2], last[3] = "Detect", last[3][:1]  # [nc, nm, npr] -> [nc]
    ckpt["ema"] = None
    ckpt["optimizer"] = None
    if isinstance(ckpt.get("train_args"), dict):
        ckpt["train_args"]["task"] = "detect"
    torch.save(ckpt, dst)


def to_fp16(fp32_file: Path, target: Path) -> None:
    """fp16 copy of an Ultralytics float32 LiteRT file, keeping its metadata (class names, input
    size, task: a metadata.json zip entry Ultralytics appends after the model)."""
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bioclip_export"))
    from quantise_tflite import quantise

    quantise(fp32_file, target, "fp16")
    with zipfile.ZipFile(fp32_file) as z:
        meta = z.read("metadata.json")
    with zipfile.ZipFile(target, "a", zipfile.ZIP_DEFLATED) as z:
        z.writestr("metadata.json", meta)


def boxes_of(model, image: Path, imgsz: int, conf: float):
    """[(x1, y1, x2, y2, conf)] in pixels of the original image. rect=False: PyTorch otherwise pads
    a portrait picture only to a multiple of 32 (e.g. 576 x 1024), while a phone file always gets
    the full square, and the two would see different pictures."""
    r = model.predict(str(image), imgsz=imgsz, conf=conf, iou=0.7, rect=False, verbose=False)[0]
    return [(*b, c) for b, c in zip(r.boxes.xyxy.tolist(), r.boxes.conf.tolist())]


def iou(a, b) -> float:
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def compare(ref_model, test_model, images: list[Path], imgsz: int, conf: float) -> dict:
    """Greedy one-to-one matching of boxes (IoU >= 0.5, most overlapping first)."""
    matched = missed = extra = 0
    ious, dconf, ms = [], [], []
    for im in images:
        ref = boxes_of(ref_model, im, imgsz, conf)
        t0 = time.time()
        got = boxes_of(test_model, im, imgsz, conf)
        ms.append((time.time() - t0) * 1000)
        pairs = sorted(((iou(a, b), i, j) for i, a in enumerate(ref) for j, b in enumerate(got)), reverse=True)
        used_r, used_g = set(), set()
        for v, i, j in pairs:
            if v < 0.5 or i in used_r or j in used_g:
                continue
            used_r.add(i)
            used_g.add(j)
            ious.append(v)
            dconf.append(abs(ref[i][4] - got[j][4]))
        matched += len(used_r)
        missed += len(ref) - len(used_r)
        extra += len(got) - len(used_g)
    return {
        "images": len(images),
        "boxes_reference": matched + missed,
        "matched": matched,
        "missed": missed,
        "extra": extra,
        "mean_iou": round(sum(ious) / len(ious), 4) if ious else None,
        "max_conf_difference": round(max(dconf), 4) if dconf else None,
        "pc_ms_per_image": round(sorted(ms)[len(ms) // 2]) if ms else None,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--weights", type=Path, required=True, help="the original Ultralytics checkpoint (.pt)")
    ap.add_argument("--name", required=True, help="short name used for the output files, e.g. flatbug-s")
    ap.add_argument("--imgsz", type=int, nargs="+", default=[640], help="one or more input sizes in pixels")
    ap.add_argument("--quantize", choices=["fp16", "w8a32", "fp32", "int8"], default="fp16",
                    help="fp16 (default): 16-bit weights, same boxes as PyTorch; w8a32: 8-bit weights, a quarter "
                         "of the size, boxes near the threshold change; fp32: nothing quantised; int8: 8-bit "
                         "weights and maths, needs --data (calibration images)")
    ap.add_argument("--data", default=None, help="dataset .yaml with calibration images (only for --quantize int8)")
    ap.add_argument("--keep-masks", action="store_true",
                    help="keep a segmentation model's outline branch (FaunaPulse cannot use such files today)")
    ap.add_argument("--check-images", type=Path, default=None, help="folder of photos for the agreement check")
    ap.add_argument("--check-limit", type=int, default=30)
    ap.add_argument("--conf", type=float, default=0.25, help="confidence threshold of the check")
    ap.add_argument("--out", type=Path, default=Path("out"))
    args = ap.parse_args()
    if args.quantize == "int8" and not args.data:
        ap.error("--quantize int8 needs --data (a dataset .yaml whose images calibrate the 8-bit ranges)")

    import torch
    from ultralytics import YOLO

    args.out.mkdir(parents=True, exist_ok=True)
    ckpt = torch.load(args.weights, map_location="cpu", weights_only=False)
    info = describe(ckpt)
    del ckpt
    print(f"{args.weights.name}: {info}")

    # 1-2. Work on a copy in --out (Ultralytics writes its exports next to the .pt).
    src_copy = args.out / f"{args.name}.pt"
    converted = info["head"] == "Segment" and not args.keep_masks
    if converted:
        to_box_detector(args.weights, src_copy)
        print(f"segmentation head -> box detector: {src_copy}")
    else:
        shutil.copyfile(args.weights, src_copy)

    images = []
    if args.check_images is not None:
        images = sorted(p for p in args.check_images.rglob("*") if p.suffix.lower() in IMAGE_SUFFIXES)
        images = images[: args.check_limit]
        print(f"check images: {len(images)} from {args.check_images}")
    if converted and images:
        # The surgery must not change a single box: original vs converted, both in PyTorch.
        same = compare(YOLO(str(args.weights)), YOLO(str(src_copy)), images, args.imgsz[0], args.conf)
        print(f"segmentation vs box-only (PyTorch, {args.imgsz[0]} px): {same}")
        if same["missed"] or same["extra"]:
            print("WARNING: the box-only model does not give the same boxes", file=sys.stderr)

    for size in args.imgsz:
        t0 = time.time()
        kw = {"format": "litert", "imgsz": size}
        if args.quantize in ("w8a32", "int8"):
            kw["quantize"] = 8 if args.quantize == "int8" else "w8a32"
        if args.data:
            kw["data"] = args.data
        exported = Path(YOLO(str(src_copy)).export(**kw))
        target = args.out / f"{args.name}_{size}_{args.quantize}.tflite"
        if args.quantize == "fp16":
            to_fp16(exported, target)
            exported.unlink()
        else:
            exported.replace(target)
        size_mb = target.stat().st_size / 2**20
        print(f"\n{target.name}: {size_mb:.1f} MiB, export {time.time() - t0:.0f} s"
              f"{'' if target.stat().st_size <= APP_MAX_BYTES else '  (LARGER than the app accepts: 30 MiB)'}")
        manifest = {
            "file": target.name,
            "bytes": target.stat().st_size,
            "sha256": sha256_of(target),
            "imgsz": size,
            "quantize": args.quantize,
            "source": {"file": args.weights.name, "sha256": sha256_of(args.weights), **info},
            "converted_to_box_detector": converted,
            "exported": date.today().isoformat(),
            "script": "tool/detector_export/export_detector.py",
        }
        if images:
            manifest["check_vs_pytorch"] = compare(YOLO(str(src_copy)), YOLO(str(target), task="detect"),
                                                   images, size, args.conf)
            print(f"check vs PyTorch at {size} px: {manifest['check_vs_pytorch']}")
        target.with_suffix(".json").write_text(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
