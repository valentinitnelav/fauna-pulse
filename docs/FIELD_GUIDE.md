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
- **Free up storage.** Each track ID saves JPEG photos; hours of activity can be
  hundreds of MB to several GB. Check free space is comfortably more than you
  expect to use.
- **Pick your model and settings ahead of time** so you're not fiddling in the
  sun. Settings persist between sessions, so last-used values reappear.
- **Fill in the field notes** (camera screen, the pin with a pencil): the
  position, who set up, site, plant, camera height and distance, notes, and
  fields of your own (*Add a field*: text, notes, number, date, time, yes or no,
  or a choice from your list), and site photos of the whole setup (*Take a site
  photo*; they move into the session at Start; tap a photo to see it, *Delete
  photo* and then *Delete* removes it). *GPS search stops at* sets how
  accurate the position must be (default 10 m; the search stops after 3 min
  with the best one). They are saved with every session until you
  change them, in the same form as the FaunaLapse app.

### Physical setup

- **Mount the phone, do not hold it.** Any camera movement looks like subject
  movement, so a handheld phone keeps the motion gate permanently awake and adds
  blur to saved photos. Use a tripod, clamp or stake with a phone holder, and check
  that it stays put in wind.
- **Portrait orientation.** The app is portrait-only; the mount has to hold the
  phone upright.
- **Distance to the flower.** There is no single correct distance: let the on-screen
  readout decide it. Move the phone closer until the region of
  interest covers the flower *and* the label shows your *Saved photo side* with no
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

0. **Get the AI models at home, on Wi-Fi** (they are large): home screen, step 1,
   *What do you want to watch?* Each answer shows how to set up the phone and the
   models chosen for it; one button downloads them and sets them up. The
   *Download* window checks the free storage when it opens: if the files do not
   fit, an orange line says how much is needed and how much is free (both in
   the same unit, for example "needs 1.2 GB, but only 0.7 GB is free"), and
   *Download* stays grey. Delete some files (for example old sessions on the
   Sessions screen), then come back to the app; the line goes away by itself,
   or shows the new amounts if there is still too little room.
   If the storage fills up during a download, the download stops at once with
   "⚠ Not enough free storage: the download stopped. …" and the half-loaded
   file is deleted; free some space, then tap *Try again*. If the phone cannot
   reach the internet, the window says so; with airplane mode on and Wi-Fi off
   it reads "Could not reach the server: airplane mode is on. Turn off airplane
   mode or turn on Wi-Fi, then try again."
1. **Open the app.** The home screen asks for camera permission (and, on first
   run, notification permission — this lets the app keep recording reliably in
   the background; see §6). Grant both. The notification permission is asked
   again when an analysis (*Find animals …* or *Identify organisms*) starts while
   it is not granted yet. If the camera is not allowed, a
   message says so for a few seconds; its *Open settings* button opens the
   phone's settings for FaunaPulse (Apps > FaunaPulse > Permissions).
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
6. **Press Record.** First a *Before you record* sheet sums up the session: the
   field notes and position, what and when will be recorded (one sentence), and
   the phone settings that matter in the field (airplane mode, Wi-Fi, Bluetooth,
   location, Stay awake, battery limits), each with a button to its settings
   page. *Change* opens the field notes or the settings; *Start* starts. Untick
   *Show this before each start* to skip it next time. Then a red REC banner and
   an elapsed-time clock appear. The session auto-stops after the configured
   session length, or when you press stop.
   If the free storage is already below *Keep free storage* (Settings, Power
   tab), the app does not record: the sheet shows a red line "Not enough free
   storage: … MB free, but a recording needs at least … MB free …" (whole
   megabytes, the unit of the setting), and *Start*
   (or REC, when the sheet is turned off) opens a *Not enough free storage*
   window instead; *Close* it, free some space, then try again. A scheduled
   window that would start with too little storage is skipped, and the camera
   screen says so; it still starts if space is freed before the window ends.
   During such a window, a tap on the dark screen shows "Window not started: …
   MB free, less than 200 MB (Settings, Keep free storage)." and under it "Free
   some storage: this window still starts if space is freed before 12:58." (the
   window's end). While a window is open but its recording has not begun yet,
   the line reads "Recording starts soon (this window ends at 12:58)."

