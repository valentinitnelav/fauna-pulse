#!/usr/bin/env python3
"""Encode SAM 3 text prompts on the PC for the phone's prompt memory (round 257, sam3 branch).

The phone keeps each encoded prompt as prompts/<token numbers>.f32 next to the SAM 3 files
(Sam3Detector.kt) and runs its 600 MB text model only for prompts it has not seen. Encoding
the usual prompts here saves the phone that step (about 2 GB of memory for a few seconds).

Usage:
    python make_prompts.py SAM3_DIR insect bee "hoverfly" ... [--out-dir DIR]

SAM3_DIR holds sam3_text.tflite, sam3_token_embed.bin, vocab.json and merges.txt. Files go
to DIR (default SAM3_DIR/prompts); copy them to the phone's files/sam3/prompts/.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from ai_edge_litert.interpreter import Interpreter
from transformers import CLIPTokenizer


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sam3_dir", type=Path)
    ap.add_argument("prompts", nargs="+")
    ap.add_argument("--out-dir", type=Path)
    a = ap.parse_args()
    out = a.out_dir or a.sam3_dir / "prompts"
    out.mkdir(parents=True, exist_ok=True)
    tok = CLIPTokenizer(str(a.sam3_dir / "vocab.json"), str(a.sam3_dir / "merges.txt"))
    table = np.memmap(a.sam3_dir / "sam3_token_embed.bin", np.float16, "r").reshape(-1, 1024)
    text = Interpreter(model_path=str(a.sam3_dir / "sam3_text.tflite"), num_threads=4)
    text.allocate_tensors()
    for p in a.prompts:
        ids = tok(p)["input_ids"][:32]
        vectors = np.zeros((1, 32, 1024), np.float32)
        vectors[0, : len(ids)] = table[ids].astype(np.float32)
        vectors[0, len(ids):] = table[0].astype(np.float32)  # padding is token 0, as on the phone
        text.set_tensor(text.get_input_details()[0]["index"], vectors)
        text.invoke()
        memory = text.get_tensor(text.get_output_details()[0]["index"]).astype("<f4").ravel()
        path = out / f"{'_'.join(map(str, ids))}.f32"
        path.write_bytes(memory.tobytes())
        print(f"{p!r}: {path.name}")


if __name__ == "__main__":
    main()
