# How the app saves sharp photos from a small on-screen ROI

Last updated: round 65 (2026-07-03).

## The puzzle

On the recording screen the ROI (the draggable square you place over the
flower) might read, say, **416×416 px**, yet the photos on the computer are
**1024×1024** and genuinely sharp, not blown up. Where do the extra pixels
come from?

## The key idea: one camera, two different image streams

The current implementation allows the phone camera to produce two image "feeds", and they serve two different jobs:

1. **The live analysis stream** — a smaller, but faster resolution video feed (e.g. 1080×1440, 
   capped by the Hardware Abstraction Layer - HAL).
   The Xiaomi test phone can deliver this stream up to ~30 times per second (~ 30 FPS). 
   The motion check, AI detector, and the preview on the screen all run on this. 
   The detector also shrinks further every frame of the live stream to its input resolution 
   (e.g. 320x320 or 640×640 px). 
   Big video frames (e.g. 3000x4000, 12 MP) would only overheat the phone 
   (heat is a significant limit in the field).

2. **The full-resolution still** — the same thing that happens when you press
   the shutter in the normal camera app - e.g. a single 12-megapixel photo
   (3000×4000). It takes ~1 second and briefly costs some processing,
   so it can't run 30×/s.
   Because this is slower, it should be avoided. This gets activated in two ways:
   Session settings > Camera > ROI photo source ... > Auto ... or Full-resolution stills always options.
   On Auto, whenever the ROI is under the desired threshold (e.g. < 1024x1024 px),
   the app will default to capturing a higher resolution still (at the desired threshold of 1024x1024 px),
   cropped with the ROI relative coordinates.
   So, try to adjust the distance between the flower so that the ROI square stays within the desired resolution
   within the live analysis stream.

Both streams look at **the same scene through the same lens**. The ROI box is
stored relative to the frame. The same fraction can be cut out of either stream
resulting is saving images (ROI cropped) at different resolutions.

```
      live analysis stream                full-resolution still
      (the preview / on screen)           (slower to crop & store ~ 1 sec)
      1080 × 1440 px                       3000 × 4000 px
      ┌──────────────┐                    ┌────────────────────┐
      │     ROI      │                    │                    │
      │   ┌────┐     │    same box,       │       ┌─────┐      │
      │   │ ▒▒ │ 30% │    same flower     │       │  ▒▒ │ 30%  │
      │   └────┘     │       →            │       └─────┘      │
      │  = 360 px    │                    │       = 1000 px    │
      └──────────────┘                    └────────────────────┘
```

See also:
- https://developer.android.com/media/camera/camera2/multiple-camera-streams-simultaneously

## What the app does with this ("auto" mode)

For every scheduled photo the app asks: *would cutting the ROI box out of the
live frame meet the user's target size (e.g. 1024 px)?*

- **Yes** (the ROI box is large on screen) → cut from the live frame. Little costs, 
  so no significant camera interruption.
- **No** (the ROI box is small — a small flower) → take a full still and cut the
  box out of that instead. Costs ~1 s and a brief frame-rate dip, but the
  photo meets the target.

Photos larger than the target are shrunk to exactly the target (storage
control). Photos are not enlarged: stretching a small image invents no
detail, it only makes a blurry image with more pixels, which would actively
mislead the insect classifier later. If even the full still can't reach the
target (the box is a very small fraction of the frame), the app saves the
best it can and shows **⚠ below N px** — the only real fixes are physical:
move the phone closer or switch to the telephoto lens.

## Reading the on-screen label

`ROI: 416×416 px → saves 1024×1024 (still)`

- **416×416** — the box's size measured on the live stream (the picture you
  are looking at). This number moves smoothly as you drag, and its scale
  never changes.
- **saves 1024×1024** — the size of the JPEG that will actually be written.
- **(still)** or **(fast)** — which stream the photo will be cut from.
- **⚠ below 1024 px** — appears when even the still can't reach the target.

## Where each number lands in the session file (`session.jsonl`)

| Field | Record | Meaning |
|---|---|---|
| `targetRoiSavedPx` | `start_of_session` → `config` | The user's target side (e.g. 1024) |
| `saved_px` | each `capture` | Exact side of that JPEG|
| `path` | each `capture` | `"still"` or `"fast"` - which stream it was cut from |
| `roi` + `roi_source` + `saves_px` | `start_of_session`, `roi_update` | Box geometry, the stream it refers to, and the predicted file side |
| `camera_full_*` / `analysis_frame_*` | `start_of_session` | The two stream sizes, upright |

For any analysis of image resolution, **trust `saved_px` in the capture
records**. It is computed with the same arithmetic the crop itself uses.

## Two honest costs of the "still" path (logged, not hidden)

1. **Timing**: a still lands a fraction of a second after the detection that
   requested it, so a fast-moving insect may have shifted slightly relative
   to the logged bounding box. Each capture record's `total_ms` documents the
   delay.
2. **Frame-rate dip**: the detector briefly sees fewer frames around each
   still. Visitation statistics are unaffected (they come from detections,
   not photos).

## Technical footnote

All crops snap their side length to a multiple of 32 pixels (friendlier for
vision models) and every size shown or logged is computed by the same shared
functions (`savedSidePx`, `capSavedSidePx`, `chooseCapturePath` in
`lib/fauna_pulse/capture/roi_capture.dart` — unit-tested). Stills arrive from
the camera *unrotated*; the crop is mapped into the raw orientation and only
the small cropped square is rotated upright (`rawRectForUprightRect`) — this
is why taking a photo no longer freezes the app.
