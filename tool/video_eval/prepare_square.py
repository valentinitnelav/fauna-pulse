#!/usr/bin/env python3
"""Prepare a video for hand annotation in VIA3: crop it to the target square (round 272).

The target square is the area around the flower that is annotated by hand AND analysed by the
app. The cropped copy is used for both: it is annotated in VIA3 and imported into the app,
where "Find animals in videos" runs on the whole picture. So the app sees exactly the pixels
that were annotated.

Steps (docs/VIDEO_ANALYSIS.md, section 3):

  1. squares  one VIA3 project with all the videos: play them, pause, and draw ONE rectangle
              per video around the flower, as the ROI square is placed on the phone; save.
              The rectangle becomes a square with the same centre and the longer side, moved
              inside the picture, at most the picture's height. No rectangle = not cropped.
  2. crop     --from-via the saved project: each square as a new video (same frames, same
              times; checked), a preview picture of it, and everything for annotation: a VIA3
              project for the timeline (pass 1) and positions (pass 2), and 30 snapshot
              pictures with their own VIA3 project (pass 0). Also by numbers: --x --y --side.
  range       optional help: one picture per video showing where the flower moves: left the
              brightest value of every pixel over the video (a bright flower shows its whole
              range of movement), right the middle frame; grid lines every 50 pixels.
  preview     a square given by numbers, drawn on that picture.
  annotate    the annotation files for a video that is not cropped: already square (for
              example clips the app recorded itself), or the whole picture.

Usage (a folder stands for every video file in it; subfolders are not searched):
  python3 prepare_square.py squares ~/videos/
  python3 prepare_square.py crop --from-via ~/Downloads/via_project_....json
  python3 prepare_square.py crop VIDEO.mp4 --x 180 --y 60 --side 320
  python3 prepare_square.py annotate ~/videos/  (or single videos)
  python3 prepare_square.py range ~/videos/
  python3 prepare_square.py preview VIDEO.mp4 --x 180 --y 60 --side 320

Everything is written into an "eval" folder next to the videos (a video that already lies in
a folder called "eval" keeps its files there), unless --out names another folder. Cropped
copies (names ending in "_square") are never taken as input again.

The VIA3 projects keep the folder once (VIA3's "location prefix") and only the file names
per file. After moving a folder, VIA3 says it cannot load the file and shows the file's
settings: type the new folder into the field next to "File Location", click "Reload File",
and save the project. Needs ffmpeg and ffprobe; otherwise only the Python standard library
(3.8+).
"""
import argparse
import json
import random
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote, unquote, urlparse

HERE = Path(__file__).resolve().parent
VIDEO_TEMPLATE = HERE / "via3" / "video_template.json"
SNAPSHOT_TEMPLATE = HERE / "via3" / "snapshots_template.json"
SQUARES_TEMPLATE = HERE / "via3" / "squares_template.json"
GRID_PX = 50
VIDEO_SUFFIXES = {".mp4", ".m4v", ".mov", ".mkv", ".webm", ".avi"}
SNAPSHOT_BLOCK_S = 10.0


class InputError(Exception):
    """A problem with the input, explained in plain words."""


def run(cmd):
    """Run a command; raise InputError with its last error lines when it fails."""
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        tail = "\n".join(p.stderr.strip().splitlines()[-5:])
        raise InputError(f"{cmd[0]} failed:\n{tail}")
    return p.stdout


def probe(video):
    """Width, height and the sorted frame times (s) of the first video stream.

    Frame times come from the packets (no decoding), sorted, so they are in display order.
    """
    info = json.loads(run([
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,pix_fmt", "-of", "json", str(video),
    ]))
    if not info.get("streams"):
        raise InputError(f"{video}: no video stream")
    s = info["streams"][0]
    out = run([
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "packet=pts_time", "-of", "csv=p=0", str(video),
    ])
    times = sorted(float(x) for x in out.split() if x.strip() not in ("", "N/A"))
    if not times:
        raise InputError(f"{video}: no frame times")
    return {"width": int(s["width"]), "height": int(s["height"]), "pix_fmt": s.get("pix_fmt", ""), "times": times}


