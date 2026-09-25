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
| `focus_mode` (`manual`/`auto`/`fixed`), `focus_value` | Focus; `focus_value` (0..1) present only for manual. Round 164+: always `manual` (locked at a ~13 cm close-up preset until the user adjusts) or `fixed` (lens without manual focus) — `auto` only occurs in sessions recorded before round 164. |
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

**Imported videos (round 227+):** a session made with *Import videos…* has
`source: "imported_video"` in its start record, plus `imported_at`,
`file_token`, the app/build fields and a `video` summary (`clips`,
`total_duration_ms`, `total_bytes`, and `start_shift_ms` when the user
corrected the start). It has no camera fields and no `config`, because no
camera ran. Its `time_ms` is the first clip's start. See §9.

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

### `gt_capture` — reference photo saves (round 107 as "ground-truth frames"; renamed and on by default in round 152)

One record per periodic **reference photo** (Setup tab → Reference photos; on
by default since round 152, every 30 s). These photos land in `gt_frames/`
(not `roi_frames/`) and are taken on a fixed clock regardless of detections —
an unbiased sample of what the camera saw. Use them to spot pollinators the
live pipeline missed, or to hand-count the true visits when evaluating a
tracker. The wire names are frozen from round 107: record type `gt_capture`,
folder `gt_frames/`, config keys `gtFramesEnabled`/`gtFrameSeconds`. Fields:
`jpeg` (filename), `captured_at_ms` (trigger moment), plus the same
`total_ms` / `bytes` / `path` / `saved_px` stats as a `capture` record.
Deliberately a separate type: never mix these into detection-photo joins.

Round 152 details: files are named
`ref_<token>_<yyyy-MM-dd>_<HHmmss>_<SSS>.jpg`
(`^ref_([a-z0-9]+)_(\d{4}-\d{2}-\d{2})_(\d{6})_(\d{3})\.jpg$`; sessions
recorded before round 152 used the normal `roi_` prefix inside `gt_frames/`).
Reference photos always take the fast live-frame path (`path` is always
`fast`; a high-res capture would stall the detection stream), so they carry
no lag fields. In time-lapse sessions the feature is inert: no `gt_capture`
records, no `gt_frames/` folder, and the two config keys appear in the start
record's `config_not_applicable` list.

### `roi_update` — when the ROI is moved/resized mid-session

Carries the `roi` sub-object, plus `roi_source` (`fast`/`still`; `still` = the high-res path, frozen wire name), `saves_px`
and (round 109+) `roi_side_stream_px` (the on-screen ÷32 side — see the `roi`
note above). Since round 109 these records are **debounced**: one record per
adjustment, written once the box has sat unchanged for ~2 s (a change still
pending when recording stops is flushed, so the session's final ROI is always
on record; an adjustment that ends back on the previous geometry writes
nothing). Sessions recorded before round 109 instead carry one record per drag
tick — take the last of a burst. The summary's Setup tab (labeled "Settings"
before round 182) lists these as "ROI changes during the session".

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

### `timelapse_capture` — one per time-lapse photo (round 97+)

