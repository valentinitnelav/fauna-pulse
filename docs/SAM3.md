# SAM 3 as a slow "AI later" detector (sam3 branch, round 257)

Status: **experimental, not for release.** SAM 3 runs on the PC today; on the test Xiaomi it
loads but its GPU computes the picture model wrongly (details below).

## What SAM 3 is

SAM 3 ("Segment Anything with Concepts", Meta, November 2025) finds every object that matches
a short English prompt ("insect", "bee") in a picture, without training on your data. It is
about 840 million numbers (parameters), roughly 30 times BioCLIP's work per picture, so it is
meant for analysing saved videos afterwards, never for the live camera.

The files used here are the LiteRT conversion by mlboydaisuke on Hugging Face,
`mlboydaisuke/SAM3-LiteRT` (SAM License: use and redistribution allowed with the license text,
"Built with SAM" in publications). They stay out of git and out of the app package.

| File | Size | Job |
|---|---|---|
| `sam3_vision.tflite` | 930 MB | picture (1008 x 1008) to image features; the slow part |
| `sam3_text.tflite` | 607 MB | prompt to "text memory"; once per new prompt |
| `sam3_head.tflite` | 68 MB | features + text memory to 200 candidate boxes, scores and a "prompt is in the picture" (presence) score |
| `sam3_token_embed.bin`, `vocab.json`, `merges.txt` | 103 MB | the tokenizer (turns the prompt into numbers) |

A candidate's probability is score x presence. There is no class list: the class name of every
box is the prompt.

## In the app

- **Run AI on videos** lists "SAM 3 (finds what you name; slow)" when the files are in the app's
  private folder `files/sam3/`, with a "What to find" field (default `insect`, stored as
  `video_analysis_sam3_prompt`). The prompt is saved with the run (`settings.prompt`,
  `model_name` "SAM 3, prompt "insect""); a changed prompt asks before replacing results.
  Tracking, track IDs, the Video tab and the summary are unchanged.
- Native side: `Sam3Detector.kt` (+ `ClipTokenizer.kt`), channel methods `sam3Load`,
  `sam3DetectFile`, `sam3Close`, and `videoOpen` with `detector: "sam3"`.
- **Picture model in parts.** Setting the whole 930 MB model up on the Xiaomi's GPU took the app
  to about 5 GB and Android closed it. `tool/sam3/split_tflite.py` cuts it between transformer
  blocks, where only one tensor is passed on, into `sam3_vision_part1..4.tflite`; the parts give
  exactly the same numbers (checked on the PC: largest difference 0). With parts the model
  loads (42 s); the app then holds about 4.2 GB, because each part keeps its own GPU working
  memory.
- **Prompt memory.** `files/sam3/prompts/<token numbers>.f32` keeps each encoded prompt, so the
  text model (about 2 GB of memory for a few seconds) only runs for a new prompt.
  `tool/sam3/make_prompts.py` makes these files on the PC.
- `android:largeHeap` is on: each picture moves 111 MB of features through Java arrays.

Copying the files to a debug build (no import screen yet):

```bash
adb shell mkdir -p /data/local/tmp/sam3
adb push sam3_vision_part*.tflite sam3_head.tflite sam3_text.tflite sam3_token_embed.bin \
  vocab.json merges.txt LICENSE prompts /data/local/tmp/sam3/
adb shell 'run-as com.faunapulse.app sh -c "mkdir -p files/sam3 && cp -r /data/local/tmp/sam3/* files/sam3/ && chmod -R go-rwx files/sam3"'
adb shell rm -rf /data/local/tmp/sam3
```

Device check: `integration_test/sam3_check_test.dart` (compares the phone with the PC on one
frame).

## Measured on the Xiaomi (Mi 11 Lite 5G, Adreno GPU, 7.4 GB), 2026-09-30

| | Result |
|---|---|
| Whole picture model on the GPU | app closed by Android while setting up (about 5 GB), LiteRT 2.1.5 and 2.2.0 |
| Picture model in 4 parts, GPU | loads in 42 s; 9.6 s per picture; **all numbers NaN** from part 1 on |
| Same with LiteRT 2.2.0, 32-bit adding up, or overflow clamping | still all NaN |
| Head on the CPU (4 threads) | 7.2 s per picture |
| Text model on the CPU | about 3 s, peak about 2 GB |

The model card verified a Pixel 8a (Mali GPU) and an iPhone. On this Adreno GPU something in the
first transformer blocks goes wrong; finding which operation needs an operation-by-operation
comparison with the PC (next step). The app therefore stops a SAM 3 run with a plain message as
soon as a picture gives NaN. The phone's CPU is no way out: minutes per picture and more memory
than the phone has.

## On the PC (works)

`tool/sam3/detect_video.py` runs the same files on the PC's CPU (about 40 s per picture on a
4-core laptop) over exactly the frames of an earlier "Run AI on videos", and writes the app's
`video_detections.jsonl`. The app's own tracker then counts track IDs, either in the app ("Find
track IDs" after copying the session folder back) or on the PC:

