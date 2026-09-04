# Google Play Store listing — draft answers (round 204)

Copy-paste starting point for the Play Console forms, grounded in `PRIVACY_POLICY.md`
and the current `AndroidManifest.xml` permissions. This is a draft: re-verify against
the live Play Console wording during setup (form fields change over time), and the
owner must review before submitting anything. See `docs/RELEASE_PLAN.md` Phase 4 for
the full checklist this supports.

## Store listing basics

- **App name:** FaunaPulse
- **Short description / Full description:** see
  `fastlane/metadata/android/en-US/short_description.txt` and `full_description.txt`
  (same texts work for Play, F-Droid and IzzyOnDroid).
- **App category:** suggest **Science** (fallback: Tools) — no specific "Nature/Field
  research" category exists on Play.
- **Contact details (email):** OWNER TODO — Play requires a public contact email in
  the Data safety form / store listing, separate from `PRIVACY_POLICY.md`. Prefer an
  institutional address over a personal one (same open question already flagged in
  `PRIVACY_POLICY.md`'s round-158 owner-TODO comment).
- **Privacy policy URL:** OWNER TODO — Play requires a URL, not a repo file path.
  Once the repo is public, the raw GitHub URL works:
  `https://github.com/valentinitnelav/fauna-pulse/blob/main/PRIVACY_POLICY.md`
  (or the GitHub Pages site once that exists, per RELEASE_PLAN.md Phase 2).
- **Graphic assets still needed (owner):** 1024×500 feature graphic (none exists yet
  for FaunaPulse itself), 2-8 phone screenshots (reuse the 6-10 captured for Phase 2 /
  the docs site). The Play Store icon is already prepared:
  `android/app/src/main/ic_launcher-playstore.png`.

## Content rating questionnaire — draft answers

Play's questionnaire is dynamic (IARC), but the expected answers based on the app's
actual behavior:

- Violence, sexual content, profanity, controlled substances, gambling: **None** —
  FaunaPulse only records passive images of animals/environment for research.
- User-generated content shared with others: **No** — nothing the app records is
  shared with other users; sharing is a manual, user-initiated action (export/share a
  crop or a problem report), not an in-app social feature.
- Location sharing: the app can attach a single optional GPS fix to a session, but it
  is never transmitted anywhere by the app itself — see Data safety below.
- Expected outcome: rating suitable for all ages (e.g. "Everyone" / PEGI 3), pending
  the actual questionnaire flow.

## Data safety form — draft answers

**Does your app collect or share any of the required user data types?**
Recommended answer: **No data is collected or shared**, with the following nuance
Play's newer forms allow ("data processed but not collected/transmitted off-device"):

| Data type | Collected? | Shared? | Notes |
|---|---|---|---|
| Location (precise/approximate) | Processed on-device only, not "collected" (never leaves the device) | No | One optional GPS fix per session, stored only in the app's local session log; see `PRIVACY_POLICY.md` "Permissions" table |
| Photos/videos | Processed on-device only | No | ROI-cropped session photos stay in local app storage unless the user manually exports/shares them |
| App info and performance (crash logs) | Processed on-device only | No | Crash files/problem reports are written locally and only leave the device if the user explicitly shares them |
| Any other category (contacts, financial, health, messages, etc.) | Not collected | Not shared | App has no account, no ads SDK, no analytics SDK |

**Is all of the user data collected encrypted in transit?** N/A — no user data is
transmitted off the device by the app. (The two narrow exceptions are outbound-only
HTTPS model file downloads the user explicitly triggers — no user data is sent, only
a `.tflite` file is received; see `PRIVACY_POLICY.md` "When the app uses the
internet".)

**Can users request data deletion?** Yes, entirely on-device: users can delete
individual sessions or all app data from within the app, or by uninstalling (which
deletes all app storage — external and private).

**Does your app have a privacy policy?** Yes — see the Privacy policy URL above.

## Permissions declared (from `AndroidManifest.xml`) — justification for the Play form

| Permission | Justification |
|---|---|
| `CAMERA` | Core function: live preview + on-device detector |
| `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` | Optional, one single position fix per session; user can skip or type coordinates manually |
| `INTERNET` | Only for user-initiated detection-model downloads (HTTPS); no other network use |
| `POST_NOTIFICATIONS` | Ongoing notification for the recording foreground service |
| `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_CAMERA` | Keeps a recording session running reliably while the screen is off or another app is in front |
| `WAKE_LOCK` | Keeps long unattended field sessions from being suspended by the system |

No direct battery-exemption permission and no data-sync permission are requested
(`FOREGROUND_SERVICE_DATA_SYNC` is explicitly removed via `tools:node="remove"` in the
manifest — it arrives transitively from a LiteRT dependency and is unused).

## Still open (owner decisions, not resolved by this draft)

- Contact email for Play Console / Data safety form (institutional vs personal).
- Public privacy-policy URL to use at submission time (raw GitHub file vs. a future
  Pages site).
- Feature graphic (1024×500) and final screenshot selection.
