#!/usr/bin/env python3
"""Print what a .tflite export contains: ops, constant tensor sizes by type, and how
the weights of every FULLY_CONNECTED (matrix multiply) layer are stored. Used to check
that an export is sane before copying it to the phone, and that quantisation reached
every large layer (quantise_tflite.py explains the kinds):

    fp16 weights                              fp16 file (--precision fp16)
    int8 weights, float maths                 --precision int8-weights
    int8 weights, 8-bit maths                 --precision int8 (dynamic range)
    float32 weights (not quantised)           fp32 file, or a layer the quantiser missed
    weights computed at runtime (unfolded)    converted in the memory-saving mode (see README)

Usage: python inspect_tflite.py out/bioclip-2_224_fp16.tflite [more files]
"""

from __future__ import annotations

import sys
from collections import Counter, defaultdict
from pathlib import Path

from ai_edge_litert.tools import flatbuffer_utils as fu

TYPE_NAMES = {0: "float32", 1: "float16", 2: "int32", 9: "int8", 6: "bool"}
OP_NAMES = {0: "ADD", 3: "CONV_2D", 6: "DEQUANTIZE", 9: "FULLY_CONNECTED", 18: "MUL", 22: "RESHAPE",
            25: "SOFTMAX", 39: "TRANSPOSE", 40: "MEAN", 41: "SUB", 65: "SLICE", 74: "SUM", 126: "BATCH_MATMUL"}


def inspect(path: Path) -> None:
    m = fu.read_model(path)
    sg = m.subgraphs[0]
    consumers = defaultdict(list)
    for oi, op in enumerate(sg.operators):
        for ti in op.inputs:
            if ti >= 0:
                consumers[ti].append(oi)

    def op_name(oi):
        c = m.operatorCodes[sg.operators[oi].opcodeIndex].builtinCode
        return OP_NAMES.get(c, str(c))

    def size(ti):
        b = m.buffers[sg.tensors[ti].buffer]
        return 0 if b.data is None else len(b.data)

    by_type = defaultdict(int)
    by_consumer = defaultdict(int)
    orphan_bytes = 0
    seen_buffers = set()
    for ti, t in enumerate(sg.tensors):
        s = size(ti)
        if s == 0 or t.buffer in seen_buffers:
            continue
        seen_buffers.add(t.buffer)
        by_type[TYPE_NAMES.get(t.type, t.type)] += s
        if ti not in consumers:
            orphan_bytes += s
        for c in {op_name(oi) for oi in consumers[ti]}:
            by_consumer[(c, TYPE_NAMES.get(t.type, t.type))] += s
    ops = Counter(op_name(oi) for oi in range(len(sg.operators)))
    producer = {}
    for oi, op in enumerate(sg.operators):
        for ti in op.outputs:
            producer[ti] = oi
    fc_const = Counter()
    for oi, op in enumerate(sg.operators):
        if op_name(oi) == "FULLY_CONNECTED":
            w = op.inputs[1]
            if size(w) > 0:  # the weights are a constant the layer reads directly
                kind = TYPE_NAMES.get(sg.tensors[w].type)
                fc_const["int8 weights, 8-bit maths" if kind == "int8" else f"{kind} weights (not quantised)"] += 1
            elif w in producer and op_name(producer[w]) == "DEQUANTIZE":  # stored small, widened for the layer
                kind = TYPE_NAMES.get(sg.tensors[sg.operators[producer[w]].inputs[0]].type)
                fc_const["fp16 weights" if kind == "float16" else f"{kind} weights, float maths"] += 1
            else:
                fc_const["weights computed at runtime (unfolded; use the full conversion)"] += 1

    print(f"{path} ({path.stat().st_size / 1e6:.0f} MB): {len(sg.tensors)} tensors, {len(sg.operators)} ops")
    print("  constants by type (MB):", {k: round(v / 1e6) for k, v in by_type.items()})
    print("  constants by consumer (MB):", {f"{k[0]}/{k[1]}": round(v / 1e6) for k, v in sorted(by_consumer.items(), key=lambda kv: -kv[1])[:6]})
    print("  FULLY_CONNECTED:", dict(fc_const), " orphan constant MB:", round(orphan_bytes / 1e6))
    print("  ops:", ops.most_common(8))
    for d in [("inputs", sg.inputs), ("outputs", sg.outputs)]:
        print(f"  {d[0]}:", [(sg.tensors[i].name, list(sg.tensors[i].shape)) for i in d[1]])


if __name__ == "__main__":
    for p in sys.argv[1:]:
        inspect(Path(p))