def check_square(x, y, side, width, height):
    """Square inside the picture, even numbers (needed for the usual 4:2:0 colour format)."""
    if side <= 0 or x < 0 or y < 0:
        raise InputError("x, y and side must be positive")
    if x % 2 or y % 2 or side % 2:
        raise InputError("x, y and side must be even numbers")
    if x + side > width or y + side > height:
        raise InputError(f"the square ({x}, {y}, side {side}) leaves the {width}×{height} picture")


def range_filter(step_s):
    """ffmpeg filter over two inputs of the same video: brightest value of every pixel over frames
    every step_s (lagfun with decay 1 keeps the maximum), beside the middle frame (second input,
    already sought there). hstack repeats the single middle frame until the first input ends."""
    grid = f"drawgrid=w={GRID_PX}:h={GRID_PX}:t=1:c=yellow@0.6"
    return (
        f"[0:v]fps=1/{step_s},format=gbrp,lagfun=decay=1,{grid}[mx];"
        f"[1:v]trim=end_frame=1,format=gbrp,{grid}[mid];"
        "[mx][mid]hstack=shortest=0"
    )


def range_inputs(video, duration):
    """ffmpeg inputs for range_filter: the whole video, then the same video from its middle."""
    return ["-i", str(video), "-ss", f"{duration / 2:.3f}", "-t", "1", "-i", str(video)]


def range_image(video, out_dir, step_s=2.0):
    """<stem>_range.jpg: where the flower moves (left: brightest, right: middle frame; grid every 50 px)."""
    info = probe(video)
    out = Path(out_dir) / f"{Path(video).stem}_range.jpg"
    run([
        "ffmpeg", "-v", "error", "-y", *range_inputs(video, info["times"][-1] - info["times"][0]),
        "-filter_complex", range_filter(step_s), "-update", "1", "-q:v", "2", str(out),
    ])
    return out


def preview_image(video, out_dir, x, y, side, step_s=2.0):
    """<stem>_square_preview.jpg: the range picture with the square drawn in red on both halves."""
    info = probe(video)
    check_square(x, y, side, info["width"], info["height"])
    out = Path(out_dir) / f"{Path(video).stem}_square_preview.jpg"
    w = info["width"]
    box = f"drawbox=x={x}:y={y}:w={side}:h={side}:c=red:t=2"
    box2 = f"drawbox=x={x + w}:y={y}:w={side}:h={side}:c=red:t=2"
    run([
        "ffmpeg", "-v", "error", "-y", *range_inputs(video, info["times"][-1] - info["times"][0]),
        "-filter_complex", f"{range_filter(step_s)},{box},{box2}", "-update", "1", "-q:v", "2", str(out),
    ])
    return out


def crop_video(video, out_dir, x, y, side):
    """<stem>_square.mp4 (H.264, high quality, no sound) with the same frames and frame times."""
    src = probe(video)
    check_square(x, y, side, src["width"], src["height"])
    out = Path(out_dir) / f"{Path(video).stem}_square.mp4"
    run([
        "ffmpeg", "-v", "error", "-y", "-i", str(video), "-map", "0:v:0",
        "-vf", f"crop={side}:{side}:{x}:{y}", "-c:v", "libx264", "-crf", "14", "-preset", "slow",
        "-pix_fmt", "yuv420p", "-fps_mode", "passthrough", "-an", "-movflags", "+faststart", str(out),
    ])
    dst = probe(out)
    same_count = len(dst["times"]) == len(src["times"])
    shift = dst["times"][0] - src["times"][0]
    max_err = max(abs(b - a - shift) for a, b in zip(src["times"], dst["times"])) if same_count else None
    if not same_count or max_err > 0.002:
        raise InputError(
            f"{out}: the cropped video does not have the same frames "
            f"({len(src['times'])} → {len(dst['times'])} frames, largest time difference {max_err}); "
            "it was not used"
        )
    meta = {
        "source": str(Path(video).resolve()),
        "source_size": [src["width"], src["height"]],
        "square": {"x": x, "y": y, "side": side},
        "frames": len(dst["times"]),
        "first_frame_s": dst["times"][0],
        "source_first_frame_s": src["times"][0],
        "max_time_error_s": round(max_err, 6),
    }
    Path(out).with_suffix(".json").write_text(json.dumps(meta, indent=2) + "\n")
    return out


