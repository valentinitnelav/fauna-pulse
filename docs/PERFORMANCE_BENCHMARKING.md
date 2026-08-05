# Performance benchmarking protocol

How to measure FaunaPulse performance so that two runs can be compared honestly,
and how to decide whether an optimization is real. Written for this project's
review workflow (docs/PERF_AND_ROBUSTNESS_REVIEW.md, item E1): every claimed
speed/heat/power improvement should come with numbers produced this way.

In plain language: phone performance is noisy. The same app, same phone and
same scene can differ by 10% between two runs just from starting temperature,
background OS work, or sunlight on the case. The protocol below exists so a
"5% faster" claim means something.

## The golden rules

1. **Never quote debug-build numbers as device speed.** A `flutter run` /
   debug APK runs measurably slower than a release build (review C2, round
   132). Debug numbers may only be compared against other debug numbers from
   the same binary.
2. **Never compare across different binaries.** Every session log records
   `app_version`, `app_build` and `build_mode` in its start record (round 132);
   `tool/perf_summary.dart` prints them so mixed-binary comparisons are visible.
3. **Power and energy numbers are only valid unplugged** (round 84): while
   charging, the battery-terminal current measures charging, not consumption.
   The summary tool withholds power/energy automatically when any sample in
   the session was taken while plugged in. Note the field invariant
   (2026-07-11): real field sessions run ON a power bank, so power claims are
   lab claims by definition, made on battery.
4. **Let the phone cool between runs.** Heat is the dominant confounder on the
   Xiaomi (D3 field note: the second of two back-to-back runs measured up to
   10% different purely from carry-over heat). Wait at least 10 minutes
   between runs on the same phone, and record the starting temperature (the
   start record carries it).

## Device and build matrix

| Phone | Role | Build | Notes |
|---|---|---|---|
| Xiaomi 2107113SG (SD888) | primary dev/perf phone | debug (MIUI deploy quirk; round 158 convention) | fast but hot: camera-first throttle from ~41-42 °C; its numbers show THERMAL behaviour well but absolute speed is debug-flavoured |
| Samsung SM-M127F | release-test phone | release APK | never passed ~32 °C, compute-limited; its `battery_current_ua` is broken (round 132), use battery-% drop, not power_w |

State in every result table which phone and build produced each number. A
release-build claim about absolute speed belongs on the Samsung (or a future
release-deployable phone); a thermal-collapse claim belongs on the Xiaomi.

## What to hold fixed in a paired comparison

Change exactly ONE thing (the optimization under test). Hold fixed:

- model file (same file, ideally note its size/hash), confidence/IoU
- capture trigger (detector / motion / time-lapse) and all its settings
- inference FPS cap, camera FPS cap, auto-throttle setting
- stream resolution and saved-photo side
- scene and mount: same tripod position, same view; prefer a static indoor
  scene for speed tests (repeatable) and reserve outdoor scenes for
  end-to-end validation
- screen state: blackout on or off, consistently (round 82: blackout changes
  the heat budget by ~10 °C; the log records `blackout_at_start` and every
  toggle)
- charging state (see golden rule 3), ambient conditions, starting
  temperature (begin each run below a chosen threshold, e.g. 32 °C)

The session start record captures the whole config block, so an after-the-fact
audit of "was anything else different?" is always possible.

## Run protocol

- **Three paired runs, alternating order:** A-B, then B-A, then A-B (six
  sessions). Alternation cancels the "the second run starts warmer / later in
  the day" bias that a fixed order would bake in.
- **Length:** at least 20-30 minutes per session for anything thermal
  (throttling develops over tens of minutes); 10 minutes is acceptable for
  pure pipeline-speed comparisons on a cool phone.
- **Cold vs sustained:** the first ~2 minutes after REC include model load,
  calibration and a cool chip; the honest steady-state lives in the last
  minutes. `tool/perf_summary.dart` separates the two automatically (cold =
  first 120 s of samples, sustained = last 600 s; both adjustable).

