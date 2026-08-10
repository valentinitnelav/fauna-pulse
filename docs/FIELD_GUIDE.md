# Field Guide — Running a FaunaPulse Session

**Who this is for:** the researcher operating the app in the field. It assumes
the app is already installed (see [INSTALL.md](INSTALL.md)) and covers the
actual session workflow, what the live screen is telling you, and what to do
when something looks wrong.

For *why* a small on-screen box still saves a sharp photo, see
[HOW_PHOTO_RESOLUTION_WORKS.md](HOW_PHOTO_RESOLUTION_WORKS.md). For what each
setting does, see [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md). For turning
the saved log into visitation rates, see [DATA_GUIDE.md](DATA_GUIDE.md).

---

## 1. Before you go out

- **Charge the phone fully** and, for long sessions, bring a power bank — the
  detector and camera run continuously and heat/battery are the main limits.
- **Free up storage.** Each visit saves JPEG photos; hours of activity can be
  hundreds of MB to several GB. Check free space is comfortably more than you
  expect to use.
- **Pick your model and settings ahead of time** so you're not fiddling in the
  sun. Settings persist between sessions, so last-used values reappear.

### Physical setup

- **Mount the phone, do not hold it.** Any camera movement looks like subject
  movement, so a handheld phone keeps the motion gate permanently awake and adds
  blur to saved photos. Use a tripod, clamp or stake with a phone holder, and check
  that it stays put in wind.
- **Portrait orientation.** The app is portrait-only; the mount has to hold the
  phone upright.
- **Distance to the flower.** There is no single correct distance: let the on-screen
  readout decide it. Move the phone closer until the region of
  interest covers the flower *and* the label shows your target saved size with no
  ⚠ warning. Closer means more pixels on the insect, but a smaller area watched.
- **Power.** Plan for a power bank on any session longer than a few tens of minutes
  (see §8 on heat and battery).

<!-- OWNER TODO (round 158): add your own field experience to this section before
     the first public release. Specifically: (a) which mount/clamp you actually use,
     (b) typical phone-to-flower distance in cm for your setup and target resolution,
     (c) lighting and glare (sun behind the phone or behind the flower, midday
     reflections, shading tricks), (d) how you deal with wind-moved vegetation.
     These are the questions a first-time user asks and nothing in the code answers
     them. -->


- **Location & flight mode (round 126).** The app takes ONE GPS fix per session
  (pin button on the camera screen; green = set). The GPS receiver still works in
  flight mode, but assisted-GPS data cannot download there, so a cold fix can take
  minutes: **get the fix first, then enable flight mode.** If GPS fails entirely, the
  pin dialog lets you type coordinates. The fix is written to the session log and
  stamped (with the capture time) into crops you export from the summary screen, so
  identification apps like ObsIdentify read where-and-when directly from the file.
  **ObsIdentify tip (verified in the field):** save the crop to the Gallery and then
  pick it *inside* ObsIdentify — its share-import ignores photo location, so the
  direct Share button won't carry the coordinates into that particular app.

## 2. Starting a session

1. **Open the app.** The home screen asks for camera permission (and, on first
   run, notification permission — this lets the app keep recording reliably in
   the background; see §6). Grant both.
2. **Frame the flower** in the camera preview.
3. **Place the Region of Interest (ROI).** The ROI is the square box you drag
   over the flower. Only insects whose centre is inside this box are counted —
   everything outside is ignored, which is how the app rejects background
   movement. Drag to move it; drag the corner handle (or use the size slider in
   settings) to resize. It always stays a **square**.
   - The box snaps to a model-friendly size, so the size you see is exactly the
     size that gets saved ("what you see is what you save"). While the app is
     still measuring the camera, the readout briefly shows "measuring…".
   - The on-screen label tells you the pixel size the photos will be saved at.
     If it shows a **⚠ warning that the size is below your target**, the flower
     is too small in frame — move the phone closer or zoom the lens (there is
     no software fix; enlarging pixels invents no detail).
4. **Check the focus.** Focus is always manual (round 164 — autofocus would
   drift onto the background) and starts locked for a subject about **13 cm**
   from the lens. The focus button shows an **amber dot** until you have set
   it: tap the button and drag the Far–Near slider until the flower is sharp;
   the dot then disappears. Focus stays exactly where you put it for the whole
   session (you may still fine-tune mid-recording; every change is logged).
5. **Open Settings** (gear/tune icon) if you want to change the model, target
   plant folder name, confidence, capture timing, etc. See
   [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md).
6. **Press Record.** A red REC banner and an elapsed-time clock appear. The
   session auto-stops after the configured session length, or when you press
   stop.

## 3. Reading the live screen while recording