## 3. Reading the live screen while recording

- **Status strip (top-left)** — when enabled, shows: frames per second, the
  model in use, the engine (CPU or GPU), the camera stream resolution, the ROI
  size, battery temperature, free storage, and, when a detection model runs,
  *Track IDs now* (insects followed at this moment) and *Track IDs this
  session* (all track IDs so far). Turning it off (Settings) removes that per-frame UI work for the
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
  - Live detection: "DETECTOR ON" (grey "NO DETECTION MODEL" when no
    detection model is chosen or on the phone); with the motion gate enabled, grey
    "DETECTOR SLEEPING" means nothing is moving in the ROI so the detector is
    resting to save heat and battery. **Sleeping is normal and correct** on an
    empty flower — it is not a fault. The ROI border also turns grey while
    sleeping. See §5 for how this affects the FPS number.
  - Motion-trigger: "MOTION: CAPTURING" / "MOTION: WAITING".
  - Time-lapse: "TIME-LAPSE: tap ●" before recording, then
    "TIME-LAPSE: CAPTURING" during a burst or "NEXT BURST in mm:ss" between
    bursts ("NEXT BURST in 2 h 15 min" when the wait is an hour or more).
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
  never automatic; run it yourself from Settings → Detection if you want it.)

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

**Switching the screen off is fine too** (since round 292): press the power
button, or let the phone's own screen timeout do it, and the recording goes on
with the screen off: detection, photos and video keep running, only the live
preview stops. Wake the phone and open FaunaPulse to look or to stop. Blackout
remains for when you want the app on screen but dark. To have the screen go dark
by itself, set *Screen off by itself after* (Power tab, e.g. 3 minutes): the
black screen comes up that long after your last touch, and the phone's own
screen timeout then switches the screen off. Note: while a phone
charges (a power bank counts), Android's "Stay awake" developer option keeps
the screen on whatever its timeout says.

Blackout is also the app's biggest built-in *cooling* measure — see §8 on
heat. Since round 132 every blackout on/off toggle is written to the session
log, so you can tell afterwards whether a session ran screen-on or dark.

## 5. Stopping and the summary

Press stop (or let the session timer expire). While the app closes the files
(a few seconds on a hot phone, longer when a video clip is open), the button
dims and shows *Stopping…*; more taps do nothing. The app writes a final
`end_of_session` record, then opens the **session summary**, organized into
tabs:

- **Photos** — browse the saved ROI JPEGs; each shows its exact saved pixel
  size. A random sample of at most 10 loads by itself; **Show all photos**
  loads the rest (a long session can hold thousands, so expect that to be
  slow — for big sessions, copying the folder to a computer over USB is
  easier, see §6). Reference photos (see below) are mixed in chronologically
  and marked with a "Reference photo" chip; they have no detection boxes by
  design. **Copy photos to Gallery** at the bottom copies the session's
  photos into the phone's own Gallery app (details in §6).
- **Graphs** — the track ID count, the track ID timeline (your
  visitation-rate result), a track-length histogram with a selectable bin
  width, and a per-session "Track IDs by time of day" chart, all shown
  automatically. Temperature, FPS and battery/power are always recorded and
  sit under a tap-to-expand "Extra graphs" section for when you need them.
  Note: the power (W) graph only renders for sessions recorded fully on
  battery — plugged in (even on a power bank with a full battery), the
  battery sensor measures the charger, not consumption, so the app hides it.
  The *Detector time per frame (ms)* graph there is the detector model's own run time only
  (image preparation and box post-processing are logged separately, see
  [DATA_GUIDE.md](DATA_GUIDE.md)).
- **Setup** — the headline numbers (date, times, duration, battery used,
  storage) plus, behind "All session settings", every setting this session
  recorded (useful for your methods write-up). Settings that had no effect
  in the session's capture mode are listed anyway, dimmed and marked not
  applicable. When the recording stopped by itself (battery at *Stop at
  battery level*, or free storage below *Keep free storage*), a *Stopped by
  itself* row says which, with the level and the limit.

