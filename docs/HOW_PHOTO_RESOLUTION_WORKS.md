# How the app saves sharp photos from a small on-screen ROI

This page explains why a small ROI (the yellow square on the camera screen) can still save a
large, sharp photo, and how to choose where each photo comes from. It is for everyone who
records with FaunaPulse. Details for researchers and developers are at the end of the page; the
most technical parts are folded: click a line that starts with ▸ to open it.

> **In short**
>
> - The camera gives two pictures of the same scene: a small, fast live stream (for the screen
>   and the AI) and a slow, full-resolution high-res photo.
> - The ROI box is stored as a fraction of the frame, so the same box can be cut from either
>   picture. Cut from the high-res photo, it has many more pixels.
> - The default is **fast crops**: every photo is cut from the live stream. No pause, and the
>   photo shows the exact moment of the detection.
> - **Auto** takes a high-res photo only when a fast crop would be smaller than your target size
>   (for example 1024 px). High-res photos pause detection briefly and are often blurred.
> - Photos are shrunk to the target size, never enlarged. If the ROI line shows **⚠ below N px**,
>   move the phone closer or use the telephoto lens.

**Contents**

- [The puzzle](#the-puzzle)
- [One camera, two image streams](#one-camera-two-image-streams)
- [Choose the photo source](#choose-the-photo-source)
- [Why fast crops are the default](#why-fast-crops-are-the-default)
- [Photo size: shrunk, never enlarged](#photo-size-shrunk-never-enlarged)
- [Read the ROI line on the camera screen](#read-the-roi-line-on-the-camera-screen)
- [Two costs of the high-res path](#two-costs-of-the-high-res-path)
- For researchers and developers:
  [Where each number lands in the session file](#where-each-number-lands-in-the-session-file-sessionjsonl),
  [Technical footnote](#technical-footnote)

## The puzzle

On the camera screen, the ROI (the square you drag over the flower) might read, say,
**416×416 px**. Yet the photos on the computer are **1024×1024** and really sharp, not blown up.

Where do the extra pixels come from? The answer: the phone camera can produce two different
pictures of the same scene: a continuous live stream and, on request, a full-resolution photo.

## One camera, two image streams

The app lets the phone camera produce two image "feeds". They serve two different jobs.

**1. The live analysis stream.** A smaller but faster video feed, for example 1080×1440 px. Its
size is capped by the phone's camera software (its Hardware Abstraction Layer, HAL).

- The Xiaomi test phone can deliver this stream up to about 30 times per second (about 30 FPS).
- The motion check, the AI detector and the preview on the screen all run on this stream.
- The detector shrinks every frame further, to its own input size (for example 320×320 or
  640×640 px).
- Big video frames (for example 3000×4000, 12 MP) would only overheat the phone. Heat is a
  significant limit in the field.

**2. The high-res photo (full resolution).** This is what happens when you press the shutter in
the normal camera app: for example one 12-megapixel photo (3000×4000).

- It takes about 1 second and briefly costs some processing, so it cannot run 30 times per
  second.
- Because it is slower, it is best avoided. You can turn it on with the **ROI photo source**
  setting (see [Choose the photo source](#choose-the-photo-source)).

Both streams look at **the same scene through the same lens**. The ROI box is stored relative to
the frame (as a fraction of it). The same fraction can be cut out of either stream, so the saved
ROI photos can have different resolutions.

```
 live analysis stream
 (the preview on screen)
 1080 × 1440 px
 ┌────────────┐
 │    ROI     │
 │  ┌────┐    │
 │  │ ▒▒ │30% │
 │  └────┘    │
 │ = 360 px   │
 └────────────┘
       ↓  same box, same flower
 high-res photo (full resolution)
 (slower to crop and store, ~1 s)
 3000 × 4000 px
 ┌──────────────────┐
 │                  │
 │     ┌─────┐      │
 │     │ ▒▒  │ 30%  │
 │     └─────┘      │
 │     = 1000 px    │
 └──────────────────┘
```

See also: [Android: use multiple camera streams at the same time](https://developer.android.com/media/camera/camera2/multiple-camera-streams-simultaneously).

## Choose the photo source

1. Open **Session settings**, then the **Photos** tab.
2. Set **Saved photo side (px)**: the target size of the square photos (default 1024, from 128 to
   2048, rounded to a multiple of 32).
3. Choose **ROI photo source**:

| Option in the app | Where each photo comes from |
|---|---|
| **Fast crops only (live frame)** (default) | Always cut from the live frame |
| **Auto (high-res only when needed)** | Live frame if big enough, else a high-res photo |
| **High-res photos always (full resolution)** | Always a high-res photo |

**Fast crops** (the default): every photo is cut from the live frame. Nothing stalls, and the
photo shows the exact trigger moment.

**Auto** asks, for every scheduled photo: *would cutting the ROI box out of the live frame meet
the user's target size (for example 1024 px)?*

- **Yes** (the ROI box is large on screen): cut from the live frame. It costs little, so there is
  no significant camera interruption.
- **No** (the ROI box is small, for example a small flower): take a high-res photo and cut the
  box out of that instead. This costs about 1 s and a brief frame-rate dip, but the photo meets
  the target. The high-res photo is cropped with the ROI's relative position (the same fraction
  of the frame).

**Tip:** adjust the distance between the phone and the flower so that the ROI square reaches the
target size within the live analysis stream. Then even fast crops meet the target.

## Why fast crops are the default

A high-res photo is not free:

- Taking one pauses the AI detection stream for 0.13 to 1.5 s (longer on older phones).
- The photo shows the scene a fraction of a second *after* the trigger.
- It often carries motion blur.

Blur destroys exactly the fine structure the extra pixels were supposed to capture. A blurred
1024 px photo holds less real detail than a crisp crop with fewer pixels. So for later
classification (naming the insect), "more pixels" is not automatically better.

Choose **Auto** or **High-res photos always** on purpose: when the flower is tiny in the frame
and the visitors mostly sit still.

## Photo size: shrunk, never enlarged

- **Larger than the target:** the photo is shrunk to exactly the target size (to keep storage
  under control).
- **Smaller than the target:** the photo is not enlarged. Stretching a small image adds no
  detail. It only makes a blurry image with more pixels, which would actively mislead the
  insect classifier later.
- **Even the high-res photo cannot reach the target** (the box is a very small part of the
  frame): the app saves the best it can and shows **⚠ below N px**. The only real fixes are
  physical: move the phone closer or switch to the telephoto lens.

## Read the ROI line on the camera screen

Example: `ROI: 416×416 px → saves 1024×1024 (high-res)`

| Part | Meaning |
|---|---|
| **416×416** | Box size on the live stream (the picture you see) |
| **saves 1024×1024** | Size of the JPEG that will really be written |
| **(high-res)** or **(fast)** | The source the photo will be cut from |
| **⚠ below 1024 px** | Even the high-res photo cannot reach the target |

The box size moves smoothly as you drag, and its scale never changes. When the box size and the
saved size are the same, the line shows only one number, for example `ROI: 1024×1024 px (fast)`.
Before the camera sizes are known, it shows `ROI: measuring…`.

## Two costs of the high-res path

Both are logged, not hidden.

1. **Timing.** A high-res photo lands a fraction of a second after the detection that asked for
   it. A fast-moving insect may have moved a little from the logged bounding box (the box
   around the insect). The `total_ms` of each capture record documents the delay.
2. **Frame-rate dip.** The detector briefly sees fewer frames around each photo. Visitation
   statistics are not affected: they come from detections, not photos.

## Where each number lands in the session file (`session.jsonl`)

For researchers who analyse the log.

Each item gives the field, the record it is in, and its meaning.

- `targetRoiSavedPx` (in `start_of_session` → `config`): the user's target side (e.g. 1024).
- `saved_px` (in each `capture`): exact side of that JPEG.
- `path` (in each `capture`): `"still"` or `"fast"`, the source it was cut from.
- `roi` + `roi_source` + `saves_px` (in `start_of_session` and `roi_update`): box geometry, its
  stream, predicted file side.
- `camera_full_*` / `analysis_frame_*` (in `start_of_session`): the two stream sizes, upright.

`"still"` in `path` means the high-res path. It is the FROZEN log name of that path, kept for
compatibility with all previously recorded sessions after the path was renamed (see *Page
history* below).

For any analysis of image resolution, **trust `saved_px` in the capture records**. It is
computed with the same arithmetic the crop itself uses.

## Technical footnote

<details>
<summary>Crop sizes, shared functions and rotation (for developers)</summary>

- **Multiple of 32.** All crops snap their side length to a multiple of 32 pixels (friendlier for
  vision models).
- **One set of functions.** Every size shown or logged is computed by the same shared functions:
  `savedSidePx`, `capSavedSidePx` and `chooseCapturePath` in
  `lib/fauna_pulse/capture/roi_capture.dart` (unit-tested).
- **Rotation.** High-res photos arrive from the camera *unrotated*. The crop is mapped into the
  raw orientation, and only the small cropped square is rotated upright
  (`rawRectForUprightRect`). This is why taking a photo no longer freezes the app.

</details>

<details>
<summary>Page history</summary>

- Last updated: round 65 (2026-07-03).
- Since round 117 the default photo source is **fast crops**.
- The high-res path was renamed from "still" in round 112; the log keeps the name `"still"`.

</details>
