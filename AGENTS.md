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

Code comments and technical explanations should 
define complex mobile development terms in plain language upon first occurrence.

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
    Append short summary changes at the end of the file without reading it entirely. 
    The next round number is one more than the last header
    (`grep '^## Round' docs/AGENT_CHANGELOG.md | tail -1`).
    Add a header line like this: "## Round xy (yyyy-mm-dd): some short title"
    Example: "## Round 76 (2026-07-08): added user-triggered engine benchmark".
    Each round entry (briefly): what was asked, what changed (visible behavior and main files), 
    why (decisions, evidence, rejected options), what was checked, and what is open, 
    in about 1,500–2,000 characters; leave details the git diff shows to the diff.
    Do not write suggested commit message here.
    Add an empty line that will separate future entries.
    Do not write personal or private information here either (see *General rules*).

## General rules

Keep answers concise, but clear and easy to understand.

Less is more: the simplest code solution is the better solution as long as core 
functionality is not lost and as long as the code remains readable for humans too.

Do not place in any git tracked file any private or sensitive data like email addresses,
passwords, any sort of digital keys.
Everything tracked is public (GitHub, and every release is archived on Zenodo), so also keep
out of tracked files: personal details and whereabouts, the names of people whose data or
models are not public yet, models shared privately by colleagues, and where third-party test
material that is not ours to share came from (describe it by what it is, for example "an edited
compilation video").

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
- Commits use the identity in the repository's git config (the GitHub noreply address): never
  pass `--author` or write a private address. Commit messages contain no author or attribution
  lines (no "Co-Authored-By", no tool or person names).
- When files changed, suggest a short, clear commit message that says what the overall edits
  were about. Its first line starts with "Round <counter>" (e.g. "Round 76: added
  user-triggered engine benchmark"), the same counter as the round appended to
  `AGENT_CHANGELOG.md`; after it, a short summary of the changes and why they were needed.
