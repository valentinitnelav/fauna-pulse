#!/usr/bin/env python3
"""Turn VIA3 annotation projects into hand-count tables for the scoring scripts (round 272).

Reads project files saved by the VIA3 video annotator (made from via3/video_template.json by
prepare_square.py) and by the VIA3 image annotator (via3/snapshots_template.json, the pass-0
snapshot pictures). Attributes are found by their names, so options or attributes added in
VIA3 itself are fine.

Video projects (passes 1 and 2; docs/VIDEO_ANALYSIS.md section 3):
  * each timeline row of the attribute "insect" is one insect (one individual); each time
    segment in that row is one appearance (the insect visible inside the square);
  * the row "ignore" marks time left out of all scores;
  * points or boxes on video frames are pass-2 positions of the insect whose timeline row was
    selected while drawing them (or whose row name was typed into the point's "insect" field);
  * only videos whose "watched" attribute is "whole video" are written (--include-unfinished
    writes the others too). A watched video without any appearance gets one row with the clip
    and no times: "watched, no insect", the convention evaluate_track_ids.py already reads.

Snapshot projects (pass 0): one row per picture marked "counted", with the number of points
(insects) in it. The clip, time and frame come from the picture name prepare_square.py gave it.

Output files in --out (default: the first project's folder):
  hand_count.csv       clip, start_s, end_s, taxon, insect, focus, size, sure, edge, on_flower, note
                       (one row per appearance; evaluate_track_ids.py reads it)
  ignore_spans.csv     clip, start_s, end_s, note
  positions.csv        clip, insect, t_s, x, y, w, h  (pixels of the annotated video; x, y = centre)
  snapshots.csv        clip, t_s, frame, picture, n_insects, n_edge, note
  snapshot_points.csv  clip, t_s, frame, x, y, focus, edge

--draft DRAFT.json compares a corrected project with the AI draft it started from (made by
detect_video_pc.py) and prints how many appearances and positions were kept, changed,
deleted and added.

Usage:
  python3 via3_to_hand_count.py eval/*_via3.json --out eval/truth
  python3 via3_to_hand_count.py eval/DAUCUS_square_via3.json --draft eval/DAUCUS_square_draft_via3.json

Standard library only (Python 3.8+).
"""
import argparse
import csv
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

VIDEO, IMAGE = 4, 2
POINT, RECT, CIRCLE, ELLIPSE = 1, 2, 3, 4
SEGMENT_ANCHOR, REGION_IN_FRAME, REGION_IN_IMAGE, FILE_ANCHOR = "FILE1_Z2_XY0", "FILE1_Z1_XY1", "FILE1_Z0_XY1", "FILE1_Z0_XY0"
SEGMENT_FIELDS = ("taxon", "focus", "size", "sure", "edge", "on_flower", "note")
SNAPSHOT_NAME = re.compile(r"^(?P<clip>.+)__t(?P<t>\d+(?:\.\d+)?)__f(?P<frame>\d+)\.[A-Za-z]+$")


class InputError(Exception):
    """A problem with the input files, explained in plain words."""


class Project:
    """One VIA3 project file: attribute lookup by name, values as the option text."""

    def __init__(self, path):
        self.path = Path(path)
        try:
            self.d = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            raise InputError(f"{path}: cannot read it as a VIA3 project ({e})")
        for key in ("attribute", "file", "view", "metadata"):
            if key not in self.d:
                raise InputError(f"{path}: not a VIA3 project (no '{key}')")
        self.attrs = self.d["attribute"]

    def aid(self, name, anchor):
        for aid, a in self.attrs.items():
            if a.get("aname", "").strip().lower() == name and a.get("anchor_id") == anchor:
                return aid
        return None

    def value(self, av, aid):
        """The option text of a select/radio/checkbox value, or the typed text."""
        if aid is None or aid not in av:
            return ""
        raw = str(av[aid]).strip()
        options = self.attrs[aid].get("options") or {}
        if self.attrs[aid].get("type") == 2:  # checkbox: comma-separated option ids
            return ";".join(options.get(v, v) for v in raw.split(",") if v)
        return str(options.get(raw, raw)).strip()

    def files_by_view(self):
        """view id -> file entry (VIA3 views hold one file here)."""
        out = {}
        for vid, view in self.d["view"].items():
            fids = view.get("fid_list") or []
            if fids:
                out[vid] = self.d["file"][str(fids[0])]
        return out


