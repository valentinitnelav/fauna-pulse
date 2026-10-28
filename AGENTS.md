# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, codex, etc.) 
when working with code in this repository. CLAUDE.md points to this file.
It holds working rules only. Facts about the app (file map, defaults, invariants) live in
`docs/AGENT_CHANGELOG_OVERVIEW.md`, so the two files cannot drift apart.

## Project Overview

This project is an Android field application designed to detect flower-visiting pollinators 
in real time and log every detection with its timestamp to compute visitation rates. 
With swappable detection models and AI-free capture modes (motion-triggered, time-lapse), 
it can monitor the activity of any organism at a fixed spot. 
The app is Dart (Flutter) code on top of native Android code in Kotlin; the models run on the
phone with LiteRT.
The application is built on the Ultralytics YOLO Flutter plugin, using a modified copy (fork) in
`packages/ultralytics_yolo/`; its `FAUNAPULSE_FORK.md` lists what FaunaPulse changed.

## Start of a session

The app sits at the git repository root and paths below are relative to it.

1. Read `docs/AGENT_CHANGELOG_OVERVIEW.md`: what is true now (defaults, file map, key
   invariants, pointers).
2. Read nothing else up front: not `docs/AGENT_CHANGELOG.md` and not the related repositories
   (both below). Open them only when the task needs them.

## Keeping the agent documents current

A **round** is one piece of agent work that changes tracked files; it ends with one commit whose
message starts with "Round <n>:". A session that only answers questions, or changes only files
outside git, has no round, and changes the owner makes by hand need none. The next round number is one more than the last header in
`docs/AGENT_CHANGELOG.md` (`grep '^## Round' docs/AGENT_CHANGELOG.md | tail -1`); when that round
has no commit yet (`git log --grep '^Round <n>:'`), the work may still belong to it.

- `docs/AGENT_CHANGELOG_OVERVIEW.md` holds only what an agent needs before working on the app.
  Keep a line there only if an agent would likely make a mistake without it and could not
  quickly find it where it works: a code comment at that code, `grep`, the feature's doc in
  `docs/`, or git history. Feature details go to those places instead. It says only what is true
  now: when a round changes a rule or where something lives, replace or delete the affected text
  in place (no round numbers, old values or measurements). When the reason for a rule is not
  obvious, give it in one short clause. Keep it under 35,000 characters (`wc -m`).
- `docs/AGENT_CHANGELOG.md` is the very long history. Never read it whole. Ask the owner before
  reading old round entries, and only when past rationale is really needed (search with `grep`,
  read single entries). Each round appends one entry at the end, without reading the file:
  - a header line "## Round xy (yyyy-mm-dd): some short title", for example
    "## Round 76 (2026-07-08): added user-triggered engine benchmark";
  - the round's commit says what changed and the diff shows how, so the entry adds only what
    those do not: what was asked, why (decisions, evidence, rejected options), what was checked,
    and what is open, in about 500 to 1,200 characters. No file lists, no commit message (neither
    a repeat nor a suggestion) and no personal or private information (see *General rules*);
  - an empty line after it, to separate the next entry.

## Related repositories

FaunaPulse is one of several repositories of the same maintainer. The folders named below are
where the maintainer keeps them; a contributor usually has none of them, and the GitHub links are
enough. Do not open them at the start of a session. Open one only when the task touches it (the
"When" of each entry), search before reading whole files, and read its own `AGENTS.md` before
changing anything there.

