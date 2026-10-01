# SAM 3 as a slow "AI later" detector (rounds 257 to 261, parked)

Status: **parked 2026-09-30 (round 261), not for release.** The code (`Sam3Detector.kt`,
`ClipTokenizer.kt`, `models/sam3_model.dart`, the "What to find" field, `tool/sam3/`,
`integration_test/sam3_check_test.dart`) is on branch `sam3` (tag `archive/sam3`); `develop` has
only this file and the changelog rounds. SAM 3 runs on the PC. On the test Xiaomi its GPU computes
the picture model wrongly (NaN), but its main processor (CPU) gives the PC's results, at 3.2 to
3.5 minutes per picture (round 259, details below). Why it is parked and when to reopen: see
"Verdict" at the end.

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

- **Find animals in videos** lists "SAM 3 (finds what you name; slow)" when the files are in the app's
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
frame). Its pictures go to `files/sam3_check/` the same way: `bumblebees_6s.jpg` (Bumblebees clip
at 6 s), `bumblebees_6s_1008.png` (the same, 1008 x 1008) and `onflower_3s.jpg`. They are frames of
the YouTube test clips, so they are not in git (the owner keeps a copy); the PC numbers written in
the test belong to them. With other pictures, replace those numbers with a PC run of the same
files (ai-edge-litert on the CPU).

## Measured on the Xiaomi (Mi 11 Lite 5G, Adreno GPU, 7.4 GB), 2026-09-30

| | Result |
|---|---|
| Whole picture model on the GPU | app closed by Android while setting up (about 5 GB), LiteRT 2.1.5 and 2.2.0 |
| Picture model in 4 parts, GPU | loads in 42 s; 9.6 s per picture; **all numbers NaN** from part 1 on |
| Same with LiteRT 2.2.0, 32-bit adding up, or overflow clamping | still all NaN |
| Head on the CPU (4 threads) | 7.2 s per picture |
| Text model on the CPU | about 3 s, peak about 2 GB |
| **Picture model and head on the CPU, one part at a time (round 259)** | **correct: same probabilities as the PC to 3 decimals** (0.911, 0.529, 0.268), boxes overlap 96 to 99.5 %; **3.2 to 3.5 min per picture** (4 parts: 17 to 26 s to load plus 17 to 32 s to run each, head 18 to 20 s); app peak 4.4 GB |

The model card verified a Pixel 8a (Mali GPU) and an iPhone. On this Adreno GPU something in the
first transformer blocks goes wrong; finding which operation needs an operation-by-operation
comparison with the PC (next step). The app therefore stops a SAM 3 run with a plain message as
soon as a picture gives NaN, which now says to switch off "Use GPU when faster".