Fields: `jpeg` (filename in `roi_frames/`), `captured_at_ms` (the trigger
moment, same convention as `capture` records) and `burst` (0-based index of
the burst the photo belongs to). `burst` semantics in CONTINUOUS mode (since
round 174: config `timeLapseGapSeconds` = 0, no break; on r97–r173 builds:
`timeLapseIntervalSeconds` ≤ "Photo duration"): before round 173 it was
always `0`; since round 173 it advances every photo-duration block (the fix
for a field bug where a continuous session silently stopped capturing after
the first photo duration — sessions recorded on r97–r172 builds with a
continuous configuration contain ONLY that first burst's photos). Round 174
config-key change: the start record's config block carries
`timeLapseGapSeconds` (the BREAK between bursts, one burst's end to the next
one's start); pre-174 sessions carry `timeLapseIntervalSeconds` instead
(START-TO-START spacing) — convert via gap = interval − duration when
comparing across the change.

### `camera_sleep` — time-lapse camera parking transitions (round 163+)

Written only in time-lapse sessions with "Turn camera off between bursts"
enabled. The camera is fully turned off between bursts and back on shortly
before the next one (the "Camera wake lead" setting,
`timeLapseWakeLeadSeconds`, default 10 s); these records make the resulting
frame-less gaps auditable — "confirmed intentionally off", never "camera
failed".

| Field | Meaning |
|---|---|
| `state` | `parked` (camera off between bursts), `warming` (turned back on, waiting for the first fresh frame), `running` (fresh frames confirmed — photos may flow), `fallback_bound` (a park/wake failed: parking disabled for the rest of the session, camera stays on). |
| `reason` | Why the transition happened: `between_bursts`, `prewake`, `late_wake` (an OS-delayed wake after the burst was already due), `fresh_frame`, `wake_timeout` (no frame within 20 s), `park_failed` / `wake_failed` (the platform call itself errored). |
| `next_burst_at_ms` | The next scheduled burst start (epoch ms) — join against `timelapse_capture` records to see whether a burst started on time, late (`late_wake`), or fell inside a failure. |
| `wake_ms` | On `running` only: how long the wake took, from the turn-on call to the first fresh frame. |

Analysis rule: photos are only captured in `running`/`fallback_bound` states,
so a burst overlapping a `parked`/`warming` gap starts its photos late (the
burst grid itself never shifts). A `fallback_bound` record means every later
gap in that session is real camera time, not parking.

### `torch` — nocturnal time-lapse torch transitions (round 180+)

Written only in time-lapse sessions with "Torch during bursts (night)"
enabled. The LED torch is switched on a lead before each burst (the "Torch
lead" setting, `timeLapseTorchLeadSeconds`, default 5 s) so auto-exposure
settles under the final lighting, and off in the break. Records are written
only on OUTCOME changes (a confirmed on/off flip, or the first failure since
the last success), never per retry, so they stay sparse.

| Field | Meaning |
|---|---|
| `on` | The state the schedule asked for (`true` = torch on). |
| `success` | Whether the camera confirmed it. `false` usually means this lens has no flash unit (the session continues unlit; the app also shows a one-time notice). |
| `reason` | `burst_lead` (scheduled on, lead before a burst), `burst_end` (scheduled off), `camera_parked` (the camera power-off physically killed the LED; it re-lights after the wake), `session_stop`. |

Analysis rule: illumination changes detectability, so treat the torch-on
windows as their own observation condition. The first burst of every
recording (and of every scheduled window) starts immediately and gets no
lead; its earliest photos can still show the exposure settling. Note the
light itself may attract or repel some taxa — a methods consideration for
nocturnal visitation rates.

### `focus_change` — camera focus changed mid-session (round 132+)

Same fields as the start record's focus pair: `focus_mode`
(`manual`; `auto` only in pre-round-164 sessions) and, for manual,
`focus_value` (0..1, 0 = far/infinity).
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
  `battery_voltage_mv`, `charge_counter_uah`, `is_charging`, `is_plugged`
  (round 188+, see the power note below), `thermal_headroom`, `power_w`
  (derived — see the caveat below), and since round 68
  `free_storage_bytes` / `total_storage_bytes` (so the session's disk fill
  rate can be plotted against its photo cadence).
- `fps`: while the motion gate is idle (round 77) the record carries
  `gate_idle: true` and OMITS every inference-derived field — an absent field
  means the detector was off, never a zero reading; summary graphs break
  their lines across such gaps. While awake: `fps` (detector FPS) plus
  per-second camera/detector/pipeline rates, the applied throttle cap
  (`applied_cap_fps`) and the per-stage timing breakdown:
  - `pre_ms` — image preparation: ROI crop, rotate, resize to the model
    input and packing into the input tensor;
  - `inf_ms` — the detector model run ONLY (handing the tensor to the
    LiteRT/NPU interpreter, the network forward pass, reading the outputs
    back). This is what the summary's "Detector inference time" throttle
    graph plots;
  - `post_ms` — output decoding, non-maximum suppression and mapping boxes
    back to image coordinates;
  - `track_ms` — the Dart-side tracker update.
  All four are raw single-frame values captured when the sampler fires, not
  averages; `throttle_inf_ms_ema` is the smoothed inference time the
  auto-throttle controller acts on. (The camera-to-bitmap conversion happens
  before this pipeline and is in none of them.)
- `power`: `power_w`, `battery_current_ua`, `battery_voltage_mv` (mV),
  `charge_counter_uah` (µAh remaining), `is_charging`, `is_plugged`
  (round 188+: any attached power source, even when the battery reports
  "not charging" because it is full — e.g. on a power bank).

**Power & energy: how to read them (accuracy caveats).** The `power` fields
are the phone's own battery-sensor values, logged RAW:

- `battery_current_ua` is microamps per the Android spec, but several phones
  (e.g. the Samsung test device) actually report **milliamps** in this field —
  the raw `power_w` derived from it is then ~1000× too LOW. Other phones
  (e.g. the Xiaomi test device) report a 2-cell series voltage (~8.8 V), which
  makes raw `power_w` ~2× too HIGH.
- The app's summary graph corrects both before plotting: it multiplies the
  current by 1000 when the session's median magnitude says milliamps, halves
  any voltage above 4.6 V down to a single-cell value, lightly smooths
  (3-point moving average), and integrates the corrected curve for the Wh
  total. If you analyse the JSONL yourself, apply the same corrections — or
  sidestep the sensors entirely and use the battery-percent drop
  (`battery_percent` in the start/end records), which is coarse but
  unit-safe on every device.
- Any sample with `is_charging: true` OR `is_plugged: true` makes the whole
  session's power series meaningless as a consumption measure: plugged in,
  the sensor sees the charging current (or ~0 once the charger carries the
  load). The summary hides the graph in that case; do the same in your own
  analysis. Field sessions on a power bank therefore have no valid power
  data by design — record on battery when you want the graph.

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
`unique_track_count`, and a final `thermal` reading. (One exception to "last
line": a `session_renamed` record, below, lands after it if the session was
renamed later — detect a crash by the record's *absence*, as in §2, not by
its position.)

### `session_renamed` — the session was renamed after recording (round 182+)

Written when the user renames a session from the app's home screen (the gear
menu on a session row). The rename also rewrites `config.folderName` in the
`start_of_session` record so the log agrees with the folder; this record is
the audit trail of that edit — the one sanctioned post-recording change to an
otherwise append-only file. It appears AFTER `end_of_session` (one per
rename, so several can accumulate).

| Field | Meaning |
|---|---|
| `old_name` | Folder name before the rename. |
| `new_name` | Folder name after the rename (also the new `config.folderName`). |

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
  Since round 168 also `elapsed_ms` (the run's total wall time, matching
  the duration the app shows when the run finishes) and, for SAHI runs
  only, a `phases` map splitting that time by pipeline phase: counts
  `photos`, `tiled_photos`, `tiles`, `full_passes`, and millisecond totals
  `source_decode_ms` (decoding each source photo), `tile_prep_ms` (cutting
  tiles + re-encoding them to JPEG), `tile_transfer_ms` (background-worker
  startup and byte copies), `tile_predict_ms` / `full_predict_ms` (the
  native detector calls — transfer, native decode and inference in one
  lump), `merge_ms` (duplicate merge), and the convenience sum
  `tile_overhead_ms` (= everything tiling adds outside the detector
  calls). All phase times are summed across the whole run; the difference
  between `elapsed_ms` and the phase sum is file I/O and bookkeeping.
  Since round 177 the map also carries `native_tiled_photos` /
  `native_fallbacks`: photos that went through the native one-call tiled
  path (decode + crop + every tile inference in a single plugin call). For
  those photos `tile_predict_ms` is that whole lump, `source_decode_ms` is
  only a header-only dimension probe, and `tile_prep_ms` /
  `tile_transfer_ms` contribute 0 — a mostly-native run's
  `tile_overhead_ms` is expected to be tiny compared to r168–r176 runs.
* `post_cleanup` — audit record of the optional keep/delete storage triage
  (which files were deleted and under which keep rule: `gap_seconds`, and
  since round 179 `min_box_frac` when the review-time tiny-box filter was
  active — the keep decision then ignored recorded boxes whose narrower
  side was under that fraction of the photo, without altering the
  `post_detection` records themselves).

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

## 7. Derived cache files (safe to ignore)

`<session>/dashboard_stats.json` (round 186+) is an app-derived cache for the
home screen's cross-session Dashboard: the session's start/end, whether the
AI detector ran, and each track id's first/last timestamp — all re-derivable
from `session.jsonl`. It is keyed to the log's size and mtime, so deleting it
is always safe (the app just recomputes it on the next Dashboard visit). It
is NOT part of the scientific record; analysis workflows should read
`session.jsonl` (and `post_detections.jsonl`) only.

## 8. Identification output (`identification/`, round 208+)

"Identify organisms" (session gear menu, or the summary's Photos tab) runs the BioCLIP
image tower over the crops of every tracked visit and writes its files into
`<session>/identification/`. All `.jsonl` files are strict one-object-per-line;
`docs/IDENTIFICATION.md` explains the method, `README_identification.txt` inside the
folder repeats the column dictionary for whoever gets the folder later.

### `embeddings_<model>.jsonl` + `embeddings_<model>.bin`

Append-only (resumable). Records:

| `type` | Fields |
|---|---|
| `identify_start` | the run's settings (`model`, `model_id`, `pack`, `input_size`, `dim`, `accelerator`, `margin`, `min_crop_px`, `max_crops_per_track`, `tau`, `none_threshold`, `thermal_limit_c`, `target_rank`, `use_gpu`, `cpu_threads`), `crops_planned`, `crops_pending`, `crops_done_before`, `app_version` |
| `crop` | `key` (resume key: source|track|box), `src` (file in `roi_frames/` that was cut), `photo` (the log's photo name; differs from `src` when the `_live` companion was used), `box_source` (`trigger` / `live` / `post`), `track_id` (null for post-hoc boxes), `box` `[l,t,r,b]` (0..1 of the photo), `crop_px` (longer box side in photo px), `pad_frac`, `sharpness` (variance of the Laplacian), `det_conf`, `captured_at_ms`, `row` (index of the vector in the `.bin`) |
| `crop_skipped` | `key`, `reason` (`too_small`, `outside`, `decode`, `read_or_decode`, `embed_error`) |
| `identify_end` | `embedded`, `skipped`, `failed`, `thermal_pauses`, `cancelled`, `elapsed_ms`, `avg_embed_ms`, `error` |

The `.bin` holds row-major float32 little-endian unit vectors (`dim` per row). Read in
Python: `np.fromfile(path, dtype='<f4').reshape(-1, dim)`.

### `predictions_<pack>.jsonl`

One `prediction` per crop: `key`, `src`, `track_id` and `top[]` = the five most probable
pack rows with `name`
(Genus epithet, or the "none" key), `family`, `order`, `p`.

### `tracks_<pack>.csv` and `tracks_<pack>.json`

One row (CSV) / object (JSON) per visit (track id); crops without a track id (post-hoc
boxes of no-AI sessions) get one row each with an empty `track_id`.

| Column | Meaning |
|---|---|
| `device_id`, `session_id`, `track_id` | identifiers |
| `track_imgs` | crops used |
| `pred`, `pred_prob_weighted` | the taxon at the chosen target rank (default family) and the track id's Conf. for it (round 219: the counted crops' embeddings averaged with each crop's top-1 probability as weight, scored once, species summed; see IDENTIFICATION.md) |
| `pred_imgs`, `pred_prob_mean` | crops whose own top species falls under that taxon, and the plain (unweighted) mean of the crops' own Conf. under it. Same column names as insect-detect-post, different formulas (there: mean over the voting images times the vote share) |
| `start_time`, `end_time`, `duration_s` | the track's first/last detection (ISO local time) |
| `det_conf_mean` | mean detector confidence of the crops |
| `bioclip_kingdom` … `bioclip_species` | the taxon chosen at each rank on a consistent top-down path (species as "Genus epithet") |
| `p_kingdom` … `p_species` | Conf. of that taxon from the pooled answer (round 219); can exceed every crop's own value when the crops agree |
| `p_mean_<rank>`, `p_max_<rank>`, `p_agree_<rank>` | the plain mean over all crops, the highest single crop, and the mean over the crops whose top species is under the taxon (round 219); `agree_<rank>` × `p_agree_<rank>` reproduces insect-detect-post's weighted probability |
| `identified_rank`, `headline` | deepest rank whose Conf. reached `tau` (default 0.6); the taxon there, or `unidentified` / `no organism` |
| `agree_<rank>` | share of crops whose own top species falls under that taxon (was `support_<rank>` until round 216) |
| `n_crops_used`, `none_p` | crops in the average; mass on the "none of these" rows |
| `best_view_photo`, `best_view_species`, `best_view_p` | the crop whose own top species has the highest probability (the photo the model is surest about on its own, round 217); that species and probability |
| `flags` | `no_organism` (round 221, was `none`: the "none of these" entries took more than the "No organism" threshold; headline `no organism`), `unidentified` (no rank reached `tau`, not even kingdom), `path_conflict` (at some rank a taxon outside the ladder's path has more Conf. than the ladder's pick; the ladder itself stays one consistent path, see `rival_*`), `single_crop`, plus `merged`, `short`, `low_det`, `weak_id`, `suspect` |
| `model_id`, `pack_id` | provenance |
| `merged_track_ids` | round 210, trailing column: every track id of the visit, semicolon-separated (one id unless "Merge consecutive visits" was on; `flags` then also holds `merged`) |
| `n_detections`, `suspect` | round 212: detector frames the track id(s) appeared in; 0/1 verdict of the suspect rule (short AND weakly supported; `flags` carries the parts: `short`, `low_det`, `weak_id`, `suspect`). Nothing is removed from the file |
| `rival_rank`, `rival_taxon`, `rival_p` | round 221, trailing: for a `path_conflict` track id, the highest rank where a taxon outside the ladder's path scored more than the ladder's pick, that taxon (genus + epithet at species) and its Conf.; empty otherwise. Only ranks below the reported one can be affected, because `tau` is at least 0.5 |

### `crops_<pack>.csv` (round 215)

One row per crop (photo × track), for tracing a visit's answer to single photos:
`session_id`, `track_id`, `crop_no` (capture order within the visit), `photo`, `box_left`
… `box_bottom` (detector box as fractions of the photo side), `crop_px`, `sharpness`,
`det_conf`, `pad_frac` (descriptive only since round 217), `top1_species`, `top1_p` (the
species this crop alone predicts and its probability; also the crop's weight in the track
id's answer), `top1_kingdom` … `top1_family` (round 220: that species' higher ranks; kingdom
`none` for a "none of these" entry), `agrees` (1 when that species falls under the visit's reported taxon),
`counted` (round 219: 1 when the crop entered the pooled answer, 0 when it was left out as
far less sure than the surest crop),
`ladder_<rank>` (the visit's ladder taxa, repeated per row) and `p_<rank>` (this crop's own
Conf. under each of them). Identities for checking in R: over a track id's rows, the plain
mean of `p_<rank>` equals `p_mean_<rank>`, the maximum equals `p_max_<rank>`, the mean over
rows whose top species is under the taxon equals `p_agree_<rank>`, and the count of
`agrees == 1` equals `agree_<rank>` × crops at the identified rank. The track's own
`p_<rank>` is NOT a function of these columns (it comes from the averaged embeddings);
recompute it with `tool/bioclip_export/reproduce_track_conf.py`.

To align identifications with the recording: join on `track_id` (the same id as in the
`detections` records of `session.jsonl`; a merged visit lists every member id in
`merged_track_ids`) or, per crop, on the photo file name (`src` here, `jpeg` in the log)
plus box coordinates. Identification results deliberately stay in their own files instead
of `session.jsonl` (raw log vs derived, re-runnable data).

The JSON adds the full `ladder` (`rank`, `taxon`, `p`, `p_mean`, `p_max`, `p_agree`,
`support`; round 221: on every path_conflict row also `rival`, `rival_p` and `rival_lineage`,
the rival's ancestors from kingdom down to one rank above it), every crop with its own top-1, `counted`, `agrees` (round 214: whether that top-1 falls under the reported
taxon; the ladder's `support` at the identified rank is the share of `agrees == true`) and
`p_ladder` (round 215: the crop's own Conf. under each ladder taxon, index = rank),
`top1_tree` (round 220: kingdom … family of the crop's top species; the crops table shows
its family, order and class), `det_conf` (round 223: the live detector's confidence for the
crop's box, as in the crops CSV; `det_conf_mean` is their mean), `best_view`, `flags`, and
the run `settings`.

### `summary_<pack>.json`

Counts for the app: `tracks_total` (visits after the optional merge), `visits_merged`,
`tracks_before_merge` (round 210), `suspect` (round 212), `by_identified_rank`, `no_organism` (round 221, was `none`), `unidentified`,
`taxa_order`, `taxa_family` (visits per taxon among the visits identified at least to that
rank), a compact `tracks[]` list (`track_id`, `track_ids`, `suspect`, `headline`, `identified_rank`, `p`, `n_crops`;
plus `src` = the photo name when the entry is a no-AI per-photo crop, round 209) and the run's
provenance. The app's session summary reads this list to label photos, never the full
tracks file.

R sketch:

```r
tr <- read.csv("identification/tracks_<pack>.csv")
table(tr$identified_rank)
aggregate(track_id ~ bioclip_family, data = subset(tr, p_family >= 0.8), FUN = length)
```

## 9. Imported videos (`videos/`, `video_detections.jsonl`), round 225+

*Import videos…* (home screen ⋮ menu, round 227) makes a session from video files
filmed elsewhere: the phone's camera app, a collaborator, a published dataset. The files
are moved into `<session>/videos/` (names made file-system safe; the original name is
logged). `session.jsonl` then only records where the clips came from: the start record
(§3), one `video_clip` record per clip in start order, and an `end_of_session` with
`ended_normally: true` whose `time_ms` is the last clip's end. It has no `detections` or
`track_event` records; the boxes come from the analysis pass below.

### `video_clip` — one per imported clip

| Field | Meaning |
|---|---|
| `time_ms` | The clip's start (same as `start_epoch_ms`). |
| `file` | Path inside the session folder (`videos/<name>`). |
| `original_name` | The file's name on the phone before the import. |
| `start_epoch_ms` | When the clip started (Unix epoch ms). |
| `start_time_source` | Where that start came from (table below). |
| `start_time_guess_source` | Only when the clip's own guess was replaced (`after_previous` or `user`): what that guess was. |
| `start_time_shift_ms` | Only when the user corrected the start; every clip moves by the same amount. |
| `duration_ms`, `size_bytes` | Length and file size. |
| `width`, `height`, `rotation` | Picture size as seen upright, and the turn (degrees) stored in the file. |
| `codec`, `frame_count`, `fps_mean`, `fps_nominal` | Video format; the mean frames per second from the frames' own time stamps, and the rate the file header claims. Phone videos often have a variable frame rate, so the app computes times from each frame's time stamp, never from frame number ÷ fps. |
| `stored_time_ms` | The time stored in the file, when there is one (see `metadata` below). |

**Where a clip's start comes from** (`start_time_source`), most reliable first:

| Value | Meaning |
|---|---|
| `session_log` | Read back from the `video_clip` record (what the analysis pass uses). |
| `file_name` | A date and time in the file name (`VID_20260924_155954.mp4`, `PXL_…`, `20260924_155954`), as most camera apps write it. |
| `metadata` | The time stored in the file **minus the clip length**: Android phones store when recording *stopped* (checked on a Xiaomi clip, round 226). |
| `file_name_date` | Only the day is in the name (WhatsApp: `VID-20260924-WA0005.mp4`); noon is assumed. Uncertain. |
| `file_time` | The file's modification time minus the length. Uncertain: copying resets it, and the Android file picker copies every file it hands over. |
| `after_previous` | A clip with an uncertain time that would overlap the clip before it, placed right after that clip (so several WhatsApp clips from one day play one after the other instead of all at noon). Clips with a reliable time never move, so a real overlap (two cameras) stays visible. |
| `user` | The user set the start on the import screen. |

When the file name's time and the stored time differ by more than 2 minutes, the name wins
but the import screen marks the time as uncertain. Messengers such as WhatsApp remove the
stored time; video editors reset it to the export time.

### `video_detections.jsonl` — "Run AI on videos" (round 225+)

"Run AI on videos" (home screen) runs a detector over every clip and appends to
`<session>/video_detections.jsonl`, following the same append-only JSONL rules as
`session.jsonl` (records carry `time_ms` = when written, no `time_iso`):

* `video_run_start` — one per run: `settings` (`model`, `confidence`, `iou`,
  `analysis_fps` = frames looked at per video second, `roi` = `[center_x, center_y, side]`
  as fractions of the upright picture, side as a fraction of its width, or `null` for the
  whole picture, `max_side_px`), `model_name`, `use_gpu`, `thermal_limit_c` (the pause
  temperature, round 229+), `clips_total`, `clips_pending`, `started_over` (when earlier
  results were replaced), `app_version`.
  Results made with other `settings` are never mixed: a run with changed settings asks,
  then starts the file over.
* `video_clip_start` — per clip: `clip`, `start_epoch_ms`, `start_time_source`,
  `resume_from_pts_us` (when a stopped run continued), and the format fields.
* `raw_detections` — per analysed frame: `clip`, `pts_us` (the frame's time stamp in the
  file), `frame` (0-based in display order, as CVAT counts), `frame_ms` (epoch ms = clip
  start + time stamp offset) and `boxes` as `[left, top, right, bottom, conf, class]`
  normalized 0–1 **to the whole upright frame**, also with a square. This is the live
  log's `raw_detections` shape (§3), so the tracker replay tools read it.
* `video_clip_done` — per clip: `frames_analysed`, `frames_decoded`, `frame_width`,
  `frame_height`, `roi_px` (the square in video pixels), `class_names`, and time sums
  `decode_ms`, `convert_ms`, `infer_ms`, `elapsed_ms`. `video_clip_error` instead when a
  clip failed (`error`, `at_pts_us`).
* `video_run_end` — `clips_done`, `clips_failed`, `frames_analysed`, `thermal_pauses`,
  `elapsed_ms`, `ended_normally` (plus `reason: "cancelled"` when stopped).

The file holds boxes only; the next files turn them into visits.

### Visits: `post_tracks.jsonl`, `visits.csv`, `mot/` (round 228+)

*Find visits* (under the analysis on the "Run AI on videos" screen, and automatically
after each finished analysis) runs the boxes through the same tracker a live session
uses (ByteTrack or C-BIoU, chosen under camera Settings, with the screen's own
**occlusion tolerance** and **minimum visit length**). It follows each insect from frame
to frame, so one insect seen in many frames counts as one visit. It takes seconds and
never re-runs the detector, so it can be repeated with other settings; each run
**replaces** these three outputs (each is written under a temporary name and renamed when
complete, so a crash never leaves half a file in place of a good one):

* `post_tracks.jsonl`: shaped like the live log. `post_track_start` first (`run_id`,
  `detections_run_ms` = `time_ms` of the analysis run's first `video_run_start`, the
  `detection_settings`, `occlusion_seconds`, `min_hits_seconds`, `tracker` = the effective
  tracker parameters, `clips`, `observed_ms` = filmed time of the tracked clips, overlaps
  counted once (round 229+), `clips_continuing_previous`, `clips_left_out`), then
  `detections` and `track_event` records as in §3 (with `time_ms` = the frame's own time,
  plus `clip`, `frame` and `pts_us`; `box_in_roi` relative to the analysed square, as live),
  and `post_track_end` last (`visits`, `frames`, `detections`, `clips_tracked`,
  `elapsed_ms`).
* `visits.csv`: one row per visit (confirmed track id), for spreadsheets and R:
  `track_id, clip, start_time` (wall clock), `start_s, end_s, duration_s` (seconds from
  the start of the clip the visit began in, the position a video player shows),
  `n_frames` (frames with a box), `mean_conf` and `class` (the class seen in most frames).
* `mot/<clip>.txt`: every tracked box in the MOTChallenge text format
  `frame,id,x,y,w,h,conf,-1,-1,-1` (frames counted from 1 in display order, box
  left/top/width/height in video pixels). Tracking benchmarks (TrackEval) read it as is;
  for CVAT, `tool/video_eval/mot_to_cvat.py` adds the class column CVAT expects (round
  230). A clip without any box gets an empty file.

Worth knowing when comparing with a hand count:

* As in live sessions, a track shows up only once confirmed (after the minimum visit
  length), so `mot/` and `detections` lack each visit's first frames. `start_s` is the
  tracker's first sighting, before confirmation; `n_frames` counts from confirmation.
* Only clips whose analysis finished are tracked (`clips_left_out` lists the others).
* One tracker follows an insect from one clip into the next only when the next clip's
  first analysed frame comes after the previous clip's last one, within the occlusion
  tolerance (clips recorded back to back). The visit keeps the first clip's clock, so its
  `end_s` can exceed that clip's length. Otherwise the tracker starts afresh, since
  imported files can overlap or carry wrong clocks. Track ids stay unique per session.
* Times come from each frame's own time stamp, never from frame number ÷ fps.
* At a low analysis rate, keep the occlusion tolerance well above the time between two
  analysed frames, or every visit breaks into pieces.

*Share results* zips `visits.csv`, `mot/`, `post_tracks.jsonl`, `video_detections.jsonl`
(to track again on a computer) and `session.jsonl` (clip start times). How to count the
same clips by hand, score the app against that count and find the lowest frame rate that
still counts visits correctly: [VIDEO_ANALYSIS.md](VIDEO_ANALYSIS.md) (round 230).

### Where the app reads these visits (round 229+)

The session summary (visit count and timeline, Setup rows), the dashboard and
identification read a session's visits from **one** file: `post_tracks.jsonl` when it
exists and the session did not track live (imported videos, or a motion or time-lapse
session), `session.jsonl` otherwise. The two are never added together. The dashboard counts
an imported session once *Find visits* has run, and its visits per hour use `observed_ms`
(the filmed time), not the span from the first clip's start to the last one's end, since
the gaps between clips were not filmed. A problem report carries the run records of both
files (`video_detections_runs.jsonl`, `post_tracks_runs.jsonl`), without the per-frame
boxes.

### The Video tab: watching the boxes (round 231+)

For an imported video session the summary's first tab is **Video** (live sessions keep
*Photos*). It plays the session's clips with the AI's boxes drawn on them, so you can see
what the AI found and whether the analysed square was well placed. The tab only reads
`video_detections.jsonl` and `post_tracks.jsonl`; it writes nothing.

* **Which boxes show at a moment.** The player's position counts from the clip's first
  frame, the same clock as `start_s`/`end_s` in `visits.csv`. It shows the boxes of the
  last analysed frame at or before that position and keeps them for at most 1.5 times the
  step between analysed frames (150 ms at 10 frames per second). Parts of a clip that were
  never analysed (a gap, the tail of a stopped analysis) show no boxes, never old ones. At
  an analysis rate below the video's frame rate the boxes move in small steps, and at
  higher playback speeds they can trail a fast insect a little.
* **Visits or all AI boxes.** Once *Find visits* has run, the boxes are the tracked ones
  from `post_tracks.jsonl`, labelled `#<track id> class conf` with the same number as in
  `visits.csv`. A faded box is a frame where the detector missed the insect and the tracker
  kept its place. The *All AI boxes* switch shows every `raw_detections` box instead,
  including those *Find visits* did not count (a visit shorter than the minimum length,
  or the frames before a track was confirmed, see above). Before *Find visits*, and when
  the videos were analysed again after it (the visits' `detections_run_ms` no longer
  matches the analysis run), only the AI boxes are shown, with a note.
* **Whole frame or what the AI saw.** When a square was analysed, *Whole frame* draws it
  and darkens the part left out; *What the AI saw* zooms onto the square. The square comes
  from `roi_px` in `video_clip_done`, or from the run's `settings.roi` for a clip whose
  analysis has not finished. Insects outside the square or cut by its edge mean the square
  should move: *Change square and analyse again* opens *Run AI on videos* for the session,
  and the tab reloads on return.
* **Controls.** Tap the video to pause or play; 5 s back and forward; previous and next
  visit (each starts 1 s before the visit); speed 0.5×, 1×, 2× or 4×; sound is off until
  switched on. The coloured bars under the time bar mark the visits, and tapping a visit in
  the list below the player jumps to it.
