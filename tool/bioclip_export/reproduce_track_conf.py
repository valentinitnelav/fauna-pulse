#!/usr/bin/env python3
"""Recompute FaunaPulse's per-track-id identification from a session's stored
embeddings, off the phone (round 219).

The app stores one embedding vector per crop in
<session>/identification/embeddings_<model>.{jsonl,bin}. This script applies
the same pooling rule as the app (see docs/IDENTIFICATION.md, "How a track
id's Conf. is computed") against a label pack and prints, per track id, the
ladder with Conf., the plain mean, the maximum and the agreeing-crops mean of
the crops' own values, and the agreement share, so every number on the
results screen can be checked independently.

Rule (defaults = the app's defaults):
  p_i   = softmax(scale * M @ e_i)        per crop, scale = logit_scale / temperature
  w_i   = max(p_i)                        certainty weight (the crop's top-1 probability)
  counted_i = w_i >= max(w) / drop_factor (drop_factor <= 1: every crop counts)
  m     = sum(w_i e_i) / sum(w_i)         over counted crops, NOT re-normalised
  pbar  = softmax(scale * M @ m)          scored once; masses = species summed per taxon
  ladder: top-down best child of the chosen parent; identified rank = deepest
          rank with mass >= tau

Usage:
  python3 reproduce_track_conf.py <session_dir> <pack.fpack> [--model STEM]
      [--tau 0.6] [--drop-factor 10] [--temperature T] [--track ID] [--crops]

Needs only numpy. Compare with <session>/identification/tracks_<pack>.json.
"""
import argparse
import json
import struct
import sys
from collections import defaultdict

import numpy as np

RANKS = ["kingdom", "phylum", "class", "order", "family", "genus", "species"]


def load_pack(path):
    raw = open(path, "rb").read()
    if raw[:4] != b"FPK1":
        sys.exit("not a label pack (missing FPK1 magic)")
    hlen = struct.unpack("<I", raw[4:8])[0]
    hdr = json.loads(raw[8:8 + hlen].decode())
    dim, rows = hdr["dim"], hdr["rows"]
    dtype = np.float32 if hdr.get("dtype", "f16") == "f32" else np.float16
    nbytes = rows * dim * np.dtype(dtype).itemsize
    matrix = np.frombuffer(raw[8 + hlen:8 + hlen + nbytes], dtype=dtype).astype(np.float32).reshape(rows, dim)
    labels = [(list(l) + [""] * 8)[:7] for l in hdr["labels"]]
    return hdr, matrix, labels


def load_embeddings(session_dir, stem):
    base = f"{session_dir}/identification/embeddings_{stem}"
    recs = [json.loads(l) for l in open(base + ".jsonl") if l.strip()]
    dim = next((r["dim"] for r in recs if r.get("type") == "identify_start" and "dim" in r), None)
    crops = [r for r in recs if r.get("type") == "crop"]
    vectors = np.fromfile(base + ".bin", dtype=np.float32)
    if dim is None:
        sys.exit("embedding dimension not found in the jsonl header")
    return crops, vectors.reshape(-1, dim)


