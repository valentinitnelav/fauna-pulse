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

**Code comments** explain why: the reason for a choice, alternatives that failed, side effects,
and what must stay in sync elsewhere. Names and the code itself say what it does. Define mobile,
Android and machine-learning terms in plain words at first use. Write so that a coding agent or a
new contributor understands the code without reading its history.

## Development Environment & Context

The app sits at the git repository root and paths below are relative to it.
The PC tools that convert and publish models (detectors, classifiers, BioCLIP, `.fpack` name lists)
live in the separate repository [fauna-pulse-models](https://github.com/valentinitnelav/fauna-pulse-models) (usually `~/fauna-pulse-models`);
its `docs/AGENT_OVERVIEW.md` lists the rules both repositories share.
The converted model files and their model cards (origin, licence, conversion, citation) are
published on [Hugging Face](https://huggingface.co/collections/Valen-Peregrine/faunapulse);
this repository keeps no copy of the cards.

**Grounding order at the start of a session:** 

1. Read `docs/AGENT_CHANGELOG_OVERVIEW.md` for a brief snapshot of current defaults, 
    file maps, key invariants and pointers. 
    Keep `AGENT_CHANGELOG_OVERVIEW.md` current when changes alter defaults or invariants.
    It is read at the start of every session, so each entry says only what is true 
    now and where it lives: replace or remove text when it changes instead of adding to it.
    Keep `AGENT_CHANGELOG_OVERVIEW.md` under 75000 characters.
    When a change alters what is true, replace the affected text (no history
    there). When the reason for a choice is not obvious, give it in one short clause
    next to the fact, or in a code comment. The history of a change (which round, why)
    belongs in `AGENT_CHANGELOG.md` and git commit messages (git history).
2. The very long, extra detailed history in `docs/AGENT_CHANGELOG.md` 
    should never be read fully due to its size. 
    Always ask for permission to read round entries if explicit past rationale or a round-by-round 
    change log is absolutely needed. 
    Append a short entry at the end of the file without reading it entirely. 
    The next round number is one more than the last header
    (`grep '^## Round' docs/AGENT_CHANGELOG.md | tail -1`).
    Add a header line like this: "## Round xy (yyyy-mm-dd): some short title"
    Example: "## Round 76 (2026-07-08): added user-triggered engine benchmark".
    The round's commit ("Round xy: ...", found with `git log --grep '^Round xy:'`) says what
    changed and the diff shows how, so the entry adds only what those do not: what was asked,
    why (decisions, evidence, rejected options), what was checked, and what is open,
    in about 500 to 1,200 characters. No file lists and no repeat of the commit message.
    Do not write suggested commit message here.
    Add an empty line that will separate future entries.
    Do not write personal or private information here either (see *General rules*).

## General rules

Keep answers concise, but clear and easy to understand.

Less is more: the simplest code solution is the better solution as long as core 
functionality is not lost and as long as the code remains readable for humans too.
Before adding a helper, widget or setting, search the repository and reuse or extend what exists.
Fix a bug in the code that owns the behaviour instead of guarding its symptom somewhere else.

Report checks honestly: say what was verified and how (unit tests, analyzer, which phone model).
Never claim a check that was not run.

Do not place in any git tracked file any private or sensitive data like email addresses,
passwords, any sort of digital keys.
Everything tracked is public (GitHub, and every release is archived on Zenodo), so also keep
out of tracked files: personal details and whereabouts, the names of people whose data or
models are not public yet, models shared privately by colleagues, and where third-party test
material that is not ours to share came from (describe it by what it is, for example "an edited
compilation video"). Phones are named by model, never by serial number (`adb devices -l` lists
both); use placeholders such as `<device-id>` in commands.

Do not read without being asked specifically into the folder `~/InsectDetectApp/sessions/`. 
It contains many txt files with test session outputs.
Sometimes for diagnostics, the project owner might ask you to read specific 
files or lines within those files.
If needing to read some of those files at `~/InsectDetectApp/sessions/`,
then ask for permission first and always use keywords search and do not read entire 
large txt files.

Avoid the usage em dash (—) as a punctuation mark, I prefer parentheses (round brackets).

**Git related:**

- Do not perform destructive Git operations without explicit approval.
- Do not git commit or git push changes unless requested by project owner via prompts.
- Never git push to main branch and never force push. 
- When you implement code changes, and git is on main, then git branch into `develop`,
  but do not git commit the changes.
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
