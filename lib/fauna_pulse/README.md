# FaunaPulse (Phase 1)

Field app for detecting and timing flower-visiting insects, built on the
Ultralytics YOLO Flutter plugin. This folder holds all the app-specific code;
the plugin itself (camera, detector, GPU/CPU) is untouched.

## What Phase 1 does
- Live camera preview with on-device YOLO detection (plugin).
- A **draggable square ROI** (region of interest) over the flower. Only
  detections whose centre is inside the ROI are kept.
- A **pure-Dart ByteTrack-style tracker** assigns each insect a stable
  `track id` across frames (this is what makes visitation rate measurable).
- **Time-lapse JPEG capture** of the ROI while a visit is active (first photo on
  appearance, then every `step` seconds for up to `duration` seconds per track;
  simultaneous tracks share one photo).
- An **append-only `session.jsonl` log** (one JSON object per line) that survives
  crashes — a missing `end_of_session` line means the session ended abnormally.
- An **end-of-session summary**: unique track count + a visit-duration bar chart.

Deferred to Phase 2 (see the plan): native crop-to-model ROI for better
small-insect recall, the CPU-vs-GPU startup benchmark, and the screen-dim
power-saving mode.

## Code map
```
models/roi.dart            square ROI math (resolution-independent)
models/track.dart          Track + Detection types
models/session_config.dart user/default settings (+ SharedPreferences)
tracking/byte_track.dart   the tracker
logging/session_logger.dart append-only JSONL writer
capture/roi_capture.dart   time-lapse scheduler + ROI crop (background isolate)
widgets/roi_overlay.dart   draggable square overlay
widgets/track_box_painter.dart  boxes labelled with track id
screens/home_screen.dart        entry + camera permission
screens/camera_session_screen.dart  the orchestrator
screens/settings_sheet.dart     all settings
screens/session_summary_screen.dart dashboard
```

## Output layout (per session)
```
<external files>/sessions/<folder>/
  session.jsonl          append-only log (read with jsonlines / read_json(lines=True))
  roi_frames/roi_<sessionId>_<epochMs>.jpg
```
On Android this is `Android/data/<package>/files/sessions/...`, visible over USB.

## session.jsonl record types
Every line has `type`, `time_ms`, `time_iso` (ISO-8601 with ms + UTC offset).
- `start_of_session` — device, battery_percent, model/params, tracker_params, initial `roi`.
- `roi_update` — new `roi` whenever the user adjusts the box.
- `detection` — `track_id`, `class_name`, `confidence`, `box_in_roi`
  (coordinates 0..1 *inside the ROI*), and `jpeg` (filename or null).
- `end_of_session` — `ended_normally` (true only on a clean stop), battery, count.

Reading in R: `jsonlines::read_json_lines("session.jsonl")` or
`jsonlite::stream_in(file(...))`. In Python:
`pandas.read_json("session.jsonl", lines=True)`.