def snapshot_frames(times, clip_key, n=30, block_s=SNAPSHOT_BLOCK_S, seed=1):
    """Frame numbers for pass 0: one at a random time inside each block of block_s seconds.

    Random but repeatable: the same video, seed and n always give the same frames. Blocks
    without a frame (a gap in the video) are skipped; at most n frames.
    """
    rng = random.Random(f"{seed}:{clip_key}")
    t0, t_end = times[0], times[-1]
    picks, k = [], 0
    while len(picks) < n and t0 + k * block_s <= t_end:
        lo, hi = t0 + k * block_s, t0 + (k + 1) * block_s
        inside = [i for i, t in enumerate(times) if lo <= t < hi]
        if inside:
            picks.append(rng.choice(inside))
        k += 1
    return picks


def snapshot_name(stem, t, frame):
    """Picture name holding clip, time and frame, read back by via3_to_hand_count.py."""
    return f"{stem}__t{t:08.3f}__f{frame:05d}.jpg"


def extract_snapshots(video, out_dir, n=30, seed=1):
    """Save the pass-0 pictures in <stem>_snapshots/; return their paths in time order."""
    info = probe(video)
    stem = Path(video).stem
    frames = snapshot_frames(info["times"], stem, n=n, seed=seed)
    folder = Path(out_dir) / f"{stem}_snapshots"
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    expr = "+".join(f"eq(n\\,{f})" for f in frames)
    run([
        "ffmpeg", "-v", "error", "-y", "-i", str(video), "-vf", f"select={expr}",
        "-fps_mode", "passthrough", "-q:v", "2", str(folder / "tmp_%03d.jpg"),
    ])
    made = sorted(folder.glob("tmp_*.jpg"))
    if len(made) != len(frames):
        raise InputError(f"{video}: expected {len(frames)} snapshot pictures, ffmpeg wrote {len(made)}")
    paths = []
    for tmp, f in zip(made, sorted(frames)):
        target = folder / snapshot_name(stem, info["times"][f] - info["times"][0], f)
        tmp.rename(target)
        paths.append(target)
    return paths


def expand_videos(items):
    """Video files from the arguments: files as given, folders as every video file in them
    (sorted, no subfolders), cropped copies ("_square") left out."""
    out = []
    for item in items:
        path = Path(item).expanduser()
        if path.is_dir():
            found = sorted(f for f in path.iterdir() if f.is_file() and f.suffix.lower() in VIDEO_SUFFIXES
                           and not f.stem.endswith("_square"))
            if not found:
                raise InputError(f"{path}: no video files in this folder")
            out += found
        elif path.is_file():
            out.append(path)
        else:
            raise InputError(f"{path}: no such file or folder")
    return list(dict.fromkeys(f.resolve() for f in out))


def default_out(video):
    """The "eval" folder next to a video, or the video's own folder when it is called "eval"."""
    folder = Path(video).resolve().parent
    return folder if folder.name == "eval" else folder / "eval"


def via3_project(template, name, files, file_type):
    """A VIA3 project from a template, one view per file. Files in one folder: the folder is
    VIA3's location prefix (one place to change after moving it) and src only the file name;
    files from several folders keep their full paths."""
    p = json.loads(Path(template).read_text())
    p["project"]["pname"] = name
    p["project"]["data_format_version"] = "3.1.1"
    p["project"]["vid_list"] = [str(i) for i in range(1, len(files) + 1)]
    files = [Path(f).resolve() for f in files]
    folders = {f.parent for f in files}
    one_folder = len(folders) == 1
    p["config"]["file"]["loc_prefix"]["3"] = quote(f"{folders.pop()}/") if one_folder else ""
    for i, f in enumerate(files, start=1):
        p["file"][str(i)] = {
            "fid": i, "fname": f.name, "type": file_type, "loc": 3,
            "src": quote(f.name) if one_folder else f.as_uri(),
        }
        p["view"][str(i)] = {"fid_list": [i]}
    return p


