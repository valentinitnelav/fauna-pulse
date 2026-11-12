# Performance benchmarking protocol

How to measure FaunaPulse performance so that two runs can be compared
honestly, and how to decide whether an optimization is real. Every claim of
better speed, heat or power needs numbers made this way.

Phone performance is noisy: the same app, phone and scene can differ by 10%
between two runs, only from the starting temperature, background work of the
system, or sun on the case. This protocol makes a "5% faster" claim mean
something.

## The golden rules

1. **Never quote debug-build numbers as phone speed.** A `flutter run` or
   debug APK is clearly slower than a release build (round 132). Compare debug
   numbers only with debug numbers from the same binary.
2. **Never compare different binaries.** Each session's start record has
   `app_version`, `app_build` and `build_mode`; `tool/perf_summary.dart`
   prints them, so mixed binaries are visible.
3. **Power and energy numbers are valid only unplugged** (round 84): while
   charging, the battery current measures charging, not use. The summary tool
   hides power and energy when any sample was taken while plugged in. Field
   sessions run on a power bank, so power claims are lab claims, made on
   battery.
4. **Let the phone cool between runs.** Heat is the main confounder on the
   Xiaomi: the second of two back-to-back runs differed by up to 10% from the
   heat left over. Wait at least 10 minutes between runs on the same phone, and
   note the starting temperature (the start record has it).

## Device and build matrix

| Phone | Role | Build | Notes |
|---|---|---|---|
| Xiaomi 11T Pro 2107113SG (Snapdragon 888) | main development and performance phone | debug (MIUI install quirk) | fast but hot: the camera throttles from about 41-42 °C; good for HEAT behaviour, but its speed is a debug build's |
| Samsung Galaxy M12 SM-M127F | slow phone that stays cool | debug; a release APK as a side-by-side copy ([test/README.md](../test/README.md)) | never passed about 32 °C, limited by compute; `battery_current_ua` is broken, so use the battery-% drop, not `power_w` |

In every result table, say which phone and build made each number. Claims
about absolute release speed need a release build (on a test phone: the
side-by-side copy); claims about heat collapse belong on the Xiaomi.

## What to hold fixed in a paired comparison

Change exactly ONE thing (the optimization under test). Hold fixed:

- the model file (the same file; note its size or hash), confidence and IoU
- the capture trigger (detector, motion or time-lapse) and all its settings
- the detector rate, the camera frame rate (a camera runs only at the rates its
  lens offers), the auto-adjust setting
- GPU or CPU, and on the CPU 16-bit or 32-bit maths (`cpu_16bit` in the
  records)
- the stream resolution and the saved-photo side
- scene and mount: the same tripod position and view. Use a still indoor scene
  for speed tests (repeatable); keep outdoor scenes for end-to-end checks
- screen state: blackout always on or always off (it changes the heat budget by
  about 10 °C, round 82; the log records `blackout_at_start` and every switch)
- charging state (golden rule 3), weather and room conditions, and starting
  temperature (start each run below a chosen value, for example 32 °C)

The session start record holds all settings, so you can always check later
whether anything else was different.

## Run protocol

- **Three paired runs, in alternating order:** A-B, B-A, A-B (six sessions).
  This cancels the bias of a fixed order (the second run starts warmer, or
  later in the day).
- **Length:** at least 20-30 minutes per session for anything about heat
  (throttling builds up over tens of minutes); 10 minutes is enough for pure
  pipeline speed on a cool phone.
- **Cold and sustained:** the first ~2 minutes after REC include model load,
  calibration and a cool chip; the honest steady state is at the end.
  `tool/perf_summary.dart` separates them (cold = first 120 s of samples,
  sustained = last 600 s; change with `--cold=S` and `--sustained=S`).

## Reading the numbers

Run the summary tool on the session folders (needs only the Dart SDK, not
Flutter):

```bash
dart tool/perf_summary.dart sessions/run_a1 sessions/run_b1 sessions/run_a2 ...
dart tool/perf_summary.dart --csv sessions/run_* > runs.csv   # for R / pandas
```

It reads each `session.jsonl` line by line (no size limit) and prints one
comparison row and detail tables per session. It already handles these rules:

- `pipeline_fps ?? fps` for older logs without `pipeline_fps` (round 85)
- inference fields are MISSING (not zero) while the motion gate sleeps;
  gate-idle time has its own percentage
- power and energy are hidden whenever charging was seen (round 84)
- broken or cut-off lines (a crash during a write) are counted and skipped

Main columns to compare in a paired test: sustained `pipe fps med`, sustained
`inf ms med/p95`, `temp start→max`, `power W med` and `energy Wh` (unplugged
runs only), `cap chg` (changes by the auto-adjust), and `errors`.

⚠ **`power W` and `energy Wh` here come from the RAW logged `power_w`**
(round 188). Unlike the app's summary graph, `perf_summary.dart` makes NO unit
correction (a current in mA: about 1000× too low on Samsung-class phones) and
does NOT halve the 2-cell voltage (about 2× too high on Xiaomi-class phones).
So its absolute W and Wh can differ from the app's. They are fine for PAIRED
comparisons on the SAME phone (both runs are wrong by the same factor); for
absolute numbers use the app summary or the battery-% drop.

Aligning the tool with the app's corrections is an open task. Its output feeds
benchmark records, so its maths must not change silently.

## Acceptance criteria (when is an optimization real?)

Adopt a change only when BOTH hold:

1. **All three paired runs agree in direction** (A better than B three times,
   or the reverse).
2. **The median gain is larger than the run-to-run spread** of the same
   settings (compare the three A runs; a "gain" smaller than that spread is
   noise).

For limited modes (detector rate limit, motion gate, time-lapse), speed is not
the goal. Require instead **the same useful delivered FPS** plus at least **5%
lower power** or a **clearly later heat collapse** (a later or lower
temperature plateau on the Xiaomi).

Record the verdict (numbers, phones, builds, dates) in the round's entry in
`AGENT_CHANGELOG.md`.

## Existing benchmarking assets (don't duplicate these)

- **In-app engine benchmark** (Settings → Detection → *Advanced (engine &
  thresholds)*): times the GPU and CPU thread variants (also CPU 16-bit) on
  noise input at the model's own resolution. Good for choosing an engine; NOT
  a pipeline benchmark (no camera, no tracker).
- **Earlier measurements:** parity with the Ultralytics demo app, the cost of
  frame conversion per stream size, timing of analysis afterwards, and the
  10-minute cool-down lesson (rounds 128 to 156 in `AGENT_CHANGELOG.md`).
- **`integration_test/qnn_benchmark_test.dart`:** checks QNN on a phone and
  times CPU, GPU and QNN. It needs the internet (it downloads models and
  bus.jpg), a Snapdragon phone that can run QNN, and the NPU edition of the
  app ([LEAN_QNN_PACKAGING.md](LEAN_QNN_PACKAGING.md)). Turn on the optional
  parts with exactly `--dart-define=RUN_BENCH=true` and
  `--dart-define=RUN_SOAK=true` (`=1` silently does nothing). The pinned
  v0.3.5 release files are v73/v81 Hexagon context binaries: NEITHER runs on
  the Snapdragon 888 Xiaomi (v68, round 151), so QNN rows need a newer phone.
- **Tracker comparisons** are a different problem (accuracy, not speed): use
  `tracking/tracker_replay.dart` with hand-counted ground truth, as in rounds
  105 and 108.