def centre(xy):
    """(x, y, w, h) of a VIA3 shape: centre, and width/height for boxes (else None)."""
    shape, c = xy[0], [float(v) for v in xy[1:]]
    if shape == RECT and len(c) >= 4:
        return c[0] + c[2] / 2, c[1] + c[3] / 2, c[2], c[3]
    if shape in (POINT, CIRCLE, ELLIPSE) and len(c) >= 2:
        return c[0], c[1], None, None
    if len(c) >= 2:  # polygon, polyline, line: mean of the corner points
        xs, ys = c[0::2], c[1::2]
        return sum(xs) / len(xs), sum(ys) / len(ys), None, None
    return None


def read_video_project(p, warn):
    """Per clip: watched flag, appearances, ignore spans, positions."""
    insect_aid = p.aid("insect", SEGMENT_ANCHOR)
    if insect_aid is None:
        raise InputError(f"{p.path}: no timeline attribute 'insect' (was the project made from via3/video_template.json?)")
    field_aid = {f: p.aid(f, SEGMENT_ANCHOR) for f in SEGMENT_FIELDS}
    region_aid = p.aid("insect", REGION_IN_FRAME)
    watched_aid = p.aid("watched", FILE_ANCHOR)
    files = p.files_by_view()
    clips = {}
    for vid, f in files.items():
        if f.get("type") == VIDEO:
            clips[vid] = {"clip": f["fname"], "watched": False, "appear": [], "ignore": [], "pos": []}
    for mid, m in p.d["metadata"].items():
        c = clips.get(str(m.get("vid")))
        if c is None:
            continue
        z, xy, av = m.get("z") or [], m.get("xy") or [], m.get("av") or {}
        if not z and not xy:
            c["watched"] = p.value(av, watched_aid).lower() == "whole video"
        elif len(z) >= 2 and not xy:
            insect = p.value(av, insect_aid)
            if not insect:
                warn(f"{c['clip']}: time segment {z[0]:.3f}-{z[1]:.3f} s has no insect row; left out")
                continue
            row = {"mid": mid, "start_s": float(z[0]), "end_s": float(z[1]), "insect": insect}
            row.update({f: p.value(av, field_aid[f]) for f in SEGMENT_FIELDS})
            (c["ignore"] if insect.lower() == "ignore" else c["appear"]).append(row)
        elif len(z) == 1 and xy:
            pos = centre(xy)
            # VIA3 labels a point or box with the timeline row selected while drawing it;
            # the typed attribute is the fallback.
            insect = p.value(av, region_aid) or p.value(av, insect_aid)
            if pos is None or not insect:
                warn(f"{c['clip']}: a position at {z[0]:.3f} s has no insect name; left out")
                continue
            x, y, w, h = pos
            c["pos"].append({"mid": mid, "insect": insect, "t_s": float(z[0]), "x": x, "y": y, "w": w, "h": h})
    return list(clips.values())