def softmax(z):
    z = z - z.max()
    e = np.exp(z)
    return e / e.sum()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("session_dir")
    ap.add_argument("pack")
    ap.add_argument("--model", default="bioclip-2_image_fp16", help="embeddings file stem (default: bioclip-2_image_fp16)")
    ap.add_argument("--tau", type=float, default=0.6)
    ap.add_argument("--drop-factor", type=float, default=10.0)
    ap.add_argument("--temperature", type=float, default=None, help="override the pack's calibration temperature")
    ap.add_argument("--track", type=int, default=None, help="only this track id")
    ap.add_argument("--crops", action="store_true", help="also print the per-crop table")
    a = ap.parse_args()

    hdr, M, labels = load_pack(a.pack)
    temperature = a.temperature if a.temperature is not None else hdr.get("temperature", 1.0)
    scale = hdr["logit_scale"] / temperature
    keys = [["|".join(l[:k + 1]) if l[k] else None for k in range(7)] for l in labels]
    rows_under = [defaultdict(list) for _ in range(7)]
    for r, kk in enumerate(keys):
        for k in range(7):
            if kk[k]:
                rows_under[k][kk[k]].append(r)
    rows_under = [{key: np.array(v) for key, v in d.items()} for d in rows_under]

    crops, E = load_embeddings(a.session_dir, a.model)
    by_track = defaultdict(list)
    for c in crops:
        by_track[c.get("track_id")].append(c)
    print(f"pack {hdr.get('pack_id')} ({len(labels)} names), scale {scale:.1f} (temperature {temperature}), "
          f"tau {a.tau}, drop factor {a.drop_factor}, {len(crops)} crops in {len(by_track)} track ids")

    for tid in sorted(by_track, key=lambda t: (t is None, t)):
        if a.track is not None and tid != a.track:
            continue
        cr = by_track[tid]
        e = np.stack([E[c["row"]] for c in cr])
        P = np.stack([softmax(scale * (M @ v)) for v in e])
        w = P.max(axis=1)
        counted = w >= w.max() / a.drop_factor if a.drop_factor > 1 else np.ones(len(cr), bool)
        m = (w[counted, None] * e[counted]).sum(0) / w[counted].sum()
        pbar = softmax(scale * (M @ m))
        top1 = P.argmax(axis=1)

        def mass(p, key, k):
            return float(p[rows_under[k][key]].sum()) if key in rows_under[k] else 0.0

        # ladder: best child of the chosen parent
        ladder = []
        parent = ""
        for k in range(7):
            best_key, best = None, -1.0
            for key, idx in rows_under[k].items():
                if k > 0 and not key.startswith(parent + "|"):
                    continue
                v = float(pbar[idx].sum())
                if v > best:
                    best, best_key = v, key
            if best_key is None:
                break
            own = np.array([mass(P[i], best_key, k) for i in range(len(cr))])
            agree = np.array([keys[top1[i]][k] == best_key for i in range(len(cr))])
            ladder.append((RANKS[k], best_key.split("|")[-1] if k < 6 else " ".join(best_key.split("|")[5:7]),
                           best, own.mean(), own.max(), own[agree].mean() if agree.any() else 0.0, agree.mean()))
            parent = best_key
        identified = None
        for rank, _, p, *_ in ladder:
            if p >= a.tau and ladder[0][1] != "none":
                identified = rank
            else:
                break
        print(f"\n== track id {tid}: {len(cr)} crops, {int(counted.sum())} counted; identified rank: {identified}")
        print(f"   {'rank':8s} {'taxon':28s} {'Conf.':>6s} {'p_mean':>7s} {'p_max':>6s} {'p_agree':>8s} {'agree':>6s}")
        for rank, taxon, p, pm, px, pa, ag in ladder:
            print(f"   {rank:8s} {taxon[:28]:28s} {p*100:5.1f}% {pm*100:6.1f}% {px*100:5.1f}% {pa*100:7.1f}% {ag*100:5.0f}%")
        if a.crops:
            lkeys = []
            parent = ""
            for k, (_, taxon, *_rest) in enumerate(ladder):
                cand = [key for key in rows_under[k] if (k == 0 or key.startswith(parent + "|")) and key.split("|")[-1] == (taxon.split(" ")[-1] if k == 6 else taxon)]
                lkeys.append(cand[0] if cand else None)
                parent = lkeys[-1] or parent
            print(f"   {'no':>3s} {'counted':>7s} {'top-1 species':30s} {'sp.conf':>7s} " + " ".join(f"{r[:5]:>6s}" for r, *_ in ladder) + "  photo")
            for i, c in enumerate(cr):
                own = " ".join(f"{mass(P[i], key, k)*100:5.0f}%" if key else "    -" for k, key in enumerate(lkeys))
                print(f"   {i+1:>3d} {'yes' if counted[i] else 'no':>7s} {' '.join(labels[top1[i]][5:7])[:30]:30s} {w[i]*100:6.1f}% {own}  {c['src']}")


if __name__ == "__main__":
    main()
