#!/usr/bin/env python3
"""Put the insectDCT hierarchical classifier (insectdct-cls-v7) on the phone: export and check.

insectDCT's classifier (Bjerge et al. 2026) names a crop at three levels at once: level 1 (19
groups, e.g. Hymenoptera_bees), level 2 (41, mostly families) and level 3 (104: species, genera
and coarser leftovers such as "Coleoptera" = other beetles). It is one network (ConvNeXt-Base,
EfficientNetV2-S or ResNet50; the V7 download holds all three) with three output layers ("heads"),
one per level.

This script
  1. builds the network with insectDCT's own code (the `upstream/` folder of the InsectAI Model
     Zoo download, GPL-3.0, used where it is and never copied into this repository) and loads the
     V7 weights;
  2. writes a phone file (.tflite): input = one 224 x 224 RGB crop in 0..1 (insectDCT applies no
     further colour normalisation), output = the 164 raw scores of the three heads one after the
     other (19 + 41 + 104); fp16 weights by default; plus a .json manifest;
  3. with --check-images: classifies every picture with insectDCT's own decision code
     (makePrediction, called the way the InsectAI Model Zoo calls it) twice, with the original
     network and with the phone file in its place, and prints both answers next to two candidate
     rules for FaunaPulse (README section 4);
  4. with --draft-taxa: writes the table that links every level-3 class to kingdom ... species,
     looked up in the TreeOfLife names that BioCLIP uses, plus a short hand-made list for names
     that are not taxa (e.g. "Apoidea small", "Vegetation"). Review the table before using it.

Usage (environment: README section 1):
    python export_insectdct_cls.py --zoo-dir /path/to/weights/insectdct-cls-v7 --backbone cnb \
        --check-images ~/InsectDetectApp/test_videos/crops_bumblebees_720p_square
    python export_insectdct_cls.py --zoo-dir ... --draft-taxa /path/to/txt_emb_bioclip-2.5-vith14.json
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import csv
import hashlib
import io
import json
import pickle
import sys
import time
from collections import Counter
from datetime import date
from pathlib import Path
from types import SimpleNamespace

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bioclip_export"))  # export_tflite, quantise_tflite, fpack
from fpack import class_probabilities, sink_label, write_class_list  # noqa: E402

# backbone key -> (file tag in the V7 download, insectDCT's model name)
BACKBONES = {"cnb": ("CNB", "ConvNextBase"), "eff2s": ("EFF2S", "EfficientNetV2S"), "res": ("RES", "ResNet50")}
CROP = 224          # V7 was trained on 224 x 224 crops (the zoo's insectdct_cls.py)
RANKS = ["kingdom", "phylum", "class", "order", "family", "genus", "species"]
TAU = 0.6           # FaunaPulse's default: a rank counts as identified at 60 % or more
DEFAULT_TAXA = HERE / "taxa" / "insectdct-cls-v7.csv"
APP_SINK = "none"   # kingdom of a "no organism" row in FaunaPulse label packs

# insectDCT class names that are not plain taxon names: (name to look up, its rank, note).
# None = not an organism (FaunaPulse's "no organism" rows). The rest are looked up as written,
# after removing the suffix "_fw", which insectDCT uses for a separate class of the same taxon.
NOT_TAXA = {
    "Aranaea": ("Araneae", "order", ""),
    "Birds": ("Aves", "class", ""),
    "Formidicidae": ("Formicidae", "family", ""),
    "Hesperidae": ("Hesperiidae", "family", ""),
    "Milipedes": ("Diplopoda", "class", ""),
    "Moths": ("Lepidoptera", "order", "moths"),
    "Slugs": ("Gastropoda", "class", "slugs"),
    "Snails": ("Gastropoda", "class", "snails"),
    "Larvae": ("Insecta", "class", "larvae"),
    "Herpetofauna": ("Chordata", "phylum", "reptiles and amphibians"),
    "Fritillaries": ("Nymphalidae", "family", "fritillaries (several genera)"),
    "Satyrinae_fw": ("Nymphalidae", "family", "subfamily Satyrinae (no rank for it here)"),
    "Hymenoptera_bees": ("Hymenoptera", "order", "bees"),
    "Apoidea": ("Hymenoptera", "order", "bees (superfamily Apoidea; no rank for it here)"),
    "Apoidea red_abdomen": ("Hymenoptera", "order", "bees with a red abdomen"),
    "Apoidea reddish": ("Hymenoptera", "order", "reddish bees"),
    "Apoidea small": ("Hymenoptera", "order", "small bees"),
    "Apoidea striped": ("Hymenoptera", "order", "striped bees"),
    "Sphaerophoria scripta-complex": ("Sphaerophoria", "genus", "Sphaerophoria scripta complex"),
    "Vegetation": None,
}


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def v7_files(zoo_dir: Path, tag: str) -> dict[str, Path]:
    names = {"weights": f"HierarchicalClassifier_{tag}_V7.pth", "labels": f"HierarchicalLabels3L_{tag}_V7.pkl",
             "thresholds": f"HierarchicalThresholds3S_{tag}_V7.csv"}
    files = {}
    for k, n in names.items():
        hits = sorted(zoo_dir.rglob(n))
        if not hits:
            raise SystemExit(f"{n} not found under {zoo_dir} (unzip HierarchicalClassifierV7.zip there)")
        files[k] = hits[0]
    return files


def load_labels(path: Path):
    """(level-2 parents of level 1, level-3 parents of level 2, class names per level)."""
    with open(path, "rb") as f:
        _, h1, h2, l1, l2, l3, *_ = pickle.load(f)
    return h1, h2, [l1, l2, l3]


def load_upstream(zoo_dir: Path, key: str):
    """insectDCT's own classifier object with the V7 weights of backbone [key], on the CPU."""
    tag, model_name = BACKBONES[key]
    upstream = zoo_dir / "upstream"
    if not (upstream / "common" / "hierarchical_classifier.py").exists():
        raise SystemExit(f"insectDCT's code is missing in {upstream} (the zoo downloads it next to the weights)")
    sys.path.insert(0, str(upstream))
    import torchvision.models as tvm

    import common.convNext as m_cnb
    import common.efficientNet as m_eff
    import common.resnet50tf as m_res
    # insectDCT's code first loads ImageNet weights (a download of up to 350 MB) that the V7
    # weights replace anyway; build the bare networks instead (the zoo's wrapper does the same).
    m_cnb.convnext_base = lambda weights=None: tvm.convnext_base(weights=None)
    m_eff.efficientnet_v2_s = lambda weights=None: tvm.efficientnet_v2_s(weights=None)
    m_res.models = SimpleNamespace(resnet50=lambda weights=None: tvm.resnet50(weights=None))
    from common.hierarchical_classifier import HierarchicalClassifier

    files = v7_files(zoo_dir, tag)
    h1, h2, levels = load_labels(files["labels"])
    with contextlib.redirect_stdout(io.StringIO()):  # insectDCT prints a lot while loading
        clf = HierarchicalClassifier(h1, h2, *levels, img_size=CROP, stdThreshold=0.0, device="cpu")
        clf.loadmodel(str(files["weights"]), str(files["thresholds"]), modelName=model_name)
    return clf, files, (h1, h2, levels)


