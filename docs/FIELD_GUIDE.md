# Field guide: running a FaunaPulse session

This page is for the person who runs FaunaPulse in the field. It shows how to prepare, how to
start and stop a session, what the live screen tells you, and what to do when something looks
wrong. It assumes the app is already installed (see [INSTALL.md](INSTALL.md)). Measurements
and details are in folded blocks: click a line that starts with ▸ to open it.

> **In short**
>
> - Get the AI models at home, on Wi-Fi: on **Home**, step 1 (**What do you want to watch?**).
> - Mount the phone upright, do not hold it. In our field work 15 to 20 cm between the phone
>   and the flower worked well; move closer if the region of interest label shows ⚠. Fix the flower to a thin wooden plant stick against wind.
> - Drag the square region of interest over the flower, set the focus, then press Record.
> - Heat and battery are the main limits: keep the phone in shade, use blackout and bring a
>   power bank.
> - The photos and the data log are in the app's folder on the phone. Copy them to a computer
>   over USB.

**Contents**

1. [Before you go out](#1-before-you-go-out)
2. [Starting a session](#2-starting-a-session)
3. [Reading the live screen while recording](#3-reading-the-live-screen-while-recording)
4. [Power-saving (blackout) during long sessions](#4-power-saving-blackout-during-long-sessions)
5. [Stopping and the summary](#5-stopping-and-the-summary)
6. [Where the files are, and getting them off the phone](#6-where-the-files-are-and-getting-them-off-the-phone)
7. [Field troubleshooting](#7-field-troubleshooting)
8. [Heat: what to expect and what helps](#8-heat-what-to-expect-and-what-helps)

- For developers: [Version notes](#version-notes)

Other pages: why a small box on the screen still saves a sharp photo is explained in
[HOW_PHOTO_RESOLUTION_WORKS.md](HOW_PHOTO_RESOLUTION_WORKS.md). What each setting does is in
[SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md). How to turn the saved log into visitation rates
is in [DATA_GUIDE.md](DATA_GUIDE.md).

---

## 1. Before you go out

- **Charge the phone fully.** For long sessions, bring a power bank. The detector and the
  camera run all the time, and heat and battery are the main limits.
- **Free up storage.** Each track ID saves JPEG photos. Hours of activity can be hundreds of MB
  to several GB. Make sure the free space is well above what you expect to use.
- **Choose your model and settings before you go,** so that you do not have to change them in
  the sun. Settings are kept between sessions: the last values you used come back.
- **Fill in the field notes.** On the camera screen, tap the pin with a pencil.

The field notes hold:

| Field | What it holds |
|---|---|
| Position | the GPS position (see *GPS search stops at* below) |
| Who set up, site, plant | who set up the phone, the site and the plant |
| *Device ID* | a short name per phone, such as `cam-03`, when several phones record |
| Camera height and distance | the camera's height and distance |
| Notes | your notes |
| *Add a field* | fields of your own |
| *Take a site photo* | photos of the whole setup |

- **Device ID** names the phone in the results file of *Identify organisms* (`device_id`) and
  for programs on the computer, so phones of the same model stay apart.
- **Your own fields** (*Add a field*) can be text, notes, a number, a date, a time, yes or no,
  or a choice from your list.
- **Site photos** move into the session at Start. Tap a photo to see it. *Delete photo* and
  then *Delete* removes it.
- **GPS search stops at** sets how accurate the position must be (default 10 m). The search
  stops after 3 min with the best position found.

The field notes are saved with every session until you change them. They are stored in the same
form as in the FaunaLapse app.

### Physical setup

- **Mount the phone, do not hold it.** Any camera movement looks like the movement of an
  animal. A phone held in the hand keeps the motion gate awake all the time and blurs the saved
  photos. Use a tripod, a clamp or a stake with a phone holder, and check that it does not move
  in wind.
- **Use a smartphone, upright (portrait).** FaunaPulse is made for smartphones; tablets are not
  supported. The screen is locked upright, so the mount must hold the phone upright. Mounted
  sideways, every saved photo and video is turned by 90 degrees and the AI can find and name
  animals less well. When the phone looks straight down on flowers, this matters little (see
  the folded block below).
- **Distance to the flower.** There is no single correct distance: let the readout on the
  screen decide. Move the phone closer until the region of interest covers the flower *and* the
  label shows your *Saved photo side* with no ⚠ warning. Closer means more pixels on the
  insect, but a smaller area watched.
- **15 to 20 cm worked for us.** In our own field work 15 to 20 cm between the phone and the
  flower worked well (the same as the setup tip for *Pollinators on flowers* on Home). This may
  seem close, but further away the insects look too small and the detector may miss them.
- **Keep the flower still.** Wind moves flowers. We fixed the plant or the target flower to a thin wooden plant stick, the kind that
  garden centres and DIY stores sell cheaply in bundles.
- **Do not re-aim during a session.** Moving or turning the phone breaks the running track IDs
  and puts the region of interest over another spot. To re-aim, stop the session and start a
  new one.
- **Power.** Plan for a power bank on any session longer than a few tens of minutes (see
  [section 8](#8-heat-what-to-expect-and-what-helps) on heat and battery).

<details>
<summary>A phone mounted sideways</summary>

A phone mounted sideways still works, but the app does not notice the turn. Every saved photo
and video then shows the scene turned by 90 degrees. The AI models mostly learned from pictures
where up is up, so they can find and name animals less well in side views.

When the phone looks straight down on flowers there is no "up", so the turn matters little. The
saved positions of the boxes are measured on the phone's own picture, so note a sideways mount
in your field notes.

</details>

### Location and flight mode

1. The app takes **one GPS fix per session** (a fix is one measured position). Use the pin
   button on the camera screen; it turns green when the position is set.
2. **Get the fix first, then turn on flight mode.** The GPS receiver still works in flight
   mode, but assisted-GPS data (help data from the internet) cannot download there. A cold fix
   (the first one in a while) can then take minutes.
3. If GPS fails completely, the pin window lets you type the coordinates.

The fix is written to the session log. It is also stamped, with the capture time, into the
crops you export from the summary screen, so identification apps like ObsIdentify read where
and when directly from the file.

**ObsIdentify tip (checked in the field):** save the crop to the Gallery, then pick it *inside*
ObsIdentify. Its share import ignores the photo location, so the direct Share button does not
carry the coordinates into that app.

## 2. Starting a session

1. **Get the AI models at home, on Wi-Fi** (they are large). On the home screen, step 1 asks
   *What do you want to watch?* Each answer shows how to set up the phone and the models chosen
   for it. One button downloads them and sets them up. The *Download* window checks the free
   storage first (see the folded block below).
2. **Open the app.** The home screen asks for camera permission and, on the first run, for
   notification permission. The notification lets the app keep recording reliably in the
   background (see [section 7](#battery-storage-and-android-closing-the-app)). Grant both.
   - The notification permission is asked again when an analysis (*Find animals …* or
     *Identify organisms*) starts while it is not granted yet.
   - If the camera is not allowed, a message says so for a few seconds. Its *Open settings*
     button opens the phone's settings for FaunaPulse (Apps > FaunaPulse > Permissions).
3. **Frame the flower** in the camera preview.
4. **Place the region of interest (ROI).** The ROI is the square box you drag over the flower.
   Only insects whose centre is inside this box are counted. Everything outside is ignored:
   this is how the app rejects movement in the background.
   - Drag the box to move it. Drag the corner handle (or use the size slider in Settings) to
     resize it. It always stays a **square**.
   - The box snaps to a size that suits the model, so the size you see is exactly the size that
     is saved ("what you see is what you save"). While the app is still measuring the camera,
     the readout briefly shows "measuring…".
   - The label on the screen shows the pixel size of the saved photos. A **⚠ warning that the
     size is below your target** means the flower is too small in the picture. Move the phone
     closer or zoom the lens. Software cannot fix this: enlarging pixels invents no detail.
5. **Check the focus.** Focus is always manual, because autofocus would drift onto the
   background. It starts locked for a subject about **13 cm** from the lens.
   - The focus button shows an **amber dot** until you have set it. Tap the button and drag the
     Far–Near slider until the flower is sharp; the dot then disappears.
   - Focus stays exactly where you put it for the whole session. You can still fine-tune it
     while recording; every change is logged.
6. **Open Settings** (the gear or tune icon) if you want to change the model, the target plant
   folder name, the confidence, the capture timing and so on. See
   [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md).
7. **Press Record.** First a *Before you record* sheet sums up the session:
   - the field notes and the position;
   - what will be recorded and when (one sentence);
   - the phone settings that matter in the field (airplane mode, Wi-Fi, Bluetooth, location,
     Stay awake, battery limits), each with a button to its settings page.

   *Change* opens the field notes or the settings; *Start* starts. Untick *Show this before
   each start* to skip the sheet next time. Then a red REC banner and a clock with the time
   since the start appear. The session stops by itself after the session length you set, or
   when you press stop. If the free storage is too low, the app does not record (see the
   folded block below).

<details>
<summary>When the models do not fit or the phone is offline (step 1)</summary>

**Not enough storage before the download.** If the files do not fit, an orange line says how
much is needed and how much is free, both in the same unit (for example "needs 1.2 GB, but only
0.7 GB is free"). *Download* stays grey. Delete some files (for example old sessions on the
Sessions screen), then come back to the app. The line goes away by itself, or shows the new
amounts if there is still too little room.

**Storage full during the download.** The download stops at once with "⚠ Not enough free
storage: the download stopped. …", and the half-loaded file is deleted. Free some space, then
tap *Try again*.

**No internet.** If the phone cannot reach the internet, the window says so. With airplane mode
on and Wi-Fi off it reads "Could not reach the server: airplane mode is on. Turn off airplane
mode or turn on Wi-Fi, then try again."

</details>

<details>
<summary>When the free storage is too low to record (step 7)</summary>

**At Record.** If the free storage is already below *Keep free storage* (Settings, Power tab),
the app does not record. The sheet shows a red line "Not enough free storage: … MB free, but a
recording needs at least … MB free …" (whole megabytes, the unit of the setting). *Start* (or
REC, when the sheet is turned off) opens a *Not enough free storage* window instead. *Close*
it, free some space, then try again.

**Scheduled windows.** A scheduled window that would start with too little storage is skipped,
and the camera screen says so. It still starts if space is freed before the window ends.

During such a window, a tap on the dark screen shows "Window not started: … MB free, less than
200 MB (Settings, Keep free storage)." Under it: "Free some storage: this window still starts
if space is freed before 12:58." (the window's end).

While a window is open but its recording has not begun yet, the line reads "Recording starts
soon (this window ends at 12:58)."

</details>

## 3. Reading the live screen while recording

**Mode chip.** It is always shown at the top left, so you can see at a glance which capture
mode is running. **Green = photos are being taken or possible right now; grey = waiting.**

| Mode | Chip | Meaning |
|---|---|---|
| Live detection | "DETECTOR ON" | the detector runs |
| Live detection | grey "NO DETECTION MODEL" | no detection model is chosen or on the phone |
| Live detection | grey "DETECTOR SLEEPING" | motion gate on, nothing moves in the ROI |
| Motion trigger | "MOTION: CAPTURING" / "MOTION: WAITING" | taking photos / waiting |
| Time-lapse | "TIME-LAPSE: tap ●" | before recording |
| Time-lapse | "TIME-LAPSE: CAPTURING" | during a burst |
| Time-lapse | "NEXT BURST in mm:ss" | between bursts |

- **"DETECTOR SLEEPING"** means the detector rests to save heat and battery. **Sleeping is
  normal and correct** on an empty flower: it is not a fault. The ROI border also turns grey
  while sleeping. See [section 7](#frame-rate-and-the-detector) for how this affects the FPS
  number.
- **"NEXT BURST"** reads "NEXT BURST in 2 h 15 min" when the wait is an hour or more.
- On a narrow screen a long label may shorten itself with "…". This is on purpose, so the info
  toggle next to it always stays reachable.

**ROI border colour.** It tells you at a glance what is happening:

| Border | Meaning |
|---|---|
| grey | the motion gate is idle (detector sleeping) |
| red | recording |
| a brief flash | a photo was just saved |

The flash is only a visual cue at the photo rate. It never affects the frame rate, and you can
turn it off.

**Status strip (top left).** When it is turned on, it shows:

- frames per second (FPS), the model in use and the engine (CPU or GPU);
- the camera stream resolution and the ROI size;
- the battery temperature and the free storage;
- when a detection model runs: *Track IDs now* (insects followed at this moment) and *Track IDs
  this session* (all track IDs so far).

Turning the strip off (Settings) removes that work on every frame, for the lightest preview.

**Storage free.** How much room is left on the phone for photos and logs. It is refreshed at
every temperature sample. A ⚠ appears below 1 GB: clean up old sessions before you start a
long recording. If the storage runs out during a session, the session keeps running and shows a
red banner, but new photos and log lines can no longer be saved.

**Boxes and track IDs.** Coloured boxes with a number are drawn over each tracked insect. The
**track ID** is what makes a visit measurable: the same insect keeps the same number from frame
to frame. You can turn the drawing of boxes off in Settings. Detection and tracking still run;
only the drawing stops.

**Info panel over the REC banner.** While recording, open the "▸" info panel. It is drawn on a
dark background **on top of** the red REC banner, so every line is readable. Close it ("▾ hide
info") to see the banner again. The red ROI border still shows that recording is running.

**"Calibrating…" banner.** It is shown briefly at the start while the app tests the camera
(first analysis frame, photo resolution, highest stream size). The results are saved, so later
starts clear it faster. Wait until it is gone before you trust the readouts. The engine
benchmark (**Benchmark engines (GPU vs CPU)** in Settings → Detection) never runs by itself:
run it yourself if you want it.

## 4. Power-saving (blackout) during long sessions

In a long session nobody watches the screen, and lighting it wastes battery. The **blackout
button** darkens the screen while recording goes on. **Tap anywhere to wake** the screen. A
short "tap to wake" hint fades in when blackout starts.

- Recording, detection, tracking and photo capture all keep running while the screen is dark.
- Blackout also **stops the live preview stream at the camera**, not only the display. The
  phone no longer makes preview pictures that nobody can see. This was measured to cut the
  phone's total load roughly in half during quiet periods (when the motion gate lets the
  detector sleep).
- Waking takes about a fifth of a second while the preview comes back. The locked focus and the
  camera frame-rate cap are set again automatically.
- Every blackout on or off is written to the session log, so you can tell afterwards whether a
  session ran with the screen on or dark.
- Blackout is also the app's biggest built-in way to keep the phone cool (see
  [section 8](#8-heat-what-to-expect-and-what-helps) on heat).

**Switching the screen off is fine too.** Press the power button, or let the phone's own screen
timeout do it. The recording goes on with the screen off: detection, photos and video keep
running; only the live preview stops. Wake the phone and open FaunaPulse to look or to stop.

Blackout is for when you want the app on the screen, but dark.

**Screen dark by itself.** Set *Screen off by itself after* (Power tab, for example 3 minutes).
The black screen comes up that long after your last touch, and the phone's own screen timeout
then switches the screen off.

Note: while a phone charges (a power bank counts), Android's "Stay awake" developer option keeps
the screen on, whatever its timeout says.

## 5. Stopping and the summary

1. Press stop, or let the session timer run out.
2. While the app closes the files, the button dims and shows *Stopping…*; more taps do nothing.
   This takes a few seconds on a hot phone, longer when a video clip is open.
3. The app writes a final `end_of_session` record, then opens the **session summary**.

The summary has three tabs:

| Tab | What it shows |
|---|---|
| **Photos** | the saved ROI photos (JPEG) and the reference photos |
| **Graphs** | track ID counts and timelines (your visitation-rate result) |
| **Setup** | the main numbers and every setting of the session |

**Photos.** Each photo shows its exact saved pixel size.

- A random sample of at most 10 photos loads by itself. **Show all photos** loads the rest. A
  long session can hold thousands, so expect that to be slow. For big sessions, copying the
  folder to a computer over USB is easier (see [section 6](#6-where-the-files-are-and-getting-them-off-the-phone)).
- Reference photos (see section 6) are mixed in by time and marked with a "Reference photo"
  chip. They have no detection boxes, by design.
- **Copy photos to Gallery** at the bottom copies the session's photos into the phone's own
  Gallery app (details in section 6).

**Graphs.** Shown automatically: the track ID count, the track ID timeline, a histogram of track
lengths (you can choose the bin width) and a "Track IDs by time of day" chart for the session.

- Temperature, FPS and battery or power are always recorded. Their graphs are under "Extra
  graphs" (tap to open) for when you need them.
- The power (W) graph only shows for sessions recorded fully on battery. When the phone is
  plugged in (even to a power bank with a full battery), the battery sensor measures the
  charger, not the use, so the app hides the graph.
- The *Detector time per frame (ms)* graph there is the detector model's own run time only.
  Image preparation and box post-processing are logged separately (see
  [DATA_GUIDE.md](DATA_GUIDE.md)).

**Setup.** The main numbers: date, times, duration, battery used and storage.

- Behind "All session settings" is every setting this session recorded (useful for the methods
  section of a paper).
- Settings that had no effect in the session's capture mode are listed anyway, dimmed and
  marked not applicable.
- When the recording stopped by itself (battery at *Stop at battery level*, or free storage
  below *Keep free storage*), a *Stopped by itself* row says which, with the level and the
  limit.

**A session that "ended abnormally".** If you open a past session and the summary says it ended
abnormally, the `end_of_session` line is missing: the app was killed or crashed. The data up to
that point is still valid (see [DATA_GUIDE.md](DATA_GUIDE.md)).

## 6. Where the files are, and getting them off the phone

Each session writes to:

```
Android/data/<app-package>/files/
  sessions/<your-folder-name>/
    session.jsonl
    roi_frames/
    gt_frames/
    logcat_start.txt
    logcat_end.txt
```

- `session.jsonl`: the append-only data log.
- `roi_frames/`: saved ROI photos (`roi_<sessionId>_<epochMs>.jpg`).
- `gt_frames/`: reference photos (`ref_<token>_<stamp>.jpg`), fixed-interval, on by default.
- `logcat_start.txt`, `logcat_end.txt`: diagnostic logs.

If a folder name already exists, a number is added to the end, so nothing is overwritten.

**Copy the data to a computer.** Connect the phone by **USB** and copy the `sessions` folder to
your computer with your file manager (or `adb pull`). This location is app-scoped external
storage (the app's own folder in the phone's main storage), which is visible over USB.

**Why reference photos matter.** They are taken on a fixed clock (by default every 30 s),
whether or not anything was detected. So they show what the camera *really* saw. If you find an
animal in a reference photo that the AI never logged, that photo is a documented miss: it shows
what the detection model did not see at your site.

### Seeing the photos in the phone's Gallery app

The session folder is hidden from gallery apps by design: Android never indexes the app's
private storage. To browse the photos on the phone itself:

1. Open the session's summary → **Photos** tab → **Copy photos**. Or, on the **Sessions**
   screen, open the ⋮ menu at the end of the session's row (it also offers **Rename session**,
   **Find animals in photos** and **Delete session**).
2. Every saved photo, including the reference photos from `gt_frames/`, is copied into the
   shared album `Pictures/FaunaPulse/<session-name>`. Any gallery app shows it as its own album.

Notes:

- They are *copies*: the window shows how much extra storage they take.
- The data log is not exported.
- Pressing the button again skips photos already exported (no duplicates).
- The feature needs Android 10 or newer.
- Avoid copying sessions with large amounts of data.

### Sessions from FaunaLapse

The sister app FaunaLapse records time-lapse photos or video on any phone, without AI, and runs
long on a battery. To run FaunaPulse's AI on them afterwards:

- **Photo session:** copy the zip that FaunaLapse's *Pack* button made to this phone. Then use
  Sessions → ⋮ → *Import a FaunaLapse session…*.
- **Video session:** use *Import videos…*.

Import only zips that you made with FaunaLapse or that someone you trust sent you. The app
first checks that the phone has enough free storage, and it leaves out damaged photos. Sessions
of up to 1,000,000 photos can be imported (for example eleven days at one photo per second).

## 7. Field troubleshooting

Find your problem in the bold lines below. The problems are grouped:

- [Frame rate and the detector](#frame-rate-and-the-detector)
- [Detection, photo size and the camera](#detection-photo-size-and-the-camera)
- [Battery, storage and Android closing the app](#battery-storage-and-android-closing-the-app)
- [Finding and identifying animals in the background](#finding-and-identifying-animals-in-the-background)

### Frame rate and the detector

**FPS dropped a lot after ~30 seconds.** Under direct sun the phone's own heat management slows
the processor. The phone protects itself; this is not an app bug. Shade the phone if you can.

The app defends against it with **Max detector rate** (Power tab, default 15 FPS) and the switch
**Auto-adjust detector rate (reduces heat)**, which is on by default. A steady lower rate
collects better data than a fast rate that collapses.

**FPS dropped sharply after the phone warmed up.** That is the phone protecting itself from
heat, not an app fault. The session keeps recording at a lower rate and recovers as the phone
cools. See [section 8](#8-heat-what-to-expect-and-what-helps) for what to expect and what helps
(shade first).

**"DETECTOR SLEEPING" and it does not wake.** The motion gate only wakes on movement inside the
ROI.

- Check that the ROI really covers the spot where insects land.
- Check the motion gate settings in the **Gate sensitivity** fold (Power tab): *Pixel
  sensitivity*, *Trigger area* and *Motion grid resolution*.
- Shaking in the hand also keeps the gate awake: the gate is made for a *mounted* phone.

**The FPS number looks low while nothing is happening.** While the motion gate sleeps, it looks
at only a few frames per second on purpose (*Idle check rate* in the Gate sensitivity fold). A
low FPS readout during an empty period is the feature working, not the camera failing.

**"Camera: 1 fps" in time-lapse mode.** Same idea: between bursts the app keeps only about one
frame per second on purpose, to save heat and battery. It throws the other frames away before
the costly image conversion; with "Turn camera off between bursts" on, the camera is off.

- The number counts the frames the app *keeps*, and the panel label says so in this mode.
- During a burst it rises a little. It never needs to reach the camera's full rate, because
  time-lapse photos come on a clock, not from every frame.

**Frozen preview and "camera off" in the chip (time-lapse).** With "Turn camera off between
bursts" on (the default), the camera hardware is fully off between bursts. The preview freezes
on its last frame, and the chip reads "NEXT BURST in mm:ss · camera off". That is the power
saver working, not a crash.

- The camera turns back on shortly before each burst: the "Camera wake lead" setting, default
  10 s. A woken camera needs a few seconds to settle the exposure and to move the lens back to
  your locked focus; otherwise the first photo comes out dark and blurry.
- If the camera ever fails to come back in time, the app leaves it on for the rest of the
  session and logs the failure. So a burst is never silently skipped twice.
- This combines freely with blackout ([section 4](#4-power-saving-blackout-during-long-sessions)):
  the moon button saves the screen, camera sleep saves the camera. Use both for time-lapse runs
  that nobody watches.

### Detection, photo size and the camera

**No detections at all.** Check: is the right model selected? Is the confidence set too high?
Is the insect's centre really inside the ROI?

If the camera clearly runs but nothing is ever detected for several seconds (the detection
model has given no result at all since the start), the app shows a banner:
"The detection model gives no results although the camera is running. It may not work on this
phone: …". Choose another model in Session settings (Detection tab), or tap *Report*.

**⚠ "below N px" on the ROI label.** The flower is too small in the picture to reach your *Saved
photo side* (Settings, Photos tab). Move closer or use a zoom lens (software cannot fix this).

**"Model failed to load" when the camera opens.** The detection model file could not be set up;
it may be damaged. The window names the file and says: "The file may be damaged. On the
"Download & import models" screen, delete it, then download or import it again." *Find animals
in videos* gives the same advice ("The detector model could not be loaded. …") instead of
saying that the videos could not be read.

**Red banner: "The camera stopped delivering frames."** The camera itself sent nothing for 10
seconds or more. Usually another app took it over, or the phone's camera service failed.

- The event is written to the session log with its time, so the gap is visible in your data
  afterwards.
- Stop and restart the session (or reopen the app). The banner clears by itself if frames come
  back.

### Battery, storage and Android closing the app

**The battery drains fast, or the phone killed the app during a session.** Long sessions are
demanding.

- On the first recording the app offers to open Android's battery settings. Find FaunaPulse and
  choose **Unrestricted** or **Don't optimize** if reliable recording without you matters.
- Some phones have strict battery managers from the phone maker. They also need FaunaPulse
  turned on under **Autostart**.
- While recording, the app runs a foreground service (the notification that stays). Its text
  says that the recording goes on with the screen off, and that swiping FaunaPulse away from
  the recent apps also stops the recording.

**Where did my photos go / storage full.** See [section 6](#6-where-the-files-are-and-getting-them-off-the-phone)
for the folder.

- When the free storage drops below *Keep free storage* (Power tab, default 200 MB), the
  recording stops cleanly. The camera screen says "Recording stopped: less than 200 MB free
  storage (Settings, Keep free storage)."
- The same happens with the battery at *Stop at battery level*.
- The session summary keeps the reason in the *Stopped by itself* row (Setup tab).
- *Keep free storage* cannot be set below 50 MB (the phone and the last files need room). A
  recording does not start at all while less than that limit is free (see
  [section 2](#2-starting-a-session), step 7).
- Keep enough free space for the session length you plan.

### Finding and identifying animals in the background

**Find animals and Identify in the background.** *Find animals in videos*, *Find animals in
photos* and *Identify organisms* (also when started by *Also identify them*) go on while you use
other apps or the screen is off.

- While one runs, a notification says so: "FaunaPulse is finding animals in videos", "… in
  photos" or "FaunaPulse is identifying animals".
- Tapping it opens the running screen (checked for *Find animals in videos* on Android 14).
- The notification can take about 10 seconds to appear, because Android waits that long before
  it shows such notifications.
- *Stop* on that screen, or swiping FaunaPulse away from the recent apps, ends the run. What is
  done is kept.
- The notification channel is called *Finding and identifying animals* in the phone's
  notification settings.

<details>
<summary>Android 15 and newer: the 6-hour limit (not yet tested)</summary>

On Android 15 and newer, Android should protect such work for about 6 hours a day. After that
the run should go on, but Android may close the app while it is in the background. This is not
yet tested on an Android 15 phone.

</details>

**Keep FaunaPulse on the screen during identification.** Identification is the heaviest step: a
model such as BioCLIP 2 needs more than 1 GB of the phone's memory. When another app is in
front, Android may make the identification wait, or close FaunaPulse to free memory.

FaunaPulse is a measuring tool, so it does not try to guess when the phone has memory to spare.
Plug the phone in and leave FaunaPulse open until the results show.

The screens say this too:

- With *Also identify them* on, *Find animals in videos* and *Find animals in photos* show under
  the switch: "Identification needs a lot of memory. Keep FaunaPulse on the screen until it
  ends: if you switch to another app, it may wait, or Android may stop it."
- *Identify organisms* shows the same line (ending "… Android may stop it.") above *Start* and
  during the run.

**When the identification waits ("Animals found").** This can happen when *Also identify them*
reaches the identification while FaunaPulse is in the background. The app first checks that the
identification model fits in the phone's free memory.

- Small models (such as insectDCT) fit and go on in the background.
- A large model such as BioCLIP 2 often does not fit, on the processor (CPU) and also on the
  graphics chip (GPU), which needs even more memory (about 4.5 times the model file). Android
  would close the app.
- Then the app keeps what it found, ends the "finding" notification and shows the notification
  "Animals found" ("Open FaunaPulse to identify them. …").

To go on:

1. Open FaunaPulse (tap the notification, or open the app from the recent apps or its icon).
2. *Identify organisms* opens by itself, shows "Loading the model…" and runs. Keep FaunaPulse
   on the screen until the results show.

<details>
<summary>If Android closed FaunaPulse while the identification waited or ran</summary>

**While it waited.** This also works when Android closed FaunaPulse while the identification
waited. On one test phone this happened 15 to 75 seconds after "Animals found" appeared. The app
remembers the waiting identification for up to 24 hours and starts it the next time you open the
app. It tries this once.

**Closed again during that start.** Then the next opening starts nothing and shows for a few
seconds: "The identification of "<session>" stopped when FaunaPulse was closed. To continue: on
the Sessions screen, tap ⋮ next to this session, then "Identify organisms". It goes on where it
stopped." Do these steps; what was identified already is kept.

**Closed during an identification started on the screen.** The same line shows when Android
closed FaunaPulse during an identification that started while FaunaPulse was on the screen. An
example: you switched to another app while it ran (up to 24 hours after the identification
started). Then nothing starts by itself, so opening the app (for example to record) does not
start that identification again by surprise.

**Notifications.** The notification channel of "Animals found" is called *Identification
waiting*. Notifications need the phone's permission (Android 13 and newer). FaunaPulse asks for
it when a recording starts. It also asks when *Find animals in videos*, *Find animals in photos*
or *Identify organisms* starts (once each time the app is opened; the run goes on whatever you
answer). Without the permission no notification shows, but opening the app still starts the
waiting identification.

</details>

## 8. Heat: what to expect and what helps

Phones protect themselves from overheating by slowing down without a word. This is called
**"thermal throttling"**. There is no warning: the operating system just reduces what the
hardware may do. On the phones we tested it slows the **camera** first, not the detection
model.

What you see on the screen: the detector FPS dips (sometimes sharply). Then the app's
auto-adjust finds a lower rate that the warm phone can keep up. **A hot session gets slower: it
does not stop.** Every temperature and FPS sample is in the session log, so afterwards you can
always see exactly when and how hard a session was slowed down.

### What helps, in order of payoff

1. **Keep the phone out of direct sun.** Sunlight adds several watts of heat that no setting
   can remove: it is the single biggest factor. Mount the phone in shade, or shade it (a white
   or reflective cover, or a simple sunshade over the mount). A dark phone body in summer sun
   can pass the throttle point before recording even starts.
2. **Use blackout mode ([section 4](#4-power-saving-blackout-during-long-sessions)).** The
   screen is one of the phone's biggest heaters. With the cover up, the measured difference was
   about 10 °C of case temperature on our hot test phone.
3. **Turn the motion gate on** for scenes that are mostly still. The detector then sleeps while
   no insect is there, instead of heating the phone all the time.
4. **Lower *Saved photo side* if you do not need large photos.** A smaller target lets the app
   choose a smaller camera stream. That is less load on the camera hardware, which is exactly
   the part the phone slows down first.
5. **Expect charging to cost headroom.** A power bank keeps a long session alive but adds
   charging heat, so the throttle point comes sooner. This trade is usually worth it: just plan
   for it.
6. **On slow phones, choose the faster model** (Settings → Detection). The benchmark button
   tells you which engine is faster on your phone.

<details>
<summary>What we measured on two phones (your phone will differ)</summary>

These are two real phones from development. They show the range you should expect, and they
show that the limit depends on the phone.

**A budget phone with a slow chip (Samsung Galaxy M12).**

- It never passed ~32 °C battery temperature in five one-hour indoor sessions: heat is not an
  issue.
- Its limit is speed: the standard model ran at ~3 FPS flat, and a smaller (quantized) model at
  ~7 FPS.
- Battery use was 7–12 %/h unplugged (roughly 8 to 10 h on its own battery).
- On phones like this, **the choice of model matters far more than heat** (2.5 times the FPS
  between models).

**A faster phone with a strict heat control (Xiaomi, Snapdragon class).**

- It runs at ~10 FPS when cool.
- While charging it reached 46 °C within 12 minutes.
- At ~41–42 °C the system slowed the camera hard: frames briefly dropped to 1 to 2 per second.
  Then the app's auto-adjust settled at ~6 FPS, which it kept even as the temperature kept
  rising.
- On phones like this, **the heat budget is the limit, and charging and sun use it up**.

Neither phone's own "thermal status" API (the system's report of its heat state) showed that
anything was happening. The temperature and FPS records in the session log are the only honest
witnesses.

</details>

<details>
<summary>Active cooling gadgets (not tested by us: read before buying)</summary>

Clip-on phone coolers ("semiconductor" or Peltier coolers sold as gaming accessories, roughly
€15–40) can really lower the back of the phone by several degrees. But:

- they draw 2 to 5 W, so your power bank drains much faster;
- they attach where mounts often clamp;
- cooling a phone below the dew point on a humid morning can put water drops on it.

A plain small fan is gentler (no water drops) but also weaker.

If you try one, the app itself is the test instrument. Record two sessions at the same spot,
with the cooler on and off. Then compare the temperature and FPS graphs in the session
summaries (under "Extra graphs").

</details>

## Version notes

<details>
<summary>When some field features arrived (for developers)</summary>

- Round 82: blackout also stops the live preview stream at the camera, not only the display.
- Round 126: location and flight mode (one GPS fix per session, pin button on the camera
  screen).
- Round 132: every blackout on/off toggle is written to the session log.
- Round 164: focus is always manual.
- Round 291: "Turn camera off between bursts" is on by default.
- Round 292: switching the screen off is fine (power button or the phone's screen timeout):
  the recording goes on.

</details>
