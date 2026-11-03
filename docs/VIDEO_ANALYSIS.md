# Video analysis: from imported videos to track IDs checked against a hand count

FaunaPulse can find and follow flower visitors as track IDs in videos filmed elsewhere: the
phone's own camera app, a collaborator, or a published dataset. This guide covers the whole path, from the import on the phone to a track ID
count that has been checked against a hand count. Details for researchers and developers are
in folded blocks: click a line that starts with ▸ to open it.

To try it in a few minutes first, follow the [tutorial](TUTORIAL_VIDEO_ANALYSIS.md) with two
demo videos.

> **In short**
>
> - Detection runs afterwards on the phone ("AI later"), so the phone does not
>   need to detect live in the field.
> - Import the videos (or record them with FaunaPulse), then tap **Find animals in videos**.
>   One main button analyses the clips, finds the track IDs and, if you want, names the animals.
> - All numbers to tune are on one screen. Finding track IDs again with other settings takes
>   seconds and needs no new AI run.
> - To know how good the count is, count a sample of clips by hand and score the app with
>   `evaluate_track_ids.py`. Report recall and precision, not only the count error.
> - The frame-rate sweep shows how many frames per second your videos need.
> - **Work in progress:** the checking method (sections 3 to 5 and the scripts in
>   `tool/video_eval/`) is still being developed, together with a validation study of the app.

**Contents**

