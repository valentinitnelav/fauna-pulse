# Installing & testing FaunaPulse app

A step-by-step guide for collaborators.

For contributing to this repository, please first fork it and then work on that forked repository in parallel. When happy with your implementations, then ask for a pull request. See also the guidelines suggested by GitHub - [Contributing to a project](https://docs.github.com/en/get-started/exploring-projects-on-github/contributing-to-a-project)

This guide shows two ways to get the app running on an Android phone:

| Track | Who it's for | What you need | Effort |
|-------|--------------|---------------|--------|
| **A. Install the ready-made app** | You just want to **test** the app | An Android phone + the app `.apk` file | a few minutes, no coding |
| **B. Build from source** | You want to **change the code** | Windows/MacOS/Linux computer + developer tools | ~1 hour first time (installing software) |


---

## Track A: Install the ready-made app (no coding)

### A1. Get the app file (`.apk`) on your phone

Save the `.apk` file to your phone: download it directly on the phone from a provided link, or copy it over USB from your computer (e.g. in the phones' `Download` folder).

### A2. Install it

On the phone, open your **File Manager** app, tap the downloaded `.apk` file, and follow the Install prompts.
Because this is an app outside the Play Store (for now), you will get security warnings that make the installation not a very smooth process. 
Google Play intends it in this way, but the app is safe to install.

### A3. Add detection models

The app ships with one **general-purpose** model, so it runs immediately, but that
model does not recognise insects. For insect work you need a purpose-trained model
(see [Getting the models](#getting-the-models)). Once you have one or more `.tflite`
model files to test, load them in **either** way:

- **In-app (easiest):** open **FaunaPulse → Settings (gear icon) → Import…**,
  then pick the `.tflite` file(s) you downloaded (e.g. from your **Downloads** folder).
- **Over USB (drag-and-drop):** connect the phone to a computer; drop `.tflite` files into a folder of your choice.

Imported models then appear in the app's **model dropdown** at the start of a session.


---

## Track B: Build from source (for developers)

The app is a **Flutter** project (Dart language) with the YOLO plugin under `packages/ultralytics_yolo/`.

### B0. Install the tools (one time)

Install these for your operating system (follow the official links):

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

### B1. Get the code

```bash
git clone git@github.com:valentinitnelav/fauna-pulse.git
# If you don't use SSH, clone the HTTPS URL shown on the GitHub repo page instead.

cd fauna-pulse
flutter pub get           # retrieve or upgrade flutter dependencies
```

### B2. Add the models

Models are **not** in the repo (see [Getting the models](#getting-the-models)).
Two options:

- build/run first, then use the in-app **Import…** button (Track A3).
- **Bundle them into your build:** copy the model files you were given into
  `assets/models/` (general models) and `assets/models/custom/` (custom detectors)
  *before* building. These folders are git-ignored, so your models never get committed.

### B3. Run on a connected phone

1. On the phone: **Settings → Developer options → enable USB debugging**.
2. Check the phone is seen:

    Run this

    ```bash
    flutter devices
    ```

    Example of possible output (2 smartphones were connected, 1st row points to a Xiaomi model, 2nd is a Samsung):

    ```text
    Found 4 connected devices:
      2107113SG (mobile) • 2b2dc560    • android-arm64  • Android 14 (API 34)
      SM M127F (mobile)  • RF8T403A3AT • android-arm64  • Android 12 (API 31)
      Linux (desktop)    • linux       • linux-x64      • Ubuntu 24.04.4 LTS 6.8.0-124-generic
      Chrome (web)       • chrome      • web-javascript • Google Chrome 149.0.7827.196
  
    Run "flutter emulators" to list and start any available device emulators.
  
    If you expected another device to be detected, please run "flutter doctor" to diagnose potential issues. You may also try increasing the time to wait for connected devices with the "--device-timeout" flag. Visit https://flutter.dev/setup/ for troubleshooting tips.
    ```

3. Launch the app (debug):

   ```bash
   cd fauna-pulse    # navigate to the git repository (cloned on your computer)
   flutter pub get          # retrieve or upgrade flutter dependencies
   flutter run              # will run the app (debug mode) on the first detected smartphone
   ```

   If you have multiple smartphones connected, and need to run on a specific smartphone, use its ID listed in the output of `flutter devices`.
   See above the device IDs: "2b2dc560" & "RF8T403A3AT"
   
   ```bash
   cd fauna-pulse    # navigate to this git repository (cloned on your computer)
   flutter run -d 2b2dc560  # will run the app (debug mode) on mobile device id "2b2dc560"
   # -d stands for --device-id
   ```

   Or if you want to also store the terminal outputs into a txt file (useful for diagnostics & debugging when testing the app), can get inspired from this Linux command:

   ```bash
   cd fauna-pulse # navigate to the git repository (cloned on your computer)
   stdbuf -oL -eL flutter run -d 2b2dc560 2>&1 | tee -a ~/InsectDetectApp/sessions/logcats/flutter_run_output_xiaomi_$(date +"%Y-%m-%d_%H:%M:%S").txt
   ```

   > Note that in the path used above, `~/InsectDetectApp/sessions/logcats/` is an example on my local computer at the time of writing this guide.

### B4. Set up release signing (one time, maintainers only)

Every Android app file is **signed** with a cryptographic key. Android will only
install an update if the new file is signed with the **same** key as the version
already on the phone, which is how it knows the update really comes from you and not
from someone else. That key lives in a **keystore** file (`.jks`), protected by a
password.

Two consequences worth understanding before you create one:

- **Losing the keystore or its password is permanent.** Nobody can recover it, not
  even Google. Every user would have to uninstall and reinstall to move to a new key,
  losing their local sessions. Back it up in at least two places.
- **Use the same key everywhere.** If FaunaPulse is later published on Google Play,
  upload this same key to Play App Signing. Otherwise a Play install and a
  GitHub-download install become two incompatible apps that cannot update each other.

Create the key once with the helper script (it asks for a password, which is never
displayed or stored in the repository):

```bash
cd fauna-pulse
bash scripts/create_release_keystore.sh
```

It writes two things:

| File | What it is | In git? |
|---|---|---|
| `~/faunapulse-release.jks` | the keystore itself (kept outside the repository) | no, back it up yourself |
| `android/key.properties` | tells Gradle where the keystore is and its password | no, git-ignored |

If you already have a keystore (for instance on a second computer), skip the script
and copy `android/key.properties.example` to `android/key.properties`, filling in your
own path and passwords. On a build server you can instead set the environment
variables `ANDROID_STORE_FILE`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS` and
`ANDROID_KEY_PASSWORD`.

Release builds deliberately fail with an explanatory message if this is missing, so an
unsigned or debug-signed app can never be published by accident. Debug builds
(`flutter run`, `flutter build apk --debug`) need none of this.

### B5. Build an installable `.apk` to share

Note: make sure to have the `key.properties` file existing in the `.../fauna-pulse/android/` folder (see B4).

Also, in case you have sessions that are stored on the phone and they might be 
still useful for debugging purposes or want to keep that collected data for 
further testing, make sure to back the up on your computer first - see [Pulling data from the smartphone](##pulling-data-from-the-smartphone).

```bash
cd fauna-pulse                  # navigate to the git repository (cloned on your computer)
flutter pub get                 # retrieve or upgrade flutter dependencies
flutter build apk --release     # or: flutter build apk --debug (but slower app run time)

# Expected output if success:

#   fetch_bundled_models: have yolo26n_int8.tflite
#   Font asset "MaterialIcons-Regular.otf" was tree-shaken, reducing it from 1645184 to 9532 bytes (99.4% reduction). 
#   Tree-shaking can be disabled by providing the --no-tree-shake-icons flag when building your app.
#   Running Gradle task 'assembleRelease'...                          232.1s
#   ✓ Built build/app/outputs/flutter-apk/app-release.apk (122.2MB)
```

The file appears at `.../build/app/outputs/flutter-apk/` 
(e.g.: `app-release.apk` and `app-release.apk.sha1`).
Note that these files are overwritten. 
That's exactly the file used in **Track A**. Share it via a GitHub Release or a private link.

To deploy the app (the `app-release.apk`) on a specific smartphone:

```bash
cd fauna-pulse           # navigate to the git repository
adb -s 2b2dc560 install -r build/app/outputs/flutter-apk/app-release.apk
# Your phone might require you to click "Allow" (or something similar) to install the app,
# so watch the phone's screen for any pop-up messages.

# Expect on the terminal these 2 lines if the installation was successful:
#   Performing Streamed Install
#   Success
```

The `-r` flag stands for `reinstall`. It instructs the Android operating system to replace any existing version of the app on the device while preserving all local session data and databases you've already generated.

If the installation fails with an error like `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, it means an active Debug version of the app is already sitting on your phone. Android security protocols strictly prohibit a Release build from overwriting a Debug build because their cryptographic signatures do not match.

Example of error message:

```
# Performing Streamed Install
# adb: failed to install build/app/outputs/flutter-apk/app-release.apk: 
# Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: 
# Existing package com.faunapulse.app signatures do not match newer version; ignoring!]
```

How to resolve it:

You must purge the debug package from the phone before the release installation will succeed.
Note that this will discard any session setups and change them to their defaults values.

Uninstall the existing package directly via ADB:

```bash
adb -s 2b2dc560 uninstall com.faunapulse.app
# Then re-run the release installation command
# Note that this will discard any sesssion setups and change them to their defaults values.
adb -s 2b2dc560 install -r build/app/outputs/flutter-apk/app-release.apk
```

NOTES:

IMPORTANT: Evaluating performance using a **Debug build** will give highly distorted data. Never benchmark inference speeds, tracking accuracy, or frame-per-second (FPS) metrics on a debug binary. You must deploy a `--release` APK to measure the "true" hardware performance and processing latency of the application.

To understand the difference between **debug** & **release**, imagine preparing a complex recipe:

- **Debug Mode** is a cooking school class. The chef works with all measuring tools left out on the counter. It is highly instructional and easy to fix if a mistake happens, but it is slow and cluttered.

- **Release Mode** is a sealed, pre-packaged meal shipped to the supermarket. It is optimized for rapid consumption. You cannot change the ingredients mid-bite.

**Debug Mode** (`--debug`; JIT = Just-In-Time compilation)
- Debug mode is architected for the developer's machine.
- Instead of compiling your Dart code directly into native machine instructions, the compiler packages the source code along with the Dart Virtual Machine (VM) inside the APK (Android Package Kit). When the app runs, the VM reads and compiles code on the fly as it executes.
  - **Advantage**: enables Flutter's Hot Reload. Because the code is interpreted by a live VM, you can inject updated source files directly into the running memory pool without rebuilding the binary.
  - **Cost**: inflates the APK size and bottlenecks execution speed.

**Release Mode** (`--release`; AOT = Ahead-Of-Time compilation):
- Release mode is architected for the end-user.
- The compiler strips away the Dart VM entirely.
  - **Advantage**: Raw speed and smaller size. The smartphone's processor executes the native binaries directly.
  - **Cost**: Compilation takes a bit longer, and you lose all interactive diagnostics, Hot Reload, and debugging hooks.

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
  (Track A3). The app lists any `.tflite` it finds; nothing else is required.

The in-app model picker is built **dynamically** from whatever `.tflite` files it finds. 
Models can also be placed in `assets/models/` / `assets/models/custom/` before building and running the app (those folders stay
git-ignored).

## Pulling data from the smartphone

### USB transfer via Media Transfer Protocol (MTP)

#### On Linux

Connect your Android smartphone to your computer and allow File Transfer option. On your smartphone you should get a info message where you can allow the file transfer option.

Then you can see the content of the folder associated with the app on your file explorer. Note that the path on your file explorer could appear like `mtp:/<your phone name>/Internal shared storage/Android/data/com.faunapulse.app/files/`. This is the usual Media Transfer Protocol (MTP).

You can copy or add files and folders between your computer and the smartphone using your favorite file explorer.

#### On Windows

> To be added.


### USB transfer via Android Debug Bridge (ADB)

Need to install [SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools#downloads). There you get download links for all 3 major operating systems: Windows, Mac, Linux.

#### On Linux

Can also install ADB tools with these commands:

```bash
sudo apt-get update
sudo apt-get -y install android-tools-adb
```

Verify that ADB is installed.

```bash
adb version
```

Should see something like:

```text
Android Debug Bridge version 1.0.41
Version 34.0.4-debian
Installed as /usr/lib/android-sdk/platform-tools/adb
Running on Linux 6.8.0-134-generic (x86_64)
```

Example on how to pull the results of a particular recording session.

Usually, on Linux, the 'adb' path to the app on the Android smartphone is something like: 
`/sdcard/Android/data/com.faunapulse.app/files/`. 
This path is also valid: 
`/storage/emulated/0/Android/data/com.faunapulse.app/files/`

There you find these:

```text
/sdcard/.../files
├── error_reports/    # error reports generated by the end-user
├── models/           # any custom models (e.g. `.tflite` files)
└── sessions/         # a folder per recording session with the results (images + metadata)
```

```bash
# 1) Locate the destination folder on your computer
cd ~/InsectDetectApp/sessions/Xiaomi/

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
adb -s 2b2dc560 pull -a /sdcard/Android/data/com.faunapulse.app/files/. ./

# Or pull directly into the destination folder (without `cd` command first):
adb pull -a /sdcard/Android/data/com.faunapulse.app/files/ ~/InsectDetectApp/sessions/Xiaomi/
```

#### On Windows

> To be added.