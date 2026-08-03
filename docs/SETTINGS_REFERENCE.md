# Settings Reference

**Who this is for:** the researcher choosing session settings. Each entry says
what the setting does, its default, and when to change it. Settings persist
between sessions (last-used values reappear).

Source of truth for defaults: `lib/fauna_pulse/models/session_config.dart`
(the `SessionConfig` constructor). If a default here ever disagrees with that
file, the file wins — please update this doc.

The Settings sheet is organized into four tabs, grouped by what you are trying
to do (round 159): **Setup** (what am I recording?), **AI** (how does detection
behave?), **Photos** (what do saved photos look like?), **Power** (heat,
battery and rates). A first session needs only the Setup tab: output folder,
capture trigger, session length. Expert settings sit inside collapsed
**Advanced** sections on each tab — tap to open them; nothing is hidden for
good. Each numeric setting also keeps its full explanation behind a small ⓘ
icon: tap the setting's name to show or hide it.

Before round 159 the last two tabs were called **Camera** and **Graphs**, and
the heat controls (inference throttle, camera frame rate cap, motion gate) sat
on the Camera tab. If an older screenshot or note mentions those, look on the
**Power** tab now.

**Mode-aware controls (round 147):** settings that have no effect under the
selected *Capture trigger* grey out or disappear instead of pretending to be
editable — the whole **AI** tab and "Show detection boxes" in the motion and
time-lapse modes, the inference auto-throttle outside AI mode, and the motion
gate + its sensitivity in time-lapse mode. Greyed values are not erased: they
come back as soon as a mode that uses them is selected.

---

## Model & detection

| Setting | Default | What it does / when to change |
|---|---|---|
| **Model** | `yolo26n` | Which AI model detects insects. Only the bundled "nano" model ships with the app; other `.tflite` models must be added to the phone first (see [INSTALL.md](INSTALL.md)). Change to use a custom-trained model. |
| **Confidence threshold** | `0.25` | Minimum score (0–1) for a detection to be kept. Raise it if you get false detections on non-insects; lower it if real insects are being missed. |
| **IoU threshold** | `0.7` | *(AI tab → Advanced (engine & thresholds))* Overlap threshold (0–1) for removing duplicate boxes of the same insect ("Non-Max Suppression"). Rarely needs changing. Lower it if one insect gets multiple overlapping boxes. |
| **CPU threads** | `0` (auto) | *(AI tab → Advanced (engine & thresholds))* How many processor cores the model may use on the CPU (GPU runs ignore it). Run the engine benchmark in the same fold before changing it. |

## Region of Interest & photos

| Setting | Default | What it does / when to change |
|---|---|---|
| **Target plant / folder name** | `session` | Names the output folder (usually the target flower species). |
| **Time-lapse step** | `1.0 s` | Seconds between saved photos while a visit is ongoing. The first photo is taken the moment an insect is detected, then every step. Larger = fewer photos. |
| **Capture duration** | `10.0 s` | Total seconds to keep photographing one insect (track), from first detection. **Must be a whole multiple of the step** (e.g. step 1 s, duration 10 s → up to 10 photos). The app warns if it isn't. |
| **Turn camera off between bursts (time-lapse only)** | `off` | Round 163. Big heat/power saver for sparse time-lapses: after each burst the camera hardware is fully turned off ("parked") and turned back on ~10 s before the next burst so it is warm when the first photo is due. The **preview freezes** while the camera is off — the mode chip adds "camera off" so you know it is intentional. Only takes effect when the burst timing leaves at least 30 s between bursts (otherwise the camera simply stays on). Reliability first: if the camera ever fails to deliver frames within 20 s of a wake, it stays on for the rest of the session and the failure is logged (`camera_sleep` records; see DATA_GUIDE). Off by default because turning the camera off/on is the riskier path — validate one session before a long unattended deployment. |
| **Photo source (capture mode)** | `fast` (round 117; was `auto`) | Where each saved photo comes from. **fast** (the default) = crop the small live video frame: no camera stall, and the photo shows the exact trigger moment. **high-res** = take a full-resolution photo and cut the ROI out. That sounds desirable, but each high-res photo pauses the AI detection pipeline for 0.13–1.5 s (longer on older phones), lands a fraction of a second after the trigger, and often shows motion blur — and a blurred high-res photo carries *less* usable detail than a smaller crisp crop, so the extra pixels can hurt rather than help downstream classification. It also costs heat and storage. **auto** = per photo, use the fast crop when it already meets your target size, and pay for a high-res photo only when the ROI is too small. Pick auto or high-res deliberately: tiny flower in frame, mostly stationary insects. *Renamed in round 112: this path was called "still" before, and `still` remains its value in `session.jsonl` and saved configs (frozen wire format).* |
| **Sync companion photo (high-res)** | `on` | Round 108. Only applies when a photo takes the **high-res path** (in fast mode it does nothing — a fast photo *is* the live crop). The companion is always the fast live-frame crop, never a second high-res photo: a high-res photo physically lands up to ~1 s after the detection that triggered it (measured ~0.76 s median on the test Xiaomi), so a fast insect can be gone from it. With this on, the trigger-moment live crop is saved next to the high-res photo as `…_live.jpg` — lower resolution, but the insect is in it. ~50–200 KB extra per photo. |
| **Target saved size** | `1024 px` | The pixel size (one side) you want saved ROI photos to have. In auto mode this is the threshold that decides fast-vs-high-res, and it also caps size (bigger crops are downscaled to it). Photos are **never upscaled** to reach it — if even a high-res photo can't reach it, the photo saves smaller and the on-screen readout shows ⚠. Snapped to a multiple of 32 for the model. |
| **Reference photos** | `on` (round 152; was the round-107 "Ground-truth frames" toggle, off, under AI → Visit tracking → Advanced) | Saves an ROI photo at a fixed interval, whether or not anything is detected — an unbiased record of what the camera really saw. Use them to spot pollinators the AI missed (send those photos in to improve the model) or to hand-count true visits. They land in `gt_frames/` with `ref_…` filenames (folder/record names kept from round 107 so old data stays readable), always via the fast live-frame crop (a high-res capture would stall detection), size follows Target saved size. Greyed out in time-lapse mode — that whole session is already clock-driven photos. |
| **Reference photo interval** | `30 s` | Time between reference photos (1 s–1 h; enter in seconds or minutes). 30 s ≈ 120 photos/hour (~0.15–0.3 GB per 8 h day); shorter catches briefer visits but uses more storage. |

