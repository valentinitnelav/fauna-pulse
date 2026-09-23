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


def read_fpack(path: Path) -> tuple[dict, np.ndarray]:
    """Read a pack back: (header dict, float32 matrix rows x dim)."""
    with open(path, "rb") as f:
        if f.read(4) != MAGIC:
            raise ValueError(f"{path} is not an fpack file (bad magic)")
        (hlen,) = struct.unpack("<I", f.read(4))
        hdr = json.loads(f.read(hlen).decode("utf-8"))
        rows, dim, dtype = hdr["rows"], hdr["dim"], hdr["dtype"]
        np_dtype = "<f2" if dtype == "f16" else "<f4"
        mat = np.frombuffer(f.read(), dtype=np_dtype, count=rows * dim).astype(np.float32)
    return hdr, mat.reshape(rows, dim)


def sink_label(name: str, prompt: str) -> list[str]:
    """Taxonomy row for a "none of these" candidate: kingdom 'none', the key in the
    species slot, the prompt as the common name."""
    return ["none", "", "", "", "", "", name, prompt]


if __name__ == "__main__":
    # Writes the tiny cross-language fixture used by the Dart unit tests.
    import sys

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