```bash
python tool/sam3/detect_video.py SESSION_COPY --sam3-dir DIR --prompt insect --confidence 0.5 --fps 1
flutter test test/fauna_pulse/video_fps_sweep_test.dart --dart-define=SWEEP_SESSION=SESSION_COPY/sam3 \
  --dart-define=SWEEP_FPS=1 --dart-define=SWEEP_OCCLUSION=3 --dart-define=SWEEP_MIN_S=1
```

(`SESSION_COPY/sam3` needs the session's `session.jsonl` next to the new file.)

## Results on the test videos (2026-09-30)

These clips are YouTube compilations, not hand-counted field videos: the numbers compare two
models on the same frames, they say nothing about accuracy. Both models saw exactly the same
frames and square; track IDs come from the app's own tracker with the settings of the earlier
ArthroNat run (ByteTrack, occlusion tolerance 3 s). Prompt `insect`.

| Clip, frames | ArthroNat flatbug YOLO11n int8 (phone) | SAM 3 (PC) |
|---|---|---|
| bumblebee on a flower, 6 s, 30 frames (5 per s), confidence 0.25, min. track 0.5 s | 2 track IDs (one bee split in two); 1 to 4 boxes per frame; a box on the empty flower at the end | **1 track ID** (0 to 5.1 s); exactly 1 box per frame while the bee is there, none after it left (presence 0.02) |
| Pollinators, 14 min, 836 frames (1 per s), confidence 0.5, min. track 1 s | 52 track IDs (50 at 5 per s, as on the phone) | stopped after 358 frames (4 h, laptop too hot) |
| Bumblebees, 13 s, 3 scenes with one bee each, then 2 s without; 14 frames (1 per s), confidence 0.5, min. track 1 s | 1 track ID (9.9 to 11.9 s; also 1 at 5 per s on the phone); bee boxed in 3 of 13 frames, 4 more boxes elsewhere (flowers) | **3 track IDs**, one per scene; bee boxed in all 13 frames that show it, nothing in the last frame |

The phone's own "Find track IDs" on a copy of the first session with SAM 3's boxes
(`video_20260929_2_sam3_pc`) also gave 1 track ID. Results and run output: `~/SAM3/runs/`
(outside git; the Bumblebees session is `bumblebee-2`, with `compare_1fps.jpg` showing every
model's boxes on the same frames).

## EfficientSAM3 (tried on the PC, round 258): does not find the bees

EfficientSAM3 (University of Bristol, Apache-2.0) is SAM 3 "distilled" into small models: a
small picture model and a small text model were trained to copy SAM 3's answers, and SAM 3's
box-finding part was kept. The three full models are on Hugging Face
(`Simon7108528/EfficientSAM3`, folder `efficientsam3_ft/`, about 470 MB each as 32-bit numbers,
no login needed); the code is on GitHub (`SimonZeng7108/efficientsam3`). Tried: **EV-M**
(EfficientViT-B1 picture model, MobileCLIP-S0 text model, 89 million numbers, 10 times fewer
than SAM 3). SAM 3's own `sam3.pt` is not needed.

- Speed: **about 4 s per picture** on the laptop (4 threads), against about 40 s for SAM 3.
- Bumblebees clip, the 67 frames the phone analysed (5 per s), prompt `insect`: **0 boxes at
  0.5**, 2 weak ones (0.1 to 0.2) in all 67 frames; "prompt is in the picture" (presence)
  0.01 to 0.19 throughout, although the bee is in view (often filling much of the picture) until
  about 12 s.
- Checks that the setup is not at fault: on the same two frames SAM 3 says 0.9 for `insect`,
  `bee` and `bumblebee`; EfficientSAM3 finds "leaf" at the same place as SAM 3 (so pictures and
  box coordinates are right) but not the bee with `bee` or `bumblebee` either; giving it SAM 3's
  own encoding of "insect" barely helps (0.09 to 0.15), so its picture model is the weak part.
  Shrinking the picture inside the 1008 px input lets it find the sunflower, not the bee.

So EV-M is fast enough for a phone but blind to bumblebees on this clip; no reason to convert
it for the phone. RV-M and TV-M (other picture models, same text model) were not tried.
`detect_video.py --efficientsam3 CKPT` runs any of the three.

## Next steps

1. Find the operation the Adreno GPU gets wrong: run vision part 1 in smaller pieces on the phone
   and compare each with the PC (its first steps are the "safe layer norm": scaling, sums over
   1024 channels, square root). Ask the conversion's author whether Adreno was tested.
2. A lighter model with the same prompts: EfficientSAM3 EV-M misses the bees (above); TV-M
   (TinyViT picture model) is the last cheap try before dropping EfficientSAM3.
3. A proper import screen for the files instead of adb, if SAM 3 ever runs on a phone.
