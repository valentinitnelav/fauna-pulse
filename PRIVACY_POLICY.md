# FaunaPulse Privacy Policy

Applies to the FaunaPulse Android application (`com.faunapulse.app`) and its source code in this repository.

## Short version

FaunaPulse itself does not collect, transmit or sell personal data. There is no
account, advertising, analytics or tracking library. Photos, session logs and the
optional GPS position stay on your phone unless you deliberately copy or share them.
Android may back up the app's settings to your Google account if system backup is
enabled, as described below.

## What the app creates, and where it stays

While a session records, FaunaPulse writes field data to its own folder
(`Android/data/com.faunapulse.app/files/`):

| What | Contents |
|---|---|
| Session photos | JPEG crops of the region you selected (ROI), plus optional reference frames |
| Session videos | Video clips of the region you selected, and the videos you import for analysis (copied or moved into the session folder) |
| Field notes and site photos | What you type into the field notes, and the site photos you take for them |
| `session.jsonl` | Session log: timestamps, detections, track identifiers, box coordinates, settings used, phone model, whether airplane mode, Wi-Fi and Bluetooth were switched on, battery and temperature readings, your field notes, and the session position if you set one |
| Analysis results | Detections, track IDs and identifications found afterwards, saved as files next to the session log |

Imported and downloaded models, crash files and problem reports are kept in the app's internal
storage. A problem report becomes readable
to the app you choose only when you explicitly use a sharing option.

Uninstalling FaunaPulse deletes its external and private app storage. You can also
delete individual sessions, or all of them, from inside the app.

Detection runs entirely on the phone's own processor. Camera images are never
uploaded, and no image ever leaves the device unless you export or share it yourself.

## Android system backup

FaunaPulse explicitly permits Android to back up app settings only. If Android
backup is enabled on your phone, Google may store those settings in your account
and restore or transfer them to another device. The settings can include the last
optional GPS coordinates you entered or obtained, and the field notes you last typed (for
example the "Set up by" name and your notes).

Session photos, session logs, imported models, crash files and problem reports are
excluded from the app's backup rules. FaunaPulse does not itself upload backup data
and cannot control whether you enable Google's system backup.

## Permissions, and why each one is needed

| Permission | Why |
|---|---|
| Camera | The core function: the live preview and the on-device detector |
| Location (precise / approximate) | Optional. One single position fix per data recording session, so recorded visits / sampled site can be placed on a map later. FaunaPulse never tracks you continuously, and you can type coordinates by hand or skip location entirely. The position comes from Android's location service: on phones with Google Play services this is Google's location service (Fused Location Provider), and Google's own privacy policy applies to it |
| Internet | For downloading an AI model or a name list when you ask for one (see below). Nothing uses the network automatically |
| Notifications | To show the ongoing notification of the recording service, so Android does not stop a long session |
| Foreground service (camera) | Keeps a session recording reliably while the screen is off or another app is in front |
| Foreground service (data sync, media processing) | Keeps "Find animals in videos/photos" and identification going while the screen is off or another app is in front |
| Prevent sleeping | Keeps long field sessions running instead of being suspended by the system |
| Start after reboot, network state | Added by a library that LiteRT (the on-device AI engine) uses to plan background work. FaunaPulse itself starts nothing after a reboot and does not use the network-state permission |

For reliable unattended sessions, FaunaPulse can open Android's general battery
settings. You choose there whether to allow unrestricted operation. The app does
not request the restricted direct battery-exemption permission.

## When the app uses the internet

FaunaPulse is designed to run fully offline, and normal recording never touches the
network. No AI model comes inside the app, so you download the ones you need once. There
are exactly two exceptions, both about AI models and their name lists:

1. You tap a download on the **Download & import models** screen or on a **What do you
   want to watch?** page. The file is downloaded over HTTPS from the link in the app's
   built-in list of models, which points to the project's model pages on Hugging Face
   (huggingface.co) or to the project's GitHub releases.
2. You paste an HTTPS link into **Download from a link**, and the app fetches that file.

Both are file downloads only. Nothing about you, your sessions, your photos or your
location is sent anywhere in the process. As with any download, the server that holds the
file (Hugging Face, GitHub or the site of a link you entered) sees your phone's internet
address and the request; their own privacy policies apply to that.

## Problem reports and crash files

If something goes wrong, **Report a problem** builds a plain-text file on the phone
containing app and device information, your description, recent crash files, your
settings, a sample of the most recent session log and recent system log lines. The
file is created locally, and it is only sent if you choose to share or e-mail it. GPS
coordinates and the field notes you typed (names, places, notes, the values of your own
fields) are removed from the session sample before the report is written, so sensitive
sites and names are not disclosed by accident. The session name and the names of your own
fields stay, so please read a report before you post it in a public place such as a GitHub
issue. Problem reports and the
newest 20 crash files are stored in the app's private internal storage, excluded
from Android backup, and never transmitted automatically.

## Children

FaunaPulse is a field research tool and is not directed at children. It collects no
personal information from anyone, including children.

## Responsible use of location data

Coordinates recorded by the app describe where you observed wildlife. If you publish
photos, session logs or exported crops, consider that precise coordinates of protected,
rare or persecuted species can put populations at risk, and that photographing on
private land or in protected areas may be regulated where you live. Blur or omit exact
coordinates when in doubt. Note that crops you save or share from the summary screen carry
the capture time and, if set, the session position in their EXIF metadata (session photos
themselves carry no EXIF). To leave the position out, turn off "Add the position to exported
crops" in Session settings (Photos tab).

On Android 10 and older, other apps that have the storage permission can read the app's
session folder (`Android/data/com.faunapulse.app/files/`), with its photos, positions and
field notes. Android 11 and newer block this. On field phones with Android 10 or older,
install only apps you trust.

## Changes to this policy

Any change will be committed to this file in the public repository, so the version
history is the record.

## Contact

Questions or concerns: open an issue at
<https://github.com/valentinitnelav/fauna-pulse/issues>.