def file_path(project, entry):
    """The local path of a VIA3 file entry: location prefix + src, plain path or file:// URI."""
    prefix = (project.get("config", {}).get("file", {}).get("loc_prefix") or {}).get(str(entry.get("loc")), "")
    full = f"{prefix}{entry['src']}"
    return Path(unquote(urlparse(full).path if full.startswith("file:") else full))


def refuse_annotated(path):
    """Never overwrite a project that already holds annotations (a saved VIA3 file put back here)."""
    try:
        has_work = bool(json.loads(Path(path).read_text()).get("metadata"))
    except (OSError, ValueError):
        return
    if has_work:
        raise InputError(f"{path} already holds annotations; move it away first, it was not overwritten")


def project_paths(stem, out_dir):
    """The two annotation projects of a video stem; refuses when either holds annotations."""
    paths = (Path(out_dir) / f"{stem}_via3.json", Path(out_dir) / f"{stem}_snapshots_via3.json")
    for path in paths:
        refuse_annotated(path)
    return paths


def annotation_files(video, out_dir, n=30, seed=1):
    """VIA3 video project (passes 1-2), snapshot pictures and their VIA3 project (pass 0)."""
    stem = Path(video).stem
    video_project, snap_project = project_paths(stem, out_dir)
    video_project.write_text(json.dumps(via3_project(VIDEO_TEMPLATE, stem, [video], 4), indent=1) + "\n")
    pictures = extract_snapshots(video, out_dir, n=n, seed=seed)
    snap_project.write_text(
        json.dumps(via3_project(SNAPSHOT_TEMPLATE, f"{stem} snapshots", pictures, 2), indent=1) + "\n"
    )
    return video_project, snap_project, pictures


def square_from_rect(x, y, w, h, width, height):
    """The square for a rectangle drawn in VIA3: same centre, the longer side (at most the
    picture's shorter side), moved inside the picture; even numbers."""
    side = int(min(max(w, h), width, height)) // 2 * 2
    if side < 2:
        raise InputError("the rectangle is too small")
    cx, cy = x + w / 2, y + h / 2
    sx = min(max(int(round(cx - side / 2)), 0), width - side) // 2 * 2
    sy = min(max(int(round(cy - side / 2)), 0), height - side) // 2 * 2
    return sx, sy, side


def squares_project(videos, out_dir):
    """squares_via3.json: all videos in one VIA3 project, to draw one rectangle on each."""
    path = Path(out_dir) / "squares_via3.json"
    refuse_annotated(path)
    path.write_text(json.dumps(via3_project(SQUARES_TEMPLATE, "Target squares", videos, 4), indent=1) + "\n")
    return path


def squares_from_project(path):
    """(video path, rectangle (x, y, w, h) or None) per video of a saved squares project."""
    try:
        d = json.loads(Path(path).read_text())
        files, views, metadata = d["file"], d["view"], d["metadata"]
    except (OSError, ValueError, KeyError) as e:
        raise InputError(f"{path}: cannot read it as a VIA3 project ({e})")
    out = []
    for vid, view in views.items():
        f = files[str(view["fid_list"][0])]
        if f.get("type") != 4:
            continue
        video = file_path(d, f)
        if not video.is_file():
            raise InputError(
                f"{video}: not found. If the videos were moved, open the project in VIA3, type the new "
                "folder next to 'File Location', click 'Reload File' and save the project again"
            )
        rects = [m["xy"][1:5] for m in metadata.values()
                 if str(m.get("vid")) == vid and (m.get("xy") or [None])[0] == 2]
        if len(rects) > 1:
            raise InputError(f"{f['fname']}: {len(rects)} rectangles; keep only one (select the others and press Delete)")
        out.append((video, rects[0] if rects else None))
    return out