def phone_graph(net):
    """The network as the phone runs it: one picture in, the three heads' scores in one row out.

    Two rewrites with the same arithmetic, so phone GPUs can run the file (Xiaomi, round 265):
    - ConvNeXt ends with an average over the 7 x 7 grid (AdaptiveAvgPool2d) and a normalisation
      of the 1024 x 1 x 1 result (LayerNorm2d). The converter writes that pooling with a
      GATHER_ND step, which phone GPUs cannot run (the GPU refused the whole file). Replaced by
      the mean over height and width, then a layer norm of the 1024 numbers. (The file then
      compiles on the Xiaomi's GPU, but its GPU results do not match the CPU's; cause not found,
      see README section 3.)
    - ResNet50's max pooling pads with minus infinity (PADV2), which the GPU refused ("src has
      wrong size"). The pooling follows a ReLU (every value is 0 or more), so padding with 0
      gives the same maximum: zero padding (PAD), then pooling without padding.
    """
    import torch
    import torch.nn.functional as F
    from torchvision.models.convnext import LayerNorm2d

    class GridMean(torch.nn.Module):
        def forward(self, x):  # [1, C, H, W] -> [1, C]
            return x.mean(dim=(2, 3))

    class FlatLayerNorm(torch.nn.Module):
        def __init__(self, norm):
            super().__init__()
            self.norm = norm

        def forward(self, x):  # [1, C] -> [1, C]; the following Flatten changes nothing
            n = self.norm
            return F.layer_norm(x, n.normalized_shape, n.weight, n.bias, n.eps)

    net = copy.deepcopy(net)  # the check compares against the untouched original
    body = getattr(net, "model_ft", None)
    head = getattr(body, "classifier", None)
    if isinstance(head, torch.nn.Sequential) and isinstance(head[0], LayerNorm2d):  # ConvNeXt
        body.avgpool = GridMean()
        head[0] = FlatLayerNorm(head[0])
    pool = getattr(body, "maxpool", None)
    if isinstance(pool, torch.nn.MaxPool2d) and pool.padding == 1:  # ResNet50, after a ReLU
        body.maxpool = torch.nn.Sequential(torch.nn.ZeroPad2d(1),
                                           torch.nn.MaxPool2d(pool.kernel_size, pool.stride, padding=0))

    class PhoneGraph(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.net = net

        def forward(self, x):  # x: [1, 3, 224, 224] RGB 0..1, as insectDCT's ToTensor() makes it
            return torch.cat(self.net(x), dim=1)

    return PhoneGraph().eval()


class PhoneFile:
    """A .tflite behind the same call as insectDCT's network (batch in, three score tensors out),
    so insectDCT's own makePrediction can run on it unchanged."""

    def __init__(self, path: Path, sizes: list[int], threads: int = 4):
        from ai_edge_litert.interpreter import Interpreter

        self.it = Interpreter(model_path=str(path), num_threads=threads)
        self.it.allocate_tensors()
        self.inp, self.out = self.it.get_input_details()[0], self.it.get_output_details()[0]
        self.nhwc = int(self.inp["shape"][-1]) == 3
        self.sizes = sizes

    def scores(self, chw: np.ndarray) -> np.ndarray:
        x = chw[None].astype(np.float32)
        if self.nhwc:
            x = x.transpose(0, 2, 3, 1)
        self.it.set_tensor(self.inp["index"], np.ascontiguousarray(x))
        self.it.invoke()
        return self.it.get_tensor(self.out["index"])[0].copy()

    def __call__(self, batch):
        import torch

        out = torch.from_numpy(np.stack([self.scores(b) for b in batch.detach().cpu().numpy()]))
        return tuple(torch.split(out, self.sizes, dim=1))


# ---------------------------------------------------------------------------- taxonomy table

def draft_taxa(levels, h1, h2, tol_json: Path, out_csv: Path) -> None:
    """Write the level-3 class -> kingdom..species table (see the file header)."""
    print(f"Reading the TreeOfLife names ({tol_json.name}, about 800,000 species)...")
    with open(tol_json, encoding="utf-8") as f:
        tol = json.load(f)
    species, by_name = {}, [dict() for _ in range(6)]
    for entry in tol:
        sci = [s or "" for s in entry[0]]
        species.setdefault((sci[5], sci[6]), sci)
        for k in range(6):
            if sci[k]:
                by_name[k].setdefault(sci[k], Counter())[tuple(sci[:k + 1])] += 1

    notes = {}

    def lineage(name: str, rank: str | None = None) -> list[str]:
        words = name.split()
        if len(words) == 2 and rank in (None, "species"):
            sci = species.get((words[0], words[1]))
            if sci is None:  # e.g. listed there under a synonym: kingdom..genus from its genus
                sci = lineage(words[0], "genus")[:6] + [words[1]]
                notes[name] = "species not in the TreeOfLife names; kingdom to genus from its genus"
            return sci
        for k in ([RANKS.index(rank)] if rank else [5, 4, 3, 2, 1]):
            if name in by_name[k]:
                prefix = by_name[k][name].most_common(1)[0][0]  # a name can sit in two places
                return list(prefix) + [""] * (7 - len(prefix))
        raise SystemExit(f"'{name}' is not in the TreeOfLife names; add it to NOT_TAXA")

    parent2 = {c: p for p, children in h2.items() for c in children}
    parent1 = {c: p for p, children in h1.items() for c in children}
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    with open(out_csv, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["model_class", "model_level2", "model_level1", *RANKS, "note"])
        for name in levels[2]:
            note = ""
            if name in NOT_TAXA and NOT_TAXA[name] is None:
                ranks = [APP_SINK] + [""] * 6
                note = "not an organism (FaunaPulse: 'no organism')"
            elif name in NOT_TAXA:
                look, rank, note = NOT_TAXA[name]
                ranks = lineage(look, rank)
            else:
                look = name[:-3] if name.endswith("_fw") else name
                ranks = lineage(look)
                note = notes.get(look, "")
            if name.endswith("_fw"):
                note = "; ".join(x for x in (note, "separate insectDCT class (suffix _fw)") if x)
            w.writerow([name, parent2[name], parent1[parent2[name]], *ranks, note])
    print(f"Wrote {out_csv} ({len(levels[2])} classes). Review it before use.")


def read_taxa(path: Path, leaves: list[str]) -> list[list[str]]:
    """Kingdom..species per level-3 class, in the model's order."""
    with open(path, encoding="utf-8") as f:
        rows = {r["model_class"]: [r[k] for k in RANKS] for r in csv.DictReader(f)}
    missing = [c for c in leaves if c not in rows]
    if missing:
        raise SystemExit(f"{path} has no row for {missing}")
    return [rows[c] for c in leaves]


# ---------------------------------------------------------------------------- candidate app rules

def leaf_probabilities(scores: np.ndarray, sizes: list[int], ancestors: list[tuple[int, int, int]],
                       rule: str) -> np.ndarray:
    """One probability per level-3 class from the three heads' raw scores (fpack.py's
    class_probabilities, the formula the app uses).

    rule "mean": a class's score is the mean of its own, its level-2 group's and its level-1
    group's log-probability, so a class only scores high when all three levels agree, and three
    heads do not count as three independent votes.
    rule "level3": the level-3 head alone.
    """
    return class_probabilities(scores, sizes, ancestors, heads=None if rule == "mean" else [2])


def class_list_header(stem: str, levels, ancestors, lineages, manifest: dict) -> dict:
    """The app's class list for one phone file (fpack.write_class_list): the 104 level-3 classes
    with kingdom ... species from the taxonomy table, their place in each head, Vegetation as
    the "none of these" row. Named like the phone file, so the app pairs the two by name."""
    labels = []
    for name, lin in zip(levels[2], lineages):
        if lin[0] == APP_SINK:
            labels.append(sink_label(name, ""))  # the key of a "none" row sits in the species slot
        else:
            labels.append(list(lin) + [""])
    return {
        "pack_id": stem, "model_id": stem, "logit_scale": 1.0, "temperature": 1.0, "ranks": RANKS,
        "sink_rows": sum(1 for lin in lineages if lin[0] == APP_SINK),
        "labels": labels,
        "classes": list(levels[2]),
        "heads": [{"name": f"level {i + 1}", "size": len(level), "classes": list(level)}
                  for i, level in enumerate(levels)],
        "head_index": [list(a) for a in ancestors],
        "combine": "mean of the heads' log-probabilities",
        "model": manifest["model"], "backbone": manifest["backbone"],
        "source_sha256": manifest["source_sha256"], "taxonomy": "taxa/insectdct-cls-v7.csv",
        "built": date.today().isoformat(), "license": manifest["license"],
    }


def app_answer(p: np.ndarray, lineages: list[list[str]], tau: float = TAU) -> str:
    """FaunaPulse's readout (track_fusion.dart for one crop): roll the probabilities up the
    taxonomy, follow the best child of the chosen parent, report the deepest rank with at least
    [tau]; "no organism" when the sink rows win."""
    parent: tuple = ()
    path = []
    for k in range(7):
        masses: dict[tuple, float] = {}
        for prob, lin in zip(p, lineages):
            if not all(lin[: k + 1]) or tuple(lin[:k]) != parent:
                continue
            key = tuple(lin[: k + 1])
            masses[key] = masses.get(key, 0.0) + float(prob)
        if not masses:
            break
        best = max(masses, key=masses.get)
        path.append((k, best, masses[best]))
        parent = best
    if not path:
        return "unidentified"
    if path[0][1][0] == APP_SINK:
        return "no organism" if path[0][2] > 0.5 else "unidentified"
    answer = "unidentified"
    for k, key, mass in path:
        if mass < tau:
            break
        name = f"{key[5]} {key[6]}" if k == 6 else key[-1]
        answer = f"{name} ({RANKS[k]}, {mass:.2f})"
    return answer


def upstream_answer(clf, bgr: np.ndarray) -> tuple[str, np.ndarray]:
    """insectDCT's own answer (makePrediction, strongCheck=False as in the zoo), plus the exact
    224 x 224 input it built (to feed the phone file the same numbers)."""
    import torch

    with torch.inference_mode():
        _line, level, index, name, _conf = clf.makePrediction(np.ascontiguousarray(bgr), strongCheck=False)
    text = "Unsure" if index < 0 else f"{name} (level {level})"
    return text, clf.imagesInBatch[0].detach().cpu().numpy().copy()


def check(clf, phone: PhoneFile, images: list[Path], lineages, ancestors, sizes, limit: int) -> dict:
    import cv2
    import torch

    def taxon(answer: str) -> str:  # "Bombus (genus, 0.97)" -> "Bombus (genus": the confidence aside
        return answer.rsplit(",", 1)[0]

    net = clf.model
    rows, diffs, same_up, rule_differs = [], [], 0, []
    pt_ms = tf_ms = 0.0
    for path in images[:limit]:
        bgr = cv2.imread(str(path))
        if bgr is None:
            continue
        t0 = time.perf_counter()
        up_pt, x = upstream_answer(clf, bgr)
        pt_ms += (time.perf_counter() - t0) * 1000
        with torch.inference_mode():
            s_pt = torch.cat(net(torch.from_numpy(x)[None]), dim=1)[0].numpy()
        clf.model = phone
        t0 = time.perf_counter()
        up_tf, _ = upstream_answer(clf, bgr)
        tf_ms += (time.perf_counter() - t0) * 1000
        clf.model = net
        s_tf = phone.scores(x)
        diffs.append(float(np.abs(s_pt - s_tf).max()))
        rule_pt = app_answer(leaf_probabilities(s_pt, sizes, ancestors, "mean"), lineages)
        rule_mean = app_answer(leaf_probabilities(s_tf, sizes, ancestors, "mean"), lineages)
        rule_l3 = app_answer(leaf_probabilities(s_tf, sizes, ancestors, "level3"), lineages)
        same_up += up_pt == up_tf
        if taxon(rule_pt) != taxon(rule_mean):
            rule_differs.append(f"{path.name}: original {rule_pt}, phone file {rule_mean}")
        rows.append((path.name, up_pt, up_tf, rule_mean, rule_l3))
    n = len(rows)
    header = ("picture", "insectDCT (PyTorch)", "insectDCT (phone file)", "app rule: mean of 3 levels",
              "app rule: level 3 only")
    w = [max(len(r[i]) for r in rows + [header]) for i in range(5)]
    for r in [header] + rows:
        print("  ".join(c.ljust(w[i]) for i, c in enumerate(r)))
    return {"pictures": n, "upstream_answer_same": same_up, "app_rule_same_taxon": n - len(rule_differs),
            "app_rule_differs": rule_differs,
            "max_score_difference": round(max(diffs), 4) if diffs else None,
            "pc_ms_per_crop_pytorch": round(pt_ms / max(n, 1), 1),
            "pc_ms_per_crop_phone_file": round(tf_ms / max(n, 1), 1)}


# ---------------------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zoo-dir", type=Path, required=True,
                    help="the zoo's insectdct-cls-v7 folder (HierarchicalClassifierV7.zip unpacked + upstream/)")
    ap.add_argument("--backbone", choices=sorted(BACKBONES), default="cnb",
                    help="cnb = ConvNeXt-Base (the zoo's choice), eff2s = EfficientNetV2-S, res = ResNet50")
    ap.add_argument("--precision", choices=["fp16", "fp32", "int8"], default="fp16")
    ap.add_argument("--out", type=Path, default=HERE / "out")
    ap.add_argument("--keep-fp32", action="store_true", help="keep the float32 intermediate .tflite")
    ap.add_argument("--check-images", type=Path, help="folder of crops (jpg/png) to compare on")
    ap.add_argument("--check-limit", type=int, default=50)
    ap.add_argument("--taxa", type=Path, default=DEFAULT_TAXA, help="class -> taxonomy table (--draft-taxa)")
    ap.add_argument("--draft-taxa", type=Path, metavar="TOL_JSON",
                    help="write --taxa from this TreeOfLife names file (txt_emb_*.json) and stop")
    args = ap.parse_args()

    tag, model_name = BACKBONES[args.backbone]
    if args.draft_taxa:
        h1, h2, levels = load_labels(v7_files(args.zoo_dir, tag)["labels"])
        draft_taxa(levels, h1, h2, args.draft_taxa, args.taxa)
        return 0

    print(f"Loading insectDCT V7 {model_name}...")
    clf, files, (h1, h2, levels) = load_upstream(args.zoo_dir, args.backbone)
    sizes = [len(level) for level in levels]
    args.out.mkdir(parents=True, exist_ok=True)
    # Naming rule (tool/model_downloads/README.md, round 276): <model>_<input px>_<precision>,
    # the class list under the same name.
    stem = f"insectdct-cls-v7-{args.backbone}_{CROP}_{args.precision}"
    tflite = args.out / f"{stem}.tflite"
    if tflite.exists():
        print(f"Reusing {tflite}")
    else:
        import export_image_tower as eit

        eit.KEEP_FP32 = args.keep_fp32
        eit.export_tflite(phone_graph(clf.model), CROP, args.precision, tflite)
    manifest = {
        "kind": "classifier",
        "model": "insectdct-cls-v7",
        "backbone": model_name,
        "source_weights": files["weights"].name,
        "source_sha256": sha256_of(files["weights"]),
        "precision": args.precision,
        "bytes": tflite.stat().st_size,
        "input_size": CROP,
        "input_layout": "NCHW",
        "input_range": "0..1 RGB, no further normalisation (insectDCT's ToTensor())",
        "output": "raw scores of the three heads, one after the other (level 1, 2, 3); not normalised",
        "heads": [{"level": i + 1, "size": n, "classes": levels[i]} for i, n in enumerate(sizes)],
        "exported": date.today().isoformat(),
        "license": "GPL-3.0 (insectDCT, Bjerge et al. 2026); check before sharing",
    }

    index1 = {c: i for i, c in enumerate(levels[0])}
    index2 = {c: i for i, c in enumerate(levels[1])}
    parent2 = {c: p for p, children in h2.items() for c in children}
    parent1 = {c: p for p, children in h1.items() for c in children}
    ancestors = [(index1[parent1[parent2[c]]], index2[parent2[c]], i) for i, c in enumerate(levels[2])]
    lineages = read_taxa(args.taxa, levels[2])
    class_list = args.out / f"{stem}.fpack"
    write_class_list(class_list, class_list_header(stem, levels, ancestors, lineages, manifest))
    manifest["class_list"] = class_list.name

    if args.check_images:
        images = sorted(p for p in args.check_images.iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png"))
        print(f"\nChecking {min(len(images), args.check_limit)} pictures from {args.check_images}:")
        manifest["check"] = check(clf, PhoneFile(tflite, sizes), images, lineages, ancestors, sizes,
                                  args.check_limit)
        print(json.dumps(manifest["check"], indent=1))
    (args.out / f"{stem}.json").write_text(json.dumps(manifest, indent=1, ensure_ascii=False))
    print(f"\n{tflite} ({tflite.stat().st_size / 2**20:.1f} MiB) + {stem}.json + {class_list.name} (class list)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