## Reading the numbers

Run the summary tool on the session folders (Dart SDK only, no Flutter):

```bash
dart tool/perf_summary.dart sessions/run_a1 sessions/run_b1 sessions/run_a2 ...
dart tool/perf_summary.dart --csv sessions/run_* > runs.csv   # for R / pandas
```

It streams each `session.jsonl` (no size limit) and prints one comparison row
per session plus per-session detail tables. Semantics it already honours, so
you don't have to remember them:

- `pipeline_fps ?? fps` for pre-round-131 logs (round 85)
- inference fields are ABSENT (not zero) while the motion gate sleeps (round
  77); gate-idle time is reported as its own percentage
- power/energy withheld whenever charging was detected (round 84)
- malformed or truncated lines (crash mid-write) are counted and skipped

Headline columns to compare in a paired test: sustained `pipe fps med`,
sustained `inf ms med/p95`, `temp start→max`, `power W med` / `energy Wh`
(unplugged runs only), `cap chg` (auto-throttle interventions), and `errors`.

⚠ **`power W` / `energy Wh` here are computed from the RAW logged `power_w`**
(round 188 note): unlike the app's summary graph, `perf_summary.dart` applies
NO unit correction (mA-scale current ⇒ ~1000× low on Samsung-class phones) and
NO 2-cell voltage halving (⇒ ~2× high on Xiaomi-class phones), so its absolute
W/Wh can disagree with the app for the same session. They are still fine for
PAIRED comparisons on the SAME device (both runs are wrong by the same factor);
for absolute numbers use the app summary or the battery-% drop. Aligning the
tool with the app's corrections is a recorded follow-up — its output feeds
benchmarking records, so its math must not change silently.

## Acceptance criteria (when is an optimization real?)

Adopt a change only when BOTH hold:

1. **All three paired runs agree in direction** (A better than B three times,
   or the reverse).
2. **The median gain exceeds the run-to-run variation** of the same
   configuration (compare the spread between the three A runs; a "gain"
   smaller than that spread is noise).

For capped/limited modes (inference cap active, motion gate, time-lapse), a
speed win is not the goal; require instead: **equal useful delivered FPS**
plus at least **5% lower power** or a **materially delayed thermal collapse**
(later/lower temperature plateau on the Xiaomi).

Record the verdict (numbers, phones, builds, dates) in
`PERF_AND_ROBUSTNESS_REVIEW.md` under the item that motivated the test, as
rounds C2/C3/D3 did.

## Existing benchmarking assets (don't duplicate these)

- **In-app engine benchmark** (Settings → AI, round 76): times GPU vs CPU
  thread variants on noise input at the model's own resolution. Good for
  picking an engine; NOT a pipeline benchmark (no camera, no tracker).
- **Review measurements:** C2 (parity vs the Ultralytics demo app), C3
  (per-frame conversion cost vs stream size), D3 (batch-analysis timing and
  the 10-minute cool-down lesson). All in `PERF_AND_ROBUSTNESS_REVIEW.md`.
- **`integration_test/qnn_benchmark_test.dart`:** on-device QNN validation +
  CPU/GPU/QNN micro-benchmark. Needs network (downloads models + bus.jpg) and
  a QNN-capable Snapdragon. Opt-in flags are exact-spelling booleans:
  `--dart-define=RUN_BENCH=true` and `--dart-define=RUN_SOAK=true` (`=1`
  silently does nothing; fixed round 160). The pinned v0.3.5 release assets
  are v73/v81 Hexagon context binaries: NEITHER runs on the SD888 Xiaomi
  (v68, round 151), so QNN rows require a newer test device.
- **Tracker comparisons** are a different problem (accuracy, not speed): use
  `tracking/tracker_replay.dart` with hand-counted ground truth, per the
  round-105/108 workflow.
