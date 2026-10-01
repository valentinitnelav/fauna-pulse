"""Refresh sizes and checksums in assets/model_downloads.json from local files.

FaunaPulse (round 268): the app downloads every model from the links in
assets/model_downloads.json and verifies each download with the SHA-256 written
there. Weights change as the project evolves (re-exports, new versions), so run
this before uploading changed files:

    python tool/model_downloads/update_catalogue.py path/to/file.tflite path/to/list.fpack ...
    python tool/model_downloads/update_catalogue.py --check path/to/*.tflite   # report only

Each file is matched to the catalogue entry with the same file name (a model or
a name list); its "bytes" and "sha256" are rewritten. Files with no matching
entry are reported and left out (add the entry by hand first). Needs only the
Python standard library.
"""

import argparse
import hashlib
import json
import os
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
    for entry in catalogue.get("detectors", []) + catalogue.get("identification", []):
        out[entry["file"]["name"]] = entry["file"]
        for lst in entry.get("lists", []):
            out[lst["file"]["name"]] = lst["file"]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", help="local model files or name lists")
    ap.add_argument("--check", action="store_true", help="report differences, write nothing")
    ap.add_argument("--catalogue", default=CATALOGUE)
    args = ap.parse_args()

    with open(args.catalogue, encoding="utf-8") as f:
        catalogue = json.load(f)
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
        with open(args.catalogue, "w", encoding="utf-8") as f:
            json.dump(catalogue, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print(f"wrote {args.catalogue}")
    return 1 if (args.check and changed) else 0


if __name__ == "__main__":
    sys.exit(main())
