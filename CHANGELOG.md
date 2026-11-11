<!--
Versions follow the `MAJOR.MINOR.PATCH` scheme of the `version:` field in
`pubspec.yaml`, and each release is tagged `v<version>` on GitHub. While the app is
a research preview, versions carry a SemVer pre-release suffix (`0.7.0-alpha.1`
and `0.8.0-alpha.1`, then beta from `0.9.0-beta.1`) and the GitHub release is marked as a
pre-release.
-->

## Next release (not released yet)

Faster AI on the phone's processor, a list of the frame rates each camera offers, and more
readings of the phone during long runs.

- **Faster on the processor (CPU).** When a model runs on the phone's processor instead of
  its graphics chip (GPU), it now computes with 16-bit numbers where the model file and the
  processor allow it (most phones of the last few years). Detection models are about twice
  as fast this way. BioCLIP 2 is 1.6 to 2.5 times faster and needs about 0.75 GB of memory
  instead of 1.25 GB. Other models and older phones run as before. Session records say which
  maths ran (`cpu_16bit`).
- **Identify organisms.** The last step, which combines the results of each track ID, is 3
  to 7 times faster. It uses several processor cores; the new setting *Cores for combining
  results* chooses how many. Once per phone, a short self-test finds the fastest number of
  processor threads for the model.
- **Camera frame rate.** Settings list the frame rates that the phone's camera offers (they
  differ between phones and lenses). Before, a rate the camera did not offer ran at the next
  lower one without a word. A detector rate of 0, the new default, means "same as the
  camera".
- **Phone readings.** Next to the battery temperature, the app records the phone's memory,
  the processor use of FaunaPulse and, where the phone allows it (for example Xiaomi
  phones), the temperature of the processor and the graphics chip. They show on the camera
  screen, on the *Identify organisms* and *Find animals in videos* screens, and as graphs in
  the session summary. *Identify organisms* now saves its readings too.
- **Session summary and Dashboard.** Bar charts have a value axis. The track ID timeline
  moved into *Extra graphs*.
- **Detection models only.** Model files made for segmentation, pose or rotated boxes are
  refused when you import them, with the reason.
- The Sessions list and Home open faster when the phone holds many sessions, and the Video
  tab opens long sessions with less memory.
- **Privacy policy** is in the Home menu, and the policy was brought up to date with the app.
- Fixed: the text box of *Describe the problem* shrank to one line under the keyboard; a red
  error screen in the Photos tab after changing the sample size.
- The user guides were rewritten for easier reading.
- Updated LiteRT, the library that runs the models, to 2.3.2.

## 0.10.0-beta.1 (2026-10-28)

Analyses go on in the background, imported files are checked more strictly, and a few
privacy and comfort changes.

- **Analyses go on in the background.** *Find animals in videos*, *Find animals in photos*
  and *Identify organisms* keep running while you use other apps or the screen is off. A
  notification says so; tapping it opens the running screen, where *Stop* ends the run
  (what is done is kept). On Android 15 and newer, Android protects such work for about
  6 hours a day. If Android closes FaunaPulse during an identification, the next opening
  says so and offers *Continue*; nothing starts by itself. When there is too little free
  memory to load BioCLIP in the background, the identification waits until you open
  FaunaPulse again, instead of being closed by Android.
- **Safer files.** Model files, name lists and photos that you import or download can no
  longer close the app, also when they are damaged or made to harm; FaunaLapse zips, name
  lists and videos are checked more strictly. Your own model file is no longer replaced by
  a download with the same name.
- **Privacy.** Saved and shared crops carry the position from the field notes unless the
  new switch *Add the position to exported crops* (Session settings) is off. Problem
  reports leave out the field notes you typed and every position. Spreadsheet cells that
  start like a formula are made harmless.
- **Device ID** field on the Field notes page, above Sample ID: it names the phone in the
  results, so phones of the same model stay apart.
- Notes that come back every time have **Don't show again**; *Show tips and notes* in the
  Home menu brings them back. The message after saving crops stays 10 s.
- The name lists offered are the v2 lists; the 32-family demo lists are no longer offered.
  The info card of each model offered links its model card on Hugging Face.
- When Android closes FaunaPulse in the background (for example while a link is open in
  the browser), most screens come back as you left them instead of starting over on Home.
- Fixed: a download hung when the storage filled up; a damaged detection model was
  reported as unreadable videos.
- Updated the Guava library (security fix).

## 0.9.0-beta.1 (2026-10-18)

The first beta: the features are in place for field use, bugs are still possible, and from
this version on an update keeps your sessions and settings.

