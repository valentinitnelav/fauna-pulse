# Identify organisms

**Status:** experimental. The method and its defaults are not yet tested on pollinator data.

This page explains how FaunaPulse names the animals it found in a session. It is for citizen
scientists, students and researchers. Methods, measurements and file details for researchers and
developers are lower on the page, in folded blocks: click a line that starts with ▸ to open it.

To try it in a few minutes, follow the [tutorial](TUTORIAL_VIDEO_ANALYSIS.md) with two demo
videos.

> **In short**
>
> - Identification is a step after recording. FaunaPulse cuts the saved photos of every track
>   ID into *crops* (small pictures around the animal). An AI model looks at each crop, and the
>   crops of one track ID are combined into one answer: order, family, genus and species, each
>   with a confidence.
> - Everything runs on the phone. Nothing is uploaded.
> - You need an identification model and a name list made for it. Step 1 on Home
>   (**What do you want to watch?**) downloads both.
> - It is meant for bulk work after a day of recording. Plug the phone in and keep FaunaPulse
>   on the screen until the run ends.
> - The percentages are the model's confidence, not measured accuracy. Read about 90 % at
>   family rank as "very likely", and species names as leads to check.

**Contents**

- [What you need](#what-you-need)
- [Run an identification](#run-an-identification)
- [Read the results](#read-the-results)
- [Settings](#settings)
- [Troubleshooting](#troubleshooting)
- [Files](#files)
- For researchers and developers: [How the answer is computed](#how-the-answer-is-computed),
  [The models: GPU, memory and speed](#the-models-gpu-memory-and-speed),
  [Credits and citations](#credits-and-citations)

## What you need

You need two files on the phone: an **identification model** and a **name list** made for that
model. The name list holds the names the model may choose from.

### The easy way

1. On **Home**, step 1 asks **What do you want to watch?**. Tap your answer.
2. FaunaPulse chooses an identification model with its name list for you (and a detection
   model).
3. One button downloads them and sets them up.

Other suggestions, and the other models already on the phone, are under **Choose other models**.
If you choose **Not now** under **To name them**, the animals are found and counted, not named.

| Your answer | Identification model and name list |
|---|---|
| **Pollinators on flowers** | BioCLIP 2 with *Flies, bees and wasps, beetles, butterflies and moths of Europe* (or the insectDCT classifier) |
| **Insects on a flat surface** | the same as for pollinators |
| **Mammals and birds** | BioCLIP 2 with *Mammals and birds of the world* |

### The models

| Model | What it does | Size | Time per crop |
|---|---|---|---|
| **[BioCLIP 2][bioclip]** | Names any organism, choosing from a name list. | 0.6 GB | 0.27 s (GPU), 2.6 s (CPU) |
| **BioCLIP 2.5** | The larger successor of BioCLIP 2. | 1.27 GB | 5.3 to 5.6 s (CPU; the test phone's GPU has too little memory for it) |
| **insectDCT classifier** | Names insects in 104 fixed classes of flower visitors, from order down to species where it can. | 42 MB | 0.02 s (GPU), 0.15 s (CPU) |

The times were measured on a test phone (Xiaomi 11T Pro, plugged in). GPU means the graphics
processor, CPU the main processor. BioCLIP 2.5 is an overnight job on the charger (about 1.5
hours per 1000 crops). The insectDCT classifier also needs its class list (14 kB).

It is not yet tested which model names this project's pollinators best (BioCLIP 2, BioCLIP 2.5
or insectDCT).

### The name lists

| Name list | For model | Names | Size |
|---|---|---|---|
| *Flies, bees and wasps, beetles, butterflies and moths of Europe* | BioCLIP 2 | 34,978 | 57 MB |
| *Mammals and birds of the world* | BioCLIP 2 | 17,130 | 28 MB |
| *Flies, bees and wasps, beetles, butterflies and moths of Europe* | BioCLIP 2.5 | 34,392 | 74 MB |
| *Its 104 classes* (a class list) | insectDCT classifier | 104 | 14 kB |

A model can identify only with a name list made for it:

- **Download & import models** lists each identification model with its name lists under it. A
  model without a name list is flagged: it cannot identify.
- **Identify organisms** offers only the lists made for the chosen model, and does not start
  without one.
- A list works only with the model it was built for. The app refuses a list made for another
  model.

### Download & import models

Open it from **Home**: **AI models** in the bottom bar, or **Menu** → **Download & import
models**. The Identify screen has a link to it too (**Download & import models…**).

- The screen has two lists: **Detection models** (find animals and draw a box around each one) and
  **Identification models** (name what is inside each box). Each list is sorted by file name.
  A file on the phone has a green **On this phone** mark. Each file that is not on the phone has
  its own **Download** button.
- **Name lists without their model** lists name lists whose model is not on this phone. They
  cannot be used until you download the model.
- A BioCLIP model has its own **Download** and two numbered steps: *1. The model, needed once*,
  then *2. Then the name lists for your region and the animals you watch*. A name list's **Download**
  also brings the model when it is missing.
- The insectDCT classifier is one row with its class list. Downloading the class list brings the
  model along, and choosing the model also chooses its class list.
- Each file has an ⓘ button. It opens a card named after the file, with rows such as *Kind*,
  *File*, *Licence* and *Source*. For a file the app does not know, one row *Licence and source*
  says that it is not known. The card of a model downloaded from Hugging Face ends with
  **Model card on Hugging Face**, its page there.
- **All models for FaunaPulse on Hugging Face** opens the collection of all models. The box
  **About these models** at the end of the screen says more about them.

**Delete models.** Tap the bin next to a file (**Delete**). Under a list of two files or more,
**Delete all detection models…** or **Delete all identification models…** deletes the whole
list. To delete some files, press and hold one file, tap the others, then tap the bin at the top.
A model's name lists are deleted with it. Sessions and results already made keep their results.

### Import your own files

1. Copy the files to the phone (over USB, or with `adb push … /sdcard/Download/`).
2. On **Home**, open **Menu** → **Download & import models** → **Import model files…** (or
   **Download from a link…** to download from a web address).
3. Choose the files. For insectDCT, choose both files (model and class list) at once. The app
   finds out what each `.tflite` file is and puts it in its place. If a file of the same name is
   already there, the window **Already on this phone** asks: **Keep the one on the phone** or
   **Replace**. With several files, tick **Same answer for the other chosen files already on the
   phone**.
4. Wait for the line with a green tick, for example "Imported {name}: an identification model,
   listed under Identification models."

The files are copied into the app's private storage (Android/data is not used). So you can
delete the copies in Downloads afterwards.

<details>
<summary>Import: progress, full storage, and how the app tells the files apart</summary>

- The progress shows under the button: "Copying {name} into the app…", a bar, and for example
  "0.3 GB of 1.1 GB". The result stays there as a line with a green tick.
- If the storage fills up during the copy, the import stops at once ("Not enough free storage:
  the import stopped. …") and the half-copied file is deleted.
- One import takes every kind of file (since round 275). The app reads what each `.tflite` file is: an
  identification model gives one row of numbers per picture, a detection model a table of boxes.

</details>

<details>
<summary>Name lists in detail (for developers)</summary>

- **Words (round 276).** A *name list* is what an identification model chooses its names from.
  It is one of two kinds, both `.fpack` files ("FaunaPulse pack"): a *class list* (the fixed
  classes of a classifier such as insectDCT) or a *label pack* (names with their embeddings, for
  BioCLIP). Hugging Face and fauna-pulse-models say "label pack".
- **How a list finds its model (round 271).** A class list belongs to the model with the same
  file name. A label pack belongs to every model file whose name starts the same way, by the
  naming rule of round 276 (`tool/model_downloads/README.md`):
  `bioclip-2_pollinator-orders-europe_v2.fpack` goes with `bioclip-2_224_fp16.tflite` and
  `bioclip-2_224_fp32.tflite`. BioCLIP 2.5 packs start with `bioclip-2.5_`.
- A pack also names its model in its header (`model_id`). So a renamed pack still finds a model
  whose name starts with that id (upper and lower case, "-" and "." alike: `bioclip-2.5` also
  finds `bioclip-25_image_fp16.tflite`, the name of that model before the naming rule).
- **Why a list for another model is refused:** BioCLIP 2 packs hold 768 numbers per name,
  BioCLIP 2.5 packs 1024.
- **Versions.** Since round 322 the lists offered are version 2 (`…_v2.fpack`). The version 1
  lists and the 32-family demo lists are no longer offered. A copy on the phone keeps working,
  with a line under its file name on Download & import models (version 1: replaced by version 2;
  the demo: its 32 families are an example, not a checked choice). Their files stay on Hugging
  Face.
- The download list (catalogue) is `assets/model_downloads.json`, described in
  `tool/model_downloads/README.md`.

</details>

<details>
<summary>Make your own model files and name lists on a PC</summary>

Your own files are built once on a PC and then copied to the phone. A normal laptop without a
GPU is fine. The commands are in `bioclip_export/README.md` of
[fauna-pulse-models](https://github.com/valentinitnelav/fauna-pulse-models).

| File | What it is | Size | Made with (fauna-pulse-models) |
|---|---|---|---|
| `bioclip-2_224_fp16.tflite` | the BioCLIP 2 image tower, converted for the phone | ~0.6 GB (fp16) | `bioclip_export/export_image_tower.py` |
| `bioclip-2.5_224_fp16.tflite` | the BioCLIP 2.5 Huge image tower (round 264; see *BioCLIP 2.5* below) | ~1.27 GB (fp16) | the same script, `--model bioclip-2.5` |
| `<pack>.fpack` | a name list for BioCLIP (a *label pack*): the names the model may choose from, their embeddings, their taxonomy, plus "none of these" entries (flower, leaf, shadow, …) | tens of MB (a list of families) to ~430 MB (all Insecta + Arachnida; slow to score in this version) | `bioclip_export/build_label_pack.py` |
| `insectdct-cls-v7-eff2s_224_fp16.tflite` + `.fpack` | insectDCT's hierarchical classifier (round 266) and its **class list** (same file name; see *insectDCT* below) | 42 MB + 14 kB | `classifier_export/export_insectdct_cls.py` |

</details>

> **When you publish results.** Model weights: BioCLIP 2 and BioCLIP 2.5 by Imageomics (MIT).
> Name embeddings: TreeOfLife-200M (CC0). Please cite Gu et al. (2025), *BioCLIP 2: Emergent
> Properties from Scaling Hierarchical Contrastive Learning*, NeurIPS. The model cards
> [bioclip-2-tflite](https://huggingface.co/Valen-Peregrine/bioclip-2-tflite) and
> [bioclip-2.5-tflite](https://huggingface.co/Valen-Peregrine/bioclip-2.5-tflite) give the full
> references. More in [Credits and citations](#credits-and-citations).

## Run an identification

There are two ways to start.

**Together with Find animals.** On **Find animals in photos** or **Find animals in videos**,
switch on **Also identify them** and choose the model and name list under it. **Start** then
finds the animals and their track IDs, opens **Identify organisms** (which starts by itself),
and ends on the results. The steps below are the same, only without the taps.

On **Find animals in videos**, the identification settings are also on the Identification card
of **Detection, track ID and identification settings** (the same values).

**From a session.** Live detection sessions already have their track IDs, so start from the
session:

1. On the **Sessions** screen, open the session's ⋮ menu and tap **Identify organisms**. (Or:
   the session's summary → **Photos** tab, or **Video** tab for a video session → the
   **Identify organisms** button at the end.)
2. Under **Model and name list**, pick the **Model (.tflite)** and the **Name list (.fpack)**. A
   line under them says how many names the list has. If no list fits the model, an amber line
   says "No name list for this model, so it cannot identify". The screen shows how many crops will be processed: one per
   photo per tracked animal, with a cap per track ID. After the first run on this phone it also
   shows a time estimate, for example "120 crops from 8 track IDs (about 5 min on this phone,
   plus any heat pauses)". The estimate leaves heat pauses out.
3. Plug the phone in and tap **Start**. The progress shows the crops done, the elapsed time, the
   estimated time left, the battery temperature, the memory in use on the whole phone (with
   FaunaPulse's own share, mostly the loaded model) and the processor cores FaunaPulse keeps
   busy. The time left leaves heat pauses out, so it stays the same while the run is paused.
4. When the run has finished, tap **View results**.

> **Keep FaunaPulse on the screen until the run ends.** Identification is the heaviest step:
> BioCLIP 2 needs more than 1 GB of memory. The screen says so above **Start** and during the
> run: "Identification needs a lot of memory. Keep FaunaPulse on the screen until it ends: if you
> switch to another app, Android may stop it." Swiping FaunaPulse away from the recent apps ends
> the run (what is done is kept).

**Heat pauses.** The run pauses by itself above the temperature limit (default 43 °C, the same
as for **Find animals in videos**) and goes on at 3 °C lower. The line under the temperature
scale ends "To change the limit, open Advanced settings after the run."

**Sessions without track IDs.** Motion-triggered and time-lapse sessions (no live detection)
have no track IDs. Run **Find animals in photos** first. When the photos are at most 0.5 s
apart, it also finds the track IDs, by itself after each run, and the crops are then combined
per track ID. Photos further apart have no track IDs, so their boxes are identified one by one.

### Buttons

| Button | What it does |
|---|---|
| **Start** | Starts the run. During the run a line shows the step: "Loading the model (the first time on this phone can take up to a minute)…", "Planning crops…", "Identifying crops on the CPU…" (or GPU), "Combining crops per track ID and writing results…", or "Paused: …" during a heat pause. |
| **Cancel (keeps what is done)** | Stops the run and keeps everything done so far. |
| **Continue / re-run** | Shown in place of **Start** once crops are stored. Goes on where the run stopped, then scores everything again. On a session that did not change, this takes seconds. |
| **Stop and leave** | When you leave the screen during a run (Back), the app asks *Identification is still running*. **Stop and leave** stops after the current photo and keeps what is done; **Cancel** stays on the screen. |
| **Update results** | Repeats only the last step (seconds): the stored model output is compared with a different name list, for example one for a single country, without running the model again. Shown when stored model output exists and the track IDs did not change. |
| **Test speed** | In the Run section. Measures the seconds per crop on this phone with the current settings, so you can compare GPU on or off and thread counts in about a minute each (a few minutes on an older phone's CPU). |
| **View results** | Opens the results ([next section](#read-the-results)). |
| **Share results (CSV file)** | Under **Last run**. Shares the per-track-ID table. |

After a run, the block **Last run** sums it up, for example "12 track IDs: 9 to family, 2
unidentified, 1 no organism.", with a note if the run was cancelled or some crops failed.

### Messages you may see

| Message | What it means | What to do |
|---|---|---|
| "N of M crops could not be identified (the model stopped with an error). They are missing from the results." | The model gave an error on some crops. | Tap **Continue / re-run** to try them again. |
| "N of M crops could not be identified because their photos could not be read (the files may be damaged). They are missing from the results." | Those photos are damaged. | Nothing helps: **Continue / re-run** does not, because the photo stays damaged. |
| A red line that says no crop at all could be identified because of model errors | The model failed on every crop. | If it fails a second time, delete the model on **Download & import models** and download it again (the line says so). |
| "Identifying crops on the CPU (GPU not used, see below)…", with a small amber line under the counts | The model runs on the slower CPU. The amber line gives the reason. | See [Troubleshooting](#troubleshooting). |
| "Only N of M kept frames of the videos are saved, so X of Y track IDs have no photo to identify yet. Save the remaining frames on "Find animals in videos" first." | A video session whose kept frames are not all saved yet. | Tap **Open Find animals in videos** and save the frames, then come back. |
| "N kept frames can no longer be saved: the video is gone from the session folder." | The video file was deleted or moved. | Those frames cannot be identified. |
| "No crops to identify: this session has no photos of tracked animals. …" | The session was recorded without a detection model. | Run **Find animals in photos** (videos: **Find animals in videos**) from the session's ⋮ menu first. |
| "The phone is not plugged in." | The phone runs on its battery. | Plug it in for long runs. |
| "Track IDs were found again after the last identification, so its results no longer fit them. …" | The track IDs changed after the last run. | **Continue / re-run** identifies all photos again from the start (as long as a first run). |
| A note on **Home** for a few seconds when you open FaunaPulse | Android closed the app during a run. Nothing starts by itself. | On **Sessions**, open the session's ⋮ menu → **Identify organisms**. It goes on where it stopped. |

<details>
<summary>When FaunaPulse is in the background, or Android closes it</summary>

- The run does go on while another app is open or the screen is off (round 319), with a
  notification "FaunaPulse is identifying animals". But Android may close the app to free
  memory.
- Swiping FaunaPulse away from the recent apps ends the run (what is done is kept).
- When Android closed the app during a run that started with FaunaPulse on the screen, the next
  opening of FaunaPulse (up to 24 hours after the run started) says so on Home for a few
  seconds, and nothing starts by itself. Continue with *Identify organisms* from the session's ⋮
  menu on the Sessions screen, which goes on where it stopped.
- On Android 13 and newer, the first run after the app opens asks for the notification
  permission if it is not granted yet. The run goes on whatever the answer.
- When **Also identify them** starts the identification after *Find animals in videos* or *in
  photos* with the app in the background, the app first checks the phone's free memory, strictly
  on purpose (a wait costs one tap, a closed app loses the run):
  - A model that fits (for example insectDCT) loads and runs in the background. Opening
    FaunaPulse then shows the run's progress, or its results when it has ended.
  - A model that does not fit waits: often BioCLIP 2, on the CPU and also on the GPU, which
    needs about 4.5 times the model file. The notification "Animals found" asks you to open
    FaunaPulse, and the identification starts by itself when you do (from the notification, the
    recent apps or the app icon).
  - This also works after Android has closed FaunaPulse while it waited (within 24 hours, once).
    If it was closed again during that start, Home says so, and you continue with *Identify
    organisms* from the session's ⋮ menu on the Sessions screen (see
    [FIELD_GUIDE.md](FIELD_GUIDE.md#7-field-troubleshooting), *When the identification waits*).

</details>

<details>
<summary>What a re-run computes again (round 213), and Update results after new track IDs</summary>

The model output for every crop is stored in `embeddings_<model>.jsonl/.bin`, keyed by photo,
track ID and box (the files are append-only). **Continue / re-run** runs the model only on
crops without a stored vector (new photos, or crops that a lower *Smallest box to identify* now
admits) and then re-scores everything. That is why a re-run on an unchanged session takes
seconds.

Confidence and "no organism" thresholds, the CSV rank, the merge settings and the suspect flags
are all applied at scoring, so changing them never re-runs the model. **Crop margin** and
**Square crops** are the exception: they change what the model saw, but the stored vectors do
not know it. When either differs from what the stored crops were cut with, Start asks (*Crop
settings changed*) whether to *Keep stored crops* (fast) or *Recompute all crops* (a full run).
*Smallest box to identify* and *Crops per track ID* only add or remove crops.

**Update results** compares the stored embeddings against a different name list (for example a
country-restricted one) without running the model again. For track IDs found in videos, *Find
track IDs* numbers the track IDs anew each time. After it ran again, the stored crops belong to
the old numbers, so the button is hidden, a note says the next *Continue / re-run* starts over,
and the session summary shows no answers on the frames until then (round 235).

</details>

## Read the results

**View results** opens the screen **Identification**, with the session's name under the title.
Its header lists the *Model*, the *Name list* (*Class list* for insectDCT), the *Date run* and
the number of *Track IDs*. Below is a table with one row per taxon. A taxon is a named group of organisms at
one rank, such as the order Hymenoptera or the genus *Bombus*.

1. Choose how to count, above the table:
   - **As identified** (default): one row per answer, at the rank the model was sure about.
     Track IDs identified only to the genus *Bombus* are one row; track IDs identified to
     *Bombus terrestris* are another.
   - **Order**, **Family**, **Genus** or **Species**: every track ID counts under its taxon at
     that rank. Track IDs the model did not resolve that deep land in a "not resolved to ..."
     row.
   - Under the chips, **Rank filter:** keeps only the rows of one rank. A long table shows its
     first rows: tap **Show all N rows** for the rest. **All N track IDs** below the table lists
     every track ID.
2. Read the columns. *Track IDs* is the number of track IDs in the row. *Time* adds up their
   durations. *Med. Conf.* is their median confidence.
3. Tap a row to see its track IDs. Tap a track ID to open its sheet with the full ladder (see
   below).
4. Tap the share icon at the top right (**Share results (CSV file)**) to hand the per-track-ID table (`tracks_<pack>.csv`, one row per track ID)
   to another app. The same file
   stays in the session folder under `identification/`, so you can also copy it over USB.

The header's *Name list* row shows the name list by its file name, as on **Identify organisms**
(for example "bioclip-2_pollinator-orders-europe_v2.fpack (34,978 names)"). After the run, the
**Photos** tab of the session summary shows each track ID's identification under its photos.

One identification belongs to one **track ID** and combines all photos of that track ID. The
Photos tab shows it under every photo of that track ID. It is not an answer per photo: the
guesses per crop are in `predictions_<pack>.jsonl`.

### Words used on the results screens

| Word | Meaning |
|---|---|
| **Track ID** | One tracked organism. Pollination ecologists call it a visit when detection and tracking worked, but some track IDs are false detections, and one insect can be split into several. The app says "track ID" everywhere (file and field names included), because it is the neutral term and the app also serves birds, mammals and other organisms. |
| **Conf.** | The model's confidence that a track ID belongs to a taxon: the probabilities of all species under that taxon added up (a genus = the sum of its species, a family = the sum of its genera, and so on). BioCLIP itself only scores species names; FaunaPulse does the adding. All Conf. values at one rank, plus the "none of these" entries, add up to 100 %. |
| **Species conf.** | The probability of *one* species for *one* crop, with no adding. |
| **Med. Conf.** | In the taxon table: the median of Conf. across the row's track IDs, rounded to whole percent. The list that opens from the row states the same median above its table, so it can be checked. |
| **Agree** | How many crops, judged alone, put their top species under the taxon. Shown as a share (*Agree*, "50 %") and as a count (*Crops agree*, "5/10"). |
| **Ladder** | The taxon chosen at every rank, on a consistent path from kingdom to species, each with its Conf. and Agree. |
| **Identified rank** | The deepest rung of the ladder whose Conf. reaches the confidence threshold (default 0.6). The headline is that rung's taxon. Species names below the threshold are still shown, as suggestions to verify. |
| **unidentified** | No taxonomic rank reached the threshold, not even kingdom. In a pack of animals only, this means the "none of these" entries took a large share, but not more than the "No organism" threshold. |
| **no organism** | The "none of these" entries (flower, leaf, shadow, …) took more than the "No organism" threshold. |
| **Best single photo** | The crop whose own top species has the highest Species conf.: the photo the model is surest about on its own. |

### A track ID's sheet

- **The ladder**, as an aligned table. The reported rank is highlighted; the taxa below it
  (suggestions) are grey.
- **The best single photo**, with its full file name on its own line. The sheet also names its
  species and confidence, the crop number, and how many photos name the same species, and it
  opens the photo view on it. In the photo, the yellow box is the detector's box, labelled with
  the live detector's confidence for that photo. The cyan box is the crop given to the model.
  The eye button (**Hide boxes** / **Show boxes**) switches the boxes off and on; pinch to zoom
  and tap **Reset zoom** to go back.
- **The crops table.** For each crop: its side in pixels, its weight, its own best guess
  (*Top species*, with *Species conf.*), the
  detector's confidence for the crop's box (*Detector conf.*), and the best guess's family, order
  and class in one column each. Tap a crop to see its photo.
- A line *"None of these" (flower, leaf, shadow …)* with its probability. For a classifier with
  fixed classes, such as insectDCT, a line *Model's own class* gives the class it chose.
- A "?" in a table means an older app version made these results. **Update results** on
  **Identify organisms** fills in the missing values within seconds.
- **Flags**, as amber ⚠ lines where they apply. Their ⓘ gives the reason with the actual values.

The crops table names the taxon in its confidence column, for example "Conf. Hymenoptera". Tap
a ladder row to change the taxon this column shows.

### Flags

| Flag | Meaning | Shown |
|---|---|---|
| `short` | The track ID lasted less than 2 s, or the detector saw it in fewer than 3 frames. | under the header (the number behind it turns amber) |
| `low_det` | The mean detector confidence is below 0.2. | under the header (the number behind it turns amber) |
| `suspect` | `short` AND (`low_det` OR `weak_id` OR no organism): possibly a false detection. | under the header |
| `merged` | Joined from several track IDs (setting *Merge consecutive track IDs*). | under the header |
| `weak_id` | Conf. at order rank is below 0.5. | under the ladder |
| `unidentified` | No rank reached the threshold. | under the ladder |
| `no_organism` | The "none of these" entries took more than the "No organism" threshold. | under the ladder |
| `path_conflict` | At some rank, a taxon outside the ladder's path scored more. The line names that rival taxon and why the ladder skips it ([details](#how-the-answer-is-computed)). | under the ladder |
| `single_crop` | Only one crop, so there is no agreement between photos to measure. | above the crops table |

The ladder rows that a flag concerns carry ⚠. A small grey "Flags in tracks CSV" line at the
bottom lists the flags as they are written to the CSV, with a dictionary.

Nothing is deleted. The results table hides suspect track IDs behind the switch **Include N
suspect track IDs** (off at first), the Photos tab
marks them, and the CSV keeps every row. All four thresholds are settings.

### How sure is it?

The percentages are *model confidence*, not measured accuracy. A calibration can be fitted
later on labelled crops and stored in the name list. Until then, read 90 % at family rank as
"very likely", and treat species-level answers as leads. The rule and its defaults are not yet
tested on pollinator data ([Validation status](#how-the-answer-is-computed)).

<details>
<summary>The results tables in detail</summary>

- The table (round 214) is sortable by tapping a column header. It has the rank in its own
  column and a rank filter (for example only rows that reached species).
- A row opens its track IDs as a numbered list. *No.* is the row number; *Track ID* is the
  tracker's id, which can jump. In "All track IDs" the taxon's rank has its own column (since
  round 222).
- A table wider than the screen scrolls sideways under a slider. In that list only the table
  moves; the text above it stays.
- In the crops table, the detector's confidence (*Detector conf.*) and the yellow box label came
  in round 223. Since round 222 the best guess's family, order and class have one column each;
  round 220 had them as one "Taxonomic tree" column.
- Long column names over short values (for example "Species conf.") wrap onto two lines, with
  room for the sort arrow.
- Since round 221 each flag is shown where it applies, as an amber ⚠ line whose ⓘ gives the
  reason with the actual values: `merged`, `short`, `low_det` and `suspect` under the header,
  `path_conflict`, `weak_id`, `unidentified` and `no_organism` under the ladder (the affected
  rows carry ⚠; the `path_conflict` line names the rival taxon and why the ladder skips it),
  `single_crop` above the crops table.
- *Time* and *Med. Conf.* can be reproduced from `tracks_<pack>.csv` (`bioclip_<rank>` /
  `p_<rank>` columns).

</details>

<details>
<summary>Why the crops table names the taxon in its confidence column</summary>

A crop's confidence for the reported taxon sits in the same row as that crop's top species. In
a test it was read as the species' probability (track #19 of a test session: Hymenoptera 90 %,
with per-crop values of 95 %, 90 %, 97 % … next to species names). So the column now says
"Conf. Hymenoptera". Tapping a ladder row changes the taxon the column shows. The track ID's
Conf. for that taxon is that column averaged with the Species conf. column as weights, spelled
out as a worked example in the info texts.

</details>

<details>
<summary>Worked examples (2026-09-22, from a test phone)</summary>

These examples were computed with the rule used until round 216, and they motivated the words
above. Under the rule of round 219, track #19 reads Apidae 86 %, *Bombus* 54 %, *B. impatiens*
50 %, and track #10 *B. impatiens* 88 % from its one counted crop.

- A 1.7-second track with four crops, whose predicted species had Conf. 8 %, 5 %, 2 % and 3 %
  (two of them spiders), was reported as Insecta with Conf. 83 %. The combined vector's
  probability lies mostly on insect names, thousands of them, none of them likely on its own.
  The four Conf. values are single names from four different distributions and are not meant
  to add up to anything.
- A 35-second bumblebee track with seven crops was *Bombus* at Conf. 99 %, while its best
  species row read *Bombus cingulatus* 13 %. The genus collects the mass of all *Bombus* species
  (*cingulatus* 13 %, *hypnorum*, *vestalis*, ...). The crops' own predicted species (*vestalis*
  30 %, *cingulatus* 17 %, *dahlbomii* 12 %, ...) are each that crop's single best name.

</details>

<details>
<summary>Why a short track ID can have several photos and a long one only seven</summary>

Time is the span from the tracker's first sighting to the last frame of the track ID, measured
as in `track_ids.csv` (round 305). The detector runs several frames per second, so a 35-s track
ID had 152 frames. Photos are saved on the photo schedule: by default one per second during the
first 10 s of a track ID. Every photo that another insect triggered while this one was in view
also yields a crop for it. So a 1.7-s track in a crowded scene got four crops from other
insects' photos, and a 35-s bumblebee got seven photos in its first ten seconds and none
afterwards. Both are as designed.

</details>

## Settings

Open **Identify organisms** → the **Advanced settings** fold. Settings are saved as you change them,
and every run logs them in its `identify_start` record. The defaults come from the literature,
from BioCLIP's documentation and from the `insect-detect-post` pipeline. The full list:
[SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md),
*Identification*.

| Setting | Default | Notes |
|---|---|---|
| **Use the GPU when it can run the model** | on | Much faster when the phone's GPU can run the model. The app checks each phone and uses the CPU otherwise, with the reason on the screen. |
| **CPU threads (0 = automatic)** | 0 = 2 threads | 4 threads are about a quarter faster but keep twice as many cores busy, so the heat pause comes sooner. Try other values with **Test speed**. |
| **Square crops** | on | The crop is the detector box made square on its longer side, so the insect is not distorted. Off: the box (plus the margin) is stretched to a square, so a long, thin insect looks squeezed. Which works better on pollinator photos is not yet tested. |
| **Crop margin** | 0 | The box itself, so the model sees as little flower or background as possible. |
| **Smallest box to identify** | 48 px | A smaller box is enlarged more than 4 times to the model's 224 px and is mostly blur. |
| **Crops per track ID (0 = all)** | 10 | Keeps the ten largest boxes of a track ID. It rarely removes anything and only limits the run time of long bursts. |
| **Ignore crops far less sure than the best (factor)** | 10 | A crop the model is far less sure about than the best crop adds no usable information. |
| **Confidence needed to call a rank identified** | 0.6 | 0.7 to 0.8 are common in ecological studies; none is tested on pollinators. |
| **"No organism" threshold** | 0.5 | Above this share for the "none of these" entries, a track ID is "no organism". |
| **Pause above battery temperature** | 43 °C | The same limit as **Pause the analysis above** on **Detection, track ID and identification settings** (opened from **Find animals in videos**); the run goes on 3 °C lower. |
| **Merge consecutive track IDs** | off | Joins a track ID to the previous one when the tracker lost the animal for a moment (the three checks are in a folded block below). When it is on, three fields appear under it. |
| **Largest gap between joined track IDs**, **Appearance similarity needed**, **Box size may differ by up to** | 3 s, 0.85, 50 % | Shown only with **Merge consecutive track IDs** on. |
| *Suspect track IDs (flags only, nothing is deleted)*: **Short: duration below**, **Short: detections below**, **Weak: detector confidence below**, **Weak: order confidence below** | 2 s, 3, 0.20, 0.50 | Flags only, nothing is deleted. The duration and detector-confidence limits follow the `insect-detect-post` software, so the two tools agree. |
| **CSV file only: rank of the "pred" columns** | family | Only for `tracks_<pack>.csv`; the screen always shows every rank. |

**What a change costs.** Most settings act only when the answers are scored, so changing them
never runs the model again. **Crop margin** and **Square crops** change what the model saw:
**Start** then opens the window **Crop settings changed**: **Keep stored crops** (fast),
**Recompute all crops** (a full run) or **Cancel**.
Details are in the folded block *What a re-run computes again* above.

<details>
<summary>Why the crop defaults were chosen</summary>

- **Crop margin 0 with Square crops on:** the detector box itself, squared on its longer side
  as in `make_bbox_square()` of insect-detect-post. So the model sees as little flower or
  background as possible without distorting the insect.
- The model always takes a 224 × 224 square, so switching Square crops off means stretching the
  box. pybioclip does the same with any non-square picture, and BioCLIP's training (open_clip's
  default `RandomResizedCrop`) squashes photos to a square by up to about 4:3, so that much
  stretch is familiar to it. Long, thin boxes (a fly from the side, an open butterfly) are
  distorted beyond that. Squaring instead costs pixels: on a 1.5:1 box a third of the square is
  background.
- The margin is a share of the box's longer side in both shapes (round 262), because legs,
  antennae and wings stick out by an amount tied to the insect's size, not to the box's shorter
  side.
- Neither shape nor margin is yet compared on pollinator photos. To compare them, re-run a
  session with *Recompute all crops* and another setting.
- **Smallest box to identify 48 px:** the model looks at every crop at 224 px, so a smaller box
  is enlarged more than 4 times and is mostly blur. On the default 1024 px photos that is an
  insect about 5 % of the photo side.
- **Crops per track ID 10** keeps a track ID's ten LARGEST boxes when it has more photos. The
  photo count per track ID comes from the session's photo schedule (live detection default: one
  photo per second for 10 s), so the cap rarely removes anything and only bounds the runtime of
  long bursts.

</details>

<details>
<summary>Merge consecutive track IDs: the three checks (round 210)</summary>

The tracker sometimes loses an insect for a moment and gives it a new track ID. When this
setting is on, a track ID that starts within the set gap after the previous one ended is joined
to it when three checks pass (round 212). The gap is 3 s by default, the same as the live
tracker's occlusion buffer; longer gaps risk joining two individuals of one species, which the
appearance check cannot tell apart.

1. **A compatible identification:** the same taxon at the shallower of the two identified
   ranks (for example Apidae, then *Bombus*).
2. **A similar appearance:** the cosine similarity of the two track IDs' combined image
   embeddings is at least the threshold (default 0.85). This is the strong signal: "the model
   sees the same animal".
3. **A similar mean box side** relative to the ROI (the yellow square): by default within 50 %
   of the larger one. This is a loose guard; 100 % disables it.

Position continuity is deliberately not used: within its buffer the tracker handles it, and
after a real loss the insect may re-enter the ROI anywhere. The union of the crops is then
identified again. Track IDs that overlap in time are never joined (two insects at once are two
track IDs). The outputs carry `track_ids` (JSON) / `merged_track_ids` (CSV, semicolon list), the
`merged` flag, and the summary counts `track_ids_merged` and `tracks_before_merge`.

</details>

<details>
<summary>Suspect track IDs: the rule and its sources (round 212)</summary>

Very short track IDs are often false detections, and a weak identification makes that more
likely. A track ID is flagged:

- `short` when its duration is below 2 s OR it has fewer than 3 detector frames;
- `low_det` when the mean detector confidence is below 0.2;
- `weak_id` when the probability at ORDER rank is below 0.5;
- `suspect` when it is short AND (low_det OR weak_id OR "no organism").

All four thresholds are settings. Nothing is deleted: the results table hides suspect track IDs
behind a switch, the Photos tab marks them, and the CSV keeps every row with `n_detections` and
a 0/1 `suspect` column, so the thresholds can be checked on your own data in R.

The duration and detector-confidence criteria follow the optional track filter of the
`insect-detect-post` software (Sittinger (2026), Software for post-processing of data captured
with the Insect Detect camera trap, v1.0.0, Zenodo, doi:10.5281/zenodo.21822140;
`metadata.filter_tracks`, defaults `min_dur_s: 2`, `min_det_conf: 0.2`), adopted here on purpose
so the two pipelines agree. That software is the post-processing companion of the Insect Detect
camera trap (Sittinger et al. 2024, PLOS ONE 19(4): e0295474). The identification-strength
criterion and the AND rule are FaunaPulse additions. Bjerge et al. (2022, Remote Sensing in
Ecology and Conservation) instead removed stationary detections repeating at the same position,
which is a tracker-side idea for later.

</details>

## Troubleshooting

| What you see | Why | What to do |
|---|---|---|
| *"GPU not used: This phone's graphics processor (GPU) cannot run this model, so the main processor (CPU) is used …"* | The model file is an old export that no phone's GPU can run (see [GPU details](#the-models-gpu-memory-and-speed)), or this phone's GPU cannot compile or hold it. | Download or export the model again if it is old. Otherwise nothing: the CPU is slower but gives the same answers. The exact reason from the phone (for example "Failed to compile model") is in the log only. |
| *"GPU not used: On this phone the GPU gave different answers from the CPU on a test picture …"* | This phone's GPU failed the check at first use. | Nothing: the app uses the CPU for that model until the next Android update. |
| *"GPU not used: The GPU failed with this model several times before on this phone …"* | Setting this model up on the GPU crashed or failed again and again on this phone, so the app no longer tries. | Nothing: the CPU gives the same answers, only slower. |
| *"GPU not used: This phone has N GB of memory …"* | The model is too large to set up on this phone's GPU without Android closing the app | Nothing: the CPU gives the same answers, only slower. |
| The model does not load at all | The phone has too little free memory (RAM) for the file (fp16 needs about 1 GB free, BioCLIP 2.5 about 2 GB), or the export is broken. | Check the export on the PC with `verify_parity.py` (fauna-pulse-models). |
| Every track ID comes out "no organism" | The name list has no rows for the animals in the photos (for example an orders-only test pack). | Use or build a wider name list. |
| Everything is "unidentified" | The confidence threshold is high for this size of name list, or the crops are poor (very small boxes give weak embeddings). | Lower **Confidence needed to call a rank identified** in **Advanced settings**, or check the crops. |
| Scoring is slow | A large name list (more than 100,000 names) takes a while per crop in this version. | Use a list restricted to a country or to some orders. |

## Files

The results are in `<session>/identification/`.

| File | Content |
|---|---|
| `embeddings_<model>.jsonl` + `.bin` | one record + one float32 vector per crop (`row` = vector index); `identify_start` / `identify_end` records with the run's settings and timing |
| `predictions_<pack>.jsonl` | per crop: the most probable names with probabilities |
| `tracks_<pack>.json` | per track ID: ladder, crops with weights, best single view, flags |
| `tracks_<pack>.csv` | one row per track ID; the column dictionary is in `README_identification.txt` next to it; the first columns match the `_final.csv` of `insect-detect-post` (Sittinger 2026); `device_id` is the device's name (the field notes' *Device ID*, else an own field of that name, else FaunaLapse's phone ID, else the phone model; DATA_GUIDE §8), the phone model is also the last column, `phone_model` |
| `crops_<pack>.csv` | every crop's own values and its `counted` flag |
| `summary_<pack>.json` | counts for the results screen, the session summary and the Dashboard |

[DATA_GUIDE.md](DATA_GUIDE.md) §8 documents the records and columns.

**Join the results with the detection data in R or Python.** Both sides share the same keys, so
no extra bookkeeping is needed:

| Key | In the identification files | In the detection data |
|---|---|---|
| session | the session id (folder name) | the session id (folder name) |
| track ID | `track_id` in `tracks_<pack>.csv` | `track_id` inside the `detections` records of `session.jsonl` |
| one crop | the photo file name (`src` in `tracks_<pack>.json` and `predictions_<pack>.jsonl`) with the box coordinates | the photo file name (`jpeg` in the log's detection records) with the box coordinates |

A merged track ID lists all its ids in `merged_track_ids`. So a join on `track_id` (or on file
name for work per crop) lines up detections, photos and identifications.

## How the answer is computed

*This section and the next two are for researchers and developers.*

1. **Crop:** cut the detector box from the photo, made square (setting) and resized to the
   model input (224 px).
2. **Embed:** the model turns each crop into a vector (a list of numbers describing its
   content). Vectors are stored, so scoring again costs nothing.
3. **Score each crop:** compare the vector with every name in the name list, turn the result
   into probabilities, and add species up the taxonomy.
4. **Combine:** average the crops' vectors (surer crops weigh more), score the average once, and
   build the ladder from kingdom to species.
5. **Export the alternatives:** other ways to combine the crops are written to the files, so
   they can be compared in R.

<details>
<summary>The five steps in full</summary>

1. **Crop:** the detector box plus a border of *margin* × its longer side on every side (margin
   0 by default), widened to a square on its longer side when **Square crops** is on (default),
   or kept in the box's shape and stretched to the square input when it is off (round 262).
   Padded with a neutral colour where it leaves the photo, and resized to the model input
   (224 px). Boxes under 48 px are skipped as too small. For high-res photos the in-sync
   `_live.jpg` companion is used (the logged boxes were observed on that frame).
2. **Embed:** the model turns each crop into a unit vector. Stored, so re-scoring is free.
3. **Score each crop:** the vector is compared with every name in the pack (cosine similarity
   × the model's scale, softmax); species masses are summed up the taxonomy.
4. **Combine:** the crops' vectors are averaged, each crop weighted by its own top-1
   probability, and crops below the surest crop's top-1 divided by the drop factor are left out
   (round 219; no image-quality weights). The average is scored once and species masses are
   summed up the taxonomy. The ladder is walked top-down on those pooled masses, and Agree is
   counted from the per-crop best guesses. The unit-length average is also the vector the merge
   check compares.
5. **Export the alternatives:** per rank the plain mean (`p_mean_<rank>`), the best single crop
   (`p_max_<rank>`), the agreeing-crops mean (`p_agree_<rank>`) and the agreement share
   (`agree_<rank>`), plus every crop's own values and its `counted` flag in `crops_<pack>.csv`.

</details>

<details>
<summary>How a track ID's Conf. is computed: pooling before the softmax (round 219)</summary>

Each crop is classified on its own for the tables. The model turns the crop into a vector,
compares it with every species name it was given (cosine similarity times the pack's logit
scale, divided by the calibration temperature), and turns the similarities into probabilities
with a softmax. The probabilities of the species under a taxon are added up: this is the crop's
own Conf. for that taxon, the "Conf. <taxon>" column of the crops table.

The track ID's answer is NOT an average of those per-crop values. Instead the crops' vectors
themselves are averaged, each crop weighted by its own top-1 probability (its Species conf.).
Crops whose top-1 probability is below the surest crop's divided by a factor (default 10) are
left out. The average, deliberately not re-normalised, is classified once in the same way.

Averaging before the softmax is the "Average Logit" rule that Dussert et al. (2025) found best
calibrated for camera-trap image sequences. Their "Average Score", the average of per-image
probabilities, was systematically underconfident, which is what FaunaPulse did in rounds 217
and 218.

Consequences:

- Photos that agree reinforce each other, so a track ID's Conf. can exceed every single photo's
  value.
- Photos that disagree pull the average apart and lower every Conf.
- A photo the model is far less sure about than its best photo carries no usable information
  and is left out (the crops table marks it "left out of the combined answer").

Every number can be recomputed off the phone with `bioclip_export/reproduce_track_conf.py`
(fauna-pulse-models) from the stored embeddings and the label pack.

</details>

<details>
<summary>Validation status (honest)</summary>

The rule and its defaults have NOT been tested on pollinator data. Origins:

- averaging before the softmax: Dussert et al. 2025 (European mammals, 22 classes, five models,
  three test sets; they flag hierarchical and very-many-class settings as future work);
- the certainty weights and the drop factor 10: FaunaPulse choices (the unweighted rule
  flattens to nothing with 38 000 candidate names);
- the threshold 0.6 (0.80 until round 216, 0.6 since round 217): the developers' choice (0.7 to
  0.8 are common in ecological studies, Whytock et al. 2021, Dussert et al. 2025);
- the calibration temperature 1.0: no calibration. Dussert et al. fit one temperature on a
  labelled test set and keep it; the pack format carries the field.

The planned check uses expert-labelled smartphone crops (Zenodo 10.5281/zenodo.15096610):
accuracy per rank, a fitted temperature, and a comparison of pooling rules on track IDs with
three or more crops. Until then, treat Conf. as a model score with a known direction of bias
(sharper than the per-crop average) rather than a calibrated probability.

</details>

<details>
<summary>path_conflict and the rival taxon (round 221)</summary>

A track ID is `path_conflict` when, at some rank, the taxon with the most mass overall is not a
child of the ladder's taxon one rank up. The chosen branch's mass is spread over several
sub-taxa, while another branch's smaller mass sits mostly in one. That rival is kept per ladder
row and exported as `rival_*`. With `tau` >= 0.5 it can only happen below the reported rank.

</details>

<details>
<summary>Columns for other pooling rules</summary>

Two more numbers accompany Conf.:

- **Agree**: how many crops, judged alone, put their top species under the taxon, shown as a
  share (Agree, "50 %") and a count (Crops agree, "5/10"; one column each since round 222).
- In the files, for every rank: the plain mean (`p_mean_<rank>`), the best single crop
  (`p_max_<rank>`) and the mean over the agreeing crops (`p_agree_<rank>`). So
  insect-detect-post's weighted probability = `agree_<rank>` × `p_agree_<rank>`, and other
  pooling rules can be compared in R without re-scoring.

</details>

<details>
<summary>Names used only down to genus or family (version 2 name lists, round 322)</summary>

The names are those of TreeOfLife-200M as the BioCLIP authors publish them; none is corrected or
removed. A few rows are not in the plain form "genus, epithet":

- two different genera in one row, or authors, codes or a placeholder such as "spec" in the
  species field: used down to genus;
- the kingdom "Metazoa", which the dataset card lists as unresolved: read as Animalia and used
  down to family.

The list builder leaves the slots below that rank empty, and the app counts a row only down to
the rank above its first empty slot (the same rule as for a gap in the source taxonomy). So such
a row adds to its genus or family but never names a species: a crop that matches "Bombus spec"
is named "Bombus". It concerns 109 of the 34,978 Europe names of BioCLIP 2 and 613 of the 17,130
mammal and bird names (none in the BioCLIP 2.5 Europe list). The pack header lists each such
row with its names as published (`name_rules.rows`). The version 1 lists use every row as
published.

Details: the model cards on Hugging Face (section *Names*; the ⓘ card of a name list on
Download & import models links its model card, which also lists newer versions) and
`bioclip_export/build_label_pack.py` of fauna-pulse-models.

</details>

## The models: GPU, memory and speed

<details>
<summary>BioCLIP on the GPU (round 242)</summary>

The GPU switch (on by default) asks LiteRT to compile the model for the phone's GPU, the same
path the live detector uses.

- **Old files.** BioCLIP files exported before round 242 cannot run on any GPU: their attention
  layers use 5-dimensional tensors, which the phone's GPU engine rejects. So the app falls back
  to the CPU. The raw note ("Failed to compile model") goes to the log only. The screen shows
  "GPU not used: This phone's graphics processor (GPU) cannot run this model, so the main
  processor (CPU) is used …", and adds that a model you converted yourself needs converting
  again with the current tool. The catalogue's files are new exports.
- **New files.** Files exported since then (fauna-pulse-models `bioclip_export`,
  `--attention 4d`, the default) run entirely on the GPU with the same weights and maths. The
  downloadable `bioclip-2_224_fp16.tflite` is such a file.
- **Measured** on the Xiaomi test phone (plugged in): 0.27 s per crop on the GPU instead of
  2.6 s on the CPU. Identifying a session of 11 crops took 9.9 s instead of 35 s, with the same
  answer for each track ID.

</details>

<details>
<summary>The GPU check at first use</summary>

GPUs differ between phones and Android versions, so the app checks each one. The first time a
model runs on a phone's GPU, it embeds a fixed test picture on the GPU and on the CPU (one model
in memory at a time). It keeps the GPU only when the two embeddings agree (cosine ≥ 0.995);
otherwise it uses the CPU and says why.

The verdict is stored per model file and Android build (`embedder_gpu_checks.txt` in the app's
private files). So a system update, which usually brings new GPU drivers, checks again, and the
first load takes longer once (about 20 s on the test phone).

The GPU computes with 16-bit numbers. On the test phone its embeddings matched the CPU to 0.9995
on the test picture and 0.994 to 0.997 on real crops. That moved a track ID's confidence by up
to 0.03 without changing any answer. 32-bit GPU maths would match more closely, but needs about
1.2 GB of GPU memory for BioCLIP 2. Android closed the app for lack of memory on the 7.4 GB test
phone, so it is not offered.

</details>

<details>
<summary>The memory guard (round 243) and the CPU engine</summary>

Setting a model up on the GPU also needs several times its file size in ordinary memory for a
moment. On the second test phone (Samsung Galaxy M12: 3.9 GB, Exynos 850 with a Mali-G52 GPU)
the app reached 2.7 GB while BioCLIP 2 was being set up there, and Android closed it.

Since round 243 the app first compares the need, about 4.5 × the file size, with the phone's
memory, and tries the GPU only when that stays under 60 % of it. Otherwise it runs on the CPU
with a note such as "GPU not used: This phone has 3.9 GB of memory; setting this model up on
the GPU needs about 2.7 GB, so it runs on the CPU." On that phone the CPU takes about 15.5 s per crop (2
threads; 10 crops in about 3 minutes), so identification there is a job to leave running on the
charger.

`identify_start` records `accelerator`, `gpu_note` (why the GPU was not used) and
`gpu_agreement` (DATA_GUIDE §8). Since round 211 the reason is shown on the screen after loading
(and in the "Last run" card) instead of only in logcat.

The thread count is passed to the CPU engine's (XNNPACK) thread pool, so it does change how the
matrix maths is spread. Whether more threads are faster on a given phone is an empirical
question. **Test speed** (Run section) loads the model with the current settings, embeds 10 of
the session's own crops after a warm-up, one at a time with a progress line ("Crop 3 of 10,
about 40 s left"; round 247, was 8 in one call with no feedback), and reports seconds per crop.
So GPU on/off and thread counts can be compared in a minute each (a few minutes on an older
phone's CPU); the app does not claim a speed it has not measured.

</details>

<details>
<summary>CPU threads: measurements (rounds 226 and 250)</summary>

Round 226 chose the thread count with the engine benchmark
(`integration_test/cpu_threads_check_test.dart`). Measured again in round 250 on the Xiaomi
(BioCLIP-2 4d export, plugged in, battery 32 to 34 °C, 3 runs per value, forward and reverse
order):

| Threads | Seconds per crop |
|---|---|
| 1 (LiteRT's own default, which "0" meant until round 226) | 4.6 to 5.4 |
| 2 | 2.6 to 3.0 |
| 4 | 1.9 to 2.0 |
| 8 | 2.0 |
| GPU | 0.26 |

Round 226 had measured about 3.5 times longer at every thread count (23.4, 9.4, 7.1 and 7.7 s),
with the same ratios. The cause is not known (probably a phone slowed by heat, as the Snapdragon
888 throttles hard under long loads), so those absolute numbers should not be used.

"0 = automatic" means 2 threads, the same as for the detectors. 4 is about a quarter faster but
keeps twice as many cores busy. On a long run the extra heat can cost more in thermal pauses
than it saves, so it is left for users to try with "Test speed" rather than made the default.

</details>

<details>
<summary>BioCLIP 2.5 (round 264)</summary>

BioCLIP 2.5 Huge (ViT-H/14) is the larger successor of BioCLIP 2 (2.1 times the computation per
crop, 1024-number embeddings). Its phone file is made the same way
(`export_image_tower.py --model bioclip-2.5`, GPU-friendly attention, fp16: 1.27 GB). Against the
original PyTorch model it gave the same top family and top species on 34 of 34 bumblebee crops
(cosine 1.0000).

Measured on the Xiaomi test phone (Xiaomi 11T Pro, Snapdragon 888, 7.4 GB, plugged in):

| | BioCLIP 2 (fp16) | BioCLIP 2.5 (fp16) |
|---|---|---|
| GPU | 0.27 s per crop | not possible on this phone (memory, below) |
| CPU, 2 threads (the automatic choice) | 2.6 s per crop | **5.3 to 5.6 s per crop** (load 9 s) |
| CPU, 4 threads | | 16.6 s per crop (slower) |
| app memory while running on the CPU | | 2.8 GB (3.4 GB at the peak) |

Why no GPU: setting BioCLIP 2 up on this phone's GPU took the app to 3.8 GB for a moment (6
times its 0.6 GB file) and left 0.55 GB free on the phone. BioCLIP 2.5 would need about 7.8 GB,
more than the phone has. The memory guard above already sends it to the CPU with a note. A phone
with 12 GB or more might run it on the GPU (untested). So BioCLIP 2.5 is an overnight,
plugged-in choice: about 1.5 hours per 1000 crops on this phone.

An 8-bit (int8) file was also tried: half the size and 1.6 GB of memory, but slower on the
phone's CPU (9.2 s per crop), and it changed the top family on 2 of 34 crops (one where the
original was sure) and the top species on 4 of 34. It is not recommended.

Whether BioCLIP 2.5 identifies this project's pollinators better than BioCLIP 2 has not been
tested yet (the one test session here is an edited compilation video, not a field recording, fit
for timing only).

</details>

<details>
<summary>insectDCT, a fixed-class classifier (round 266)</summary>

insectDCT's hierarchical classifier V7 (Bjerge et al. 2026; weights from the authors' zip that
the insectDCT README links on Google Drive, see the model card
[insectdct-cls-v7-tflite](https://huggingface.co/Valen-Peregrine/insectdct-cls-v7-tflite)) knows
104 classes on three levels (for example `Hymenoptera_bees` > Apidae > *Bombus pascuorum*),
instead of comparing a crop with a label pack's names. It comes as two files with the same name:
the model (`insectdct-cls-v7-eff2s_224_fp16.tflite`, 42 MB) and its **class list**
(`insectdct-cls-v7-eff2s_224_fp16.fpack`, 14 kB: every class with its kingdom ... species).

It runs like BioCLIP: the same crops, the same combination per track ID, ladder, threshold,
tables and files. Differences:

- Each crop gets a score per class on each level. A class's probability combines its own level
  with its two parent groups, so it is only likely when all three levels agree.
- Some classes stop above species: `Bombus` (genus only), `Coleoptera` (other beetles),
  `Apoidea small` (a group of bees, which has no rank here: it counts for the order
  Hymenoptera). The ladder then stops there. The model's own class is kept beside the taxonomy
  (*Model's own class* on the track ID's sheet, `model_class` in the files), because it can say
  more (a bee, not just Hymenoptera).
- Its 104 classes are fixed: the flower visitors of insectDCT's camera-trap training data (list:
  `classifier_export/taxa/insectdct-cls-v7.csv` in fauna-pulse-models). Anything else is forced
  into the nearest class or "Vegetation" ("no organism").
- Speed on the Xiaomi test phone: 0.02 s per crop on the GPU (0.15 s on its CPU), more than ten
  times faster than BioCLIP 2 on the GPU.

Why the EfficientNetV2-S version: insectDCT ships three networks. The authors' published test
results (version 6) rank ConvNeXt-Base first, EfficientNetV2-S second, ResNet50 third (F1
averaged over classes at level 3: 0.76, 0.73, 0.69). ConvNeXt-Base runs only on the Xiaomi's CPU
(0.7 s per crop; its GPU results are wrong there), so EfficientNetV2-S is the best one the GPU
runs. The other two files and their class lists are made the same way
(`classifier_export/README.md` of fauna-pulse-models) and should work the same way (ResNet50 on
the GPU, ConvNeXt-Base on the CPU; not tried in the app). Whether insectDCT or BioCLIP names this
project's pollinators better has not been tested yet.

</details>

<details>
<summary>What the times on the screen measure (round 250)</summary>

*Test speed* and the progress line ("the model takes 0.27 s per crop") time the model alone: a
stopwatch around each call, which returns only once the GPU or CPU has finished that crop.

A run does more: it loads the model, reads each photo and cuts its crops, and after the last
crop combines the crops per track ID and scores them against every name of the pack. *Last run*
therefore gives the whole time, model loading included (the same clock as *Elapsed*), and the
model's share of it. It counts in the singular when there is one ("1 crop", "1 heat pause"). The
time-left estimate starts with the first crop (before round 250 it counted the model loading as
crop time and started too high).

Example, a 20-crop session on the Xiaomi test phone (GPU, 35,264-name pack): about 18 s in all,
of which the model 5.4 s (0.27 s per crop), reading 19 photos and cutting the crops about 3 s,
combining and scoring 4 s, and loading the model the rest.

`bioclip_gpu_check_test.dart` checks these numbers with three clocks (the app's stopwatch, the
plugin's own clock around the model, and the phone's wall clock), which agreed to 0.01 s per
crop, and checks that the GPU computes every crop anew. The speed fits the chip: one crop is
about 157 billion arithmetic operations (the converter's count for BioCLIP 2's image tower), so
0.27 s is about 0.6 trillion per second on the GPU, and 2.6 s about 0.06 trillion on two CPU
cores.

</details>

## Credits and citations

- **From BioCLIP and pybioclip (Imageomics):** the model and the TreeOfLife-200M name
  embeddings, zero-shot identification from hierarchical taxonomic names, the label-subset
  mechanism the packs implement (`--subset` / `apply_filter`), the softmax with the model's
  logit scale, the roll-up of species probabilities to higher ranks, and the recommendation to
  restrict candidates to a regional GBIF species list ("Geo-Restricted Taxon List Predictions"
  in the pybioclip docs). Cite Stevens et al. (2024) and Gu et al. (2025), as the authors'
  [BioCLIP 2 model card](https://huggingface.co/imageomics/bioclip-2) suggests.
- **From `insect-detect-post`** (Sittinger, M. 2026, AGPL-3.0, Zenodo
  https://doi.org/10.5281/zenodo.21822140), re-implemented in FaunaPulse's own code with no lines
  copied: the API-based construction of the regional list (GBIF occurrence facets) and its
  TreeOfLife-to-GBIF key mapping, the per-track-ID CSV column names of its
  `_classified_final.csv`, and the square-crop rule of its `make_bbox_square()`.
- **"None of these" rows** follow common practice, with the `none_*` classes of the
  classification dataset of Sittinger (Zenodo https://doi.org/10.5281/zenodo.8325384) as the
  precedent for insect crops.
- **Pooling of crops per track ID** follows the "Average Logit" rule of Dussert et al. (2025,
  Remote Sensing in Ecology and Conservation 11:88-99), with FaunaPulse's certainty weights, drop
  rule, ladder and agreement columns. Kittler et al. (1998, IEEE TPAMI 20:226-239) is the
  theoretical reason for averaging rather than multiplying evidence from correlated views.
- **The result differs from insect-detect-post:** there, `pred_prob_weighted` is the mean
  probability of the images that voted for the winning candidate times the share of images that
  voted for it, and `pred_prob_mean` the mean over those voting images (`metadata_processor.py`).
  FaunaPulse keeps the column names so the same scripts read both outputs, with its own formulas.
- **The version 2 Europe name lists** (built in fauna-pulse-models) choose their
  species as insect-detect-post v1.1.0 does (Sittinger 2026,
  https://doi.org/10.5281/zenodo.23404778): its published table that maps the BioCLIP names to
  accepted species of the Catalogue of Life (Bánki et al. 2026,
  https://doi.org/10.48580/dgy8b), and the same GBIF query, which counts the records per accepted
  species and keeps the species of Diptera, Hymenoptera, Coleoptera and Lepidoptera with at
  least 3 records in Europe. The model cards on Hugging Face give the full citations of the
  names, the lists and the method.

<!-- Reference links used in this file -->

[bioclip]: https://imageomics.github.io/bioclip-ecosystem/index.html