def crop_and_annotate(video, out_dir, x, y, side, n=30, seed=1):
    """Check that no annotation would be lost, then crop, preview, and make the annotation files."""
    project_paths(f"{Path(video).stem}_square", out_dir)  # refuse before anything is overwritten
    square = crop_video(video, out_dir, x, y, side)
    preview = preview_image(video, out_dir, x, y, side)
    return [square, preview, *annotation_files(square, out_dir, n=n, seed=seed)[:2]]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    q = sub.add_parser("squares", help="one VIA3 project to draw a rectangle on each video")
    q.add_argument("videos", nargs="+", help="video files or folders")
    r = sub.add_parser("range", help="where the flower moves: brightest picture and middle frame")
    r.add_argument("videos", nargs="+", help="video files or folders")
    pv = sub.add_parser("preview", help="draw a square given by numbers")
    c = sub.add_parser("crop", help="crop and prepare annotation")
    c.add_argument("--from-via", help="saved squares project (from 'squares'): crop every video in it")
    for p in (pv, c):
        p.add_argument("video", nargs="?" if p is c else None)
        p.add_argument("--x", type=int, required=p is pv, help="left edge of the square, pixels")
        p.add_argument("--y", type=int, required=p is pv, help="top edge of the square, pixels")
        p.add_argument("--side", type=int, required=p is pv, help="side of the square, pixels")
    a = sub.add_parser("annotate", help="annotation files for videos that are not cropped")
    a.add_argument("videos", nargs="+", help="video files or folders")
    for p in (q, r, pv, c, a):
        p.add_argument("--out", help='output folder (default: "eval" next to the videos)')
    for p in (c, a):
        p.add_argument("--snapshots", type=int, default=30, help="pass-0 pictures (default 30)")
        p.add_argument("--seed", type=int, default=1, help="changes which random frames are picked")
    args = ap.parse_args(argv)

    def out_for(video):
        folder = Path(args.out).expanduser() if args.out else default_out(video)
        folder.mkdir(parents=True, exist_ok=True)
        return folder

    try:
        if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
            raise InputError("ffmpeg and ffprobe are needed (for example: sudo apt install ffmpeg)")
        if args.cmd == "squares":
            videos = expand_videos(args.videos)
            print(squares_project(videos, out_for(videos[0])))
        elif args.cmd == "range":
            for v in expand_videos(args.videos):
                print(range_image(v, out_for(v)))
        elif args.cmd == "preview":
            print(preview_image(args.video, out_for(args.video), args.x, args.y, args.side))
        elif args.cmd == "annotate":
            for v in expand_videos(args.videos):
                for f in annotation_files(v, out_for(v), n=args.snapshots, seed=args.seed)[:2]:
                    print(f)
        elif args.from_via:
            if args.video or args.x is not None:
                raise InputError("give either --from-via or a video with --x --y --side, not both")
            jobs = []
            for video, rect in squares_from_project(args.from_via):
                if rect is None:
                    print(f"{video.name}: no rectangle drawn, not cropped "
                          f"(for the whole picture: prepare_square.py annotate {video})")
                    continue
                info = probe(video)
                x, y, side = square_from_rect(*rect, info["width"], info["height"])
                print(f"{video.name}: drawn x {rect[0]:.0f}, y {rect[1]:.0f}, {rect[2]:.0f}×{rect[3]:.0f} "
                      f"→ square x {x}, y {y}, side {side}")
                jobs.append((video, x, y, side))
            for video, x, y, side in jobs:
                for f in crop_and_annotate(video, out_for(video), x, y, side, n=args.snapshots, seed=args.seed):
                    print(f)
        else:
            if not args.video or None in (args.x, args.y, args.side):
                raise InputError("crop needs --from-via, or a video with --x --y --side")
            for f in crop_and_annotate(args.video, out_for(args.video), args.x, args.y, args.side,
                                       n=args.snapshots, seed=args.seed):
                print(f)
    except InputError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
