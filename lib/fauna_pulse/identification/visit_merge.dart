// FaunaPulse (round 210): optional joining of consecutive track ids into one
// visit AFTER identification. The tracker sometimes loses an insect for a
// moment and gives it a new id (see the tracker-fragmentation notes in the
// changelog); when the user turns "Merge consecutive visits" on, a track that
// starts within [gapMs] after the previous one ended, whose identification is
// compatible (same taxon on the same path, e.g. "Apidae" then "Bombus") and
// whose crops are of similar size (within [maxSizeRatio]) is joined to it,
// and the joined visit is identified again from all its crops. Tracks that
// overlap in time are never joined: two insects at once are two visits.
// Off by default: it changes the visit count, which is the scientific
// deliverable, so the user decides.

import 'label_pack.dart' show kRankNames;
import 'identification_store.dart' show EmbeddingRecord, ScoredTrack;
import 'track_fusion.dart' show FusedTrack;

/// Whether [b] (the later track) may be joined to the visit ending with [a].
bool canMergeVisits(ScoredTrack a, ScoredTrack b, {required int gapMs, double maxSizeRatio = 2.0, double noneThreshold = 0.5}) {
  if (a.trackIds.isEmpty || b.trackIds.isEmpty) return false;
  if (a.endMs == null || b.startMs == null) return false;
  final gap = b.startMs! - a.endMs!;
  if (gap < 0 || gap > gapMs) return false;
  final fa = a.fused, fb = b.fused;
  if (fa.identifiedRank == null || fb.identifiedRank == null) return false;
  if (fa.noneMass > noneThreshold || fb.noneMass > noneThreshold) return false;
  // Compatible = identical taxon at the shallower of the two identified ranks.
  final ia = kRankNames.indexOf(fa.identifiedRank!), ib = kRankNames.indexOf(fb.identifiedRank!);
  final rank = kRankNames[ia < ib ? ia : ib];
  final sa = fa.stepAt(rank), sb = fb.stepAt(rank);
  if (sa == null || sb == null || sa.key != sb.key) return false;
  final pa = _meanCropPx(a.crops), pb = _meanCropPx(b.crops);
  if (pa <= 0 || pb <= 0) return false;
  final ratio = pa > pb ? pa / pb : pb / pa;
  return ratio <= maxSizeRatio;
}

double _meanCropPx(List<EmbeddingRecord> crops) =>
    crops.isEmpty ? 0 : crops.map((c) => c.cropPx).reduce((x, y) => x + y) / crops.length;

/// Joins chains of mergeable tracks in [scored] (any order; sorted by start
/// time here). [refuse] identifies a joined crop set again. Tracks without a
/// track id or time span pass through unchanged.
List<ScoredTrack> mergeConsecutiveVisits(
  List<ScoredTrack> scored, {
  required int gapMs,
  required FusedTrack Function(List<EmbeddingRecord> crops) refuse,
  double maxSizeRatio = 2.0,
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
    if (chain != null && canMergeVisits(chain!, t, gapMs: gapMs, maxSizeRatio: maxSizeRatio, noneThreshold: noneThreshold)) {
      members.add(t);
      // The chain's end moves to the later track's end; its identification
      // stays the first member's until the flush re-identifies the union.
      chain = ScoredTrack(
        fused: chain!.fused,
        crops: chain!.crops,
        startMs: chain!.startMs,
        endMs: t.endMs! > chain!.endMs! ? t.endMs : chain!.endMs,
        trackIds: chain!.trackIds,
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
