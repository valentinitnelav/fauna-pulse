# Video Analysis: from imported videos to checked visit counts

FaunaPulse can count flower visits in videos filmed elsewhere: the phone's own camera
app, a collaborator, or a published dataset. The AI runs afterwards ("AI later"), so the
phone does not need to detect live in the field. This guide covers the whole path, from
the import on the phone to a visit count that has been checked against a hand count
(round 230). The file formats are in [DATA_GUIDE §9](DATA_GUIDE.md#9-imported-videos-videos-video_detectionsjsonl-round-225);
the scripts are in [`tool/video_eval/`](../tool/video_eval/README.md).

Terms used below:

* **Track**: the tracker's record of one insect it followed from frame to frame. One
  track id = one **visit**.
* **Hand count** (also "ground truth"): the visits a person noted while watching the
  video. It is the reference the app is scored against.
* **fps**: frames per second. A phone video usually has 30. The app can look at fewer
  (*Frames analyzed per second*) to save time and heat.

## 1. The workflow

1. **Import**: home screen ⋮ → *Import videos…*. One session per site and day works
   best. Check the start time on the import sheet: visits per hour and the dashboard use
   it. Optionally, draw a square around the flower. The analysed area is scaled down to
   the model's input size, so a small insect in a whole 4K frame shrinks to a few pixels;
   a square keeps it large.
2. **Run AI on videos** (home screen): model, confidence threshold and *Frames analyzed
   per second* (default 15, the live AI's rate). This is the slow step (it can be paused
   and continued). It finds boxes only.
3. **Find visits** (same screen, starts by itself when the analysis finishes): links the
   boxes into tracks with the tracker chosen under the camera Settings (ByteTrack or
   C-BIoU), using the screen's *Occlusion tolerance* and *Minimum visit length*. It
   takes seconds and can be run again with other settings. With *Keep frames of each
   visit* on (the default, round 234) it then saves pictures of every visit from the
   clips, by the live photo rule: the first frame, then one every *Keep a frame every*
   (1 s) for up to *For up to* (10 s). They land in `roi_frames/` like live photos, show
   under the player on the summary's Video tab (*Show in video* jumps there) and are what
   *Identify organisms* reads. Saving reads each clip once; it can be stopped and
   continued with *Save the remaining frames*. Finding the visits again numbers them
   anew, so identification results made before say to run identification again.
4. **Share results**: one zip with `visits.csv` (one row per visit), `mot/` (every
   tracked box), `post_tracks.jsonl`, `video_detections.jsonl` and `session.jsonl`.
   Unzip it on the computer and keep the files together: the scripts below need them.
5. **Hand count** a sample of the clips (§3).
6. **Score** the app against the hand count with `evaluate_visits.py` (§4).

Videos in 10-bit or HDR (some newer phones film this way) are refused with a message;
re-export them as 8-bit H.264, for example with the phone's video editor or HandBrake.

A video missing from the file window? Its **Downloads** view lists only files Android
marked as downloads. A clip saved by another app (for example WhatsApp) and then moved into
the Download folder is missing there. Tap ☰ in the file window and choose **Videos**, or
the phone's name and then the same folder: the clip is listed there. The app shows this
tip when the file window is closed without a choice.

## 2. What the app counts as a visit

Count by hand with the same rule, or the comparison measures the rule and not the AI:

* A visit starts when the insect is first detected in the analysed area and ends when it
  was last seen there. If it hides or leaves for **longer than the occlusion tolerance**
  (3 s by default) and comes back, that is a new visit. Shorter gaps stay one visit.
* Visits shorter than the **minimum visit length** (0.2 s by default) are not counted.
* The app sees an insect *in the picture*, not *on the flower*. Whether an insect that
  only flies through counts is your decision. For scoring the app, count every insect
  that appears in the analysed area; flower contact can be a second column.
* A visit that runs on into the next clip (clips recorded back to back) is one visit.
  Note it once, in the clip where it began, with its end time on that clip's clock (so
  the end can exceed the clip's length). The app does the same.
* `start_s` and `end_s` are seconds from the start of the clip, the position a video
  player shows.

## 3. Counting by hand

Watch without looking at the app's results first, ideally by someone who did not choose
the settings: knowing the answer changes what one sees. Pick clips across conditions
(sun and shade, wind, busy and quiet flowers) and include clips **without** visits: they
show how often the app counts leaves, shadows or flowers as insects.

### 3a. Visit counts (what the app claims): spreadsheet or BORIS

No need to annotate every frame. Watch at normal or double speed, pause when an insect
arrives and note its start and end time.

* **Spreadsheet**: copy [`hand_count_template.csv`](../tool/video_eval/hand_count_template.csv).
  Columns `clip, start_s, end_s, taxon`; add your own columns (the script ignores them).
  Times in seconds (`65.0`) or as the player shows them (`1:05.0`). The clip name may be
  the name before the import (`VID 1.mp4`) or inside the app (`VID_1.mp4`). A row with
  a clip and no times says "watched, no visit". Comma, semicolon or tab separated.
* **[BORIS](https://www.boris.unito.it/)** (free event-logging software for behavioural
  coding, Friard & Gamba 2016, *Methods in Ecology and Evolution* 7: 1325–1330):
  * In the ethogram, add a **state** behaviour "visit" (one key starts it, the same key
    stops it). Point events work too, for a quick "insect here" mark; the script widens
    them by the tolerance (§4).
  * Subjects can be the taxa (Apis, Bombus, Syrphidae…); the script reads the subject as
    the taxon, or the behaviour when there is no focal subject.
  * **One observation per video.** BORIS counts time over the whole observation, not per
    video, so an observation with two videos would give wrong times. The script refuses
    such exports. Keep the observation's **time offset at 0**.
  * Export: *Observations → Export events → Aggregated events*, as CSV or TSV
    ([BORIS user guide](https://www.boris.unito.it/user_guide/export_events/)). One
    BORIS version failed when exporting only some behaviours
    ([issue 747](https://github.com/olivierfriard/BORIS/issues/747)): export all and
    choose with the script's `--behavior visit`.

### 3b. Boxes and tracks (optional)

Only needed to score the tracker frame by frame (for example, how often a track id jumps
to another insect). Visit counts do not need it.

* Annotate **keyframes**, not every frame: in [CVAT](https://www.cvat.ai/)'s track mode,
  draw the box every 10th–15th frame and let CVAT fill in the frames in between. Score on
  the keyframes only.
* Start from the app's boxes instead of an empty video:
  `python3 tool/video_eval/mot_to_cvat.py <unzipped results>` writes one zip per clip.
  In CVAT, create a task from the same video file, with the labels the script prints,
  then *Actions → Upload annotations → MOT 1.1*. Correct the boxes, add what the app
  missed and set the taxon. Each visit's first frames are missing: a track shows up only
  once confirmed (after the minimum visit length).
* A script for box-level scores (HOTA, IDF1 with
  [TrackEval](https://github.com/JonathonLuiten/TrackEval)) will be added when these
  annotations exist. `mot/` is already in the format TrackEval reads.

### 3c. Annotation helpers, and what not to use

* **[SAM 3](https://github.com/facebookresearch/sam3)** (Meta, 2025) follows every
  object matching a text prompt ("bee") through a video. It needs a computer with a
  graphics card (GPU).
* CVAT and X-AnyLabeling offer **point-and-click boxes and tracking** based on SAM
  models; which ones depends on the version and plan.
* These are AI too: a person must check every box they draw before it counts as a hand
  count, or the app is scored against another AI's mistakes.
* **AI-generated videos** are fine to test that the pipeline runs, never to measure
  accuracy: the insects' look and movement are not real.

## 4. Scoring: `evaluate_visits.py`

```bash
cd fauna-pulse/tool/video_eval
python3 evaluate_visits.py --truth my_count.csv --app ~/results/site1/visits.csv \
    --out scores.csv --pairs pairs.csv
```

A hand-counted visit and an app visit **match** when they overlap in time, after the hand
count is widened by `--tolerance` seconds (0.5 by default) on each side, since clicks are
never exact. Each visit matches at most one other; the longest overlap goes first. Only
clips in the hand count are scored. The console shows one line per run:

| Number | Meaning |
|---|---|
| found | hand-counted visits the app also found |
| missed | hand-counted visits the app did not find |
| extra | app visits nobody counted (leaves, shadows, or one insect counted twice) |
| split | hand-counted visits overlapped by 2 or more app visits: one insect counted more than once, for example when it hid behind a petal for longer than the occlusion tolerance |
| merged | app visits overlapping 2 or more hand-counted visits: insects that followed each other closely, counted as one |
| recall | found ÷ hand-counted visits: the share of real visits the app found |
| precision | found ÷ app visits: the share of the app's visits that are real |
| count error | app visits − hand-counted visits |

Report recall and precision, not only the count error: 5 missed and 5 extra visits give a
count error of 0.

`--out` writes one row per run and clip, plus an `ALL` row per run. Its columns also hold
the total visit time (`true_visit_s`, `app_visit_s`), the mean duration error (app minus
hand count, only for visits with a duration) and the median start error (positive = the
app starts later). `--pairs` writes every
visit with its status (`found`, `missed`, `extra`), to look at the misses in the video.
Both are tidy CSVs for R:

```r
library(ggplot2)
s <- read.csv("sweep_scores.csv")
s <- subset(s, clip == "ALL")
ggplot(s, aes(fps, recall, colour = tracker)) + geom_line() + geom_point() +
  scale_x_log10() + labs(x = "frames analyzed per second", y = "share of visits found")
```

## 5. Which frame rate is enough? The sweep

More frames per second find short and fast visits and keep fast insects on one track, but
cost time and heat on the phone. Two published systems show both ends:

* Bjerge et al. (2021, *Remote Sensing in Ecology and Conservation*,
  [doi:10.1002/rse2.245](https://doi.org/10.1002/rse2.245)) tracked insects in time-lapse
  images at 0.33 fps and counted a track only with at least two detections.
* Sittinger et al. (2024, *PLOS ONE*,
  [doi:10.1371/journal.pone.0295474](https://doi.org/10.1371/journal.pone.0295474))
  tracked live at about 12.5 fps (1080p) or 3.4 fps (4K) and note that too low a rate
  makes the track ids of fast-moving insects "jump", so one insect is counted more than
  once.

Instead of guessing, measure it on your own videos: detect once at the full rate, then
re-run only the tracker on every 2nd, 3rd, 6th… frame, and compare each result with the
hand count.

1. **On the phone**: *Run AI on videos* with *Frames analyzed per second* at the video's
   own rate (30 for most phone videos). This takes about twice as long as 15, once.
   Then *Find visits* with the settings you want to test, and *Share results*.
2. **On the computer** (needs this repository and Flutter, like the app's tests):

   ```bash
   cd fauna-pulse
   flutter test test/fauna_pulse/video_fps_sweep_test.dart \
       --dart-define=SWEEP_SESSION=$HOME/results/site1 \
       --dart-define=SWEEP_FPS=15,10,5,2,1
   ```

   For each rate and both trackers, this runs the app's own tracking code on the frames a
   run at that rate would have looked at (the same frame-picking rule as the phone) and
   writes `fps_sweep/visits_<tracker>_<fps>fps.csv`. The occlusion tolerance and
   minimum visit length (in seconds) are those of the last *Find visits*, so every rate is
   compared under the same rule.
3. **Score** all runs at once:

   ```bash
   python3 tool/video_eval/evaluate_visits.py --truth my_count.csv \
       --app "$HOME/results/site1/fps_sweep/visits_*.csv" --out sweep_scores.csv
   ```

Analyse at the video's full rate: thinning a 15 fps analysis to 10 fps would give
unevenly spaced frames that no real 10 fps run would use. At low rates, keep the occlusion
tolerance well above the time between two analysed frames (2 s at 0.5 fps), or every
visit breaks into pieces.

## 6. Where to get videos

No widely used flower-visitor video set with human-annotated tracks turned up in the
search for this guide (September 2026), so your own and collaborators' videos, counted
as in §3, are the realistic source. Useful public material:

| Data | What it holds | Use here |
|---|---|---|
| [HyDaT](https://github.com/malikaratnayake/HyDaT_Tracker) | 78 min of honeybee video, with tracks made by an algorithm, not by people | good footage; count the visits yourself |
| BuzzSet, BuzzSpot | pollinator images with boxes | detection only (no video) |
| [Zenodo 15096610](https://doi.org/10.5281/zenodo.15096610) (own) | time-lapse images: expert-labelled Hymenoptera and Diptera crops, and insect-free backgrounds (CC BY-NC-SA) | detection and identification, not tracking |
| [SA-FARI](https://huggingface.co/datasets/facebook/SA-FARI) ([about](https://www.conservationxlabs.com/sa-fari)) | 11,609 camera-trap videos of 99 species, boxes and track ids at 6 fps (CC BY-NC; accept the terms before download) | mammals and birds, see below |
| [Lindenthal camera traps](https://lila.science/datasets/lindenthal-camera-traps/) | camera-trap videos in RealSense files (one 213 GB zip) | mammals, second choice |

**Mammals and birds**: the app's default detector, MegaDetector V6 (MDV6), finds
animals, people and vehicles. For names, build a BioCLIP label pack of the expected
mammals or birds with `tool/bioclip_export/` ([IDENTIFICATION.md](IDENTIFICATION.md)).
The occlusion tolerance and minimum visit length then need values that suit larger,
slower animals.

## 7. Resolution

The analysed area of an imported video is scaled down to the model's input size, a few
hundred pixels. Drawing a square on import (§1) is the way to give small insects more
pixels. For
videos recorded by the app itself (planned), version 1 records the square at the size of
today's saved photos (1024 px on the test phone); a full-sensor path follows only if
tests show that 1024 px limits detection or identification.
