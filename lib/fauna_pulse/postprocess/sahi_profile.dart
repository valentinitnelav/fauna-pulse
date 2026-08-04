// FaunaPulse — per-phase wall-time profile of a SAHI batch run
// (round 168, perf review E6 step 1).
//
// E6 asks whether a NATIVE tiled-image API (decode the photo once on the
// Kotlin side, crop + infer tile by tile there) would speed SAHI up. Its gate:
// build it only if tile preparation plus the JPEG round trips cost at least
// 15% of a run's wall time. Until this round the only timing was the lumped
// per-photo `infer_ms`, which cannot answer that. This profile splits each
// SAHI photo into its pipeline phases and accumulates their wall time across
// the whole run; the totals land in the run's `post_end` record ("phases").
//
// Phase map (who spends the time, and where it is measured):
//  - source_decode: JPEG → pixels of the SOURCE photo, pure Dart, measured
//    inside the tile worker's background isolate.
//  - tile_prep: cutting the tile grid out of the decoded photo and re-encoding
//    every tile back to JPEG, same isolate.
//  - tile_transfer: the tile worker's total wall time minus the two phases
//    above — isolate startup plus copying the photo bytes in and the tile
//    JPEGs out (an "isolate" is Dart's worker thread; data moves between
//    isolates by copying).
//  - tile_predict / full_predict: the native predict call per tile / per whole
//    photo. One lump on purpose: the platform-channel transfer, the NATIVE
//    JPEG re-decode and the actual inference are indistinguishable from Dart
//    (the plugin's predict response carries no timing split).
//  - merge: the IoS-NMS duplicate merge of all passes' boxes.
//
// Internally everything accumulates in MICROseconds so many sub-millisecond
// events (merge, per-tile overheads) don't round away to zero; the JSON
// reports whole milliseconds.

/// Mutable accumulator, created per batch run by the analysis screen, filled
/// by [sahiPredictFn], written out by `PostDetector.run` at `post_end`.
class SahiPhaseProfile {
  /// Photos routed through the SAHI wrapper in this run.
  int photos = 0;

  /// Photos where tiling actually ran (a photo no bigger than one tile skips
  /// tiling and gets only the plain whole-photo pass).
  int tiledPhotos = 0;

  /// Tile inferences across the run.
  int tiles = 0;

  /// Whole-photo inferences across the run.
  int fullPasses = 0;

  int sourceDecodeUs = 0;
  int tilePrepUs = 0;
  int tileTransferUs = 0;
  int tilePredictUs = 0;
  int fullPredictUs = 0;
  int mergeUs = 0;

  /// The cost tiling ADDS over a plain run that Dart can see directly (the E6
  /// gate's numerator, minus the native per-tile JPEG decode hidden inside
  /// [tilePredictUs]).
  int get tileOverheadUs =>
      sourceDecodeUs + tilePrepUs + tileTransferUs + mergeUs;

  static int _ms(int us) => (us / 1000).round();

  /// The `phases` map of the `post_end` record (documented in DATA_GUIDE §6).
  Map<String, dynamic> toJson() => {
    'photos': photos,
    'tiled_photos': tiledPhotos,
    'tiles': tiles,
    'full_passes': fullPasses,
    'source_decode_ms': _ms(sourceDecodeUs),
    'tile_prep_ms': _ms(tilePrepUs),
    'tile_transfer_ms': _ms(tileTransferUs),
    'tile_predict_ms': _ms(tilePredictUs),
    'full_predict_ms': _ms(fullPredictUs),
    'merge_ms': _ms(mergeUs),
    'tile_overhead_ms': _ms(tileOverheadUs),
  };
}
