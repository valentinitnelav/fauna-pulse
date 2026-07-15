# Data Guide — Reading `session.jsonl` and Computing Visitation Rates

**Who this is for:** the researcher (or their analysis scripts) turning a
recorded session into numbers. The app's scientific deliverable is the
**visitation rate** — how often and how long insects visit a flower — and this
document is how you get there from the raw log.

For the photo-resolution side of the data (`saves_px`, `analysis_frame_*`), see
[HOW_PHOTO_RESOLUTION_WORKS.md](HOW_PHOTO_RESOLUTION_WORKS.md).

---

## 1. The file format

Each session writes `session.jsonl` — **one JSON object per line**
(newline-delimited JSON, "JSONL"). This is deliberate: unlike one big JSON
array, lines can be appended without rewriting the file, so a crash or dead
battery never corrupts what was already saved. **The file is simply missing its
final `end_of_session` line — which is exactly how you detect an abnormal
stop.**

Every line has:

- `type` — the record kind (see §3),
- `time_ms` — Unix epoch milliseconds (for computation),
- `time_iso` — human-readable ISO-8601 with local offset, e.g.
  `2026-07-04T19:03:12.123+02:00`.

Reading it:

- **R:** `jsonlite::stream_in(file("session.jsonl"))` or
  `jsonlines::read_json_lines("session.jsonl")`
- **Python:** `pandas.read_json("session.jsonl", lines=True)` or the
  `jsonlines` package.

## 2. Detecting a clean vs crashed session

```r
lines <- jsonlite::stream_in(file("session.jsonl"))
ended_ok <- any(lines$type == "end_of_session")   # FALSE => crashed / killed
```

A crashed session's data up to the last written line is still valid — you just
won't have the end-of-session totals, and the last ~0.5 s of detections may be
missing (writes are flushed roughly twice a second).

## 3. Record types (data dictionary)

Fields shared by every record: `type`, `time_ms`, `time_iso`.

### `start_of_session` — one per session, first line

Session-wide metadata. Notable fields:

| Field | Meaning |
|---|---|
| `session_id` | Unique id for this recording. |
| `device` | Device descriptor (model/id). |
| `battery_percent` | Battery level at start. |
| `free_storage_bytes`, `total_storage_bytes` | Free/total bytes on the session's storage volume at start (round 68). |
| `model_path`, `task`, `use_gpu` | Requested model & task settings. |
| `accelerator` | What was **actually** used (e.g. GPU, or CPU fallback for int8 models). |
| `camera_full_width_px`, `camera_full_height_px` | Full-resolution still size. |
| `selected_lens_zoom`, `selected_lens_label` | Which rear lens was used. |
| `focus_mode` (`manual`/`auto`/`fixed`), `focus_value` | Focus; `focus_value` (0..1) present only for manual. |
| `confidence_threshold`, `iou_threshold` | Detection thresholds. |
| `step_seconds`, `duration_seconds`, `session_minutes` | Timing config. |
| `roi` | Starting ROI geometry (see the `roi` sub-object below). |
| `roi_source`, `saves_px` | Which source the ROI photo comes from, and exact saved pixel side. |
| `analysis_frame_width_px`, `analysis_frame_height_px` | Live analysis-frame size. |
| `inference_fps`, `*_sample_seconds` | Rate cap and logging cadences. |
| `config` | **A complete self-describing copy of every setting used** — the most reliable source for your methods section. Individual keys above are kept for older readers. |
| `thermal` | A starting thermal/power reading (see `thermal` block below). |

The `roi` sub-object (also used in `roi_update`):

| Field | Meaning |
|---|---|
| `center_x_norm`, `center_y_norm` | ROI centre as a fraction (0..1) of the frame. |
| `width_px`, `height_px` | ROI side in pixels (square, so equal). |
| `frame_width_px`, `frame_height_px` | The frame these are relative to. |

### `detections` — the core record, one per processed frame with insects

This is what you count. One line per frame; the frame's insects are entries in
its `tracks` array (round 69 — earlier sessions wrote one `detection` line per
insect instead, see the note below):

| Field | Meaning |
|---|---|
| `tracks` | Array with one entry per tracked insect this frame. Entry fields below. |
| `tracks[].track_id` | **Stable ID for one insect across frames — this defines a "visit".** |
| `tracks[].class_index`, `tracks[].class_name` | Detected class. |
| `tracks[].confidence` | Detection score (0..1). |
| `tracks[].box_in_roi` | Bounding box **relative to the ROI**, all edges in 0..1 (`{left, top, right, bottom}`). 0 = ROI's left/top edge, 1 = right/bottom edge. |
| `tracks[].jpeg` | Filename of the ROI photo that covered this track at this moment; **absent** when no photo was saved for it on this frame. |

