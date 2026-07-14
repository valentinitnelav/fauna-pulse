# Settings Reference

**Who this is for:** the researcher choosing session settings. Each entry says
what the setting does, its default, and when to change it. Settings persist
between sessions (last-used values reappear).

Source of truth for defaults: `lib/fauna_pulse/models/session_config.dart`
(the `SessionConfig` constructor). If a default here ever disagrees with that
file, the file wins — please update this doc.

The Settings sheet is organized into four tabs: **Setup**, **AI**, **Camera**,
**Graphs**. Below they are grouped by purpose.

---

## Model & detection

| Setting | Default | What it does / when to change |
|---|---|---|
| **Model** | `yolo26n` | Which AI model detects insects. Only the bundled "nano" model ships with the app; other `.tflite` models must be added to the phone first (see [INSTALL.md](INSTALL.md)). Change to use a custom-trained model. |
| **Confidence threshold** | `0.25` | Minimum score (0–1) for a detection to be kept. Raise it if you get false detections on non-insects; lower it if real insects are being missed. |
| **IoU threshold** | `0.7` | Overlap threshold (0–1) for removing duplicate boxes of the same insect ("Non-Max Suppression"). Rarely needs changing. Lower it if one insect gets multiple overlapping boxes. |

## Region of Interest & photos

| Setting | Default | What it does / when to change |
|---|---|---|
| **Target plant / folder name** | `session` | Names the output folder (usually the target flower species). |
| **Time-lapse step** | `1.0 s` | Seconds between saved photos while a visit is ongoing. The first photo is taken the moment an insect is detected, then every step. Larger = fewer photos. |
| **Capture duration** | `10.0 s` | Total seconds to keep photographing one insect (track), from first detection. **Must be a whole multiple of the step** (e.g. step 1 s, duration 10 s → up to 10 photos). The app warns if it isn't. |
| **Photo source (capture mode)** | `auto` | Where each saved photo comes from. **fast** = crop the small live video frame (no camera stall, but small ROI → small photo). **still** = take a full-resolution photo and cut the ROI out (far more detail, but briefly stalls the camera and costs heat/storage). **auto** (recommended) = per photo, use the fast crop when it already meets your target size, and pay for a full still only when the ROI is too small. |
| **Target saved size** | `1024 px` | The pixel size (one side) you want saved ROI photos to have. In auto mode this is the threshold that decides fast-vs-still, and it also caps size (bigger crops are downscaled to it). Photos are **never upscaled** to reach it — if even a full still can't reach it, the photo saves smaller and the on-screen readout shows ⚠. Snapped to a multiple of 32 for the model. |

## Session length

| Setting | Default | What it does / when to change |
|---|---|---|
| **Session length** | `60 min` | Recording auto-stops after this many minutes. Set to your planned observation window. |

## Speed, heat & battery (AI tab)

| Setting | Default | What it does / when to change |
|---|---|---|
| **Inference FPS cap** | `10` | Maximum times per second the detector runs. Insect visits last seconds, so ~10/s is plenty and it delays the thermal collapse that happens if the phone runs flat-out under sun. **`0` = uncapped** (raw benchmark mode only). |
| **Auto-throttle** | `on` | When on, the app automatically lowers the inference rate during the session to keep the phone cool and the rate steady, instead of overheating into a ~3 fps collapse. With it on, the FPS cap above acts as the *ceiling*; with it off, the cap is a fixed manual value. Leave on for field use. |
| **Minimum inference FPS** | `3` | The lowest rate auto-throttle will drop to, so the session stays usable even when hot. Only used when auto-throttle is on. |
| **Throttle duty target** | `0.5` | How busy (0–1) auto-throttle tries to keep the processor. Lower = cooler and steadier but fewer FPS; higher = more FPS but more heat. Only used when auto-throttle is on. |
| **Use GPU when available** | `on` | Prefer the GPU for the model; the app automatically falls back to CPU if the GPU can't run the model (and remembers models that crash the GPU). |

## Motion gate (opt-in; AI tab)

The motion gate lets the detector **sleep** while nothing moves in the ROI, so
the phone stays cool during the (usually long) empty-flower stretches of a
field session. It is **off by default** until validated against always-on
recall. A cheap brightness comparison against a slowly-learned background does
the watching (native side, under ~1 ms/frame).

| Setting | Default | What it does / when to change |
|---|---|---|
| **Motion gate** | `off` | Master switch. Turn on for long sessions on a **mounted** phone (handheld shake keeps it awake). |
| **Pixel delta** | `25` | How much a pixel's brightness (0–255) must change to count as "moved". Lower = more sensitive (better recall, but petal shadows can wake it); higher = stricter. |
| **Area fraction** | `0.005` (0.5%) | Fraction of the ROI that must change in one frame to wake the detector. Kept small because an insect covers little of the ROI. |
| **Wake seconds** | `3.0 s` | How long the detector keeps running after the last motion or detection. Longer = safer recall (a still insect keeps being re-detected, extending the window), but saves less heat. |
| **Grid size** | `48` (range 16–160) | How many cells per side the ROI is shrunk to for the motion check. Raise it (e.g. 96–128) when insects are small relative to the ROI box; costs slightly more CPU. |
| **Idle check FPS** | `5` (range 1–30) | How many frames per second are inspected *while the gate is asleep*. Higher = faster wake-up but a warmer idle phone. An arriving insect is noticed within ~1/this seconds. (This is why the FPS readout legitimately shows this low number during empty periods.) |

## Visit tracking (AI tab)

Tracking links each insect's detections across frames into one visit with a
stable ID. Two algorithms are available (round 105); both count visits the
same way, so results stay comparable across sessions.

