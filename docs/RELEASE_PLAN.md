# FaunaPulse Release Plan (for first public release and beyond)

A living checklist for taking FaunaPulse from working prototype to a citable, publicly
distributed app. Tick boxes as work lands; each implementation batch is a numbered round in
`AGENT_CHANGELOG.md`. A new Claude session working on release topics should re-ground by
reading THIS file (not the full changelog).

Created 2026-07-28 (round 157). App state at that date: v0.6.4+10, AGPL-3.0, no git tags
yet, no release keystore, docs written for researchers.

## Decisions already made (owner, 2026-07-28)

- **Sequence:** quick hygiene fixes first, then an early `v0.7.0` tag with a Zenodo DOI,
  then docs + UX polish, then Google Play. Reason: Zenodo only archives releases created
  AFTER its webhook is enabled (no retroactive DOIs).
- **Heat/performance controls move to a renamed "Power" tab**, not the AI tab: the AI tab
  is fully greyed out in the no-AI capture modes (round 147 mechanism), but the motion
  gate must stay editable in motion mode, where its sensitivity fields ARE the capture
  sensitivity.
- **Free distribution channel: GitHub Releases + Obtainium** (an Android app that installs
  and auto-updates apps directly from a project's GitHub releases; needs nothing from us
  beyond tagged releases with stable APK file names). IzzyOnDroid is ruled out (approx.
  30 MB APK limit vs our 116.5 MB universal release APK, round-160 measurement; the
  QNN runtime alone is ~76 MB of that, see review E8). F-Droid main repo is an
  optional later phase.
- **Signing strategy (irreversible, do first):** generate and keep OUR own keystore (the
  key file that signs every APK; Android only installs an update if it is signed with the
  same key as the installed version). Upload that key to Play App Signing so a Play
  install and a GitHub-APK install can update each other. If Google generated the key
  instead, the two channels would be permanently split.

## Hard deadlines and gates

| What | When | Why |
|---|---|---|
| Target API 36 (Android 16) | new Play apps from **2026-08-31** | Play requirement; currently not pinned in build.gradle |
| Play closed test: **12 testers, 14 continuous days** | before production access | rule for personal developer accounts created after Nov 2023 |
| Zenodo webhook enabled | **before the first git tag** | Zenodo cannot mint DOIs for pre-existing releases |
| Android developer verification | enforcement 2026-09-30 (BR, ID, SG, TH), global 2027 | Play registration satisfies it; also protects the GitHub-APK channel on certified devices |

## Build-config state

Fixed in round 158:

- [x] SDK levels pinned in `android/app/build.gradle`: `minSdk 24`, `targetSdk 36`,
  `compileSdk 36` (verified in the built APK). They previously followed whichever
  Flutter SDK was installed. The Play API-36 deadline is therefore already met.
- [x] `fetchBundledModels` now runs `fauna-pulse/scripts/fetch_bundled_models.sh` (new,
  ours) and downloads ONLY the default `yolo26n_int8.tflite` into `assets/models/`.
  It used to point outside the repo at the plugin's script, which writes into the
  plugin's own example app and pulls six unused task variants.
- [x] Release builds are blocked when the bundled model is missing (escape hatch:
  `-PallowMissingBundledModels`). Note the ordering: `fetchBundledModels` runs first,
  so on an online machine the model is simply downloaded and the guard never fires; it
  is an offline/failed-download backstop.
- [x] `scripts/create_release_keystore.sh` + `android/key.properties.example` + INSTALL.md
  section B4 make signing setup a one-command step.

Still open:

- [x] **The owner must run the keystore script once** and back the keystore up. Until then
  `flutter build apk --release` fails by design (verified: fails in ~33 s, before
  compilation, with instructions).
- [x] The stale `build/.../app-release.apk` with the old id `com.pollinatormonitor.app`
  was overwritten by the 2026-07-28 rebuild (now `com.faunapulse.app`, release-signed).
- [ ] The two camera `uses-feature` manifest entries default to required=true (narrows Play
  device eligibility; decide whether to mark them `android:required="false"`).
- [ ] `ic_launcher-playstore.png` is 1.1 MB; the Play listing icon must be 512x512 and
  at most 1 MB (recompress).
- [ ] Universal APK ships 4 ABIs (CPU architectures); GitHub releases should use
  `--split-per-abi` so each APK is far smaller.