> Note: a `detections` line is written for **every processed frame** with at
> least one tracked insect, not once per visit. You reconstruct a visit by
> grouping consecutive entries that share a `track_id` (see §4).

> **Legacy format (sessions recorded ≤ round 68, 2026-07-05):** one
> `"type": "detection"` line per insect per frame, with the entry fields at
> the top level and `jpeg: null` when no photo was saved. Same information —
> scripts should accept both (the snippets in §4 do). The in-app summary
> screen reads both formats too.

### `raw_detections` — pre-tracking boxes (round 105, only when the evaluation toggle is on)

Written only when Settings → AI → Visit tracking → Advanced → **Log raw
detections** is enabled: one line per processed frame (empty frames included —
the tracker ages its tracks by frames) with the detector's boxes **before**
tracking. This is the input the offline tracker replay harness uses to compare
association algorithms on real data
(`flutter test test/fauna_pulse/tracker_replay_test.dart
--dart-define=REPLAY_SESSION=…/session.jsonl`).

| Field | Meaning |
|---|---|
| `frame_ms` | The frame's timestamp (ms since epoch) — use this, not `time_ms` (which is stamped at log-queue time). |
| `boxes` | Array of `[left, top, right, bottom, confidence, class_index]`, boxes **frame-normalized** 0..1 (not ROI-relative like `box_in_roi`). |

### `gt_capture` — ground-truth frame saves (round 107, only when that toggle is on)

One record per periodic ground-truth photo (Settings → AI → Visit tracking →
Advanced → **Ground-truth frames**). These photos land in `gt_frames/` (not
`roi_frames/`) and are taken on a fixed clock regardless of detections — use
them to hand-count the true visits when evaluating a tracker. Fields:
`jpeg` (filename), `captured_at_ms` (trigger moment), plus the same
`total_ms` / `bytes` / `path` / `saved_px` stats as a `capture` record.
Deliberately a separate type: never mix these into detection-photo joins.

### `roi_update` — when the ROI is moved/resized mid-session

Carries the `roi` sub-object, plus `roi_source` (`fast`/`still`) and `saves_px`.

### `motion_gate` — when the detector sleeps/wakes (only if the gate is enabled)

| Field | Meaning |
|---|---|
| `state` | `idle` (detector went to sleep) or `awake` (resumed). |
| `motion_score` | The motion measure at the transition. |
| `idle_s` | On wake only: how long it was asleep. |

Gated (idle) periods carry **no** `detection` lines by design — these records
make that auditable, so an empty stretch is "confirmed asleep", not "missed".

### `thermal`, `fps`, `power` — periodic samples for the summary graphs

- `thermal`: `battery_temp_c`, `thermal_status`, `battery_current_ua`,
  `battery_voltage_mv`, `charge_counter_uah`, `is_charging`,
  `thermal_headroom`, `power_w` (derived), and since round 68
  `free_storage_bytes` / `total_storage_bytes` (so the session's disk fill
  rate can be plotted against its photo cadence).
- `fps`: `fps` (detector FPS) plus per-second camera/detector/pipeline rates,
  inference timing breakdown, and applied throttle cap.
- `power`: `power_w`, `battery_current_ua`, `battery_voltage_mv`,
  `charge_counter_uah`, `is_charging`.

### `capture` — one per ROI-photo save

Records `fileName`, `trackIds` (the tracks that photo covered — concurrent
tracks share one photo), timing, byte size, whether it was a full-res still,
the source `path`, and `saved_px`. Lets you check whether photo-saving dented
the frame rate.

Round-108 additions:

| Field | Meaning |
|---|---|
| `grab_ms` | Time the image grab alone took; the rest of `total_ms` is crop + encode + write. |
| `content_lag_ms` | Still path only. How much OLDER/NEWER the frame's *content* is than the capture request. **Negative = the phone's zero-shutter-lag really served a pre-request frame**; a large positive value means the photo shows the scene that long after the triggering detection (fast insects will have left). |
| `callback_lag_ms` | Still path only. Plain request→JPEG wait. |
| `live_jpeg`, `live_bytes`, `live_saved_px` | Sync companion (when enabled): the trigger-moment live-frame crop saved next to the still as `…_live.jpg`. Small but in sync — use it when the still misses the insect. |

### `app_error` — an error surfaced during recording