- **No AI model inside the app any more.** The home screen asks what you want to watch
  (pollinators on flowers, insects on a flat surface, mammals and birds), suggests
  published models for it and downloads them once from the project's model pages on
  Hugging Face: the flat-bug insect detectors (suggested first, as a demo) and insectDCT,
  MegaDetector V6, the insectDCT insect classifier, and BioCLIP 2 or 2.5 with their name
  lists. **Download & import models** lists every model and name list on the phone with its
  licence and source; your own models can still be imported or downloaded from a link
  (detection models are no longer limited to 30 MB: any model file up to 2 GB). The models
  have new file names; files downloaded with an earlier version are renamed when the app
  starts, so they are not downloaded again. On the "What do you want to watch?" pages each
  chosen file shows a tick when it is on the phone, or its download size. The camera
  starts without a model and asks for one only for live detection.
- **AI later:** *Find animals in photos* and *Find animals in videos* find animals, track
  IDs and names after recording, also in videos imported from the phone's gallery. The
  video player shows the AI's boxes and a time bar of the track IDs.
- Recording: time-lapse bursts can be saved as short video clips of the yellow square;
  live AI can also save video; the camera sleeps between bursts; a recording continues
  with the screen off, and the screen can switch off by itself after some minutes; a clean
  stop at low battery or low storage.
- Field notes (with your own fields, site photos and a GPS accuracy goal) are saved with
  every session; a *Before you record* sheet checks the phone for the field.
- Identification: the insectDCT fixed-class insect classifier as a second option;
  BioCLIP 2 runs on the phone's graphics processor where the phone allows it (checked once
  per phone); one score per track ID from all its photos.
- New Sessions screen (search, filters, select several) and Dashboard (track IDs per hour
  watched, by time of day, by day and by name). "Visit" is now "track ID" everywhere, and
  a track length runs from the first sighting to the last.
- Photo sessions of the sister app FaunaLapse can be imported for *AI later*.
- Menu, *Cite FaunaPulse*: the citation of the installed version.
- Smaller app: the normal build leaves out the Snapdragon NPU runtime; detection on the
  main processor uses two threads by default (about twice as fast as one).
- Settings you type are kept as typed: a number box never replaces a number silently
  (it says what is allowed), a comma works as the decimal point, and no setting changes
  another one behind your back (New-track confidence is no longer raised by the
  confidence threshold; a note says when the two are too close). The GPU switch and the
  CPU threads apply at once; closing the camera Settings without Apply offers to apply.
  Fixed: a short occlusion tolerance on videos gave no track IDs; "Smallest box to
  identify" and "Crops per track ID" now also apply when results are scored again.

## 0.8.0-alpha.1 (2026-09-23)

- **Identify organisms (experimental):** after a session, the saved photos of every
  tracked visit can be identified on the phone with the BioCLIP 2 vision model, against
  a label pack (the list of candidate taxa), with a confidence per taxonomic rank. The
  model and the label pack are prepared on a computer, see
  [`docs/IDENTIFICATION.md`](docs/IDENTIFICATION.md).
- Session summary, Photos tab: choose how many photos to show (10 / 50 / 100 / All) and
  draw a new random sample; identified taxa appear under the photos.
- The citation title now reads "FaunaPulse: a smartphone application for on-device
  detection, tracking and identification of animals" (`CITATION.cff`, and Zenodo from
  this release on). Earlier Zenodo versions keep their original title.

## 0.7.0-alpha.1 (2026-09-04)

The first public, citable release: an early research preview, tagged so it can be
archived on Zenodo with a DOI and installed from GitHub Releases.

- The app ships with a general-purpose detection model, so it works straight
  after installation and needs no download in the field. Insect detection still
  requires a purpose-trained model (see the README).
- Added a privacy policy: nothing is collected or transmitted, everything stays on
  the phone.
- Release builds are now signed with a proper release key and refuse to build if
  the signing key or the bundled model is missing, so a broken build can never be
  published by accident.
- Documentation: fixed the Field Guide title, added a physical field-setup section
  (mounting, distance, power), and made the README state clearly what the bundled
  model can and cannot do.
- For transparency, the extra-detailed AI-assisted development journal lives in [`docs/AGENT_CHANGELOG.md`](docs/AGENT_CHANGELOG.md)
  with an overview at [`docs/AGENT_CHANGELOG_OVERVIEW.md`](docs/AGENT_CHANGELOG_OVERVIEW.md).
- The Ultralytics plugin (`packages/ultralytics_yolo`, modified for FaunaPulse) lists its changes in [`packages/ultralytics_yolo/FAUNAPULSE_FORK.md`](packages/ultralytics_yolo/FAUNAPULSE_FORK.md).
