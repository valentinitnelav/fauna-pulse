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
| Session photos | JPEG crops of the region you selected, plus optional reference frames |
| `session.jsonl` | Session log: timestamps, detections, track identifiers, box coordinates, settings used, phone model, battery and temperature readings, and the session position if you set one |

Imported models, crash files and problem reports are kept in private internal
storage. Other apps cannot browse these files. A problem report becomes readable
to the app you choose only when you explicitly use Share.

Uninstalling FaunaPulse deletes its external and private app storage. You can also
delete individual sessions, or all of them, from inside the app.

Detection runs entirely on the phone's own processor. Camera images are never
uploaded, and no image ever leaves the device unless you export or share it yourself.

## Android system backup

FaunaPulse explicitly permits Android to back up app settings only. If Android
backup is enabled on your phone, Google may store those settings in your account
and restore or transfer them to another device. The settings can include the last
optional GPS coordinates you entered or obtained.

Session photos, session logs, imported models, crash files and problem reports are
excluded from the app's backup rules. FaunaPulse does not itself upload backup data
and cannot control whether you enable Google's system backup.

## Permissions, and why each one is needed

| Permission | Why |
|---|---|
| Camera | The core function: the live preview and the on-device detector |
| Location (precise / approximate) | Optional. One single position fix per session, so recorded visits can be placed on a map later. FaunaPulse never tracks you continuously, and you can type coordinates by hand or skip location entirely |
| Internet | Only for downloading a detection model when you ask for one (see below). No other network use |
| Notifications | To show the ongoing notification of the recording service, so Android does not stop a long session |
| Foreground service (camera) | Keeps a session recording reliably while the screen is off or another app is in front |
| Prevent sleeping | Keeps long field sessions running instead of being suspended by the system |

For reliable unattended sessions, FaunaPulse can open Android's general battery
settings. You choose there whether to allow unrestricted operation. The app does
not request the restricted direct battery-exemption permission.

## When the app uses the internet

FaunaPulse is designed to run fully offline, and normal recording never touches the
network. There are exactly two exceptions, both about detection models:

1. You paste an HTTPS link into **Settings, Download model**, and the app fetches that file.
2. You select a standard model that is not bundled in your build, and the underlying
   Ultralytics component downloads it once over HTTPS from its public release page.

Both are model downloads only. Nothing about you, your sessions, your photos or your
location is sent anywhere in the process.

## Problem reports and crash files

If something goes wrong, **Report a problem** builds a plain-text file on the phone
containing app and device information, your description, recent crash files, your
settings, a sample of the most recent session log and recent system log lines. The
file is created locally, and it is only sent if you choose to share or e-mail it. GPS
coordinates are stripped from the session sample before the report is written, so
sensitive site locations are not disclosed by accident. Problem reports and the
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
coordinates when in doubt. Note that crops you export from the summary screen carry the
capture time and, if set, the session position in their EXIF metadata (session photos
themselves carry no EXIF).

## Changes to this policy

Any change will be committed to this file in the public repository, so the version
history is the record.

## Contact

Questions or concerns: open an issue at
<https://github.com/valentinitnelav/fauna-pulse/issues>.

<!-- OWNER TODO (round 158): Google Play's Data safety form also asks for a contact
     e-mail address, which is entered in the Play Console and does not have to appear
     here. Decide whether you also want a contact e-mail in this public file (an
     institutional address is safer than a personal one). -->
