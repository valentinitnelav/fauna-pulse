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
| `app_version`, `app_build` | Round 132+: which app binary recorded the session (pubspec version + build number). Needed when comparing performance across sessions — behaviour changes between versions. |
| `build_mode` | Round 132+: `release`, `profile` or `debug`. A `flutter run` debug build performs measurably worse than the release APK, so performance comparisons must not mix modes. |
| `blackout_at_start` | Round 132+: present (`true`) when recording started with the screen-off cover already up (scheduled runs). Screen state changes thereafter are `blackout` records. |
| `battery_percent` | Battery level at start. |
| `free_storage_bytes`, `total_storage_bytes` | Free/total bytes on the session's storage volume at start (round 68). |
| `model_path`, `task`, `use_gpu` | Requested model & task settings. |
| `accelerator` | What was **actually** used (e.g. GPU, or CPU fallback for int8 models). |
| `camera_full_width_px`, `camera_full_height_px` | Full-resolution (high-res) photo size. |
| `capture_dims_from_cache` | Present (`true`) when recording started before the live photo probe confirmed the cached photo size (round 121) — the dims above came from the previous measurement. |
| `location` | The session's single location fix (round 126): `lat`, `lon` (decimal degrees), `accuracy_m` (GPS only), `fix_time_ms`, `source` (`gps` / `manual` / `previous`). Absent when no location was set. Stripped from problem-report samples. |
| `selected_lens_zoom`, `selected_lens_label` | Which rear lens was used. |
| `focus_mode` (`manual`/`auto`/`fixed`), `focus_value` | Focus; `focus_value` (0..1) present only for manual. |
| `confidence_threshold`, `iou_threshold` | Detection thresholds. |
| `step_seconds`, `duration_seconds`, `session_minutes` | Timing config. |
| `roi` | Starting ROI geometry (see the `roi` sub-object below). |
| `roi_source`, `saves_px` | Which source the ROI photo comes from, and exact saved pixel side. |
| `roi_side_stream_px` | Round 109+: the ROI side in the **stream grid** — the ÷32 number shown on screen while recording (e.g. 480). Prefer this for "how big was the box"; the `roi` block may express the same square against the full-res high-res frame (e.g. 1333 on a 3000-wide frame = the same 480 box). |
| `analysis_frame_width_px`, `analysis_frame_height_px` | Live analysis-frame size. |
| `inference_fps`, `*_sample_seconds` | Rate cap and logging cadences. |
| `config` | **A complete self-describing copy of every setting used** — the most reliable source for your methods section. Individual keys above are kept for older readers. |
| `config_not_applicable` | (round 147+) List of `config` keys that had **no effect** under this session's `captureTrigger` (e.g. all model/tracker keys in a motion or time-lapse session; the motion-gate keys in time-lapse). The values themselves stay present with their normal types — filter on this list (or on `captureTrigger`) instead of expecting missing fields or `"n/a"` strings, so typed parsing (pandas dtypes) never breaks. |
| `thermal` | A starting thermal/power reading (see `thermal` block below). |

The `roi` sub-object (also used in `roi_update`):

| Field | Meaning |
|---|---|
| `center_x_norm`, `center_y_norm` | ROI centre as a fraction (0..1) of the frame. |
| `width_px`, `height_px` | ROI side in pixels (square, so equal). |
| `frame_width_px`, `frame_height_px` | The frame these are relative to. |