## Session length

| Setting | Default | What it does / when to change |
|---|---|---|
| **Session length** | `60 min` | Recording auto-stops after this many minutes. Set to your planned observation window. |

## Speed, heat & battery (Power tab)

| Setting | Default | What it does / when to change |
|---|---|---|
| **Inference FPS cap** | `10` | Maximum times per second the detector runs. Insect visits last seconds, so ~10/s is plenty and it delays the thermal collapse that happens if the phone runs flat-out under sun. **`0` = uncapped** (raw benchmark mode only). |
| **Auto-throttle** | `on` | When on, the app automatically lowers the inference rate during the session to keep the phone cool and the rate steady, instead of overheating into a ~3 fps collapse. With it on, the FPS cap above acts as the *ceiling*; with it off, the cap is a fixed manual value. Leave on for field use. |
| **Minimum inference FPS** | `3` | *(Advanced (throttle tuning) fold)* The lowest rate auto-throttle will drop to, so the session stays usable even when hot. Only used when auto-throttle is on. |
| **Throttle duty target** | `0.5` | *(Advanced (throttle tuning) fold)* How busy (0–1) auto-throttle tries to keep the processor. Lower = cooler and steadier but fewer FPS; higher = more FPS but more heat. Only used when auto-throttle is on. |
| **Camera frame rate cap** | `15 /s` | How many frames per second the camera *hardware* captures (round 82). Different from the inference cap: that one only skips frames in software, while the sensor + image processor otherwise keep running at full rate the whole session — even while the motion gate has the detector asleep (the main measured reason a "sleeping" phone still warms up). Lower = cooler phone, slightly choppier preview; detection is unaffected while this stays at or above the inference cap. `0` = no cap (~30/s on most phones). Capping also delays high-res photos (~0.4 s content lag at 15/s vs ~0.17 s uncapped on the test phone, round 110); the `_live.jpg` companion covers the trigger moment either way. |
| **Use GPU when available** | `on` | *(AI tab → Advanced (engine & thresholds))* Prefer the GPU for the model; the app automatically falls back to CPU if the GPU can't run the model (and remembers models that crash the GPU). |

## Motion gate (opt-in; Power tab)

The motion gate lets the detector **sleep** while nothing moves in the ROI, so
the phone stays cool during the (usually long) empty-flower stretches of a
field session. It is **off by default** until validated against always-on
recall. A cheap brightness comparison against a slowly-learned background does
the watching (native side, under ~1 ms/frame).

The sensitivity settings sit in a **Gate sensitivity** fold under the switch.
In motion-trigger mode (where they decide what causes a photo) the fold opens
by itself; in AI mode it starts collapsed.

