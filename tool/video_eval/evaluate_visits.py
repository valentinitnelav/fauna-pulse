#!/usr/bin/env python3
"""Compare FaunaPulse's visits with a hand count of the same videos (round 230).

"Find visits" on the "Run AI on videos" screen writes visits.csv: one row per
visit (track id), with start_s / end_s in seconds from the start of the clip
the visit began in. This script matches those visits with the visits you
counted yourself while watching the same clips, and reports how many the app
found, missed and added, per clip and overall.

Hand count, one or more files, either
  * a CSV like hand_count_template.csv: clip, start_s, end_s, taxon (optional).
    Times in seconds, or as a video player shows them (1:23.5, 0:01:23.5).
    A row with a clip and no times marks a clip you watched without seeing a
    visit. Comma, semicolon or tab separated.
  * a BORIS "aggregated events" export (CSV or TSV), one observation per video
    (BORIS counts time over a whole observation, not per video). The taxon is
    the Subject, or the Behavior when there is no focal subject.

Matching: a hand-counted visit and an app visit match when they overlap in
time, after widening the hand-counted one by --tolerance seconds on each side
(clicks are never exact; a point event becomes a visit of that width). Each
visit matches at most one: the pair that overlaps longest goes first.

  found (matched)  hand-counted visits the app also found
  missed           hand-counted visits without an app visit
  extra            app visits without a hand-counted visit
  split            hand-counted visits overlapped by 2+ app visits (one insect
                   counted more than once, e.g. lost behind a petal)
  merged           app visits overlapping 2+ hand-counted visits (visitors
                   that followed each other closely, counted as one)
  precision = found / app visits;  recall = found / hand-counted visits

Only clips in the hand count are scored. session.jsonl (clip names before the
import, clip lengths) and post_tracks.jsonl (which clips were tracked, with
which tracker) are read from the visits file's folder or the one above; both
are in the "Share results" file.

Usage:
  python3 evaluate_visits.py --truth hand_count.csv --app visits.csv
  python3 evaluate_visits.py --truth boris.tsv --app fps_sweep/visits_*.csv \\
      --out scores.csv --pairs pairs.csv

--out writes one row per run and clip plus an "ALL" row per run, --pairs one
row per visit (matched, missed or extra), both tidy for R. A run is one
visits file; files named visits_<tracker>_<fps>fps.csv (the frame-rate sweep,
test/fauna_pulse/video_fps_sweep_test.dart) fill the tracker and fps columns.

Standard library only (Python 3.8+). Guide: docs/VIDEO_ANALYSIS.md.
"""
import argparse
import csv
import glob
import json
import os
import re
import statistics
import sys
from pathlib import Path

NO_SUBJECT = {"", "no focal subject"}


class InputError(Exception):
    """A problem with the input files, explained in plain words."""


def clip_key(name):
    """File name without folder and extension, lower case: 'VID_1.MP4' -> 'vid_1'."""
    base = re.split(r"[/\\]", str(name).strip())[-1]
    return os.path.splitext(base)[0].lower()


def parse_time(text, decimal_comma=False):
    """Seconds from '83.5', '1:23.5' or '0:01:23.5'; None when empty or NA."""
    text = (text or "").strip()
    if text.upper() in ("", "NA", "NAN"):
        return None
    if decimal_comma:
        text = text.replace(",", ".")
    seconds = 0.0
    for part in text.split(":"):
        seconds = seconds * 60 + float(part)
    return seconds


def read_table(path):
    """Header names, rows as dicts (both stripped) of a CSV/TSV, and whether it uses decimal commas."""
    text = Path(path).read_text(encoding="utf-8-sig")
    try:
        dialect = csv.Sniffer().sniff(text.split("\n", 1)[0], delimiters=",;\t")
    except csv.Error:
        dialect = csv.excel
    reader = csv.DictReader(text.splitlines(), dialect=dialect)
    header = [h.strip() for h in reader.fieldnames or []]
    rows = []
    for row in reader:
        rows.append({(k or "").strip(): (v or "").strip() for k, v in row.items() if k is not None})
    return header, rows, dialect.delimiter != ","


def column(header, *names):
    """The first header name that equals one of names (case-insensitive), or None."""
    lower = {h.lower(): h for h in header}
    for n in names:
        if n.lower() in lower:
            return lower[n.lower()]
    return None