**The CPU route (round 259).** With the GPU switched off (`useGpu = false`, which "Run AI on
videos" takes from "Use GPU when faster") and the picture model in parts, `Sam3Detector.kt`
loads one part, runs it, closes it, then the next; the head is loaded only after the four parts
and closed after each picture. Memory measured: on the PC (ai-edge-litert, CPU) all 4 parts at
once need 5.0 GB, the whole model 3.9 GB, one part about 1 GB, the head about 1.4 GB; on the
Xiaomi (LiteRT CompiledModel) the head alone took the app to 3.5 GB. A first try that kept the
head loaded while the parts ran was closed by Android at part 4 (2.1 GB in memory plus 4.6 GB
swapped out). Even at 4.4 GB, Android closes background apps to make room (its log shows about 130 and
220 closings in the two tries). About 80 s of each picture is reloading the parts (the CPU
library rearranges the weights at every load). Check: `sam3_check_test.dart` with
`--dart-define=SAM3_CPU=true`. The Bumblebees clip at 1 picture per second (14 pictures) would
take about 45 to 50 minutes on the phone (estimate).

## On the PC (works)

**Independent check with Meta's original weights, following the InsectAI Model Zoo (round 259).**
Hugo Markoff's InsectAI Model Zoo (COST Action CA22129 InsectAI;
github.com/HugoMarkoff/Insect_model_zoo) collects insect models behind one command line and
documents how to run SAM 3 on NVIDIA and Apple GPUs and on the CPU: Meta's `sam3.pt` (pinned by
checksum) through the SAM 3 implementation in Ultralytics (`SAM3SemanticPredictor`), 1008 px,
confidence 0.5, overlap 0.5, 16-bit numbers on NVIDIA GPUs; its README gives about 40 s per
picture on a CPU. Run unchanged on this laptop (`main.py -m sam3 -c none -p insect -d cpu`, our
`sam3.pt` has the zoo's checksum, 4 threads): **about 41 s per picture**, peak 7.1 GB (it pushed
about 3.5 GB of open programs into swap). On 3 Bumblebees frames its bee boxes match the LiteRT
file's within 1 to 4 pixels, with slightly higher probabilities (0.80 to 0.88 against 0.73 to
0.84, the LiteRT file is 16-bit); it also boxed a small object on a sunflower petal (0.56) and
part of a bee (0.55). It covers desktop computers only, no phones; the zoo code has no licence
file, so nothing of it is copied into FaunaPulse (it is only run and cited). SAM 3 itself:
Carion et al. (2025), arXiv:2511.16719, SAM License.

`tool/sam3/detect_video.py` runs the same files on the PC's CPU (about 40 s per picture on a
4-core laptop) over exactly the frames of an earlier "Find animals in videos", and writes the app's
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
| Bumblebees, 13 s, 3 scenes with one bee each, then a fourth whose bee flies off at 12.5 s (between two of the 1-per-s frames, so it is never seen here); 14 frames (1 per s), confidence 0.5, min. track 1 s | 1 track ID (9.9 to 11.9 s; also 1 at 5 per s on the phone); bee boxed in 3 of 13 frames, 4 more boxes elsewhere (flowers) | **3 track IDs**, one per scene; bee boxed in all 13 frames that show it, nothing in the last frame |

