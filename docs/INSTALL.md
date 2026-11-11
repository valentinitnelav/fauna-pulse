# Installing and testing the FaunaPulse app

This page shows how to get FaunaPulse onto an Android phone and how to add AI models to it. It
is a step-by-step guide for testers and collaborators. Building the app from source and the
parts only maintainers need come later on the page. Long explanations are in folded blocks:
click a line that starts with ▸ to open it.

> **In short**
>
> - The simplest way: install FaunaPulse from
>   [Google Play](https://play.google.com/store/apps/details?id=com.faunapulse.app). Google Play
>   can also install updates automatically.
> - Without Google Play: download the `.apk` file from the GitHub
>   [Releases](https://github.com/valentinitnelav/fauna-pulse/releases) and install it
>   ([Track A](#track-a-install-a-fresh-apk-release-no-coding)), or let
>   [Obtainium](#a2b-install--auto-update-via-obtainium) install it and keep it up to date.
> - The app comes with no AI model. Step 1 on Home (**AI models**, **What do you want to watch?**) downloads
>   the models you need ([A3](#a3-add-detection-models)).
> - To change the code, build the app yourself
>   ([Track B](#track-b-build-from-source-for-developers)).
> - To copy your recorded sessions to a computer, see
>   [S2](#s2-pulling-data-from-the-smartphone).

**Contents**

- [Ways to install](#ways-to-install)
- [Track A: Install a fresh APK release (no coding)](#track-a-install-a-fresh-apk-release-no-coding)
  - [A1. Get the app file](#a1-get-the-app-file-apk-on-your-phone)
  - [A2. Install it](#a2-install-it)
  - [A2b. Install & auto-update via Obtainium](#a2b-install--auto-update-via-obtainium)
  - [A3. Add detection models](#a3-add-detection-models)
- [Track B: Build from source (for developers)](#track-b-build-from-source-for-developers)
  - [B0. Install the tools](#b0-install-the-tools-one-time)
  - [B1. Get the code](#b1-get-the-code)
  - [B2. Add the models](#b2-add-the-models)
  - [B3. Run on a connected phone](#b3-run-on-a-connected-phone)
  - [B4. Set up release signing (maintainers only)](#b4-set-up-release-signing-one-time-maintainers-only)
  - [B5. Build an installable `.apk` to share](#b5-build-an-installable-apk-to-share)
- [S1. Getting the models](#s1-getting-the-models)
- [S2. Pulling data from the smartphone](#s2-pulling-data-from-the-smartphone)

## Ways to install

The simplest way to install FaunaPulse on your smartphone is from
[Google Play](https://play.google.com/store/apps/details?id=com.faunapulse.app), which also can
install updates automatically.

<a href="https://play.google.com/store/apps/details?id=com.faunapulse.app"><img src="https://play.google.com/intl/en_us/badges/static/images/badges/en_badge_web_generic.png" alt="Get it on Google Play" height="80"></a>

This guide shows two other ways to get the app running on an Android phone:

- **A. Install a fresh APK release:** for you if you just want to **test** an early GitHub
  release. You need an Android phone and the app's `.apk` file. Effort: a few minutes, no
  coding.
- **B. Build from source:** for you if you want to **change the code** and test your changes.
  You need a Windows, macOS or Linux computer and developer tools. Effort: about 1 hour the
  first time (installing software).

Supplementary sections further down are marked with **S** (S1, S2).

---

## Track A: Install a fresh APK release (no coding)

An APK (Android Package Kit) is the file that installs an app on an Android phone.

### A1. Get the app file (`.apk`) on your phone

Save the `.apk` file to your phone in one of two ways:

- download it directly on the phone from a link you were given (for example the
  [Releases](https://github.com/valentinitnelav/fauna-pulse/releases) page);
- or copy it over USB from your computer (for example into the phone's `Download` folder).

The APK files are usually in the **Assets** section of a release, for example:

<img height="170" alt="Image" src="https://github.com/user-attachments/assets/0a614eea-354a-44ef-b3c8-41aee7a601f4" />

### A2. Install it

1. On the phone, open your **File Manager** app and tap the downloaded `.apk` file.
2. Follow the install prompts.
3. Open FaunaPulse. When the app asks, allow the camera (at your first **New session**) and
   notifications (Android 13 and newer, the first time a recording, a **Find animals in
   photos** or **Find animals in videos** run, or an identification starts). Location is optional: you can
   also type the coordinates by hand.

The `.apk` file does not come from the Play Store, so Android shows security warnings, and the
installation is not very smooth. Google Play intends it this way, but the app is safe to install.

WikiHow has a tutorial with the necessary steps:
[How to Download & Install an APK on Android: Full APK Guide](https://www.wikihow.com/Install-APK-Files-on-Android).

<details>
<summary>Example with screenshots on a Samsung phone</summary>

Below is an example on a Samsung test phone. Some screens will look different on your phone,
but they should be similar. An older version of FaunaPulse was used when the screenshots were
taken. In the screenshots the APK file is named `app-release.apk`.

<table width="50%">
  <thead>
    <tr>
      <th width="2%" align="center">Step</th>
      <th width="53%">Instructions</th>
      <!-- ADJUST SINGLE WIDTH HERE (e.g., width="46%" or width="300px") -->
      <th width="45%" align="center">Screenshot</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td align="center"><b>1</b></td>
      <td>
        <b>Open Downloaded File</b><br>
        Once the APK file is downloaded, tap <b>Open</b> in the prompt, or navigate to your smartphone's <b>Downloads</b> folder (or default download location) and tap the file.<br><br>
        <i>(Note: The app icon will be visible; file names vary per release, e.g., <code>faunapulse-v0.9.0-beta.1-arm64-v8a.apk</code>).</i>
      </td>
      <td align="center">
        <!-- apk-file-downloaded -->
        <img width="100%" alt="APK Downloaded" src="https://github.com/user-attachments/assets/5510226c-e77a-4b86-9d07-716f080c8076" />
      </td>
    </tr>
    <tr>
      <td align="center"><b>2</b></td>
      <td>
        <b>Access Installation Settings</b><br>
        When prompted, allow your file manager (e.g., "My Files") to install unknown apps by tapping <b>Settings</b>.
      </td>
      <td align="center">
        <!-- apk-file-settings -->
        <img width="100%" alt="Settings Prompt" src="https://github.com/user-attachments/assets/fe77df85-c746-457c-86bc-38bc0c97402e" />
      </td>
    </tr>
    <tr>
      <td align="center"><b>3</b></td>
      <td>
        <b>Enable Unknown App Installation</b><br>
      </td>
      <td align="center">
        <!-- allow-install-1 -->
        <img width="100%" alt="Allow Installation Toggle" src="https://github.com/user-attachments/assets/359dad08-897b-4152-bfdd-c2bd1f49fc96" />
      </td>
    </tr>
    <tr>
      <td align="center"><b>4</b></td>
      <td>
        <b>Confirm Installation</b><br>
      </td>
      <td align="center">
        <!-- allow-install-2 -->
        <img width="100%" alt="Confirm Install" src="https://github.com/user-attachments/assets/9356acf7-6fa0-42bd-90f6-ec39e0b2e9cc" />
      </td>
    </tr>
    <tr>
      <td align="center"><b>5</b></td>
      <td>
        <b>Open the app and then grant camera permissions</b><br>
      </td>
      <td align="center">
        <img width="100%" alt="Camera Permission" src="https://github.com/user-attachments/assets/eb2426dd-feed-4ad1-9525-5f749520ee4e" />
      </td>
    </tr>
    <tr>
      <td align="center"><b>6</b></td>
      <td>
        <b>Grant camera & location permissions</b><br>
        Also, if prompted for location access, select your preferred permission level (e.g., "While using the app").
      </td>
      <td align="center">
        <img width="100%" alt="Location Permission" src="https://github.com/user-attachments/assets/739d2ecd-0a66-4e1f-a31c-4e95f1ff6043" />
      </td>
    </tr>
  </tbody>
</table>

</details>

### A2b. Install & auto-update via Obtainium

[Obtainium](https://github.com/ImranR98/Obtainium) is a free Android app. It installs and
updates apps straight from a project's GitHub releases, so you do not have to download the
`.apk` again each time a new version comes out.

1. Install Obtainium itself (see its own
   [installation instructions](https://github.com/ImranR98/Obtainium#installation)). Its APK
   file can be downloaded and installed in the same way as in [A2](#a2-install-it).
2. In Obtainium, tap **+ Add** (usually in the bottom right corner of the screen) and paste the
   FaunaPulse repository address: `https://github.com/valentinitnelav/fauna-pulse`
3. On that same screen, **switch on "Include prereleases"** in the app's settings before you
   tap Add or +. Without it, Obtainium reports that the repository has no releases (see the
   note below).
4. Tap Add or + (usually to the right of the address you pasted).
5. Obtainium finds the GitHub releases and lets you pick which release file (asset) to follow.
   Choose the `.apk` that matches your phone's processor type (architecture):

   | File name contains | For |
   |---|---|
   | `arm64-v8a` | almost all phones from the last several years |
   | `armeabi-v7a` | older 32-bit phones only |

6. From then on, Obtainium checks for new tagged releases and offers them to you.

**Why "Include prereleases":** while the app is a research preview, every FaunaPulse release is
published as a GitHub pre-release (tags like `v0.7.0-alpha.1` or `v0.9.0-beta.1`). Obtainium
skips pre-releases unless this switch is on. Once FaunaPulse reaches a stable `v1.0.0`, you can
switch "Include prereleases" off again to follow stable releases only.

### A3. Add detection models

The app comes with no model, so you need to download or import one to your phone. You can
download models from the FaunaPulse collection on [Hugging Face][hf_fp_models].

**The quickest way** is step 1 on Home, **AI models**: answer **What do you want to watch?**

1. Tap an answer: **Pollinators on flowers**, **Insects on a flat surface** or **Mammals and
   birds**.
2. Each answer suggests a detection model and an identification model with its name list,
   chosen for you and shown by their file names. Other models are under **Choose other
   models**.
3. Tap **Download and use** (the button shows the size of the download in brackets; it reads
   **Use these** when the files are already on the phone). A window **Download the chosen
   models** opens: tap **Download**. The models then become the app's choice. Use Wi-Fi, as
   some model files are large. Step 1 then shows **Set up for:** and the answer.

The download window shows the size in total and the progress. For a large file it says **A
large download: use Wi-Fi if you can.** If the phone does not have enough free storage, it says
so: delete old sessions on the **Sessions** screen, then come back. After an error, tap **Try
again**.

**All models:** the **Download & import models** screen offers every model, among them
MegaDetector V6 (common animals), flat-bug and insectDCT (insects). Open it from Home: **AI
models** in the bottom bar, the **Other models** tile in step 1, or **Menu** → **Download &
import models**. When a screen needs a model that is not on the phone yet, it shows a button
such as **Get a detection model…** or **Get an identification model…**, which opens the same
screen.

The ⓘ card of each model and name list links its model card on Hugging Face (in its last row).
The model card says who made the model, how it was adapted for FaunaPulse, its licence, how to
cite it and whether there is a newer version.

**Your own models:** once you have one or more `.tflite` model files to test (see
[S1. Getting the models](#s1-getting-the-models)), add them in one of two ways:

- **In-app import (easiest):** **AI models** (Home, bottom bar) → **Import model files…**.
  Pick the `.tflite` file(s) from **Downloads** or any other folder that Android's file picker
  can read.
- **HTTPS download:** **Menu** → **Download & import models** → **Download from a link…**.
  Paste a direct HTTPS link to a model file or name list (it works for `.tflite`, `.fpack` and
  `_qnn.onnx` files).

Notes on adding your own models:

- With **Import model files…**, to take every file of a folder, press and hold one file, then
  tap **Select all**. You can first copy the model into Downloads over USB.
- The app checks what each file is: a detection model, an identification model or a name list
  goes to its own list. It asks before replacing a file of the same name.

**Safety:** add only files and links from people or websites you trust. The app checks what a
file is (a model or a name list), not who made it. The files offered on the **Download & import
models** screen are downloaded from a fixed version on Hugging Face. They are checked against a
checksum (a fingerprint of the file) before they are kept.

**Where added models appear:**

- in the **Detection model** list (**Settings** on the camera screen, gear icon, **Detection**
  tab; and on the **Find animals in photos** and **Find animals in videos** screens);
- identification models and name lists: in the **Model (.tflite)** and **Name list (.fpack)**
  lists of the **Identify organisms** screen;
- on the **What do you want to watch?** pages under **Choose other models** → **Other models on
  this phone**, where they can be chosen like the suggestions (no entry in the download list is
  needed).

Added models are checked and copied into private app storage, so you cannot browse them over
USB.

---

## Track B: Build from source (for developers)

The app is a **Flutter** project (Dart language) with the YOLO plugin under
`packages/ultralytics_yolo/`.

**Contributing:** to contribute to this repository, first fork it and work on your fork. When
you are happy with your changes, open a pull request. See also GitHub's guide
[Contributing to a project](https://docs.github.com/en/get-started/exploring-projects-on-github/contributing-to-a-project).

### B0. Install the tools (one time)

Install these for your operating system (follow the official links):

1. **Git**: <https://git-scm.com/downloads>
2. **Flutter SDK**: <https://docs.flutter.dev/get-started/install>
   Choose **Android** as the target, and on the install page pick **Windows**, **macOS** or
   **Linux**. This page also guides you through the **Android SDK** and **Android Studio**
   (needed for the Android build tools and `adb`).
3. **VS Code**: <https://code.visualstudio.com/>, plus the **Flutter** extension (it also
   installs the Dart extension).

Then check that everything is set up:

```bash
flutter doctor
```

Fix anything it flags (especially "Android toolchain" and "Android licenses"):

```bash
flutter doctor --android-licenses   # accept all
```

### B1. Get the code

```bash
git clone git@github.com:valentinitnelav/fauna-pulse.git
# If you don't use SSH, clone the HTTPS URL shown on the GitHub repo page instead.

cd fauna-pulse
flutter pub get           # retrieve or upgrade flutter dependencies
```

### B2. Add the models

Models are **not** in the repository (see [S1. Getting the models](#s1-getting-the-models)).
You have two options:

- Build and run first, then use the in-app **Import model files…** or **Download from a
  link…** button ([A3](#a3-add-detection-models)).
- **Bundle them into your build:** before building, copy the model files you were given into
  `assets/models/` (general models) and `assets/models/custom/` (custom detectors). These
  folders are git-ignored, so your models never get committed. See
  [Pack models with the APK file](#pack-models-with-the-apk-file). Note: the model picker lists
  only downloaded or imported models, so it does not offer packed models.

### B3. Run on a connected phone

1. On the phone: **Settings → Developer options → enable USB debugging**.
2. Check that the computer sees the phone:

   ```bash
   flutter devices
   ```

   <details>
   <summary>Example output with two phones connected</summary>

   Two smartphones were connected: the first row is a Xiaomi phone, the second a Samsung.

   ```text
   Found 4 connected devices:
     2107113SG (mobile) • <device-id-1> • android-arm64  • Android 14 (API 34)
     SM M127F (mobile)  • <device-id-2> • android-arm64  • Android 12 (API 31)
     Linux (desktop)    • linux       • linux-x64      • Ubuntu 24.04.4 LTS 6.8.0-124-generic
     Chrome (web)       • chrome      • web-javascript • Google Chrome 149.0.7827.196

   Run "flutter emulators" to list and start any available device emulators.

   If you expected another device to be detected, please run "flutter doctor" to diagnose potential issues. You may also try increasing the time to wait for connected devices with the "--device-timeout" flag. Visit https://flutter.dev/setup/ for troubleshooting tips.
   ```

   The device IDs are in the second column (yours are different).

   </details>

3. Start the app (debug mode):

   ```bash
   # navigate to the git repository (cloned on your computer)
   cd fauna-pulse
   # retrieve or upgrade flutter dependencies
   flutter pub get
   # will run the app (debug mode) on the first detected smartphone
   flutter run
   ```

4. If several phones are connected, run the app on one of them with its device ID from the
   output of `flutter devices`:

   ```bash
   # navigate to this git repository (cloned on your computer)
   cd fauna-pulse
   # will run the app (debug mode) on the phone with that device id
   # (-d stands for --device-id)
   flutter run -d <device-id>
   ```

**Save the terminal output to a text file** (useful for diagnostics and debugging when you test
the app). This Linux command is an example you can adapt:

```bash
# navigate to the git repository (cloned on your computer)
cd fauna-pulse
stdbuf -oL -eL flutter run -d <device-id> 2>&1 | \
  tee -a ~/faunapulse_logs/flutter_run_output_$(date +"%Y-%m-%d_%H:%M:%S").txt
```

> The folder `~/faunapulse_logs/` is only an example: use any folder on your computer (it must
> exist).

### B4. Set up release signing (one time, maintainers only)

You need this only for release builds (`flutter build apk --release`). Debug builds (`flutter run`,
`flutter build apk --debug`) need none of this.

Create the key once with the helper script. It asks for a password, which is never displayed
or stored in the repository:

```bash
cd fauna-pulse
bash scripts/create_release_keystore.sh
```

It writes two files:

- `~/faunapulse-release.jks`: the keystore itself (kept outside the repository). Not in git:
  back it up yourself.
- `android/key.properties`: tells Gradle where the keystore is and its password. Not in git
  (git-ignored).

**Already have a keystore** (for instance on a second computer)? Skip the script. Copy
`android/key.properties.example` to `android/key.properties` and fill in your own path and
passwords. On a build server you can instead set the environment variables
`ANDROID_STORE_FILE`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`.

Release builds fail on purpose, with a message that explains why, if this is missing. So an
unsigned or debug-signed app can never be published by accident.

<details>
<summary>What signing is, and two things to know before you create a key</summary>

Every Android app file is **signed** with a cryptographic key. Android installs an update only
if the new file is signed with the **same** key as the version already on the phone. This is
how it knows that the update really comes from you and not from someone else. The key lives in
a **keystore** file (`.jks`), protected by a password.

- **Losing the keystore or its password is permanent.** Nobody can recover it, not even
  Google. Every user would have to uninstall and reinstall to move to a new key, and would lose
  their local sessions. Back it up in at least two places.
- **Use the same key everywhere.** FaunaPulse is on Google Play, so Play App Signing must use this
  same key. Otherwise a Play install and a GitHub-download install become
  two incompatible apps that cannot update each other.

</details>

### B5. Build an installable `.apk` to share

Before you start:

- Make sure the file `key.properties` exists in the `.../fauna-pulse/android/` folder (see
  [B4](#b4-set-up-release-signing-one-time-maintainers-only)).
- If sessions stored on the phone may still be useful for debugging, or you want to keep that
  data for further testing, back them up on your computer first (see
  [S2. Pulling data from the smartphone](#s2-pulling-data-from-the-smartphone)).

**1. Build the APK:**

```bash
# navigate to the git repository (cloned on your computer)
cd fauna-pulse
# retrieve or upgrade flutter dependencies
flutter pub get
# or: flutter build apk --debug (but slower app run time)
flutter build apk --release

# Expected output if success:

#   Font asset "MaterialIcons-Regular.otf" was tree-shaken, reducing it from 1645184 to 9532 bytes (99.4% reduction). 
#   Tree-shaking can be disabled by providing the --no-tree-shake-icons flag when building your app.
#   Running Gradle task 'assembleRelease'...                          232.1s
#   ✓ Built build/app/outputs/flutter-apk/app-release.apk (122.2MB)
```

The file appears in `.../fauna-pulse/build/app/outputs/flutter-apk/` (for example
`app-release.apk` and `app-release.apk.sha1`). Note that these files are overwritten by the
next build. This is exactly the file used in **Track A**: share it through a GitHub Release or
a private link.

**2. Install it on a phone** (here the `app-release.apk`, on a specific phone):

```bash
# navigate to the git repository
cd fauna-pulse
adb -s <device-id> install -r build/app/outputs/flutter-apk/app-release.apk
# Your phone might require you to click "Allow" (or something similar) to install the app,
# so watch the phone's screen for any pop-up messages.

# Expect on the terminal these 2 lines if the installation was successful:
#   Performing Streamed Install
#   Success
```

The `-r` flag stands for "reinstall". It tells Android to replace any existing version of the
app on the phone and to keep all local session data and databases you have already made.

<details>
<summary>Install fails with INSTALL_FAILED_UPDATE_INCOMPATIBLE</summary>

This error means that a debug version of the app is already on your phone. Android does not
allow a release build to replace a debug build, because their cryptographic signatures do not
match.

Example of the error message:

```
# Performing Streamed Install
# adb: failed to install build/app/outputs/flutter-apk/app-release.apk: 
# Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: 
# Existing package com.faunapulse.app signatures do not match newer version; ignoring!]
```

**How to fix it:** remove the debug app from the phone first; then the release installation
will work. Note that this discards your session setups and changes them back to their default
values. It also deletes every session saved on the phone, because Android removes the app
folder `Android/data/com.faunapulse.app/files/` when the app is uninstalled. Copy your sessions
to the computer first ([S2](#s2-pulling-data-from-the-smartphone)).

Uninstall the existing app directly with ADB:

```bash
adb -s <device-id> uninstall com.faunapulse.app
# Then re-run the release installation command
# Note that this will discard any session setups and change them to their default values.
# It also deletes all sessions on the phone: copy them to the computer first (S2).
adb -s <device-id> install -r build/app/outputs/flutter-apk/app-release.apk
```

</details>

**Important: measure speed only with a release build.** A **debug build** gives very distorted
numbers for inference speed, tracking accuracy and frames per second (FPS). Install a
`--release` APK to measure the true hardware performance and processing delay of the app.

<details>
<summary>Debug and release builds: what is the difference?</summary>

Imagine preparing a complex recipe:

- **Debug mode** is a cooking school class. The chef works with all measuring tools left out on
  the counter. It is very instructive and a mistake is easy to fix, but it is slow and
  cluttered.
- **Release mode** is a sealed, pre-packaged meal shipped to the supermarket. It is made for
  fast eating. You cannot change the ingredients mid-bite.

**Debug mode** (`--debug`; JIT = Just-In-Time compilation)

- Debug mode is made for the developer's machine.
- The compiler does not turn your Dart code directly into native machine instructions. It
  packages the source code together with the Dart Virtual Machine (VM) inside the APK (Android
  Package Kit). When the app runs, the VM reads and compiles the code as it runs.
  - **Advantage:** Flutter's Hot Reload works. Because a live VM runs the code, you can send
    updated source files directly into the running app without rebuilding it.
  - **Cost:** a larger APK and slower execution.

**Release mode** (`--release`; AOT = Ahead-Of-Time compilation)

- Release mode is made for the end user.
- The compiler removes the Dart VM completely.
  - **Advantage:** raw speed and a smaller size. The phone's processor runs the native code
    directly.
  - **Cost:** building takes a bit longer, and you lose all interactive diagnostics, Hot
    Reload and debugging hooks.

</details>

---

## S1. Getting the models

Model weights (`.tflite` files) are **deliberately not stored in this online repository**, for
two reasons:

- they are large;
- **some detectors belong to collaborators and must not be redistributed**.

**Published models:** the models that the app offers for download are FaunaPulse's phone
conversions of MegaDetector V6, flat-bug, insectDCT, BioCLIP 2 and BioCLIP 2.5. They are on
[Hugging Face](https://huggingface.co/collections/Valen-Peregrine/faunapulse), each with a
model card (source, licence, how to cite). The app downloads them itself
([A3](#a3-add-detection-models)).

The tools to convert and quantise the models (store their numbers with less precision, so the
files get smaller) are in the GitHub repository [fauna-pulse-models][fp_models].

**Models you receive from others:**

- **Do not** re-share unpublished models you receive, commit them to git, or upload them
  anywhere public. Treat collaborator-owned models as confidential.
- To use a model, load it with the in-app **Import model files…** button or **Download from a
  link…** ([A3](#a3-add-detection-models)).

Every model file and name list may be up to 2 GiB.

<details>
<summary>Why the 2 GiB limit</summary>

The limit is `kMaxModelFileBytes` in `lib/fauna_pulse/models/model_file_security.dart`. It is a
ceiling the app sets: an `.onnx` file cannot be larger, and the app reads a model's labels by
mapping the whole file into memory, which stops at 2 GiB for now.

</details>

### Pack models with the APK file

This is not encouraged for a public release, and not for Google Play because the APK file can
grow a lot in size. It is possible for debugging and testing on your phone, or if it becomes
practical in the future.

For local development, models can be placed in `assets/models/` or `assets/models/custom/`
before a debug or release build (those folders stay git-ignored).

1. List the model weights to pack in `assets/models/bundled_models.txt`: one
   repository-relative model path on each line. Blank lines and lines beginning with `#` are
   ignored. Both of these path styles work:

   ```text
   assets/models/my_model.tflite
   /fauna-pulse/assets/models/custom/my_other_model.tflite
   ```

2. Build as usual:

   ```bash
   flutter build apk --debug
   # or
   flutter build apk --release
   ```

What gets packed:

- **Release or profile build:** only existing `*.tflite` model weights listed in
  `fauna-pulse/assets/models/bundled_models.txt`.
- **Debug build:** every file in these folders.

Also:

- Other local test weights stay where they are but are left out of the APK file.
- If a listed weight cannot be found, the terminal prints its path with a warning. This warning
  does not stop the build.
- Before sharing an APK, make sure every listed model is licensed or otherwise allowed for
  redistribution.

<details>
<summary>Packed models are no longer offered to users</summary>

Since round 268 the model picker lists only downloaded or imported models, so a packed model is
no longer offered to users. Since round 270 the list of packed models
(`assets/models/bundled_models.txt`) is empty: the release APK carries no model,
and the camera starts without one (motion-triggered and time-lapse capture need none).

</details>

## S2. Pulling data from the smartphone

This section shows how to copy your recorded sessions from the phone to a computer, over a USB
cable.

### S2.1. USB transfer via Media Transfer Protocol (MTP)

#### S2.1.1. On Linux

1. Connect your Android phone to your computer.
2. On the phone you should get a message where you can allow **File Transfer**. Allow it.
3. In your file explorer you can now see the folder of the app. The path may look like
   `mtp:/<your phone name>/Internal shared storage/Android/data/com.faunapulse.app/files/`.
   This is the usual Media Transfer Protocol (MTP).
4. Copy or add files and folders between your computer and the phone with your favourite file
   explorer.

#### S2.1.2 On Windows

> To be added.


### S2.2. USB transfer via Android Debug Bridge (ADB)

ADB (Android Debug Bridge) is a command-line tool that talks to a phone over USB. Install the
[SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools#downloads): that
page has download links for all 3 major operating systems (Windows, Mac, Linux).

#### S2.2.1. On Linux

On Linux you can also install the ADB tools with these commands:

```bash
sudo apt-get update
sudo apt-get -y install android-tools-adb
```

Check that ADB is installed:

```bash
adb version
```

You should see something like:

```text
Android Debug Bridge version 1.0.41
Version 34.0.4-debian
Installed as /usr/lib/android-sdk/platform-tools/adb
Running on Linux 6.8.0-134-generic (x86_64)
```

**Where the app's files are:** on Linux, the `adb` path to the app on the phone is usually
`/sdcard/Android/data/com.faunapulse.app/files/`. This path is also valid:
`/storage/emulated/0/Android/data/com.faunapulse.app/files/`

There you find:

```text
/sdcard/.../files
├── sessions/              # one folder per recording session (images + metadata)
└── site_photos_waiting/   # site photos taken before a recording starts (moved into its session)
```

Models, error reports and crash files are in private internal app storage, and are deliberately
absent from this USB-visible folder. An upgraded installation may still contain old `models/`
or `error_reports/` folders from an earlier version.

**Example: pull the results of your recording sessions.**

```bash
# 1) Locate the destination folder on your computer
# (an example: use any folder on your computer)
cd ~/faunapulse_sessions/my-phone/

# 2) Pull all content (everything from .../files/)
# It will also create a folder named "files" at the path above
adb pull -a /sdcard/Android/data/com.faunapulse.app/files/
# -a : preserve file timestamp and mode
# This will avoid the creation of the "files" folder locally
adb pull -a /sdcard/Android/data/com.faunapulse.app/files/. ./

# If you need to pull from a specific smartphone, use their flutter device id.
# Check all connected devices with:
flutter devices
# Then pull from a specific smartphone using their id
adb -s <device-id> pull -a /sdcard/Android/data/com.faunapulse.app/files/. ./

# Or pull directly into the destination folder (without `cd` command first):
adb pull -a /sdcard/Android/data/com.faunapulse.app/files/ \
  ~/faunapulse_sessions/my-phone/
```

#### S2.2.2. On Windows

> To be added.


<!-- 
Reference links: [id]: URL
These are links used throughout this file
-->

[hf_fp_models]: https://huggingface.co/collections/Valen-Peregrine/faunapulse
[fp_models]: https://github.com/valentinitnelav/fauna-pulse-models
