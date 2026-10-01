"""FaunaPulse label-pack container ("fpack"): one file = header JSON + embedding matrix.

A label pack is what the phone compares a crop's image embedding against. It holds one
L2-normalised text embedding per candidate name (species rows from the TreeOfLife
embeddings, plus a few "none of these" sink rows) and the taxonomy of every row.

Layout (all little-endian):
    bytes 0..3      ASCII magic "FPK1"
    bytes 4..7      uint32 header length H (bytes)
    bytes 8..8+H    UTF-8 JSON header (see write_fpack for the keys)
    then            rows x dim numbers, row-major, dtype "f16" or "f32" per header

The Dart reader lives in lib/fauna_pulse/identification/label_pack.dart; both sides are
covered by test/fauna_pulse/label_pack_test.dart through the fixture this module writes.
Only numpy is needed here, so the format can be tested without torch.
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

import numpy as np

MAGIC = b"FPK1"
RANKS = ["kingdom", "phylum", "class", "order", "family", "genus", "species"]


def write_fpack(path: Path, header: dict, matrix: np.ndarray, dtype: str = "f16") -> None:
    """Write [matrix] (rows x dim, any float dtype) with [header] into [path].

    Rows are re-normalised to unit length so the phone can use plain dot products.
    The header gets "rows", "dim" and "dtype" filled in; everything else is the caller's.
    """
    if matrix.ndim != 2:
        raise ValueError(f"matrix must be 2-D (rows x dim), got shape {matrix.shape}")
    mat = np.asarray(matrix, dtype=np.float32)
    norms = np.linalg.norm(mat, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    mat = mat / norms
    if dtype == "f16":
        payload = mat.astype("<f2").tobytes()
    elif dtype == "f32":
        payload = mat.astype("<f4").tobytes()
    else:
        raise ValueError("dtype must be 'f16' or 'f32'")
    hdr = dict(header)
    hdr.update({"format": "fpack", "version": 1, "rows": int(mat.shape[0]),
                "dim": int(mat.shape[1]), "dtype": dtype})
    labels = hdr.get("labels")
    if labels is None or len(labels) != mat.shape[0]:
        raise ValueError("header['labels'] must have one entry per matrix row")
    hdr_bytes = json.dumps(hdr, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    with open(path, "wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<I", len(hdr_bytes)))
        f.write(hdr_bytes)
        f.write(payload)


def write_class_list(path: Path, header: dict) -> None:
    """Write a class list (round 266): the label pack of a fixed-class classifier such as
    insectDCT. No name vectors: the model itself scores every class. The header holds, per
    row (finest class), its taxonomy in "labels" and the model's own name in "classes", plus
    "heads" (the model's output layers: [{"name", "size", "classes"}], one after another in
    the model's output) and "head_index" (per row, its class in every head). "dim" is the
    model's output length, so the app's size check pairs model and class list.
    """
    hdr = dict(header)
    rows = len(hdr["labels"])
    sizes = [h["size"] for h in hdr["heads"]]
    if len(hdr["classes"]) != rows or len(hdr["head_index"]) != rows:
        raise ValueError("labels, classes and head_index need one entry per row")
    for idx in hdr["head_index"]:
        if len(idx) != len(sizes) or any(not 0 <= i < n for i, n in zip(idx, sizes)):
            raise ValueError(f"head_index entry {idx} does not fit the heads {sizes}")
    hdr.update({"format": "fpack", "version": 1, "kind": "classes", "rows": rows,
                "dim": int(sum(sizes)), "dtype": "none"})
    hdr_bytes = json.dumps(hdr, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    with open(path, "wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<I", len(hdr_bytes)))
        f.write(hdr_bytes)


def class_probabilities(scores, head_sizes, head_index, heads=None) -> np.ndarray:
    """One probability per class-list row from a classifier's raw output (the rule the app
    uses, track_fusion.dart): each head's scores become log-probabilities (log-softmax); a
    row scores the mean of its classes' log-probabilities over the heads used (default: all),
    so a fine class only scores high when every level agrees and K heads do not count as K
    independent votes; then one softmax over the rows."""
    scores = np.asarray(scores, dtype=np.float64)
    use = range(len(head_sizes)) if heads is None else heads
    logp, start = [], 0
    for n in head_sizes:
        h = scores[start:start + n]
        m = h.max()
        logp.append(h - m - np.log(np.exp(h - m).sum()))
        start += n
    s = np.array([np.mean([logp[k][idx[k]] for k in use]) for idx in head_index])
    e = np.exp(s - s.max())
    return e / e.sum()


def read_fpack(path: Path) -> tuple[dict, np.ndarray]:
    """Read a pack back: (header dict, float32 matrix rows x dim; rows x 0 for a class list)."""
    with open(path, "rb") as f:
        if f.read(4) != MAGIC:
            raise ValueError(f"{path} is not an fpack file (bad magic)")
        (hlen,) = struct.unpack("<I", f.read(4))
        hdr = json.loads(f.read(hlen).decode("utf-8"))
        rows, dim, dtype = hdr["rows"], hdr["dim"], hdr["dtype"]
        if dtype == "none":
            return hdr, np.zeros((rows, 0), np.float32)
        np_dtype = "<f2" if dtype == "f16" else "<f4"
        mat = np.frombuffer(f.read(), dtype=np_dtype, count=rows * dim).astype(np.float32)
    return hdr, mat.reshape(rows, dim)


def sink_label(name: str, prompt: str) -> list[str]:
    """Taxonomy row for a "none of these" candidate: kingdom 'none', the key in the
    species slot, the prompt as the common name."""
    return ["none", "", "", "", "", "", name, prompt]


def _write_class_fixture(path: Path) -> None:
    """Tiny two-level class list for the Dart tests (round 266), with two raw score vectors and
    the row probabilities class_probabilities gives for them (the app's rule, all heads)."""
    level1 = ["Diptera", "Hymenoptera", "Vegetation"]
    level2 = ["Syrphidae", "Eristalis tenax", "Apis mellifera", "Vegetation"]
    head_index = [[0, 0], [0, 1], [1, 2], [2, 3]]
    sizes = [len(level1), len(level2)]
    scores = [[2.0, -1.0, 0.5, 1.5, 0.2, -0.3, 0.1], [-0.5, 3.0, 0.0, 0.4, 0.1, 2.5, -1.0]]
    write_class_list(path, {
        "pack_id": "tiny-classes", "model_id": "tiny-classes", "logit_scale": 1.0, "temperature": 1.0,
        "ranks": RANKS, "sink_rows": 1,
        "labels": [["Animalia", "Arthropoda", "Insecta", "Diptera", "Syrphidae", "", "", ""],
                   ["Animalia", "Arthropoda", "Insecta", "Diptera", "Syrphidae", "Eristalis", "tenax", ""],
                   ["Animalia", "Arthropoda", "Insecta", "Hymenoptera", "Apidae", "Apis", "mellifera", ""],
                   sink_label("Vegetation", "")],
        "classes": level2,
        "heads": [{"name": "level 1", "size": sizes[0], "classes": level1},
                  {"name": "level 2", "size": sizes[1], "classes": level2}],
        "head_index": head_index,
        "test_scores": scores,
        "test_probs": [class_probabilities(s, sizes, head_index).round(6).tolist() for s in scores],
    })


if __name__ == "__main__":
    # Writes the tiny cross-language fixtures used by the Dart unit tests:
    #   python fpack.py ../../test/fauna_pulse/fixtures/tiny_pack.fpack ../../test/fauna_pulse/fixtures/tiny_classes.fpack
    import sys

    if len(sys.argv) > 2:
        _write_class_fixture(Path(sys.argv[2]))
        hdr, _ = read_fpack(Path(sys.argv[2]))
        print("wrote", sys.argv[2], "rows", hdr["rows"], "dim", hdr["dim"], "probs", hdr["test_probs"])
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("tiny.fpack")
    rng = np.random.default_rng(7)
    labels = [
        ["Animalia", "Arthropoda", "Insecta", "Diptera", "Syrphidae", "Eristalis", "tenax", "Drone fly"],
        ["Animalia", "Arthropoda", "Insecta", "Diptera", "Syrphidae", "Episyrphus", "balteatus", "Marmalade hoverfly"],
        ["Animalia", "Arthropoda", "Insecta", "Hymenoptera", "Apidae", "Apis", "mellifera", "Western honey bee"],
        ["Animalia", "Arthropoda", "Insecta", "Hymenoptera", "Apidae", "Bombus", "terrestris", "Buff-tailed bumblebee"],
        ["Animalia", "Arthropoda", "Arachnida", "Araneae", "Thomisidae", "Misumena", "vatia", "Goldenrod crab spider"],
        sink_label("flower", "a photo of a flower."),
    ]
    mat = rng.standard_normal((len(labels), 4)).astype(np.float32)
    write_fpack(out, {
        "pack_id": "tiny-test", "model_id": "test-model", "logit_scale": 100.0,
        "temperature": 1.0, "ranks": RANKS, "sink_rows": 1, "labels": labels,
    }, mat, dtype="f16")
    hdr, back = read_fpack(out)
    assert hdr["rows"] == 6 and hdr["dim"] == 4
    print("wrote", out, "rows", hdr["rows"], "dim", hdr["dim"], "first row", back[0])
