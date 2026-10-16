"""Refresh sizes and checksums in assets/model_downloads.json from local files.

FaunaPulse (round 268): the app downloads every model from the links in
assets/model_downloads.json and verifies each download with the SHA-256 written
there. Weights change as the project evolves (re-exports, new versions), so run
this before uploading changed files:

    python tool/model_downloads/update_catalogue.py path/to/file.tflite path/to/list.fpack ...
    python tool/model_downloads/update_catalogue.py --check path/to/*.tflite   # report only
    python tool/model_downloads/update_catalogue.py --names path/to/out/*      # naming rule only

Each file is matched to the catalogue entry with the same file name (a model or
a name list); its "bytes" and "sha256" are rewritten. Files with no matching
entry are reported and left out (add the entry by hand first).

Round 276: --names checks file names against the naming rule (README.md) and
reports the files that do not follow it, or whose <model> part is not an "id"
in the list (their details would show as "not known" in the app). Entries
without a "file" (known models that are not offered) are fine. Needs only the
Python standard library.

Round 312: --urls takes the pinned Hugging Face links that fauna-pulse-models
writes after an upload (its publish/published.json):

    python tool/model_downloads/update_catalogue.py --urls ~/fauna-pulse-models/publish/published.json
    python tool/model_downloads/update_catalogue.py --urls ... --check   # report only

Each published model file or name list is matched to its catalogue file by
SHA-256 (the same bytes published under a new name), else by its old name
("catalogue_name"); the catalogue file then takes the published name, link,
size and checksum, and the "uses" suggestions follow a renamed name list. A
published file with no match goes to the entry of its <model> part when that
entry offers no file yet (a new detector), or replaces a classifier's class
list (rebuilt under the new name, so other bytes). Anything else is reported
(add it by hand). Manifests (.json) and LICENSE files are not app downloads.
"""

import argparse
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CATALOGUE = os.path.normpath(os.path.join(HERE, "..", "..", "assets", "model_downloads.json"))


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_entries(catalogue):
    """Every {"name", "bytes", "sha256"} dict in the catalogue, by file name."""
    out = {}
    for entry in catalogue.get("models", []):
        if "file" in entry:
            out[entry["file"]["name"]] = entry["file"]
        for lst in entry.get("name_lists", []):
            out[lst["file"]["name"]] = lst["file"]
    return out


# The naming rule (README.md, round 276): <model>_<input px>_<precision>[_<extra>].<ext>, a label
# pack <model>_<list>_v<n>.fpack. <model>: lower-case words joined by "-", a dot only inside a
# version number (bioclip-2.5).
MODEL_ID = r"[a-z0-9]+(?:-[a-z0-9]+|\.[0-9]+)*"
MODEL_FILE = re.compile(rf"^(?P<id>{MODEL_ID})_[0-9]{{2,4}}_(?:int8|w8a32|fp16|fp32)(?:_[a-z0-9]+)?\.(?:tflite|fpack|onnx)$")
LABEL_PACK = re.compile(rf"^(?P<id>{MODEL_ID})_[a-z0-9]+(?:-[a-z0-9]+)*_v[0-9]+\.fpack$")
MAX_STEM = 40


def name_problem(name, ids):
    """Why [name] does not follow the naming rule, or None."""
    m = MODEL_FILE.match(name) or LABEL_PACK.match(name)
    if m is None:
        return "does not follow <model>_<input px>_<precision> (or <model>_<list>_v<n>.fpack)"
    if len(os.path.splitext(name)[0]) > MAX_STEM:
        return f"longer than {MAX_STEM} characters"
    if m.group("id") not in ids:
        return f"model '{m.group('id')}' is not an id in the list (the app would show 'not known')"
    return None


def check_names(catalogue, paths):
    ids = {e["id"] for e in catalogue.get("models", [])}
    bad = 0
    for path in paths:
        name = os.path.basename(path)
        problem = name_problem(name, ids)
        if problem:
            bad += 1
            print(f"{name}: {problem}")
        else:
            print(f"ok: {name}")
    print(f"{bad} of {len(paths)} names to change")
    return 1 if bad else 0


# A pinned Hugging Face link: one commit, never a branch ("main" can change) or a /blob/ page.
PINNED_URL = re.compile(r"^https://huggingface\.co/[^/]+/[^/]+/resolve/[0-9a-f]{40}/(?P<name>[^/]+)$")
APP_FILE = (".tflite", ".fpack", ".onnx")


