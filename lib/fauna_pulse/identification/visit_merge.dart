// FaunaPulse (round 210, rule reworked round 212): optional joining of
// consecutive track ids into one visit AFTER identification. The tracker
// buffers a lost insect for `occlusionSeconds` (default 3 s) but can still
// hand out a new id (velocity overshoot, brief exit from the ROI); when the
// user turns "Merge consecutive visits" on, a track that starts within
// [gapMs] after the previous one ended is joined to it when
//   1. the identifications are compatible (same taxon at the shallower of
//      the two identified ranks, e.g. "Apidae" then "Bombus"), neither is
//      "no organism";
//   2. the two visits' fused embeddings are similar: cosine >= [minCos]
//      (the strong signal: "looks like the same animal", available for free
//      from the identification);
//   3. the mean box side relative to the ROI differs by at most [sizeTol]
//      (a coarse guard: pose, distance and ROI-edge cuts change box size,
//      so this is deliberately loose).
// The joined visit is identified again from all its crops. Tracks that
// overlap in time are never joined: two insects at once are two visits.
// Position continuity is NOT used: the tracker already handles it within
// its buffer, and after a real loss the insect may re-enter anywhere.
// Off by default: it changes the visit count, which is the scientific
// deliverable, so the user decides.

import 'dart:typed_data';

import 'label_pack.dart' show kRankNames;
import 'identification_store.dart' show EmbeddingRecord, ScoredTrack;
import 'track_fusion.dart' show FusedTrack;

/// Mean box side (longer side, as a fraction of the ROI) over a visit's crops.
double meanRelativeBoxSide(List<EmbeddingRecord> crops) {
  if (crops.isEmpty) return 0;
  var sum = 0.0;
  for (final c in crops) {
    final w = c.box[2] - c.box[0], h = c.box[3] - c.box[1];
    sum += w > h ? w : h;
  }
  return sum / crops.length;
}

/// Cosine similarity of two unit vectors (dot product).
double cosine(Float32List a, Float32List b) {
  final n = a.length < b.length ? a.length : b.length;
  var dot = 0.0;
  for (var i = 0; i < n; i++) {
    dot += a[i] * b[i];
  }
  return dot;
}

/// Whether [b] (the later track) may be joined to the visit ending with [a].
bool canMergeVisits(
  ScoredTrack a,
  ScoredTrack b, {
  required int gapMs,
  double sizeTol = 0.5,
  double minCos = 0.85,
  double noneThreshold = 0.5,
}) {
  if (a.trackIds.isEmpty || b.trackIds.isEmpty) return false;
  if (a.endMs == null || b.startMs == null) return false;
  final gap = b.startMs! - a.endMs!;
  if (gap < 0 || gap > gapMs) return false;
  final fa = a.fused, fb = b.fused;
  if (fa.identifiedRank == null || fb.identifiedRank == null) return false;
  if (fa.noneMass > noneThreshold || fb.noneMass > noneThreshold) return false;
  final ia = kRankNames.indexOf(fa.identifiedRank!), ib = kRankNames.indexOf(fb.identifiedRank!);
  final rank = kRankNames[ia < ib ? ia : ib];
  final sa = fa.stepAt(rank), sb = fb.stepAt(rank);
  if (sa == null || sb == null || sa.key != sb.key) return false;
  if (cosine(fa.fusedEmbedding, fb.fusedEmbedding) < minCos) return false;
  final pa = meanRelativeBoxSide(a.crops), pb = meanRelativeBoxSide(b.crops);
  if (pa <= 0 || pb <= 0) return false;
  final larger = pa > pb ? pa : pb;
  return (pa - pb).abs() / larger <= sizeTol;
}

/// Joins chains of mergeable tracks in [scored] (any order; sorted by start
/// time here). [refuse] identifies a joined crop set again. Tracks without a
/// track id or time span pass through unchanged.
List<ScoredTrack> mergeConsecutiveVisits(
  List<ScoredTrack> scored, {
  required int gapMs,
  required FusedTrack Function(List<EmbeddingRecord> crops) refuse,
  double sizeTol = 0.5,
  double minCos = 0.85,
  double noneThreshold = 0.5,
}) {
  final out = <ScoredTrack>[];
  final sorted = [...scored]..sort((a, b) => (a.startMs ?? 0).compareTo(b.startMs ?? 0));
  ScoredTrack? chain;
  var members = <ScoredTrack>[];
  void flush() {
    if (chain == null) return;
    if (members.length == 1) {
      out.add(chain!);
    } else {
      final crops = [for (final m in members) ...m.crops]
        ..sort((x, y) => (x.capturedAtMs ?? 0).compareTo(y.capturedAtMs ?? 0));
      out.add(
        ScoredTrack(
          fused: refuse(crops),
          crops: crops,
          startMs: members.first.startMs,
          endMs: chain!.endMs,
          trackIds: [for (final m in members) ...m.trackIds],
          detections: members.map((m) => m.detections).fold<int>(0, (s, d) => s + (d ?? 0)),
        ),
      );
    }
    chain = null;
    members = [];
  }

  for (final t in sorted) {
    if (t.trackIds.isEmpty || t.startMs == null || t.endMs == null) {
      flush();
      out.add(t);
      continue;
    }
    if (chain != null &&
        canMergeVisits(chain!, t, gapMs: gapMs, sizeTol: sizeTol, minCos: minCos, noneThreshold: noneThreshold)) {
      members.add(t);
      // The chain's end moves to the later track's end; its identification
      // stays the first member's until the flush re-identifies the union.
      chain = ScoredTrack(
        fused: chain!.fused,
        crops: chain!.crops,
        startMs: chain!.startMs,
        endMs: t.endMs! > chain!.endMs! ? t.endMs : chain!.endMs,
        trackIds: chain!.trackIds,
        detections: chain!.detections,
      );
      continue;
    }
    flush();
    chain = t;
    members = [t];
  }
  flush();
  return out;
}
