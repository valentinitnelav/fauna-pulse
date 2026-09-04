# FaunaPulse Release Plan (for first public release and beyond)

A living checklist for taking FaunaPulse from working prototype to a citable, publicly
distributed app. Tick boxes as work lands; each implementation batch is a numbered round in
`AGENT_CHANGELOG.md`. A new code-agent session working on release topics should re-ground by
reading THIS file (not the full changelog).

Created 2026-07-28 (round 157). App state at that date: v0.6.4+10, AGPL-3.0, no git tags
yet, no release keystore, docs written for researchers.

## Decisions already made (owner, 2026-07-28)

- **Sequence:** quick hygiene fixes first, then an early `v0.7.0` tag with a Zenodo DOI,
  then docs + UX polish, then Google Play. Reason: Zenodo only archives releases created
  AFTER its webhook is enabled (no retroactive DOIs).
- **Tag scheme, updated (owner, 2026-09-04):** the first tag is `v0.7.0-alpha.1`, not a
  bare `v0.7.0`. README already describes FaunaPulse as an "early research preview
  (alpha)" (Project status section); the owner wants that reflected in the tag itself,
  not left implicit in SemVer's 0.x convention. Standard SemVer pre-release suffix,
  paired with checking GitHub's "Set as a pre-release" box when publishing. Every
  `v0.7.0` reference below now means `v0.7.0-alpha.1`; future alphas bump to
  `-alpha.2`, etc., and the suffix drops once the app is no longer alpha.
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
| Target API 36 (Android 16) | new Play apps from **2026-08-31** | Play requirement; pinned in build.gradle since round 158 (done) |
| Play closed test: **12 testers, 14 continuous days** | before production access | rule for personal developer accounts created after Nov 2023 |
| Zenodo webhook enabled | **before the first git tag** | Zenodo cannot mint DOIs for pre-existing releases |
| Android developer verification | enforcement 2026-09-30 (BR, ID, SG, TH), global 2027 | Play registration satisfies it; also protects the GitHub-APK channel on certified devices |

## Build-config state

Fixed in rounds 158, 194, 199, 200, 201 and 202:

- [x] SDK levels pinned in `android/app/build.gradle`: `minSdk 24`, `targetSdk 36`,
  `compileSdk 36` (verified in the built APK). They previously followed whichever
  Flutter SDK was installed. The Play API-36 deadline is therefore already met.
- [x] Round 194 removed `fetchBundledModels` from the build graph. The retained
  `scripts/fetch_bundled_models.sh` is a manual example only and is never executed by
  `flutter build`.
- [x] Round 199 made `assets/models/bundled_models.txt` the single release
  allowlist. The normal `flutter build apk --release` command packages each
  existing listed weight from `assets/models/` or `assets/models/custom/`;
  missing entries warn without failing, and unlisted local weights are excluded
  without deleting the source files. The release model picker uses the same list.
- [x] `scripts/create_release_keystore.sh` + `android/key.properties.example` + INSTALL.md
  section B4 make signing setup a one-command step.
- [x] Round 200 added the Play security baseline: HTTPS-only model downloads,
  bounded and validated private model imports (30 MiB TFLite ceiling), bounded
  native metadata parsing, settings-only Android backup rules, private
  diagnostics, cleartext blocking, minimum manifest permissions, release lint,
  automated dependency updates, CI security regressions, and
  `scripts/security_release_gate.sh` for the signed AAB. The recording wake lock
  also has a renewable timeout and cannot restart as an orphan service.
- [x] Round 201 repaired the fresh-checkout CI gate by tracking the app Gradle
  wrapper that the native-test and Flutter-build steps require. GitHub's checkout
  and Java setup actions use their Node.js 24-based v5 releases, and Dependabot
  now watches GitHub Actions as well as Pub and Gradle.
- [x] Round 202 made repository maintenance legible to contributors:
  `main` is stable, `develop` is the normal PR target, short-lived branches
  are removed after review, and a PR template carries the verification
  checklist. Dependabot version updates now target `develop`, open at most
  three PRs per configured entry, and group only updates that should be reviewed
  together.

Still open:

- [x] **The owner must run the keystore script once** and back the keystore up. Until then
  `flutter build apk --release` fails by design (verified: fails in ~33 s, before
  compilation, with instructions).
- [x] The stale `build/.../app-release.apk` with the old id `com.pollinatormonitor.app`
  was overwritten by the 2026-07-28 rebuild (now `com.faunapulse.app`, release-signed).
- [x] The two camera `uses-feature` entries decided and set (round 193): the back
  camera stays `android:required="true"` (the app is unusable without it, so hiding
  it from camera-less devices on Play is correct); `autofocus` is now
  `android:required="false"` because the app uses manual focus only (round 164) and
  clamps its focus preset to whatever range the lens reports, so fixed-focus
  devices still work.
- [x] `ic_launcher-playstore.png` recompressed (round 193): 1254x1254 at 1.17 MB down
  to the Play-required 512x512 32-bit PNG, now ~218 KB (the original stays in git
  history).
- [x] Per-ABI release APKs scripted (round 193): `scripts/build_release_apks.sh` runs
  `flutter build apk --release --split-per-abi` and stages
  `dist/faunapulse-v<version>-<abi>.apk` (arm64-v8a and armeabi-v7a) under the
  stable Obtainium-friendly names; `dist/` is git-ignored. Used in Phase 1 step 7.
- [x] Third-party license attribution (round 193, owner decision reversing round 189
  for the store release): the About dialog carries a muted "Third-party licenses"
  button again. It opens Flutter's auto-generated LicensePage (zero maintenance,
  satisfies the BSD/MIT/Apache accompany-the-binary clauses) and stays discreet:
  nothing is listed in the About itself, the page opens only on demand, and its
  header warns that the list is long. Extracted `AboutFaunaPulseDialog` widget,
  covered by `test/fauna_pulse/home_about_dialog_test.dart`.

## Open question for the owner

The bundled MegaDetector v6 (`MDV6-yolov10-c_int8_256.tflite`, classes animal / person /
vehicle; rounds 194 and 199) makes the AI pipeline run out of the box but it does **not**
recognise insects specifically. So a citizen scientist who installs the app today cannot
detect insects without obtaining a model from somewhere. Decide whether an insect-trained
`.tflite` may be published as a public GitHub release asset (licence, collaborator
approval). If yes, the "Download…" button becomes a copy-paste step and the Field Guide
can promise real detections. If no, the docs keep saying plainly that insect work needs a
model the user supplies (README §Models, INSTALL.md A3 and the Play full description
already do).

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
- [x] Release bundling finalized: automatic fetching removed; both MDV6 tester
      models required; release copy allowlisted to those two weights (round 194).
- [x] `PRIVACY_POLICY.md` at the repo root (round 158): offline processing, permission
      table, the two model-download exceptions, problem reports with location
      redaction, protected-species note.
- [x] `CITATION.cff`: stale TODO comments removed (round 158); DOI line stays commented
      until Phase 1.
- [x] Release security hardening and checks (rounds 200-201): model and metadata input
      limits, private model/diagnostic storage, explicit settings-only backup,
      cleartext disabled, restricted battery and unused data-sync permissions
      removed, release lint and signed local AAB gate; CI's tracked Gradle
      wrapper and action versions were repaired in round 201.
- [x] Branch and dependency-update workflow documented and configured (round 202):
      contributor PRs and Dependabot version updates target `develop`; README and
      PR template point newcomers to the same rule.
- [ ] **OWNER: in GitHub Settings → General → Pull Requests, enable
      "Automatically delete head branches"; add a `main` ruleset that blocks
      force pushes/deletion and requires a PR plus the security/release check.**
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

## Phase 1: v0.7.0-alpha.1 GitHub release + Zenodo DOI (~1 round + owner web steps)

Step-by-step recipe (round 193). Order matters: public repo first, then the Zenodo
toggle, then the tag/release. Zenodo can only archive releases published AFTER its
webhook exists. The owner does the web steps when ready; Agent can do the repo steps
on request.

Owner web steps:

