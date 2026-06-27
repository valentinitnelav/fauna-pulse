# Installing & Testing Pollinator Monitor

A step-by-step guide for collaborators. No mobile-development experience is assumed.

**Pollinator Monitor** is an Android app that detects flower-visiting insects in real time
and logs their visits. This guide shows two ways to get it running on an Android phone:

| Track | Who it's for | What you need | Effort |
|-------|--------------|---------------|--------|
| **A. Install the ready-made app** (recommended) | You just want to **test** the app | An Android phone + the app file we send you | ~10 min, no coding |
| **B. Build from source** | You want to **change the code** | Windows/macOS/Linux computer + developer tools | ~1 hour first time |

> **Phone requirement:** a reasonably modern Android phone (Android 8 or newer
> recommended). iPhones are not supported yet.

---

## Track A — Install the ready-made app (no coding)

### A1. Allow your phone to install the app

Because the app is not on the Google Play Store, you tell Android to trust it:

1. Open **Settings → About phone**, tap **Build number** 7 times to unlock
   *Developer options* (only needed for some phones / for USB transfer).
2. When you later tap the app file, Android will ask to **“Allow installs from this
   source”** — say **Allow**. (Exact wording varies by phone brand.)

### A2. Get the app file (`.apk`)

We will send you the app as an `.apk` file in one of these ways:

- **GitHub Releases** (if you have access to the private repo): go to the repo →
  **Releases** → download the latest `app-release.apk` (or `app-debug.apk`).
- **A private download link** (e.g. shared drive) — just download the `.apk`.

Save it to your phone (download it directly on the phone, or copy it over USB).

### A3. Install it

On the phone, open your **Files** app, tap the downloaded `.apk`, and follow the prompts
(**Install**). If a “Play Protect” warning appears, choose **Install anyway** — this is
expected for apps outside the Play Store. You should now see **Pollinator Monitor** in
your app list.

### A4. Add the detection models

The app ships **without** model files (they are shared separately — see
[Getting the models](#getting-the-models)). Once you have one or more `.tflite` model
files on the phone, load them in **either** way:

- **In-app (easiest):** open **Pollinator Monitor → Settings (gear icon) → Import…**,
  then pick the `.tflite` file(s) you downloaded (e.g. from your **Downloads** folder).
  You'll see “Imported N model(s).”
- **Over USB (drag-and-drop):** connect the phone to a computer; the app keeps a
  `…/Pollinator Monitor/models/` folder you can drop `.tflite` files into directly.

Imported models then appear in the app's **model dropdown** at the start of a session.

### A5. Run a test session

1. Open the app, grant **Camera** and **storage** permissions when asked.
2. Pick a model from the dropdown, choose a save folder, drag the square **region of
   interest (ROI)** over a flower, and press **Record**.
3. Detections, tracks, and cropped images are saved on the phone; transfer them later
   over USB.

✅ That's it — no terminal, no coding.

---

## Track B — Build from source (for developers)

Use this only if you want to modify the app. The app is a **Flutter** project (Dart
language) with the vendored YOLO plugin under `packages/ultralytics_yolo/`.

### B0. Install the tools (one time)

Install these for your operating system (follow the official links — they stay current):

1. **Git** — <https://git-scm.com/downloads>
2. **Flutter SDK** — <https://docs.flutter.dev/get-started/install>
   (choose **Android** as the target; on the install page pick **Windows / macOS /
   Linux** as appropriate). This also guides you through the **Android SDK** /
   **Android Studio** (needed for the Android build tools and `adb`).
3. **VS Code** — <https://code.visualstudio.com/> + the **Flutter** extension
   (which pulls in the Dart extension).

Then verify everything is set up:

```bash
flutter doctor
```

Fix anything it flags (especially “Android toolchain” and “Android licenses”):

```bash
flutter doctor --android-licenses   # accept all
```

> **Per-OS notes**
> - **Windows:** if your phone isn't detected over USB, install your phone maker's
>   **USB driver** (or the “Google USB Driver” via Android Studio → SDK Manager → SDK
>   Tools). Use **PowerShell** for the commands below.
> - **macOS:** USB usually works out of the box. If `adb` isn't found, ensure
>   Android *platform-tools* are on your `PATH`.
> - **Linux:** you may need `udev` rules for your phone (see Flutter's Linux setup).

### B1. Get the code

```bash
git clone git@github.com:valentinitnelav/pollinator-monitor.git
cd pollinator-monitor
flutter pub get
```

(If you don't use SSH, clone the HTTPS URL shown on the GitHub repo page instead.)

### B2. Add the models

Models are **not** in the repo (see [Getting the models](#getting-the-models)). Two
options:

- **Easiest:** build/run first, then use the in-app **Import…** button (Track A4).
- **Bundle them into your build:** copy the files you were given into
  `assets/models/` (general models) and `assets/models/custom/` (custom detectors)
  *before* building. These folders are git-ignored, so your models never get committed.

### B3. Run on a connected phone

1. On the phone: **Settings → Developer options → enable USB debugging**, plug in USB,
   and approve the “Allow USB debugging?” prompt.
2. Check the phone is seen:

   ```bash
   flutter devices
   ```
3. Launch the app (debug):

   ```bash
   flutter run
   ```

### B4. Or build an installable `.apk` to share

```bash
flutter build apk --release     # or: flutter build apk --debug
```

The file appears at `build/app/outputs/flutter-apk/app-release.apk` (or
`app-debug.apk`). That's exactly the file used in **Track A**. Share it via a GitHub
Release or a private link.

> Tip: a **debug** APK needs no signing setup and is fine for internal testing. A
> release APK may require a signing key — not needed just to test among collaborators.

---

## Getting the models

Model weights (`.tflite` files) are **deliberately not stored in this repository**, for
two reasons: they are large, and **some detectors belong to collaborators and must not
be redistributed**.

- The maintainer will send you the model files you're permitted to use via a **private
  channel** (direct transfer or a shared-drive link).
- **Do not** re-share models you receive, commit them to git, or upload them anywhere
  public. Treat collaborator-owned models as confidential.
- To use a model, load it with the in-app **Import…** button or USB drag-drop
  (Track A4). The app lists any `.tflite` it finds; nothing else is required.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| **Phone not listed in `flutter devices`** | Enable **USB debugging**, approve the on-phone prompt, try a different USB cable/port. Windows: install the phone's USB driver. |
| **“App not installed” / “Play Protect” blocks it** | Choose **Install anyway** / allow installs from this source (Track A1). |
| **`flutter doctor` shows Android license errors** | Run `flutter doctor --android-licenses` and accept all. |
| **App opens but the model dropdown is empty** | You haven't imported a model yet — do Track A4. |
| **Camera is black / no detections** | Grant Camera + storage permissions in the phone's app settings; make sure a model is selected. |

For anything else, send the maintainer the exact error text (and a screenshot of
`flutter doctor` for Track B issues).