| Setting | Default | What it does / when to change |
|---|---|---|
| **Motion gate** | `off` | Master switch. Turn on for long sessions on a **mounted** phone (handheld shake keeps it awake). |
| **Pixel delta** | `25` | How much a pixel's brightness (0–255) must change to count as "moved". Lower = more sensitive (better recall, but petal shadows can wake it); higher = stricter. |
| **Area fraction** | `0.005` (0.5%) | Fraction of the ROI that must change in one frame to wake the detector. Kept small because an insect covers little of the ROI. |
| **Wake seconds** | `3.0 s` | How long the detector keeps running after the last motion or detection. Longer = safer recall (a still insect keeps being re-detected, extending the window), but saves less heat. In **motion-trigger mode** the same window means: how long photos keep being taken after the last motion (they stop when the gate goes back to sleep). |
| **Grid size** | `48` (range 16–160) | How many cells per side the ROI is shrunk to for the motion check. Raise it (e.g. 96–128) when insects are small relative to the ROI box; costs slightly more CPU. |
| **Idle check FPS** | `5` (range 1–30) | How many frames per second are inspected *while the gate is asleep*. Higher = faster wake-up but a warmer idle phone. An arriving insect is noticed within ~1/this seconds. (This is why the FPS readout legitimately shows this low number during empty periods.) |

## Visit tracking (AI tab)

Tracking links each insect's detections across frames into one visit with a
stable ID. Two algorithms are available (round 105); both count visits the
same way, so results stay comparable across sessions.

| Setting | Default | What it does / when to change |
|---|---|---|
| **Tracker algorithm** | `ByteTrack` | *(inside the Advanced fold since round 159 — comparing trackers is a research task)* How detections are linked frame to frame. **ByteTrack** predicts where each insect went and matches by box overlap; **C-BIoU** enlarges the boxes before comparing them. Compare them on your own recordings with the replay harness (see "Log raw detections" below) rather than trusting labels. |
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

The round-107 **Ground-truth frames** toggle that used to live here is now
**Reference photos** on the Setup tab (see "Region of Interest & photos") —
on by default since round 152.

A **Reset tracking to defaults** button in Advanced restores every setting in
this section (keeping the algorithm choice).

## Camera stream & lens (Photos tab)

The stream choice sits in the **Advanced (camera stream)** fold: on "Auto" it
simply follows *Saved photo side*, so most users never open it. The camera
frame rate cap moved to the Power tab (it is a heat control, see above).