def tidy_clip(c, warn):
    """Fill empty taxa from the insect's other appearances; warn about doubtful entries."""
    by_insect = defaultdict(list)
    for a in c["appear"]:
        by_insect[a["insect"]].append(a)
    for insect, rows in by_insect.items():
        taxa = Counter(r["taxon"] for r in rows if r["taxon"])
        if len(taxa) > 1:
            warn(f"{c['clip']}: insect {insect} has different taxa {sorted(taxa)}; kept as annotated")
        elif taxa:
            only = next(iter(taxa))
            for r in rows:
                r["taxon"] = r["taxon"] or only
        rows.sort(key=lambda r: r["start_s"])
        for a, b in zip(rows, rows[1:]):
            if b["start_s"] < a["end_s"]:
                warn(f"{c['clip']}: insect {insect} has overlapping appearances at {b['start_s']:.3f} s (pressed twice?)")
    for a in c["appear"] + c["ignore"]:
        if a["end_s"] < a["start_s"]:
            warn(f"{c['clip']}: a time segment ends before it starts ({a['start_s']:.3f} s)")
    for q in c["pos"]:
        rows = by_insect.get(q["insect"])
        if not rows:
            warn(f"{c['clip']}: position at {q['t_s']:.3f} s names insect {q['insect']}, which has no timeline row")
        elif not any(r["start_s"] - 0.5 <= q["t_s"] <= r["end_s"] + 0.5 for r in rows):
            warn(f"{c['clip']}: position of insect {q['insect']} at {q['t_s']:.3f} s is outside its appearances")


def read_snapshot_project(p, warn):
    """Pass-0 rows (one per picture marked counted) and their points."""
    counted_aid, note_aid = p.aid("counted", FILE_ANCHOR), p.aid("note", FILE_ANCHOR)
    focus_aid, edge_aid = p.aid("focus", REGION_IN_IMAGE), p.aid("edge", REGION_IN_IMAGE)
    pics = {}
    for vid, f in p.files_by_view().items():
        if f.get("type") != IMAGE:
            continue
        m = SNAPSHOT_NAME.match(f["fname"])
        if not m:
            warn(f"{p.path.name}: picture {f['fname']} has no clip/time in its name; left out")
            continue
        pics[vid] = {"clip": m["clip"], "t_s": float(m["t"]), "frame": int(m["frame"]), "picture": f["fname"],
                     "counted": False, "note": "", "points": []}
    for m in p.d["metadata"].values():
        pic = pics.get(str(m.get("vid")))
        if pic is None:
            continue
        xy, av = m.get("xy") or [], m.get("av") or {}
        if not xy:
            pic["counted"] = pic["counted"] or p.value(av, counted_aid).lower() == "yes"
            pic["note"] = p.value(av, note_aid) or pic["note"]
        else:
            pos = centre(xy)
            if pos:
                pic["points"].append({"x": pos[0], "y": pos[1], "focus": p.value(av, focus_aid), "edge": p.value(av, edge_aid)})
    done = [pic for pic in pics.values() if pic["counted"]]
    if len(done) < len(pics):
        warn(f"{p.path.name}: {len(pics) - len(done)} of {len(pics)} pictures not marked 'counted'; left out")
    return done


def compare_with_draft(final, draft):
    """Kept / changed / deleted / added appearances and positions, by VIA3 metadata id."""
    def items(p):
        out = {}
        for mid, m in p.d["metadata"].items():
            z, xy = m.get("z") or [], m.get("xy") or []
            kind = "appearance" if len(z) >= 2 and not xy else "position" if len(z) == 1 and xy else None
            if kind:
                out[mid] = (kind, json.dumps([z, xy, m.get("av") or {}], sort_keys=True))
        return out
    a, b = items(draft), items(final)
    counts = Counter()
    for mid, (kind, sig) in a.items():
        if mid not in b:
            counts[(kind, "deleted")] += 1
        else:
            counts[(kind, "kept" if b[mid][1] == sig else "changed")] += 1
    for mid, (kind, _) in b.items():
        if mid not in a:
            counts[(kind, "added")] += 1
    return counts


def fmt(v):
    if v is None:
        return ""
    if isinstance(v, float):
        return f"{v:.3f}"
    return str(v)