- [fauna-pulse-models](https://github.com/valentinitnelav/fauna-pulse-models)
  (`~/fauna-pulse-models`): the PC tools that convert and publish the models (detectors,
  classifiers, BioCLIP, `.fpack` name lists). The converted files and their model cards (origin,
  licence, conversion, citation) are on
  [Hugging Face](https://huggingface.co/collections/Valen-Peregrine/faunapulse); this repository
  keeps no copy of the cards. When: a model, a model file format, a name list or the download
  catalogue changes. Its `docs/AGENT_OVERVIEW.md` lists the rules both repositories share.
- [fauna-lapse](https://github.com/valentinitnelav/fauna-lapse) (`~/FaunaLapseApp/fauna-lapse`):
  the sister app (Java, time-lapse photos, no AI). FaunaPulse imports its packed sessions and uses
  the same field-note and phone-state keys. When: the FaunaLapse import, the field notes or the
  phone state change, or an idea is taken from it.
- [fauna-pulse-export](https://github.com/valentinitnelav/fauna-pulse-export)
  (`~/fauna-pulse-export`): PC tools that write FaunaPulse sessions in formats other software
  reads (today for insect-detect-post). Its `session_reader.py` repeats app rules (the device
  name; which photo shows which track ID with which box). When: session records, photo names or
  those rules change.

The maintainer's private repositories are listed outside git, in `~/InsectDetectApp/CLAUDE.md`
(skip this if the file does not exist).

When a task reaches another repository:

- Each file goes into the repository whose job it is and follows that repository's `AGENTS.md`.
- Do not edit another repository from an app session unless the owner asks. When an app change
  breaks a rule that another repository repeats, say so, and write a short hand-off note (what
  changed, why, which files) in that repository's `private/` folder (git-ignored; FaunaLapse:
  `~/FaunaLapseApp/`). Contributors mention it in their pull request instead. Larger work there
  continues in a session opened in that repository.
- When the owner asks for one task in two repositories, check `git status` in both first
  (another session may be working there), and suggest one commit message per repository.
- Docs and code comments refer to another repository by its name or GitHub URL, never by a
  local path.
- Before calling an idea new, search the related repositories for it (code, docs, and their
  `private/` plans).

## General rules

Keep answers concise, but clear and easy to understand. Write plain English with short
sentences and no idioms (the owner and many users are not native speakers). Do not use the em
dash (—) as a punctuation mark; use parentheses (round brackets) instead.

**Code comments** explain why: the reason for a choice, alternatives that failed, side effects,
and what must stay in sync elsewhere. Names and the code itself say what it does. Define mobile,
Android and machine-learning terms in plain words at first use. Write so that a coding agent or a
new contributor understands the code without reading its history.

Less is more: the simplest code solution is the better solution as long as core 
functionality is not lost and as long as the code remains readable for humans too.
Before adding a helper, widget or setting, search the repository and reuse or extend what exists.
Fix a bug in the code that owns the behaviour instead of guarding its symptom somewhere else.

Report checks honestly: say what was verified and how (unit tests, analyzer, which phone model).
Never claim a check that was not run.

**Phones.** Ask the owner before using a connected phone. Before every `flutter run` or
`flutter test integration_test/...` on a phone, first install a debug build yourself with
`adb -s <device-id> install -r` and stop if that is refused: when Flutter's own install is
refused (a different signing key, or MIUI's "Install via USB?" question left unanswered),
Flutter uninstalls the app even with `--no-uninstall`, which deletes every session on the phone.
So never leave a device check running unattended on a phone that may ask that question. Backup
and reinstall steps: *Build and test* in the overview.

Do not place in any git tracked file any private or sensitive data like email addresses,
passwords, any sort of digital keys.
Everything tracked is public (GitHub, and every release is archived on Zenodo), so also keep
out of tracked files: personal details and whereabouts, the names of people whose data or
models are not public yet, models shared privately by colleagues, and where third-party test
material that is not ours to share came from (describe it by what it is, for example "an edited
compilation video"). Phones are named by model, never by serial number (`adb devices -l` lists
both); use placeholders such as `<device-id>` in commands.

Do not read `~/InsectDetectApp/sessions/` (test session outputs, many large text files) unless
the owner asks. Then ask before reading, use keyword searches, and never read a large file whole.

**Git related:**

- Do not perform destructive Git operations without explicit approval.
- Do not git commit or git push changes unless requested by project owner via prompts.
- Never git push to main branch and never force push. 
- Work on `develop`: if the repository is on `main` when you start changing files, switch to
  `develop` first (and do not commit).
- If asked to commit, stage files by name (`git add <path>`), never `git add -A` or `git add .`: model files, logs
  and other local files can sit in the working tree, and binaries never go into git.
- Change the app version in `pubspec.yaml` only when the owner asks (release rounds).
- Commits use the identity in the repository's git config (the GitHub noreply address): never
  pass `--author` or write a private address. Commit messages contain no author or attribution
  lines (no "Co-Authored-By", no tool or person names).
- When files changed, suggest a short, clear commit message that says what the overall edits
  were about. Its first line starts with "Round <counter>" (e.g. "Round 76: added
  user-triggered engine benchmark"), the same counter as the round appended to
  `AGENT_CHANGELOG.md`; after it, a short summary of the changes and why they were needed.

## Credit, copying and the licence

The whole repository is AGPL-3.0, inherited from the Ultralytics plugin, and contributions are
made under it. FaunaPulse is also scientific work, so credit follows academic practice, not only
the licence.

- **Do not plagiarise.** Do not copy large parts of code, or a whole approach, from other
  software. Short snippets from documentation or web answers are fine, and so is code from the
  official docs and sources of this project's own dependencies (Flutter, Android, LiteRT, the
  Ultralytics plugin). Use common sense about where borrowing becomes copying. If a task seems to
  need substantial code or a whole design from another project, stop and tell the owner first.
- **Credit an algorithm where it is implemented.** When code follows a published method (for
  example ByteTrack or C-BIoU), the comment at the top of the file or function names the method,
  its authors, year, venue and a DOI or link, and says how our version differs (simplified,
  other parameters). User docs that describe the method cite it too. Even if an idea is not protected by
  copyright, citing the original source is honest scientific practice.
- **Credit the origin and the implementer separately.** If an idea comes from one source (a
  paper, official documentation) and we followed another project's implementation of it, name
  both and say who contributed what ("idea from X; implementation follows Y"). Use neutral
  wording ("as in Y (Author 2026)"), not possessive ("Author's method"). A statement such as
  "no code copied" must be true.
- **Copied code keeps its notices.** Code copied or closely adapted (after the owner agreed) must
  have a licence compatible with AGPL-3.0: MIT, BSD, Apache-2.0 and GPL-3.0 are; GPL-2.0-only,
  "non-commercial" licences and code with no licence at all (all rights reserved) are not; ask
  the owner when unsure. Keep the original copyright and licence notice, add a comment with the
  source link (with commit or version) and what was changed, and mention it in the round's
  changelog entry.
- **Ultralytics plugin and headers.** Never remove or edit the `Ultralytics 🚀 AGPL-3.0` headers
  in files that came from upstream. The AGPL asks that changes to them are marked:
  `packages/ultralytics_yolo/FAUNAPULSE_FORK.md` does this, so record new plugin changes there.
  New files written for FaunaPulse do not get the Ultralytics header (Ultralytics did not write
  them).
- **Models and data** keep their creators' licences. Their credit (authors, licence, citation)
  lives in the model cards on Hugging Face and in fauna-pulse-models repository, not in this repository.
