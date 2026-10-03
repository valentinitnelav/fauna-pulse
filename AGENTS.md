# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, codex, etc.) 
when working with code in this repository. CLAUDE.md points to this file.

## Project Overview

This project is an Android field application designed to detect flower-visiting pollinators 
in real time and log every detection with its timestamp to compute visitation rates. 
With swappable detection models and AI-free capture modes (motion-triggered, time-lapse), 
it can monitor the activity of any organism at a fixed spot. 
The application is built on the Ultralytics YOLO Flutter plugin, using a modified copy (fork) in
`packages/ultralytics_yolo/`; its `FAUNAPULSE_FORK.md` lists what FaunaPulse changed.

The project owner is a pollination ecologist with statistical proficiency (R/Python) 
but is not a professional mobile developer. Code comments and technical explanations should 
define complex mobile development terms in plain language upon first occurrence.

## Development Environment & Context

The app sits at the git repository root and paths below are relative to it.

**Grounding order at the start of a session:** 

1. Read `docs/AGENT_CHANGELOG_OVERVIEW.md` for a brief snapshot of current defaults, 
    file maps, key invariants and pointers. 
    Keep `AGENT_CHANGELOG_OVERVIEW.md` current when changes alter defaults or invariants.
    It is read at the start of every session, so each entry says only what is true 
    now and where it lives: replace or remove text when it changes instead of adding to it.
    Keep `AGENT_CHANGELOG_OVERVIEW.md` under 75000 characters.
    The history of a change (which round, why) belongs in `AGENT_CHANGELOG.md`.
2. The very long, extra detailed history in `docs/AGENT_CHANGELOG.md` 
    should never be read fully due to its size. 
    Always ask for permission to read round entries if explicit past rationale or a round-by-round 
    change log is absolutely needed. 
    Append summary changes at the end of the file without reading it entirely. 
    Add a header line like this: "## Round xy (yyyy-mm-dd): some short title"
    Example: "## Round 76 (2026-07-08): added user-triggered engine benchmark".
    Each round entry: what was asked, what changed (visible behavior and main files), 
    why (decisions, evidence, rejected options), what was checked, and what is open, 
    in about 1,500–3,000 characters; leave details the git diff shows to the diff.
    Add an empty line that will separate future entries.

## General rules

Keep answers concise, but clear and easy to understand.

Less is more: the simplest code solution is the better solution as long as core 
functionality is not lost and as long as the code remains readable for humans too.

Do not place in any git tracked file any private or sensitive data like email addresses,
passwords, any sort of digital keys.

Do not read without being asked specifically into the folder `~/InsectDetectApp/sessions/`. 
It contains many txt files with test session outputs.
Sometimes for diagnostics, the project owner might ask you to read specific 
files or lines within those files.
If needing to read some of those files at `~/InsectDetectApp/sessions/`,
then ask for permission first and always use keywords search and do not read entire 
large txt files.

Avoid the usage em dash (—) as a punctuation mark, I prefer parentheses (round brackets).

Git related:
- Do not perform destructive Git operations without explicit approval.
- Do not git commit or git push changes unless requested by project owner via prompts.
- Never git push to main branch and never force push. 
- When you implement code changes, and git is on main, then git branch into `develop`,
  but do not git commit the changes.

If code changes happened, then suggest also clear, readable git message.
That message must start with "Round <counter>" (e.g. Round 76) where <counter> 
is the same counter/round id used in the appended summary rounds in `AGENT_CHANGELOG.md` 
(and also matches the counter in the title of the git messages).
After the first line in the git message, you can add a short summary of changes and why 
those were needed.

## Pipeline & Technical Specifications

The app is Dart (Flutter) code on top of native Android code in Kotlin.
Computer vision detection runs on smartphone (on the device) using LiteRT, 
and real-time inference is handled via the YOLOView camera widget. 

### Tracking & Region of Interest (ROI)

* **Tracking:** To calculate accurate visitation rates, a tracker follows each 
detected animal across frames and gives it a track ID: ByteTrack by default, 
C-BIoU selectable (`lib/fauna_pulse/tracking/`).

* **ROI:** To eliminate background noise, a draggable, square (1:1) Region of Interest 
overlay is placed on the camera preview. This square matching also ensures cropping 
eliminates letterbox padding before sending data to the machine learning model.

* **Triggers:** When an organism enters the ROI, the tracking pipeline activates 
and assigns track IDs. Each session is saved in its own folder under the app's 
`files/sessions` folder (reachable over USB): photos (JPEG) or videos, and the session's log.