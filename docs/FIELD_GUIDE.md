# Field Guide — Running a Pollinator Monitoring Session

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

> **TODO (owner knowledge):** physical field setup — recommended phone mount,
> distance from the flower so the ROI meets your target photo resolution, and
> lighting/glare tips. Fill in from field experience.

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
4. **Open Settings** (gear/tune icon) if you want to change the model, target
   plant folder name, confidence, capture timing, etc. See
   [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md).
5. **Press Record.** A red REC banner and an elapsed-time clock appear. The
   session auto-stops after the configured session length, or when you press
   stop.

## 3. Reading the live screen while recording

- **Status strip (top-left)** — when enabled, shows: frames per second, the
  model in use, the engine (CPU or GPU), the camera stream resolution, the ROI
  size, phone temperature, and the current number of tracked insects. Turning
  it off (Settings) removes that per-frame UI work for the lightest preview.
- **Bounding boxes + track IDs** — colored boxes with a number label are drawn
  over each tracked insect. The **track ID** is what makes a visit measurable:
  the same insect keeps the same number across frames. (You can turn box
  drawing off in Settings; detection and tracking still run — only the drawing
  stops.)
- **DETECTOR ON / SLEEPING chip** — only appears when the **motion gate** is
  enabled (off by default). Green "DETECTOR ON" means the model is running;
  grey "SLEEPING" means nothing is moving in the ROI so the detector is resting
  to save heat and battery. **Sleeping is normal and correct** on an empty
  flower — it is not a fault. The ROI border also turns grey while sleeping.
  See §5 for how this affects the FPS number.
- **ROI border colour** tells you what's happening at a glance:
  - **grey** — motion gate is idle (detector sleeping),
  - **red** — recording,
  - **a brief flash** — a photo was just saved (this is only a visual cue at
    photo cadence; it never affects the frame rate; you can disable it).
- **"Calibrating…" banner** — shown briefly at startup while the app measures
  the camera and benchmarks the engine. Wait for it to clear before relying on
  the readouts.

## 4. Power-saving (blackout) during long sessions

Long unattended sessions waste battery lighting a screen nobody is watching.
There is a **blackout button** that dims/darkens the display while recording
continues in the background. **Tap anywhere to wake** the screen; a brief
"tap to wake" hint fades in when you enter blackout. Recording, detection,
tracking and photo capture all keep running while the screen is dark.

(Recording only runs while the app is open — blackout is *not* the same as
locking the phone. Don't press the hardware lock button; use blackout.)

## 5. Stopping and the summary

Press stop (or let the session timer expire). The app writes a final
`end_of_session` record, then opens the **session summary**, organized into
tabs:

- **Overview** — unique insect (track) count and headline numbers.
- **Settings** — every setting this session actually used (useful for your
  methods write-up).
- **Photos** — browse the saved ROI JPEGs; each shows its exact saved pixel
  size.
- **Graphs** — visit timeline, temperature, FPS and battery/power over the
  session. On long sessions these can be set to generate on a button press
  instead of automatically (Settings → Graphs).

If you open a past session and the summary flags it as ended abnormally, that
means the `end_of_session` line is missing — the app was killed or crashed. The
data up to that point is still valid (see [DATA_GUIDE.md](DATA_GUIDE.md)).

## 6. Where the files are, and getting them off the phone

Each session writes to:

```
Android/data/<app-package>/files/sessions/<your-folder-name>/
    session.jsonl              ← the append-only data log
    roi_frames/                ← saved ROI photos (roi_<sessionId>_<epochMs>.jpg)
    logcat_start.txt, logcat_end.txt   ← diagnostic logs
```

If a folder name already exists, a numeric suffix is added so nothing is
overwritten.

To retrieve the data: connect the phone by **USB** and copy the `sessions`
folder to your computer with your file manager (or `adb pull`). This location
is app-scoped external storage, which is visible over USB.

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

**No detections at all.** Check: is the right model selected? Is confidence set
too high? Is the insect's centre actually inside the ROI? If the camera is
clearly running but nothing is ever detected for several seconds, the app raises
a banner suggesting the model may be incompatible.

**⚠ "below N px" on the ROI label.** The flower is too small in frame to reach
your target saved photo size. Move closer or use a zoom lens — this cannot be
fixed in software.

**Battery drains fast / phone got killed mid-session.** Long sessions are
demanding. On first record the app asks to be exempted from battery
optimization and runs a foreground service (that's the ongoing notification) so
the OS doesn't kill it — accept those prompts. Some phones (aggressive OEM
battery managers) still need the app manually whitelisted in system settings.

**Where did my photos go / storage full.** See §6 for the path. If storage
fills mid-session, saving fails — keep comfortable free space for the session
length you're planning.
