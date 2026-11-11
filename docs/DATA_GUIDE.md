# Data guide: reading `session.jsonl` and computing visitation rates

This page is for researchers (and their analysis scripts) who turn a recorded session into
numbers. The app's scientific result is the **visitation rate**: how often and how long insects
visit a flower. This page shows how to get there from the raw log, and what the main files in a
session folder hold.

Notes on older files, long reasons and code examples are in folded blocks: click a line that starts
with ▸ to open it.

> **In short**
>
> - Every session folder holds `session.jsonl`: one JSON object per line, written while the
>   session runs (imported sessions: at import). When the file has no `end_of_session` line
>   (normally the last line; a rename or a video deletion adds lines after it), the recording
>   stopped abnormally ([§1](#1-the-file-format), [§2](#2-detecting-a-clean-vs-crashed-session)).
> - A `detections` line is one analysed camera frame with insects. A track ID is all entries that share one
>   `track_id`. Visitation rate = number of track IDs ÷ observation time
>   ([§4](#4-computing-visitation-rate), with R and Python code).
> - Photos join to boxes by file name (`jpeg`); high-res photos join better by time
>   ([§5](#5-joining-photos-to-detections)).
> - Results made after recording have their own files: photo analysis ([§6](#6-after-session-photo-analysis-post_detectionsjsonl)),
>   identification ([§8](#8-identification-output-identification)), imported videos and their
>   track IDs ([§9](#9-imported-videos-videos-video_detectionsjsonl)).
>   `session.jsonl` stays the raw log.
> - Some fields exist only in sessions from newer app builds. The folded blocks *Older files*
>   say what older sessions contain.

**Contents**

- [Which file answers which question](#which-file-answers-which-question)
- [Track IDs and visits](#track-ids-and-visits)
- [1. The file format](#1-the-file-format)
- [2. Detecting a clean vs crashed session](#2-detecting-a-clean-vs-crashed-session)
- [3. Record types (data dictionary)](#3-record-types-data-dictionary)
- [4. Computing visitation rate](#4-computing-visitation-rate)
- [5. Joining photos to detections](#5-joining-photos-to-detections)
- [6. After-session photo analysis](#6-after-session-photo-analysis-post_detectionsjsonl)
- [7. Derived cache files (safe to ignore)](#7-derived-cache-files-safe-to-ignore)
- [8. Identification output](#8-identification-output-identification)
- [8b. Sessions imported from FaunaLapse](#8b-sessions-imported-from-faunalapse)
- [9. Imported videos](#9-imported-videos-videos-video_detectionsjsonl)

## Which file answers which question

- **Did the session end normally?** `session.jsonl`: `end_of_session`, [§2](#2-detecting-a-clean-vs-crashed-session)
- **Which settings were used?** `start_of_session`: `config`, [§3](#start_of_session)
- **Site, field notes, position?** `start_of_session`: `field`, [§3](#start_of_session)
- **How many track IDs, how long?** `detections`, `track_event`, [§4](#4-computing-visitation-rate)
- **Which photo shows which insect?** `jpeg`, `capture`, `roi_frames/`, [§5](#5-joining-photos-to-detections)
- **Phone heat, frame rate, power?** `thermal`, `fps`, `power`, [§3](#thermal-fps-power)
- **Which photos hold an animal?** `post_detections.jsonl`, [§6](#6-after-session-photo-analysis-post_detectionsjsonl)
- **Which taxon is each track ID?** `identification/tracks_<pack>.csv`, [§8](#8-identification-output-identification)
- **Where did a FaunaLapse session come from?** `faunalapse_session.jsonl`, [§8b](#8b-sessions-imported-from-faunalapse)
- **Boxes and track IDs in videos?** `video_detections.jsonl`, `post_tracks.jsonl`, `track_ids.csv`, [§9](#9-imported-videos-videos-video_detectionsjsonl)
- **The phone during a video analysis?** `phone_during_analysis.csv`, [§9](#the-phone-during-the-analysis)
- **The phone during an identification?** `identification/phone_during_identification.csv`, [§8](#the-phone-during-the-identification)
- **The Dashboard's numbers?** `dashboard_stats.json` (a cache), [§7](#7-derived-cache-files-safe-to-ignore)

For the photo-resolution side of the data (`saves_px`, `analysis_frame_*`), see
[HOW_PHOTO_RESOLUTION_WORKS.md](HOW_PHOTO_RESOLUTION_WORKS.md).

## Track IDs and visits

The app records every insect it follows from frame to frame as a **track ID**. It says "track
ID" everywhere: on screen, in file names (`track_ids.csv`) and in field names (`track_ids`,
`track_ids_run_id`, …).

In pollination ecology a track ID usually stands for one **visit** (an insect's stay on the
flower), and the visitation rate below is computed from track IDs. The two differ where
detection or tracking failed:

- some track IDs are false detections (a leaf, a shadow);
- one insect can be split into several track IDs (hidden longer than the occlusion tolerance);
- two insects can be merged into one.

[VIDEO_ANALYSIS.md](VIDEO_ANALYSIS.md) shows how to measure that against a hand count.

<details>
<summary>Old names with "visits" (files from older app builds)</summary>

These names were renamed in round 248. The app and the PC scripts still read the old names in
files written before.

| Now | Before round 248 |
|---|---|
| `track_ids.csv` | `visits.csv` |
| `post_track_end` field `track_ids` (`post_tracks.jsonl`) | `visits` |
| `track_ids_run_id` (`identify_start`, identification summary `capture`, `video_cleanup`) | `visits_run_id` |
| identification settings `merge_track_ids`, summary `track_ids_merged` | `merge_visits`, `visits_merged` |
| `video_cleanup` mode `without_track_ids` | `without_visits` |
| `dashboard_stats.json` field `track_ids` | `visits` |
| frame-rate sweep files `track_ids_<tracker>_<fps>fps.csv` | `visits_<tracker>_<fps>fps.csv` |
| `tool/video_eval/evaluate_track_ids.py`, score column `app_track_s` | `evaluate_visits.py` (still runs), `app_visit_s` |

</details>

---

## 1. The file format

Each session writes `session.jsonl`: **one JSON object per line** (newline-delimited JSON,
"JSONL"). This is on purpose. Unlike one big JSON array, lines can be added without rewriting
the file, so a crash or a dead battery never damages what was already saved. **The file is
then simply missing its final `end_of_session` line, and that is how you detect an abnormal
stop.**

Every line has:

- `type`: the record kind (see §3);
- `time_ms`: Unix epoch milliseconds (for computation);
- `time_iso`: human-readable ISO-8601 with local offset, e.g. `2026-07-04T19:03:12.123+02:00`.

Reading it:

- **R:** `jsonlite::stream_in(file("session.jsonl"))` or
  `jsonlines::read_json_lines("session.jsonl")`
- **Python:** `pandas.read_json("session.jsonl", lines=True)` or the `jsonlines` package.

## 2. Detecting a clean vs crashed session

```r
lines <- jsonlite::stream_in(file("session.jsonl"))
ended_ok <- any(lines$type == "end_of_session")   # FALSE => crashed / killed
```

The data of a crashed session up to the last written line is still valid. You only miss the
end-of-session totals, and the last ~0.5 s of detections may be missing (writes are flushed
roughly twice a second).

## 3. Record types (data dictionary)

Fields shared by every record: `type`, `time_ms`, `time_iso`.

| Record (`type`) | Written |
|---|---|
| [`start_of_session`](#start_of_session) | once, first line |
| [`detections`](#detections) | per processed frame with insects |
| [`track_event`](#track_event) | when a track ID changes life stage |
| [`raw_detections`](#raw_detections) | per frame, only with an evaluation switch on |
| [`gt_capture`](#gt_capture) | per reference photo |
| [`roi_update`](#roi_update) | when the ROI was moved or resized |
| [`motion_gate`](#motion_gate) | when the detector sleeps or wakes |
| [`blackout`](#blackout) | when the screen-off cover goes up or down |
| [`screen`](#screen) | when the app goes off or on screen |
| [`guard_stop`](#guard_stop) | when the recording stopped itself |
| [`motion_capture`](#motion_capture) | per photo in a motion session |
| [`timelapse_capture`, `timelapse_skipped`](#timelapse_capture) | per time-lapse photo; per gap |
| [video records](#timelapse_video_start-video_clip-video_skipped) | per video clip of a burst or live piece |
| [`camera_sleep`](#camera_sleep) | time-lapse camera off and on |
| [`torch`](#torch) | night torch on and off |
| [`focus_change`](#focus_change) | when the focus was changed |
| [`thermal`, `fps`, `power`](#thermal-fps-power) | samples at a fixed interval |
| [`capture`](#capture) | per saved ROI photo |
| [`app_error`](#app_error) | per error during recording |
| [`end_of_session`](#end_of_session) | once, last line (absent = crash) |
| [`session_renamed`](#session_renamed) | per rename, after the end |
| [`video_cleanup`](#freeing-storage-deleting-the-videos) | per video deletion, after the end |

### `start_of_session`

One per session, the first line. Session-wide metadata. Notable fields:

- `session_id`: Unique id for this recording.
- `device`: Device descriptor (model/id).
- `app_version`, `app_build`: Which app binary recorded the session (pubspec version + build number). Needed when comparing performance across sessions: behaviour changes between versions.
- `build_mode`: `release`, `profile` or `debug`. A `flutter run` debug build performs measurably worse than the release APK, so performance comparisons must not mix modes.
- `blackout_at_start`: Present (`true`) when recording started with the screen-off cover already up (scheduled runs). Screen changes after that are `blackout` records.
- `battery_percent`: Battery level at start.
- `phone_state`: Phone settings at Start, as in FaunaLapse (keys below the list).
- `field`: The field notes, in the same form as FaunaLapse (keys below the list).
- `free_storage_bytes`, `total_storage_bytes`: Free/total bytes on the session's storage volume at start.
- `model_path`, `task`, `use_gpu`, `cpu_threads`: Requested model and task settings, and the number of CPU threads set for the detector.
- `accelerator`: What was **actually** used (e.g. GPU, or CPU fallback for int8 models); the summary's *Detector ran on* row.
- `cpu_16bit` (only when `accelerator` is CPU): `true` when the CPU computed with 16-bit numbers, `false` for 32-bit. Since app round 367 the CPU uses 16-bit maths when the model file is in 16-bit: about twice as fast, and the boxes differ from 32-bit about as much as between CPU and GPU (the GPU always uses 16-bit). Files with 8-bit weights (for example MegaDetector) and phones without 16-bit maths use 32-bit. No key in older sessions: their CPU used 32-bit.
- `camera_full_width_px`, `camera_full_height_px`: Full-resolution (high-res) photo size.
- `capture_dims_from_cache`: Present (`true`) when recording started before the live photo probe confirmed the cached photo size: the sizes above came from the previous measurement.
- `location`: The session's single location fix: `lat`, `lon` (decimal degrees), `accuracy_m` (GPS only), `fix_time_ms`, `source` (`gps` / `manual` / `previous`). Absent when no location was set. Stripped from problem-report samples.
- `selected_lens_zoom`, `selected_lens_label`: Which rear lens was used.
- `focus_mode`, `focus_value`: Focus. `focus_mode` is `manual` (locked at a ~13 cm close-up preset until the user adjusts) or `fixed` (lens without manual focus); `auto` occurs only in older sessions. `focus_value` (0..1) is present only for manual.
- `confidence_threshold`, `iou_threshold`: Detection thresholds.
- `tracker_params`: The tracker settings that ran: `algorithm` (`bytetrack` or `cbiou`) and the frame counts derived from the seconds set by the user at the session's frame rate. The seconds themselves are in `config`.
- `step_seconds`, `duration_seconds`, `session_minutes`: Timing config.
- `roi`: Starting ROI geometry (see the `roi` sub-object below).
- `roi_source`, `saves_px`: Which source the ROI photo comes from, and the exact saved pixel side.
- `roi_side_stream_px`: The ROI side in the **stream grid**: the ÷32 number shown on screen while recording (e.g. 480). Prefer this for "how big was the box". The `roi` block may express the same square against the full-res high-res frame (e.g. 1333 on a 3000-wide frame = the same 480 box).
- `analysis_frame_width_px`, `analysis_frame_height_px`: Live analysis-frame size.
- `inference_fps`, `*_sample_seconds`: Rate cap and logging cadences. `inference_fps` is the rate that ran (never above the camera cap); `config.inferenceFps` keeps the value typed.
- `config`: **A complete self-describing copy of every setting used**: the most reliable source for your methods section. The single keys above are kept for older readers.
- `config_not_applicable`: List of `config` keys that had **no effect** under this session's `captureTrigger` (details below the list).
- `thermal`: A starting reading of the battery temperature, power, memory and processor use (see the `thermal` block below).
- `schedule`: Scheduled runs only: which slot this session is. `day` and `window` (both counted from 1), `days_total`, `windows_per_day`, `window_start`, `window_end`. Absent for a session started by hand.
- `file_token`: The short random code of this session that is part of every photo and video clip filename, so photos stay traceable to their session after folders from several phones are merged.

**`config_not_applicable`.** Examples: all model and tracker keys in a motion or time-lapse
session; the motion-gate keys in time-lapse; `motionGateEnabled` in a motion session, where the
gate always runs (the trigger no longer stores the switch on). The values themselves stay
present with their normal types. Filter on this list (or on `captureTrigger`) instead of
expecting missing fields or `"n/a"` strings, so typed parsing (pandas dtypes) never breaks.

**`phone_state`** holds the phone settings at Start (true/false, null when unknown):
`airplane_mode`, `wifi_on`, `bluetooth_on`, `location_on`, `stay_awake_while_charging`,
`battery_optimisation_on` (Android's battery limits apply to the app), `background_restricted`,
`battery_saver_on`.

**`field`** holds the field notes (camera screen → pin with a pencil → **Field notes**), in the
same form as the `field` block of the sister app FaunaLapse, so one script reads both apps.
Every key is always present, null when empty:

- `phone_maker`, `phone_model`: The phone.
- `phone_id`: Always null in FaunaPulse.
- `setup_by`, `site`, `transect`, `plant`, `habitat`, `sample_id`, `session_id`: Field notes entries.
- `device_id`: The *Device ID* field: a short name for the phone that names the device (see §8). FaunaLapse is to add the same key.
- `camera_height_m`, `detection_distance_m`: Numbers, in m.
- `detection_distance_source`: `typed` or null.
- `site_photos_about`: The note about the site photos, cleared after each Start.
- `custom`: The user's own fields by name (below).
- `location`: null, or a position (below).
- `site_photos`: The names of the photos moved into the session's `site_photos/` folder at Start, `yyyyMMdd_HHmmss_SSS.jpg`.

- **`custom`:** a number for a number field, true/false for yes or no, `yyyy-MM-dd` for a date,
  `HH:mm` for a time, else text, null when empty; then `"Notes"` when notes were written. An own
  field named `Device ID` (as FaunaLapse's help suggests) names the device when `device_id` is
  empty, see §8.
- **`location`:** `latitude`, `longitude` with 6 decimals, `datum` `WGS 84`, `source`
  `gps`/`typed`/`previous`, `coordinate_uncertainty_m`, `satellites_used` (null),
  `uncertainty_goal_m` (the user's GPS goal for a GPS position, default 10), `fix_time` ISO or
  null. The older top-level `location` stays as before.
- **Problem reports** replace every position and every value of this block with
  `"[redacted]"` (the keys stay, in `custom` too), except `phone_maker`, `phone_model`,
  `phone_id`, `camera_height_m`, `detection_distance_m`, `detection_distance_source` and
  `site_photos`.

The `roi` sub-object (also used in `roi_update`):

| Field | Meaning |
|---|---|
| `center_x_norm`, `center_y_norm` | ROI centre as a fraction (0..1) of the frame. |
| `width_px`, `height_px` | ROI side in pixels (square, so equal). |
| `frame_width_px`, `frame_height_px` | The frame these are relative to. |

> ⚠ `width_px` is relative to whichever frame the photos were being saved from
> (`frame_width_px`). On the high-res path that is the full-resolution photo, so it is usually
> **larger** than the box the user saw. For the on-screen ÷32 size use `roi_side_stream_px`.

**Imported videos:** a session made with **Import videos…** has `source: "imported_video"` in
its start record, plus `imported_at`, `file_token`, the app/build fields and a `video` summary
(`clips`, `total_duration_ms`, `total_bytes`, and `start_shift_ms` when the user corrected the
start). It has no camera fields and no `config`, because no camera ran. Its `time_ms` is the
first clip's start. See §9. (Sessions imported from FaunaLapse: §8b.)

<details>
<summary>Older files: <code>start_of_session</code></summary>

When each field arrived (sessions recorded with older builds do not have it):

- Round 68: `free_storage_bytes`, `total_storage_bytes`.
- Round 109: `roi_side_stream_px`. For older logs recompute the on-screen size as
  `width_px / frame_width_px × analysis_frame_width_px`, snapped to the nearest multiple of 32.
- Round 121: `capture_dims_from_cache`.
- Round 126: the top-level `location`.
- Round 132: `app_version`, `app_build`, `build_mode`, `blackout_at_start`.
- Round 147: `config_not_applicable`.
- Round 164: `focus_mode` is always `manual` or `fixed`; `auto` occurs only in sessions recorded
  before round 164.
- Round 227: imported video sessions.
- Round 297: the `field` block. Round 298: `phone_state`. Round 301: `custom`. Round 302:
  `site_photos_about`, `site_photos`, and `uncertainty_goal_m` default 10 since round 302.
- Round 313: in a motion session the trigger no longer stores the `motionGateEnabled` switch
  on; the top-level `inference_fps` is the rate that ran, `config.inferenceFps` the value typed (0 = same as the camera).
- Round 335: FaunaPulse's help suggested an own field named `Device ID`, as FaunaLapse's help
  does. Round 336: the `device_id` key (the *Device ID* field).

</details>

### `detections`

The core record: one per processed frame with insects. This is what you count. One line per
frame; the frame's insects are entries in its `tracks` array:

| Field | Meaning |
|---|---|
| `tracks` | Array with one entry per tracked insect this frame. Entry fields below. |
| `tracks[].track_id` | **Stable ID for one insect across frames: this defines a track ID** (in pollination ecology usually one visit, see [Track IDs and visits](#track-ids-and-visits)). |
| `tracks[].class_index`, `tracks[].class_name` | Detected class. |
| `tracks[].confidence` | Detection score (0..1). |
| `tracks[].box_in_roi` | Bounding box **relative to the ROI**, all edges in 0..1 (`{left, top, right, bottom}`). 0 = the ROI's left/top edge, 1 = its right/bottom edge. |
| `tracks[].jpeg` | Filename of the ROI photo that covered this track at this moment; **absent** when no photo was saved for it on this frame. |
| `frame_ms` | The frame's epoch stamp on the **emit clock** (recorded when the native side finished inference and emitted the result, ~50–150 ms after the sensor exposure). Same clock basis as `raw_detections.frame_ms`, on purpose: one key name, one meaning. |
| `frame_sensor_ms` | The frame's **sensor-exposure moment** mapped to epoch ms: the precise stamp, directly comparable to a `capture` record's `content_at_ms`. Absent on HALs without a usable sensor clock; prefer it over `frame_ms` when present. |
| `tracks[].coasted` | Safety flag, normally **absent**: every box in a `detections` record is detector-observed (the tracker never logs its velocity-predicted positions). It would read `true` only if a future tracker version logged a predicted box: treat such an entry as an estimate, not an observation. |

> Note: a `detections` line is written for **every processed frame** with at least one tracked
> insect, not once per track ID. You rebuild a track ID by grouping consecutive entries that
> share a `track_id` (see §4).

<details>
<summary>Older files: <code>detections</code>, and the legacy <code>detection</code> lines</summary>

- The `tracks` array exists since round 69. `frame_ms` and `frame_sensor_ms` exist since
  round 114, `tracks[].coasted` since round 116.
- **Legacy format (sessions recorded ≤ round 68, 2026-07-05):** one `"type": "detection"` line
  per insect per frame, with the entry fields at the top level and `jpeg: null` when no photo
  was saved. Same information. Scripts should accept both (the snippets in §4 do). The in-app
  summary screen reads both formats too.

</details>

### `track_event`

One line every time a track ID changes life stage. Without these lines a track ID simply stops
appearing in `detections` records, and you cannot tell *why*: a briefly hidden insect, an
insect gone for good, or simply no frames analysed at all (a high-res photo pauses the analysis
stream for 0.13–1.5 s, see §5b). These records make the four cases explicit:

| `event` | Meaning |
|---|---|
| `created` | The track was matched in enough frames to count as a track ID; its id starts appearing in `detections` records from here. |
| `lost` | The first frame the track was **not** matched (occlusion, missed detection, or the insect left). The id stays buffered for the occlusion tolerance in case it comes back. |
| `recovered` | The lost track was matched again: same id, the same track ID continues. |
| `removed` | The id is gone for good. `reason` says why (table below). |

The `reason` of a `removed` line:

| `reason` | Meaning |
|---|---|
| `aged_out` | Unmatched longer than the occlusion tolerance. |
| `gate_expired` | The motion gate slept longer than the tolerance, so the stale id must not be revived by a newly arriving insect. |
| `frame_gap_expired` | No frames came for longer than the tolerance (for example the camera stopped for a while); same reason. |

Fields on every `track_event` line:

| Field | Meaning |
|---|---|
| `track_id` | Which track the transition belongs to. |
| `frame_ms` | The transition's frame timestamp (ms since epoch). For `gate_expired` removals it is the **last processed frame before the gate slept**; the line's own `time_ms` carries the wake moment. |
| `box_in_roi` | The track's box at the transition, ROI-relative 0..1 as in `detections`. For `lost` it is the last box that was actually observed. |
| `hits` | Total matched frames for this track so far. |
| `first_seen_ms` | When the track's very first detection was seen: the **real track ID start** (see below). The app and `track_ids.csv` start a track ID here (§4). |
| `last_seen_ms` | The last real observation. On a `recovered` line this is the moment before the gap, so `frame_ms − last_seen_ms` = the gap the id survived. |
| `frames_missed` | Unmatched frames at the transition (only written when > 0). |
| `reason` | Removals only: `aged_out` / `gate_expired` / `frame_gap_expired`. |

`first_seen_ms` comes before `created` by the frames the tracker needs before it confirms a
track ID. For example, a minimum track length of 1 s at 5 frames per second needs 5 frames, so
`first_seen_ms` is 4 frame steps (0.8 s) earlier.

How to use them:

- **Track ID boundaries without per-frame grouping:** a track ID runs from `first_seen_ms` (on
  its `created` line) to `last_seen_ms` (on its `removed` line). The §4 snippets group the
  `detections` frames and take the start from the `created` line, because `detections` lists a
  track only from its confirmation on. A track ID still open when the session ended has no
  `removed` line; its last `detections` frame is its end.
- **Temporary loss vs analysis pause:** a `lost` → `recovered` pair brackets a real tracking
  gap. A hole in `detections` timestamps with **no** `lost` line in it is an analysis pause
  (photo grab, throttle), not a lost insect.
- **Stitching fragmented ids:** when the tracker splits one insect into several ids, you see a
  `removed` and a `created` close together in time (`frame_ms`) and space (`box_in_roi`). That
  is your cue to consider merging those ids into one track ID during analysis.

<details>
<summary>Older files: <code>track_event</code></summary>

`track_event` lines exist since round 116. Sessions recorded before round 116 do not have them:
there, a track ID simply stops appearing in `detections` records and you cannot tell why.

</details>

### `raw_detections`

Boxes before tracking, only when the evaluation switch is on. Written only when **Session settings** →
**Detection** tab → **Tracking** → **Advanced (ByteTrack tuning)** (named **Advanced (C-BIoU tuning)** when that tracker is chosen) → **Log raw detections (evaluation)** is on: one line per
processed frame (empty frames included, because the tracker ages its tracks by frames) with the
detector's boxes **before** tracking. This is the input the offline tracker replay harness uses
to compare association algorithms on real data.

| Field | Meaning |
|---|---|
| `frame_ms` | The frame's timestamp (ms since epoch). Use this, not `time_ms` (which is stamped at log-queue time). |
| `boxes` | Array of `[left, top, right, bottom, confidence, class_index]`, boxes **frame-normalized** 0..1 (not ROI-relative like `box_in_roi`). |

<details>
<summary>Replaying the tracker, and older files</summary>

Replay command:
`flutter test test/fauna_pulse/tracker_replay_test.dart --dart-define=REPLAY_SESSION=…/session.jsonl`.

`raw_detections` lines exist since round 105.

</details>

### `gt_capture`

One record per periodic **reference photo** (Setup tab → **Reference photos**; on by default,
every 30 s). These photos land in `gt_frames/` (not `roi_frames/`) and are taken on a fixed clock
regardless of detections: an unbiased sample of what the camera saw. Use them to spot
pollinators the live pipeline missed, or to hand-count the true track IDs when evaluating a
tracker.

| Field | Meaning |
|---|---|
| `jpeg` | Filename. |
| `captured_at_ms` | The trigger moment. |
| `total_ms`, `bytes`, `path`, `saved_px` | The same stats as a `capture` record. |

- **Never mix these into detection-photo joins.** They are a separate type on purpose.
- **File names:** `ref_<token>_<yyyy-MM-dd>_<HHmmss>_<SSS>.jpg`
  (`^ref_([a-z0-9]+)_(\d{4}-\d{2}-\d{2})_(\d{6})_(\d{3})\.jpg$`).
- **Always the fast path:** reference photos always take the fast live-frame path (`path` is
  always `fast`; a high-res capture would stall the detection stream), so they carry no lag
  fields.
- **Time-lapse:** the feature is inert. There are no `gt_capture` records and no `gt_frames/`
  folder, and the two config keys appear in the start record's `config_not_applicable` list.
- **Frozen names:** the record type `gt_capture`, the folder `gt_frames/` and the config keys
  `gtFramesEnabled`/`gtFrameSeconds` keep the names of the feature's first version
  ("ground-truth frames").

<details>
<summary>Older files: <code>gt_capture</code></summary>

Round 107 added these records as "ground-truth frames"; the wire names are frozen from round
107. Round 152 renamed the feature to reference photos and turned it on by default (every
30 s), and gave the files the `ref_` names above. Sessions recorded before round 152 used the
normal `roi_` prefix inside `gt_frames/`.

</details>

### `roi_update`

Written when the ROI is moved or resized during the session. It carries the `roi` sub-object,
plus `roi_source` (`fast`/`still`; `still` = the high-res path, a frozen wire name), `saves_px`
and `roi_side_stream_px` (the on-screen ÷32 side, see the `roi` note above).

These records are **debounced**: one record per adjustment, written once the box has stayed
unchanged for ~2 s. A change still pending when recording stops is flushed, so the session's
final ROI is always on record. An adjustment that ends back on the previous geometry writes
nothing. The summary's Setup tab lists these as "ROI changes during the session".

<details>
<summary>Older files: <code>roi_update</code></summary>

`roi_side_stream_px` and the debouncing exist since round 109. Sessions recorded before round
109 instead carry one record per drag tick: take the last of a burst. The summary's Setup tab
was labelled "Settings" before round 182.

</details>

### `motion_gate`

Written when the detector sleeps or wakes (only if the gate is enabled).

| Field | Meaning |
|---|---|
| `state` | `idle` (detector went to sleep) or `awake` (resumed). |
| `motion_score` | The motion measure at the transition. |
| `idle_s` | On wake only: how long it was asleep. |

Gated (idle) periods carry **no** `detections` lines by design. These records make that
auditable, so an empty stretch is "confirmed asleep", not "missed".

### `blackout`

The screen-off power save was switched during the session. One field: `on` (`true` = the black
cover went up and the screen dimmed to minimum, `false` = the user tapped to wake).

The screen is a major heat and power source (a test measured ~10 °C skin-temperature
difference), so thermal and battery comparisons between sessions need to know the screen state.
Screen state at any moment = the last `blackout` record before it. Before the first one, use
`blackout_at_start` in the start record (absent = screen on).

<details>
<summary>Older files: <code>blackout</code></summary>

`blackout` records exist since round 132; the ~10 °C difference was measured in round 82.
Sessions recorded before round 132 carry no screen-state information.

</details>

### `screen`

The app went off or back on screen during the recording. `state`: `hidden` (screen off by the
power button or the phone's screen timeout, Home, or another app in front) or `visible`. Logged
on changes only. The camera keeps recording while the app is hidden (only the live preview
stops), so these records explain why a session's screen was dark, not gaps in the data.

<details>
<summary>Older files: <code>screen</code></summary>

`screen` records exist since round 292, and since round 292 the camera keeps recording while
the app is hidden.

</details>

### `guard_stop`

The recording stopped itself before running out. `reason`: `low_battery` (on the phone's own
battery at or below *Stop at battery level*) or `storage_low` (free storage below *Keep free
storage*); `battery_percent` and `free_storage_bytes` at that moment.

The normal `end_of_session` follows, so the session is complete up to that time. The summary's
Setup tab shows it as *Stopped by itself* (for example "Yes: storage almost full (140 MB free,
limit 200 MB)").

<details>
<summary>Older files: <code>guard_stop</code></summary>

`guard_stop` records exist since round 296.

</details>

### `motion_capture`

One per photo in a motion session (the detector does not run there, so there are no track IDs or
boxes). The `capture` record that follows carries timing and size as usual.

| Field | Meaning |
|---|---|
| `jpeg` | Filename in `roi_frames/`, the same key `detections` records use. |
| `captured_at_ms` | The trigger moment, same convention as `capture` records. |
| `motion_score` | The motion score that took the photo. |

### `timelapse_capture`

One per time-lapse photo.

| Field | Meaning |
|---|---|
| `jpeg` | Filename in `roi_frames/`. |
| `captured_at_ms` | The trigger moment, same convention as `capture` records. |
| `burst` | 0-based index of the burst the photo belongs to. |

In continuous mode (config `timeLapseGapSeconds` = 0, no break), `burst` advances every
photo-duration block. The config key `timeLapseGapSeconds` is the BREAK between bursts (one
burst's end to the next one's start).

**`timelapse_skipped`.** Photos are taken only while the camera delivers frames. Photo times are
skipped in two cases:

- the app is not on screen without a running recording to keep the camera (`app_hidden`; a
  recording always keeps it, so this is rare);
- no camera event arrives for 5 s inside a burst (for example another app took the camera).

One `timelapse_skipped` record then marks the start of that gap: `reason` (`app_hidden` or
`no_camera_frames`) and `silent_ms` (how long the camera had been silent). The next
`timelapse_capture` shows when photos resumed. Reference photos (`gt_capture`) wait the same
way.

<details>
<summary>Older files: <code>timelapse_capture</code>, continuous mode and the interval key</summary>

- `timelapse_capture` records exist since round 97.
- **Continuous mode:** since round 174 it is config `timeLapseGapSeconds` = 0; on r97–r173
  builds it was `timeLapseIntervalSeconds` ≤ "Photo duration".
- **`burst` in continuous mode:** before round 173 it was always `0`. Since round 173 it
  advances every photo-duration block. This was the fix for a field bug where a continuous
  session silently stopped capturing after the first photo duration: sessions recorded on
  r97–r172 builds with a continuous configuration contain ONLY that first burst's photos.
- **Config key change in round 174:** the start record's config block carries
  `timeLapseGapSeconds` (the break between bursts). Sessions from before round 174 carry
  `timeLapseIntervalSeconds` instead (START-TO-START spacing). Convert via gap = interval −
  duration when comparing across the change.
- `timelapse_skipped` and "photos only while the camera delivers frames" exist since round 290;
  since round 292 a recording always keeps the camera.

</details>

### `timelapse_video_start`, `video_clip`, `video_skipped`

Time-lapse video bursts. With *Save bursts as: Video* (start record `config.timeLapseSaveAs` =
`"video"`) each burst is saved as one MP4 clip of the ROI in `videos/` instead of photos. So
`roi_frames/` stays empty and there are no `timelapse_capture` or `capture` records. A
continuous time-lapse (`timeLapseGapSeconds` 0) starts a new clip every burst length. The clips
are analysed afterwards like imported videos (§9).

**The clip:** the ROI square, upright, at the "Saved photo side" (smaller when the ROI covers
fewer camera pixels, or when the phone's video encoder needs it). H.264 at
`config.timeLapseVideoFps` frames per second (default 5), a key frame every second, about 0.25
bits per pixel per frame (≈ 1.3 Mbit/s for 1024 px at 5 fps, ≈ 4 Mbit/s at 15 fps). Some phones'
encoders keep a minimum quality, so low rates may come out larger.

- **`timelapse_video_start`:** a clip was opened. `file`
  (`videos/roi_<token>_<date>_<time>_<ms>.mp4`), `burst` (as in `timelapse_capture`), `fps`,
  `side_px`, `requested_side_px` (only when the encoder took a smaller side), `bitrate` (bits per
  second), `encoder` (the phone's codec name). A start without a matching `video_clip` means the
  app was killed while that clip was open; such a file is usually unreadable.
- **`video_clip`:** the clip was closed. The same fields as an imported clip (§9) plus how it
  was recorded (list below). This record is written when the clip ends, so its `time_ms` is the
  end.
- **`video_skipped`:** a burst, or part of one, without a clip. `burst`, `reason` (table below),
  `message`, and `file` when a clip file was involved (`stop_failed`, `no_frames`).

Fields that a recorded `video_clip` adds:

- `start_epoch_ms`: the camera's time of the first frame (`start_time_source` `camera`; `clock`
  only if the camera gave no usable time). A frame's clock time is `start_epoch_ms` + its time
  inside the file (which starts at 0). Each frame carries the camera's own capture time, so the
  gaps between frames in the file are the camera's true gaps.
- `frames_skipped`: frames the camera delivered on time while the encoder was still busy with
  the previous one (it should be 0 or close to it).
- `burst`, and `end_reason`: `burst_end`, `session_end`, `camera_paused`, `camera_parked`,
  `camera_stopped`, `app_hidden` (power button or Home) or `no_camera_frames` (the camera
  stopped delivering for 5 s without being told).
- `first_pts_us`: the camera's clock, time since the phone was switched on; for diagnosis only.
- `bitrate`, `encoder`, `crop_ms_mean` (cutting the ROI out of a camera frame) and
  `draw_ms_mean` (handing it to the encoder).
- `flushed: false` when the encoder did not hand over its last frames within 2 s; `error` when
  something failed.

| `video_skipped` `reason` | Meaning |
|---|---|
| `storage_low` | Less than 1 GB free, checked again every second. |
| `start_failed` | The encoder refused; see `message`. |
| `no_frames` | The camera delivered no frame before the clip ended; the empty file was deleted. |
| `stop_failed` | The clip did not close in time; `file` may be unreadable. |

While a burst's camera is paused (settings opened, a cool-down pause) the clip ends with
`camera_paused` (or `app_hidden` / `no_camera_frames`, see above). A new clip starts for the
same `burst` once the camera is back.

**Analysing the clips.** A session with video bursts is analysed like imported videos (§9).
*Find animals in videos* (the Video tab's button, or the session's ⋮ menu) lists it, starts on
the whole picture (each clip already is the ROI square), and writes `video_detections.jsonl`,
`post_tracks.jsonl` and `track_ids.csv` next to the recording's own `session.jsonl`.

The
`thermal`, `fps` and `power` records of `session.jsonl` describe the phone during the recording.
*Copy videos* (Video tab) copies the clips into the phone's Gallery under
`Movies/FaunaPulse/<session>` (Android 10+); the copies are not recorded in the session log.

**Live detection + ROI video.** A live detection session with *Also record the ROI as video*
(start record `config.liveAiVideo: true`, `config.liveAiVideoFps`) records the same kind of
clips while live detection runs, as 5-minute pieces (a new clip every 5 minutes, so a killed app
loses at most the open one). The differences:

- `live_video_start` instead of `timelapse_video_start`;
- `segment` (0, 1, 2 …, counted from the recording start) instead of `burst`, in it, in
  `video_clip` and in `video_skipped`;
- `end_reason` is `segment_end` when the next piece started.

The clip keeps its frame rate even while the motion gate lets the detector sleep. Each clip is
the live ROI square, so a live `detections` box (`box_in_roi`) is its place in the video. Its
place in time is `frame_sensor_ms` − the clip's `start_epoch_ms` (the same camera clock); the
summary's Video tab draws the live boxes that way.

Such live clips can also be analysed again with *Find animals in videos*, for comparison:

- The files it writes (`video_detections.jsonl`, `post_tracks.jsonl`, `track_ids.csv`, `mot/`)
  sit next to the live `session.jsonl`. The session's track IDs, graphs, dashboard and
  identification stay those of live detection (the track source of a live detection session is
  always the live log, §9 `trackSourceOf`).
- *Find track IDs* keeps no frames for a live session (`keep_frames` null in
  `post_track_start`), so `roi_frames/` holds only the live photos.
- The Video tab's *Live detection | Detection afterwards* switch shows either set of boxes on
  the same clips. The two sets number their track IDs independently.

<details>
<summary>Older files: video clips</summary>

- Round 238: time-lapse video bursts and these records. `config.timeLapseVideoFps` defaults to
  5 since round 290 (15 before).
- Round 239: analysing these sessions with *Find animals in videos*, and *Copy videos*.
- Round 240: live detection + ROI video. Round 241: analysing the live clips again with *Find
  animals in videos*.
- Round 290: the `end_reason` values `app_hidden` and `no_camera_frames`.

</details>

### `camera_sleep`

Time-lapse camera parking. Written only in time-lapse sessions with "Turn camera off between
bursts" on. The camera is fully turned off between bursts and back on shortly before the next
one (the "Camera wake lead" setting, `timeLapseWakeLeadSeconds`, default 10 s). These records
make the resulting gaps without frames auditable: "confirmed intentionally off", never "camera
failed".

| Field | Meaning |
|---|---|
| `state` | `parked` (camera off between bursts), `warming` (turned back on, waiting for the first fresh frame), `running` (fresh frames confirmed: photos may flow), `fallback_bound` (a park/wake failed: parking is off for the rest of the session, the camera stays on). |
| `reason` | Why the transition happened: `between_bursts`, `prewake`, `late_wake` (an OS-delayed wake after the burst was already due), `fresh_frame`, `wake_timeout` (no frame within 20 s), `park_failed` / `wake_failed` (the platform call itself failed). |
| `next_burst_at_ms` | The next scheduled burst start (epoch ms). Join against `timelapse_capture` records to see whether a burst started on time, late (`late_wake`), or fell inside a failure. |
| `wake_ms` | On `running` only: how long the wake took, from the turn-on call to the first fresh frame. |

**Analysis rule:** photos are only captured in the `running` and `fallback_bound` states, so a
burst that overlaps a `parked`/`warming` gap starts its photos late (the burst grid itself never
shifts). A `fallback_bound` record means every later gap in that session is real camera time,
not parking.

<details>
<summary>Older files: <code>camera_sleep</code></summary>

`camera_sleep` records exist since round 163.

</details>

### `torch`

Night time-lapse torch. Written only in time-lapse sessions with "Torch during bursts (night)"
on. The LED torch is switched on a lead time before each burst (the "Torch lead" setting,
`timeLapseTorchLeadSeconds`, default 5 s), so auto-exposure settles under the final lighting,
and off in the break. Records are written only when the OUTCOME changes (a confirmed on/off
flip, or the first failure since the last success), never per retry, so they stay sparse.

| Field | Meaning |
|---|---|
| `on` | The state the schedule asked for (`true` = torch on). |
| `success` | Whether the camera confirmed it. `false` usually means this lens has no flash unit (the session continues unlit; the app also shows a one-time notice). |
| `reason` | `burst_lead` (scheduled on, lead before a burst), `burst_end` (scheduled off), `camera_parked` (turning the camera off also turned off the LED; it lights again after the wake), `session_stop`. |

**Analysis rule:** light changes how easy animals are to detect, so treat the torch-on windows
as their own observation condition. The first burst of every recording (and of every scheduled
window) starts at once and gets no lead; its earliest photos can still show the exposure
settling. The light itself may attract or repel some taxa: a methods point for night
visitation rates.

<details>
<summary>Older files: <code>torch</code></summary>

`torch` records exist since round 180.

</details>

### `focus_change`

The camera focus was changed during the session. Same fields as the start record's focus pair:
`focus_mode` (`manual`; `auto` only in older sessions) and, for manual, `focus_value` (0..1,
0 = far/infinity).

Debounced like `roi_update`: one record per adjustment, written once the slider has stayed
unchanged for ~2 s (flushed at stop; a change that ends back on the previous state writes
nothing). Focus affects sharpness and therefore detections, so treat a `focus_change` like a
small protocol change when comparing periods within a session.

<details>
<summary>Older files: <code>focus_change</code></summary>

`focus_change` records exist since round 132. `focus_mode` `auto` occurs only in sessions
recorded before round 164.

</details>

### `thermal`, `fps`, `power`

Samples at a fixed interval, for the summary graphs. These three record types are always
written while recording (one exception from an older build, see the folded block). The
detection records (and therefore the track ID timeline) do not depend on them.

**`thermal`:** `battery_temp_c`, `thermal_status`, `battery_current_ua`, `battery_voltage_mv`,
`charge_counter_uah`, `is_charging`, `is_plugged` (see `power` below), `thermal_headroom`,
`cpu_temp_c`, `gpu_temp_c`, `power_w` (derived, see the caveats below), and
`free_storage_bytes` / `total_storage_bytes` (so the session's disk fill rate can be plotted
against its photo cadence).

`battery_temp_c` is the temperature of the battery itself, from the sensor inside the battery
pack (Android's battery broadcast, in tenths of a degree). It is a real measurement, but of the
battery: the processor gets hot faster than this, which `thermal_status` and `thermal_headroom`
(from the phone's own heat sensors) show earlier. `cpu_temp_c` and `gpu_temp_c` are the chip's
own sensors in degrees (the hottest CPU core and the GPU, read from the phone's kernel); they
react within seconds. Values below 0 °C are real frost readings (kept down to -40 °C, which
marks an absent sensor). Whether an app may read them is the phone maker's choice: Xiaomi phones
allow it, Samsung phones do not (both are then null; on Xiaomi phones `thermal_headroom` is the
null one instead, so the two complement each other). The summary draws them beside the battery
line.

The same record carries the phone's memory and this app's processor use (one native reading
gives all of it, so these fields cost nothing extra; null when the phone gave nothing):

| Field | Meaning |
|---|---|
| `mem_total_bytes` | Memory of the whole phone. |
| `mem_free_bytes` | Memory still free, for everything on the phone: the smaller of Android's own figure and the kernel's `MemAvailable` (Android's can count page cache that cannot be freed). In use = total minus free. |
| `low_memory_bytes` | Below this much free memory Android starts closing background apps. |
| `app_memory_bytes` | What the FaunaPulse process holds (resident set), mostly the loaded model. |
| `app_cpu_ms` | Processor time the FaunaPulse process has used since it started, all its threads together (raw, cumulative). |
| `app_cpu_cores` | Derived: processor cores FaunaPulse kept busy, an average over about the last 10 s (an exponential moving average of the time since the previous reading, so at the usual 10 s interval it is simply the last interval). Null in the first record and after a gap longer than 150 s. |
| `cpu_count` | Processor cores of the phone. |

The cores figure is this app's process only: the camera and the video decoder run in other
Android processes, and apps cannot read the whole phone's processor load since Android 8. So in
a live session it understates the real load; in Identify and *Find animals in photos* it is
nearly all of it.

**`fps`:** while the motion gate is idle, the record carries `gate_idle: true` and OMITS every
field that comes from inference. The same holds in motion and time-lapse sessions, where the
detector never runs: the record then carries `motion_only: true` or `time_lapse: true`. An
absent field means the detector was off, never a zero reading; summary graphs break their lines
across such gaps.

Always present: `camera_fps`, `engine` (what the detector runs on),
`analysis_w`, `analysis_h` (the live analysis frame) and the applied throttle cap
(`applied_cap_fps`). While the detector runs: `fps` (detector FPS), the per-second rates
`detector_fps` and `pipeline_fps`, and the time of each stage:

| Field | What it times |
|---|---|
| `pre_ms` | Image preparation: ROI crop, rotate, resize to the model input and packing into the input tensor. |
| `inf_ms` | The detector model run ONLY (handing the tensor to the LiteRT/NPU interpreter, the network forward pass, reading the outputs back). The summary's "Detector time per frame (ms)" graph plots this. |
| `post_ms` | Output decoding, non-maximum suppression and mapping boxes back to image coordinates. |
| `track_ms` | The Dart-side tracker update. |

All four are raw single-frame values captured when the sampler fires, not averages.
`throttle_inf_ms_ema` is the smoothed inference time that *Auto-adjust detector rate* (config
key `autoThrottle`) acts on. The conversion from camera image to bitmap happens before this
pipeline and is in none of them.

**`power`:** `power_w`, `battery_current_ua`, `battery_voltage_mv` (mV), `charge_counter_uah`
(µAh remaining), `is_charging`, `is_plugged` (any attached power source, even when the battery
reports "not charging" because it is full, e.g. on a power bank).

**Power and energy: how to read them (accuracy caveats).** The `power` fields are the phone's
own battery-sensor values, logged RAW:

- `battery_current_ua` is microamps per the Android spec, but several phones (e.g. the Samsung
  test device) actually report **milliamps** in this field. The raw `power_w` derived from it is
  then ~1000× too LOW. Other phones (e.g. the Xiaomi test device) report a 2-cell series voltage
  (~8.8 V), which makes raw `power_w` ~2× too HIGH.
- The app's summary graph corrects both before plotting. It multiplies the current by 1000 when
  the session's median magnitude says milliamps, halves any voltage above 4.6 V down to a
  single-cell value, lightly smooths (3-point moving average), and integrates the corrected
  curve for the Wh total. If you analyse the JSONL yourself, apply the same corrections. Or
  avoid the sensors entirely and use the battery-percent drop (`battery_percent` in the
  start/end records), which is coarse but unit-safe on every device.
- Any sample with `is_charging: true` OR `is_plugged: true` makes the whole session's power
  series meaningless as a consumption measure. Plugged in, the sensor sees the charging current
  (or ~0 once the charger carries the load). The summary hides the graph in that case; do the
  same in your own analysis. Field sessions on a power bank therefore have no valid power data
  by design: record on battery when you want the graph.

<details>
<summary>Older files: <code>thermal</code>, <code>fps</code>, <code>power</code></summary>

- Sessions recorded with the short-lived round-148 build made these records opt-in (config
  `diagnosticsEnabled: false` in the start record's `config` block ⇒ none present). Round 149
  went back to always on. Their absence there is that setting, not a logging failure; the
  detection records (and therefore the track ID timeline) are unaffected either way.
- `free_storage_bytes` / `total_storage_bytes` in `thermal` exist since round 68.
- `gate_idle: true` in `fps` exists since round 77.
- `is_plugged` exists since round 188.
- `mem_total_bytes`, `mem_free_bytes`, `low_memory_bytes`, `app_memory_bytes`, `app_cpu_ms`,
  `app_cpu_cores` and `cpu_count` in `thermal` (and in the `thermal` block of the start and end
  records) exist since round 346.

</details>

### `capture`

One per saved ROI photo. It records `file`, `captured_at_ms` (the trigger moment), `track_ids`
(the tracks that photo covered: tracks at the same time share one photo), `total_ms`, `bytes`,
`full_res` (whether it was a high-res photo), the source `path`, and `saved_px`. It lets you check whether saving photos lowered the frame
rate. More fields:

| Field | Meaning |
|---|---|
| `grab_ms` | Time the image grab alone took; the rest of `total_ms` is crop + encode + write. |
| `content_lag_ms` | High-res path only. How much OLDER/NEWER the frame's *content* is than the capture request. **Negative = the phone's zero-shutter-lag really served a frame from before the request**; a large positive value means the photo shows the scene that long after the triggering detection (fast insects will have left). |
| `callback_lag_ms` | High-res path only. Plain wait from request to JPEG. |
| `live_jpeg`, `live_bytes`, `live_saved_px` | "Also save a fast crop with each high-res photo" (when on): the live-frame crop of the trigger moment, saved next to the high-res photo as `…_live.jpg`. Small but in sync: use it when the high-res photo misses the insect. |
| `live_lag_ms` | The companion's own delay behind the trigger moment, measured when its frame grab returned: an upper bound on how old its content can be (typically a few tens of ms; compare with the high-res photo's `content_lag_ms`). |
| `content_at_ms` | High-res path only: the photo content's **sensor-exposure moment as epoch ms**, what to time-match `detections` frames against (see §5). Absent on odd HALs. |

<details>
<summary>Older files: <code>capture</code></summary>

- `grab_ms`, `content_lag_ms`, `callback_lag_ms` and the `live_*` companion fields were added in
  round 108; `live_lag_ms` in round 112; `content_at_ms` in round 114.
- For older logs, reconstruct `content_at_ms` as `captured_at_ms + content_lag_ms +
  live_lag_ms`. This is approximate: the lag is measured from the takePicture() call, which
  follows the trigger by the companion-grab gap that `live_lag_ms` brackets.

</details>

### `app_error`

An error shown during recording. `source` (e.g. `detector`, `watchdog`, `session_log`,
`roi_capture`, `set_inference_roi`, `set_motion_gate`, `flutter_framework`, `uncaught_async`)
and `message`. Field sessions run unattended and banners are brief, so this is your record of
"something flashed red at 14:20".

- Uncaught app errors also land here. Those records may carry a shortened `stack`, and, because
  they are rate-limited to one per 2 s, a `suppressed_since_last` count of identical-window
  errors that were dropped.
- If the storage filled up during the session, log lines may be missing between a
  `session_log` app_error and the `end_of_session` line. The file stays valid JSONL throughout.

<details>
<summary>Older files: <code>app_error</code></summary>

`app_error` records exist since round 65; uncaught app errors land here since round 67.

</details>

### `end_of_session`

One per session, the last line (absent = crash). `ended_normally` (`true` only on a clean stop),
`battery_percent`, `unique_track_count`, and a final `thermal` reading.

Exceptions to "last line": a `session_renamed` record (below) lands after it if the session was
renamed later, and so does a `video_cleanup` record when videos were deleted to free storage
(§9). So detect a crash by the record's *absence*, as in §2, not by its position.

### `session_renamed`

The session was renamed after recording. Written when the user picks **Rename session** in a
session's ⋮ menu on the **Sessions** screen.

The rename also
rewrites `config.folderName` in the `start_of_session` record, so the log agrees with the
folder. This record is the audit trail of that edit: the one allowed change after recording to
a file that is otherwise only appended to. It appears AFTER `end_of_session` (one per rename,
so several can add up).

| Field | Meaning |
|---|---|
| `old_name` | Folder name before the rename. |
| `new_name` | Folder name after the rename (also the new `config.folderName`). |

<details>
<summary>Older files: <code>session_renamed</code>, <code>video_cleanup</code></summary>

`session_renamed` records exist since round 182; `video_cleanup` records since round 236.

</details>

## 4. Computing visitation rate

A **track ID** = a run of `detections` entries (or legacy `detection` records) that share one
`track_id`. How its start and end are taken:

- **End:** the last frame time for that id: `frame_ms` (the camera frame's own time; a live
  line's `time_ms` is the later moment it was queued for writing), or `time_ms` on logs without
  `frame_ms`.
- **Start:** the tracker's first sighting: `first_seen_ms` on its `created` `track_event` line,
  or its first frame time on older logs. `detections` lists a track only from its confirmation
  on (the minimum track length), so the first frames are known only from `first_seen_ms`. A
  first sighting before `start_of_session` counts from the session start.
- **Duration:** end − start.

The app (summary, Dashboard, Video tab, identification) and `track_ids.csv` use this same rule.
The tracker already applies the minimum-track-length and occlusion-tolerance settings, so each
`track_id` is one confirmed track ID: you do not filter noise again.

Two common metrics:

- **Visitation rate** = number of distinct `track_id`s ÷ observation time.
- **Mean track ID duration** = mean of (end − start) per `track_id`.

Observation time is the span from `start_of_session` to `end_of_session` (`time_ms`), minus any
`motion_gate` idle periods if you want *active* watch time only.

`unique_track_count` in `end_of_session` should match `n_visits` (the code below) for a clean
session: a quick check.

<details>
<summary>R code: visitation rate from <code>session.jsonl</code></summary>

```r
library(jsonlite)
rows <- stream_in(file("session.jsonl"), verbose = FALSE)

start_ms <- rows$time_ms[rows$type == "start_of_session"][1]
end_ms   <- rows$time_ms[rows$type == "end_of_session"]
end_ms   <- if (length(end_ms)) end_ms[1] else max(rows$time_ms)  # crashed?
obs_hours <- (end_ms - start_ms) / 3.6e6

# Flatten to one row per tracked insect per frame, accepting both formats:
# "detections" (round 69+: tracks[] array) and legacy per-track "detection".
# A frame's time: frame_ms (round 114+), else time_ms.
new <- rows[rows$type == "detections", ]
frame_t <- if ("frame_ms" %in% names(new))
  ifelse(is.na(new$frame_ms), new$time_ms, new$frame_ms) else new$time_ms
det_new <- if (nrow(new)) do.call(rbind, lapply(seq_len(nrow(new)), function(i) {
  data.frame(time_ms = frame_t[i], track_id = new$tracks[[i]]$track_id)
})) else NULL
det_old <- if ("track_id" %in% names(rows))
  rows[rows$type == "detection", c("time_ms", "track_id")] else NULL
det <- rbind(det_new, det_old)

tracks <- aggregate(time_ms ~ track_id, det,
                    FUN = function(t) c(start = min(t), end = max(t)))
tracks <- do.call(data.frame, tracks)
# Start at the tracker's first sighting (created lines, round 116+),
# never before the session start.
if (all(c("event", "first_seen_ms") %in% names(rows))) {
  cr <- rows[rows$type == "track_event" & rows$event %in% "created" &
             !is.na(rows$first_seen_ms), c("track_id", "first_seen_ms")]
  first <- cr$first_seen_ms[match(tracks$track_id, cr$track_id)]
  tracks$time_ms.start <- pmin(tracks$time_ms.start, first, na.rm = TRUE)
}
tracks$time_ms.start <- pmax(tracks$time_ms.start, start_ms)
tracks$duration_s <- (tracks$time_ms.end - tracks$time_ms.start) / 1000

n_visits             <- nrow(tracks)
visitation_rate_hr   <- n_visits / obs_hours
mean_visit_duration  <- mean(tracks$duration_s)

cat(sprintf("track IDs=%d  rate=%.1f/hr  mean duration=%.1fs\n",
            n_visits, visitation_rate_hr, mean_visit_duration))
```

</details>

<details>
<summary>Python code: visitation rate from <code>session.jsonl</code></summary>

```python
import pandas as pd

rows = pd.read_json("session.jsonl", lines=True)

start_ms = rows.loc[rows.type == "start_of_session", "time_ms"].iloc[0]
end = rows.loc[rows.type == "end_of_session", "time_ms"]
end_ms = end.iloc[0] if len(end) else rows.time_ms.max()   # crashed?
obs_hours = (end_ms - start_ms) / 3.6e6

# Flatten to one row per tracked insect per frame, accepting both formats:
# "detections" (round 69+: tracks[] array) and legacy per-track "detection".
# A frame's time: frame_ms (round 114+), else time_ms.
new = rows[rows.type == "detections"].explode("tracks")
frame_t = new["frame_ms"].fillna(new["time_ms"]) if "frame_ms" in new else new["time_ms"]
new = pd.concat(
    [frame_t.rename("time_ms").reset_index(drop=True),
     pd.json_normalize(new.tracks)], axis=1)
old_cols = [c for c in ("time_ms", "track_id") if c in rows.columns]
old = rows.loc[rows.type == "detection", old_cols]
det = pd.concat([new, old], ignore_index=True)

tracks = det.groupby("track_id")["time_ms"].agg(["min", "max"])
# Start at the tracker's first sighting (created lines, round 116+),
# never before the session start.
if "first_seen_ms" in rows:
    cr = rows[(rows.type == "track_event") & (rows.event == "created")].dropna(subset=["first_seen_ms"])
    first = cr.groupby(cr.track_id.astype(int))["first_seen_ms"].min()
    tracks["min"] = pd.concat([tracks["min"], first.reindex(tracks.index)], axis=1).min(axis=1)
tracks["min"] = tracks["min"].clip(lower=start_ms)
tracks["duration_s"] = (tracks["max"] - tracks["min"]) / 1000

n_visits = len(tracks)
visitation_rate_hr = n_visits / obs_hours
mean_visit_duration = tracks["duration_s"].mean()

print(f"track IDs={n_visits}  rate={visitation_rate_hr:.1f}/hr  "
      f"mean duration={mean_visit_duration:.1f}s")
```

</details>

<details>
<summary>Older files: the start of a track ID</summary>

`first_seen_ms` on `created` lines exists since round 116; older logs start a track ID at its
first frame time. The app and `track_ids.csv` use the rule above since round 305.

</details>

## 5. Joining photos to detections

Each track entry's `jpeg` field (in `detections.tracks[]`; top-level in legacy `detection`
records) is the filename in `roi_frames/` of the photo saved on that frame. Join on it to attach
images to specific tracks and moments.

The exact pixel size of each saved photo is in the matching `capture` record's `saved_px` (photo
box geometry). That is the authoritative size, not the ROI box geometry.

### 5b. Time-matching boxes to high-res photos

The `jpeg` join above ties a photo to its **trigger frame**. That is correct for fast-path
photos and `_live` companions (they show the trigger moment). But the content of a high-res
photo lags the trigger by 0.17–0.8 s, so the trigger boxes often miss the insect's real position
on it. Better: join to the `detections` record whose frame time is **nearest the photo's
content moment**. The in-app summary viewer does exactly this on its high-res view.

Recipe (any language):

1. **Content moment per high-res photo:** `content_at_ms` from its `capture` record (older
   logs: see the folded block below).
2. **Frame time per `detections` record:** `frame_sensor_ms`, falling back to `frame_ms` (adds a
   systematic ~50–150 ms "frame is really older" bias).
3. **Interpolate across the pause.** Capturing a high-res photo pauses the analysis stream
   (measured in a test session, session_16: frame holes of 0.1–1.5 s bracket every capture,
   exactly where the content moment falls). So do not just take the nearest frame. For each
   `track_id` present in the nearest frames BEFORE and AFTER `content_at_ms` (within ±1.5 s,
   total span ≤ 2 s), **linearly interpolate `box_in_roi` at the content moment**: the same
   constant-velocity assumption the live tracker makes. Tracks on one side only keep that side's
   box. Error: an interpolated box is off only by how non-linear the insect's motion was across
   the ≤ 2 s bracket, not by the frame cadence; a box from one side only carries that frame's
   distance (up to ~1.5 s across a capture pause).
4. **Tolerance.** The tolerance `max(250 ms, 1.5 × median frame interval)` is an HONESTY gate for
   labelling a match good or approximate, not a reason to discard it (a frame 300 ms away still
   beats the trigger frame ~0.5 s away). DO reject any photo with a `roi_update` between its
   trigger and content moment + 2.5 s: those boxes are relative to a different ROI.

<details>
<summary>R and Python code: nearest detector frame per high-res photo</summary>

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

</details>

<details>
<summary>Older files: the time match</summary>

Time-matching to high-res photos arrived in round 114. For older logs (r108–113), the content
moment is `captured_at_ms + content_lag_ms + live_lag_ms` (approximate).

Error bounds by log generation:

- r114+ logs: as in step 3 above (a same-track bracket interpolates at the exact content
  moment).
- r108–113 logs add the uncertainty of the dispatch gap (≈ `live_lag_ms`, tens of ms).
- Older sessions have no frame timestamps: only the trigger-frame join applies.

</details>

**For pixel-accurate boxes on high-res photos, re-run the detector offline** on the saved
crops (GPU workstation; their side is set by **Saved photo side (px)**, 1024 px by default).
The files are clean re-encoded JPEGs, and the filename and JSONL carry every timestamp needed to
tie results back to track IDs. That looks at the actual pixels instead of estimating from clocks.

The time-match above is the honest *approximation* for browsing and quick joins. Running the
detector on the phone **after** the session is possible too: see §6.

<details>
<summary>Why the phone does not re-run the detector during the session</summary>

Re-running the detector **on the phone** for each still *during the session* was considered and
rejected: heat is the app's main limit. Running it **after** the session is fine and
exists since round 135 (§6).

</details>

## 6. After-session photo analysis (`post_detections.jsonl`)

The **Find animals in photos** screen (the session's ⋮ menu on the **Sessions** screen, or the
button of the same name on Home) can run a detector over a session's saved `roi_frames/` photos
after the fact. This is mainly to sort AI-free motion and time-lapse sessions (which photos
contain a pollinator; optionally delete the rest).

Results are added to `<session>/post_detections.jsonl`, under the same append-only JSONL rules
as `session.jsonl` (§1–§2). Every record carries `time_ms`/`time_iso` (when it was written). Here `time_iso` is the
phone's local time **without** a time-zone offset, unlike `session.jsonl`: use `time_ms` to
join or sort.

| Record | Written |
|---|---|
| `post_start` | once per run |
| `post_detection` | once per analysed photo |
| `post_end` | once per run |
| `post_cleanup` | when photos were deleted by a keep rule |

- **`post_start`:** `model`, `model_name`, `confidence`, `iou`, `use_gpu`, `accelerator` and
  `cpu_16bit` (the engine that really ran, as in the session start record; newer sessions only),
  `photos_total`, `photos_pending`, `app_version`; `reanalyzed_all: true` when **Re-analyze photos already
  done** forced a full rerun. When small-insect tiling (SAHI) was on, a `sahi` map records the
  tiling settings (below). No `sahi` key = a plain single-pass run.
- **`post_detection`:** `jpeg` (filename in `roi_frames/`, joinable exactly as in §5),
  `captured_at_ms` (parsed from the filename), `infer_ms`, and `boxes`: each with `class_name`,
  `conf`, and `box` as `[left, top, right, bottom]` normalized 0–1 **of the photo** (same edge
  order as the live log's `box_in_roi`). A failed photo gets an `error` string and empty
  `boxes`.
- **`post_end`:** `processed`, `failed`, `skipped_done`, `ended_normally` (plus
  `reason: "cancelled"` when stopped during the run), `elapsed_ms` (the run's total wall time,
  matching the duration the app shows when the run finishes) and, for SAHI runs only, a
  `phases` map (folded block below).
- **`post_cleanup`:** audit record of the optional keep/delete storage triage: which files were
  deleted and under which keep rule (`gap_seconds`, and `min_box_frac` when the tiny-box filter
  of the review was on). The keep decision then ignored recorded boxes whose narrower side was
  under that fraction of the photo, without changing the `post_detection` records themselves.

**The `sahi` map:**

| Key | Meaning |
|---|---|
| `tile_px` | Resolved tile side ("auto" is already resolved to the model's input size here). |
| `overlap` | Fraction, e.g. `0.25`. |
| `full_pass` | Whole-photo pass on/off. |
| `merge_iou` | The threshold for merging duplicates. |
| `merge_metric` | `"ios"`: overlap measured against the smaller box. |
| `min_box_frac` | Tile boxes narrower than this fraction of the photo side in either direction were dropped; `0` = filter off. |

**Several runs per photo.** A photo can appear in several runs (analysed again with another
model or other tiling settings). Take the **last** `post_detection` per `jpeg`: the app itself
does that when it decides what to keep and draws review boxes. Match it to its run by reading
backwards to the nearest preceding `post_start`.

**Reading SAHI runs:** the boxes come from overlapping tiles plus (by default) a whole-photo
pass, merged by same-class greedy NMS. With `merge_metric: "ios"`, a small box inside a big one
merges away, and the optional `min_box_frac` filter drops speck-sized tile boxes. Either way, treat the boxes
as triage evidence, not tight annotations; for publication-grade boxes re-run offline (§5b).

The tiling is FaunaPulse's own pure-Dart implementation (`lib/fauna_pulse/postprocess/sahi.dart`),
not an external library. Concept background and the docs for each setting are in
[SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md#photo-analysis-analysis-screen).

<details>
<summary>The <code>phases</code> map of SAHI runs (where the time went)</summary>

The `phases` map in `post_end` splits `elapsed_ms` by pipeline phase:

- counts: `photos`, `tiled_photos`, `tiles`, `full_passes`;
- millisecond totals: `source_decode_ms` (decoding each source photo), `tile_prep_ms` (cutting
  tiles + re-encoding them to JPEG), `tile_transfer_ms` (background-worker startup and byte
  copies), `tile_predict_ms` / `full_predict_ms` (the native detector calls: transfer, native
  decode and inference in one lump), `merge_ms` (duplicate merge);
- the sum `tile_overhead_ms` (= everything tiling adds outside the detector calls).

All phase times are summed across the whole run. The difference between `elapsed_ms` and the
phase sum is file I/O and bookkeeping.

The map also carries `native_tiled_photos` / `native_fallbacks`: photos that went through the
native one-call tiled path (decode + crop + every tile inference in a single plugin call). For
those photos `tile_predict_ms` is that whole lump, `source_decode_ms` is only a header-only
dimension probe, and `tile_prep_ms` / `tile_transfer_ms` contribute 0. The `tile_overhead_ms` of
a mostly native run is expected to be tiny compared to r168–r176 runs.

</details>

<details>
<summary>Older files: <code>post_detections.jsonl</code></summary>

- The after-session photo analysis arrived in rounds 135–139.
- `merge_metric` and `min_box_frac` exist since round 141. A `sahi` map *without* `merge_metric` is an r139–140
  run that merged by plain IoU, and can carry extra small contained boxes: a partial insect at a
  tile border merges poorly with the full-insect box (a small box inside a big one has low IoU).
- `min_box_frac`: runs from the short-lived r141 build (2026-07-23 morning) required the box to
  be small in BOTH directions, which let long thin slivers at the border through.
- `elapsed_ms` and the `phases` map exist since round 168; `native_tiled_photos` /
  `native_fallbacks` since round 177.
- `min_box_frac` in `post_cleanup` exists since round 179.

</details>

### Track IDs found in the photos

For a motion or time-lapse session whose photo step is at most 0.5 s, *Find track IDs* on the
same screen follows each insect from photo to photo with the tracker a live session uses (with
the screen's own occlusion tolerance and minimum track length).

At a photo a second an insect
can move too far between two photos to be matched, so sparser sessions get an explanation
instead. It writes the same files as *Find track IDs* on videos (§9), replaced on every run:

- **`post_tracks.jsonl`:** `post_track_start` first, then `detections` records (one per photo
  with a track ID), `track_event` records and `post_track_end`. In the `detections` records,
  each track entry names the photo in `jpeg` unless the tracker only predicted it
  (`coasted: true`); `box_in_roi` is the box in the photo.
- **`track_ids.csv`:** as for videos, with an empty `clip` and `start_s`/`end_s` counted from the
  session's start.

`post_track_start` with `source: "photos"` holds:

| Field | Meaning |
|---|---|
| `photos` | Moments used. |
| `photo_step_s` | The photo step. |
| `detections_run_ms` | `time_ms` of the newest `post_start`: a later analysis makes these track IDs outdated. |
| `detection_settings` | That run's model and thresholds. |
| `occlusion_seconds`, `min_hits_seconds`, `tracker` | The tracker settings. |
| `clips` | `[]`. |
| `observed_ms` | Time-lapse sessions only: the time the bursts cover (below). |

**`observed_ms`:** photos closer than five photo steps (at least 1 s) form one burst, which
covers from its first photo to one step after its last. A motion session watched the whole
time, so its span counts.

How the photos are used:

- The newest result per photo is used. A photo whose analysis failed is left out (the tracker
  bridges it).
- A high-res photo and its `_live` companion are one moment: the photo's own boxes are used, the
  companion's only when the photo has none.
- The summary, dashboard and identification then read these track IDs as they read the live
  ones. Each track ID's photos are the ones whose `jpeg` it names, and identification answers
  per track ID.
- The photo viewer draws a photo's boxes with their track ID numbers, and keeps the green
  analysis boxes for photos without a track ID.

<details>
<summary>Older files: track IDs from photos</summary>

*Find track IDs* on photos exists since round 237.

</details>

## 7. Derived cache files (safe to ignore)

`<session>/dashboard_stats.json` is a cache the app derives for the **Dashboard** (Home, bottom
bar) across sessions. It holds:

- the session's start/end, and whether it has track IDs;
- each track ID's first/last timestamp (from the first sighting, §4);
- the filmed time of track IDs found afterwards;
- `guessed_clips`: start and end ms of imported clips whose filming time was only guessed
  (track IDs that begin in one stay out of the charts by time);
- `taxa`: the names of the newest identification's track IDs (suspect ones left out and counted
  in `suspect`), cut to the identified rank.

Everything can be derived again from the session's files. The cache is keyed to the size and
mtime of `session.jsonl`, `post_tracks.jsonl` and the newest identification summary, so
deleting it is always safe (the app computes it again the next time the Dashboard opens). It is
NOT part of the scientific record; analysis workflows should read `session.jsonl` and the other
files described here.

<details>
<summary>Older files: <code>dashboard_stats.json</code></summary>

The file exists since round 186. `guessed_clips` and `taxa` since round 304; first/last
timestamps from the first sighting in cache version 4 since round 305.

</details>

## 8. Identification output (`identification/`)

**Identify organisms** (the session's ⋮ menu on the **Sessions** screen, or the end of the
summary's **Photos** or **Video** tab) runs the BioCLIP image tower over the crops of every
track ID and writes its files into `<session>/identification/`. All `.jsonl` files are strict one-object-per-line.
[IDENTIFICATION.md](IDENTIFICATION.md) explains the method; `README_identification.txt` inside
the folder repeats the column dictionary for whoever gets the folder later.

| File | Holds |
|---|---|
| `embeddings_<model>.jsonl` + `.bin` | the run, every crop, and its vector |
| `predictions_<pack>.jsonl` | the top 5 names per crop |
| `tracks_<pack>.csv` / `.json` | one answer per track ID |
| `crops_<pack>.csv` | one row per crop |
| `summary_<pack>.json` | counts for the app |
| `phone_during_identification.jsonl` / `.csv` | the phone's heat, power, memory and speed during every run |

### `embeddings_<model>.jsonl` + `embeddings_<model>.bin`

Append-only (a stopped run can continue). Records:

| `type` | Fields |
|---|---|
| `identify_start` | The run's settings and counts (list below). |
| `crop` | `key` (resume key: source\|track\|box), `src` (file in `roi_frames/` that was cut), `photo` (the log's photo name; differs from `src` when the `_live` companion was used), `box_source` (`trigger` / `live` / `post`), `track_id` (null for post-hoc boxes), `box` `[l,t,r,b]` (0..1 of the photo), `crop_px` (longer box side in photo px), `pad_frac`, `sharpness` (variance of the Laplacian), `det_conf`, `captured_at_ms`, `row` (index of the vector in the `.bin`) |
| `crop_skipped` | `key`, `reason` (`too_small`, `outside`, `read_or_decode`, `embed_error`; older files may also hold `decode`) |
| `identify_end` | Counts and times (list below). |

**`identify_start`:**

- Settings: `model`, `model_id`, `pack`, `input_size`, `dim`, `accelerator`, `margin` (border on
  every side as a share of the box's longer side), `square_crops` (true = square on the longer
  side, false = box shape stretched to the model input; missing = true), `min_crop_px`,
  `max_crops_per_track`, `tau`, `none_threshold`, `thermal_limit_c`, `target_rank`, `use_gpu`,
  `cpu_threads`, `gpu_note` (why the GPU was not used, when asked for) and `gpu_agreement`
  (cosine of the GPU and CPU embeddings of the first-use test picture, see IDENTIFICATION.md).
- Counts: `crops_planned`, `crops_pending`, `crops_done_before`; and `app_version`.
- `track_ids_run_id` (track IDs found in videos only): the *Find track IDs* run that the crops'
  track IDs come from. A run after a new *Find track IDs* deletes both files and starts over.
- `memory_check`, only when **Also identify them** reached the identification with the app in
  the background: `need_mb` (the estimated memory the model needs), `model_mb`, `on_gpu`,
  `free_mb` (the smaller of `avail_mem_mb` and `mem_available_mb`), `threshold_mb` (where
  Android starts closing apps), `margin_mb`, `total_mb`, `low_memory`, `decision` (`load`, or
  `wait_for_app` when the model did not fit and the run waited for the app to be opened) and
  `waited_s` (seconds waited).

**`identify_end`:** `embedded`, `skipped`, `failed`, `unreadable` (the part of `failed` whose
photo could not be read; the rest are model errors), `thermal_pauses`, `paused_ms` (the time
spent in heat pauses, part of `elapsed_ms`; the screen's time estimate leaves it out),
`cancelled`, `elapsed_ms` (the crop loop: reading the photos, cutting the crops and running the
model; loading the model before and the scoring after are not included), `avg_embed_ms` (the
model alone, per crop: what *Test speed* and the progress line report), `error`.

**The `.bin` file** holds row-major float32 little-endian unit vectors (`dim` per row). Read in
Python: `np.fromfile(path, dtype='<f4').reshape(-1, dim)`. For a fixed-class classifier
(insectDCT, see IDENTIFICATION.md) each row is instead the model's raw scores for its classes,
the levels one after another (insectDCT: 19 + 41 + 104 = 164 numbers), not unit length.

### `predictions_<pack>.jsonl`

One `prediction` per crop: `key`, `src`, `track_id` and `top[]` = the five most probable pack
rows with `name` (Genus epithet, or the "none" key), `family`, `order`, `p`.

### `tracks_<pack>.csv` and `tracks_<pack>.json`

One row (CSV) / object (JSON) per track ID. Crops without a track ID (post-hoc boxes of no-AI
sessions) get one row each with an empty `track_id`. "Conf." below is the confidence the app
shows.

| Column | Meaning |
|---|---|
| `device_id`, `session_id`, `track_id` | Identifiers. `device_id` is the device's name (rule below the table). `session_id` is the session folder's name when Identify ran. |
| `track_imgs` | Crops used. |
| `pred`, `pred_prob_weighted` | The taxon at the chosen target rank (default family) and the track ID's Conf. for it (the counted crops' embeddings averaged with each crop's top-1 probability as weight, scored once, species summed; see IDENTIFICATION.md). |
| `pred_imgs`, `pred_prob_mean` | Crops whose own top species falls under that taxon, and the plain (unweighted) mean of the crops' own Conf. under it. Same column names as insect-detect-post, different formulas (there: mean over the voting images times the vote share). |
| `start_time`, `end_time`, `duration_s` | The track ID's first sighting and last frame (ISO local time; the §4 rule, as `track_ids.csv`) and the seconds between them. |
| `det_conf_mean` | Mean detector confidence of the crops. |
| `bioclip_kingdom` … `bioclip_species` | The taxon chosen at each rank on a consistent top-down path (species as "Genus epithet"). |
| `p_kingdom` … `p_species` | Conf. of that taxon from the pooled answer; can exceed every crop's own value when the crops agree. |
| `p_mean_<rank>`, `p_max_<rank>`, `p_agree_<rank>` | The plain mean over all crops, the highest single crop, and the mean over the crops whose top species is under the taxon. `agree_<rank>` × `p_agree_<rank>` reproduces insect-detect-post's weighted probability. |
| `identified_rank`, `headline` | Deepest rank whose Conf. reached `tau` (default 0.6); the taxon there, or `unidentified` / `no organism`. |
| `agree_<rank>` | Share of crops whose own top species falls under that taxon. |
| `n_crops_used`, `none_p` | Crops in the average; mass on the "none of these" rows. |
| `best_view_photo`, `best_view_species`, `best_view_p` | The crop whose own top species has the highest probability (the photo the model is surest about on its own); that species and probability. |
| `flags` | Parts of the verdict (table below). |
| `model_id`, `pack_id` | Provenance. |
| `merged_track_ids` | Trailing column: every track ID joined into this row, separated by semicolons (one id unless "Merge consecutive track IDs" was on; `flags` then also holds `merged`). |
| `n_detections`, `suspect` | Detector frames the track ID(s) appeared in, from the first sighting: the track ID's `detections` entries plus the frames before it was confirmed (`hits` − 1 on its `created` line); 0/1 verdict of the suspect rule (short AND weakly supported; `flags` carries the parts: `short`, `low_det`, `weak_id`, `suspect`). Nothing is removed from the file. |
| `rival_rank`, `rival_taxon`, `rival_p` | Trailing: for a `path_conflict` track ID, the highest rank where a taxon outside the ladder's path scored more than the ladder's pick, that taxon (genus + epithet at species) and its Conf.; empty otherwise. Only ranks below the reported one can be affected, because `tau` is at least 0.5. |
| `model_class`, `model_class_p` | Trailing, fixed-class classifiers only (empty for BioCLIP): the model's own class with the highest combined probability (e.g. insectDCT's `Apoidea small` or `Bombus`; some of its groups have no rank) and that probability. |
| `phone_model` | Trailing: the phone model from the start record (`device.model`); empty for imported videos. |

| `flags` value | Meaning |
|---|---|
| `no_organism` | The "none of these" entries took more than the "No organism" threshold; headline `no organism`. |
| `unidentified` | No rank reached `tau`, not even kingdom. |
| `path_conflict` | At some rank a taxon outside the ladder's path has more Conf. than the ladder's pick. The ladder itself stays one consistent path; see `rival_*`. |
| `single_crop`, `merged`, `short`, `low_det`, `weak_id`, `suspect` | Further flags: for `merged` see `merged_track_ids`; for `short`, `low_det`, `weak_id`, `suspect` see `n_detections`, `suspect`. |

**How `device_id` is chosen**, first match wins:

1. the field notes' `device_id`;
2. else the first filled field of the user's own fields named `Device ID` (case, spaces, `_`
   and `-` ignored);
3. else FaunaLapse's `phone_id` (FaunaLapse imports);
4. else the phone model.

It is empty for imported videos. Characters that file names cannot hold
(`/ \ : * ? " < > \|`) become `-`, and `-`, `.` and spaces at the ends are dropped.
fauna-pulse-export writes the same name for insect-detect-post (`device_name_cases.json`, see
[Using sessions in insect-detect-post](#using-sessions-in-insect-detect-post)).

<details>
<summary>Older files: <code>tracks_&lt;pack&gt;.csv</code> columns, <code>identify_start</code>, <code>identify_end</code> and the <code>.bin</code></summary>

- Round 208: the identification output. Round 209: `src` in the summary's `tracks[]` list.
- Round 210: `merged_track_ids`; round 212: `n_detections`, `suspect`; round 305:
  `n_detections` counts the frames before confirmation (`hits` − 1).
- `agree_<rank>` was called `support_<rank>` until round 216.
- Round 217: `best_view_*`. Round 219: the pooled Conf. (`pred_prob_weighted`, `p_kingdom` …
  `p_species`) and `p_mean_<rank>`, `p_max_<rank>`, `p_agree_<rank>`.
- Round 221: the flag `no_organism` (was `none`), `rival_rank`, `rival_taxon`, `rival_p`.
- Round 242: `gpu_note`, `gpu_agreement` in `identify_start`. Round 262: `square_crops`.
  Round 234: `track_ids_run_id`. Round 319: `memory_check`, `unreadable`, `paused_ms`.
- Round 266: `model_class`, `model_class_p`, and the raw-score rows of fixed-class classifiers
  in the `.bin`.
- Round 335: `device_id` is the device's name; before round 335 it was the phone model (now
  `phone_model`, added in round 335). Round 336: the field notes' `device_id` comes first.

</details>

### `crops_<pack>.csv`

One row per crop (photo × track), for tracing a track ID's answer to single photos:

| Column | Meaning |
|---|---|
| `session_id`, `track_id` | Identifiers. |
| `crop_no` | Capture order within the track ID. |
| `photo` | The photo name. |
| `box_left` … `box_bottom` | Detector box as fractions of the photo side. |
| `crop_px`, `sharpness`, `det_conf`, `pad_frac` | As named; `pad_frac` is descriptive only. |
| `top1_species`, `top1_p` | The species this crop alone predicts and its probability; also the crop's weight in the track ID's answer. |
| `top1_kingdom` … `top1_family` | That species' higher ranks; kingdom `none` for a "none of these" entry. |
| `agrees` | 1 when that species falls under the track ID's reported taxon. |
| `counted` | 1 when the crop entered the pooled answer, 0 when it was left out as far less sure than the surest crop. |
| `ladder_<rank>` | The track ID's ladder taxa, repeated per row. |
| `p_<rank>` | This crop's own Conf. under each of them. |
| `top1_class` | Trailing: a fixed-class classifier's own class behind `top1_species`; empty for BioCLIP. For a class above species, e.g. the genus *Bombus*, `top1_species` holds its deepest named rank. |

<details>
<summary>Checking the numbers: identities between the two CSV files</summary>

Identities for checking in R, over a track ID's rows:

- the plain mean of `p_<rank>` equals `p_mean_<rank>`;
- the maximum equals `p_max_<rank>`;
- the mean over rows whose top species is under the taxon equals `p_agree_<rank>`;
- the count of `agrees == 1` equals `agree_<rank>` × crops at the identified rank.

The track's own `p_<rank>` is NOT a function of these columns (it comes from the averaged
embeddings). Recompute it with `bioclip_export/reproduce_track_conf.py` of
[fauna-pulse-models](https://github.com/valentinitnelav/fauna-pulse-models).

Column history: `crops_<pack>.csv` exists since round 215; `pad_frac` is descriptive only since
round 217; `counted` since round 219; `top1_kingdom` … `top1_family` since round 220;
`top1_class` since round 266.

</details>

**Joining identifications to the recording:** join on `track_id` (the same id as in the
`detections` records of `session.jsonl`; a merged track ID lists every member id in
`merged_track_ids`), or, per crop, on the photo file name (`src` here, `jpeg` in the log) plus
box coordinates. Identification results stay in their own files on purpose, not in
`session.jsonl` (raw log vs derived data that can be run again).

**The JSON file** (`tracks_<pack>.json`) adds:

- the full `ladder` (`rank`, `taxon`, `p`, `p_mean`, `p_max`, `p_agree`, `support`), and on every
  path_conflict row also `rival`, `rival_p` and `rival_lineage` (the rival's ancestors from
  kingdom down to one rank above it);
- every crop with its own top-1, `counted`, `agrees` (whether that top-1 falls under the reported
  taxon; the ladder's `support` at the identified rank is the share of `agrees == true`),
  `p_ladder` (the crop's own Conf. under each ladder taxon, index = rank), `top1_tree` (kingdom …
  family of the crop's top species; the crops table shows its family, order and class) and
  `det_conf` (the live detector's confidence for the crop's box, as in the crops CSV;
  `det_conf_mean` is their mean);
- `best_view`, `flags`, and the run `settings`;
- fixed-class classifiers only: `model_class` (`name`, `p`) per track ID and `top1_class` per
  crop.

<details>
<summary>Older files: <code>tracks_&lt;pack&gt;.json</code></summary>

`agrees` since round 214, `p_ladder` since round 215, `top1_tree` since round 220, `rival`,
`rival_p`, `rival_lineage` since round 221, `det_conf` since round 223, `model_class` and
`top1_class` since round 266.

</details>

### `summary_<pack>.json`

Counts for the app:

- `tracks_total` (track IDs after the optional merge), `track_ids_merged`,
  `tracks_before_merge`, `suspect`, `by_identified_rank`, `no_organism` (was `none`),
  `unidentified`;
- `taxa_order`, `taxa_family` (track IDs per taxon among the track IDs identified at least to
  that rank);
- a compact `tracks[]` list (`track_id`, `track_ids`, `suspect`, `headline`, `identified_rank`,
  `p`, `n_crops`; plus `src` = the photo name when the entry is a per-photo crop of a no-AI
  session) and the run's provenance. The app's session summary reads this list to label photos,
  never the full tracks file;
- `capture`: the photo rule the photos were taken by (`photo_step_s`, `photo_duration_s`; for
  track IDs found in videos the kept-frames rule of their *Find track IDs* run) and, for track
  IDs found in videos, `track_ids_run_id`: the `run_id` of the `post_tracks.jsonl` whose track
  IDs the results use.

*Find track IDs* numbers the track IDs anew each time. So when the current `run_id` differs:

- the results screen says to run identification again;
- the session summary shows no answers on the frames (a note says why);
- re-scoring the stored crops refuses, because their `track_id`s belong to the earlier track
  IDs.

The next **Continue / re-run** starts over.

R sketch:

```r
tr <- read.csv("identification/tracks_<pack>.csv")
table(tr$identified_rank)
aggregate(track_id ~ bioclip_family, data = subset(tr, p_family >= 0.8), FUN = length)
```

<details>
<summary>Older files: <code>summary_&lt;pack&gt;.json</code></summary>

`tracks_before_merge` since round 210, `suspect` since round 212, `no_organism` since round 221
(was `none`), `src` in `tracks[]` since round 209, `capture` (`photo_step_s`,
`photo_duration_s`) since round 216, `track_ids_run_id` since round 234. Re-scoring refuses on
a different `run_id` since round 235.

</details>

### The phone during the identification

While **Identify organisms** runs, the app writes the phone's readings into
`phone_during_identification.jsonl`: one sample at the start of a run, one every `sample_s`
seconds (10), one where each step ends, also while the run waits for the phone to cool down.
A run has two steps: `crops` (the crops go through the model) and `results` (the crops are
combined into one answer per track ID; **Update results** is a run with this step only).

The file is for the whole session, not per model or name list, and it is append-only: every
run adds its records, also a run that was stopped, started over or closed by Android. A sample
is up to three records with the same `time_ms`, built like the samples of a video analysis
([§9](#the-phone-during-the-analysis)), so the same script reads both.

| `type` | Fields |
|---|---|
| `identify_run_start` | `model`, `pack`, `accelerator`, `step` (the run's first step), `sample_s`, `thermal_limit_c`, `scoring_workers` (the *Cores for combining results* setting, 0 = automatic), `crops_pending`, `app_version`. **Update results** writes `model`, `pack`, `step`, `sample_s`, `scoring_workers` and `app_version`. |
| `thermal` | The live record's fields without the storage ones (§3), plus `step` and `paused: true` while the run waits to cool down. |
| `power` | The live record's fields, with the same raw-sensor caveats (§3). |
| `identify_speed` | The crops since the previous `identify_speed` record (fields below). Only in the `crops` step. |
| `identify_thermal_pause`, `identify_thermal_resume` | Each cooling pause: `temp_c`, `limit_c`, `resume_below_c`; then `temp_c`, `paused_ms`, and `cancelled: true` when the run was stopped while waiting. |
| `identify_run_end` | `cancelled`, and `error` when the run failed. Missing when Android closed the app during the run. |

- **`step` names the step up to the sample.** The sample where the crops end still says
  `crops`; the samples after it say `results`. So the time of a step is the sum of the time
  before each of its samples.
- **`identify_speed`:** `step`, `period_ms`, `crops`, `crops_per_s`, `model_ms`, `paused_ms`.
  - A period runs from the previous `identify_speed` record (or the start of the run) to this
    one. A sample without a finished crop writes no record and the period goes on: a large
    model on the processor needs longer for one crop than the sample interval.
  - `crops_per_s` is crops per second of clock time in the period, reading the photos and
    cooling pauses included.
  - `model_ms` is the model's own time per crop (the mean over the period's crops).
  - `paused_ms` is the part of the period spent cooling down.

**Graphs and CSV.** The summary's Graphs tab (under *Extra graphs*, choice **While identification
ran**) plots the samples on the identification's own time: the runs back to back with a gap
between them, cooling pauses shaded. At the end of every run the app writes all samples of the
session again as `phone_during_identification.csv`, one row per sample:

`run`, `time_s`, `epoch_ms`, `model`, `step`, `temp_c`, `headroom`, `thermal_status`, `power_w`,
`battery_current_ua`, `battery_voltage_mv`, `charging`, `plugged`, `crops_per_s`, `crops`,
`model_ms`, `paused`, `paused_ms`, `mem_total_bytes`, `mem_free_bytes`, `app_memory_bytes`,
`app_cpu_cores`, `cpu_temp_c`, `gpu_temp_c`.

These are the columns of `phone_during_analysis.csv` ([§9](#the-phone-during-the-analysis)) in
the same order, with these differences:

| Column | Meaning |
|---|---|
| `run` | 1, 2, … per start of **Identify organisms** or **Update results** on this session. |
| `model`, `step` | The run's model file, and the step up to this row (in place of `clip`). |
| `crops_per_s`, `crops`, `model_ms` | From the `identify_speed` record of the same time (in place of the frame columns). Empty in rows without one. |

- **After a run that Android closed**, the CSV lacks that run until the next run ends. The
  `.jsonl` file always has it.
- **Weight by `crops`** when you average `model_ms` or `crops_per_s`: rows cover different
  numbers of crops.
- **The power columns mean nothing while the phone is plugged in** (`charging` or `plugged`),
  as in live sessions (§3). Identification is usually run on the charger.

<details>
<summary>R and Python code: reading <code>phone_during_identification.csv</code></summary>

```r
p <- read.csv("identification/phone_during_identification.csv")
plot(p$time_s / 60, p$temp_c, type = "l", xlab = "identification time (min)", ylab = "battery °C")
# Seconds spent in each step of each run: the time before each row belongs to that row's step.
p$step_s <- ave(p$time_s, p$run, FUN = function(x) c(0, diff(x)))
aggregate(step_s ~ run + model + step, data = p, FUN = sum)
# Model time per crop in each run.
d <- subset(p, !is.na(model_ms))
sapply(split(d, d$run), function(x) weighted.mean(x$model_ms, x$crops))
```

```python
import pandas as pd
p = pd.read_csv("identification/phone_during_identification.csv")
p.plot(x="time_s", y=["temp_c", "cpu_temp_c", "gpu_temp_c"])
p["step_s"] = p.groupby("run").time_s.diff().fillna(0)
print(p.groupby(["run", "model", "step"]).step_s.sum())
d = p.dropna(subset=["model_ms"])
print((d.model_ms * d.crops).groupby(d.run).sum() / d.crops.groupby(d.run).sum())
```

</details>

<details>
<summary>Older files: the phone during the identification</summary>

Both files exist since round 363. A session identified before that has neither, and the
summary's choice **While identification ran** says "Not measured".

</details>

### Using sessions in insect-detect-post

[insect-detect-post](https://github.com/maxsitt/insect-detect-post) (Sittinger 2026,
[doi:10.5281/zenodo.21822140](https://doi.org/10.5281/zenodo.21822140)) is the PC software that
post-processes the photos of the Insect Detect camera trap. It cuts square crops from the full
photos and their boxes, names them with BioCLIP 2 or a YOLO classifier, sums up each track ID
and has a window for checking the names by hand. It does no detection or tracking itself, so it
needs sessions with track IDs (live ones, or imported videos and photos after *Find track
IDs*).

- **Export:** the PC tool [fauna-pulse-export](https://github.com/valentinitnelav/fauna-pulse-export)
  writes FaunaPulse sessions in that camera's layout (the photos and boxes **Identify organisms**
  uses, but every photo). Its `compare` command puts the names of `tracks_<pack>.csv` and of
  insect-detect-post side by side per track ID. Its README explains the steps and why the two
  can differ.
- **Device names:** insect-detect-post tells devices apart by `device_id` (the camera's
  hostname). The app and the export name the device the same way (`deviceNameOf`; the export's
  `device_id_of` adds its `--device-id` option and `unknown camera` for sessions with no name):
  the field notes' Device ID, else an own field named `Device ID` (FaunaLapse's help suggests
  one), else FaunaLapse's `phone_id`, else the phone model. So phones of one model stay apart
  when each has a Device ID. Both repositories test the rule with the same cases
  (`device_name_cases.json`).
- **Session IDs still differ:** the export adds the session's 4-character token to the folder
  name (two phones may use the same folder name). So join FaunaPulse and insect-detect-post
  results with `compare`, whose `comparison.csv` holds both answers per track ID.

<details>
<summary>Older files: insect-detect-post</summary>

The export to insect-detect-post arrived in round 334. The shared device-name rule exists since
round 335; the field notes' Device ID comes first since round 336.

</details>

## 8b. Sessions imported from FaunaLapse

Sessions → ⋮ → **Import a FaunaLapse session…** turns the zip file(s) that the *Pack* button of
the sister app FaunaLapse made of one photo session into a FaunaPulse time-lapse session. The
folder holds:

- `roi_frames/roi_<token>_<date>_<time>.jpg` (the photos, renamed);
- `site_photos/` (unchanged);
- `faunalapse_session.jsonl` (FaunaLapse's own record, kept as it was);
- `session.jsonl` (below).

`session.jsonl` holds:

- **`start_of_session`** with `source: "faunalapse"`, `imported_at`, a `config` built from
  FaunaLapse's settings (time-lapse photos, step, burst, break, saved side, run length),
  `device` (maker and model from FaunaLapse's `field`), `location` (from `field.location`),
  FaunaLapse's `field` and `phone_state` blocks unchanged, and `faunalapse` (`folder`,
  `app_version`, `settings`, `camera_api`). Its `time_ms` is FaunaLapse's start time.
- **per photo** a `timelapse_capture` (`jpeg`, `captured_at_ms`, `burst`, `original_name`) and a
  `capture` (`path: "still"`, `saved_px`, `bytes`), stamped with the photo's own time. Photos
  FaunaLapse logged with an `error` are left out. Photos named in the record but missing from
  the zips are counted in `missing_photos`.
- **`end_of_session`** at FaunaLapse's end time: `ended_normally` true when FaunaLapse wrote its
  end record, `faunalapse_reason`, `imported_photos`, `damaged_photos` and
  `damaged_site_photos` (below). `missing_photos`, `damaged_photos` and `damaged_site_photos`
  are there only when photos were left out.

`damaged_photos` counts photos left out because their bytes do not match the zip's check value,
they cannot be unpacked, they are not JPEG (or PNG) photos, they are larger than 64 MB, or their
header claims more than 120 megapixels. `damaged_site_photos` counts site photos left out (check
value, unpacking, or over 512 MB).

FaunaLapse video sessions are imported with **Import videos…** (§9): their file names
(`yyyyMMdd_HHmmss_SSS.mp4`) give each clip's start time.

<details>
<summary>Folder name, limits of the import, and history</summary>

**Folder name.** The session folder keeps FaunaLapse's folder name, cleaned like a typed session
name (letters, digits, `_`, `-` and spaces, at most 80 characters; a name without a letter or
digit becomes `faunalapse`). `faunalapse.folder` keeps the original. A photo named twice in the
record is copied once.

**The import refuses:**

- a record larger than 256 MB;
- a record with more than 1,000,000 photos (for example eleven days at one photo per second);
- a record with a line over 256 KB;
- a record that does not match its check value;
- a session that does not fit in the free storage (with 50 MB to spare).

A session of one million photos needs about 800 MB of memory while it imports.

The FaunaLapse import exists since round 300.

</details>

## 9. Imported videos (`videos/`, `video_detections.jsonl`)

**Import videos…** (a button on the home screen, also in the Sessions screen's ⋮ menu and on
the Find animals in videos screen) makes a session from video files filmed elsewhere: the
phone's camera app, a collaborator, a published dataset.

- **The copies:** the files are copied into `<session>/videos/` (names made file-system safe;
  the original name is logged). The originals stay where they are, so they take storage twice
  until you delete them.
- **`session.jsonl`** then only records where the clips came from: the start record (§3), one
  `video_clip` record per clip in start order, and an `end_of_session` with
  `ended_normally: true` whose `time_ms` is the last clip's end. It has no `detections` or
  `track_event` records; the boxes come from the analysis pass below.
- **While the import copies the clips**, the folder holds a hidden file `.import_unfinished`; it
  is removed when the log is complete. A folder that still has it and whose log has no
  `end_of_session` is an import cut off by closing the app. It is deleted at the next start,
  together with the photo picker's own copies in the app's cache.
- **A copy that fails** (for example full storage) deletes its half-made folder at once and says
  why on the *Import videos* screen.

- `videos/`: the clips ([`video_clip`](#video_clip-one-per-imported-clip))
- `video_detections.jsonl`: the detector's boxes, phone samples ([below](#video_detectionsjsonl-find-animals-in-videos))
- `post_tracks.jsonl`, `track_ids.csv`, `mot/`: the track IDs ([below](#track-ids-post_tracksjsonl-track_idscsv-mot))
- `roi_frames/`: kept frames ([below](#kept-frames-roi_frames))

<details>
<summary>Older files: imported videos</summary>

The analysis of videos (`video_detections.jsonl`) arrived in round 225 and *Import videos…* in
round 227; since round 277 it is a button on the home screen. The `.import_unfinished` file
exists since round 319.

</details>

### `video_clip`: one per imported clip

- `time_ms`: The clip's start (same as `start_epoch_ms`).
- `file`: Path inside the session folder (`videos/<name>`).
- `original_name`: The file's name on the phone before the import.
- `start_epoch_ms`: When the clip started (Unix epoch ms).
- `start_time_source`: Where that start came from (table below).
- `start_time_guess_source`: Only when the clip's own guess was replaced (`after_previous` or `user`): what that guess was.
- `start_time_shift_ms`: Only when the user corrected the start; every clip moves by the same amount.
- `start_time_weak`: Only `true`: the start is a guess the user did not correct (a copy's time, only a day, a clip placed after the previous one, or a file name that disagrees with the time stored in the file). The Dashboard leaves the track IDs of such a session out of its charts by time.
- `duration_ms`, `size_bytes`: Length and file size. The length comes from the frames' time stamps when the file's header holds none (fragmented MP4s).
- `rewritten_from` and four more: Only for a clip that was a **fragmented MP4** (below the list).
- `width`, `height`, `rotation`: Picture size as seen upright, and the turn (degrees) stored in the file.
- `codec`, `frame_count`, `fps_mean`, `fps_nominal`: Video format; the mean frames per second from the frames' own time stamps, and the rate the file header claims. Phone videos often have a variable frame rate, so the app computes times from each frame's time stamp, never from frame number ÷ fps.
- `stored_time_ms`: The time stored in the file, when there is one (see `metadata` below).

**Fragmented MP4s** (as some download and recording tools save them). The phone's video player
cannot jump inside a fragmented MP4, so the app copied every frame and sound sample unchanged
into a plain MP4 (no re-compression, same frame times). Then `size_bytes` is the rewritten
file's size, and the clip has five more fields:

| Field | Meaning |
|---|---|
| `rewritten_from` | `fragmented_mp4`. |
| `original_size_bytes` | The picked file's size. |
| `rewrite_ms` | How long the rewrite took. |
| `rewrite_max_time_error_us` | The largest shift of a frame's time by the phone's MP4 writer (rounding, e.g. up to 439 µs on the Xiaomi). The rewrite is refused above a quarter of the shortest frame gap, at most 2 ms. |
| `rewrite_dropped_tracks` | Any sound track the MP4 writer could not take. |

**Where a clip's start comes from** (`start_time_source`), most reliable first:

| Value | Meaning |
|---|---|
| `session_log` | Read back from the `video_clip` record (what the analysis pass uses). |
| `file_name` | A date and time in the file name (`VID_20260924_155954.mp4`, `PXL_…`, `20260924_155954`), as most camera apps write it. Also a date and time joined by " at " (`Screen Recording 2026-09-24 at 15.59.54.mov`, dots or colons in the time). A 12-hour time (`… at 11.59.54 PM.mov`) is not read: such names give only the day. |
| `metadata` | The time stored in the file **minus the clip length**: Android phones store when recording *stopped* (checked on a Xiaomi clip). |
| `file_name_date` | Only the day is in the name (WhatsApp: `VID-20260924-WA0005.mp4`); noon is assumed. Uncertain. |
| `file_time` | The file's modification time minus the length. Uncertain: copying resets it, and the Android file picker copies every file it hands over. |
| `after_previous` | A clip with an uncertain time that would overlap the clip before it, placed right after that clip (so several WhatsApp clips from one day play one after the other instead of all at noon). Clips with a reliable time never move, so a real overlap (two cameras) stays visible. |
| `user` | The user set the start on the import screen. The first clip then starts at second 0 (the time picker has no seconds). |
| `camera` | Recorded by the app (time-lapse video bursts): the camera's time of the first frame. |
| `clock` | Recorded by the app, but the camera gave no usable time: the phone's clock when the clip opened. |

When the file name's time and the stored time differ by more than 2 minutes, the name wins, but
the import screen marks the time as uncertain. Messengers such as WhatsApp remove the stored
time; video editors reset it to the export time. Under the first clip's start, the import
screen says what the file name and the stored time gave.

<details>
<summary>Older files: <code>video_clip</code></summary>

- Round 226: the `metadata` rule (stored time minus length) was checked on a Xiaomi clip.
- Round 238: the `camera` source (time-lapse video bursts).
- Round 252: the fragmented-MP4 rewrite and its fields. Since round 252 the length of a clip
  without a length in its header comes from the frames' time stamps; before that such clips
  logged `0`.
- Round 304: `start_time_weak`.
- Round 306: file names with " at "; with `user`, the first clip starts at second 0 (before, it
  kept the seconds of the guess); the import screen shows what the file name and the stored
  time gave.

</details>

### `video_detections.jsonl`: "Find animals in videos"

**Find animals in videos** (home screen) runs a detector over every clip and adds to
`<session>/video_detections.jsonl`, under the same append-only JSONL rules as `session.jsonl`.
Records carry `time_ms` (when written), no `time_iso`.

- **`video_run_start`:** one per run. Results made with other `settings` are never mixed: a run
  with changed settings asks, then starts the file over. Fields:
  - `settings`: `model`, `confidence`, `iou`, `analysis_fps` (frames looked at per video
    second), `roi` (`[center_x, center_y, side]` as fractions of the upright picture, side as a
    fraction of its width, or `null` for the whole picture), `max_side_px`;
  - `model_name`, `use_gpu`, `accelerator` and `cpu_16bit` (the engine that really ran, as in
    the session start record; newer sessions only), `thermal_limit_c` (the pause temperature),
    `sample_s` (the "Measure the phone every" setting);
  - `clips_total`, `clips_pending`, `clips_cut_off` (see below), `started_over` (when earlier
    results were replaced), `app_version`.
- **`video_clip_start`:** per clip: `clip`, `start_epoch_ms`, `start_time_source`,
  `resume_from_pts_us` (when a stopped run continued), and the format fields.
- **`raw_detections`:** per analysed frame: `clip`, `pts_us` (the frame's time stamp in the
  file), `frame` (0-based in display order, as CVAT counts), `frame_ms` (epoch ms = clip start
  + time stamp offset) and `boxes` as `[left, top, right, bottom, conf, class]`, normalized 0–1
  **to the whole upright frame**, also with a square. This is the shape of the live log's
  `raw_detections` (§3), so the tracker replay tools read it.
- **`video_clip_done`:** per clip: `frames_analysed`, `frames_decoded`, `frame_width`,
  `frame_height`, `roi_px` (the square in video pixels), `class_names`, and the time sums
  `decode_ms`, `convert_ms`, `infer_ms`, `elapsed_ms`. `video_clip_error` instead when a clip
  failed (`error`, `at_pts_us`).
- **`video_model_error`:** `clip`, `error`: the detection model could not be loaded or run (for
  example a damaged file). The run stops there. The clip is not counted as failed, so no
  `video_clip_error` is written for it.
- **`video_run_end`:** `clips_done`, `clips_failed`, `frames_analysed`, `thermal_pauses`,
  `elapsed_ms`, `ended_normally` (plus `reason: "cancelled"` when stopped, or
  `reason: "model_error"` with `ended_normally: false` after a `video_model_error`).
- **A run stopped by full storage** has no `video_run_end`. On *Continue*, a last line that was
  cut off half-written is removed (a whole last line without its line end gets one) before new
  records are added, so every line stays valid JSON.

**Cut-off clips.** Android writes an MP4's index (the `moov` box) only when the recording is
closed. A clip that was still open when the app was killed (battery, the system, a forced stop)
has its picture data but no index, so no player or decoder can read it.

- The app checks the file's top-level boxes. An empty file, or one without `moov` whose last box
  has size 0 or runs past the end of the file, is *cut off*.
- Such clips are not analysed and not counted in `clips_total`; `clips_cut_off` says how many
  there were.
- *Find animals in videos* names them and offers to delete them (cleanup mode `cut_off`, below);
  the Video tab leaves them out with a note.
- A file that does not start with an MP4 `ftyp` box (another container) is left to the decoder
  as before.

<details>
<summary>Older files: <code>video_detections.jsonl</code></summary>

The file exists since round 225. `thermal_limit_c` since round 229, `sample_s` since round 232,
`clips_cut_off` and the cut-off check since round 243. `video_model_error`, the
`model_error` reason and the handling of a run stopped by full storage since round 319.
The phone samples exist since round 232; `convert_ms` is split over several cores since round
233.

</details>

### The phone during the analysis

Every `sample_s` seconds of a run, also while it waits for the phone to cool down, and once more
at the end of each run, the run writes one sample. A sample is up to three records with the same
`time_ms`, named as in live sessions (§3), so one script reads both.

- **`thermal`:** the live record's fields without the storage ones, plus `clip` (the clip being
  analysed) and `paused: true` while the run waits to cool down.
- **`power`:** the live record's fields, with the same raw-sensor caveats (§3: some phones report
  milliamps, the Xiaomi a two-cell voltage, and any `is_charging` or `is_plugged` makes the
  power figures meaningless).
- **`analysis_speed`:** the time since the previous sample (fields below). The three means are
  left out when no frame was analysed. The record is left out when nothing was analysed and
  nothing paused (the first sample of a run).
- **`video_thermal_pause`** (`clip`, `temp_c`, `limit_c`, `resume_below_c`) and
  **`video_thermal_resume`** (`clip`, `temp_c`, `paused_ms`, `cancelled: true` when the run was
  stopped while waiting) mark each cooling pause.

| `analysis_speed` field | Meaning |
|---|---|
| `clip`, `period_ms` | The clip, and the time since the previous sample. |
| `frames`, `frames_decoded` | Frames analysed; frames decoded. |
| `frames_per_s` | Analysed frames per second of clock time; cooling pauses count, so it is 0 during a pause. |
| `paused_ms` | The part spent cooling down. |
| `decode_ms` | Mean per analysed frame: reading frames from the video, including the frames skipped to reach the analysis rate. |
| `convert_ms` | Mean per analysed frame: cutting out the square and scaling it. Split over several cores, so it is the waiting time, not the summed work of the cores. |
| `detect_ms` | Mean per analysed frame: the detector call (input preparation, the model and box decoding). |

**Graphs and CSV.** The summary's Graphs tab (under *Extra graphs*) plots these instead of the
live graphs, on the analysis time: runs placed back to back with a gap between them (5 sample
intervals, at least a minute), cooling pauses shaded. *Share results* adds them as
`phone_during_analysis.csv`, one row per sample on the same clock:

`run`, `time_s`, `epoch_ms`, `clip`, `temp_c`, `headroom`, `thermal_status`, `power_w`,
`battery_current_ua`, `battery_voltage_mv`, `charging`, `plugged`, `frames_per_s`, `frames`,
`decode_ms`, `convert_ms`, `detect_ms`, `paused`, `paused_ms`, `mem_total_bytes`,
`mem_free_bytes`, `app_memory_bytes`, `app_cpu_cores`, `cpu_temp_c`, `gpu_temp_c`. Explained:

| Column | Meaning |
|---|---|
| `run` | 1, 2, … per start of *Find animals in videos*. |
| `time_s` | The graphs' time axis. |
| `epoch_ms` | The records' `time_ms`. |
| `power_w`, `battery_current_ua`, `battery_voltage_mv` | Raw, as logged; the two sensor columns are there to apply the §3 corrections. |
| `frames` | Frames analysed since the previous row. |
| `paused_ms` | The part of the period spent cooling down. |
| `mem_total_bytes`, `mem_free_bytes`, `app_memory_bytes`, `app_cpu_cores` | As in the `thermal` record (§3): the phone's memory and the processor cores FaunaPulse kept busy. The video decoder runs in another Android process, so the cores figure is not the whole load of the analysis. Empty in files of older app versions. |
| `cpu_temp_c`, `gpu_temp_c` | As in the `thermal` record (§3): the chip's hottest processor core and graphics sensor. Empty on phones that do not let apps read them. |

- **Empty cells** are values the phone did not report, or no frames in that period.
- **A battery current of exactly 0** counts as not reported. So `power_w` is empty whenever a
  full battery on the charger lets the phone run from the charger alone (it happens in cooling
  pauses).
- **Weight by `frames`.** Rows cover different numbers of frames (the last one of a run is
  shorter, and the first frames of a run can be slower while the detector warms up), so average
  the per-frame columns weighted by `frames`.

<details>
<summary>R and Python code: reading <code>phone_during_analysis.csv</code></summary>

```r
p <- read.csv("phone_during_analysis.csv")
plot(p$time_s / 60, p$temp_c, type = "l", xlab = "analysis time (min)", ylab = "battery °C")
# Detector ms per frame in each run: does it slow down in later runs?
sapply(split(p, p$run), function(d) weighted.mean(d$detect_ms, d$frames, na.rm = TRUE))
```

```python
import pandas as pd
p = pd.read_csv("phone_during_analysis.csv")
p.plot(x="time_s", y=["temp_c", "frames_per_s"], secondary_y="frames_per_s")
d = p.dropna(subset=["detect_ms"])
(d.detect_ms * d.frames).groupby(d.run).sum() / d.frames.groupby(d.run).sum()
```

</details>

The file holds boxes and these samples only; the next files turn the boxes into track IDs.

### Track IDs: `post_tracks.jsonl`, `track_ids.csv`, `mot/`

**Find track IDs** runs the boxes through the same tracker a live session uses. It runs:

- as the main button of the "Find animals in videos" screen when only the track IDs are due;
- as *Find track IDs for the clips analyzed so far* under it, while clips are left;
- automatically after each finished analysis.

It uses the videos' own settings: the algorithm (ByteTrack or C-BIoU), its "New-track
confidence" and fine-tuning, the **occlusion tolerance** and the **minimum track length**, all on
the Track IDs card of "Detection, track ID and identification settings", apart from the
camera's. It follows each insect from frame to frame, so one insect seen in many frames counts
as one track ID.

It takes seconds and never re-runs the detector, so it can be repeated with other settings.
Each run **replaces** these three outputs. Each is written under a temporary name and renamed
when complete, so a crash never leaves half a file in place of a good one.

**`post_tracks.jsonl`** is shaped like the live log:

1. `post_track_start` first (fields in the table below);
2. then `detections` and `track_event` records as in §3, with `time_ms` = the frame's own time,
   plus `clip`, `frame` and `pts_us`. `box_in_roi` is relative to the analysed square, as live.
   A track entry names its kept frame in `jpeg`, as live photos do;
3. `capture` records for the kept frames (see [Kept frames](#kept-frames-roi_frames));
4. `post_track_end` last: `track_ids`, `frames`, `detections`, `clips_tracked`,
   `clips_with_track_ids` (the clips in which at least one track ID has a box; missing in older
   files), `kept_frames`, `elapsed_ms`.

| `post_track_start` field | Meaning |
|---|---|
| `run_id` | This run's id. |
| `detections_run_ms` | `time_ms` of the analysis run's first `video_run_start`. |
| `detection_settings` | The detection settings. |
| `occlusion_seconds`, `min_hits_seconds` | Occlusion tolerance and minimum track length. |
| `tracker` | The effective tracker parameters. |
| `clips` | The clips. |
| `observed_ms` | Filmed time of the tracked clips, overlaps counted once. |
| `clips_continuing_previous`, `clips_left_out` | `clips_left_out` lists the clips whose analysis had not finished (below). |
| `keep_frames` | `{step_seconds, duration_seconds}`, or null when no frames were kept. |
| `file_token` | With `keep_frames`: the name token of the kept frames. |

**`track_ids.csv`:** one row per confirmed track ID, for spreadsheets and R:

| Column | Meaning |
|---|---|
| `track_id`, `clip` | The track ID and its clip. |
| `start_time` | Wall clock. |
| `start_s`, `end_s`, `duration_s` | Seconds from the start of the clip the track ID began in (the position a video player shows). |
| `n_frames` | Frames with a box. |
| `mean_conf` | Mean confidence. |
| `class` | The class seen in most frames. |

**`mot/<clip>.txt`:** every tracked box in the MOTChallenge text format
`frame,id,x,y,w,h,conf,-1,-1,-1` (frames counted from 1 in display order, box left/top/width/
height in video pixels). Tracking benchmarks (TrackEval) read it as is. For CVAT,
`tool/video_eval/mot_to_cvat.py` adds the class column CVAT expects. A clip without any box gets
an empty file.

Worth knowing when comparing with a hand count:

- **First frames:** as in live sessions, a track shows up only once confirmed (after the minimum
  track length), so `mot/` and `detections` lack each track ID's first frames. `start_s` is the
  tracker's first sighting, before confirmation (`first_seen_ms` of its `created` line);
  `n_frames` counts from confirmation. The app's summary, Dashboard, Video tab and
  identification start a track ID there too, so their lengths match `duration_s`. Even so, the
  shortest track ID can be one frame step shorter than the minimum track length (5 frames at 5
  per second span 0.8 s).
- **Finished clips only:** only clips whose analysis finished are tracked (`clips_left_out`
  lists the others).
- **Across clips:** one tracker follows an insect from one clip into the next only when the next
  clip's first analysed frame comes after the previous clip's last one, within the occlusion
  tolerance (clips recorded back to back). The track ID keeps the first clip's clock, so its
  `end_s` can exceed that clip's length. Otherwise the tracker starts again from nothing, since
  imported files can overlap or carry wrong clocks. Track IDs stay unique per session.
- **Times** come from each frame's own time stamp, never from frame number ÷ fps.
- **Low analysis rate:** keep the occlusion tolerance well above the time between two analysed
  frames, or every track ID breaks into pieces.

<details>
<summary>Older files: track IDs from videos</summary>

- *Find track IDs* on videos exists since round 228; `observed_ms` since round 229;
  `keep_frames` and `file_token` since round 234; `clips_with_track_ids` since round 319.
- Round 230: `mot_to_cvat.py`. Round 305: the app starts a track ID at the first sighting, so
  lengths match `duration_s`. Round 308: the videos' own tracker settings (algorithm,
  "New-track confidence", fine-tuning, occlusion tolerance, minimum track length).
- `track_ids.csv` was called `visits.csv` before round 248.

</details>

### Kept frames: `roi_frames/`

With *Keep frames of each track ID* on (the default), *Find track IDs* also chooses pictures of
each track ID by the rule live photos follow: the track ID's first frame, then one every *Keep a
frame every* seconds (default 1 s) for up to *For up to* seconds (default 10 s) after the track
ID was first seen.

Track IDs in the same frame share one picture. So a session keeps about
`track IDs × (1 + duration ÷ step)` frames, fewer for track IDs shorter than the duration.

- **Records:** each frame gets a `capture` record in `post_tracks.jsonl`: `file` (a live photo
  name, `roi_<token>_<date>_<time>_<ms>.jpg` with the frame's wall-clock time),
  `captured_at_ms`, `track_ids`, `source: "video"`, `clip`, `frame`, `pts_us` (the frame's
  position in the clip in µs; the Video tab's player position is `pts_us ÷ 1000` ms), `roi_px`
  (the analysed area `[x, y, width, height]` in upright video pixels) and its size: `saved_px`
  for a square, `saved_w` and `saved_h` otherwise.
- **Saving:** right after *Find track IDs*, the app reads each clip once from front to back and
  saves the analysed area of each chosen frame at full size (JPEG quality 90) into
  `roi_frames/`, where live photos go, so the gallery copy and identification treat them like
  photos. A frame whose file is there is not saved again: a stopped or interrupted saving
  continues with **Save the remaining N frames**, and finding the track IDs again with the same rule
  only saves the frames that changed.
- **Deleting:** a later *Find track IDs* deletes the kept frames it no longer keeps. It never
  overwrites or deletes a file no run kept (a name already taken moves on by 1 ms), nor a kept
  frame whose video is no longer in `videos/`, since it could not be made again.
- **On screen:** the summary's Video tab shows them under the player as *Kept frames*. *Show in
  video* moves the player to the frame's moment and scrolls it, with its controls, to the top of
  the tab. Small white marks on the player's time bar mark the saved kept frames. The *Find
  animals in videos* screen shows how many are saved and the storage they take.

<details>
<summary>Older files: kept frames</summary>

Kept frames exist since round 234. The white marks on the time bar since round 235, on the bar
itself since round 307.

</details>

### Freeing storage: deleting the videos

The videos take most of a session's space. Once the track IDs are found, **Free storage** on the
*Find animals in videos* screen offers two deletions, each after a confirmation. The videos are
kept unless you choose one:

- **Delete N clips without any track ID (…)…** (the dialog: **Delete the clips without any track
  ID?**): clips that the current *Find track IDs* followed and in which no track ID has a box.
  A track ID running on into the next clip keeps that clip; one that only ran out of time there,
  with no box in it, does not.
- **Delete all N clips, keep the saved frames (…)…** (the dialog: **Delete all videos?**): usable
  once every clip is analysed, the track IDs include the latest analysis and every kept frame is
  saved. Before that the button is greyed out, with a note that says what is left to do.

| After a deletion | |
|---|---|
| **Stays** | `video_detections.jsonl` (the detector's boxes), `post_tracks.jsonl`, `track_ids.csv`, `mot/` and the kept frames in `roi_frames/`. |
| **Still works** | *Find track IDs* runs from the boxes. A kept frame whose clip is gone is never overwritten or deleted. |
| **Goes** | Playing the clip, analysing it again (another square or model), and keeping other frames from it. |

A frame that a new rule would need from a deleted clip is counted as "can no longer be saved".
Analysing the remaining clips again with other settings also drops the boxes of the deleted
clips, and the dialog says so.

Each deletion adds one record to `session.jsonl`, after `end_of_session`:

| Field | Meaning |
|---|---|
| `type` | `video_cleanup` |
| `time_ms`, `time_iso` | When. |
| `mode` | `without_track_ids`, `all`, or `cut_off` (clips cut off by a killed app, above). |
| `clips` | The file names deleted (as in `videos/`). |
| `freed_bytes` | The space freed. |
| `track_ids_run_id` | The `run_id` of the *Find track IDs* run the choice was based on. |

The summary's Setup tab adds a *Videos deleted* row (count and space freed). On the Video tab a
deleted clip says when it was deleted, and its boxes, track IDs and kept frames still show.

**Share results** zips `track_ids.csv`, `mot/`, `post_tracks.jsonl`, `video_detections.jsonl`
(to track again on a computer), `session.jsonl` (clip start times) and, once runs have measured
the phone, `phone_during_analysis.csv` (above). How to count the same clips by hand, score the
app against that count and find the lowest frame rate that still counts track IDs correctly:
[VIDEO_ANALYSIS.md](VIDEO_ANALYSIS.md).

<details>
<summary>Older files: deleting videos, sharing results</summary>

Deleting videos (`video_cleanup`) exists since round 236; the mode `cut_off` since round 243.
`phone_during_analysis.csv` is shared since round 232. VIDEO_ANALYSIS.md dates from round 230.

</details>

### Where the app reads these track IDs

The session summary (track ID count and timeline, Setup rows), the dashboard and identification
read a session's track IDs from **one** file:

- `post_tracks.jsonl` when it exists and the session did not track live (imported videos, or a
  motion or time-lapse session);
- `session.jsonl` otherwise.

The two are never added together. The dashboard counts an imported session once *Find track IDs*
has run. Its track IDs per hour use `observed_ms` (the filmed time), not the span from the first
clip's start to the last one's end, since the gaps between clips were not filmed. A problem
report carries the run records of both files (`video_detections_runs.jsonl`,
`post_tracks_runs.jsonl`), without the boxes of each frame.

<details>
<summary>Older files: where the app reads track IDs</summary>

This rule exists since round 229.

</details>

### The Video tab: watching the boxes

For an imported video session the summary's first tab is **Video** (live sessions keep
*Photos*). It plays the session's clips with the detector's boxes drawn on them, so you can see
what the detector found and whether the analysed square was well placed. The tab only reads
`video_detections.jsonl`, `post_tracks.jsonl` and the kept frames in `roi_frames/` (shown under
the player); it writes nothing.

The same player also sits at the end of *Find animals in videos*
(*Watch the results*), without its button to that screen and without the kept frames below it.
The boxes, switches, controls and time bar below work the same there.

- **Which boxes show at a moment.** The player's position counts from the clip's first frame,
  the same clock as `start_s`/`end_s` in `track_ids.csv`. It shows the boxes of the last
  analysed frame at or before that position and keeps them for at most 1.5 times the step
  between analysed frames (150 ms at 10 frames per second). Parts of a clip that were never
  analysed (a gap, the end of a stopped analysis) show no boxes, never old ones. At an analysis
  rate below the video's frame rate the boxes move in small steps, and at higher playback speeds
  they can trail a fast insect a little.
- **Track IDs or all AI boxes.** Once *Find track IDs* has run, the boxes are the tracked ones
  from `post_tracks.jsonl`, labelled `#<track ID> class conf` with the same number as in
  `track_ids.csv`. A faded box is a frame where the detector missed the insect and the tracker
  kept its place.
- **The *All boxes* switch** shows every `raw_detections` box instead, including those *Find
  track IDs* did not count: a track ID shorter than the minimum length, the frames before a
  track was confirmed (see above), or an insect never seen with at least the tracker's
  *New-track confidence* (`highThresh` in `post_track_start.tracker`: weaker boxes only continue
  a track). The time bar is then green where a box shows (each analysed frame with a box until
  the next analysed frame), and the line under it gives the share of the analysed frames with at
  least one box.
- **Only detector boxes, with a note,** before *Find track IDs*, and when the videos were
  analysed again after it (the track IDs' `detections_run_ms` no longer matches the analysis
  run).
- **Whole frame or what the detector saw.** When a square was analysed, *Whole frame* draws it
  and darkens the part left out; *What the detector saw* zooms onto the square. The square comes
  from `roi_px` in `video_clip_done`, or from the run's `settings.roi` for a clip whose analysis
  has not finished. Insects outside the square or cut by its edge mean the square should move:
  *Change square and analyze again* opens *Find animals in videos* for the session, and the tab
  reloads on return.
- **Controls.** Tap the video to pause or play; 5 s back and forward; previous and next track ID
  (each starts 1 s before the track ID's first sighting; its boxes appear from confirmation on);
  speed 0.5×, 1×, 2×, 4×, 5× or 10× (5× and 10× for an overview; the player may skip pictures);
  sound is off until switched on. Tapping a track ID in the list below the player jumps to it.
- **Time bar.** One bar under the video is both the slider and a map of the clip: cyan where the
  clip has at least one track ID (each track ID from its start to its last box, joined where
  they overlap, at least 2 px wide), grey where there is none, with small white marks at the
  saved kept frames. All track IDs share the one colour, since a clip can have hundreds.
- **Using the time bar.** A tap jumps there. A drag pauses the clip, moves the video with the
  finger (at most one jump every 150 ms) and plays on afterwards if it played. The boxes wait
  for the new picture after each jump, as after the buttons.
- **The line under the bar** gives the share of the clip's length with track IDs, e.g. *Track
  IDs in 23 % of this clip (2:14 of 9:40).*, or *No track ID in this clip.* In *All boxes*, and
  before *Find track IDs*, the bar is green where boxes show instead. A clip not analysed yet
  shows the grey bar only.

<details>
<summary>Older files: the Video tab</summary>

The Video tab exists since round 231; the kept frames under the player since round 234. Round
247: boxes below the *New-track confidence* only continue a track. Round 273: speeds 5× and
10×. Round 307: the time bar, and the share of analysed frames with a box in *All boxes*. Round
309: the same player at the end of *Find animals in videos* (*Watch the results*).

</details>