If you open a past session and the summary flags it as ended abnormally, that
means the `end_of_session` line is missing — the app was killed or crashed. The
data up to that point is still valid (see [DATA_GUIDE.md](DATA_GUIDE.md)).

## 6. Where the files are, and getting them off the phone

**Sessions from FaunaLapse.** The sister app FaunaLapse records time-lapse photos or video on
any phone, without AI, and lasts long on a battery. To run FaunaPulse's AI on them afterwards,
copy the zip that FaunaLapse's *Pack* button made of a photo session to this phone, then
Sessions → ⋮ → *Import a FaunaLapse session…*; for a video session use *Import videos…*.


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
camera *really* saw. If you find an animal in a reference photo that the
AI never logged, that photo is a documented miss: it shows what the
detection model did not see at your site.

To retrieve the data: connect the phone by **USB** and copy the `sessions`
folder to your computer with your file manager (or `adb pull`). This location
is app-scoped external storage, which is visible over USB.

**Viewing a session's photos in the phone's own Gallery app:** the session
folder above is invisible to gallery apps by design (Android never indexes
app-private storage). To browse photos on the phone itself, open the session's
summary → Photos tab → **Copy photos** (or the ⋮ menu at the end of the
session's row on the **Sessions** screen, which also offers **Rename session**,
**Find animals in photos** and **Delete session**). This
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
thermal management slows the processor (the device protects itself; this is
not an app bug). The app defends against it with **Max detector rate** (Power
tab, default 15 FPS) and the switch **Auto-adjust detector rate (reduces
heat)**, which is on by default; a steady lower rate collects better data than
a fast rate that collapses. Shade the phone if you can.

**"DETECTOR SLEEPING" and it won't wake.** The motion gate only wakes on
movement inside the ROI. Confirm the ROI actually covers where insects land,
and check the motion gate settings in the **Gate sensitivity** fold (Power
tab): *Pixel sensitivity*, *Trigger area* and *Motion grid resolution*.
Handheld shake also keeps it awake: the gate is made for a *mounted* phone.

**FPS number looks low while nothing is happening.** When the motion gate is
sleeping it deliberately only inspects a few frames per second (*Idle check
rate* in the Gate sensitivity fold), so a low FPS readout during an empty
period is the feature working, not the camera failing.

**"Camera: 1 fps" in time-lapse mode.** Same idea: between bursts the app
deliberately keeps only about one frame per second (and discards the rest before
the costly image conversion; with "Turn camera off between bursts" on, the camera
is off) to save heat and battery. The number counts the frames the app
*keeps*, and the panel label says so in this mode. During a burst it rises a
little; it never needs to reach the camera's full rate because time-lapse
photos come on a clock, not from every frame.

**Frozen preview + "camera off" in the chip (time-lapse).** With "Turn camera
off between bursts" on (the default since round 291), the camera hardware is fully turned
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
a banner: "The detection model gives no results although the camera is
running. It may not work on this phone: …". Choose another model in Session
settings (Detection tab), or tap *Report*.

**⚠ "below N px" on the ROI label.** The flower is too small in frame to reach
your *Saved photo side* (Settings, Photos tab). Move closer or use a zoom lens
(software cannot fix this).

**Battery drains fast / phone got killed mid-session.** Long sessions are
demanding. On first record the app offers to open Android's battery settings.
Find FaunaPulse and choose **Unrestricted** or **Don't optimize** if reliable
unattended recording matters. The app also runs a foreground service (the
ongoing notification) while recording. Its text says that the recording goes
on with the screen off, and that swiping FaunaPulse away from the recent apps
also stops the recording. Some phones with aggressive manufacturer
battery managers additionally need FaunaPulse enabled under **Autostart**.

