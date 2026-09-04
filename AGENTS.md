# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, codex, etc.) 
when working with code in this repository. CLAUDE.md points to this file.

## Project Overview

This project is an Android field application designed to detect flower-visiting pollinators 
in real time and log every detection with its timestamp to compute visitation rates. 
With swappable detection models and AI-free capture modes (motion-triggered, time-lapse), 
it can monitor the activity of any organism at a fixed spot. 
The application is built on top of the official Ultralytics YOLO Flutter plugin.

The project owner is a pollination ecologist with statistical proficiency (R/Python) 
but is not a professional mobile developer. Code comments and technical explanations should 
define complex mobile development terms in plain language upon first occurrence.

## Development Environment & Context

The core application code resides in the `./fauna-pulse/` subdirectory of the repository root.

Notes:
On 2026-07-14 I have renamed the entire app and github repository. Pollinator Monitor became FaunaPulse.
On 2026-07-13 I have renamed POLLINATOR_MONITOR.md to AGENT_CHANGELOG.md, and POLLINATOR_OVERVIEW.md to AGENT_CHANGELOG_OVERVIEW.md

**Grounding order at the start of a session:** 

1. Read `./fauna-pulse/docs/AGENT_CHANGELOG_OVERVIEW.md` for a brief snapshot of current defaults, file maps, key invariants and pointers. 
    Keep `AGENT_CHANGELOG_OVERVIEW.md` current when changes alter defaults or invariants. 
    Keep it short, as it acts as an overview for the coding agent (e.g. Claude Code, codex). 
    In order to keep it short, can modify in place, even remove text if it is no longer relevant for the development of the app.
2. The very long, full, extra detailed history in `./fauna-pulse/docs/AGENT_CHANGELOG.md` should be read only 
    if explicit past rationale or a round-by-round change log is absolutely requested. 
    Also append it so that the full history is being tracked. 
    No need to consume many tokens on reading it when updating history, just append
    / add summary of changes & implementations at the end of the file.
    For example add a header line like this "## Round xy (yyyy-mm-dd): short title"
    example: "## Round 76 (2026-07-08): user-triggered engine benchmark".
    then add the summary text, bullet points, etc. that is useful for future developers, myself and coding agents,
    then add an empty line that will separate future entries.

### Pointers

**Release plan:** `./fauna-pulse/docs/RELEASE_PLAN.md` — phased checklist for the first public
  release. Re-ground THERE for any release/distribution work; tick items as rounds land.
  Do not place there any private data like email addresses.

## General rules

Keep answers concise, but clear and easy to understand.

Less is more: the simplest code solution is the better solution as long as core functionality is not lost
and as long as the code remains readable for humans too.

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

## Initial Pipeline & Technical Specifications

The development foundation relies on a clone of the Flutter-based `yolo-flutter-app` repository, 
executing Dart application code over native Kotlin or Swift code. 
Computer vision detection runs on smartphone (on the device) using LiteRT, 
and real-time inference is handled via the YOLOView camera widget. 

### Tracking & Region of Interest (ROI)

* **Tracking:** To calculate accurate visitation rates, an object tracking system (such as ByteTrack) should process streaming outputs from the detector.
* **ROI:** To eliminate background noise, a draggable, square (1:1) Region of Interest overlay is placed on the camera preview. 
This square matching also ensures cropping eliminates letterbox padding before sending data to the machine learning model.
* **Triggers:** When an insect enters the ROI, the tracking pipeline activates. 
Unique tracking IDs are assigned, and visual content is saved as JPEGs to a user-specified directory.