| Setting | Default | What it does / when to change |
|---|---|---|
| **Tracker algorithm** | `ByteTrack` | How detections are linked frame to frame. **ByteTrack** predicts where each insect went and matches by box overlap; **C-BIoU** enlarges the boxes before comparing them. Compare them on your own recordings with the replay harness (see "Log raw detections" below) rather than trusting labels. |
| **Occlusion tolerance** | `3.0 s` | How long a track survives while the insect is hidden (e.g. behind a petal) before its ID is dropped. Too low fragments one visit into several IDs; too high can merge separate visits. 3 s was tuned for bees. |
| **Minimum visit length** | `0.2 s` | How long an insect must be continuously detected before it counts as a confirmed visit (anything briefer is treated as noise). Directly affects visitation rate for brief touchdowns: lower counts more brief visits (and more false blips); higher counts only clear landings. |

The seconds-based settings are converted to frames against the live frame
rate as it varies during the session.

**Advanced** (collapsed; only the selected algorithm's knobs are shown):

| Setting | Algorithm | Default | What it does |
|---|---|---|---|
| **Match overlap (IoU)** | ByteTrack | `0.1` | Overlap required to treat a detection as the same insect. Lower tolerates faster motion. |
| **Low-score association** | ByteTrack | `0.1` | Looser second test that lets faint detections keep an existing ID. |
| **High-score threshold** | both | `0.5` | Score at/above which a detection may *start* a new ID; fainter ones only keep IDs alive. Auto-kept above Confidence. |
| **Velocity smoothing** | ByteTrack | `0.5` | How much the motion prediction trusts the latest movement. Low = "assume it barely moved". |
| **Search margin — pass 1** | C-BIoU | `0.30` | Boxes are enlarged by this fraction of their own size before the overlap test. Bigger tolerates faster movement but risks mixing close neighbours. |
| **Search margin — pass 2** | C-BIoU | `0.50` | A wider second matching round for whatever pass 1 missed — catches big between-frame jumps. Always ≥ pass 1. |
| **Log raw detections** | both | `off` | Evaluation aid: writes the detector's pre-tracking boxes for every frame into the session file so it can be replayed through either tracker offline (`flutter test test/fauna_pulse/tracker_replay_test.dart --dart-define=REPLAY_SESSION=…/session.jsonl`). Adds ~1–2 MB/h. |
| **Ground-truth frames** | both | `off` | Evaluation aid (round 107): saves an ROI photo at a fixed interval into `gt_frames/`, whether or not anything is detected — an independent record for hand-counting true visits, so the tracker is never judged against photos it triggered itself. Size follows Camera tab → Saved photo side. |
| **Ground-truth frame interval** | both | `5 s` | Time between ground-truth photos (1 s–1 h). 5 s ≈ 720 photos/hour; shorter catches briefer visits but uses more storage. |

A **Reset tracking to defaults** button in Advanced restores every setting in
this section (keeping the algorithm choice).

## Camera (Camera tab)

| Setting | Default | What it does / when to change |
|---|---|---|
| **Stream resolution** | `640 × 480` | The video resolution the detector analyzes (4:3). The phone delivers the nearest it supports. The short side caps how large a *fast* (no-stall) ROI crop can be. Higher = bigger fast crops but can cost FPS on weaker phones. |
| **Camera frame rate cap** | `15 /s` | How many frames per second the camera *hardware* captures (round 82). Different from the inference rate cap: that one only skips frames in software, while the sensor + image processor otherwise keep running at ~30/s the whole session — even while the motion gate has the detector asleep. This standing camera load was measured to be the main reason a "sleeping" phone still warms up. Lower = cooler phone, slightly choppier preview; detection is unaffected while this stays at or above the inference cap. `0` = device default (~30/s). The phone only supports certain rates; the nearest supported one is used (logged at session start). |
| **Lens** | `1.0` (main wide) | Which rear lens, by zoom factor: 1.0 = main wide, 0.5 = ultra-wide, 2.0/3.0 = telephoto. The app snaps to the available lens closest to this value; single-lens phones just stay on their one lens. Use a telephoto/zoom to reach the target photo size on a small flower. |
| **Focus** | manual/auto/fixed | Locked manual focus is recommended for a mounted session so the flower stays sharp; the log records which mode was used. |

## Display & diagnostics

| Setting | Default | What it does / when to change |
|---|---|---|
| **Show FPS** | `on` | Show the live frames-per-second number. |
| **Show boxes** | `on` | Draw bounding boxes + track-ID labels. Turning off removes per-frame repaint for the lightest preview; detection/tracking still run. |
| **Show status strip** | `on` | The top-left info strip (FPS, model, engine, stream, ROI size, temperature, track count). |
| **Flash on capture** | `on` | Briefly flash the ROI border when a photo saves, as a visual cue. Border-only, at photo cadence — never affects FPS. |

## Graphs & logging cadence (Graphs tab)

| Setting | Default | What it does / when to change |
|---|---|---|
| **Auto-compute graphs** | `on` | Generate the summary graphs automatically when the summary opens. On very long sessions, turn off so a full-log parse happens only when you tap "Generate graphs". |
| **FPS sample interval** | `5 s` | How often the frame rate is logged for the FPS graph. |
| **Temperature sample interval** | `10 s` | How often phone temperature is logged (heat changes slowly). |
| **Power sample interval** | `10 s` | How often battery power/charge is logged for the energy graphs. |

---

**Note for developers:** by project rule, every new tunable ships with a
Settings control here, persistence in `SessionConfig` (JSON round-trip + test),
and a row in the end-of-session summary — in the same round it's introduced.
See [CONTRIBUTING.md](CONTRIBUTING.md).