def read_truth(paths, behaviors):
    """Hand-counted visits as (clip, start_s, end_s, taxon, source), and the watched clips."""
    visits, watched = [], []
    for path in paths:
        header, rows, decimal_comma = read_table(path)
        clip_col = column(header, "clip", "video", "file", "Media file name")
        start_col = column(header, "start_s", "start", "Start (s)")
        end_col = column(header, "end_s", "end", "stop", "Stop (s)")
        if not clip_col or not start_col:
            raise InputError(f"{path}: needs a clip column and a start column (see hand_count_template.csv)")
        taxon_col = column(header, "taxon", "species")
        subject_col, behavior_col = column(header, "Subject"), column(header, "Behavior")
        obs_col = column(header, "Observation id")
        offset_col = column(header, "Time offset (s)", "Time offset")
        media_per_obs = {}
        for i, row in enumerate(rows, start=2):  # line 1 is the header
            where = f"{path}, line {i}"
            if obs_col:
                media_per_obs.setdefault(row[obs_col], set()).add(clip_key(row[clip_col]))
            if not row[clip_col]:
                continue
            watched.append((row[clip_col], where))
            if offset_col and row[offset_col] not in ("", "0", "0.0", "0.000"):
                raise InputError(f"{where}: the BORIS observation has a time offset; set it to 0 so times are video positions")
            if behaviors and behavior_col and row[behavior_col] not in behaviors:
                continue
            try:
                start = parse_time(row[start_col], decimal_comma)
                end = parse_time(row[end_col], decimal_comma) if end_col else None
            except ValueError:
                raise InputError(f"{where}: cannot read the times '{row[start_col]}' / '{row.get(end_col, '')}'")
            if start is None:
                continue  # a watched clip without visits
            end = start if end is None else end
            if end < start:
                raise InputError(f"{where}: the visit ends before it starts")
            if taxon_col:
                taxon = row[taxon_col]
            elif subject_col and row[subject_col].lower() not in NO_SUBJECT:
                taxon = row[subject_col]
            else:
                taxon = row[behavior_col] if behavior_col else ""
            visits.append((row[clip_col], start, end, taxon, where))
        for obs, media in media_per_obs.items():
            if len(media) > 1:
                raise InputError(
                    f"{path}: BORIS observation '{obs}' holds several videos ({', '.join(sorted(media))}). "
                    "BORIS then counts time over the whole observation; please make one observation per video."
                )
    return visits, watched


def find_near(visits_path, name):
    """name in the visits file's folder or the one above, or None."""
    folder = Path(visits_path).resolve().parent
    for f in (folder / name, folder.parent / name):
        if f.is_file():
            return f
    return None


def read_jsonl(path, types):
    """Records of the given types from a JSON Lines file (broken lines skipped)."""
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if not any(f'"{t}"' in line for t in types):
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("type") in types:
                out.append(rec)
    return out


class Run:
    """One visits file with what is known about its session."""

    def __init__(self, path):
        self.path = path
        self.name = Path(path).stem
        m = re.fullmatch(r"visits_([a-z0-9]+)_([0-9.]+)fps", self.name)
        self.tracker, self.fps = (m.group(1), m.group(2)) if m else ("", "")
        header, rows, _ = read_table(path)
        for need in ("track_id", "clip", "start_s", "end_s"):
            if not column(header, need):
                raise InputError(f"{path}: not a visits.csv of the app (no '{need}' column)")
        self.visits = [
            (r["clip"], float(r["start_s"]), float(r["end_s"]), r["track_id"], r.get("class", "")) for r in rows
        ]
        # Every name a clip is known by -> the app's clip name; clip lengths.
        self.names = {clip_key(v[0]): v[0] for v in self.visits}
        self.length_s = {}
        self.tracked = None  # None = unknown
        self.left_out = set()
        log = find_near(path, "session.jsonl")
        if log:
            for rec in read_jsonl(log, ["video_clip"]):
                app_name = str(rec.get("file", "")).split("/")[-1]
                for n in (app_name, rec.get("original_name") or ""):
                    if n:
                        self.names.setdefault(clip_key(n), app_name)
                if rec.get("duration_ms") is not None:
                    self.length_s[app_name] = rec["duration_ms"] / 1000
        post = find_near(path, "post_tracks.jsonl")
        if post:
            start = read_jsonl(post, ["post_track_start"])
            if start:
                s = start[0]
                self.tracked = set(s.get("clips") or [])
                self.left_out = set(s.get("clips_left_out") or [])
                for c in self.tracked | self.left_out:
                    self.names.setdefault(clip_key(c), c)
                if not m:  # the app's own visits.csv: label from its tracking run
                    self.tracker = str((s.get("tracker") or {}).get("algorithm", ""))
                    fps = (s.get("detection_settings") or {}).get("analysis_fps")
                    self.fps = "" if fps is None else f"{fps:g}"

    def resolve(self, clip, where):
        """The app's name for a hand-counted clip name."""
        name = self.names.get(clip_key(clip))
        if name is None:
            known = ", ".join(sorted(set(self.names.values()))) or "none"
            raise InputError(
                f"{where}: clip '{clip}' is not one of the app's clips ({known}). Check the name. "
                "visits.csv lists only clips with a visit, and only the names inside the app: put session.jsonl "
                "and post_tracks.jsonl (both in the Share results file) next to it to know every clip and its "
                "name before the import."
            )
        if name in self.left_out:
            raise InputError(f"{where}: the analysis of clip '{name}' did not finish, so it has no visits yet")
        if self.tracked is not None and name not in self.tracked:
            raise InputError(f"{where}: clip '{name}' was not tracked in this run")
        return name


