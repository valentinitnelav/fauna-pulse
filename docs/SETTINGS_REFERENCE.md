# Settings Reference

This page explains the FaunaPulse settings: what each one does, its default, and when to change it. It is
for researchers and field users who choose the settings of a session. Saved names, earlier
defaults, measurements and history are in folded blocks: click a line that starts with ▸ to open it.

> **In short**
>
> - Settings are kept between sessions: the values you used last come back.
> - The **Session settings** sheet (gear icon on the camera screen) has four tabs: **Setup**
>   (what am I recording?), **Detection**
>   (how does detection behave?), **Photos** (what do saved photos look like?) and **Power**
>   (heat, battery and rates). A first session needs only the Setup tab: output folder, capture
>   trigger, session length.
>   Scheduled recording (daily time windows) is on the Setup tab too.
> - Expert settings sit in closed folds whose titles say *Advanced* or *(advanced)*, on the
>   Detection, Photos and Power tabs. Display switches sit in the **On-screen display** fold on
>   the Setup tab. Nothing is hidden for good: tap a fold to open it.
> - The analysis screens (**Find animals in photos**, **Find animals in videos**, **Identify
>   organisms**) have their own settings. They belong to the analysis, not to a recording.
> - The defaults come from `lib/fauna_pulse/models/session_config.dart` (the `SessionConfig`
>   constructor). If a default here ever disagrees with that file, the file wins: please update
>   this page.

**Contents**

The camera Settings sheet:

- [How the Settings sheet works](#how-the-settings-sheet-works)
- [Capture trigger (Setup tab)](#capture-trigger-setup-tab)
- [Model & detection](#model--detection)
- [Region of Interest & photos](#region-of-interest--photos)
- [Session length](#session-length), with [Scheduled recording](#scheduled-recording-setup-tab)
- [Speed, heat & battery (Power tab)](#speed-heat--battery-power-tab)
- [Motion gate (opt-in; Power tab)](#motion-gate-opt-in-power-tab)
- [Tracking (Detection tab)](#tracking-detection-tab)
- [Camera stream & lens (Photos tab)](#camera-stream--lens-photos-tab)
- [Display & diagnostics (Setup tab → On-screen display fold)](#display--diagnostics-setup-tab--on-screen-display-fold)
- [Graphs & logging cadence (Power tab → Diagnostic graph sampling fold)](#graphs--logging-cadence-power-tab--diagnostic-graph-sampling-fold)

The analysis screens (after a session):

- [Photo analysis (Analysis screen)](#photo-analysis-analysis-screen) (**Find animals in
  photos**), with [Small-insect tiling (SAHI)](#small-insect-tiling-sahi-inside-advanced-settings),
  [Also identify them](#also-identify-them) and [Track IDs](#track-ids)
- [Video analysis (Find animals in videos screen)](#video-analysis-find-animals-in-videos-screen)
- [Identification (Identify organisms screen → Advanced settings)](#identification-identify-organisms-screen--advanced-settings)

For developers: [Note for developers](#note-for-developers).

---

## How the Settings sheet works

**Explanations.** Every setting keeps its full explanation behind a small ⓘ icon. Tap the
setting's name, or the ⓘ itself on a switch row, to show or hide it. Only live warnings and mode
notes (for example "the camera will stay on") stay visible all the time.

**Settings that do not apply.** Settings that have no effect under the selected *Capture trigger*
grey out or disappear instead of pretending to be editable:

- the **Detection** tab and **Show detection boxes & track IDs** in the motion and time-lapse
  modes. The tab name is dimmed but the tab still opens: a grey box says why ("These settings
  apply to live detection mode (the Tracking settings also to "Find animals in photos"). To edit
  them, switch "Capture trigger" on the Setup tab to Live detection."), and its controls cannot
  be changed;
- *Auto-adjust detector rate* outside live detection;
- the motion gate and its sensitivity in time-lapse mode.

Greyed values are not erased: they come back as soon as a mode that uses them is selected.

**Number boxes.** A box never takes a number outside its range. While you type a number outside
the range, a line under the box says what is allowed (for example "Allowed: 0.05 to 0.95."). If
you leave the box with such a number, it keeps the old value and says "Not changed: allowed is …".

When the app stores a slightly different number than you typed, the line says "Saved as …". The ⓘ
of a box also lists its allowed range.

A comma works as the decimal point. You can type only as many decimals as the box shows. Time
boxes have a unit menu beside them (s, min, h): it changes only how the time is shown and typed.

**Settings that limit each other.** No setting changes another stored setting. Where two settings
limit each other (the camera frame rate cap and the detector rates, the two C-BIoU search
margins), each keeps what was typed, and an amber note under the box says which value is used.

**Closing without Apply.** If you close the **Session settings** without *Apply* (Back, a tap
above the sheet, a swipe down), a bar says "Settings closed without Apply: your changes are not
used." and offers an *Apply* button, so the changes are not lost silently. The bar goes away by
itself after about 8 seconds.

The bar's *Apply* works only while nothing records and nothing else
changed the settings meanwhile (for example a lens switch). Otherwise a note says "Not applied:
something changed meanwhile. Open Settings again."

<details>
<summary>History: tab names, and when these rules came</summary>

- The four tabs, grouped by what you are trying to do, came in round 159. Before round 159 the
  last two tabs were called **Camera** and **Graphs**, and the heat controls (detector rate,
  camera frame rate cap, motion gate) sat on the Camera tab. If an older screenshot or note
  mentions those, look on the **Power** tab now.
- The **Detection** tab was called **AI** before round 271.
- Since round 181 every setting has its ⓘ explanation; before, only the numeric ones had one.
- Mode-aware controls (greyed or hidden settings): round 147.
- Number boxes: round 313. Since then no setting changes another stored setting any more, and
  closing without *Apply* shows the "Settings closed without Apply" bar.

</details>

## Capture trigger (Setup tab)

**Capture trigger (what causes photos)** is the drop-down under **Output folder** on the Setup
tab. It decides what makes the phone save photos, and so which other settings apply.

| Option | What it does |
|---|---|
| **Live detection - detect & track in real time** (default) | The detection model runs during the session: it finds and follows the animals (track IDs) and takes photos of each track ID. Needs a detection model; without one it reads "Live detection (needs a detection model)" and cannot be chosen. |
| **Motion-triggered photos** | Takes photos whenever something moves in the yellow square (ROI). No model runs, so no track IDs or names are recorded. What counts as movement is set under *Gate sensitivity* on the Power tab. |
| **Time-lapse photo or video bursts** | Photos or video clips on a fixed schedule, with no detection and no motion check: the cheapest mode. The burst settings below appear. |

With live detection a note under the drop-down stays visible: the detector warms the phone, and
for long or hot sessions it suggests "Time-lapse" with "Save bursts as: Video", then *Find
animals in videos* at home. In the motion and time-lapse modes, find and name the animals later
with *Find animals in photos* (or *Find animals in videos*) and *Identify organisms*.

## Model & detection

| Setting | Default | What it does / when to change |
|---|---|---|
| **Detection model** | none (*Choose a model*) | Which detection model finds the animals. Download one, or import your own (see [INSTALL.md](INSTALL.md)). Motion-triggered and time-lapse capture need no model. A line under the list shows the model's input size ("Input resolution: … px"). |
| **Confidence threshold** | `0.25` | Minimum score (0.05 to 0.95) for a detection to be kept. Raise it if you get false detections on non-insects; lower it if real insects are being missed. |
| **IoU threshold (removes duplicate boxes)** | `0.7` | *(Detection tab → Advanced (engine & thresholds))* Overlap threshold (0.10 to 0.95) for removing duplicate boxes of the same insect ("Non-Max Suppression"). Rarely needs changing. Lower it if one insect gets several overlapping boxes. |
| **CPU threads (0 = automatic)** | `0` (auto) | *(Detection tab → Advanced (engine & thresholds))* How many processor cores (0 to 8) the model may use on the CPU (GPU runs ignore it). 0 = automatic = 2. Run the engine benchmark in the same fold before changing it. |

**Getting a model.** No model comes inside the app. Download one on the **Download & import
models** screen: open it from the home screen **Menu**, or with **Download & import models…**
next to **Detection model** on the Detection tab. Until a detection model is on the phone, the capture trigger "Live detection" is
greyed out.

**Nothing is picked for you.** In live detection mode the camera asks you to choose a model
before it records. The Detection tab says "No model chosen yet. Choose one above.", or "The
chosen model is not on this phone any more. Choose one above." when the chosen file was deleted.

<details>
<summary>History and measurements (model, CPU threads)</summary>

- No model comes inside the app since round 268. Since round 271 nothing is picked for you.
- **CPU threads:** 0 = automatic = 2 since round 226. LiteRT's own default is 1. On both test
  phones 2 threads were ~1.9× faster than 1, and 4 at most ~15% faster than 2 for twice the busy
  cores.

</details>

## Region of Interest & photos

The ROI (region of interest) is the square part of the camera picture that the app watches and
saves.

**Folder name and photo timing:**

| Setting | Default | What it does / when to change |
|---|---|---|
| **Output folder** | `session` | *(Setup tab, first box)* Names the folder the session's photos and log file are saved into (usually the target flower species). |
| **Photo step** | `1.0 s` | Seconds between saved photos (0.1 to 10 s): per track ID in live detection, or within one motion or time-lapse burst. In live detection the first photo is taken the moment an animal is detected, then one every step. Larger = fewer photos. Shorter = more pictures of each track ID for *Identify organisms*, but more storage. |
| **Photo duration** | `10.0 s` | How long photos keep being saved: per track ID in live detection (from the first detection), per motion event with the motion trigger, or per burst in time-lapse. For video bursts it reads **Burst duration (clip length)**. **Must be a whole multiple of the step** (e.g. step 1 s, duration 10 s → up to 10 photos). The app warns if it isn't. |

**Live detection video:**

| Setting | Default | What it does / when to change |
|---|---|---|
| **Also record the ROI as video** | `off` | *(Detection tab → Check live detection (advanced); live detection only)* Records the ROI square as MP4 clips while live detection runs, a new clip every 5 minutes, in the session's `videos/` folder. Costs storage and heat (also while the motion gate lets the detector sleep). |
| **Video frame rate** (live detection video) | `15 FPS` | Frames per second of those clips, 1 to 30. A *Camera frame rate* below it limits the clips to that rate (amber note). |

**Time-lapse bursts:** these sit on the Setup tab, under *Capture trigger* and the photo timing.
They show only when the capture trigger is time-lapse.

| Setting | Default | What it does / when to change |
|---|---|---|
| **Save bursts as** (time-lapse only) | `Photos` | *(Setup tab, right under Capture trigger)* *Photos* saves one square ROI photo every *Photo step*. *Video (MP4), find animals later* saves each burst as one clip of the ROI with every frame, so an insect can be followed from frame to frame. The detector runs later, on *Find animals in videos* (**Sessions** screen → the session's ⋮ menu). |
| **Video frame rate** (time-lapse video only) | `5 FPS` | Frames per second in each clip, 1 to 30. Higher rates give smoother clips and help with very fast insects, but cost storage roughly in proportion. |
| **Time between bursts** (time-lapse only) | `30 min` | The break between photo bursts. `0` = no break: photos flow continuously every step. |
| **Turn camera off between bursts** (time-lapse only) | `on` | Big heat and power saver: the camera is fully turned off in each break and turned on again shortly before the next burst. Only works when *Time between bursts* is at least 30 s. |
| **Camera wake lead** (time-lapse only) | `10 s` | How many seconds before each burst the turned-off camera is turned back on. Range 1–60 s. Raise it if first photos still look off. |
| **Torch during bursts (night)** (time-lapse only) | `off` | For nocturnal monitoring: the phone's LED torch comes on shortly before each burst, stays on through the burst, and goes off in the break. |
| **Torch lead** (time-lapse only) | `5 s` | How many seconds before each burst the torch comes on, so the exposure settles before the first photo. Range 1–60 s. |

**Photo source and size:**

| Setting | Default | What it does / when to change |
|---|---|---|
| **ROI photo source** | *Fast crops only (live frame)* | Where each saved photo comes from: the small live video frame (*Fast crops only*), a full-resolution photo (*High-res photos always*), or a choice per photo (*Auto (high-res only when needed)*). See below. |
| **Also save a fast crop with each high-res photo** | `on` | Only for photos that take the **high-res path**. Saves the trigger-moment live crop next to the high-res photo as `…_live.jpg`: lower resolution, but the insect is in it. ~50–200 KB extra per photo. |
| **Saved photo side (px)** | `1024 px` | The pixel size (one side) you want saved ROI photos to have. Photos are **never upscaled** to reach it. Snapped to a multiple of 32 for the model. |

**Reference photos:**

| Setting | Default | What it does / when to change |
|---|---|---|
| **Reference photos** | `on` | *(Setup tab)* Saves an ROI photo at a fixed interval, whether or not anything is detected: an unbiased record of what the camera really saw. In time-lapse mode the switch shows off and greyed, with the note "Not used in time-lapse mode; photos come on a clock there anyway." |
| **Reference photo interval** | `30 s` | Shown only while *Reference photos* is on (not in time-lapse). Time between reference photos (1 s to 1 h; enter in s, min or h). 30 s ≈ 120 photos/hour (~0.15–0.3 GB per 8 h day). |

**Photo step and storage.** A shorter step helps *Identify organisms* most with short track IDs;
the naming gains little beyond a few pictures per track ID. With fast crops, a step down to 0.2 s
did not slow live detection on the test phones. Storage grows in proportion: 0.5 s doubles it
(about 180 to 240 kB per 1024 px photo).

**Turning the camera off between bursts.** The **preview freezes** while the camera is off; the
mode chip adds "camera off" so you know it is intentional. Switch the setting off only if a phone
keeps failing to wake (the summary's `camera_sleep` records show it). It combines with the
screen-off (moon) button: the moon saves the screen, this saves the camera. Use both for
unattended runs.

**Torch at night.** The mode chip adds "torch" while the LED is lit. Light can attract or repel
some taxa: treat lit windows as their own observation condition.

**Choosing the ROI photo source.** *Fast crops only* (the default) has no camera stall, and the
photo shows the exact trigger moment. A high-res photo sounds better, but it pauses detection,
lands a fraction of a second late and is often blurred (details below). Pick *Auto* or
*High-res* deliberately: for a tiny flower in the frame and mostly stationary insects.

**Reference photos.** Use them to spot animals the detector missed, or to hand-count true track
IDs. Shorter intervals catch briefer track IDs but use more storage.

<details>
<summary>More about the live detection video and burst videos</summary>

**Also record the ROI as video** (round 240). The session summary then opens on a
Video tab that plays the clips with live detection's own boxes and track ID list (the session's
photos follow below the player). So what live detection caught and missed can be checked, counted
by hand, or analysed again with *Find animals in videos*. Storage: an estimate shows under the
switch (the whole session is filmed). Heat: every frame of the clip is converted even while the
motion gate lets the detector sleep. Records: `live_video_start`, `video_clip`, `video_skipped`
with `segment` (DATA_GUIDE §3).

**Video frame rate (live detection video):** round 240.

**Save bursts as** (round 238). *Video (MP4)* clips: the frame rate is set with *Video frame
rate*; the detector runs on *Find animals in videos* (**Sessions** screen → the session's ⋮
menu), as for imported videos.
The clip's side is the *Saved photo side* (Photos tab; smaller when the ROI covers fewer camera
pixels). In video mode *Photo step*, *ROI photo source* and the companion photo are greyed (not
used), and *Photo duration* reads *Burst duration (clip length)*. A storage estimate shows under
the setting: up to about 0.7 GB per recorded hour at 1024 px and the default 5 fps, 2.0 GB at
15 fps (the bit rate plus 20 %, the overshoot measured on the Xiaomi). The session estimate
scales it by burst ÷ (burst + break). Records: `timelapse_video_start`, `video_clip`,
`video_skipped` (DATA_GUIDE §3).

**Video frame rate (time-lapse video only)** (round 238; default 15 until round 290). Default 5:
the rate *Find animals in videos* reads by default, so no stored frame goes unused (FaunaLapse
records 5 too). A *Camera frame rate* below this rate limits the clips to it, and an amber note
says so (choose a higher camera rate, or lower this).

</details>

<details>
<summary>More about bursts, camera off, wake lead and torch</summary>

**Time between bursts** (round 97; renamed and redefined in round 174). After each burst (a photo
every step for the photo duration) the camera waits this long before the next burst starts. This
break is exactly when *Turn camera off between bursts* can power the camera down. Before round
174 the setting ("Repeat burst every") counted START-TO-START of consecutive bursts, so a value ≤
the photo duration silently meant continuous. Saved configs migrate automatically (break = old
interval − duration, effective timing unchanged).

**Turn camera off between bursts** (round 163; default off until round 291). For sparse
time-lapses: after each burst the camera hardware is fully turned off ("parked") and turned back
on shortly before the next burst (see *Camera wake lead*), so it is warm when the first photo is
due. Reliability first: if the camera ever fails to deliver frames within 20 s of a wake, it stays
on for the rest of the session and the failure is logged (`camera_sleep` records; see
DATA_GUIDE). Why on by default since round 291: with the default 30-min break the camera is on
about 1 % of the time instead of all of it (the sister app FaunaLapse closes its camera in every
break by default). Below 30 s of break the camera simply stays on.

**Camera wake lead** (round 164). A full power-off parks the lens motor and discards the exposure
state. So the wake needs real time for the motor to travel back to your locked focus and for
exposure to ramp. A 5 s field test produced a dark, blurry first burst photo, hence the 10 s
default. Lower it only if your first-photo quality holds up.

**Torch during bursts (night)** (round 180). Overnight time-lapses produce usable photos without
anyone standing in the field. The torch comes on *Torch lead* seconds before each burst. It works
together with *Turn camera off between bursts* (the camera wakes at whichever lead is longer, and
the torch re-lights right after the camera is back on) and with the screen-off (moon) button (the
torch sits on the camera, not the screen). The very first burst of a recording, and of each
scheduled window (each window restarts its burst clock), begins immediately and skips the lead.
If the active lens has no flash unit, a one-time notice appears and the session continues without
light. Every torch flip is logged (`torch` records; see DATA_GUIDE).

**Torch lead** (round 180). The camera's automatic exposure settles under the lit scene before the
first photo. Exposure typically re-converges within 1–2 s of the light coming on (it runs in the
camera hardware's own loop, even while the app samples few frames between bursts); 5 s leaves
margin for slow low-light behaviour. A lead ≥ *Time between bursts* means the torch simply never
turns off.

</details>

<details>
<summary>More about the photo source, the fast crop, photo side and reference photos</summary>

**ROI photo source** (default `fast` since round 117; was `auto`).

- **Fast crops only** (`fast`, the default) = crop the small live video frame: no camera stall,
  and the photo shows the exact trigger moment.
- **High-res photos always** (`still`) = take a full-resolution photo and cut the ROI out. Each
  high-res photo pauses the detection pipeline for 0.13–1.5 s (longer on older phones), lands a
  fraction of a second after the trigger, and often shows motion blur. A blurred high-res photo
  carries *less* usable detail than a smaller crisp crop, so the extra pixels can hurt rather
  than help later classification. It also costs heat and storage.
- **Auto (high-res only when needed)** (`auto`) = per photo, use the fast crop when it already
  meets the *Saved photo side*, and take a high-res photo only when the ROI is too small.

Renamed in round 112: this path was called "still" before, and `still` remains its value in
`session.jsonl` and saved configs (frozen wire format). Since round 294, *fast* also switches off
the camera's zero-shutter-lag buffer: two full-size (12 MP) streams the camera otherwise fills all
the time for instant high-res photos, which *fast* never uses (Xiaomi, camera screen open: camera
service about 32 % of one core instead of about 121 %, the whole camera path about 85 % instead of
about 225 %). *Auto* and *High-res* keep the buffer.

**Also save a fast crop with each high-res photo** (round 108). In fast mode it does nothing: a
fast photo *is* the live crop. The companion is always the fast live-frame crop, never a second
high-res photo. A high-res photo physically lands up to ~1 s after the detection that triggered
it (measured ~0.76 s median on the test Xiaomi), so a fast insect can be gone from it.

**Saved photo side.** In *Auto* mode this is the threshold that decides fast or high-res, and it
also caps size (bigger crops are downscaled to it). If even a high-res photo can't reach it, the
photo saves smaller and the on-screen readout shows ⚠.

**Reference photos** (on by default since round 152; this was the round-107 "Ground-truth frames"
toggle, off, under Detection → Tracking → Advanced). They land in `gt_frames/` with `ref_…`
filenames (folder and record names kept from round 107 so old data stays readable), always via the
fast live-frame crop (a high-res capture would stall detection). Their size follows *Saved photo
side*. Greyed out in time-lapse mode because that whole session is already clock-driven photos.

</details>

## Session length

| Setting | Default | What it does / when to change |
|---|---|---|
| **Session length** | `60 min` | *(Setup tab)* Recording stops by itself after this time. Type minutes or hours (the **Minutes** / **Hours** buttons; in Hours you can type decimals such as 1.5, and a line shows "= … min total"). At least 1 minute. Set it to your planned observation window. Not used with *Scheduled recording*. |

## Scheduled recording (Setup tab)

With the **Scheduled recording** switch on (default off), the record button starts a run of
daily time windows. The phone records during each window and sleeps in between (screen dark,
camera off). Each window is saved as its own session. *Session length* is not used: each window
ends at its own end time.

| Setting | Default | What it does / when to change |
|---|---|---|
| **Scheduled recording** | `off` | Switches the time windows on. |
| **Window 1**, **Window 2**, … | one window, 06:00 to 10:00 | Each row has a start and an end time button (tap to change). With two or more windows, each row has a delete icon. |
| **Add window** | | Adds a window (up to 3). A new one starts at 15:00 to 20:00. |
| **Days to run** | `1` | The windows repeat every day for this many days (1 to 14). Day 1 is the day you start the run; windows already past at that moment are skipped. |

Windows must not overlap, and a window cannot cross midnight. Otherwise a warning says "Windows
must not overlap, and each must end after it starts (a window cannot cross midnight: split it in
two)." The gear on the camera screen is locked during a recording and while a scheduled run
sleeps, so the settings cannot be changed then.

## Speed, heat & battery (Power tab)

The Power tab starts with the heading **Trade detection speed against phone heat and battery**.
Its ⓘ says that a dark screen saves the most power: switch it off with the power button (the
recording goes on), or use the screen-off (moon) button on the camera screen.

| Setting | Default | What it does / when to change |
|---|---|---|
| **Screen off by itself after** | `0` (never) | During a recording the screen stays on until this many minutes (0 to 10) after the last touch; then the black power-save screen comes up and the phone's own screen timeout switches it off. Recording goes on. `0` keeps the screen on for the whole recording. 3 minutes suits unattended runs. |
| **Stop at battery level** | `15 %` | On the phone's own battery, the recording stops cleanly at this level instead of the phone dying mid-file. A power bank counts as plugged in. `0` = never; range 0 to 50. |
| **Keep free storage** | `200 MB` | The recording stops cleanly when free storage drops below this many megabytes (50 to 5000). A recording also does not start while free storage is already below it. |
| **Max detector rate** | `0` (same as the camera) | The most camera frames per second the detector may analyse (the **detector rate**, also called inference FPS, not the frame rate of the camera picture). A ceiling, not a promise: the phone and model may be slower. `0` means the same rate as the camera, so the detector follows when you choose another camera rate; a line under the box shows that rate. Or type 5 to 30 FPS: the detector can run at any rate up to the camera's by skipping frames. Shown in live detection mode only. |
| **Auto-adjust detector rate (reduces heat)** | `on` | Lowers the detector rate during the session to keep the phone cool and the rate steady, instead of overheating into a ~3 fps collapse. On: *Max detector rate* is the ceiling. Off: it is a fixed manual value. Leave on for field use. Outside live detection it is greyed out ("Live detection mode only; the detector does not run in this mode."). |
| **Min detector rate** | `3 FPS` | *(Advanced (detector rate tuning) fold)* The lowest rate auto-adjust will drop to, so the session stays usable even when hot (1 to 30). The fold shows only when auto-adjust is on. |
| **Target processor load** | `0.50` | *(Advanced (detector rate tuning) fold)* How busy (0.3 to 0.8) auto-adjust lets the processor stay on detection; 0.50 = about half the time. Lower = cooler and steadier but fewer FPS; higher = more FPS but more heat. The fold shows only when auto-adjust is on. |
| **Camera frame rate** | `15 FPS` | How many frames per second the camera *hardware* captures. The list shows only the rates this camera offers: each phone and each lens has its own, for example 12, 15 or 30 on one phone and 15, 20, 24 or 30 on another. *No limit* lets the phone choose (~30 FPS on most phones). The detector never runs faster than this. |
| **Use the GPU when it can run the model** | `on` | *(Detection tab → Advanced (engine & thresholds))* Prefer the GPU for the model. The app falls back to the CPU by itself if the GPU can't run the model. |

**Detector rate and camera rate.** The camera frame rate is different from the detector rate.
The detector rate only decides how many delivered frames the detector analyses; with no limit on
the camera, the sensor and image processor keep running at full rate the whole session.

**Why a list.** A camera runs only at the rates it offers, so a rate between two of them cannot
run. The list changes with the lens. A saved rate the lens does not offer (saved on another lens,
or by an older version of the app) shows as the rate that really runs: the highest one below it.
A lens without 15 FPS starts at its next rate up, which is cooler than *No limit*. The list appears
once the camera picture is on screen; until then only the saved rate is shown.

The detector never runs above the camera rate: the *Max detector rate* box keeps the value typed
and an amber note shows the rate used. With *No limit* on the camera, the *Max detector rate* may
be set up to 30 FPS.

*Min detector rate* is never above the detector rate used (an amber note says when
it is limited).

**GPU or CPU.** The app remembers models that crash the GPU. No speed check runs: the GPU is used
whenever it can load the model.

Only **Benchmark engines (GPU vs CPU)** (Detection tab →
**Advanced (engine & thresholds)**) compares the two. It takes up to about 30 s. The
**Engine benchmark** window then lists the time per picture ("ms per inference") for the GPU and
for CPU thread counts. "CPU 16-bit" means the CPU computes with shorter numbers, as the GPU does:
about twice as fast, and the boxes differ very slightly. Model files with 8-bit weights (for
example MegaDetector) cannot do this, so their rows say only "CPU". On some phones with a weak
GPU, the CPU with 4 or more threads is faster than the GPU.

Tap **Use** (followed by the fastest choice) to take it, then tap **Apply**
at the bottom of the Settings sheet. **Close** keeps your settings.

For a model that runs on a Snapdragon AI chip (NPU), the Detection tab shows instead: "This model
runs on the phone's AI chip (NPU), not on the GPU or CPU, so the benchmark and "CPU threads" do not
apply to it."

<details>
<summary>More about these settings: saved names, records, history</summary>

**Screen off by itself after** (round 293, idea from the sister app FaunaLapse). After the set
minutes the app stops holding the screen on, so the phone's own screen timeout switches it off.
Recording goes on with the screen off (round 292). A touch, or waking and unlocking the phone,
brings the screen back and restarts the count. `0` keeps the screen on, as before. 3 minutes gives
time to check the first photos. While the phone charges (a power bank too), Android's "Stay awake"
developer option keeps the screen on, black. Config key `screenOffAfterMin`.

**Stop at battery level** (round 296, idea from FaunaLapse). Applies only on the phone's own
battery (not plugged in, not charging). The log gets its end record and an open video is closed.
Checked on the temperature sampling cadence (every 10 s by default). A scheduled run ends as a
whole. The camera screen says why for a few seconds ("Recording stopped: battery at or below 15 %
…") and the summary's Setup tab has a *Stopped by itself* row. Record `guard_stop`
(`low_battery`). Config key `lowBatteryStopPercent`, 0 to 50.

**Keep free storage** (round 296). Round 319: the lowest value is 50 MB, so the phone and the
last files keep room. A saved 0 ("never" before) reads as 50; older sessions recorded with 0 show
"never" in their summary. Since round 319 a recording also does not start while free storage is
already below the value: the *Before you record* sheet shows a red "Not enough free storage" line,
and *Start* (or REC without the sheet) opens a *Not enough free storage* window. A scheduled window
is skipped (log line only, plus a camera-screen message). Video bursts already refuse to start a
new clip under 1 GB free. When the recording stops, the camera screen says why for a few seconds
("Recording stopped: less than 200 MB free storage …") and the summary's Setup tab has a *Stopped
by itself* row. Record `guard_stop` (`storage_low`). Config key `storageReserveMb`.

**Max detector rate.** It has a 30 FPS maximum, and `0` means the same as the camera (config key
`inferenceFps`). Round 313: the box keeps the value typed and an amber note shows the rate used;
before, the camera rate rewrote this value.

**Auto-adjust detector rate:** config key `autoThrottle`. **Min detector rate:** config key
`minInferenceFps`. **Target processor load:** config key `throttleDutyTarget`.

**Camera frame rate** (round 82, config key `cameraFpsCap`, `0` = no limit). The Max detector rate
keeps its own value and shows the rate used (round 313). A lower rate also delays high-res photos (~0.4 s content lag at 15 FPS vs
~0.17 s uncapped on the test phone, round 110); the `_live.jpg` companion covers the trigger
moment either way.

</details>

## Motion gate (opt-in; Power tab)

The motion gate lets the detector **sleep** while nothing moves in the ROI. So the phone stays
cool during the (usually long) empty-flower stretches of a field session. It is **off by
default** until it is validated against always-on recall (how many animals are found when the
detector never sleeps).

A cheap brightness comparison against a slowly learned background does the watching (native
side, under ~1 ms per frame).

The sensitivity settings sit in a **Gate sensitivity** fold under the switch. The fold shows
only while the gate is on, and never in time-lapse mode. In motion-trigger mode (where they decide
what causes a photo) the fold opens by itself; in live detection mode it starts collapsed.

In motion-trigger mode the switch is locked on ("Locked on: the motion capture trigger (Setup
tab) needs it."). In time-lapse mode it is shown off and cannot be changed ("Not used in
time-lapse mode.").

| Setting | Default (range) | What it does / when to change |
|---|---|---|
| **Motion gate (experimental): sleep while the flower is empty** | `off` | Master switch. Turn on for long sessions on a **mounted** phone (handheld shake keeps it awake). |
| **Pixel sensitivity** | `25` (5–100) | How much a pixel's brightness (0–255) must change to count as "moved". Lower = more sensitive (fewer missed animals, but petal shadows can wake it); higher = stricter. |
| **Trigger area** | `0.5 %` (0.05–20 %) | Share of the ROI that must change in one frame to wake the detector. Kept small because an insect covers little of the ROI. |
| **Wake duration after motion** | `3.0 s` (0.5–60 s) | How long the detector keeps running after the last motion or detection. Longer = fewer missed animals, but saves less heat. In **motion-trigger mode**: how long photos keep being taken after the last motion. |
| **Motion grid resolution** | `48` (16–160) | How many cells per side the ROI is shrunk to for the motion check. Raise it (e.g. 96–128) when insects are small relative to the ROI box; costs slightly more CPU. |
| **Idle check rate (frames/s)** | `5` (1–30) | How many frames per second are inspected *while the gate is asleep*. Higher = faster wake-up but a warmer idle phone. An arriving insect is noticed within ~1/this seconds. |

<details>
<summary>More about the motion gate: saved names and details</summary>

- **Pixel sensitivity:** config key `motionGatePixelDelta`.
- **Trigger area:** config key `motionGateAreaFraction`, stored as a fraction (0.005 = 0.5 %).
- **Wake duration after motion:** a still insect keeps being re-detected, extending the window.
  In motion-trigger mode photos stop when the gate goes back to sleep. Config key
  `motionGateWakeSeconds`.
- **Motion grid resolution:** config key `motionGateGridSize`.
- **Idle check rate:** while the gate sleeps, the "Camera" line of the info panel shows about
  this number; that is normal. Config key `motionGateIdleFps`.

</details>

## Tracking (Detection tab)

Tracking links each insect's detections across frames into one track ID with a stable ID. Two
algorithms are available. They can give a different number of track IDs for the same scene, so
compare only sessions that used the same algorithm.

| Setting | Default | What it does / when to change |
|---|---|---|
| **Tracking algorithm** | `ByteTrack` | *(inside the **Advanced (ByteTrack tuning)** fold)* How detections are linked frame to frame: **ByteTrack** ([Zhang et al. 2022](https://doi.org/10.1007/978-3-031-20047-2_1)) or **C-BIoU** ([Yang et al. 2023](https://doi.org/10.1109/WACV56688.2023.00478)). Both are FaunaPulse's own simplified versions; compare them on your own recordings (see *Log raw detections*). |
| **Occlusion tolerance** | `3.0 s` | How long a track survives while the insect is hidden (e.g. behind a petal) before its ID is dropped. Too low splits one track ID into several IDs; too high can merge separate track IDs. 3 s was tuned for bees. |
| **Minimum track length** | `0.2 s` | How long an insect must be detected without a break before it counts as a confirmed track ID (anything briefer is treated as noise). Lower counts more brief touchdowns (and more false blips); higher counts only clear landings. At least 2 detections in a row are always needed. |

The seconds-based settings are converted to frames against the live frame rate as it varies
during the session. The minimum track length directly affects the visitation rate for brief
touchdowns.

**Advanced (ByteTrack tuning)** fold (named **Advanced (C-BIoU tuning)** when C-BIoU is chosen; only the selected algorithm's settings are shown):

| Setting (algorithm) | Default | What it does |
|---|---|---|
| **Match overlap (IoU)** (ByteTrack) | `0.1` | Overlap required to treat a detection as the same insect. Lower tolerates faster motion. |
| **Low-score association** (ByteTrack) | `0.1` | Looser second test that lets faint detections keep an existing ID. |
| **New-track confidence** (both) | `0.5` | Score at or above which a detection may *start* a new track ID; fainter ones only continue a track ID that a stronger box started. Keep it at least 0.10 above Confidence (amber note otherwise). Range 0.05 to 0.95. |
| **Velocity smoothing** (ByteTrack) | `0.5` | How much the motion prediction trusts the latest movement. Low = "assume it barely moved". |
| **Search margin, pass 1** (C-BIoU) | `0.30` | Boxes are enlarged by this fraction of their own size before the overlap test. Bigger tolerates faster movement but risks mixing close neighbours. |
| **Search margin, pass 2** (C-BIoU) | `0.50` | A wider second matching round for whatever pass 1 missed: catches big jumps between frames. Never narrower than pass 1: a smaller value is used as pass 1 (amber note). |
| **Log raw detections (evaluation)** (both) | `off` | Evaluation aid: writes the detector's boxes before tracking, for every frame, into the session file, so it can be replayed through either tracker offline. Adds ~1–2 MB/h. |

A **Reset tracking to defaults** button in Advanced restores every setting in this section
(keeping the algorithm choice).

These controls (the algorithm, *New-track confidence* and the fine-tuning) are shared with the
Track IDs card of *Find animals in videos* (below), which stores its own values: a change on one
never changes the other.

<details>
<summary>More about tracking: the two algorithms, the replay test, history</summary>

**Tracking algorithm.** Two algorithms since round 105; inside the Advanced fold since round 159
(comparing trackers is a research task). **ByteTrack** predicts where each insect went and matches
by box overlap; **C-BIoU** enlarges the boxes before comparing them. Both are FaunaPulse's own
simplified versions of these methods. Compare them on your own recordings with the replay harness
(see *Log raw detections*) rather than trusting labels.

**Log raw detections.** Replay command:
`flutter test test/fauna_pulse/tracker_replay_test.dart --dart-define=REPLAY_SESSION=…/session.jsonl`.

**Minimum track length.** A track starts on its first box and is confirmed on a later match, so
1 has always worked like 2 (round 313 shows the number really used).

**New-track confidence.** Called "High-score threshold" before round 247. The band of faint boxes
below it is the idea of ByteTrack. Round 313: 0.05 to 0.95 and never raised by Confidence
(before, it was kept 0.10 above Confidence by force and raised for good whenever Confidence went
up, also by a half-typed number). Used by live detection and by *Find animals in photos*; since
round 308 videos have their own value (Video analysis, below).

**Search margin, pass 2.** Round 313 keeps each value as typed instead of raising pass 2 with
pass 1.

**Ground-truth frames.** The round-107 **Ground-truth frames** toggle that used to live here is
now **Reference photos** on the Setup tab (see "Region of Interest & photos"), on by default
since round 152.

**Shared with videos:** round 308.

</details>

## Camera stream & lens (Photos tab)

Only the stream is on the Photos tab. **Lens** and **Focus** are set on the camera screen, not in
the Settings sheet; they are listed here because they decide the photo size too.

The stream choice sits in the **Advanced (camera stream)** fold. On "Auto" it simply follows
*Saved photo side*, so most users never open it. The camera frame rate cap moved to the Power tab
(it is a heat control, see above).

| Setting | Default | What it does / when to change |
|---|---|---|
| **Live stream resolution (short × long)** | `Auto` | The video resolution the detector analyses (4:3). It limits how large a *fast* ROI crop can be; it does **not** affect detection accuracy. On a heat-limited phone pick a small size by hand. |
| **Lens** | `1.0` (main wide) | *(camera screen: the lens button right of the record button, showing "1×", "0.5×", ...)* Each tap switches to the next rear lens. Locked while recording ("Stop recording to switch lens") and on phones with one usable lens. Which rear lens, by zoom factor: 1.0 = main wide, 0.5 = ultra-wide, 2.0/3.0 = telephoto. Use a telephoto or zoom lens to reach the target photo size on a small flower. |
| **Focus** | manual (close-up preset, ~13 cm) | *(camera screen: focus button with the Far–Near slider)* Focus is **always manual**. Each time the camera screen opens, focus is set for a subject ~13 cm from the lens. Check sharpness and adjust the Far–Near slider. |

**Camera & lens info (advanced).** A closed fold at the end of the Photos tab lists which
rear and front lenses this phone lets apps use, and for each one whether "Detector can use it".

Many phones (for example Xiaomi) keep the ultra-wide, macro and telephoto lenses for their own
camera app, so these lenses do not appear even though you can see them on the back of the phone.
That is a limit of the phone, not of FaunaPulse. When apps can use only one rear camera, the
lens-switch button is off.

**Live stream resolution.** The phone delivers the nearest size it supports. The short side caps how
large a *fast* (no-stall) ROI crop can be. Detection accuracy does not change because every frame
is shrunk to the model's input size anyway.

**Auto** chooses the smallest size the phone supports
whose short side is at least the *Saved photo side* (1024 px by default). If no size reaches it,
Auto picks the largest size the phone streams.

The menu item says which: "Auto (matches Saved
photo side, ... px)" or "Auto (largest this phone streams, below ... px)". So fast crops can reach
the *Saved photo side*, and the
slow high-res path (≈0.4–0.8 s behind the trigger on the test phone) is needed less often. Sizes
above the phone's real analysis ceiling are never picked by Auto.

Trade-off: larger streams cost
more processing per frame, so more heat and battery. A size you pick by hand is never overridden.

**Lens.** The app snaps to the available lens closest to this value; single-lens phones just stay
on their one lens.

**Focus.** Autofocus was removed entirely: on a mounted phone it drifts onto the background and
silently changes what is sharp mid-session. The ~13 cm preset is the middle of the typical
10–20 cm flower distance, clamped to what the lens can reach.

An amber dot on the focus button
reminds you to check sharpness; it goes away once you adjust the Far–Near slider. Focus then stays
exactly where you set it. Adjusting it during a recording is allowed and logged (`focus_change`).

<details>
<summary>More about the stream and focus: history and logs</summary>

- **Stream resolution:** **Auto** came in round 109; it is the default until you pick a size.
- **Focus:** always manual since round 164. Lenses that report no manual-focus range (many
  ultra-wides) show no control and log `fixed`, as before. Logs from older versions may say
  `auto`: that mode no longer exists.

</details>

## Display & diagnostics (Setup tab → On-screen display fold)

| Setting | Default | What it does / when to change |
|---|---|---|
| **Show FPS** | `on` | Show the live frames-per-second number. |
| **Show detection boxes & track IDs** | `on` | Draw bounding boxes and track-ID labels. Turning it off removes the repaint of every frame for the lightest preview; detection and tracking still run. Live detection mode only: in the other modes it is off and greyed out (there are no detections to draw). |
| **Show on-screen info panel** | `on` | The top-left info panel (FPS, model, engine, stream, ROI size, temperature, track count). Off: only the ROI box and the recording controls remain. |
| **Flash ROI border when a photo is saved** | `on` | Briefly flash the ROI border when a photo saves, as a visual cue. Border only, at photo cadence: never affects FPS. |

Related settings in other places:

- **Show tips and notes** is in the home screen's **Menu** at the bottom left. It is an app-level
  preference, not a setting of one session. On: the setup tips and the "Before you record" sheet
  show at session start, and every note hidden with *Don't show again* comes back (the
  **Setting up a session** tips window, the slow-phone hint below, the position sentence after
  saving a crop, the **Import a FaunaLapse session** window).
  Off: all of them stay hidden.
- **The slow-phone hint**: in live detection, when the phone checks fewer than 5 pictures per
  second, a note at the top of the camera screen suggests time-lapse with "Save bursts as: Video"
  and *Find animals in videos* afterwards. It shows once per camera screen. *Don't show again*
  hides it for good, until *Show tips and notes* is turned on again. 5 per second is a fixed
  number, not a setting: it only decides when the note appears.
- **Square (1:1) export crops** (Photos tab → "Photo viewer", off by default) forces the crop-and-export box in
  the summary photo viewer to a square. The "1:1" chip next to the crop box toggles the same
  setting.
- **Add the position to exported crops** (Photos tab → "Photo viewer", on by default) writes the
  session position (GPS) into the EXIF block of crops saved or shared from the summary photo
  viewer, as a phone camera photo does. So iNaturalist and similar apps can place the record on a
  map. Off: the crop keeps only its time. The save and share message says when a crop carries the
  position; its *Don't show again* hides only that sentence, and the crops keep the position.
  Turn it off for sites that must stay private (rare species).

<details>
<summary>More about the display settings: history and the slow-phone test</summary>

- **Show FPS** moved from the Detection tab in round 159: it is a display toggle.
- **Show tips and notes** was named "Show setup tips at session start" until round 331.
- **The slow-phone hint** (round 278) is judged from the work per picture (preparing, detecting
  and sorting the boxes; the median of 30 pictures, or of 10 s of pictures on a very slow phone,
  after the first 15 s), not from the shown fps. So the frame-rate cap and the motion gate do not
  raise it. *Don't show again* is saved as the pref `faunapulse_hide_slow_phone_hint`.

</details>

## Graphs & logging cadence (Power tab → Diagnostic graph sampling fold)

The settings below sit in the **Diagnostic graph sampling (advanced)** fold of the Power tab.

Frame rate, battery temperature (with the phone's memory and the processor cores FaunaPulse
keeps busy, from the same reading) and battery power are always logged while recording. The
readings are taken for the live preview anyway, so logging them is free: roughly 2–3 MB per
8-hour session.

In the session summary they appear under the **Extra graphs (temperature, FPS, power, track ID timeline)** section (it also holds the heat level graph). It is collapsed at first, and the app remembers
whether you last left it open or closed. So the track ID
charts (the main result) stay front and centre.

A session whose videos were analysed, or that was identified, gets a choice above these graphs:
the phone **While recording**, **While the detector ran** or **While identification ran**. The
last two have their own interval, not the ones below: **Measure the phone every** for videos,
and a fixed 10 s for the identification.

| Setting | Default | What it does / when to change |
|---|---|---|
| **Frame-rate sample** | `5 s` (1–60 s) | How often the frame rate is logged for the FPS graph. |
| **Phone readings sample** | `10 s` (1–120 s) | How often the battery temperature, the memory in use and the processor cores FaunaPulse keeps busy are logged (one reading gives all three; heat and memory change slowly). |
| **Power sample** | `10 s` (1–120 s) | How often battery power and charge are logged for the energy graphs. |

<details>
<summary>History (sampling)</summary>

- **Phone readings sample:** called "Temperature sample" until round 346, when the memory and
  processor figures joined the same reading. The saved key (`thermalSampleSeconds`) is unchanged.

</details>

## Photo analysis (Analysis screen)

These settings live on the **Find animals in photos** screen, not on the Settings sheet. They
control how saved photos are examined again *after* a session, so they are not part of
`SessionConfig`. They are kept in the app preferences (`analysis_*`).

The screen shows only the session, the detection model and the main button (**Analyze N
photos**). The settings below sit in the closed fold **Advanced settings**. Its line names the values in use (for example "Confidence
0.25, IoU 0.70, small-insect tiling off").

| Setting | Default | What it does |
|---|---|---|
| **Confidence threshold** (Advanced) | `0.25` | Minimum score for a detection to count; the live camera's default. |
| **IoU threshold** (Advanced) | `0.7` | IoU = how much two boxes overlap (0 to 1). When two boxes overlap more than this, only the more confident box is kept, so one insect gets one box. Lower removes more overlapping boxes but can drop one of two insects sitting close together. 0.7 is the live camera's default. |

Saved names: *Confidence threshold* is saved as `analysis_confidence` and *IoU threshold* as
`analysis_iou`, when a run starts.

**Photo cleanup.** After a run, the screen shows a **Photo cleanup** part: how many analysed
files contain a detection, and how many would be kept or deleted.

| Setting or button | Default | What it does |
|---|---|---|
| **Keep time-window around a detection** | `2 s` | Photos within this time of a detection are kept too, so photos where the detector missed an insect that is still there are not deleted. Up to 60 minutes. Saved as `analysis_keep_gap`. |
| **Review photos before deleting** | | Opens the session's Photos tab, which marks the photos this cleanup would remove. |
| **Delete … files (…)…** | | Asks "Delete photos without detections?", then deletes for good the files with no detection and no detection nearby. The session log keeps its records. |

Also on this screen: **Re-analyze photos already done** (a checkbox for each run, deliberately
not saved). It shows once the session has analysed photos. It runs every photo again, so you can
try a different model or different tiling settings on a finished session; the button then reads
**Re-analyze N photos**. Only the newest result of each photo is kept (see
[DATA_GUIDE.md §6](DATA_GUIDE.md)).

<details>
<summary>History of this screen</summary>

Since round 273 the screen shows only the session, the detection model and Start, with the
settings in the closed **Advanced settings** fold.

</details>

### Small-insect tiling (SAHI), inside Advanced settings

Normally the whole photo is shrunk down to the model's input size before detection
("letterboxing"). A 1024 px photo fed to a 640 px model loses about 40% of its linear
resolution, and a tiny insect can shrink below detectability.

Tiling instead cuts the photo into overlapping tiles of roughly the model's own input size. The
detector runs once per tile at near-native pixel scale. The boxes of each tile are mapped back
into whole-photo coordinates, and duplicates are merged. An optional extra whole-photo pass
catches insects larger than one tile.

Tiling is slower: one inference per pass. The screen shows a live cost preview like "1024×1024 px
photos, 640 px tiles, 25% overlap → 2×2 tiles + whole photo = 5 passes ≈ 5× processing time". It is worth
trying when the model input is much smaller than your photos.

| Setting | Default | What it does / when to change |
|---|---|---|
| **Use tiled analysis** | `off` | Master switch. Off = each photo gets the single plain pass. |
| **Tile size** | `0 px` (auto) | Tile side in pixels: 0 or 128 to 2048. 0 = automatic: the selected model's own input size, so each tile is analysed at native model scale (the standard choice). Larger tiles = fewer passes but more downscaling per tile. |
| **Tile overlap** | `25 %` | How much neighbouring tiles share, so an insect sitting on a tile border appears whole in at least one tile. |
| **Also run the whole-photo pass** | `on` | Adds the plain letterboxed pass on top of the tiles: catches insects larger than one tile, at the cost of one extra inference. |
| **Duplicate-merge overlap** | `0.5` | The overlap at which two same-class boxes from different passes count as the *same* insect and merge into one (the higher-confidence box wins). Overlap is measured against the **smaller** box ("IoS"), so a partial box inside a bigger one merges away. |
| **Ignore tiny tile boxes** | `0 %` (off) | Drops tile detections whose box is *narrower* than this fraction of the photo side in either direction. It never removes whole-photo-pass boxes. Start low (~1–2%) and check the review boxes. |

A photo that fits inside one tile skips tiling entirely: only the whole-photo pass runs, and the
preview says so.

**Ignore tiny tile boxes** catches both background specks (tiny both ways) and the thin sliver
boxes tiling produces at tile borders (a partial insect cut by a tile edge is thin in one
direction but can be long in the other). Because it never removes whole-photo-pass boxes, it can
only trim what tiling added, never fall below a plain run. Careful: SAHI's whole purpose is
finding small insects, and a slender insect seen side-on also has a narrow side.

**Tuning it after the analysis.** This setting also works as a LIVE review filter. After an
analysis, moving the value re-derives the cleanup numbers (and the review screen's boxes, chips
and deletion marks) instantly from the recorded results, with no new analysis. That makes a
sensitivity analysis cheap: analyse once at 0% (every box stays recorded), then tune.

It can only
go as low as the filter the analysis itself ran with (an amber hint appears otherwise). Unlike the
filter during the analysis, it is size-only (boxes after the merge carry no tile or full-pass
origin). Executed deletions record the value in the `post_cleanup` record.

**Extra small boxes when tiling.** Two causes:

- partial insects at tile borders (small boxes *inside* the full-insect box): merged away by the
  smaller-box overlap above;
- fine background specks that each tile sees at near-native scale: trim them with "Ignore tiny
  tile boxes" and/or a higher confidence threshold.

Either way, treat the boxes as triage evidence ("this photo contains a pollinator"), not as tight
annotations. That matches the feature's stated goal: recall for keep or delete triage.

<details>
<summary>How the tiling is implemented, and its history</summary>

This is FaunaPulse's own pure-Dart implementation of the "Slicing Aided Hyper Inference" idea
(`lib/fauna_pulse/postprocess/sahi.dart`). No external SAHI library is used (none exists for
Android/Flutter). For the concept, see the [original SAHI project](https://github.com/obss/sahi)
and [Ultralytics' SAHI guide](https://docs.ultralytics.com/guides/sahi-tiled-inference/). Those
describe *their* implementations. Since round 141 FaunaPulse merges duplicates by the same
criterion they use (intersection-over-smaller-box); rounds 139–140 used plain IoU.

- **Use tiled analysis:** off = the single plain pass, exactly as before round 139.
- **Tile size:** round 313 (before, typing 1024 stored a 1 px tile at the first keystroke).
- **Duplicate-merge overlap:** IoS since round 141. Rounds 139–140 measured plain IoU, which kept
  boxes contained in a bigger box as extra small boxes.
- **Ignore tiny tile boxes:** round 141, fixed in 143; the live review filter came in round 179.
- **Extra small boxes when tiling:** mostly fixed in round 141 (the smaller-box overlap).

</details>

### Also identify them

A switch under the detection model. While it is on, the identification model and the name list
show under it. One tap on the main button then finds the animals and their track IDs (when the photos are close
enough in time), names them and opens the results.

After the detector, the screen opens *Identify organisms*, which starts by itself and ends on the
results. Its settings (Identify organisms → **Advanced settings**, below) apply. The model and list are the
ones *Identify organisms* remembers, so a change on either screen shows on the other.

The switch is on the first time when the phone has an identification model with a name list for
it. With every photo analysed already, the main button reads **Identify the animals found**. Not offered for
live detection sessions: their track IDs are named from the session's ⋮ menu → *Identify
organisms*.

<details>
<summary>Saved names and history</summary>

Round 274. The model and list are saved as `identify_model` and `identify_pack`. The switch is
saved as `find_also_identify` (shared by both Find screens).

</details>

### Track IDs

Shown once the photos of a motion or time-lapse session are analysed. *Find track IDs* follows
each insect from photo to photo, as the live camera does with live detection on. It writes
`post_tracks.jsonl` and `track_ids.csv`; the summary, dashboard and identification then use those
track IDs.

It is only offered when the session's photo step is at most 0.5 s. For sparser photos the section
says that an insect can move too far between two photos to be followed. It runs by itself after
every finished run (as on *Find animals in videos*); *Find track IDs again* repeats it with other
settings. The two settings sit in the closed fold **Track ID settings**.

| Setting | Default (range) | What it does |
|---|---|---|
| **Occlusion tolerance** | `3 s` (0.2–10) | How long an insect can be missing (hidden, or missed in a photo) and keep its track ID. Same default as the live camera. Keep it well above the photo step (an amber note says when it is shorter than two photo steps). |
| **Minimum track length** | `0.2 s` (0–2) | How long an insect must be seen before it counts as a track ID, in photos in a row (at least 2). Same default as the live camera. |

The tracker itself (ByteTrack or C-BIoU, New-track confidence, fine-tuning) is the camera's:
**Settings → Detection → Tracking → Advanced (ByteTrack tuning)** (or *C-BIoU tuning*), editable
while the Capture trigger is Live detection. The fold names it ("ByteTrack, New-track
confidence 0.50 (camera)"). It warns when New-track confidence is not 0.10 above this screen's
Confidence, and a change of it shows "Settings changed".

<details>
<summary>Saved names, records and history</summary>

- Track IDs for photo sessions: round 237. Since round 273 *Find track IDs* runs by itself after
  every finished run.
- **Occlusion tolerance:** saved as `analysis_occlusion_s`, logged as `occlusion_seconds` in
  `post_track_start`, and shown on the summary's Setup tab.
- **Minimum track length:** saved as `analysis_min_visit_s`, logged as `min_hits_seconds` in
  `post_track_start`, and shown on the Setup tab.
- Since round 313 the fold names the camera's tracker, warns about New-track confidence and shows
  "Settings changed".

</details>

## Video analysis (Find animals in videos screen)

**Getting videos in.** Videos come in through **Import videos…**: a button on the home screen, also
on the Find animals in videos screen (there it reads **Import other videos…** once a session with
videos exists) and in the Sessions screen's ⋮ menu.

The button opens Android's photo picker, whose ⋮ menu browses the phone's folders. The import asks only for a session name
and when filming started (both logged, see [DATA_GUIDE.md §9](DATA_GUIDE.md)). "Find animals in
videos" then finds the insects in them.

**Settings belong to the analysis.** As for the photo analysis, these settings belong to the
analysis, not to a recording. They are stored on the phone. A session's results always come from
one set of settings: after a change the screen offers **Analyze again with these settings**.

It first asks **Replace the earlier results?**, names the changed settings and warns when deleted
clips lose their boxes and track IDs; **Replace and start** replaces the earlier results. The
session summary's Setup tab lists the settings (Model & detection, Tracking), read back from the last run's records.

**Where the settings are.** The screen shows the session, the detection model, the proposed area
and the main button (**Analyze N clips**). Every number to tune sits on its own screen, **Detection, track ID and identification
settings**. Its entry under *Also identify them* names the values in use, one line per card. It
can be opened before the first run and is greyed while a run goes on. It has three cards:

- the **Detection** card: the rows marked (Detection) below;
- the **Track IDs** card: the rows marked (Track IDs) below;
- the **Identification** card: the settings of *Identify organisms* (Identification, below).

Everything there is saved as it changes. The tracker settings are the videos' own: they start
from the app's defaults, not from the camera's values, and a change never reaches the camera.

| Setting | Default (range) | What it does / when to change |
|---|---|---|
| **Detection model** | the last one used (first in the list the first time) | Any detection model on the Download & import models screen (home screen Menu, or *Download & import models…* under the list). There is no real-time limit here, so a bigger model than the live one can be used; it only takes longer. |
| **Confidence threshold** (Detection) | `0.25` (0.05–0.95) | Minimum score for a box to count; the live camera's default. Lower finds more faint boxes. A change needs a new analysis. |
| **Frames analyzed per second** (Detection) | `5` (1–30) | How many pictures of each second of the video the detector looks at; the pictures in between are skipped. More follows fast flying insects better but takes longer. |
| **Area to analyze** | the largest square in the middle, proposed | The square the detector looks at, shown on the first frame to accept or change. Insects outside it are ignored. Kept per session. |
| **IoU threshold** (Detection) | `0.7` (0.05–0.95) | IoU = how much two boxes overlap (0 to 1). When two boxes overlap more than this, only the more confident box is kept, so one insect gets one box. Lower removes more overlapping boxes but can drop one of two insects sitting close together. 0.7 is the live camera's default. |
| **Pause the analysis above** (Detection) | `43 °C` (35–45) | The run pauses at this battery temperature and resumes 3 °C lower. A hot battery ages faster, and a hot phone slows itself down anyway. The Identification card has its own value. |
| **Measure the phone every** (Detection) | `10 s` (5–60) | How often the battery temperature, the memory in use, the processor cores FaunaPulse keeps busy, the power use and the analysis speed are written down during a run, also while it pauses to cool down. Shorter shows quick changes but gives a longer file. |
| **Occlusion tolerance** (Track IDs) | `3 s` (0.2–10) | How long an insect can vanish (for example behind a petal) and keep its track ID. Longer: fewer track IDs split in two; too long: two visitors can merge into one. |
| **Minimum track length** (Track IDs) | `1 s` (0–2) | How long an insect must be seen before it counts as a track ID; shorter sightings are dropped as noise. |
| **Tracking algorithm** (Track IDs) | `ByteTrack` | ByteTrack or C-BIoU, as on the camera (Tracking, above) but the videos' own choice. |
| **New-track confidence** (Track IDs) | `0.50` (0.05–0.95) | A box at or above this may start a new track ID; weaker boxes, down to the confidence the videos were analysed at, only continue one. Each algorithm has its own value. |
| **Fine-tuning (ByteTrack)** or **Fine-tuning (C-BIoU)** (Track IDs, folded) | see below | The selected algorithm's own values, with the camera's texts (Tracking, above). |
| **Keep frames of each track ID** (Track IDs) | on | After *Find track IDs*, saves pictures of every track ID from the clips into `roi_frames/`, like the photos the live camera takes, for looking at the visitors and for *Identify organisms*. |
| **Keep a frame every** (Track IDs) | `1 s` (0.1–10) | The first frame of a track ID is always kept, then one after each such step, as the live camera's photo step. Shorter catches more poses but fills more storage. |
| **For up to** (Track IDs) | `10 s` (1–300) | How long into a track ID frames keep being saved, as the live camera's photo duration; a long track ID gives no more after this. A track ID gives up to about 1 + this ÷ the step frames. |
| **Also identify them** | on the first time when an identification model has a name list; then as left | Under *Area to analyze*. One tap on the main button finds the animals, their track IDs and kept frames, then identifies them. Needs *Keep frames of each track ID* on. |

**Fine-tuning defaults.** ByteTrack: *Match overlap (IoU)* `0.10`, *Low-score association*
`0.10`, *Velocity smoothing* `0.50`. C-BIoU: *Search margin, pass 1* `0.30`, *pass 2* `0.50`.
*Reset tracking to defaults* there puts both algorithms' values, the occlusion tolerance and the
minimum track length back to their defaults (the algorithm choice and the kept frames stay). A
changed value makes the main button read *Find track IDs again with these settings*.

**Confidence and New-track confidence.** Faint boxes can keep an insect's track ID while it is
half-hidden, and *New-track confidence* decides which boxes may start one.

A change of the
confidence needs a new analysis; a change of New-track confidence needs only the track IDs found
again (seconds). To try settings, analyse once with a low confidence, then try New-track values.

After the videos were deleted, a note says these values apply to other sessions only, and the
screen shows the values the boxes were found with.

**New-track confidence, more.** It is never raised by the confidence. An amber note says when it
is less than 0.10 above the confidence the saved boxes were found at (the confidence threshold
before the first analysis). If *All boxes* on the Video tab shows an insect that never gets a
track ID, lower it and find the track IDs again (no new analysis).

<details>
<summary>More about each video setting (frame rate, area, measuring, track IDs, kept frames, identification)</summary>

**Frames analyzed per second.** 5 = one picture every 0.2 s of video: enough for insects
that stay on a flower for a second or more. A run takes less than half the time 15 would (not a
third: the phone still decodes every picture). More pictures per second means fewer insects
missed or counted twice; 15 is what the live camera analyses. The rate counts seconds of the
video, not of the run: a slow or warm phone takes longer, it never looks at fewer pictures. Asking
for more than the video has changes nothing (most phone videos have 30). To measure which rate is
enough for your videos: [VIDEO_ANALYSIS.md §5](VIDEO_ANALYSIS.md#5-which-frame-rate-is-enough-the-sweep).

**Area to analyze.** The detector looks at a square picture, as with the camera's square.
A session never analysed proposes the largest square in the middle of its first clip, its side
rounded down to a multiple of 32 px by the same rule as the camera's largest square (640×480 →
480 × 480, 1920×1080 → 1056 × 1056). It is shown on the first frame with the rest darker. A video
that is already square, such as the clips the app records of the camera's square or a copy
cropped to a square, starts on the whole picture. Under *Area to analyze* you choose
**Whole picture** or **A square**; *Whole picture* includes the edges.

*Change…* (or a tap on the picture) opens the square editor. The clip plays muted and looping at
4× (speeds up to 10×; another clip of the same picture size can be chosen), so camera or flower
movement over the whole video shows while the square is dragged, pinched or resized with the
slider. Its side is snapped to a multiple of 32 video pixels, as on the live camera. Small insects
are found more easily because the square is shrunk less before detection. The area is kept per
session, not as an app setting: reopening a session takes the area of its last run (square or
whole picture), so *Continue* works without placing it again.

**Measure the phone every.** The readings make the summary's video graphs and
`phone_during_analysis.csv` (DATA_GUIDE §9). 10 s is the live camera's temperature and power
interval.

**Occlusion tolerance.** It is used when *Find track IDs* follows an insect from frame to
frame. Keep it well above the time between two analysed frames: below two of them an amber note
says what it means. Same default as the live camera.

**Minimum track length.** The detector must find the insect in this many analysed frames in
a row, shown under the field (1 s = 5 detections at 5 frames per second). An insect it sees only
on and off is dropped too when the value is high. At least 2 detections in a row are always
needed, so the live camera's 0.2 s would be the minimum of 2 at 5 frames per second. Seconds
become frames at the rate the video was analysed at, fixed for the whole run.

**Keep frames of each track ID.** One picture is about as big as a live photo (the analysed
area at full size). Off: *Find track IDs* keeps none and removes the ones kept before (a note says
how many), unless their video is gone. Shown on the Setup tab as *Kept frames per track ID*.

**Also identify them.** After the frames are kept, the screen opens *Identify organisms*,
which starts by itself and ends on the results. The identification model and name list under the
switch are the ones *Identify organisms* remembers. The switch needs *Keep frames of each track
ID* because identification names the saved frames; otherwise the switch is greyed with the
reason. With every clip analysed already (or the videos deleted) and the track IDs up to date, the
main button reads *Identify the animals found*. Not offered for live detection sessions (their
track IDs are named from the session's ⋮ menu). The Identification card of the settings screen
holds the settings of *Identify organisms* (Identification, below; the same values), greyed with
the reason while the automatic identification will not run.

</details>

**Keep FaunaPulse on the screen.** While *Also identify them* is on, a line under it asks to keep
FaunaPulse on the screen until the identification ends. It needs a lot of memory: if you switch
to another app, it may wait, or Android may stop it.

With the app in the background, a model that
does not fit in the phone's free memory waits for the app to be opened (notification "Animals
found"). This also works after Android has closed the app meanwhile (once, within 24 hours; see
[IDENTIFICATION.md](IDENTIFICATION.md), step 3).

<details>
<summary>Saved names, records and history (video analysis)</summary>

**History of the screen.** Video analysis came in round 227. *Import videos…* became a home
screen button in round 277. Since round 229 the summary's Setup tab lists the settings. Since
round 273 the screen shows the session, the detection model, the proposed area and Start.
Since round 308 every number to tune sits on the **Detection, track ID and identification
settings** screen, and everything there is saved as it changes (before round 308 the three sliders
were saved only at Start).

**Saved names.** The settings are stored on the phone as `video_analysis_*` and echoed into the
`settings` of every `video_run_start` record. The pause temperature is logged as
`thermal_limit_c`.

- **Frames analyzed per second:** default 15 before round 254.
- **Area to analyze:** proposed square since round 273; whole picture before.
- **Pause the analysis above:** called "Pause above battery temperature" until round 313; default
  40 °C before round 252.
- **Measure the phone every** (round 232): saved as `video_analysis_sample_s`, logged as
  `sample_s` in `video_run_start` (not part of `settings`, so a change never makes the run start
  over), and shown on the Setup tab.
- **Occlusion tolerance** (round 228): saved as `video_analysis_occlusion_s` and logged in
  `post_track_start`. Round 313: a value at or below the time between two analysed frames (0.2 s
  at 5 frames per second) gave 0 track IDs or one per second, because the tracker took every frame
  gap for a pause; fixed.
- **Minimum track length** (round 228; 0.2 s until round 256): saved as
  `video_analysis_min_visit_s` and logged in `post_track_start`. Seconds have become frames at a
  fixed rate since round 256; before, the rate was re-estimated every second, and 0.5 s at 5
  frames per second flipped between 2 and 3 detections.
- **Tracking algorithm** (round 308): saved as `video_analysis_tracker`; logged as
  `tracker.algorithm` in `post_track_start`.
- **New-track confidence** (round 308): never raised by the confidence since round 313. Before,
  it was kept 0.10 above the Detection card's confidence by force (reported in testing as "it
  jumps back to 0.60").
- **Fine-tuning** (round 308): saved as JSON in `video_analysis_bytetrack` and
  `video_analysis_cbiou`; logged in `post_track_start.tracker` with the frame budgets derived from
  the seconds.
- **Keep frames of each track ID** (round 234): saved as `video_analysis_keep_frames`; logged as
  `keep_frames` in `post_track_start` (null when off).
- **Keep a frame every** (round 234): saved as `video_analysis_keep_step_s`; logged as
  `keep_frames.step_seconds`.
- **For up to** (round 234): saved as `video_analysis_keep_duration_s`; logged as
  `keep_frames.duration_seconds`.
- **Also identify them** (round 274): saved as `find_also_identify`, shared with the photo screen.

</details>

## Identification (Identify organisms screen → Advanced settings)

These settings belong to the identification job, not to a recording. They are stored on the
phone (`identify_*`) and echoed into the `identify_start` record of every run. The same settings
(one set of values) are also on the Identification card of *Find animals in videos* → *Detection,
track ID and identification settings*.

When *Also identify them* on a Find screen opens this screen, it starts by itself once the crops
are counted (not with 0 crops), and it opens the results when the run ends.

| Setting | Default | Meaning |
|---|---|---|
| **Use the GPU when it can run the model** | on | Runs the model on the phone's graphics processor (GPU), on tested phones about ten times faster than the main processor (CPU). The first time, the app checks on a test picture that the GPU gives the same answers as the CPU; if not, or if the GPU cannot run the model, the CPU is used and the app says why. "Test speed" shows what this phone does. Off = CPU only. |
| **CPU threads (0 = automatic)** | 0 (automatic) | Processor cores the CPU engine may use. 0 = automatic = 2. 4 keeps twice the cores busy, so the thermal pause comes sooner. Measure with "Test speed". |
| **Square crops** | on | The model always looks at a square picture. On: the box is widened to a square, so the insect keeps its shape and some flower shows around it. Off: only the box (plus the margin) is cut out and stretched to a square, so a long, thin insect looks squeezed. After a change, the next run asks whether to cut the stored crops again. |
| **Crop margin** | 0 | Extra border added on every side of the detector box, as a share of the box's longer side (0.05 = 5 % of it). 0 = the box itself (made square when *Square crops* is on). Raise it if legs or antennae look cut off. |
| **Smallest box to identify** | 48 px | Boxes whose longer side is smaller (in photo pixels) are skipped as too small. |
| **Crops per track ID (0 = all)** | 10 | Keeps the largest boxes of a track ID when a track ID has more photos than this. |
| **Ignore crops far less sure than the best (factor)** | 10 | A crop whose top-1 probability is below the surest crop's divided by this factor is left out of the pooled answer (still listed, marked "left out"); 1 = every crop counts. FaunaPulse estimate, not tested on pollinator data. |
| **Confidence needed to call a rank identified** | 0.60 | The deepest rank whose Conf. reaches this value becomes the identification; deeper ranks are still listed as suggestions. 0.7 to 0.8 are common thresholds in the camera-trap literature, none tested for pollinators. |
| **"No organism" threshold** | 0.50 | Summed probability of the "none of these" entries above which a track ID is reported as no organism. |
| **Pause above battery temperature** | 43 °C | The run pauses at this battery temperature and resumes 3 °C lower. |
| **Merge consecutive track IDs** | off | Joins a track ID to the previous one when the gap, a compatible identification, the appearance similarity and the box-size guard all pass; the union is identified again. |
| **Largest gap between joined track IDs** | 3 s | End of one track ID to the start of the next (same as the tracker's occlusion buffer). |
| **Appearance similarity needed** | 0.85 | Cosine similarity of the two track IDs' combined image embeddings (1 = identical). |
| **Box size may differ by up to** | 50 % | Mean box side relative to the ROI, as a percentage of the larger one; 100 % disables the guard. |
| **Short: duration below** | 2 s | Suspect flag `short` when the duration is below this OR the detections are below the next row. |
| **Short: detections below** | 3 | Detector frames the track ID appeared in, from the first sighting (this includes the frames before the tracker confirmed it as a track ID). |
| **Weak: detector confidence below** | 0.20 | `low_det` when the mean live-detector confidence is below this (same default as the `insect-detect-post` software's track filter, Sittinger 2026; DOI below the table). |
| **Weak: order confidence below** | 0.50 | `weak_id` when the track ID's confidence (Conf.) at ORDER rank is below this. |
| **CSV file only: rank of the "pred" columns** | family | Changes nothing in the app (the results on screen show every rank). Which rank fills the "pred" columns of `tracks_<pack>.csv`. |

The `insect-detect-post` software: Sittinger 2026, doi:10.5281/zenodo.21822140.

**Suspect flags.** `suspect` = short AND (low_det OR weak_id OR no organism). These are flags
only: nothing is deleted. The duration runs from the tracker's first sighting to its last frame,
as in `track_ids.csv`.

**Crop margin and box size.** With margin 0 the box is made square on its longer side, as in the
Insect Detect pipeline (`make_bbox_square()`, Sittinger), so the model sees as little flower or
background as possible; the square already adds some along the shorter side. The model sees
224 px, so a 48 px box is already enlarged more than 4 times. On the default 1024 px photos it is
an insect about 5 % of the photo side.

**Conf.** Conf. is the pooled answer: the crops' embeddings averaged with certainty weights, then
scored once.

**CSV "pred" columns.** The rank chosen fills `pred`, `pred_prob_weighted`, `pred_prob_mean` and
`pred_imgs` in `tracks_<pack>.csv`. The columns are named as in insect-detect-post, so files of
both tools can be compared. The other ranks are in their own columns anyway.

**Model and name list** are chosen on the same screen. They are added and deleted on the
Download & import models screen (the link under the lists, or the home screen's Menu), which
copies the files into the app's private storage. `docs/IDENTIFICATION.md` explains where the files
come from and how the answer is computed.

<details>
<summary>Measurements, earlier defaults and history (identification)</summary>

- Identification settings: round 208. Shared with the videos' Identification card since round
  308. Automatic start from *Also identify them*: round 274.
- **Use the GPU when it can run the model:** CPU fallback with the reason on screen since r211.
- **CPU threads:** 0 = automatic = 2 since round 226 (LiteRT's own default is 1). BioCLIP-2 on the
  Xiaomi (round 250, phone cool): 4.6 to 5.4 s per crop on 1 thread, 2.6 to 3.0 s on 2, 1.9 to
  2.0 s on 4, 2.0 s on 8 (0.26 s on the GPU).
- **Crop margin:** 0.05 in round 255, 0.15 before.
- **Ignore crops far less sure than the best:** r219.
- **Confidence needed to call a rank identified:** 0.80 until round 216. Conf. is the pooled
  answer of round 219.
- **Pause above battery temperature:** 40 °C before round 252.
- **Merge consecutive track IDs:** r210/212.
- **Short: duration below:** suspect flags since r212. The duration is measured as in
  `track_ids.csv` since round 305.
- **Short: detections below:** since round 305 this includes the frames before the tracker
  confirmed it as a track ID.
- **CSV file only: rank of the "pred" columns:** label before round 247: "Rank for the CSV "pred"
  columns".

</details>

---

## Note for developers

By project rule, every new tunable ships with a Settings control here, persistence in
`SessionConfig` (JSON round-trip + test), and a row in the end-of-session summary, in the same
round it is introduced. See [CONTRIBUTING.md](CONTRIBUTING.md).