1. [ ] Make the GitHub repo public. Quick pre-flight before flipping the switch:
       - confirm no signing secrets are tracked: `git ls-files | grep -iE "\.jks|key.properties"`
         must show only `android/key.properties.example` (the real `key.properties`
         and the keystore are git-ignored by round-158 design);
       - skim the git history once for private data (personal emails, collaborator
         model files); README, PRIVACY_POLICY.md and CITATION.cff were already
         written for a public audience in round 158. Re-verified in round 205: the
         only author/committer address in the history is the GitHub noreply one,
         no keystore or `key.properties` is tracked, and the largest tracked file
         is 492 KB (no model binaries);
       - GitHub: repo Settings > General > Danger Zone > "Change visibility" >
         "Make public".
2. [ ] zenodo.org: "Log in with GitHub" (authorizes Zenodo's OAuth app). In the
       Zenodo profile settings, link the ORCID iD.
3. [ ] Zenodo > account menu > GitHub (https://zenodo.org/account/settings/github/):
       press "Sync now", then flip the switch next to `fauna-pulse` ON. This installs
       the webhook. MUST happen before step 6 publishes the release.
4. [ ] datacite.org (DataCite Profiles): sign in with the ORCID iD and enable
       "ORCID Auto-Update" once, so every Zenodo DOI is pushed to the ORCID record
       automatically. Works because the ORCID iD is in CITATION.cff's authors.

Repo steps (Code-agent prepares, owner reviews and pushes):

5. [x] Bump version to `0.7.0-alpha.1+11` in pubspec.yaml, update CHANGELOG.md,
       CITATION.cff and this doc (round 204, prepared on branch
       `release/v0.7.0-alpha.1`; round 205 made version, licence id and description
       consistent across every metadata file). [ ] Owner: merge the release branch
       into `develop`, then `develop` into `main`; on `main` create an annotated tag
       and push both:
       `git tag -a v0.7.0-alpha.1 -m "FaunaPulse v0.7.0-alpha.1"` then
       `git push origin main v0.7.0-alpha.1`. If publishing slips past 2026-09-04,
       first update `date-released` in CITATION.cff and the date in CHANGELOG.md.
6. [ ] GitHub > Releases > "Draft a new release" (or `gh release create`): pick tag
       `v0.7.0-alpha.1`, title "FaunaPulse v0.7.0-alpha.1", **check "Set as a
       pre-release"**, paste release notes (round 205 draft in
       `dist/RELEASE_NOTES_v0.7.0-alpha.1.md`, git-ignored: the CHANGELOG.md
       section plus install lines). PUBLISHING the release (not the tag alone) fires
       the Zenodo webhook. Zenodo's docs say nothing about pre-releases; its GitHub
       integration code ignores only DRAFT releases, so the pre-release flag is
       fine. If no DOI badge appears within ~15 minutes, open the release's
       "Errors" fold on Zenodo's GitHub page (metadata errors can be fixed and the
       release re-published). Zenodo takes its metadata from `CITATION.cff` (a
       `.zenodo.json`, if one existed, would override it entirely; we deliberately
       keep CITATION.cff as the single source): title, authors (ORCID,
       affiliation), abstract, keywords, licence id and version come from there,
       not from the GitHub release form.
7. [ ] Attach the per-ABI APKs: run `bash scripts/build_release_apks.sh` (round 193)
       and upload the two files from `dist/`. `faunapulse-v0.7.0-alpha.1-arm64-v8a.apk`
       covers virtually all modern phones; `...-armeabi-v7a.apk` the old 32-bit
       ones. Keep these asset names stable across releases so Obtainium users'
       filters keep working. Round 205: the script passes
       `-P force-version-code-ignoring-abi=true`, so both APKs carry versionCode 11,
       identical to the Play AAB. Without it Flutter stamps 2011 (arm64) / 1011
       (armeabi) and a phone that installed the GitHub APK could never switch to the
       Play build (Android refuses a lower versionCode), defeating the
       cross-updatable-channels decision above. Verify after the build with aapt2
       from the SDK build-tools:
       `aapt2 dump badging dist/faunapulse-v0.7.0-alpha.1-arm64-v8a.apk | grep versionCode`.
