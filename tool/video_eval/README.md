# Video evaluation tools: score the app's track IDs against a hand count (PC side)

FaunaPulse finds track IDs in imported videos (*Find animals in videos* → *Find track IDs* →
*Share results*). A track ID is one insect the app followed from frame to frame; in
pollination ecology it usually stands for one visit, as far as detection and tracking
worked. These scripts check the track IDs against the visits a person counted while
watching the same clips, which measures exactly how far that holds. They need only Python 3.8 or newer: no packages to install, no
GPU. The full workflow (annotating, the frame-rate sweep, datasets) is in
[`docs/VIDEO_ANALYSIS.md`](../../docs/VIDEO_ANALYSIS.md).

| File | What it does |
|---|---|
| `evaluate_track_ids.py` | Matches hand-counted visits with the app's `track_ids.csv` by time overlap; prints found / missed / extra per run and writes tidy CSVs for R (`--out`, `--pairs`). Reads a plain CSV or a BORIS *aggregated events* export. Called `evaluate_visits.py` before round 248, when the app wrote `visits.csv`: both old names still work (`evaluate_visits.py` runs this script). |
| `hand_count_template.csv` | The plain hand-count layout: `clip, start_s, end_s, taxon` (+ your own columns). Times in seconds or as a video player shows them (`1:05.0`). A row with only a clip = watched, no visit. |
| `mot_to_cvat.py` | Turns the app's `mot/<clip>.txt` boxes into a zip CVAT imports (*MOT 1.1*), as a first draft for box-level annotation. |
| `test_*.py` | Tests: `python3 -m unittest` in this folder. |

```bash
cd fauna-pulse/tool/video_eval
# one run: the unzipped "Share results" folder
python3 evaluate_track_ids.py --truth my_count.csv --app ~/results/track_ids.csv \
    --out scores.csv --pairs pairs.csv
# the frame-rate sweep (test/fauna_pulse/video_fps_sweep_test.dart)
python3 evaluate_track_ids.py --truth boris_export.tsv --behavior visit \
    --app "~/results/fps_sweep/track_ids_*.csv" --out sweep_scores.csv
```

Keep `session.jsonl` and `post_tracks.jsonl` next to `track_ids.csv` (they are in the
*Share results* file): they tell the script every clip that was analysed, including clips
without a track ID, and each clip's name before the import.