def natural_key(path):
    """Sort key that puts visits_x_2fps before visits_x_15fps."""
    return [float(p) if i % 2 else p for i, p in enumerate(re.split(r"(\d+(?:\.\d+)?)", path))]


def overlap(a0, a1, b0, b1):
    return min(a1, b1) - max(a0, b0)


def match_clip(truth, app, tolerance):
    """Greedy one-to-one matching of one clip's visits by time overlap.

    truth: [(start, end, taxon, source)], app: [(start, end, track_id, class)].
    Returns (pairs [(ti, ai, overlap_s)], split count, merged count).
    """
    links = []
    for ti, (t0, t1, _, _) in enumerate(truth):
        for ai, (a0, a1, _, _) in enumerate(app):
            if overlap(t0 - tolerance, t1 + tolerance, a0, a1) > 0:
                links.append((overlap(t0, t1, a0, a1), overlap(t0 - tolerance, t1 + tolerance, a0, a1), ti, ai))
    links.sort(key=lambda x: (-x[0], -x[1], x[2], x[3]))
    used_t, used_a, pairs = set(), set(), []
    for raw, _, ti, ai in links:
        if ti in used_t or ai in used_a:
            continue
        used_t.add(ti)
        used_a.add(ai)
        pairs.append((ti, ai, max(0.0, raw)))
    per_t = [sum(1 for l in links if l[2] == ti) for ti in range(len(truth))]
    per_a = [sum(1 for l in links if l[3] == ai) for ai in range(len(app))]
    return pairs, sum(1 for n in per_t if n > 1), sum(1 for n in per_a if n > 1)


def ratio(a, b):
    return a / b if b else None


def score(counts):
    """Summary numbers from summed counts and the matched-pair errors."""
    n_true, n_app, found = counts["n_true"], counts["n_app"], counts["found"]
    p, r = ratio(found, n_app), ratio(found, n_true)
    return {
        "n_true": n_true,
        "n_app": n_app,
        "found": found,
        "missed": n_true - found,
        "extra": n_app - found,
        "precision": p,
        "recall": r,
        "f1": 2 * p * r / (p + r) if p and r else (0.0 if p == 0 or r == 0 else None),
        "count_error": n_app - n_true,
        "split": counts["split"],
        "merged": counts["merged"],
        "true_visit_s": counts["true_s"],
        "app_visit_s": counts["app_s"],
        "mean_duration_error_s": statistics.mean(counts["dur_err"]) if counts["dur_err"] else None,
        "median_start_error_s": statistics.median(counts["start_err"]) if counts["start_err"] else None,
    }