def attach_unmatched(catalogue, name):
    """The catalogue file dict a published file without a match takes, or None (add by hand)."""
    m = MODEL_FILE.match(name)
    entry = next((e for e in catalogue.get("models", []) if m and e["id"] == m.group("id")), None)
    if entry is None:
        return None
    if name.endswith(".tflite") and "file" not in entry:
        entry["file"] = {}
        return entry["file"]
    class_lists = [lst for lst in entry.get("name_lists", []) if lst.get("kind") == "class_list"]
    if name.endswith(".fpack") and len(class_lists) == 1:
        return class_lists[0]["file"]
    return None


def apply_published(catalogue, published):
    """Takes names and pinned links from published.json; returns (changes, renames, problems)."""
    by_name = file_entries(catalogue)
    by_sha = {f["sha256"]: f for f in by_name.values() if f.get("sha256")}
    changes, renames, problems = [], {}, []
    for repo, repo_entry in published.items():
        for name, pub in repo_entry["files"].items():
            if not name.endswith(APP_FILE):
                continue
            url = PINNED_URL.match(pub.get("url", ""))
            if url is None or url.group("name") != name:
                problems.append(f"{repo}/{name}: not a pinned link (https://huggingface.co/<owner>/<repo>/resolve/<commit>/{name})")
                continue
            target = by_sha.get(pub["sha256"]) or by_name.get(pub.get("catalogue_name", name))
            if target is None:
                target = attach_unmatched(catalogue, name)
            if target is None:
                problems.append(f"{repo}/{name}: not in the catalogue (add the entry by hand, then run again)")
                continue
            new = {"name": name, "url": pub["url"], "bytes": pub["bytes"], "sha256": pub["sha256"]}
            if all(target.get(k) == v for k, v in new.items()):
                continue
            old = target.get("name")
            if old and old != name:
                renames[old] = name
            changes.append(f"{old or '(new)'} -> {name}" if old != name else f"{name}: link, size or checksum")
            target.update(new)
    for use in catalogue.get("uses", []):
        for suggestion in use.get("name", []):
            if suggestion.get("list") in renames:
                suggestion["list"] = renames[suggestion["list"]]
    return changes, renames, problems


def take_published(catalogue, path, check):
    with open(path, encoding="utf-8") as f:
        published = json.load(f)
    changes, renames, problems = apply_published(catalogue, published)
    for line in changes:
        print(f"{'differs' if check else 'updated'}: {line}")
    for line in problems:
        print(f"PROBLEM: {line}")
    if renames:
        print("\nRenamed files: tests, integration checks and docs that name the old files need the new names:")
        for old, new in renames.items():
            print(f"  {old} -> {new}")
    if not changes:
        print("nothing to change")
    return changes, problems


def write_catalogue(catalogue, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(catalogue, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help="local model files or name lists")
    ap.add_argument("--check", action="store_true", help="report differences, write nothing")
    ap.add_argument("--names", action="store_true", help="only check the names against the naming rule")
    ap.add_argument("--urls", metavar="PUBLISHED_JSON",
                    help="take names and pinned links from fauna-pulse-models' publish/published.json")
    ap.add_argument("--catalogue", default=CATALOGUE)
    args = ap.parse_args()
    if not args.files and not args.urls:
        ap.error("give model files, or --urls PUBLISHED_JSON")

    with open(args.catalogue, encoding="utf-8") as f:
        catalogue = json.load(f)
    if args.names:
        return check_names(catalogue, args.files)
    if args.urls:
        changes, problems = take_published(catalogue, args.urls, args.check)
        if changes and not args.check:
            write_catalogue(catalogue, args.catalogue)
        return 1 if problems or (args.check and changes) else 0
    entries = file_entries(catalogue)
    changed = 0
    for path in args.files:
        name = os.path.basename(path)
        entry = entries.get(name)
        if entry is None:
            print(f"not in the catalogue (add it by hand first): {name}")
            continue
        size, digest = os.path.getsize(path), sha256_of(path)
        if entry.get("bytes") == size and entry.get("sha256") == digest:
            print(f"unchanged: {name}")
            continue
        print(f"{'differs' if args.check else 'updated'}: {name} ({entry.get('bytes')} -> {size} bytes)")
        entry["bytes"], entry["sha256"] = size, digest
        changed += 1
    if changed and not args.check:
        write_catalogue(catalogue, args.catalogue)
    return 1 if (args.check and changed) else 0


if __name__ == "__main__":
    sys.exit(main())