`source` (e.g. `detector`, `watchdog`, `session_log`, `roi_capture`,
`set_inference_roi`, `set_motion_gate`, `flutter_framework`, `uncaught_async`)
and `message`. Field sessions run unattended and banners are brief, so this is
your record of "something flashed red at 14:20" (round 65). Since round 67,
uncaught app errors also land here: those records may carry a truncated
`stack` and, because they are rate-limited to one per 2 s, a
`suppressed_since_last` count of identical-window errors that were dropped.
If the storage filled up mid-session, log lines may be missing between a
`session_log` app_error and the `end_of_session` line — the file stays valid
JSONL throughout.

### `end_of_session` — one per session, last line (absent = crash)

`ended_normally` (`true` only on a clean stop), `battery_percent`,
`unique_track_count`, and a final `thermal` reading.

## 4. Computing visitation rate

A **visit** = a run of `detection` records sharing one `track_id`. Its start and
end are the first and last `time_ms` for that id; its duration is the
difference. The tracker already enforces the minimum-visit-length and
occlusion-tolerance settings, so each `track_id` is one confirmed visit — you
don't re-filter noise.

Two common metrics:

- **Visitation rate** = number of distinct `track_id`s ÷ observation time.
- **Mean visit duration** = mean of (last − first `time_ms`) per `track_id`.

Observation time is the span from `start_of_session` to `end_of_session`
(`time_ms`), minus any `motion_gate` idle periods if you want *active* watch
time only.

### R

```r
library(jsonlite)
rows <- stream_in(file("session.jsonl"), verbose = FALSE)

start_ms <- rows$time_ms[rows$type == "start_of_session"][1]
end_ms   <- rows$time_ms[rows$type == "end_of_session"]
end_ms   <- if (length(end_ms)) end_ms[1] else max(rows$time_ms)  # crashed?
obs_hours <- (end_ms - start_ms) / 3.6e6

# Flatten to one row per tracked insect per frame, accepting both formats:
# "detections" (round 69+: tracks[] array) and legacy per-track "detection".
new <- rows[rows$type == "detections", c("time_ms", "tracks")]
det_new <- if (nrow(new)) do.call(rbind, lapply(seq_len(nrow(new)), function(i) {
  data.frame(time_ms = new$time_ms[i], track_id = new$tracks[[i]]$track_id)
})) else NULL
det_old <- if ("track_id" %in% names(rows))
  rows[rows$type == "detection", c("time_ms", "track_id")] else NULL
det <- rbind(det_new, det_old)

visits <- aggregate(time_ms ~ track_id, det,
                    FUN = function(t) c(start = min(t), end = max(t)))
visits <- do.call(data.frame, visits)
visits$duration_s <- (visits$time_ms.end - visits$time_ms.start) / 1000

n_visits             <- nrow(visits)
visitation_rate_hr   <- n_visits / obs_hours
mean_visit_duration  <- mean(visits$duration_s)

cat(sprintf("visits=%d  rate=%.1f/hr  mean duration=%.1fs\n",
            n_visits, visitation_rate_hr, mean_visit_duration))
```

### Python

```python
import pandas as pd

rows = pd.read_json("session.jsonl", lines=True)

start_ms = rows.loc[rows.type == "start_of_session", "time_ms"].iloc[0]
end = rows.loc[rows.type == "end_of_session", "time_ms"]
end_ms = end.iloc[0] if len(end) else rows.time_ms.max()   # crashed?
obs_hours = (end_ms - start_ms) / 3.6e6

# Flatten to one row per tracked insect per frame, accepting both formats:
# "detections" (round 69+: tracks[] array) and legacy per-track "detection".
new = rows[rows.type == "detections"].explode("tracks")
new = pd.concat(
    [new[["time_ms"]].reset_index(drop=True),
     pd.json_normalize(new.tracks)], axis=1)
old_cols = [c for c in ("time_ms", "track_id") if c in rows.columns]
old = rows.loc[rows.type == "detection", old_cols]
det = pd.concat([new, old], ignore_index=True)

visits = det.groupby("track_id")["time_ms"].agg(["min", "max"])
visits["duration_s"] = (visits["max"] - visits["min"]) / 1000

n_visits = len(visits)
visitation_rate_hr = n_visits / obs_hours
mean_visit_duration = visits["duration_s"].mean()

print(f"visits={n_visits}  rate={visitation_rate_hr:.1f}/hr  "
      f"mean duration={mean_visit_duration:.1f}s")
```

`unique_track_count` in `end_of_session` should match `n_visits` for a clean
session — a quick sanity check.

## 5. Joining photos to detections

Each track entry's `jpeg` field (in `detections.tracks[]`; top-level in legacy
`detection` records) is the filename in `roi_frames/` for the photo saved on
that frame. Join on it to attach images to specific tracks/moments. The exact pixel size of each saved photo is in the
matching `capture` record's `saved_px` (photo box geometry), which is the
authoritative size — not the ROI box geometry.
