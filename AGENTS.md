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

1. Read `docs/AGENT_CHANGELOG_OVERVIEW.md` for a brief snapshot of current defaults, file maps, key invariants and pointers. 
    Keep `AGENT_CHANGELOG_OVERVIEW.md` current when changes alter defaults or invariants.
    It is read at the start of every session, so each entry says only what is true 
    now and where it lives: replace or remove text when it changes instead of adding to it.
    Keep `AGENT_CHANGELOG_OVERVIEW.md` under 75000 characters.
    The history of a change (which round, why) belongs in `AGENT_CHANGELOG.md`.
2. The very long, extra detailed history in `docs/AGENT_CHANGELOG.md` 
    should never be read fully due to its size and therefore wasting tokens. Always ask for permission to read it 
    if explicit past rationale or a round-by-round change log is absolutely needed. 
    Just append summary changes to it without reading it entirely so that the full history is being tracked. 
    No need to consume many tokens on reading it when updating history, just append
    / add summary of changes and implementations at the end of the file.
    For example add a header line like this "## Round xy (yyyy-mm-dd): some short title"
    example: "## Round 76 (2026-07-08): added user-triggered engine benchmark".
    then add the summary text, bullet points, etc. that is useful for future developers, myself and coding agents,
    then add an empty line that will separate future entries.

## General rules

Keep answers concise, but clear and easy to understand.

Less is more: the simplest code solution is the better solution as long as core functionality is not lost
and as long as the code remains readable for humans too.

Do not place in any git tracked file any private or sensitive data like email addresses, passwords, any sort of digital keys.

Do not read without being asked specifically into the folder `~/InsectDetectApp/sessions/`. 
This folder contains a lot of txt files with session outputs, and it will consume a lot of tokens.
Sometimes for diagnostics, the project owner might ask you to read specific files or lines within those files.
If you ever decide by yourself that reading into some of these files, then ask for permission first and
always use keywords search and do not read entire large txt files as some of them can have tens of thousands of lines.

Git related:
- Do not perform destructive Git operations without explicit approval.
- Do not git commit or git push changes unless requested by project owner via prompts.
- Never git push to main branch and never force push. 
- When you implement code changes, and git is on main, then git brach into `develop`, but do not git commit the changes.

If code changes happened, then suggest also clear, readable git message.
That message must start with "Round <counter>" (e.g. Round 76) where <counter> 
is the same counter/round id used in the appended summary rounds in `AGENT_CHANGELOG.md` 
(and also matches the counter in the title of the git messages).
After the first line in the git message, you can add a short summary of cahnges and why 
those were needed.
Avoid the usage em dash (—) as a punctuation mark, I prefer parentheses (round brackets).

## Pipeline & Technical Specifications

The development foundation relies on a clone of the Flutter-based `yolo-flutter-app` repository, 
executing Dart application code over native Kotlin or Swift code. 
Computer vision detection runs on smartphone (on the device) using LiteRT, 
and real-time inference is handled via the YOLOView camera widget. 

### Tracking & Region of Interest (ROI)

* **Tracking:** To calculate accurate visitation rates, a tracker follows each detected animal across frames and gives it a track ID: ByteTrack by default, C-BIoU selectable (`lib/fauna_pulse/tracking/`).
* **ROI:** To eliminate background noise, a draggable, square (1:1) Region of Interest overlay is placed on the camera preview. 
This square matching also ensures cropping eliminates letterbox padding before sending data to the machine learning model.
* **Triggers:** When an organism enters the ROI, the tracking pipeline activates and assigns track IDs.
Each session is saved in its own folder under the app's `files/sessions` folder (reachable over USB):
photos (JPEG) or videos, and the session's log.