8. [ ] Wait a few minutes, then reload Zenodo's GitHub page: the release should show
       a DOI badge. Open the Zenodo record and copy the CONCEPT DOI (the "Cite all
       versions" one, which always resolves to the newest release), not the
       single-version DOI.
9. [ ] Put the concept DOI into `CITATION.cff` (the line left commented in round
       158) and fill in the DOI + license + version badges reserved as an HTML
       comment in the README, just above the Citation section (added round 204).
       Commit; no new tag needed for this.
10. [x] INSTALL.md Track A2b "install via Obtainium" subsection added (round 204).
       Round 206 correction, verified in Obtainium's source (`github.dart`,
       `includePrereleases` defaults to false and pre-releases are skipped): users
       must switch on "Include prereleases" when adding the app, otherwise Obtainium
       finds no FaunaPulse release at all. Also note that GitHub's
       `/releases/latest` URL ignores pre-releases; link the releases list or the
       tag URL, never `/releases/latest`, while the app is alpha.

Verification: DOI resolves; GitHub shows "Cite this repository"; a fresh phone installs
the arm64 APK and the AI pipeline runs with the bundled MegaDetector v6 (MDV6) model out of
the box.

## Phase 2: citizen-scientist documentation (~2 rounds + owner screenshots)

Owner decisions 2026-08-05 (round 193): no separate QUICK_START.md, `docs/FIELD_GUIDE.md`
already plays that role and keeps being updated; screenshots and video are better hosted
on a GitHub Pages documentation site built from the existing docs (recipe below); CI is
deferred (see the last item).

- [x] ~~`docs/QUICK_START.md`~~ dropped (owner decision 2026-08-05): FIELD_GUIDE.md is
      the quick start. When reordering the README, link it first and label it
      accordingly ("Field guide (start here)"). The owner still captures 6-10
      on-device screenshots (reused for the Pages site AND the Play listing).