> ⚠ `width_px` is relative to whichever frame the photos were being saved from
> (`frame_width_px`) — on the high-res path that is the full-resolution photo, so
> it is usually **larger** than the box the user saw. For the on-screen ÷32
> size use `roi_side_stream_px` (round 109+); for older logs recompute it as
> `width_px / frame_width_px × analysis_frame_width_px`, snapped to the
> nearest multiple of 32.

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
| `frame_ms` | Round 114+. The frame's epoch stamp on the **emit clock** (recorded when the native side finished inference and emitted the result — ~50–150 ms after the sensor exposure). Same clock basis as `raw_detections.frame_ms`, deliberately: one key name, one meaning. |
| `frame_sensor_ms` | Round 114+. The frame's **sensor-exposure moment** mapped to epoch ms — the precise stamp, directly comparable to a `capture` record's `content_at_ms`. Absent on HALs without a usable sensor clock; prefer it over `frame_ms` when present. |
| `tracks[].coasted` | Round 116+ safety flag, normally **absent**: every box in a `detections` record is detector-observed (the tracker never logs its velocity-predicted positions). It would read `true` only if a future tracker version logged a predicted box — treat such an entry as an estimate, not an observation. |

> Note: a `detections` line is written for **every processed frame** with at
> least one tracked insect, not once per visit. You reconstruct a visit by
> grouping consecutive entries that share a `track_id` (see §4).

> **Legacy format (sessions recorded ≤ round 68, 2026-07-05):** one
> `"type": "detection"` line per insect per frame, with the entry fields at
> the top level and `jpeg: null` when no photo was saved. Same information —
> scripts should accept both (the snippets in §4 do). The in-app summary
> screen reads both formats too.

### `track_event` — track lifecycle transitions (round 116+)

One line every time a track id changes life stage. Sessions recorded before
round 116 don't have these lines — there, a track id simply stops appearing in
`detections` records and you cannot tell *why*: briefly hidden insect, insect
gone for good, or simply no frames analyzed at all (a high-res photo pauses
the analysis stream for 0.13–1.5 s, see §5b). These records make the four
cases explicit:

| `event` | Meaning |
|---|---|
| `created` | The track was matched in enough frames to count as a visit — its id starts appearing in `detections` records from here. |
| `lost` | The first frame the track was **not** matched (occlusion, missed detection, or the insect left). The id stays buffered for the occlusion tolerance in case it comes back. |
| `recovered` | The lost track was matched again: same id, the same visit continues. |
| `removed` | The id is gone for good. `reason` says why: `aged_out` (unmatched longer than the occlusion tolerance) or `gate_expired` (the motion gate slept longer than the tolerance, so the stale id must not be revived by a newly arriving insect). |

Fields on every `track_event` line:

| Field | Meaning |
|---|---|
| `track_id` | Which track the transition belongs to. |
| `frame_ms` | The transition's frame timestamp (ms since epoch). For `gate_expired` removals it is the **last processed frame before the gate slept**; the line's own `time_ms` carries the wake moment. |
| `box_in_roi` | The track's box at the transition, ROI-relative 0..1 like in `detections`. For `lost` it is the last box that was actually observed. |
| `hits` | Total matched frames for this track so far. |
| `first_seen_ms` | When the track's very first detection was seen — the **real visit start** (it precedes `created` by the confirmation lag, default 0.2 s). |
| `last_seen_ms` | The last real observation. On a `recovered` line this is the pre-gap moment, so `frame_ms − last_seen_ms` = the gap the id survived. |
| `frames_missed` | Unmatched frames at the transition (only written when > 0). |
| `reason` | Removals only: `aged_out` / `gate_expired`. |

How to use them:

* **Visit boundaries without per-frame grouping:** a visit runs from
  `first_seen_ms` (on its `created` line) to `last_seen_ms` (on its `removed`
  line). The §4 snippets that group `detections` frames still work and give
  the same answer — these lines are just the direct route.
* **Temporary loss vs analysis pause:** a `lost` → `recovered` pair brackets a
  real tracking gap; a hole in `detections` timestamps with **no** `lost`
  line in it is an analysis pause (photo grab, throttle), not a lost insect.
* **Stitching fragmented ids:** when the tracker splits one insect into
  several ids, you'll see a `removed` and a `created` close together in time
  (`frame_ms`) and space (`box_in_roi`) — your cue to consider merging those
  ids into one visit during analysis.

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