- [Terms used on this page](#terms-used-on-this-page)
- [1. The workflow](#1-the-workflow)
- [2. What the app counts as a track ID](#2-what-the-app-counts-as-a-track-id)
- [3. Counting by hand](#3-counting-by-hand)
- [4. Scoring: `evaluate_track_ids.py`](#4-scoring-evaluate_track_idspy)
- [5. Which frame rate is enough? The sweep](#5-which-frame-rate-is-enough-the-sweep)
- [6. Where to get videos](#6-where-to-get-videos)
- [7. Resolution](#7-resolution)

The file formats are in [DATA_GUIDE §9](DATA_GUIDE.md#9-imported-videos-videos-video_detectionsjsonl);
the scripts are in [`tool/video_eval/`](../tool/video_eval/README.md).

<details>
<summary>When this arrived (for developers)</summary>

The check of track IDs against a hand count arrived in round 230. Before round 248 a track ID
was called a "visit".

</details>

## Terms used on this page

- **Track ID**: the tracker's record of one insect it followed from frame to frame. In
  pollination ecology a track ID usually stands for one **visit** (an insect's stay on the
  flower), but only as far as detection and tracking worked. Some track IDs are false
  detections (a leaf, a shadow), one insect can be split into several track IDs, and two can
  be merged into one. Scoring the app against a hand count (below) measures exactly that.
- **Hand count** (also "ground truth"): the visits a person noted while watching the video. It
  is the reference the app is scored against.
- **fps**: frames per second. A phone video usually has 30. The app can look at fewer
  (**Frames analyzed per second**) to save time and heat.

## 1. The workflow

1. **Import or record** the videos ([step 1](#step-1-import-or-record)).
2. **Find animals in videos**: the detector looks at the clips and finds boxes
   ([step 2](#step-2-find-animals-in-videos)).
3. **Find track IDs**: the boxes are linked into track IDs ([step 3](#step-3-find-track-ids)).
4. **Share results** as one zip ([step 4](#step-4-share-results)).
5. **Hand count** a sample of the clips ([§3](#3-counting-by-hand)).
6. **Score** the app against the hand count with `evaluate_track_ids.py`
   ([§4](#4-scoring-evaluate_track_idspy)).

If a video cannot be read or found, see [When a video does not work](#when-a-video-does-not-work).

### Step 1. Import or record

**Import** clips filmed elsewhere:

1. Tap **Import videos…**. The button is on **Home** (step 3, **Or use your own videos**), in
   the ⋮ menu of the **Sessions** screen and on the **Find animals in videos** screen (there it
   reads **Import other videos…** once a session has videos).
2. Android's photo picker opens, with the camera's videos first. A video saved elsewhere (for
   example in Download) is found with the picker's own ⋮ menu (**Browse**).
3. The **Import videos** screen opens. Give the session a name under **Session name**.
4. Check the line **Filming started**: track IDs per hour and the dashboard use it.
   **Change…** sets the day, hour and minute.
5. Tap **Import 8 clips** (the number of clips you picked). When the copy is done, tap **Find
   animals in these videos** to go on with step 2, or **Done**.

One session per site and day works best. The videos are copied, so they take storage twice
until you delete the originals.

**Or record** the clips with FaunaPulse itself: **Capture trigger (what causes photos)**: **Time-lapse
photo or video bursts**, then **Save bursts as**: **Video (MP4), find animals later**. These clips are already the ROI square (the area of interest) and carry the
camera's own start time. They go straight to step 2: their session summary opens on the
**Video** tab with a **Find animals in videos** button.

<details>
<summary>Free storage during the import, and failed copies</summary>

- A note above the import button says that the videos are copied, so they take storage twice.
  The session can copy them back to the Gallery later (open the session, **Video** tab, **Copy
  videos to Gallery**).
- The **Import videos** screen checks the free storage when it opens, when you come back to the
  app and again before the copy.
- While the clips do not fit, a red line says how much is needed and how much is free, and the
  import button is grey. Free some space in another app (for example Files), then come back to
  this screen. After deleting sessions in FaunaPulse itself, pick the videos again.
- If a copy fails, a plain message says why ("The videos could not be copied: not enough free
  storage …") and what to do. The half-copied files are deleted.
- An import cut off by closing the app is deleted at the next start.
- A fragmented MP4 (as some download tools save videos) is written once more as a plain MP4
  while importing ("Rewriting clip 1 of 3 as a plain MP4…"). Same pictures, nothing
  re-compressed.
- Files that cannot be used are listed under **Left out** with the reason.

</details>

<details>
<summary>The start time on the Import videos screen</summary>

- The line under **Filming started** says what the file name and the time stored in the video gave.
- **Change…** sets the day, hour and minute. The seconds become 0 (the time picker has no
  seconds).
- **Back to the time read from the file** (with several clips: **Back to the times read from
  the files**) undoes the change.

</details>

### Step 2. Find animals in videos

1. Right after an import, tap **Find animals in these videos**. Later, on **Home**, step 4
   **Find and name the animals**, tap **Find animals in videos** (or use the session's ⋮ menu on
   the **Sessions** screen).
2. Choose the session, the model and the area (the proposed square is ready).
3. Tap the main button, for example **Analyze 8 clips** (**Analyze 8 clips and identify** with
   **Also identify them** on).

**The area to analyze.** The screen proposes the largest square in the middle of the video (a
video that is already square is used whole). Under **Area to analyze** you can choose **Whole picture** or
**A square**, and **Change…** the square while the video plays fast (4×, up to 10×). Watching it
fast shows whether the camera or the flowers move. **Use this square** keeps it.

The analysed area is scaled down to the model's input size. So a small insect in a whole 4K
frame shrinks to a few pixels; a square keeps it large.

**The settings screen.** Every number to tune sits on its own screen, **Detection, track ID and
identification settings**. The entry under **Also identify them** opens it (also before the
first run); its lines show the values in use. Everything there is saved as it changes.

The cards and what they hold:

- **Detection**: the confidence threshold, **Frames analyzed per second** (default 5; live
  detection analyses 15), the IoU threshold, the pause temperature, how often the phone is
  measured.
- **Track IDs**: the tracker settings ([step 3](#step-3-find-track-ids)).
- **Identification**: the settings of **Identify organisms**.

The **Identification** card is greyed, with the reason, while the automatic identification will
not run: **Also identify them** is off, **Keep frames of each track ID** is off, or it is a live
detection session.

**The main button** does what is due, in this order:

1. It analyzes the clips not done yet, or analyzed with other detection settings
   (**Analyze 8 clips**, **Continue (3 of 8 clips left)**, **Analyze again with these settings**).
2. Else it finds the track IDs when they are missing, out of date or found with other track ID
   settings (**Find track IDs**, **Find track IDs again with these settings**). With **Also
   identify them** on, **Analyze 8 clips**, **Find track IDs** and **Find track IDs again with
   these settings** end with "and identify" (**Continue…** and **Analyze again with these
   settings** do not).
3. Else, with **Also identify them** on, **Identify the animals found**.

Analyzing is the slow step. It can be paused and continued, and it finds boxes only. With
**Also identify them** on, the same button goes on through step 3 and the identification
(**Identify organisms** starts by itself on the kept frames) and ends on the results.

While clips are left (a stopped run, or a clip that cannot be read), **Find track IDs for the
clips analyzed so far** under the main button finds the track IDs of the finished clips. This
helps, for example, to free storage during a long run in several parts.

**Keep FaunaPulse open for the identification.** The analysis, the saving of frames and the
identification go on while another app is open or the screen is off, with a notification. But
with **Also identify them** on, a line under the switch says: "Identification needs a lot of
memory. Keep FaunaPulse on the screen until it ends: if you switch to another app, it may wait,
or Android may stop it."

**The screen stays on.** While a run or the saving of frames goes on, and while a video plays,
the app keeps the screen on. Afterwards the phone's own screen timeout applies again.

**Stop and continue.** **Stop**, or swiping FaunaPulse away from the recent apps, ends the run;
what is done is kept. After a **Stop** the main button reads **Continue (N of M clips left)**
(just **Continue** for a session with one clip), and it goes on inside the clip where it
stopped.

<details>
<summary>Running in the background: notifications and memory</summary>

- The notification reads "FaunaPulse is finding animals in videos", then "FaunaPulse is
  identifying animals". Opening FaunaPulse shows the progress, or the results when the run has
  ended.
- When the identification model does not fit in the phone's free memory while the app is in the
  background (often BioCLIP 2, on the CPU and also on the GPU, which needs about 4.5 times the
  model file), the identification waits for you. The notification "Animals found" asks you to
  open FaunaPulse, and it starts when you do, also after Android has closed the app meanwhile.
  Details: [IDENTIFICATION.md](IDENTIFICATION.md), step 3.
- On Android 13 and newer, the first run after the app opens asks for the notification
  permission if it is not granted yet. The run goes on whatever the answer.

</details>

<details>
<summary>Progress line, heat pauses and error messages</summary>

- **Continue** also appears when the run stopped inside its first clip.
- The progress line's **ms per frame** and time left leave out heat pauses. When a clip's length
  is not known yet, it says "time left not known yet".
- Under the progress line, **Battery temperature** shows the phone's temperature on a scale
  that ends at "pauses at N °C" (the pause temperature). After a heat pause the run goes on by
  itself 3 °C below that limit. The limit is set in **Detection, track ID and identification
  settings**, after the run.
- During a heat pause the screen says "Cooling down. Put the phone on a cool, hard surface out
  of the sun (or in front of a fan); a case traps heat. It resumes by itself."
- **Back** during a heat pause asks **The analysis is paused** (**Cancel** keeps it paused,
  **Stop and leave** stops it).
- If the storage fills up, the run stops with "Storage full: the analysis stopped. What is done
  is kept. Free some space, then press Continue." Finding the track IDs and saving the frames
  have the same message, each with its own next step.
- If the detection model cannot be loaded, the message says "The detector model could not be
  loaded. The file may be damaged. …". Delete the model on **Download & import models**, then
  download or import it again. No clip is marked as unreadable in this case.

</details>

<details>
<summary>Compare with live detection</summary>

A live detection session with **Also record the ROI as video** can be analysed the same way, to
compare with what live detection found. On its **Video** tab, the card **Compare with
detection afterwards** has a **Find animals in videos** button. The tab then switches between
**Live detection** and **Detection afterwards** on the same clips. This shows, for example, track IDs
that live detection missed while the phone was hot or the motion gate slept.

</details>

<details>
<summary>The phone during the analysis: Graphs tab</summary>

- The session's **Graphs** tab shows the block **While the detector ran on the videos**: the
  rows **Analysis time**, **Frames analyzed**, **Speed while running**, **Cooling pauses** and
  **Energy used**, and the graphs **Battery temperature (°C)**, **Frames analyzed per second**,
  **Detector time per frame (ms)** and **Power draw (W)**.
- For a session recorded with FaunaPulse (video bursts or live detection with video), a switch
  chooses between **While recording** and **While the detector ran**.

</details>

### Step 3. Find track IDs

This step is on the same screen and starts by itself when the analysis finishes. It links the
boxes into tracks. It takes seconds and can be run again with other settings: after a change,
the main button reads **Find track IDs again with these settings**.

The videos have their own tracker settings, the **Track IDs** card. They are kept apart from the
camera's, so trying values on videos never changes live detection. They start from the app's
defaults.

The settings and what they do:

- **Tracking algorithm**: ByteTrack or C-BIoU.
- **New-track confidence**: a new track ID starts only from a box the detector is at least this
  sure of (0.50).
- **Occlusion tolerance**: how long an insect may hide or leave the area and still stay one track ID
  ([§2](#2-what-the-app-counts-as-a-track-id)).
- **Minimum track length**: shorter track IDs are not counted
  ([§2](#2-what-the-app-counts-as-a-track-id)).
- **Keep frames of each track ID**: saves pictures of every track ID (on by default).
- **Fine-tuning** (folded): the algorithm's own values.

**New-track confidence.** Weaker boxes, down to the confidence the videos were analysed at, only
continue a track. Keep the two at least 0.10 apart (a note says when they are not).

**Trying tracker settings.** Analyze once with a low confidence (for example 0.10 to 0.25), then
try **New-track confidence** values. Each try only finds the track IDs again (seconds). If **All
boxes** (on the **Video** tab or under **Watch the results**) shows an insect that never gets a
track ID, lower **New-track confidence** and find the track IDs again: no new AI run is needed.

**Kept frames.** With **Keep frames of each track ID** on, the app then saves pictures of every
track ID from the clips, by the live photo rule: the first frame, then one every **Keep a frame
every** (1 s) for up to **For up to** (10 s). They land in `roi_frames/` like live photos and
show under the player on the summary's **Video** tab (**Show in video** jumps there). They are
what **Identify organisms** reads.

**Watch the results**, at the end of the same screen once clips are analysed, is the player of
the summary's **Video** tab (boxes, track IDs, the time bar, the track ID list). So a run is
judged where its settings are. If insects are missed, or one insect gets several track IDs,
change the settings above, run again and watch again. The player comes back on the same clip
and moment, with the same view and speed, to compare.

**Free storage**, in the **Track IDs** part under the track ID result (above **Watch the
results**), deletes videos. **Delete 4 clips without any track ID (1.2 GB)…** removes the clips
without any track ID. **Delete all 8 clips, keep the saved frames (…)…** removes all clips. Each
button shows the size it frees. They wait, with a line that gives the reason, until every clip is
analyzed, the track IDs include the latest analysis and the kept frames are saved.

The boxes, track IDs and kept frames stay, so **Find track IDs** can still
run again ([DATA_GUIDE §9](DATA_GUIDE.md#9-imported-videos-videos-video_detectionsjsonl)).
Copy the clips to a computer first if you may want to analyse them again.

<details>
<summary>Saving frames: stop, continue and leaving the screen</summary>

- Saving reads each clip once. It can be stopped and continued with **Save the remaining
  frames**.
- Leaving the screen while it saves stops it, so the app asks first (**Stop and leave** or
  **Cancel**, as when leaving while the detector runs).
- Only saved frames can be identified. **Identify organisms** says how many track IDs still
  have no saved frame, with a button back to this screen.

</details>

<details>
<summary>The result lines, and finding track IDs again</summary>

- When the track IDs are found, the bar at the bottom says, for example, "Found 8 track IDs in 4
  of 8 clips." and the **Track IDs** part "8 track IDs in 4 of 8 clips (occlusion tolerance …)".
- 4 is the number of clips in which at least one track ID has a box. So the other 4 are the
  clips that **Delete 4 clips without any track ID (…)…** (under **Free storage**) removes.
- With no track ID it reads "0 track IDs in 8 clips (…)".
- Finding the track IDs again numbers them anew. So identification results made before say
  "Track IDs were found again after these results were made." and need **Continue / re-run** on
  **Identify organisms**.

</details>

<details>
<summary>The time bar, Free storage and Watch the results in detail</summary>

- **Time bar.** On the summary's **Video** tab, the time bar under the video (which is also its
  slider) is cyan where the clip has at least one track ID and grey where it has none, with
  small white marks at the kept frames. The line under it gives the share of the clip with track
  IDs, so a fast drag finds the insects quickly.
- **Free storage.** A clip where a track ID only ends, with no box of it in the clip, counts as
  a clip without any track ID.
- **Watch the results** is hidden while the detector runs, the track IDs are found, frames are
  saved or clips are deleted (the phone reads one video at a time). It pauses when another
  screen opens over it. For a live detection session it shows **Detection afterwards** first.
- **Cards under the player** on the **Video** tab: **Not analyzed yet** (before the first run),
  **Square in the wrong place?** (**Change square and analyze again** opens **Find animals in
  videos** for the session) and, once the videos were deleted, **Other track ID settings?** (the
  track IDs can still be found again from the saved boxes).

</details>

### Step 4. Share results

**Share results** makes one zip with:

- `track_ids.csv` (one row per track ID),
- `mot/` (every tracked box),
- `post_tracks.jsonl`, `video_detections.jsonl` and `session.jsonl`,
- `phone_during_analysis.csv` (the phone's temperature, power and speed during the runs), when
  it has data.

Unzip it on the computer and keep the files together: the scripts below need them.

### When a video does not work

**10-bit or HDR videos** (some newer phones film this way) are refused with a message.
Re-export them as 8-bit H.264, for example with the phone's video editor or HandBrake.

**Cut-off clips.** A clip that was still recording when the app stopped (flat battery, Android
closing the app, a forced stop) is cut off. The phone writes a video's index only when the
recording ends, so the file cannot be read.

**Find animals in videos** says so, analyses the
other clips and offers **Delete the cut-off clip (…)…** (with the size it frees) right under the
note. The **Video** tab
leaves such clips out.
Live detection + video records 5-minute pieces, and video bursts one clip
per burst, so a stop loses at most the piece or burst that was recording.

**A video is missing from the photo picker?** The picker lists the camera's videos first. Open
its own ⋮ menu (**Browse**) to find a video in another folder, for example Download.

**Older phones.** A phone too slow for live detection can still record and analyse later. On the
second test phone (Samsung Galaxy M12, 2021, Exynos 850), live detection ran at 3 to 5 frames per
second, too slow for a fast insect, while video bursts recorded at the full 15 frames per second.

**Find animals in videos** then took a few times the clip's length there (23 s of bursts in
93 s; a 30-s clip at 30 frames per second in about 170 s). This is better done on the charger.

<details>
<summary>When each part arrived (for developers)</summary>

- Round 238: recording video with the app itself (*Save bursts as: Video*).
- Round 240: *Also record the ROI as video* for live detection; round 241: the Video tab switches
  between *Live detection* and *Detection afterwards*.
- Round 243: *Delete the cut-off clip…*; the Samsung Galaxy M12 measurements.
- Round 247: lowering *New-track confidence* and finding the track IDs again without a new AI run.
- Round 234: *Keep frames of each track ID* on by default.
- Round 236: *Free storage*.
- Round 254: *Frames analyzed per second* default 5 (15 before).
- Round 256: the question before leaving while frames are saved.
- Round 273: the proposed largest square in the middle (a square video used whole).
- Round 274: *Also identify them*.
- Round 306: the line under the start time on the import sheet.
- Round 307: the share of the clip with track IDs under the time bar.
- Round 308: the separate settings screen; the videos' own tracker settings, kept apart from the
  camera's.
- Round 309: *Watch the results*.
- Round 313: New-track confidence and the analysis confidence no longer forced 0.10 apart (a
  note instead).
- Round 319: the storage checks on the *Import videos* screen; analysis, saving of frames and
  identification go on in the background.

</details>

## 2. What the app counts as a track ID

Count by hand with the same rule, or the comparison measures the rule and not the detector.

| Rule | Default | Meaning |
|---|---|---|
| **Occlusion tolerance** | 3 s | an insect that hides or leaves for longer and comes back is a new track ID; shorter gaps stay one track ID |
| **Minimum track length** | 1 s | shorter track IDs are not counted |

- **Start and end.** A track ID starts when the insect is first detected in the analysed area and
  ends when it was last seen there.
- **Minimum track length.** It is set in seconds. The detector must find the insect in that many
  analysed frames in a row (the frames are shown under the setting: 1 s = 5 detections at 5 frames
  per second). At least 2 detections in a row are always needed, even at 0 s. So a high
  value also drops an insect it sees only on and off. The seconds become frames at the rate the
  video was analysed at, fixed for the whole run.
- **In the picture, not on the flower.** The app sees an insect *in the picture*, not *on the
  flower*. Whether an insect that only flies through counts is your decision. For scoring the
  app, count every insect that appears in the analysed area; flower contact can be a second
  column.
- **Across clips.** A track ID that runs on into the next clip (clips recorded back to back) is
  one track ID. Note it once, in the clip where it began, with its end time on that clip's clock
  (so the end can exceed the clip's length). The app does the same.
- **Times.** `start_s` and `end_s` are seconds from the start of the clip, the position a video
  player shows.

<details>
<summary>Older default (for developers)</summary>

The minimum track length is 1 s by default since round 256; it was 0.2 s before.

</details>

## 3. Counting by hand

> **Work in progress.** Sections 3 to 5 and the scripts in
> [`tool/video_eval/`](../tool/video_eval/README.md) are still being developed, together with a
> validation study of the app. Steps, file formats and scripts may still change. Until the study
> is published, the app's track ID counts are not validated against hand counts: check them on a
> sample of your own clips.

Watch without looking at the app's results first, ideally by someone who did not choose the
settings: knowing the answer changes what one sees.

Pick clips across conditions (sun and shade, wind, busy and quiet flowers). Include clips
**without** visits: they show how often the app counts leaves, shadows or flowers as insects.

There are four ways:

| Way | When | Section |
|---|---|---|
| test set in VIA3 | videos scored again and again | [3a](#3a-a-test-set-insects-appearances-and-three-passes-in-via3) |
| spreadsheet or BORIS | quick visit counts | [3b](#3b-quick-visit-counts-spreadsheet-or-boris) |
| boxes in CVAT | score the tracker frame by frame | [3c](#3c-boxes-and-tracks-in-cvat-optional) |
| AI helpers | drafts a person checks | [3d](#3d-annotation-helpers-and-what-not-to-use) |

### 3a. A test set: insects, appearances and three passes in VIA3

For a set of videos that will be scored again and again (other settings, other detectors),
annotate the facts once. Then the hand count does not depend on the app's settings.

**Tool:** the [VIA3](https://www.robots.ox.ac.uk/~vgg/software/via/) video and image annotators
(Visual Geometry Group, University of Oxford; version 3.0.13, two-clause BSD licence). They are
single HTML files that work offline in any browser, with nothing to install.

**The target square.** Only insects inside one square around the flower are annotated, and the
app analyses the same square. [`prepare_square.py`](../tool/video_eval/prepare_square.py) crops
the video to it, and the cropped copy is used for both: it is imported into the app and analysed
with the area **Whole picture** (a square video gets this by itself). So the app sees exactly the
annotated pixels.

For scores that are comparable with a phone recording, run **Find animals in videos** at **15
frames per second or less**.

<details>
<summary>How the cropped copy compares with a phone recording</summary>

The cropped copy also stands in for a phone time-lapse video (**Save bursts as**: **Video (MP4), find animals later**), which
records only the square ROI. The model sees a square, the insects keep their pixels, and what is
outside the square cannot give false track IDs, as in the field.

What still differs:

- the square of a 480-pixel-high video is at most 480 px (a phone records up to the *Saved photo
  side*, 1024 px by default);
- these videos have 30 frames per second (the phone records 5 by default, set under **Video frame rate**);
- the camera and lens are different.

The copy keeps all 30 frames per second, so the frame-rate sweep
([§5](#5-which-frame-rate-is-enough-the-sweep)) can still try more.

A square video gets the area **Whole picture** by itself since round 273. In the app, a video left
without a rectangle starts on the largest square in the middle since round 273 too.

</details>

**Choose the square** as on the phone, by watching the video and placing it:

```bash
cd fauna-pulse/tool/video_eval
python3 prepare_square.py squares ~/videos/
```

A folder stands for every video file in it (subfolders are not searched); single files work
too. Everything is written into an `eval` folder next to the videos (`--out` chooses another).
The project files are data: keep them with the videos, not in the code repository.

1. Open `~/videos/eval/squares_via3.json` in the VIA3 video annotator (steps below). It holds
   all the videos; the list of files in the toolbar at the top switches between them.
2. For each video: play it to see where the flower moves, pause, choose the *Rectangle* shape in
   the toolbar and draw **one** rectangle around the flower.
3. Save the project (it lands in the browser's download folder), then:

```bash
python3 prepare_square.py crop \
    --from-via ~/Downloads/via_project_<date>.json
```

VIA3 has no square tool: the rectangle becomes a square with the same centre and the longer
side, moved to stay inside the picture, at most the picture's height.

Leave a video without a rectangle to keep its whole picture (for example when the camera itself
moves). In the app such a video starts on the largest square in the middle: choose **Whole
picture** under **Area to analyze** before the run.

<details>
<summary>What <code>prepare_square.py</code> writes, and its other commands</summary>

- For each rectangle it prints the square it used, then writes `A_square.mp4` (same frames and
  frame times as the original, checked; the numbers are in `A_square.json`) and a picture of the
  square on the video (`A_square_preview.jpg`).
- It also writes everything for annotation: `A_square_via3.json` (passes 1 and 2) and 30
  pictures in `A_square_snapshots/` with `A_square_snapshots_via3.json` (pass 0).
- It never overwrites a project that already holds annotations.
- **`annotate`**: for a video left without a rectangle, `prepare_square.py annotate A.mp4` makes
  the same annotation files for the whole picture. `annotate` also takes a folder, for example
  of square clips the app recorded itself.
- **By numbers**: a square can also be given as `crop A.mp4 --x 40 --y 0 --side 480`.
- **`range`** makes a picture of where the flower moves during the video (the brightest value of
  every pixel, beside the middle frame), as a help.

</details>

**What is annotated.**

- **Insect**: one individual, as far as you can tell. One timeline row per insect.
- **Appearance**: one continuous time span in which that insect is visible inside the square:
  one time segment in the insect's row. Hidden for less than 1 s (behind a petal) is still the
  same appearance. When it leaves the square and comes back, give it a second segment in the
  same row only if you saw it is the same individual. If not sure, start a new row and write
  "maybe same as insect N" in its note.
- **No insect**: every moment of a watched video outside the appearances counts as "no insect".
  That is what measures false track IDs, so mark a video as watched only when every insect in it
  is annotated.
- **ignore**: this row marks time left out of all scores (camera knocked, heavy blur, cannot
  tell).
- Annotate what you see, not the app's rule. The scoring joins an insect's appearances into
  visits with any gap rule, for example the app's occlusion tolerance
  ([§2](#2-what-the-app-counts-as-a-track-id)).

Attributes of each time segment:

| Attribute | Values |
|---|---|
| **taxon** | set it on the insect's first appearance; the others take it over |
| **focus** | sharp, soft, very blurred |
| **size** | small = less than 15 pixels long |
| **sure** | it is an animal: yes, probably |
| **edge** | yes = mostly outside the square; such insects count as neither missed nor extra |
| **on_flower** | touched the flower, or only flew through |
| **note** | free text |

**Three passes.** A pass is one way of going through a video.

| Pass | What (VIA3 file) | Time (first guess) |
|---|---|---|
| 0, snapshot counts | a point on every insect in 30 pictures (image annotator, `*_snapshots_via3.json`) | about 10 min per video |
| 1, insect timeline | the insects' appearances with their attributes (video annotator, `*_via3.json`) | 20 to 40 min (quiet video), 1 to 3 h (busy) |
| 2, positions | a point on each insect every 1 s (the same project as pass 1) | 1 to 3 h for a busy video |

- **Pass 0**: the 30 pictures are one random moment in each 10 s. Set *counted: yes* on each
  picture, also on pictures without insects. Do pass 0 first, without looking at anything else:
  it is the unbiased count of how many insects are present at a moment (the "MeanCount" of fish
  video counts) and checks the other passes.
- **Pass 2** is only needed when several insects are present at once. Put a point on each insect
  every 1 s, and at its start and end. It lets the scoring tell insects apart when several are
  present, count when a track ID jumps from one insect to another, and see which insect was
  missed.

<details>
<summary>VIA3, video annotator (passes 1 and 2): step by step</summary>

1. Open `via_video_annotator.html` (downloaded from the VIA page) in Firefox (in Chrome,
   Ctrl + a number switches browser tabs instead of moving the video). Click *Open a VIA
   project* (folder icon) and choose `A_square_via3.json`.
   A project stores the folder of its files once (VIA3's *location prefix*) and only the file
   names. After the folder was moved, VIA3 cannot load the file and shows its settings instead:
   type the new folder (for example `/home/me/videos/eval/`) into the field next to *File
   Location*, click *Reload File*, and save the project.
2. The timeline under the video has rows `1` to `5` and `ignore`. To add a row, type its name
   (`6`) into the field *add/del insect* in the timeline's toolbar and click *Add*.
3. Keys: Space plays and pauses, ← → step one frame, 1 to 9 jump that many seconds back and
   Ctrl + 1 to 9 forward, + − change the speed (all keys: *Keyboard Shortcuts* in the timeline's
   toolbar). Select a row (↑ ↓ or a click), then at the insect's first frame press **a** (adds a
   segment in that row). Go to its last frame and press **Shift + a** (moves the segment's end
   there). A click on a segment shows its attributes beside the timeline.
4. Pass 2: choose the *Point* shape in the toolbar above the video, select the insect's row,
   pause and click on the insect. VIA3 labels the point with the selected row. Move on 1 s
   (Ctrl + 1) and repeat.
5. At the end, set *watched* to *whole video* (in the small table of the video's own attributes
   shown with the video). Save often with the save icon: VIA3 saves `via_project_<date>.json`
   into the browser's download folder. Keep the newest one per video, for example in
   `eval/annotations/`.

</details>

<details>
<summary>VIA3, image annotator (pass 0): step by step</summary>

Open `via_image_annotator.html`, then `A_square_snapshots_via3.json`. For each picture choose the
point tool, click on every insect in it, and set *counted: yes* (also when there is none).
Pictures without *counted* are not scored.

</details>

**Turn the saved projects into tables** with
[`via3_to_hand_count.py`](../tool/video_eval/via3_to_hand_count.py):

```bash
python3 via3_to_hand_count.py eval/annotations/*.json \
    --out eval/truth
```

It writes `hand_count.csv` (one row per appearance; `evaluate_track_ids.py` reads it as it is),
`ignore_spans.csv`, `positions.csv`, `snapshots.csv` and `snapshot_points.csv`. Videos not
marked *watched: whole video* are left out (`--include-unfinished` writes them too).

<details>
<summary>What the script prints, and what is not scored yet</summary>

- It prints a line per video (insects, appearances, insect-seconds).
- It notes doubtful entries: an insect with two taxa, appearances that overlap, a point outside
  its insect's appearances.
- The scoring of ignore spans, edge insects, snapshot counts and positions follows in a later
  round. Until then `evaluate_track_ids.py` scores each appearance as one visit.
- This test set arrived in round 272.

</details>

### 3b. Quick visit counts: spreadsheet or BORIS

No need to annotate every frame. Watch at normal or double speed, pause when an insect arrives
and note its start and end time.

**Spreadsheet.** Copy [`hand_count_template.csv`](../tool/video_eval/hand_count_template.csv).

- Columns `clip, start_s, end_s, taxon`. Add your own columns: the script ignores them.
- Times in seconds (`65.0`) or as the player shows them (`1:05.0`).
- The clip name may be the name before the import (`VID 1.mp4`) or inside the app
  (`VID_1.mp4`).
- A row with a clip and no times says "watched, no visit".
- Comma, semicolon or tab separated.

**[BORIS](https://www.boris.unito.it/)** (free event-logging software for behavioural coding,
Friard & Gamba 2016, *Methods in Ecology and Evolution* 7: 1325–1330):

- In the ethogram, add a **state** behaviour "visit" (one key starts it, the same key stops it).
  Point events work too, for a quick "insect here" mark; the script widens them by the
  tolerance ([§4](#4-scoring-evaluate_track_idspy)).
- Subjects can be the taxa (Apis, Bombus, Syrphidae…). The script reads the subject as the
  taxon, or the behaviour when there is no focal subject.
- **One observation per video.** BORIS counts time over the whole observation, not per video, so
  an observation with two videos would give wrong times. The script refuses such exports. Keep
  the observation's **time offset at 0**.
- Export: *Observations → Export events → Aggregated events*, as CSV or TSV
  ([BORIS user guide](https://www.boris.unito.it/user_guide/export_events/)). One BORIS version
  failed when exporting only some behaviours
  ([issue 747](https://github.com/olivierfriard/BORIS/issues/747)): export all and choose with
  the script's `--behavior visit`.

### 3c. Boxes and tracks in CVAT (optional)

This is only needed to score the tracker frame by frame (for example, how often a track ID jumps
to another insect). Visit counts do not need it.

- Annotate **keyframes**, not every frame: in [CVAT](https://www.cvat.ai/)'s track mode, draw
  the box every 10th–15th frame and let CVAT fill in the frames in between. Score on the
  keyframes only.
- Start from the app's boxes instead of an empty video:
  `python3 tool/video_eval/mot_to_cvat.py <unzipped results>` writes one zip per clip. In CVAT,
  create a task from the same video file, with the labels the script prints, then *Actions →
  Upload annotations → MOT 1.1*. Correct the boxes, add what the app missed and set the taxon.
- Each track ID's first frames are missing: a track shows up only once confirmed (after the
  minimum track length).
- A script for box-level scores (HOTA, IDF1 with
  [TrackEval](https://github.com/JonathonLuiten/TrackEval)) will be added when these annotations
  exist. `mot/` is already in the format TrackEval reads.

### 3d. Annotation helpers, and what not to use

- **[SAM 3](https://github.com/facebookresearch/sam3)** (Meta, 2025) follows every object
  matching a text prompt ("bee") through a video. It needs a computer with a graphics card
  (GPU).
- CVAT and X-AnyLabeling offer **point-and-click boxes and tracking** based on SAM models; which
  ones depends on the version and plan.
- These are AI too: a person must check every box they draw before it counts as a hand count, or
  the app is scored against another AI's mistakes.
- **AI-generated videos** are fine to test that the pipeline runs, never to measure accuracy:
  the insects' look and movement are not real.

## 4. Scoring: `evaluate_track_ids.py`

```bash
cd fauna-pulse/tool/video_eval
python3 evaluate_track_ids.py \
    --truth my_count.csv \
    --app ~/results/site1/track_ids.csv \
    --out scores.csv --pairs pairs.csv
```

**When a visit and a track ID match.** A hand-counted visit and an app track ID **match** when
they overlap in time. The hand count is first widened by `--tolerance` seconds (0.5 by default)
on each side, since clicks are never exact. Each visit and each track ID matches at most one;
the longest overlap goes first. Only clips in the hand count are scored.

The console shows one line per run:

| Number | Meaning |
|---|---|
| found | hand-counted visits the app also has a track ID for |
| missed | hand-counted visits without a track ID |
| extra | track IDs nobody counted (leaves, shadows, or one insect followed twice) |
| split | hand-counted visits overlapped by 2 or more track IDs: one insect followed more than once |
| merged | track IDs overlapping 2 or more hand-counted visits: insects that followed each other closely, followed as one |
| recall | found ÷ hand-counted visits: the share of real visits the app found |
| precision | found ÷ track IDs: the share of the app's track IDs that are real visits |
| count error | track IDs − hand-counted visits |

A split happens, for example, when an insect hid behind a petal for longer than the occlusion
tolerance.

**Report recall and precision, not only the count error:** 5 missed visits and 5 extra track IDs
give a count error of 0.

**Output files.** `--out` writes one row per run and clip, plus an `ALL` row per run. `--pairs`
writes every hand-counted visit and track ID with its status (`found`, `missed`, `extra`), to
look at the misses in the video. Both are tidy CSVs for R.

<details>
<summary>Columns of the <code>--out</code> file, and an R example</summary>

Besides the numbers above, the columns hold:

- the total time of the hand-counted visits and of the track IDs (`true_visit_s`,
  `app_track_s`; `app_visit_s` before round 248);
- the mean duration error (track ID minus visit, only for visits with a duration);
- the median start error (positive = the track ID starts later);
- `new_track` (the new-track confidence of the run, when known).

```r
library(ggplot2)
s <- read.csv("sweep_scores.csv")
s <- subset(s, clip == "ALL")
ggplot(s, aes(fps, recall, colour = tracker)) + geom_line() + geom_point() +
  scale_x_log10() + labs(x = "frames analyzed per second", y = "share of visits found")
```

</details>

## 5. Which frame rate is enough? The sweep

More frames per second find short and fast visits and keep fast insects on one track, but cost
time and heat on the phone. The app's default is 5 fps.

Instead of guessing, measure it on your own videos: detect once at the full rate, then re-run
only the tracker on every 2nd, 3rd, 6th… frame, and compare each result with the hand count.

1. **On the phone**: **Find animals in videos** with **Frames analyzed per second** at the
   video's own rate (30 for most phone videos). This takes several times longer than the default
   5, once. Then **Find track IDs** with the settings you want to test, and **Share results**.
2. **On the computer** (needs this repository and Flutter, like the app's tests):

   ```bash
   cd fauna-pulse
   flutter test \
       test/fauna_pulse/video_fps_sweep_test.dart \
       --dart-define=SWEEP_SESSION=$HOME/results/site1 \
       --dart-define=SWEEP_FPS=15,10,5,2,1
   ```

   For each rate and both trackers, this runs the app's own tracking code on the frames a run at
   that rate would have looked at (the same frame-picking rule as the phone). It writes
   `fps_sweep/track_ids_<tracker>_<fps>fps.csv`.
3. **Score** all runs at once:

   ```bash
   python3 tool/video_eval/evaluate_track_ids.py \
       --truth my_count.csv \
       --app "$HOME/results/site1/fps_sweep/track_ids_*.csv" \
       --out sweep_scores.csv
   ```

**Two rules:**

- Analyse at the video's full rate. Thinning a 15 fps analysis to 10 fps would give unevenly
  spaced frames that no real 10 fps run would use.
- At low rates, keep the occlusion tolerance well above the time between two analysed frames
  (2 s at 0.5 fps), or every track ID breaks into pieces.

<details>
<summary>Sweep options: tracker rule and New-track confidence</summary>

- The occlusion tolerance and minimum track length (in seconds) are those of the last *Find
  track IDs* (the app's defaults if there is none), so every rate is compared under the same
  rule. `--dart-define=SWEEP_OCCLUSION=3` and `--dart-define=SWEEP_MIN_S=1` set other values.
- `--dart-define=SWEEP_OUT=/absolute/path` writes to another folder (default: `fps_sweep/` in
  the session folder).
- `--dart-define=SWEEP_HIGH=0.5,0.4,0.3,0.25` also tries other *New-track confidence* values
  with ByteTrack (files ending in `_new<value>.csv`), to choose it against the hand count
  (round 247).

</details>

<details>
<summary>Published frame rates, and a first test of the default</summary>

Two published systems show both ends:

- Bjerge et al. (2021, *Remote Sensing in Ecology and Conservation*,
  [doi:10.1002/rse2.245](https://doi.org/10.1002/rse2.245)) tracked insects in time-lapse images
  at 0.33 fps and counted a track only with at least two detections.
- Sittinger et al. (2024, *PLOS ONE*,
  [doi:10.1371/journal.pone.0295474](https://doi.org/10.1371/journal.pone.0295474)) tracked
  live at about 12.5 fps (1080p) or 3.4 fps (4K) and note that too low a rate makes the track
  IDs of fast-moving insects "jump", so one insect is counted more than once.

The app's default is 5 fps since round 254 (15 before). On the first 333 s of a 60-fps edited
compilation of bees on flowers, analysed once at 15 fps, re-running the tracker on the frames of
lower rates gave:

| fps | Track IDs |
|---|---|
| 15 | 53 |
| 10 | 52 |
| 5 | 48 |
| 3 | 39 |
| 2 | 32 |

Every track ID of the 15-fps run still had one at the same time at 5 fps. That clip has scene
cuts and no hand count, so it is a hint, not a validation.

</details>

## 6. Where to get videos

To try the workflow first, the [tutorial](TUTORIAL_VIDEO_ANALYSIS.md) uses two short
public-domain demo videos (a honey bee on a flower, two deer at a trail camera).

No widely used flower-visitor video set with human-annotated tracks turned up in the search for
this guide (September 2026). So your own and collaborators' videos, counted as in
[§3](#3-counting-by-hand), are the realistic source. Useful public material:

| Data | What it holds | Use here |
|---|---|---|
| [HyDaT](https://github.com/malikaratnayake/HyDaT_Tracker) | 78 min of honeybee video, tracks made by an algorithm | good footage; count the visits yourself |
| BuzzSet, BuzzSpot | pollinator images with boxes | detection only (no video) |
| [Zenodo 15096610](https://doi.org/10.5281/zenodo.15096610) (by a FaunaPulse developer) | time-lapse images | detection and identification, not tracking |
| [SA-FARI](https://huggingface.co/datasets/facebook/SA-FARI) ([about](https://www.conservationxlabs.com/sa-fari)) | 11,609 camera-trap videos of 99 species | mammals and birds, see below |
| [Lindenthal camera traps](https://lila.science/datasets/lindenthal-camera-traps/) | camera-trap videos in RealSense files | mammals, second choice |

More about each:

- **HyDaT**: the tracks were made by an algorithm, not by people.
- **Zenodo 15096610**: expert-labelled Hymenoptera and Diptera crops, and insect-free
  backgrounds (CC BY-NC-SA).
- **SA-FARI**: boxes and track IDs at 6 fps (CC BY-NC; accept the terms before download).
- **Lindenthal camera traps**: one 213 GB zip.

**Mammals and birds.** For this answer of **What do you want to watch?** the app suggests
MegaDetector V6 (MDV6), which finds animals, people and vehicles. For names it suggests
BioCLIP 2 with the name list *Mammals and birds of the world*. For a shorter list of the
expected mammals or birds, build your own BioCLIP label pack with `bioclip_export/` of
[fauna-pulse-models](https://github.com/valentinitnelav/fauna-pulse-models)
([IDENTIFICATION.md](IDENTIFICATION.md)). The occlusion tolerance and minimum track length then
need values that suit larger, slower animals.

## 7. Resolution

The analysed area of an imported video is scaled down to the model's input size, a few hundred
pixels. Choosing a square under **Area to analyze** ([§1, step 2](#step-2-find-animals-in-videos)) is the way to give small
insects more pixels.

Videos recorded by the app itself (**Save bursts as**: **Video (MP4), find animals later**)
are the camera's square at the **Saved photo side (px)**, 1024 px by default. A full-sensor path
follows only if tests show that 1024 px limits detection or identification.