- [ ] GitHub Pages documentation site: see the recipe below.
- [ ] README: reorder for two audiences ("I want to use it" first, "I want the
      science/code" second); demote the 3 agent-facing docs to a footnote; add a
      screenshots section; link the Pages site in the header once it exists.
- [ ] Strip internal "(round N)" references from user docs (39 in DATA_GUIDE, 14 in
      SETTINGS_REFERENCE, 3 in FIELD_GUIDE, header of HOW_PHOTO_RESOLUTION_WORKS);
      relabel HOW_PHOTO_RESOLUTION_WORKS as advanced-user (currently "Developer", but it
      is the friendliest explainer in the repo). Doing this BEFORE the first Pages
      deploy pays double: the site publishes the cleaned pages.
- [ ] Short glossary (ROI, model, confidence, track/visit, JSONL) in FIELD_GUIDE or the
      Pages site's landing page; define terms at first use elsewhere.
- [ ] CONTRIBUTING: add non-code contribution paths (bug reports via the in-app problem
      report, field observations, doc fixes); add `CODE_OF_CONDUCT.md`
      (Contributor Covenant).
- [x] `fastlane/metadata/android/en-US/` texts (round 204): `short_description.txt`
      (60 chars, limit 80), `full_description.txt` (2.3 k chars, limit 4000),
      `changelogs/11.txt` (472 chars, limit 500). Written once, they serve the Play
      listing AND the F-Droid/IzzyOnDroid conventions. [ ] Still missing (owner
      assets): `images/icon.png`, `images/featureGraphic.png` (1024x500),
      `images/phoneScreenshots/` (the Phase 2 screenshots).
- [ ] GitHub Actions CI (`flutter analyze` + `flutter test` on push, APK build on tag):
      DEFERRED (owner decision 2026-08-05): the repo sees several pushes a day during
      active development and the owner does not want a build per push. Revisit near
      v1.0; if revived, trigger it on tag pushes (and optionally pull requests) only,
      never on every push to main.

### GitHub Pages recipe (docs site with screenshots and video, no CI involved)

Recommended tooling: **MkDocs with the Material theme** (Python, `pip install`, fits the
owner's toolchain; renders the existing markdown as-is). Publishing is a LOCAL command,
`mkdocs gh-deploy`: it builds the site on the owner's machine and pushes only the built
HTML to a `gh-pages` branch. No GitHub Actions run at all, nothing builds on the daily
development pushes, and the site changes only when the owner deliberately deploys.

One-time setup (owner, ~30 min; Code-agent can prepare steps 2-3 in a round):

1. [ ] `pip install mkdocs-material` (brings mkdocs itself).
2. [ ] Create `mkdocs.yml` at the repo root: `site_name: FaunaPulse`,
       `docs_dir: docs`, `theme: {name: material}`, a `nav:` listing ONLY the
       user-facing pages (a new landing page, FIELD_GUIDE, INSTALL,
       SETTINGS_REFERENCE, DATA_GUIDE, HOW_PHOTO_RESOLUTION_WORKS, PRIVACY_POLICY),
       and `exclude_docs:` globs for the agent/internal docs (AGENT_*, RELEASE_PLAN,
       MODEL_CONVERSION, LEAN_QNN_PACKAGING) so they are not published as pages
       (they stay visible in the repo itself, which is public anyway).
3. [ ] Add `docs/index.md` as the site landing page: two sentences on what the app is,
       an install link, the screenshot strip, the glossary.
4. [ ] Screenshots: commit them under `docs/images/` (PNG, phone-portrait) and
       reference them as `![caption](images/name.png)`; the same files feed fastlane
       and the Play listing later. Keep each under ~500 KB (resize to ~1080 px wide).
5. [ ] Video: host on YouTube (an unlisted video is fine) and link or embed it from
       the page. Never commit video files (repo bloat, GitHub rejects files over
       100 MB, and Zenodo would archive them into every release snapshot).
6. [ ] Preview locally with `mkdocs serve` (http://127.0.0.1:8000, live-reloads on
       edit), then publish with `mkdocs gh-deploy` (creates/updates the `gh-pages`
       branch).
7. [ ] GitHub: Settings > Pages > Source "Deploy from a branch" > branch `gh-pages`,
       folder `/ (root)`. The site appears at
       https://<github-user>.github.io/fauna-pulse/ (requires the repo to be public,
       which Phase 1 step 1 does). Add that URL to the repo's About sidebar and the
       README header.

Update cadence afterwards: edit docs, `mkdocs serve` to check, `mkdocs gh-deploy` to
publish. Nothing happens automatically.

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
      GitHub and Play builds stay cross-updatable. This choice is offered ONCE, when
      the app is created in the Console and before the first AAB upload: App integrity
      > "Choose signing key" > "Use a different key" > "Export and upload a key from
      Java keystore" (Google's PEPK tool wraps the key). If the first AAB is uploaded
      without doing this, Google generates its own key and the channels split forever.
- [x] Build config: `scripts/security_release_gate.sh` ends with a signed
      `flutter build appbundle --release` (AAB, the publishing format Play
      requires; Play generates per-device APKs from it); targetSdk 36 and release
      lint are enforced; the camera
      uses-feature decision is done (round 193: camera required, autofocus not); keep
      `useLegacyPackaging` (the QNN/NPU runtime needs real file paths) and accept the
      size cost. (A lean two-artifact alternative is documented, not implemented, in
      [LEAN_QNN_PACKAGING.md](LEAN_QNN_PACKAGING.md) — review E8, round 171 — with the
      reopen triggers; this bullet's decision stands until one fires.)
- [ ] Store listing: reuse the fastlane texts; feature graphic 1024x500; 2-8 phone
      screenshots (from Phase 2); the 512x512 Play icon is ready (round 193);
      privacy policy URL (the public repo's PRIVACY_POLICY.md); complete the Data
      safety form against the actual settings-only Android backup and the current
      Play Console wording. Draft answers for all of these forms are in
      `docs/PLAY_STORE_LISTING_DRAFT.md` (round 204).
      FaunaPulse itself has no analytics or user-data upload. Declare and justify
      camera, optional location, notifications, and the camera foreground service.
      There is no direct battery-exemption or data-sync permission. Complete the
      content rating questionnaire.
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
  bundled model (validates the Phase 0 build fixes; the bundled MegaDetector model
  does not detect insects specifically, see the open owner question). A fresh clone
  has NO model files (they are git-ignored), so this check needs the listed
  `MDV6-yolov10-c_int8_256.tflite` placed in `assets/models/custom/` first.
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