Carries the `roi` sub-object, plus `roi_source` (`fast`/`still`; `still` = the high-res path, frozen wire name), `saves_px`
and (round 109+) `roi_side_stream_px` (the on-screen ÷32 side — see the `roi`
note above). Since round 109 these records are **debounced**: one record per
adjustment, written once the box has sat unchanged for ~2 s (a change still
pending when recording stops is flushed, so the session's final ROI is always
on record; an adjustment that ends back on the previous geometry writes
nothing). Sessions recorded before round 109 instead carry one record per drag
tick — take the last of a burst. The summary's Settings tab lists these as
"ROI changes during the session".

### `motion_gate` — when the detector sleeps/wakes (only if the gate is enabled)

| Field | Meaning |
|---|---|
| `state` | `idle` (detector went to sleep) or `awake` (resumed). |
| `motion_score` | The motion measure at the transition. |
| `idle_s` | On wake only: how long it was asleep. |

Gated (idle) periods carry **no** `detection` lines by design — these records
make that auditable, so an empty stretch is "confirmed asleep", not "missed".

### `blackout` — screen-off power save toggled mid-session (round 132+)

One field: `on` (`true` = the black cover went up and the screen dimmed to
minimum, `false` = the user tapped to wake). The screen is a major heat and
power source (round 82 measured ~10 °C skin-temperature difference), so
thermal/battery comparisons between sessions need to know the screen state.
Screen state at any moment = the last `blackout` record before it (before the
first one: `blackout_at_start` in the start record, absent = screen on).
Sessions recorded before round 132 carry no screen-state information.

### `focus_change` — camera focus changed mid-session (round 132+)

Same fields as the start record's focus pair: `focus_mode`
(`manual`/`auto`) and, for manual, `focus_value` (0..1, 0 = far/infinity).
Debounced like `roi_update`: one record per adjustment, written once the
slider has sat unchanged for ~2 s (flushed at stop; a change that ends back
on the previous state writes nothing). Focus affects sharpness and therefore
detections — treat a `focus_change` like a small protocol change when
comparing periods within a session.

### `thermal`, `fps`, `power` — periodic samples for the summary graphs

These three record types are always written while recording. One exception:
sessions recorded with the short-lived round-148 build made them opt-in
(config `diagnosticsEnabled: false` in the start record's `config` block ⇒
none present); round 149 reverted to always-on. Their absence there is that
setting, not a logging failure — the detection-derived records (and therefore
the visit timeline) are unaffected either way.

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
tracks share one photo), timing, byte size, whether it was a high-res photo,
the source `path`, and `saved_px`. Lets you check whether photo-saving dented
the frame rate.

Round-108 additions:

| Field | Meaning |
|---|---|
| `grab_ms` | Time the image grab alone took; the rest of `total_ms` is crop + encode + write. |
| `content_lag_ms` | High-res path only. How much OLDER/NEWER the frame's *content* is than the capture request. **Negative = the phone's zero-shutter-lag really served a pre-request frame**; a large positive value means the photo shows the scene that long after the triggering detection (fast insects will have left). |
| `callback_lag_ms` | High-res path only. Plain request→JPEG wait. |
| `live_jpeg`, `live_bytes`, `live_saved_px` | Sync companion (when enabled): the trigger-moment live-frame crop saved next to the high-res photo as `…_live.jpg`. Small but in sync — use it when the high-res photo misses the insect. |
| `live_lag_ms` | Round 112. The companion's own delay behind the trigger moment, measured when its frame grab returned — an upper bound on how old its content can be (typically a few tens of ms; compare with the high-res photo's `content_lag_ms`). |
| `content_at_ms` | Round 114. High-res path only: the photo content's **sensor-exposure moment as epoch ms** — what to time-match `detections` frames against (see §5). Absent on odd HALs; reconstruct older logs as `captured_at_ms + content_lag_ms + live_lag_ms` (approximate — the lag is measured from the takePicture() call, which follows the trigger by the companion-grab gap that `live_lag_ms` brackets). Also present in `gt_capture` records. |

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