- **Status strip (top-left)** — when enabled, shows: frames per second, the
  model in use, the engine (CPU or GPU), the camera stream resolution, the ROI
  size, phone temperature, free storage, and the current number of tracked
  insects. Turning it off (Settings) removes that per-frame UI work for the
  lightest preview.
- **Storage free** — how much room is left on the phone for photos and logs
  (refreshed every temperature sample). A ⚠ appears below 1 GB: clean up old
  sessions before starting a long recording. If storage runs out mid-session
  the session keeps running and shows a red banner, but new photos and log
  lines can no longer be saved.
- **Bounding boxes + track IDs** — colored boxes with a number label are drawn
  over each tracked insect. The **track ID** is what makes a visit measurable:
  the same insect keeps the same number across frames. (You can turn box
  drawing off in Settings; detection and tracking still run — only the drawing
  stops.)
- **Mode chip** — always shown at the top left, so you can tell at a glance
  which capture mode is running: **green = photos happening/possible right
  now, grey = waiting.**
  - AI detector: "DETECTOR ON"; with the motion gate enabled, grey
    "DETECTOR SLEEPING" means nothing is moving in the ROI so the detector is
    resting to save heat and battery. **Sleeping is normal and correct** on an
    empty flower — it is not a fault. The ROI border also turns grey while
    sleeping. See §5 for how this affects the FPS number.
  - Motion-trigger: "MOTION: CAPTURING" / "MOTION: WAITING".
  - Time-lapse: "TIME-LAPSE: press REC" before recording, then
    "TIME-LAPSE: CAPTURING" during a burst or "NEXT BURST in mm:ss" between
    bursts.
  On a narrow screen a long label may shorten itself with "…" — that is
  deliberate, so the info toggle next to it always stays reachable.
- **Info panel over the REC banner** — while recording, expanding the "▸"
  info panel draws it on a dark backdrop **on top of** the red REC banner so
  every line is readable; collapse it ("▾ hide info") to see the banner
  again. The red ROI border still shows that recording is running.
- **ROI border colour** tells you what's happening at a glance:
  - **grey** — motion gate is idle (detector sleeping),
  - **red** — recording,
  - **a brief flash** — a photo was just saved (this is only a visual cue at
    photo cadence; it never affects the frame rate; you can disable it).
- **"Calibrating…" banner** — shown briefly at startup while the app probes
  the camera (first analysis frame, photo resolution, stream ceiling); the
  probe results are cached, so later launches clear it faster. Wait for it to
  clear before relying on the readouts. (The GPU-vs-CPU engine benchmark is
  never automatic; run it yourself from Settings → AI if you want it.)

## 4. Power-saving (blackout) during long sessions

Long unattended sessions waste battery lighting a screen nobody is watching.
There is a **blackout button** that dims/darkens the display while recording
continues in the background. **Tap anywhere to wake** the screen; a brief
"tap to wake" hint fades in when you enter blackout. Recording, detection,
tracking and photo capture all keep running while the screen is dark.

Since round 82 blackout also **stops the live preview stream at the camera**
(not just the display): the phone no longer spends effort producing preview
images nobody can see, which was measured to cut the phone's total load
roughly in half during quiet (motion-gated) periods. Waking takes about a
fifth of a second while the preview reattaches; the locked focus and the
camera frame-rate cap are re-applied automatically.