def evaluate(run, truth, watched, tolerance):
    """Score rows (per clip and ALL) and pair rows for one run."""
    by_clip = {}
    for clip, where in watched:
        by_clip.setdefault(run.resolve(clip, where), ([], []))
    for clip, start, end, taxon, where in truth:
        name = run.resolve(clip, where)
        length = run.length_s.get(name)
        if length is not None and start > length + 1:
            raise InputError(f"{where}: starts at {start:g} s, after the end of clip '{name}' ({length:g} s)")
        by_clip[name][0].append((start, end, taxon, where))
    for clip, start, end, track_id, cls in run.visits:
        if clip in by_clip:
            by_clip[clip][1].append((start, end, track_id, cls))

    keys = ("n_true", "n_app", "found", "split", "merged", "true_s", "app_s")
    total = {k: 0 for k in keys}
    total.update(dur_err=[], start_err=[])
    scores, pairs = [], []
    label = {"run": run.name, "tracker": run.tracker, "fps": run.fps}
    for clip in sorted(by_clip):
        t, a = by_clip[clip]
        t.sort(key=lambda v: v[0])
        a.sort(key=lambda v: v[0])
        matched, split, merged = match_clip(t, a, tolerance)
        c = {
            "n_true": len(t),
            "n_app": len(a),
            "found": len(matched),
            "split": split,
            "merged": merged,
            "true_s": sum(v[1] - v[0] for v in t),
            "app_s": sum(v[1] - v[0] for v in a),
            "dur_err": [(a[ai][1] - a[ai][0]) - (t[ti][1] - t[ti][0]) for ti, ai, _ in matched if t[ti][1] > t[ti][0]],
            "start_err": [a[ai][0] - t[ti][0] for ti, ai, _ in matched],
        }
        for k in keys:
            total[k] += c[k]
        total["dur_err"] += c["dur_err"]
        total["start_err"] += c["start_err"]
        scores.append({**label, "clip": clip, "clip_s": run.length_s.get(clip), **score(c)})

        def pair_row(status, ti=None, ai=None, ov=None):
            tv = t[ti] if ti is not None else (None, None, "", "")
            av = a[ai] if ai is not None else (None, None, "", "")
            return {
                **label,
                "clip": clip,
                "status": status,
                "true_start_s": tv[0],
                "true_end_s": tv[1],
                "true_taxon": tv[2],
                "true_source": tv[3],
                "track_id": av[2],
                "app_start_s": av[0],
                "app_end_s": av[1],
                "app_class": av[3],
                "overlap_s": ov,
            }

        mt, ma = {ti for ti, _, _ in matched}, {ai for _, ai, _ in matched}
        pairs += [pair_row("found", ti, ai, ov) for ti, ai, ov in matched]
        pairs += [pair_row("missed", ti=ti) for ti in range(len(t)) if ti not in mt]
        pairs += [pair_row("extra", ai=ai) for ai in range(len(a)) if ai not in ma]
    lengths = [run.length_s.get(c) for c in by_clip]
    clip_s = sum(lengths) if lengths and None not in lengths else None
    scores.append({**label, "clip": "ALL", "clip_s": clip_s, **score(total)})
    return scores, pairs


def fmt(v):
    if v is None:
        return "NA"
    if isinstance(v, float):
        return f"{v:.3f}"
    return v


def write_csv(path, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        for r in rows:
            w.writerow({k: fmt(v) for k, v in r.items()})


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--truth", nargs="+", required=True, help="hand count: CSV or BORIS aggregated events export")
    ap.add_argument("--app", nargs="+", required=True, help="the app's visits.csv (one or more runs; wildcards work)")
    ap.add_argument("--tolerance", type=float, default=0.5, help="seconds added on each side of a hand-counted visit (0.5)")
    ap.add_argument("--behavior", action="append", help="BORIS: only these behaviors count as visits (repeatable)")
    ap.add_argument("--out", help="write the scores (per run and clip) to this CSV")
    ap.add_argument("--pairs", help="write every visit (found, missed, extra) to this CSV")
    args = ap.parse_args(argv)
    apps = [p for pattern in args.app for p in (sorted(glob.glob(os.path.expanduser(pattern)), key=natural_key) or [pattern])]
    try:
        truth, watched = read_truth(args.truth, set(args.behavior or []))
        all_scores, all_pairs = [], []
        for path in apps:
            run = Run(path)
            scores, pairs = evaluate(run, truth, watched, args.tolerance)
            all_scores += scores
            all_pairs += pairs
            s = scores[-1]
            unscored = {v[0] for v in run.visits} - {r["clip"] for r in scores}
            print(
                f"{run.name}: {len(scores) - 1} clip(s), hand count {s['n_true']}, app {s['n_app']}: "
                f"found {s['found']} (recall {fmt(s['recall'])}), missed {s['missed']}, "
                f"extra {s['extra']} (precision {fmt(s['precision'])}), split {s['split']}, merged {s['merged']}"
                + (f"; {len(unscored)} clip(s) with app visits not in the hand count, not scored" if unscored else "")
            )
    except (InputError, OSError) as e:
        sys.exit(f"Error: {e}")
    if args.out:
        write_csv(args.out, all_scores)
    if args.pairs and all_pairs:
        write_csv(args.pairs, all_pairs)


if __name__ == "__main__":
    main()