### 5b. Time-matching boxes to HIGH-RES photos (round 114)

The `jpeg` join above ties a photo to its **trigger frame** — correct for
fast-path photos and `_live` companions (they show the trigger moment), but a
high-res photo's content lags the trigger by 0.17–0.8 s, so the trigger boxes
often miss the insect's real position on it. Better: join to the `detections`
record whose frame time is **nearest the photo's content moment**. This is
exactly what the in-app summary viewer does on its high-res view.

Recipe (any language):

1. Content moment per high-res photo: `content_at_ms` from its `capture`
   record. Older logs (r108–113): `captured_at_ms + content_lag_ms +
   live_lag_ms` (approximate).
2. Frame time per `detections` record: `frame_sensor_ms`, falling back to
   `frame_ms` (adds a systematic ~50–150 ms "frame is really older" bias).
3. **Capturing a high-res photo pauses the analysis stream** (measured in
   session_16: frame holes of 0.1–1.5 s bracket every capture — exactly
   where the content moment falls). So don't just take the nearest frame:
   for each `track_id` present in the nearest frames BEFORE and AFTER
   `content_at_ms` (within ±1.5 s, total span ≤ 2 s), **linearly interpolate
   `box_in_roi` at the content moment** — the same constant-velocity
   assumption the live tracker makes. Tracks on one side only keep that
   side's box.
4. The tolerance `max(250 ms, 1.5 × median frame interval)` is an HONESTY
   gate for labelling a match good vs approximate — not a reason to discard
   it (a 300 ms-away frame still beats the ~0.5 s-away trigger frame).
   DO reject any photo with a `roi_update` between its trigger and content
   moment + 2.5 s: those boxes are relative to a different ROI.

```r
# R (data.table): nearest detector frame per high-res photo
library(data.table)
lines  <- jsonlite::stream_in(file("session.jsonl"))
caps   <- as.data.table(lines[lines$type == "capture", ])
caps   <- caps[!is.na(content_at_ms)]                 # high-res photos only
frames <- as.data.table(lines[lines$type == "detections", ])
frames[, t := fifelse(is.na(frame_sensor_ms), frame_ms, frame_sensor_ms)]
frames <- frames[!is.na(t)]
tol    <- max(250, 1.5 * median(diff(sort(frames$t))))
setkey(frames, t); caps[, t := content_at_ms]; setkey(caps, t)
joined <- frames[caps, roll = "nearest"]              # one frame per photo
joined <- joined[abs(t - content_at_ms) <= tol]       # honesty gate
# joined$tracks holds the matched boxes (box_in_roi is ROI-normalized,
# i.e. directly drawable on the square photo).
```

```python
# Python (pandas): same join
import pandas as pd
df = pd.read_json("session.jsonl", lines=True)
caps = df[df.type.eq("capture") & df.content_at_ms.notna()].copy()
fr = df[df.type.eq("detections")].copy()
fr["t"] = fr.frame_sensor_ms.fillna(fr.frame_ms)
fr = fr.dropna(subset=["t"]).sort_values("t")
tol = max(250, 1.5 * fr.t.diff().median())
caps = caps.sort_values("content_at_ms")
joined = pd.merge_asof(caps, fr[["t", "tracks"]],
                       left_on="content_at_ms", right_on="t",
                       direction="nearest", tolerance=tol)
```

Error bounds by log generation: r114+ logs with a same-track bracket
interpolate at the exact content moment (error bounded by how non-linear
the insect's motion was across the ≤ 2 s bracket, not by frame cadence);
single-side matches carry the frame's distance (up to ~1.5 s across a
capture pause); r108–113 add the dispatch-gap uncertainty
(≈ `live_lag_ms`, tens of ms); older sessions have no frame timestamps —
only the trigger-frame join applies.