def write_csv(path, header, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        for r in rows:
            w.writerow([fmt(r.get(h)) for h in header])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("projects", nargs="+", help="VIA3 project files (.json) saved by VIA3")
    ap.add_argument("--out", help="output folder (default: the first project's folder)")
    ap.add_argument("--include-unfinished", action="store_true", help="also write videos not marked 'whole video'")
    ap.add_argument("--draft", help="AI draft project the (single) project started from, to compare")
    args = ap.parse_args(argv)
    warnings = []
    warn = warnings.append
    try:
        projects = [Project(p) for p in args.projects]
        out = Path(args.out or projects[0].path.parent)
        out.mkdir(parents=True, exist_ok=True)
        clips, pics = [], []
        for p in projects:
            types = {f.get("type") for f in p.d["file"].values()}
            if VIDEO in types:
                clips += read_video_project(p, warn)
            if IMAGE in types:
                pics += read_snapshot_project(p, warn)
        written = []
        if clips:
            appear, ignore, pos = [], [], []
            for c in sorted(clips, key=lambda c: c["clip"]):
                if not c["watched"] and not args.include_unfinished:
                    warn(f"{c['clip']}: 'watched' is not 'whole video'; left out (or use --include-unfinished)")
                    continue
                tidy_clip(c, warn)
                # A watched video without appearances: one row with only the clip ("no insect").
                for r in c["appear"] or ([{}] if c["watched"] else []):
                    appear.append({"clip": c["clip"], **r})
                ignore += [{"clip": c["clip"], **r} for r in c["ignore"]]
                pos += [{"clip": c["clip"], **q} for q in c["pos"]]
                n_insects = len({r["insect"] for r in c["appear"]})
                insect_s = sum(r["end_s"] - r["start_s"] for r in c["appear"])
                print(f"{c['clip']}: {n_insects} insects, {len(c['appear'])} appearances "
                      f"({insect_s:.1f} insect-seconds), {len(c['ignore'])} ignore spans, {len(c['pos'])} positions")
            appear.sort(key=lambda r: (r["clip"], r.get("start_s", -1), r.get("insect", "")))
            write_csv(out / "hand_count.csv", ["clip", "start_s", "end_s", "taxon", "insect", *SEGMENT_FIELDS[1:]], appear)
            write_csv(out / "ignore_spans.csv", ["clip", "start_s", "end_s", "note"], ignore)
            write_csv(out / "positions.csv", ["clip", "insect", "t_s", "x", "y", "w", "h"],
                      sorted(pos, key=lambda q: (q["clip"], q["insect"], q["t_s"])))
            written += ["hand_count.csv", "ignore_spans.csv", "positions.csv"]
        if pics:
            pics.sort(key=lambda q: (q["clip"], q["t_s"]))
            rows, points = [], []
            for q in pics:
                rows.append({**q, "n_insects": len(q["points"]), "n_edge": sum(1 for x in q["points"] if x["edge"] == "yes")})
                points += [{"clip": q["clip"], "t_s": q["t_s"], "frame": q["frame"], **x} for x in q["points"]]
            write_csv(out / "snapshots.csv", ["clip", "t_s", "frame", "picture", "n_insects", "n_edge", "note"], rows)
            write_csv(out / "snapshot_points.csv", ["clip", "t_s", "frame", "x", "y", "focus", "edge"], points)
            for clip in sorted({q["clip"] for q in pics}):
                n = [len(q["points"]) for q in pics if q["clip"] == clip]
                print(f"{clip} snapshots: {len(n)} pictures counted, mean {sum(n) / len(n):.2f} insects per picture, most {max(n)}")
            written += ["snapshots.csv", "snapshot_points.csv"]
        if args.draft:
            if len(projects) != 1:
                raise InputError("--draft compares one project with its draft; give one project")
            counts = compare_with_draft(projects[0], Project(args.draft))
            for kind in ("appearance", "position"):
                parts = [f"{counts[(kind, s)]} {s}" for s in ("kept", "changed", "deleted", "added")]
                print(f"against the draft, {kind}s: " + ", ".join(parts))
        for w in warnings:
            print(f"Note: {w}", file=sys.stderr)
        if written:
            print(f"Wrote {', '.join(written)} in {out}")
        else:
            print("Nothing to write: no video or snapshot project found", file=sys.stderr)
    except InputError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
