#!/usr/bin/env python3
"""Turn the app's MOT files into a first draft for CVAT (round 230).

"Share results" holds mot/<clip>.txt: every tracked box in the MOTChallenge
results layout (frame,id,x,y,w,h,conf,-1,-1,-1), which tracking benchmarks
read as is. CVAT's "MOT 1.1" import reads columns 7 and 8 differently ("not
ignored" and the class number in labels.txt; -1 gives a box without a label,
which CVAT cannot place). This script writes one zip per clip that CVAT
accepts: gt/gt.txt with each track's class taken from visits.csv, and
gt/labels.txt.

In CVAT: create a task from the same video file, with labels named as printed
at the end, then Actions > Upload annotations > MOT 1.1 > the clip's zip.
Each visit arrives as one track. Correct the boxes, add what the app missed
(also each visit's first frames: tracks show up only once confirmed), set the
taxon, and export.

Usage:
  python3 mot_to_cvat.py results_folder [--out folder]
results_folder is the unzipped "Share results" file (visits.csv and mot/);
the zips go to results_folder/cvat unless --out says otherwise.

Standard library only (Python 3.8+). Guide: docs/VIDEO_ANALYSIS.md.
"""
import argparse
import csv
import sys
import zipfile
from pathlib import Path


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("folder", help="unzipped Share results file (visits.csv and mot/)")
    ap.add_argument("--out", help="where to write the zips (default: <folder>/cvat)")
    args = ap.parse_args(argv)
    folder = Path(args.folder)
    mot = folder / "mot"
    if not mot.is_dir():
        sys.exit(f"Error: no mot/ folder in {folder}")
    track_class = {}
    visits = folder / "visits.csv"
    if visits.is_file():
        with visits.open(newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                track_class[r["track_id"]] = r.get("class") or "insect"
    labels = sorted(set(track_class.values())) or ["insect"]
    out = Path(args.out) if args.out else folder / "cvat"
    out.mkdir(parents=True, exist_ok=True)
    for txt in sorted(mot.glob("*.txt")):
        rows = []
        for line in txt.read_text(encoding="utf-8").splitlines():
            c = line.split(",")
            if len(c) < 6:
                continue
            cls = track_class.get(c[1], labels[0])
            # frame, id, x, y, w, h, not ignored, class (from 1), visibility
            rows.append(",".join(c[:6] + ["1", str(labels.index(cls) + 1), "1"]))
        zip_path = out / f"{txt.stem}.zip"
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("gt/gt.txt", "".join(r + "\n" for r in rows))
            z.writestr("gt/labels.txt", "".join(name + "\n" for name in labels))
        print(f"{zip_path}: {len(rows)} boxes")
    print("Labels to create in the CVAT task: " + ", ".join(labels))


if __name__ == "__main__":
    main()