| Setting | Default | What it does / when to change |
|---|---|---|
| **Stream resolution** | `Auto` | The video resolution the detector analyzes (4:3). The phone delivers the nearest it supports. The short side caps how large a *fast* (no-stall) ROI crop can be — it does **not** affect detection accuracy (every frame is shrunk to the model's input size anyway). **Auto** (round 109, the default until you pick a size) chooses the smallest device-supported size whose short side is ≥ 1024 px, so fast crops can reach the default *Saved photo side* and the slow high-res path (≈0.4–0.8 s behind the trigger on the test phone) is needed less often; sizes above the phone's real analysis ceiling are never auto-picked. Trade-off: larger streams cost more per-frame processing → more heat and battery; on a heat-limited phone pick a small size manually (a manual choice is never overridden). |
| **Lens** | `1.0` (main wide) | Which rear lens, by zoom factor: 1.0 = main wide, 0.5 = ultra-wide, 2.0/3.0 = telephoto. The app snaps to the available lens closest to this value; single-lens phones just stay on their one lens. Use a telephoto/zoom to reach the target photo size on a small flower. |
| **Focus** | manual/auto/fixed | Locked manual focus is recommended for a mounted session so the flower stays sharp; the log records which mode was used. |

## Display & diagnostics (Setup tab → On-screen display fold)

| Setting | Default | What it does / when to change |
|---|---|---|
| **Show FPS** | `on` | Show the live frames-per-second number. (Moved from the AI tab in round 159 — it is a display toggle.) |
| **Show boxes** | `on` | Draw bounding boxes + track-ID labels. Turning off removes per-frame repaint for the lightest preview; detection/tracking still run. |
| **Show status strip** | `on` | The top-left info strip (FPS, model, engine, stream, ROI size, temperature, track count). |
| **Flash on capture** | `on` | Briefly flash the ROI border when a photo saves, as a visual cue. Border-only, at photo cadence — never affects FPS. |

Two related toggles live elsewhere:

- **Show setup tips at session start** moved to the home screen's **⋮ menu**
  (round 159) — it is an app-level preference, not a per-session setting.
- **Square (1:1) export crops** (Photos tab → "Photo viewer") forces the
  crop-and-export box in the summary photo viewer to a square; the "1:1" chip
  next to the crop box toggles the same setting.

## Graphs & logging cadence (Power tab → Diagnostic graph sampling fold)

Frame rate, phone temperature and battery power are always logged while
recording (the readings are taken for the live preview anyway, so logging them
is free — roughly 2–3 MB per 8-hour session). In the session summary they
appear under a collapsed **"Extra graphs"** section, so the visit timeline —
the main result — stays front and centre.

| Setting | Default | What it does / when to change |
|---|---|---|
| **FPS sample interval** | `5 s` | How often the frame rate is logged for the FPS graph. |
| **Temperature sample interval** | `10 s` | How often phone temperature is logged (heat changes slowly). |
| **Power sample interval** | `10 s` | How often battery power/charge is logged for the energy graphs. |

## Photo analysis (Analysis screen)

These settings live on the **Analysis** screen (long-press a session), not
the Settings sheet, and persist in app preferences (`analysis_sahi_*`) — they
control how saved photos are re-examined *after* a session, so they are not
part of `SessionConfig`.

### Small-insect tiling (SAHI) — advanced

Normally the whole photo is shrunk down to the model's input size before
detection ("letterboxing" — a 1024 px photo fed to a 640 px model loses about
40% of its linear resolution, and a tiny insect can shrink below
detectability). Tiling instead cuts the photo into overlapping tiles of
roughly the model's own input size, runs the detector once per tile at
near-native pixel scale, maps the per-tile boxes back into whole-photo
coordinates, and merges duplicates. An optional extra whole-photo pass
catches insects larger than one tile. It is slower (one inference per pass —
the screen shows a live cost preview like "1024×1024 px photos, 640 px tiles,
25% overlap → 2×2 tiles + whole photo = 5 passes ≈ 5× time"), and worth
trying when the model input is much smaller than your photos.

This is FaunaPulse's own pure-Dart implementation of the "Slicing Aided
Hyper Inference" idea (`lib/fauna_pulse/postprocess/sahi.dart`) — no external
SAHI library is used (none exists for Android/Flutter). For the concept, see
the [original SAHI project](https://github.com/obss/sahi) and
[Ultralytics' SAHI guide](https://docs.ultralytics.com/guides/sahi-tiled-inference/).
Those describe *their* implementations; since round 141 FaunaPulse merges
duplicates by the same criterion they use (intersection-over-smaller-box —
rounds 139–140 used plain IoU, see the note below the table).

| Setting | Default | What it does / when to change |
|---|---|---|
| **Use tiled analysis** | `off` | Master switch. Off = each photo gets the single plain pass, exactly as before round 139. |
| **Tile size** | `0 px` (auto) | Tile side in pixels. 0 = automatic: the selected model's own input size, so each tile is analyzed at native model scale — the standard choice. Larger tiles = fewer passes but more downscaling per tile. A photo that fits inside one tile skips tiling entirely (only the whole-photo pass runs; the preview says so). |
| **Tile overlap** | `25 %` | How much neighbouring tiles share, so an insect sitting on a tile border appears whole in at least one tile. |
| **Also run the whole-photo pass** | `on` | Adds the plain letterboxed pass on top of the tiles — catches insects larger than one tile, at the cost of one extra inference. |
| **Duplicate-merge overlap** | `0.5` | The overlap level at which two same-class boxes from different passes count as the *same* insect and merge into one (the higher-confidence box wins). Since round 141 overlap is measured against the **smaller** box ("IoS"), so a partial box sitting inside a bigger one merges away — rounds 139–140 measured plain IoU, which kept such contained boxes as extra small boxes. |
| **Ignore tiny tile boxes** | `0 %` (off) | Round 141, fixed in 143. Drops tile detections whose box is *narrower* than this fraction of the photo side in either direction — catching both background specks (tiny both ways) and the thin sliver boxes tiling produces at tile borders (a partial insect cut by a tile edge is thin in one direction but can be long in the other). It never removes whole-photo-pass boxes, so it can only trim what tiling added, never fall below a plain run. Careful: SAHI's whole purpose is finding small insects, and a slender insect seen side-on also has a narrow side — start low (~1–2%) and check the review boxes before trusting it. |

**Extra small boxes when tiling** — mostly fixed in round 141. Two causes:
partial insects at tile borders (small boxes *inside* the full-insect box —
merged away since round 141 by the smaller-box overlap above) and fine
background specks that each tile sees at near-native scale (trim with
"Ignore tiny tile boxes" and/or a higher confidence threshold). Either way,
treat the boxes as triage evidence ("this photo contains a pollinator"),
not as tight annotations — that matches the feature's stated goal (recall
for keep/delete triage).

Also on this screen: **Re-analyze photos already done** (per-run checkbox,
deliberately not persisted) — reruns photos that already have a result, so
you can try a different model or different tiling settings on a finished
session. The newest result per photo wins downstream (see
[DATA_GUIDE.md §6](DATA_GUIDE.md)).

---

**Note for developers:** by project rule, every new tunable ships with a
Settings control here, persistence in `SessionConfig` (JSON round-trip + test),
and a row in the end-of-session summary — in the same round it's introduced.
See [CONTRIBUTING.md](CONTRIBUTING.md).
