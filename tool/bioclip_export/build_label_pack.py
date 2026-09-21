#!/usr/bin/env python3
"""Build a FaunaPulse label pack (.fpack) from the TreeOfLife text embeddings.

In plain words: BioCLIP identifies a crop by comparing its image embedding with one
pre-computed text embedding per candidate name. The Imageomics team publishes those
name embeddings for every species in TreeOfLife (2.66 GB for BioCLIP 2). This script
downloads them once, keeps only the rows you ask for (e.g. class Insecta + Arachnida,
optionally restricted to a species list such as a GBIF country list), adds a few
"none of these" rows (flower, leaf, shadow, ...) so false detections are not forced
onto an insect name, and writes ONE .fpack file the app imports.

Examples:
    # Insecta + Arachnida worldwide for BioCLIP 2 (about 280k rows, ~430 MB at f16):
    python build_label_pack.py --model bioclip-2 --classes Insecta,Arachnida --out ./out

    # Same, restricted to a species list (one column 'species', "Genus epithet"):
    python build_label_pack.py --model bioclip-2 --classes Insecta,Arachnida \
        --species-csv species_DE.csv --pack-id bioclip2_insecta_arachnida_DE --out ./out

    # Only some orders (small pack for a first phone test):
    python build_label_pack.py --model bioclip-2 --orders Diptera,Hymenoptera,Coleoptera,Lepidoptera --out ./out

Sink rows need the text tower (torch + open_clip). Pass --no-sink to skip them (not
recommended for real use: every crop then gets an insect name, even a leaf).
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from datetime import date
from pathlib import Path

import numpy as np

from fpack import RANKS, sink_label, write_fpack

EMBEDDINGS = {
    # model key -> (HF dataset repo, npy file, json file)
    "bioclip-2": ("imageomics/TreeOfLife-200M", "embeddings/txt_emb_species.npy", "embeddings/txt_emb_species.json"),
    "bioclip-2.5": ("imageomics/TreeOfLife-200M", "embeddings/txt_emb_bioclip-2.5-vith14.npy",
                    "embeddings/txt_emb_bioclip-2.5-vith14.json"),
    "bioclip-1": ("imageomics/TreeOfLife-10M", "embeddings/txt_emb_species.npy", "embeddings/txt_emb_species.json"),
}
MODEL_HUB = {
    "bioclip-2": "hf-hub:imageomics/bioclip-2",
    "bioclip-2.5": "hf-hub:imageomics/bioclip-2.5-vith14",
    "bioclip-1": "hf-hub:imageomics/bioclip",
}
# "None of these" candidates: (key, prompt), per kind of detector/scene.
# Explicit "background" classes are common practice in image classification; a
# precedent for insect crops is the none_bg / none_dirt / none_shadow / none_bird
# classes of the Insect Detect classification dataset (Sittinger, Uhler & Pink 2023,
# Zenodo 10.5281/zenodo.8325384). BioCLIP and pybioclip have no such rows; embedding
# negative prompts with the text tower next to the TreeOfLife names is FaunaPulse's
# own use of the model. "arthropod" = flower-scene false positives, "mammal" =
# camera-trap false positives of a MegaDetector "animal" box.
SINK_SETS = {
    "arthropod": [
        ("flower", "a photo of a flower."),
        ("leaf", "a photo of a leaf."),
        ("shadow", "a photo of a shadow on a flower."),
        ("debris", "a photo of dirt or debris."),
        ("blurry", "a blurry photo with no animal."),
        ("web", "a photo of a spider web."),
    ],
    "mammal": [
        ("vegetation", "a photo of vegetation with no animal."),
        ("ground", "a photo of bare ground, rocks or a path with no animal."),
        ("person", "a photo of a person."),
        ("vehicle", "a photo of a vehicle."),
        ("shadow", "a photo of a shadow or a dark blurry shape."),
        ("blurry", "a blurry photo with no animal."),
    ],
    "none": [],
}
SINK_PROMPTS = SINK_SETS["arthropod"]


def load_tol(model_key: str, cache_dir: Path | None):
    """Download (once) and open the TreeOfLife embeddings for [model_key]."""
    from huggingface_hub import hf_hub_download

    repo, npy_name, json_name = EMBEDDINGS[model_key]
    kw = {"repo_id": repo, "repo_type": "dataset"}
    if cache_dir is not None:
        kw["cache_dir"] = str(cache_dir)
    npy_path = hf_hub_download(filename=npy_name, **kw)
    json_path = hf_hub_download(filename=json_name, **kw)
    emb = np.load(npy_path, mmap_mode="r")  # [dim, N] in pybioclip's layout
    with open(json_path, encoding="utf-8") as f:
        names = json.load(f)
    return emb, names


def row_taxonomy(entry) -> list[str]:
    """One TreeOfLife json entry -> [kingdom..species epithet, common name].

    pybioclip documents entries as [scientific_names(list of 7), common_name]; older
    dumps used flat lists. Handle both.
    """
    if isinstance(entry, (list, tuple)) and len(entry) == 2 and isinstance(entry[0], (list, tuple)):
        sci, common = list(entry[0]), entry[1]
    elif isinstance(entry, (list, tuple)) and len(entry) >= 7:
        sci, common = list(entry[:7]), (entry[7] if len(entry) > 7 else "")
    elif isinstance(entry, dict):
        sci = [entry.get(r, "") for r in RANKS]
        common = entry.get("common_name", "")
    else:
        raise ValueError(f"unexpected TreeOfLife entry: {entry!r}")
    sci = [("" if s is None else str(s)) for s in sci][:7]
    while len(sci) < 7:
        sci.append("")
    return sci + [("" if common is None else str(common))]


def sink_embeddings(model_key: str, prompts: list[str]) -> np.ndarray:
    """Embed the negative prompts with the model's text tower (unit vectors)."""
    import torch
    import open_clip

    model, _, _ = open_clip.create_model_and_transforms(MODEL_HUB[model_key])
    tokenizer = open_clip.get_tokenizer(MODEL_HUB[model_key])
    model.eval()
    with torch.no_grad():
        t = model.encode_text(tokenizer(prompts))
        t = torch.nn.functional.normalize(t, dim=-1)
    return t.cpu().numpy().astype(np.float32), float(model.logit_scale.exp().item())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", choices=sorted(EMBEDDINGS), default="bioclip-2")
    ap.add_argument("--classes", default="Insecta,Arachnida", help="comma list of class names to keep ('' = all)")
    ap.add_argument("--orders", default="", help="comma list of order names to keep (optional, narrows further)")
    ap.add_argument("--families", default="", help="comma list of family names to keep (optional, narrows further)")
    ap.add_argument("--species-csv", type=Path, default=None,
                    help="CSV with a 'species' column ('Genus epithet'); keeps only those rows")
    ap.add_argument("--pack-id", default=None, help="identifier stored in the pack (default derived)")
    ap.add_argument("--dtype", choices=["f16", "f32"], default="f16")
    ap.add_argument("--no-sink", action="store_true", help="skip the 'none of these' rows")
    ap.add_argument("--sink-set", choices=sorted(SINK_SETS), default="arthropod",
                    help="which 'none of these' prompts to embed (arthropod: flower scenes; mammal: camera-trap scenes)")
    ap.add_argument("--logit-scale", type=float, default=None,
                    help="override (normally read from the model when sink rows are built; 100 otherwise)")
    ap.add_argument("--cache-dir", type=Path, default=None, help="Hugging Face download cache folder")
    ap.add_argument("--out", type=Path, default=Path("out"))
    args = ap.parse_args()

    emb, names = load_tol(args.model, args.cache_dir)
    dim, n = emb.shape if emb.shape[0] < emb.shape[1] else (emb.shape[1], emb.shape[0])
    transposed = emb.shape[0] == dim and emb.shape[0] < emb.shape[1]
    print(f"TreeOfLife embeddings: {n} rows, dim {dim} (layout {'[dim, N]' if transposed else '[N, dim]'})")
    if len(names) != n:
        print(f"WARNING: json has {len(names)} entries but the matrix has {n} columns", file=sys.stderr)

    keep_classes = {c.strip() for c in args.classes.split(",") if c.strip()}
    keep_orders = {o.strip() for o in args.orders.split(",") if o.strip()}
    keep_families = {f.strip() for f in args.families.split(",") if f.strip()}
    keep_species = None
    if args.species_csv is not None:
        with open(args.species_csv, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            col = "species" if "species" in reader.fieldnames else reader.fieldnames[0]
            keep_species = {row[col].strip() for row in reader if row.get(col)}
        print(f"species list: {len(keep_species)} names from {args.species_csv}")

    labels: list[list[str]] = []
    idx: list[int] = []
    for i in range(min(n, len(names))):
        tax = row_taxonomy(names[i])
        if keep_classes and tax[2] not in keep_classes:
            continue
        if keep_orders and tax[3] not in keep_orders:
            continue
        if keep_families and tax[4] not in keep_families:
            continue
        if keep_species is not None and f"{tax[5]} {tax[6]}".strip() not in keep_species:
            continue
        labels.append(tax)
        idx.append(i)
    if not idx:
        print("No rows matched the filters.", file=sys.stderr)
        return 2
    print(f"kept {len(idx)} species rows")

    idx_arr = np.asarray(idx)
    mat = (emb[:, idx_arr].T if transposed else emb[idx_arr, :]).astype(np.float32)

    logit_scale = args.logit_scale
    sink_rows = 0
    sink_prompts = [] if args.no_sink else SINK_SETS[args.sink_set]
    if sink_prompts:
        sink, model_scale = sink_embeddings(args.model, [p for _, p in sink_prompts])
        mat = np.concatenate([mat, sink], axis=0)
        labels += [sink_label(k, p) for k, p in sink_prompts]
        sink_rows = len(sink_prompts)
        if logit_scale is None:
            logit_scale = model_scale
    if logit_scale is None:
        logit_scale = 100.0

    pack_id = args.pack_id or "_".join(
        [args.model.replace(".", ""), "_".join(sorted(keep_classes)) or "all",
         *(["_".join(sorted(keep_orders))] if keep_orders else []),
         *([f"{len(keep_families)}families"] if keep_families else []),
         *([args.species_csv.stem] if args.species_csv else [])]
    )
    header = {
        "pack_id": pack_id,
        "model_id": args.model,
        "logit_scale": float(logit_scale),
        "temperature": 1.0,
        "ranks": RANKS,
        "sink_rows": sink_rows,
        "sink_set": None if not sink_prompts else args.sink_set,
        "labels": labels,
        "source": {
            "embeddings_repo": EMBEDDINGS[args.model][0],
            "embeddings_file": EMBEDDINGS[args.model][1],
            "classes": sorted(keep_classes), "orders": sorted(keep_orders),
            "families": sorted(keep_families),
            "species_csv": str(args.species_csv) if args.species_csv else None,
        },
        "built_with": {"script": "build_label_pack.py", "date": date.today().isoformat()},
        "license": "TreeOfLife embeddings CC0-1.0; sink rows generated with the MIT BioCLIP text tower",
    }
    args.out.mkdir(parents=True, exist_ok=True)
    out_path = args.out / f"{pack_id}.fpack"
    write_fpack(out_path, header, mat, dtype=args.dtype)
    print(f"Pack written: {out_path} ({out_path.stat().st_size / 1e6:.1f} MB, {len(labels)} rows incl. {sink_rows} sink rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
