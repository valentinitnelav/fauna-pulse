# FaunaPulse Privacy Policy

Applies to the FaunaPulse Android application (`com.faunapulse.app`) and its source code in this repository.

## Short version

FaunaPulse does not collect, transmit or sell any personal data. There is no account,
no advertising, no analytics and no tracking library. Everything the app records
(photos, session logs, the optional GPS position) is written to storage on your own
phone and stays there unless you deliberately copy or share it.

## What the app creates, and where it stays

While a session records, the app writes to its own folder on your phone
(`Android/data/com.faunapulse.app/files/`):

| What | Contents |
|---|---|
| Session photos | JPEG crops of the region you selected, plus optional reference frames |
| `session.jsonl` | Session log: timestamps, detections, track identifiers, box coordinates, settings used, phone model, battery and temperature readings, and the session position if you set one |
| Diagnostic files | Crash files and problem reports you generate yourself |

Uninstalling the app deletes this folder. You can also delete individual sessions,
or all of them, from inside the app.

Detection runs entirely on the phone's own processor. Camera images are never
uploaded, and no image ever leaves the device unless you export or share it yourself.

## Permissions, and why each one is needed

| Permission | Why |
|---|---|
| Camera | The core function: the live preview and the on-device detector |
| Location (precise / approximate) | Optional. One single position fix per session, so recorded visits can be placed on a map later. FaunaPulse never tracks you continuously, and you can type coordinates by hand or skip location entirely |
| Internet | Only for downloading a detection model when you ask for one (see below). No other network use |
| Notifications | To show the ongoing notification of the recording service, so Android does not stop a long session |
| Foreground service (camera) | Keeps a session recording reliably while the screen is off or another app is in front |
| Prevent sleeping / ignore battery optimisation | Keeps long field sessions running instead of being suspended by the system |

## When the app uses the internet

FaunaPulse is designed to run fully offline, and normal recording never touches the
network. There are exactly two exceptions, both about detection models:

1. You paste a link into **Settings, Download model**, and the app fetches that file.
2. You select a standard model that is not bundled in your build, and the underlying
   Ultralytics component downloads it once from its public GitHub release page.

Both are model downloads only. Nothing about you, your sessions, your photos or your
location is sent anywhere in the process.

## Problem reports and crash files

If something goes wrong, **Report a problem** builds a plain-text file on the phone
containing app and device information, your description, recent crash files, your
settings, a sample of the most recent session log and recent system log lines. The
file is created locally, and it is only sent if you choose to share or e-mail it. GPS
coordinates are stripped from the session sample before the report is written, so
sensitive site locations are not disclosed by accident. Crash files are stored on the
phone (the newest 20) and are never transmitted automatically.

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
history is the record. The date at the top shows the latest revision.

## Contact

Questions or concerns: open an issue at
<https://github.com/valentinitnelav/fauna-pulse/issues>.

<!-- OWNER TODO (round 158): Google Play's Data safety form also asks for a contact
     e-mail address, which is entered in the Play Console and does not have to appear
     here. Decide whether you also want a contact e-mail in this public file (an
     institutional address is safer than a personal one). -->