The phone's own "Find track IDs" on a copy of the first session with SAM 3's boxes
(`video_20260929_2_sam3_pc`) also gave 1 track ID. Results and run output: `~/SAM3/runs/`
(outside git; the Bumblebees session is `bumblebee-2`, with `compare_1fps.jpg` showing every
model's boxes on the same frames).

## EfficientSAM3 (tried on the PC, rounds 258 and 260): does not find the bees

EfficientSAM3 (University of Bristol, Apache-2.0) is SAM 3 "distilled" into small models: a
small picture model and a small text model were trained to copy SAM 3's answers, and SAM 3's
box-finding part was kept. The three full models are on Hugging Face
(`Simon7108528/EfficientSAM3`, folder `efficientsam3_ft/`, about 470 MB each as 32-bit numbers,
no login needed); the code is on GitHub (`SimonZeng7108/efficientsam3`). Tried: **EV-M**
(EfficientViT-B1 picture model, MobileCLIP-S0 text model, 89 million numbers, 10 times fewer
than SAM 3) and **TV-M** (TinyViT-11M picture model, same text model, 95 million numbers).
SAM 3's own `sam3.pt` is not needed.

- Speed: **about 4 s (EV-M) and 5 to 6 s (TV-M) per picture** on the laptop (4 threads), against
  about 40 s for SAM 3.
- **EV-M**, Bumblebees clip, the 67 frames the phone analysed (5 per s), prompt `insect`: **0
  boxes at 0.5**, 2 weak ones (0.1 to 0.2) in all 67 frames; "prompt is in the picture"
  (presence) 0.01 to 0.19 throughout, although a bee is in view (often filling much of the
  picture) until 12.5 s.
- Same frames with **TV-M** (round 260): **0 boxes at 0.5**, 24 weak ones (0.10 to 0.26) in 17
  of the about 60 frames with a bee; presence 0.01 to 0.41. Most weak boxes sit on the bee
  (overlap with SAM 3's bee box 56 to 94 %), so it finds the place but is never sure. Prompts
  `bee` and `bumblebee` do no better.
- **The presence score is what fails, and leaving it out does not help** (round 260). Each box
  has its own score, which is multiplied by presence. On 4 bee frames TV-M's best box scores 0.52 to
  0.65 and sits on the bee; but on the 5 frames after the bee flew off (12.6 to 13.4 s), its best
  box scores 0.65 to 0.67 (EV-M: 0.47 to 0.54), just as high. Without presence, both models would
  box something in every frame, bee or not.
- Checks that the setup is not at fault: on the same two frames SAM 3 says 0.9 for `insect`,
  `bee` and `bumblebee`; EV-M finds "leaf" at the same place as SAM 3 (so pictures and
  box coordinates are right) but not the bee with `bee` or `bumblebee` either; giving it SAM 3's
  own encoding of "insect" barely helps (0.09 to 0.15), so its picture model is the weak part.
  Shrinking the picture inside the 1008 px input lets it find the sunflower, not the bee.

So EV-M and TV-M are fast enough for a phone but blind to bumblebees on this clip; no reason to
convert them for the phone. RV-M (RepViT picture model, same text model) was not tried: both
picture models tried fail in the same way, so it is not worth a third 480 MB download.
`detect_video.py --efficientsam3 CKPT` runs any of the three.

## Verdict (round 261) and when to reopen

Parked, not abandoned: SAM 3 finds bees that the fast models miss (results above), but on today's
phones it is far too slow to analyse videos.

- Phone speed, best case: if the GPU problem were solved, about 10 to 17 s per picture (picture
  model 9.6 s on the GPU, head 7.2 s on the CPU), with 1.7 GB of files and about 4.2 GB of
  memory. A 1-minute clip at 1 picture per second would take about 17 minutes. On the CPU (works
  today) about 3.3 minutes per picture, or about 2 with the speed-up below: 2 to 3 hours for the
  same minute. So at best it could re-check a few saved pictures; it cannot scan videos.
- The fast variant, EfficientSAM3 (EV-M, TV-M), is blind to the bees (above).
- Mammals were not tried. Larger animals are probably easier than small insects, but camera-trap
  detectors already find animals at YOLO speed, so for mammals a model swap is the likelier route.

Reopen when one of these happens:

- a newer phone: more memory, or a GPU on which the conversion gives correct numbers (its model
  card verified a Pixel 8a, Mali GPU, and an iPhone);
- a LiteRT or conversion update that fixes the Adreno NaN;
- a smaller SAM-like model that finds insects;
- a PC with a proper GPU, to use SAM 3 there as a reference or to box insects for training the
  fast models (`tool/sam3/detect_video.py` already writes the app's detection file).

Cheapest first check on a new phone (about 10 minutes): a debug build of branch `sam3`, the files
copied as above, then `sam3_check_test.dart`, first as it is (GPU), then with
`--dart-define=SAM3_CPU=true`. It compares the phone with the PC on one picture and logs load
times, run times and memory.

To resume in git: `git switch sam3 && git merge develop` (brings the newer app code); on
conflicts under `docs/`, keep `develop`'s version.

## If reopened

1. Find the operation the Adreno GPU gets wrong: run vision part 1 in smaller pieces on the phone
   and compare each with the PC (its first steps are the "safe layer norm": scaling, sums over
   1024 channels, square root). Ask the conversion's author whether Adreno was tested. The GPU
   would be about 20 times faster than the CPU route (9.6 s against about 3 minutes).
2. Speed up the CPU route: run each part over several pictures before loading the next (saves
   most of the 80 s of reloading), or let the CPU library keep its rearranged weights in a file
   (XNNPACK weight cache; needs a guard against a half-written file).
3. A proper import screen for the files instead of adb, if SAM 3 ever runs on a phone.