(Recording only runs while the app is open — blackout is *not* the same as
locking the phone. Don't press the hardware lock button; use blackout.)

Blackout is also the app's biggest built-in *cooling* measure — see §8 on
heat. Since round 132 every blackout on/off toggle is written to the session
log, so you can tell afterwards whether a session ran screen-on or dark.

## 5. Stopping and the summary

Press stop (or let the session timer expire). The app writes a final
`end_of_session` record, then opens the **session summary**, organized into
tabs:

- **Photos** — browse the saved ROI JPEGs; each shows its exact saved pixel
  size. A random sample of at most 10 loads by itself; **Show all photos**
  loads the rest (a long session can hold thousands, so expect that to be
  slow — for big sessions, copying the folder to a computer over USB is
  easier, see §6). Reference photos (see below) are mixed in chronologically
  and marked with a "Reference photo" chip; they have no detection boxes by
  design. **Copy photos to gallery** at the bottom copies the session's
  photos into the phone's own Gallery app (details in §6).
- **Graphs** — the insect visit count (track IDs), the visit timeline (your
  visitation-rate result), a visit-length histogram with a selectable bin
  width, and a per-session "Visits by time of day" chart, all shown
  automatically. Temperature, FPS and battery/power are always recorded and
  sit under a tap-to-expand "Extra graphs" section for when you need them.
  Note: the power (W) graph only renders for sessions recorded fully on
  battery — plugged in (even on a power bank with a full battery), the
  battery sensor measures the charger, not consumption, so the app hides it.
  The inference-time graph there is the detector model's own run time only
  (image preparation and box post-processing are logged separately, see
  [DATA_GUIDE.md](DATA_GUIDE.md)).
- **Setup** — the headline numbers (date, times, duration, battery used,
  storage) plus, behind "All session settings", every setting this session
  recorded (useful for your methods write-up). Settings that had no effect
  in the session's capture mode are listed anyway, dimmed and marked not
  applicable.

If you open a past session and the summary flags it as ended abnormally, that
means the `end_of_session` line is missing — the app was killed or crashed. The
data up to that point is still valid (see [DATA_GUIDE.md](DATA_GUIDE.md)).

## 6. Where the files are, and getting them off the phone

Each session writes to:

```
Android/data/<app-package>/files/sessions/<your-folder-name>/
    session.jsonl              ← the append-only data log
    roi_frames/                ← saved ROI photos (roi_<sessionId>_<epochMs>.jpg)
    gt_frames/                 ← reference photos (ref_<token>_<stamp>.jpg),
                                 fixed-interval, on by default
    logcat_start.txt, logcat_end.txt   ← diagnostic logs
```

If a folder name already exists, a numeric suffix is added so nothing is
overwritten.

**Why reference photos matter:** they are taken on a fixed clock (default
every 30 s) whether or not anything was detected, so they show what the
camera *really* saw. If you find a pollinator in a reference photo that the
AI never logged, that photo is a documented miss — please send such photos
in (Report a problem, or with the session folder): they are exactly what is
needed to improve the detection models.

To retrieve the data: connect the phone by **USB** and copy the `sessions`
folder to your computer with your file manager (or `adb pull`). This location
is app-scoped external storage, which is visible over USB.

**Viewing a session's photos in the phone's own Gallery app:** the session
folder above is invisible to gallery apps by design (Android never indexes
app-private storage). To browse photos on the phone itself, open the session's
summary → Photos tab → **Copy photos** (or the ⚙ gear menu on
the session's row in the home screen's Previous sessions list, which also
offers **Rename session**, **Run AI on photos** and **Delete session**). This
copies every saved
photo (including the reference photos from `gt_frames/`) into the shared album
`Pictures/FaunaPulse/<session-name>`, which
any gallery app shows as its own album. Notes: they are *copies* (the dialog
shows how much extra storage they take), the data log is not exported,
pressing the button again skips photos already exported (no duplicates), and
the feature needs Android 10 or newer.
Also, avoid creating copy of sessions with large data volumes.

## 7. Field troubleshooting

**FPS dropped a lot after ~30 seconds.** Under direct sun the phone's own
thermal management throttles the processor — this is the device protecting
itself, not an app bug. The app defends against it with an inference FPS cap
(default 10) and optional auto-throttle; a steady lower rate collects better
data than a fast rate that collapses. Shade the phone if you can.

**"DETECTOR SLEEPING" and it won't wake.** The motion gate only wakes on
movement inside the ROI. Confirm the ROI actually covers where insects land,
and check the motion-gate sensitivity settings (pixel delta / area fraction /
grid size). Handheld shake also keeps it awake — the gate is designed for a
*mounted* phone.

**FPS number looks low while nothing is happening.** When the motion gate is
sleeping it deliberately only inspects a few frames per second (the idle check
rate), so a low FPS readout during an empty period is the feature working, not
the camera failing.

**"Camera: 1 fps" in time-lapse mode.** Same idea: the camera hardware keeps
running at its normal rate, but between bursts the app deliberately keeps only
about one frame per second (and discards the rest before the costly image
conversion) to save heat and battery. The number counts the frames the app
*keeps*, and the panel label says so in this mode. During a burst it rises a
little; it never needs to reach the camera's full rate because time-lapse
photos come on a clock, not from every frame.

**Frozen preview + "camera off" in the chip (time-lapse).** With "Turn camera
off between bursts" enabled (round 163), the camera hardware is fully turned
off between bursts — the preview freezes on its last frame and the chip reads
"NEXT BURST in mm:ss · camera off". That is the power saver working, not a
crash. The camera turns back on shortly before each burst (the "Camera wake
lead" setting, default 10 s — a woken camera needs a few seconds to settle
exposure and move the lens back to your locked focus, or the first photo
comes out dark and blurry); if it ever fails to come back in time, the app
leaves it on for the rest of the session and logs the failure, so a burst is
never silently skipped twice. This combines freely with blackout (§4): the
moon button saves the screen, camera sleep saves the camera — use both for
unattended time-lapse runs.

**No detections at all.** Check: is the right model selected? Is confidence set
too high? Is the insect's centre actually inside the ROI? If the camera is
clearly running but nothing is ever detected for several seconds, the app raises
a banner suggesting the model may be incompatible.

**⚠ "below N px" on the ROI label.** The flower is too small in frame to reach
your target saved photo size. Move closer or use a zoom lens — this cannot be
fixed in software.

**Battery drains fast / phone got killed mid-session.** Long sessions are
demanding. On first record the app offers to open Android's battery settings.
Find FaunaPulse and choose **Unrestricted** or **Don't optimize** if reliable
unattended recording matters. The app also runs a foreground service (the
ongoing notification) while recording. Some phones with aggressive manufacturer
battery managers additionally need FaunaPulse enabled under **Autostart**.

**Where did my photos go / storage full.** See §6 for the path. If storage
fills mid-session, saving fails — keep comfortable free space for the session
length you're planning.

**Red banner: "The camera stopped delivering frames."** The camera itself went
silent for 10+ seconds — typically another app took it over, or the phone's
camera service failed. The event is written to the session log with its
timestamp, so the gap is visible in your data afterwards. Stop and restart the
session (or reopen the app); the banner clears by itself if frames resume.

**FPS dropped sharply after the phone warmed up.** That is the phone
protecting itself from heat, not an app fault — the session keeps recording
at a reduced rate and recovers as the phone cools. See §8 for what to expect
and what helps (shade first).

## 8. Heat: what to expect and what helps

Phones protect themselves from overheating by silently slowing down —
**"thermal throttling"**. There is no warning: the operating system just
reduces what the hardware is allowed to do, and on the phones we tested it
slows the **camera** first, not the AI model. What you see on screen is the
detector FPS dipping (sometimes sharply), then the app's auto-adjust finding
a lower rate that the warm phone can sustain. **A hot session degrades — it
does not die.** Every temperature and FPS sample is in the session log, so
you can always see afterwards exactly when and how hard a session throttled.

### What we measured (your phone will differ)

These are two real devices from development — they bracket the range you
should expect, and they show that the limiting factor depends on the phone:

- **A budget phone with a slow chip (Samsung Galaxy M12).** Never passed
  ~32 °C battery temperature in five one-hour indoor sessions — heat is a
  non-issue. Its limit is speed: the standard model ran at ~3 FPS flat, and a
  smaller/quantized model at ~7 FPS. Battery use was 7–12 %/h unplugged
  (roughly 8–10 h on its own battery). On phones like this, **model choice
  matters far more than heat** (2.5× FPS difference between models).
- **A faster phone with an aggressive thermal governor (Xiaomi, Snapdragon
  class).** Runs ~10 FPS cool, but while charging it reached 46 °C within
  12 minutes; at ~41–42 °C the system throttled the camera hard (frames
  briefly dropped to 1–2 per second) before the app's auto-adjust settled it
  at ~6 FPS, which it then held even as the temperature kept rising. On
  phones like this, **the heat budget is the limit, and charging + sun eat
  into it**.

Neither phone's own "thermal status" API admitted anything was happening —
the session log's temperature and FPS records are the only honest witnesses.

### What helps, in order of payoff

1. **Keep the phone out of direct sun.** Sunlight adds several watts of heat
   that no software setting can remove — it is the single biggest factor.
   Mount in shade, or shade the phone (a white/reflective cover or a simple
   sunshade over the mount). A dark phone body in summer sun can exceed the
   throttle threshold before recording even starts.
2. **Use blackout mode (§4).** The screen is one of the phone's biggest
   heaters; the measured difference with the cover up was about 10 °C of
   case temperature on our hot test device.
3. **Motion gate on** for scenes that are mostly still: the detector sleeps
   between visits instead of heating the phone around the clock.
4. **Lower "Saved photo side" if you don't need large photos.** A smaller
   target lets the app pick a smaller camera stream — less load on the
   camera hardware, which is exactly the part the phone throttles first.
5. **Expect charging to cost headroom.** A power bank keeps a long session
   alive but adds charging heat; the throttle point arrives sooner. That
   trade is usually worth it — just plan for it.
6. **On slow phones, pick the faster model** (Settings → AI, and the
   benchmark button tells you which engine is faster on your device).

### Active cooling gadgets (untested by us — read before buying)

Clip-on phone coolers ("semiconductor" / Peltier coolers sold as gaming
accessories, roughly €15–40) can genuinely lower the back of the phone by
several degrees, but: they draw 2–5 W (your power bank drains much faster),
they attach where mounts often clamp, and chilling a phone below the dew
point on a humid morning can condense moisture on it. A plain small fan is
gentler (no condensation) but also weaker. If you try one, the app itself is
the test instrument: record two sessions at the same spot, cooler on and
off, and compare the temperature and FPS graphs in the session summaries
(under "Extra graphs").