**For pixel-accurate boxes on high-res photos, re-run the detector offline**
on the saved ≤ 1024 px crops (GPU workstation): the files are clean
re-encoded JPEGs, and the filename + JSONL carry every timestamp needed to
tie results back to visits. That looks at the actual pixels instead of
estimating from clocks — the time-match above is the honest *approximation*
for browsing and quick joins. Re-running the detector **on the phone** for
each still *during the session* was considered and rejected: heat is the
app's binding constraint. (Running it **after** the session is fine and
exists since round 135 — see §6.)

## 6. After-session photo analysis (`post_detections.jsonl`)

Rounds 135–139. The Analysis screen can run a detector over a session's
saved `roi_frames/` photos after the fact — mainly to triage AI-free
motion/time-lapse sessions (which photos contain a pollinator; optionally
delete the rest). Results append to `<session>/post_detections.jsonl`,
following the same append-only JSONL rules as `session.jsonl` (§1–§2).
Every record carries `time_ms`/`time_iso` (when it was written). Types:

* `post_start` — one per run: `model`, `model_name`, `confidence`, `iou`,
  `use_gpu`, `photos_total`, `photos_pending`, `app_version`;
  `reanalyzed_all: true` when "Re-analyze photos already done" forced a
  full rerun. When small-insect tiling (SAHI) was on, a `sahi` map records
  the tiling parameters: `tile_px` (resolved tile side — "auto" is already
  resolved to the model's input size here), `overlap` (fraction, e.g.
  `0.25`), `full_pass` (whole-photo pass on/off), `merge_iou` (the
  duplicate-merge threshold), and since round 141 `merge_metric` (`"ios"` —
  overlap measured against the smaller box; a `sahi` map *without*
  `merge_metric` is an r139–140 run that merged by plain IoU and can carry
  extra small contained boxes) plus `min_box_frac` (tile boxes narrower
  than this fraction of the photo side in either direction were dropped;
  `0` = filter off; runs from the short-lived r141 build — 2026-07-23
  morning — required the box to be small in BOTH directions, which let
  elongated border slivers through). No `sahi` key = plain single-pass run.
* `post_detection` — one per analyzed photo: `jpeg` (filename in
  `roi_frames/`, joinable exactly like §5), `captured_at_ms` (parsed from
  the filename), `infer_ms`, and `boxes` — each with `class_name`, `conf`,
  and `box` as `[left, top, right, bottom]` normalized 0–1 **of the photo**
  (same edge order as the live log's `box_in_roi`). A failed photo gets an
  `error` string and empty `boxes`.
* `post_end` — one per run: `processed`, `failed`, `skipped_done`,
  `ended_normally` (plus `reason: "cancelled"` when stopped mid-run).
* `post_cleanup` — audit record of the optional keep/delete storage triage
  (which files were deleted and under which keep rule).

A photo can appear in several runs (re-analysis with another model or other
tiling settings). Take the **last** `post_detection` per `jpeg` — that is
what the app itself does when deciding keeps and drawing review boxes;
match it to its run by reading backwards to the nearest preceding
`post_start`.

**Reading SAHI runs:** the boxes come from overlapping tiles plus (by
default) a whole-photo pass, merged by same-class greedy NMS. In r139–140
runs (no `merge_metric` in the `sahi` map) the merge used plain IoU, so
expect extra small boxes: a partial insect at a tile border merges poorly
with the full-insect box (a small box inside a big one has low IoU). Since
r141 (`merge_metric: "ios"`) such contained boxes merge away, and the
optional `min_box_frac` filter drops speck-sized tile boxes. Either way,
treat the boxes as triage evidence, not tight annotations; for
publication-grade boxes re-run offline (§5b). The tiling is FaunaPulse's own pure-Dart implementation
(`lib/fauna_pulse/postprocess/sahi.dart`), not an external library — concept
background and per-setting docs are in
[SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md#photo-analysis-analysis-screen).