- [ ] Third-party license attribution (round 189): the About dialog's
  "Third-party licenses" page (Flutter's auto-generated LicensePage) was removed
  by owner decision; the About now points at the repository. Several bundled
  BSD/MIT/Apache packages expect their license text to accompany distributed
  binaries, so before the Play/store release decide how to satisfy that
  (cheapest: restore the one muted LicensePage button — it is auto-generated,
  zero maintenance; alternatives: a THIRD_PARTY_NOTICES file linked from the
  Play listing/README).

## Open question for the owner

The bundled `yolo26n` is a general-purpose COCO detector: it makes the AI pipeline run
out of the box but it does **not** recognise insects. So a citizen scientist who
installs the app today cannot detect insects without obtaining a model from somewhere.
Decide whether an insect-trained `.tflite` may be published as a public GitHub release
asset (licence, collaborator approval). If yes, the "Download…" button becomes a
copy-paste step and QUICK_START can promise real detections. If no, the docs must say
plainly that AI mode needs a model the user supplies. Marked as an OWNER TODO comment
in README (§Models).

---

## Phase 0: release prerequisites (repo hygiene, ~1 round)

- [x] Create this `docs/RELEASE_PLAN.md` and a Claude memory pointer to it (round 157).
- [x] Signing made a one-command step: `scripts/create_release_keystore.sh`,
      `android/key.properties.example`, INSTALL.md section B4 (round 158).
- [x] **OWNER: run `bash scripts/create_release_keystore.sh` once, then back the
      keystore up** in two places plus the password in a password manager. Losing it
      means no user can ever update the app.
- [x] Pin `minSdk 24` / `targetSdk 36` / `compileSdk 36` (round 158; verified in the
      built APK, tests and analyze clean).
- [x] Fix `fetchBundledModels` and block release builds with no bundled model
      (round 158).
- [x] `PRIVACY_POLICY.md` at the repo root (round 158): offline processing, permission
      table, the two model-download exceptions, problem reports with location
      redaction, protected-species note.
- [x] `CITATION.cff`: stale TODO comments removed (round 158); DOI line stays commented
      until Phase 1.
- [x] README: bundled model explained honestly ("runs out of the box, does not know
      insects"); INSTALL.md A3 aligned (round 158).
- [x] `docs/FIELD_GUIDE.md`: title typo fixed, physical-setup section written from what
      the code guarantees, with an OWNER TODO comment for the field knowledge only the
      owner has (mount model, distance in cm, lighting/glare, wind) (round 158).
- [x] Start a human-facing `CHANGELOG.md` (round 158).
- [x] Rebuild and smoke-test a release APK with the new keystore on a device
      (2026-07-28: 122.1 MB release APK built and installed on the Samsung, remeasured
      116.5 MB in round 160; the first
      install attempt failed with INSTALL_FAILED_UPDATE_INCOMPATIBLE because the phone
      still carried a debug-signed build, expected one-time step, resolved by
      uninstalling first). Convention going forward: Samsung = release-test phone,
      Xiaomi = debug/dev phone, so the two signatures never fight on the same device.

## Phase 1: v0.7.0 GitHub release + Zenodo DOI (~1 round + owner web steps)

Owner web steps (Claude prepares text, owner clicks):
- [ ] zenodo.org: log in via GitHub, link ORCID in the Zenodo profile, open the GitHub
      settings page, Sync, toggle `fauna-pulse` ON. Must happen BEFORE tagging.
- [ ] datacite.org (DataCite Profiles): enable "ORCID Auto-Update" once, so the Zenodo DOI
      is pushed to the ORCID record automatically. Works only when the ORCID iD is in the
      CITATION.cff authors (it is).

Repo steps:
- [ ] Bump version to `0.7.0+11`, tag `v0.7.0`, create a GitHub Release with release notes.
- [ ] Attach release-key-signed APKs: `flutter build apk --release --split-per-abi`;
      upload `arm64-v8a` (covers virtually all modern phones) and optionally
      `armeabi-v7a`. Keep asset names stable across releases
      (e.g. `faunapulse-v0.7.0-arm64-v8a.apk`) so Obtainium users' filters keep working.
- [ ] After Zenodo processes the release: put the CONCEPT DOI (the all-versions DOI) into
      `CITATION.cff`, and add DOI + license + version badges to the README (the DOI badge
      slot is already reserved as an HTML comment near README line 180).
- [ ] INSTALL.md Track A: add an "install via Obtainium" subsection next to the
      direct-APK route.

Verification: DOI resolves; GitHub shows "Cite this repository"; a fresh phone installs
the arm64 APK and the AI pipeline runs with the bundled model out of the box (the
bundled yolo26n knows COCO objects, not insects; real insect detections still need a
model the user obtains, see the open owner question above).

## Phase 2: citizen-scientist documentation (~2 rounds + owner screenshots)

- [ ] `docs/QUICK_START.md`: one page, plain language, zero jargon: install, point at a
      flower, drag the box, press REC, look at your photos. Linked first in the README.
      Owner captures 6-10 screenshots on-device (also reused for the Play listing).
- [ ] README: reorder for two audiences ("I want to use it" first, "I want the
      science/code" second); demote the 3 agent-facing docs to a footnote; add a
      screenshots section.
- [ ] Strip internal "(round N)" references from user docs (39 in DATA_GUIDE, 14 in
      SETTINGS_REFERENCE, 3 in FIELD_GUIDE, header of HOW_PHOTO_RESOLUTION_WORKS);
      relabel HOW_PHOTO_RESOLUTION_WORKS as advanced-user (currently "Developer", but it
      is the friendliest explainer in the repo).
- [ ] Short glossary (ROI, model, confidence, track/visit, JSONL) in QUICK_START or
      README; define terms at first use elsewhere.
- [ ] CONTRIBUTING: add non-code contribution paths (bug reports via the in-app problem
      report, field observations, doc fixes); add `CODE_OF_CONDUCT.md`
      (Contributor Covenant).
- [ ] `fastlane/metadata/android/en-US/` (a standard folder layout for store texts:
      `short_description.txt` under 80 chars, `full_description.txt`, icon,
      `images/phoneScreenshots/`, `changelogs/<versionCode>.txt`). Written once, it
      serves the Play listing AND the F-Droid/IzzyOnDroid conventions.
- [ ] Optional, recommended: GitHub Actions CI running
      `flutter analyze` + `flutter test` on push, APK build on tag.

## Phase 3: settings UX reorganization (4 rounds, design agreed)

Target: 4 tabs grouped by user intent. **Setup** (what am I recording?), **AI** (how does
detection behave?), **Photos** (was Camera: what do my saved photos look like?),
**Power** (was Graphs: heat, battery, rates). A citizen scientist should be able to run a
session touching only: output folder, capture trigger, session length, and maybe the model.
No SessionConfig JSON keys change anywhere (wire-frozen); only UI placement, folds, and
wording move. Reuse existing patterns: the ExpansionTile advanced-fold template
(`_advancedTrackerSection`, settings_sheet.dart L1256), per-control mode-aware greying,
conditional children lists.

All four sub-rounds landed together as **round 159** (2026-07-28): analyzer
clean, 363 tests pass (4 new for the ⓘ help toggle), no SessionConfig key
changes. Remaining: the owner's on-device pass across the 3 capture modes
(settings round-trip, greying, folds, gate fold auto-open in motion mode).

- [x] **Round A (core fix):** rename Graphs to Power; move from the Camera tab: the
      auto-throttle switch + max/min inference rate + duty target (L1638-1740), the
      camera FPS cap (L1538), and the motion gate + its 5 sensitivity fields
      (L1747-1871), keeping all greying logic verbatim. Folds on Power:
      "Advanced (throttle tuning)" (min rate + duty target), "Gate sensitivity"
      (auto-expanded in motion mode via `initiallyExpanded: _c.motionOnlyCapture` plus a
      ValueKey so a mode switch rebuilds it), "Diagnostic graph sampling" (the 3 old
      Graphs fields). Power-tab intro sentence points at the live-screen power-save
      button. Re-point cross-reference strings (Setup trigger explainer L363, gate
      subtitle L1760, sheet header comment).
- [x] **Round B (Setup + AI + Photos polish):** Setup gains a collapsed "On-screen
      display" fold (show boxes, info panel, ROI flash, plus "Show FPS" arriving from the
      AI tab L898); session length moves up next to the trigger. AI tab: new fold
      "Advanced (engine & thresholds)" (IoU, GPU switch, CPU threads, benchmark button);
      the tracker-algorithm dropdown moves into the existing advanced tracker fold
      (owner sign-off: keep it visible one release longer if still A/B-comparing trackers
      in the field). Photos tab: saved-photo-side first, "Square (1:1) export crops"
      arrives from Graphs, stream-resolution dropdown goes into an
      "Advanced (camera stream)" fold above the existing lens-info fold. The AI-tab
      whole-greying (r147) stays untouched (everything left on it is detector-only).
- [x] **Round C (helper-text density):** per-field info toggle inside
      `NumericSettingField` / `DurationSettingField` (small info icon in the label row;
      the helper paragraph renders only when tapped; ephemeral state, no API change for
      the ~40 call sites). Add the widgets' first widget test.
- [x] **Round D (app-level settings home):** "Show setup tips" moves from the sheet to
      the home-screen ⋮ menu as a CheckedPopupMenuItem (it is the only app-level
      preference inside the otherwise per-session sheet; `kHideSessionInfoPrefKey`
      unchanged). Extend the home menu test.

Every round: update `docs/SETTINGS_REFERENCE.md` in the same round (its headings already
say "(AI tab)" for throttle/gate, stale vs the code; Round A fixes that), append an
AGENT_CHANGELOG round entry, run `flutter analyze` + `flutter test test/fauna_pulse`, and
do an on-device pass across all 3 capture modes (settings round-trip, greying, folds).

## Phase 4: Google Play (can start alongside Phase 2; live in ~4-6 weeks)

- [ ] Owner registers a personal Play developer account ($25 one-time, government-ID
      verification). This also satisfies the new Android developer-verification program.
- [ ] Play App Signing: upload OUR keystore (from Phase 0) as the app signing key, so
      GitHub and Play builds stay cross-updatable.
- [ ] Build config: `flutter build appbundle` (AAB, the publishing format Play requires;
      Play generates per-device APKs from it); confirm targetSdk 36; decide
      `android:required="false"` for the two camera uses-feature entries; keep
      `useLegacyPackaging` (the QNN/NPU runtime needs real file paths) and accept the
      size cost. (A lean two-artifact alternative is documented, not implemented, in
      [LEAN_QNN_PACKAGING.md](LEAN_QNN_PACKAGING.md) — review E8, round 171 — with the
      reopen triggers; this bullet's decision stands until one fires.)
- [ ] Store listing: reuse the fastlane texts; feature graphic 1024x500; 2-8 phone
      screenshots (from Phase 2); recompress the 1.1 MB playstore icon to at most 1 MB;
      privacy policy URL (Phase 0 file); Data safety form ("no data collected":
      everything stays on-device; declare and justify camera, location, foreground
      service, and battery-optimization exemption); content rating questionnaire.
      (Exact asset specs are long-standing but re-verify in the Console during setup.)
- [ ] Closed testing: recruit 12+ testers (iDiv/UFZ colleagues, field assistants), keep
      them opted in for 14 continuous days, then "Apply for production" (decision usually
      within ~7 days).
- [ ] After production: Play badge in README; keep GitHub releases in lockstep with Play
      (same versionCode, same signing key).

## Phase 5 (optional, later): F-Droid main repo

Only if wanted after v1.0: explicitly license the bundled `.tflite` models and add a
`MODEL_CARD.md` (training provenance), then submit a merge request to `fdroiddata` on
GitLab. Expect a case-by-case discussion about pre-trained model files (F-Droid has no
formal policy on them; an open forum question from Sept 2025 is unresolved). Fallback if
rejected: stay on GitHub + Obtainium, which we have anyway. Flutter itself is explicitly
supported by F-Droid.

## Verification (end-to-end)

- `flutter analyze` clean and `flutter test test/fauna_pulse` green after every round.
- Fresh clone builds a release APK that installs and runs the AI pipeline with the
  bundled model (validates the Phase 0 build fixes; the bundled COCO model does not
  detect insects, see the open owner question).
- DOI badge resolves; `CITATION.cff` validates (cffconvert); Obtainium picks up a new
  tagged release within a day.
- Play pre-launch report (Google's automatic device-farm test of the uploaded build) on
  the closed track before applying for production.

## Sources (checked 2026-07-28)

- Play closed-testing requirement (12 testers / 14 days): https://support.google.com/googleplay/android-developer/answer/14151465
- Play target API levels (API 36 from 2026-08-31): https://developer.android.com/google/play/requirements/target-sdk
- Play account types / D-U-N-S (organizations only): https://support.google.com/googleplay/android-developer/answer/13634885
- Play registration fee: https://support.google.com/googleplay/android-developer/answer/6112435
- Play Data safety + privacy policy (required even with no data collected): https://support.google.com/googleplay/android-developer/answer/10787469
- Play App Signing (own-key upload): https://support.google.com/googleplay/android-developer/answer/9842756
- Android App Bundle FAQ (AAB mandatory, 200 MB base limit): https://developer.android.com/guide/app-bundle/faq
- Android developer verification program: https://developer.android.com/developer-verification and https://support.google.com/android-developer-console/answer/16561738
- AGPL on Play precedent (Signal): https://github.com/signalapp/Signal-Android
- F-Droid inclusion policy / how-to (Flutter supported; fastlane layout): https://f-droid.org/docs/Inclusion_Policy/ and https://f-droid.org/docs/Inclusion_How-To/
- IzzyOnDroid inclusion policy (approx. 30 MB limit): https://izzyondroid.org/docs/general/AppInclusionPolicy/
- Obtainium: https://github.com/ImranR98/Obtainium
- Zenodo GitHub integration: https://help.zenodo.org/docs/github/enable-repository/ and metadata precedence: https://help.zenodo.org/docs/github/describe-software/
- DataCite ORCID auto-update: https://support.datacite.org/docs/datacite-and-orcid
