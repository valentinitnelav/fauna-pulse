# FaunaPulse app code (`lib/fauna_pulse/`)

Field app for detecting and timing flower-visiting insects. This folder holds
all app-specific Dart code; `lib/main.dart` points at the home screen. The app
sits on a **vendored, modified** Ultralytics YOLO plugin
(`packages/ultralytics_yolo/`, camera + on-device detector; see
`packages/ultralytics_yolo/FAUNAPULSE_FORK.md` for what the fork changed) plus
a small native app shell (`android/.../MainActivity.kt`, high-res crop +
device/thermal/keep-alive channels).

How a frame becomes a logged visit, and the native/Dart contract:
[`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md). Current defaults and
invariants: [`docs/AGENT_CHANGELOG_OVERVIEW.md`](../../docs/AGENT_CHANGELOG_OVERVIEW.md).

## What the app does

- Live on-device detection inside a draggable square **ROI** (region of
  interest) over a flower, with a pure-Dart tracker (ByteTrack-style default,
  C-BIoU alternative) assigning stable **track ids** (visits).
- Three capture modes: **detector-triggered** photos, **motion-triggered**
  (no AI at runtime), and **time-lapse** bursts (no AI, optional camera
  parking between bursts).
- Everything is logged to an append-only `session.jsonl`; photos are ROI
  crops saved as JPEGs; optional scheduled recording windows, blackout
  power-save, one-fix GPS location, reference ("ground truth") frames.
- After a session, an on-device batch detector can re-analyze the saved
  photos (optionally SAHI tiling for small insects) and triage storage.

## Code map (one line per directory)

| Directory | Purpose |
|---|---|
| `models/` | Square ROI math (`roi.dart`), track/detection types, `session_config.dart` (all user settings + persistence), model catalog |
| `tracking/` | `InsectTracker` interface, ByteTrack-style + C-BIoU-style trackers, offline replay harness |
| `logging/` | Append-only JSONL writer, thermal/power readers, session-log index, error reporting, crash store |
| `capture/` | Photo scheduling + ROI crop paths (fast live-frame vs high-res), crop/gallery export |
| `session/` | Recording lifecycle split out of the screen (round 73): per-frame processing, recorder, camera probes/calibration cache, schedule plan, time-lapse camera parking, location fix |
| `screens/` | Home, camera session (UI orchestration only), settings sheet, session summary, post-hoc analysis |
| `widgets/` | ROI overlay, track boxes, preview coordinate mapping, setting fields |
| `postprocess/` | Batch detector over saved photos, SAHI tiling + phase profile, keep/cleanup triage |
| `perf/` | Adaptive inference throttle (heat management) |
| `services/` | Keep-alive foreground service binding |

Unit tests mirror these modules in `test/fauna_pulse/` (see
[`test/README.md`](../../test/README.md)).

## Output layout (per session)

```
<external files>/sessions/<session folder>/
  session.jsonl            append-only log, one JSON object per line
  roi_frames/              ROI photos: roi_<token>_<yyyy-MM-dd>_<HHmmss>_<SSS>.jpg
                           (+ optional trigger-moment companions *_live.jpg)
  gt_frames/               reference photos (gt_... prefix), if enabled
  post_detections.jsonl    batch-analysis results, if the user ran one
  logcat_start.txt / logcat_end.txt   diagnostic log snapshots
  crops/                   fallback folder for exported crops (< Android 10)
```

On Android that root is `Android/data/com.faunapulse.app/files/sessions/`,
visible over USB. The filename stamp is the capture TRIGGER moment in local
time, so within a session path sort equals capture order.

## Reading the data

The full record dictionary (record types, field meanings, historical format
changes such as the round-69 switch to one `detections` record per frame) and
ready-made R/Python snippets for visitation rates live in
[`docs/DATA_GUIDE.md`](../../docs/DATA_GUIDE.md). Quick start:
`pandas.read_json("session.jsonl", lines=True)` or
`jsonlines::read_json_lines()` in R.
