#!/usr/bin/env python3
"""Run SAM 3 on the PC over the frames an earlier "Run AI on videos" analysed, and write the
boxes as the app's video_detections.jsonl (round 257, sam3 branch).

Why: SAM 3's picture model gives only NaN on the Xiaomi's GPU and is far too slow on phone
CPUs (docs/SAM3.md), so for now SAM 3 runs here, with the same LiteRT files on the CPU. Taking
exactly the frames (and the same analysed square) of an earlier run lets the app's tracker
("Find visits") compare SAM 3's track IDs with that model's, frame for frame.

Usage:
    python detect_video.py SESSION_COPY (--sam3-dir DIR | --efficientsam3 CKPT) --prompt insect
        [--confidence 0.5] [--iou 0.7] [--fps 1] [--threads 4] [--out FILE]

SESSION_COPY holds videos/<clip> (the phone's copy of the video) and the earlier run's
video_detections.jsonl. --fps keeps the frames an analysis at that rate would have looked at,
by the phone's rule (PtsSampler in VideoFrameSource.kt, thinVideoDetections in
test/fauna_pulse/video_fps_sweep_test.dart), so both models see the same frames. The output
(default SESSION_COPY/sam3/video_detections.jsonl, or SESSION_COPY/<checkpoint name>/...) is
appended frame by frame, so a stopped run continues where it stopped. Needs ffmpeg. SAM 3 takes
about 40 s per frame on a 4-core laptop.

--efficientsam3 (round 258) runs a distilled, smaller SAM 3 instead: one of the three full
models (EV-M, RV-M, TV-M) from Hugging Face Simon7108528/EfficientSAM3, folder efficientsam3_ft/.
It needs PyTorch and the EfficientSAM3 code (github.com/SimonZeng7108/efficientsam3, its sam3/
folder importable, e.g. through a .pth file). EV-M: about 4 s per frame on the same laptop, TV-M 5 to 6 s.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import time
from pathlib import Path

import numpy as np
from ai_edge_litert.interpreter import Interpreter
from PIL import Image
from transformers import CLIPTokenizer

SIDE = 1008
FEATURES = 256 * (288 * 288 + 144 * 144 + 72 * 72)


def load(path, threads=8):
    it = Interpreter(model_path=str(path), num_threads=threads)
    it.allocate_tensors()
    return it


def run(it, x):
    d = it.get_input_details()[0]
    it.set_tensor(d["index"], np.ascontiguousarray(x.reshape(d["shape"]), np.float32))
    it.invoke()
    return it.get_tensor(it.get_output_details()[0]["index"]).ravel()


def text_memory(sam3_dir: Path, ids: list[int]) -> np.ndarray:
    """From prompts/<ids>.f32 (make_prompts.py, or the phone's), else the text model."""
    f = sam3_dir / "prompts" / f"{'_'.join(map(str, ids))}.f32"
    if f.exists():
        return np.fromfile(f, "<f4")
    table = np.memmap(sam3_dir / "sam3_token_embed.bin", np.float16, "r").reshape(-1, 1024)
    padded = ids + [0] * (32 - len(ids))
    return run(load(sam3_dir / "sam3_text.tflite", 4), table[padded].astype(np.float32)[None])


def sam3_detector(sam3_dir: Path, prompt: str, threads: int):
    """SAM 3 from the LiteRT files. The returned function takes the prepared picture and gives,
    for SAM 3's 200 candidates, probability (score x presence) and box (centre x, centre y,
    width, height; 0..1), plus the presence score ("prompt is in the picture")."""
    tok = CLIPTokenizer(str(sam3_dir / "vocab.json"), str(sam3_dir / "merges.txt"))
    ids = tok(prompt)["input_ids"][:32]
    tail = np.concatenate([text_memory(sam3_dir, ids),
                           (np.array(ids + [0] * (32 - len(ids))) == 0).astype(np.float32)])
    vision = load(sam3_dir / "sam3_vision.tflite", threads)
    head = load(sam3_dir / "sam3_head.tflite", threads)

    def detect(x):
        y = run(head, np.concatenate([run(vision, x), tail]))
        presence = 1 / (1 + np.exp(-y[1000]))
        return presence / (1 + np.exp(-y[:200])), y[200:1000].reshape(200, 4), presence

    return detect


# Picture model of each released full EfficientSAM3 (EV-M, RV-M, TV-M); all use the MobileCLIP-S0
# text model with 16 tokens (read from the EV-M checkpoint and the project's README).
EFFICIENTSAM3 = {"efficientvit": "b1", "repvit": "m1.1", "tinyvit": "11m"}


def efficientsam3_detector(ckpt: Path, prompt: str, threads: int):
    """EfficientSAM3 (PyTorch), same inputs and outputs as sam3_detector."""
    import sys
    import types

    import torch

    # The code imports a video reader that only its training uses; a stand-in avoids installing one.
    sys.modules.setdefault("decord", types.SimpleNamespace(cpu=None, VideoReader=None))
    from sam3.model_builder import build_efficientsam3_image_model
    from sam3.model.sam3_image_processor import Sam3Processor

    torch.set_num_threads(threads)
    backbone = next(b for b in EFFICIENTSAM3 if b in ckpt.name)
    model = build_efficientsam3_image_model(
        checkpoint_path=str(ckpt), backbone_type=backbone, model_name=EFFICIENTSAM3[backbone],
        text_encoder_type="MobileCLIP-S0", text_encoder_context_length=16, device="cpu",
        enable_segmentation=False)  # boxes only: skips the mask head
    find = Sam3Processor(model, device="cpu").find_stage
    with torch.inference_mode():
        text = model.backbone.forward_text([prompt], device="cpu")

    @torch.inference_mode()
    def detect(x):
        features = model.backbone.forward_image(torch.from_numpy(x))
        features.update(text)
        out = model.forward_grounding(backbone_out=features, find_input=find,
                                      geometric_prompt=model._get_dummy_prompt(), find_target=None)
        presence = out["presence_logit_dec"].sigmoid().item()
        return presence * out["pred_logits"][0, :, 0].sigmoid().numpy(), out["pred_boxes"][0].numpy(), presence

    return detect


def frames(video: Path, numbers: list[int], roi_px: list[int]):
    """Yields the upright, cropped RGB frames with display numbers `numbers` (ascending)."""
    x, y, w, h = roi_px
    expr = "+".join(f"eq(n\\,{n})" for n in numbers)
    # -ignore_editlist: Android's decoder (and so the app) numbers every frame in the file; ffmpeg
    # would otherwise leave out frames outside the file's edit list (the last two of a test clip).
    cmd = ["ffmpeg", "-v", "error", "-ignore_editlist", "1", "-i", str(video),
           "-vf", f"select='{expr}',crop={w}:{h}:{x}:{y}",
           "-vsync", "0", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    size = w * h * 3
    for n in numbers:
        buf = p.stdout.read(size)
        if len(buf) < size:
            raise RuntimeError(f"ffmpeg gave no picture for frame {n}")
        yield n, np.frombuffer(buf, np.uint8).reshape(h, w, 3)
    p.stdout.close()
    p.wait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session", type=Path)
    model_arg = ap.add_mutually_exclusive_group(required=True)
    model_arg.add_argument("--sam3-dir", type=Path)
    model_arg.add_argument("--efficientsam3", type=Path, metavar="CKPT")
    ap.add_argument("--prompt", default="insect")
    ap.add_argument("--confidence", type=float, default=0.5)
    ap.add_argument("--iou", type=float, default=0.7)
    ap.add_argument("--fps", type=float, help="default: the earlier run's rate")
    ap.add_argument("--threads", type=int, default=4, help="more is faster but heats the laptop")
    ap.add_argument("--out", type=Path)
    a = ap.parse_args()
    if a.efficientsam3:
        model_id, model_name = a.efficientsam3.stem, f"EfficientSAM3 {a.efficientsam3.stem}"
    else:
        model_id, model_name = "sam3", "SAM 3"
    out = a.out or a.session / model_id / "video_detections.jsonl"
    out.parent.mkdir(parents=True, exist_ok=True)

    ref = [json.loads(line) for line in open(a.session / "video_detections.jsonl")]
    start = next(r for r in ref if r["type"] == "video_run_start")
    clip_start = next(r for r in ref if r["type"] == "video_clip_start")
    clip_done = next(r for r in ref if r["type"] == "video_clip_done")
    fps = a.fps or start["settings"]["analysis_fps"]
    dets = thin([r for r in ref if r["type"] == "raw_detections"], fps)
    fw, fh = clip_done["frame_width"], clip_done["frame_height"]
    roi_px = clip_done["roi_px"]

    done = set()
    if out.exists():
        old = [json.loads(line) for line in open(out)]
        if any(r["type"] == "video_run_end" for r in old):
            print(f"{out} is complete")
            return
        done = {r["frame"] for r in old if r["type"] == "raw_detections"}
    log = open(out, "a")

    def write(rec):
        log.write(json.dumps(rec, separators=(",", ":")) + "\n")
        log.flush()

    now = lambda: int(time.time() * 1000)
    if not done:
        settings = dict(start["settings"], model=model_id, confidence=a.confidence, iou=a.iou,
                        analysis_fps=fps, prompt=a.prompt)
        runtime = "PyTorch" if a.efficientsam3 else "ai-edge-litert"
        write({"type": "video_run_start", "time_ms": now(), "settings": settings,
               "model_name": f'{model_name}, prompt "{a.prompt}"', "use_gpu": False,
               "clips_total": 1, "clips_pending": 1,
               "app_version": f"PC: tool/sam3/detect_video.py ({runtime}, CPU)"})
        write(dict(clip_start, time_ms=now()))

    if a.efficientsam3:
        detect = efficientsam3_detector(a.efficientsam3, a.prompt, a.threads)
    else:
        detect = sam3_detector(a.sam3_dir, a.prompt, a.threads)
    todo = [r for r in dets if r["frame"] not in done]
    t_run = time.time()
    for k, (n, rgb) in enumerate(frames(a.session / "videos" / clip_start["clip"], [r["frame"] for r in todo], roi_px)):
        rec = todo[k]
        assert rec["frame"] == n
        img = Image.fromarray(rgb).resize((SIDE, SIDE), Image.BILINEAR)
        x = ((np.asarray(img, np.float32) / 255 - 0.5) / 0.5).transpose(2, 0, 1)[None]
        prob, cxcywh, presence = detect(x)
        boxes = []
        for q in np.argsort(-prob):
            if prob[q] < a.confidence:
                break
            cx, cy, bw, bh = map(float, cxcywh[q])
            l, t, r, b = [min(max(v, 0.0), 1.0) for v in (cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2)]
            box = [l * roi_px[2], t * roi_px[3], r * roi_px[2], b * roi_px[3]]
            if any(_iou(box, kept) > a.iou for kept in boxes):
                continue
            boxes.append(box + [float(prob[q])])
        write({"type": "raw_detections", "time_ms": now(), "frame_ms": rec["frame_ms"], "clip": rec["clip"],
               "pts_us": rec["pts_us"], "frame": n, "presence": round(float(presence), 4),
               "boxes": [[round((roi_px[0] + b[0]) / fw, 4), round((roi_px[1] + b[1]) / fh, 4),
                          round((roi_px[0] + b[2]) / fw, 4), round((roi_px[1] + b[3]) / fh, 4),
                          round(b[4], 4), 0] for b in boxes]})
        per = (time.time() - t_run) / (k + 1)
        print(f"frame {n} ({len(done) + k + 1}/{len(dets)}): {len(boxes)} boxes, presence {presence:.2f}, "
              f"{per:.0f} s/frame, about {(len(todo) - k - 1) * per / 3600:.1f} h left", flush=True)
    write(dict(clip_done, time_ms=now(), frames_analysed=len(dets), class_names=[a.prompt]))
    write({"type": "video_run_end", "time_ms": now(), "clips_done": 1, "clips_failed": 0,
           "frames_analysed": len(dets), "ended_normally": True})


def thin(records, fps):
    """The phone's frame picker: a frame is taken once its time stamp reaches the next deadline
    (1/10 of the interval early is fine); after a long gap the grid restarts at that frame."""
    interval = round(1e6 / fps)
    due = None
    kept = []
    for r in records:
        pts = r["pts_us"]
        if due is not None and pts < due - interval // 10:
            continue
        due = pts + interval if due is None or pts - due >= interval else due + interval
        kept.append(r)
    return kept


def _iou(a, b):
    iw = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    ih = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = iw * ih
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


if __name__ == "__main__":
    main()
