#!/usr/bin/env python3
"""Split a large .tflite graph into consecutive parts, so a phone sets each part up on its GPU
separately (round 257, sam3 branch).

Why: setting SAM 3's 930 MB picture model up on the Xiaomi's GPU needs about 4 GB of memory
at its peak, and Android closed the app. The model is a stack of transformer blocks; between
two blocks only one tensor (the "residual stream", [1, 72, 72, 1024]) is passed on. Cutting
there gives parts that, run one after the other, compute exactly the same numbers as the
whole model, while each part's setup needs only its share of the memory.

Usage:
    python split_tflite.py sam3_vision.tflite --parts 4 [--out-dir DIR] [--check picture.png]

Writes <name>_part1.tflite ... <name>_partN.tflite. Each part has one input (args_0) and one
output (output_0), like the original. --check runs the whole model and the parts on the CPU
with a picture preprocessed as SAM 3 expects and prints the largest difference.
"""

from __future__ import annotations

import argparse
import copy
from pathlib import Path

import numpy as np
from ai_edge_litert.tools import flatbuffer_utils as fu


def single_tensor_cuts(sg):
    """(op index, tensor index) pairs where only one computed tensor is alive after the op."""
    n = len(sg.operators)
    last_use = {}
    for i, op in enumerate(sg.operators):
        for t in op.inputs:
            if t >= 0:
                last_use[t] = i
    for t in sg.outputs:
        last_use[t] = n
    produced = {t: -1 for t in sg.inputs}
    for i, op in enumerate(sg.operators):
        for t in op.outputs:
            produced[t] = i
    cuts = []
    for i in range(n - 1):
        alive = [t for t, p in produced.items() if p <= i and last_use.get(t, -1) > i]
        if len(alive) == 1:
            cuts.append((i, alive[0]))
    return cuts


def weight_share(m, sg):
    """Cumulative share of the constant bytes read up to each op."""
    produced = set(sg.inputs)
    for op in sg.operators:
        produced.update(op.outputs)
    seen = set()
    per_op = np.zeros(len(sg.operators))
    for i, op in enumerate(sg.operators):
        for t in op.inputs:
            if t >= 0 and t not in produced and t not in seen:
                seen.add(t)
                data = m.buffers[sg.tensors[t].buffer].data
                per_op[i] += 0 if data is None else len(data)
    cum = np.cumsum(per_op)
    return cum / cum[-1]


def make_part(m, first_op, last_op, inp, out):
    """A model holding ops first_op..last_op with graph input `inp` and output `out`."""
    sg = m.subgraphs[0]
    ops = sg.operators[first_op:last_op + 1]
    used = [inp, out]
    for op in ops:
        used += [t for t in list(op.inputs) + list(op.outputs) + list(op.intermediates or []) if t >= 0]
    tensor_map = {}
    buffers = [m.buffers[0]]  # buffer 0 stays the empty one, as TFLite expects
    buffer_map = {0: 0}
    tensors = []
    for t in used:
        if t in tensor_map:
            continue
        ten = copy.copy(sg.tensors[t])
        if t == inp:
            ten.buffer = 0
        elif ten.buffer not in buffer_map:
            buffer_map[ten.buffer] = len(buffers)
            buffers.append(m.buffers[ten.buffer])
        ten.buffer = buffer_map[ten.buffer]
        tensor_map[t] = len(tensors)
        tensors.append(ten)

    def remap(ix):
        return [tensor_map[t] if t >= 0 else -1 for t in ix]

    new_ops = []
    for op in ops:
        o = copy.copy(op)
        o.inputs = remap(op.inputs)
        o.outputs = remap(op.outputs)
        if op.intermediates is not None:
            o.intermediates = remap(op.intermediates)
        new_ops.append(o)

    part = copy.copy(m)
    new_sg = copy.copy(sg)
    new_sg.tensors = tensors
    new_sg.operators = new_ops
    new_sg.inputs = [tensor_map[inp]]
    new_sg.outputs = [tensor_map[out]]
    part.subgraphs = [new_sg]
    part.buffers = buffers
    part.metadata = []
    part.metadataBuffer = []
    sig = copy.deepcopy(m.signatureDefs[0])
    sig.inputs = sig.inputs[:1]
    sig.outputs = sig.outputs[:1]
    sig.inputs[0].tensorIndex = tensor_map[inp]
    sig.outputs[0].tensorIndex = tensor_map[out]
    part.signatureDefs = [sig]
    return part


def run_cpu(path, x):
    from ai_edge_litert.interpreter import Interpreter

    it = Interpreter(model_path=str(path), num_threads=8)
    it.allocate_tensors()
    d = it.get_input_details()[0]
    it.set_tensor(d["index"], np.ascontiguousarray(x.reshape(d["shape"]), np.float32))
    it.invoke()
    return it.get_tensor(it.get_output_details()[0]["index"]).copy()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model", type=Path)
    ap.add_argument("--parts", type=int, default=4)
    ap.add_argument("--out-dir", type=Path)
    ap.add_argument("--check", type=Path, help="picture to compare whole model and parts on")
    a = ap.parse_args()
    out_dir = a.out_dir or a.model.parent
    m = fu.read_model(str(a.model))
    assert len(m.subgraphs) == 1 and len(m.subgraphs[0].inputs) == 1 and len(m.subgraphs[0].outputs) == 1
    sg = m.subgraphs[0]
    cuts = single_tensor_cuts(sg)
    share = weight_share(m, sg)
    # For each wanted boundary (1/parts, 2/parts, ...) the cut whose weight share is closest.
    chosen = []
    for k in range(1, a.parts):
        i, t = min(cuts, key=lambda c: abs(share[c[0]] - k / a.parts))
        if not chosen or i > chosen[-1][0]:
            chosen.append((i, t))
    bounds = [(-1, sg.inputs[0])] + chosen + [(len(sg.operators) - 1, sg.outputs[0])]
    paths = []
    for k in range(len(bounds) - 1):
        (a_op, a_t), (b_op, b_t) = bounds[k], bounds[k + 1]
        part = make_part(m, a_op + 1, b_op, a_t, b_t)
        path = out_dir / f"{a.model.stem}_part{k + 1}.tflite"
        fu.write_model(part, str(path))
        paths.append(path)
        print(f"{path.name}: ops {a_op + 1}..{b_op}, input {list(sg.tensors[a_t].shape)}, "
              f"output {list(sg.tensors[b_t].shape)}, {path.stat().st_size / 1e6:.0f} MB")
    if a.check:
        from PIL import Image

        img = Image.open(a.check).convert("RGB").resize((1008, 1008), Image.BILINEAR)
        x = ((np.asarray(img, np.float32) / 255 - 0.5) / 0.5).transpose(2, 0, 1)[None]
        whole = run_cpu(a.model, x)
        y = x
        for p in paths:
            y = run_cpu(p, y)
        diff = np.abs(whole.ravel() - y.ravel())
        print(f"check: largest difference {diff.max():.3g}, mean {diff.mean():.3g}, "
              f"values up to {np.abs(whole).max():.3g}")


if __name__ == "__main__":
    main()