**Find animals and Identify in the background.** *Find animals in videos*,
*Find animals in photos* and *Identify organisms* (also when started by *Also
identify them*) go on while you use other apps or the screen is off. While one
runs, a notification says so ("FaunaPulse is finding animals in videos", "… in
photos" or "FaunaPulse is identifying animals"); tapping it should open the running
screen (not yet checked on a phone). *Stop* on that screen, or swiping FaunaPulse away
from the recent apps, ends the run (what is done is kept). On Android 15 and newer,
Android should protect such work for about 6 hours a day; after that the run should go
on, but Android may close the app while it is in the background (not yet tested on an
Android 15 phone). The notification channel is called *Finding and identifying
animals* in the phone's notification settings.

**Keep FaunaPulse on the screen during identification.** Identification is the
heaviest step: a model such as BioCLIP 2 needs more than 1 GB of the phone's memory. When
another app is in front, Android may make the identification wait, or close FaunaPulse
to free memory. FaunaPulse is a measuring tool, so it does not try to guess when the
phone has memory to spare: plug the phone in and leave FaunaPulse open until the
results show. The screens say this too: with *Also identify them* on, *Find animals in
videos* and *Find animals in photos* show "Identification needs a lot of memory. Keep
FaunaPulse on the screen until it ends: if you switch to another app, it may wait, or
Android may stop it." under the switch, and *Identify organisms* shows the same line
(ending "… Android may stop it.") above *Start* and during the run.

**When the identification waits ("Animals found").** When *Also identify them*
reaches the identification while FaunaPulse is in the background, the app first checks
that the identification model fits in the phone's free memory. Small models (such as
insectDCT) fit and go on in the background. A large model such as BioCLIP 2 often does
not fit, on the processor (CPU) and also on the graphics chip (GPU), which needs even
more memory (about 4.5 times the model file): Android would close the app. Then the app
keeps what it found, ends the "finding" notification and shows the notification
"Animals found" ("Open FaunaPulse to identify them. …"). To go on:

1. Open FaunaPulse (tap the notification, or open the app from the recent apps or its
   icon).
2. *Identify organisms* opens by itself, shows "Loading the model…" and runs. Keep
   FaunaPulse on the screen until the results show.

This also works when Android closed FaunaPulse while it waited (on one test phone this
happened 15 to 75 seconds after "Animals found" appeared): the app remembers the waiting
identification for up to 24 hours and starts it the next time you open the app. It
tries this once. If Android closes FaunaPulse again during that start, the next opening
starts nothing and shows for a few seconds: "The identification of "<session>" stopped
when FaunaPulse was closed. To continue: on the Sessions screen, tap ⋮ next to this
session, then "Identify organisms". It goes on where it stopped." Do these steps; what
was identified already is kept.

The notification channel of "Animals found" is called *Identification waiting*.
Notifications need the phone's permission (Android 13 and newer). FaunaPulse asks for it
when a recording starts, and also when *Find animals in videos*, *Find animals in
photos* or *Identify organisms* starts (once each time the app is opened; the run goes
on whatever you answer). Without it no notification shows, but opening the app still
starts the waiting identification.

**Where did my photos go / storage full.** See §6 for the path. When free
storage drops below *Keep free storage* (Power tab, default 200 MB) the
recording stops cleanly and the camera screen says "Recording stopped: less
than 200 MB free storage (Settings, Keep free storage)." The same happens with
the battery at *Stop at battery level*. The session summary keeps the reason
in the *Stopped by itself* row (Setup tab). *Keep free storage* cannot be set
below 50 MB (the phone and the last files need room), and a recording does not
start at all while less than that limit is free (see §2, step 6). Keep
comfortable free space for the session length you're planning.

**"Model failed to load" when the camera opens.** The detection model file
could not be set up; it may be damaged. The window names the file and says:
"The file may be damaged. On the "Download & import models" screen, delete it,
then download or import it again." *Find animals in videos* gives the same
advice ("The detector model could not be loaded. …") instead of saying the
videos could not be read.

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
slows the **camera** first, not the detection model. What you see on screen is the
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
   while no insect is there instead of heating the phone around the clock.
4. **Lower "Saved photo side" if you don't need large photos.** A smaller
   target lets the app pick a smaller camera stream — less load on the
   camera hardware, which is exactly the part the phone throttles first.
5. **Expect charging to cost headroom.** A power bank keeps a long session
   alive but adds charging heat; the throttle point arrives sooner. That
   trade is usually worth it — just plan for it.
6. **On slow phones, pick the faster model** (Settings → Detection, and the
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
