// FaunaPulse (round 208): the identification job driver.
//
// Phase 1 (embedding): plan the crops of a session (crop_planner), cut them
// in a worker isolate (crop_worker), embed them through the injected
// [EmbedFn] (the native BioCLIP image tower), and append one record + one
// vector per crop to embeddings_<model>.{jsonl,bin}. Append-only, so a
// killed run resumes where it stopped. A thermal governor pauses when the
// battery gets warm (plan 5.3). Phase 2 (scoring): load the label pack, fuse
// each track's crops (track_fusion) and write the outputs
// (identification_store). Phase 2 runs in its own isolate and can be
// re-run alone with another pack ("re-score") without touching the model.
//
// Everything native or slow is injected, so the driver is unit-testable.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../logging/app_error_hooks.dart';
import '../logging/device_thermal.dart';
import '../logging/thermal_pause.dart';
import 'visit_merge.dart';
import '../logging/session_log_index.dart';
import '../postprocess/post_detector.dart' show PostDetector;
import 'crop_planner.dart';
import 'crop_worker.dart';
import 'identification_store.dart';
import 'label_pack.dart';
import 'track_fusion.dart';

/// Embeds a batch of model-input RGB buffers; returns one unit vector each.
typedef EmbedFn = Future<List<Float32List>> Function(List<Uint8List> rgb);

/// Cuts the crops of one photo (default: the isolate worker).
typedef CropFn = Future<List<CropResult>> Function(CropBatchArgs args);

class IdentifyProgress {
  /// 'planning' | 'embedding' | 'paused' | 'scoring' | 'done'
  final String stage;
  final int done;
  final int total;
  final double avgMs;
  final double? tempC;
  final String note;
  const IdentifyProgress({
    required this.stage,
    required this.done,
    required this.total,
    required this.avgMs,
    this.tempC,
    this.note = '',
  });
}

class IdentifyRunSettings {
  final String modelName;
  final String modelId;
  final String packName;
  final int inputSize;
  final int dim;
  final String accelerator;
  final double margin;
  final int minCropPx;
  final int maxCropsPerTrack;
  final double tau;
  final double noneThreshold;
  final double thermalLimitC;
  final String targetRank;
  final bool mergeVisits;
  final double mergeGapS;
  final double mergeSizeTol;
  final double mergeMinCos;
  final double flagMinDurationS;
  final int flagMinDetections;
  final double flagMinDetConf;
  final double flagMinOrderP;

  /// Round 219: crops whose certainty is below the surest crop's divided by
  /// this are left out of the pooled answer (<= 1: every crop counts).
  final double dropFactor;
  final int batchSize;
  final Map<String, dynamic> extra;

  const IdentifyRunSettings({
    required this.modelName,
    required this.modelId,
    required this.packName,
    required this.inputSize,
    required this.dim,
    required this.accelerator,
    this.margin = 0.15,
    this.minCropPx = 48,
    this.maxCropsPerTrack = 10,
    this.tau = 0.7,
    this.noneThreshold = 0.5,
    this.thermalLimitC = 40,
    this.targetRank = 'family',
    this.mergeVisits = false,
    this.mergeGapS = 3,
    this.mergeSizeTol = 0.5,
    this.mergeMinCos = 0.85,
    this.flagMinDurationS = 2,
    this.flagMinDetections = 3,
    this.flagMinDetConf = 0.2,
    this.flagMinOrderP = 0.5,
    this.dropFactor = 10,
    this.batchSize = 8,
    this.extra = const {},
  });

  Map<String, dynamic> toJson() => {
    'model': modelName,
    'model_id': modelId,
    'pack': packName,
    'input_size': inputSize,
    'dim': dim,
    'accelerator': accelerator,
    'margin': margin,
    'min_crop_px': minCropPx,
    'max_crops_per_track': maxCropsPerTrack,
    'tau': tau,
    'none_threshold': noneThreshold,
    'thermal_limit_c': thermalLimitC,
    'target_rank': targetRank,
    'merge_visits': mergeVisits,
    'merge_gap_s': mergeGapS,
    'merge_size_tol': mergeSizeTol,
    'merge_min_cos': mergeMinCos,
    'flag_min_duration_s': flagMinDurationS,
    'flag_min_detections': flagMinDetections,
    'flag_min_det_conf': flagMinDetConf,
    'flag_min_order_p': flagMinOrderP,
    'drop_factor': dropFactor,
    ...extra,
  };
}

class IdentifyResult {
  final int planned;
  final int embedded;
  final int skipped;
  final int failed;
  final int resumedDone;
  final int thermalPauses;
  final Duration elapsed;
  final bool cancelled;
  final Map<String, dynamic>? summary;
  final String? error;

  const IdentifyResult({
    required this.planned,
    required this.embedded,
    required this.skipped,
    required this.failed,
    required this.resumedDone,
    required this.thermalPauses,
    required this.elapsed,
    required this.cancelled,
    this.summary,
    this.error,
  });
}

class IdentificationJob {
  final EmbedFn embed;
  final CropFn crop;
  final ThermalFn thermal;

  /// How long the governor sleeps between temperature checks while paused.
  final Duration pausePoll;

  IdentificationJob({
    required this.embed,
    CropFn? crop,
    ThermalFn? thermal,
    this.pausePoll = const Duration(seconds: 15),
  }) : crop = crop ?? cropBatch,
       thermal = thermal ?? DeviceThermal.read;

  /// Plans the session's crops (AI session log first, post-hoc boxes as the
  /// fallback for no-AI sessions), sampled per track.
  static Future<List<CropTask>> planSession(
    Directory sessionDir, {
    required int maxCropsPerTrack,
  }) async {
    final framesDir = Directory('${sessionDir.path}/roi_frames');
    bool exists(String name) => File('${framesDir.path}/$name').existsSync();
    var tasks = <CropTask>[];
    final log = File('${sessionDir.path}/session.jsonl');
    if (log.existsSync()) {
      final index = await SessionLogIndex.build(log);
      tasks = planFromIndex(index, fileExists: exists);
    }
    if (tasks.isEmpty) {
      final post = File('${sessionDir.path}/${PostDetector.outputFileName}');
      if (post.existsSync()) {
        tasks = planFromPostDetections(await post.readAsString());
      }
    }
    tasks = tasks.where((t) => exists(t.source)).toList();
    return sampleTracks(tasks, maxCropsPerTrack);
  }

  Future<IdentifyResult> run(
    Directory sessionDir, {
    required IdentifyRunSettings settings,
    required File packFile,
    void Function(IdentifyProgress p)? onProgress,
    bool Function()? isCancelled,
    String appVersion = '',
    bool scoreAfter = true,
    bool restart = false,
  }) async {
    final started = DateTime.now();
    final paths = IdentificationPaths(sessionDir);
    paths.dir.createSync(recursive: true);
    final modelStem = stemOf(settings.modelName);
    final jsonlFile = paths.embeddingsJsonl(modelStem);
    final binFile = paths.embeddingsBin(modelStem);
    // Round 213: the caller chose to recompute every crop (e.g. after a
    // margin change, which the resume key does not see).
    if (restart) {
      if (jsonlFile.existsSync()) jsonlFile.deleteSync();
      if (binFile.existsSync()) binFile.deleteSync();
    }

    onProgress?.call(const IdentifyProgress(stage: 'planning', done: 0, total: 0, avgMs: 0));
    final tasks = await planSession(sessionDir, maxCropsPerTrack: settings.maxCropsPerTrack);

    // Resume state: an intact jsonl/bin pair is continued; anything
    // inconsistent (dim changed, rows missing, bin short) is redone.
    var existing = const EmbeddingIndex(records: [], skippedKeys: {}, dim: null, modelId: null);
    if (jsonlFile.existsSync()) {
      existing = EmbeddingIndex.parse(await jsonlFile.readAsString());
      final binLen = binFile.existsSync() ? binFile.lengthSync() : 0;
      final intact = existing.contiguous &&
          (existing.dim == null || existing.dim == settings.dim) &&
          binLen >= existing.rows * settings.dim * 4;
      if (!intact) {
        logSwallowed('identify_resume_reset', StateError('inconsistent embeddings files; starting over'));
        if (jsonlFile.existsSync()) jsonlFile.deleteSync();
        if (binFile.existsSync()) binFile.deleteSync();
        existing = const EmbeddingIndex(records: [], skippedKeys: {}, dim: null, modelId: null);
      } else if (binLen > existing.rows * settings.dim * 4) {
        // A vector was written but its record was not (kill between the two
        // appends): truncate the bin to the record count.
        final raf = binFile.openSync(mode: FileMode.append);
        raf.truncateSync(existing.rows * settings.dim * 4);
        raf.closeSync();
      }
    }
    final done = existing.doneKeys;
    // Too-small crops are retried when the threshold was lowered (round 213).
    final skippedBefore = existing.skippedFor(settings.minCropPx);
    final pending = tasks.where((t) => !done.contains(t.key) && !skippedBefore.contains(t.key)).toList();
    var nextRow = existing.rows;

    final sink = jsonlFile.openWrite(mode: FileMode.append);
    final binSink = binFile.openWrite(mode: FileMode.append);
    void writeRecord(String type, Map<String, dynamic> rec) {
      final now = DateTime.now();
      sink.writeln(jsonEncode({'type': type, 'time_ms': now.millisecondsSinceEpoch, ...rec}));
    }

    writeRecord('identify_start', {
      ...settings.toJson(),
      'crops_planned': tasks.length,
      'crops_pending': pending.length,
      'crops_done_before': done.length,
      if (appVersion.isNotEmpty) 'app_version': appVersion,
    });

    var embedded = 0, skipped = 0, failed = 0, pauses = 0;
    var cancelled = false;
    String? error;
    final clock = Stopwatch()..start();
    var embedMs = 0.0;
    var embedCount = 0;
    var lastEmit = Duration.zero;
    void emit(String stage, {double? tempC, String note = ''}) {
      final total = pending.length;
      final doneNow = embedded + skipped + failed;
      onProgress?.call(
        IdentifyProgress(
          stage: stage,
          done: doneNow,
          total: total,
          avgMs: embedCount == 0 ? 0 : embedMs / embedCount,
          tempC: tempC,
          note: note,
        ),
      );
      lastEmit = clock.elapsed;
    }

    // Group by source file so each photo is decoded once.
    final groups = <String, List<CropTask>>{};
    for (final t in pending) {
      (groups[t.source] ??= []).add(t);
    }
    final framesDir = Directory('${sessionDir.path}/roi_frames');

    try {
      emit('embedding');
      for (final entry in groups.entries) {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          break;
        }
        // Thermal governor: pause while the battery is warm. The reading is
        // also shown during normal embedding (round 210 temperature gauge).
        final warm = await waitWhileWarm(
          thermal: thermal,
          limitC: settings.thermalLimitC,
          poll: pausePoll,
          isCancelled: isCancelled,
          onPaused: (t, note) => emit('paused', tempC: t, note: note),
          errorTag: 'identify_thermal',
        );
        final temp = warm.tempC;
        if (warm.paused) {
          pauses++;
          if (isCancelled?.call() ?? false) {
            cancelled = true;
            break;
          }
        }

        final source = entry.key;
        final group = entry.value;
        List<CropResult> results;
        try {
          final bytes = await File('${framesDir.path}/$source').readAsBytes();
          results = await crop(
            CropBatchArgs(
              jpegBytes: bytes,
              requests: [for (final t in group) CropRequest(t.key, t.left, t.top, t.right, t.bottom)],
              margin: settings.margin,
              minCropPx: settings.minCropPx,
              outSize: settings.inputSize,
            ),
          );
        } catch (e) {
          logSwallowed('identify_crop', e);
          for (final t in group) {
            writeRecord('crop_skipped', {'key': t.key, 'src': t.source, 'track_id': t.trackId, 'reason': 'read_or_decode'});
            failed++;
          }
          continue;
        }
        final byKey = {for (final t in group) t.key: t};
        final toEmbed = <CropResult>[];
        for (final r in results) {
          if (r.rgb == null) {
            final t = byKey[r.key];
            writeRecord('crop_skipped', {
              'key': r.key,
              'src': t?.source,
              'track_id': t?.trackId,
              'reason': r.skipped ?? 'unknown',
              'crop_px': r.cropPx,
            });
            skipped++;
          } else {
            toEmbed.add(r);
          }
        }
        for (var i = 0; i < toEmbed.length; i += settings.batchSize) {
          final batch = toEmbed.sublist(i, (i + settings.batchSize).clamp(0, toEmbed.length));
          List<Float32List> vectors;
          final t0 = clock.elapsed;
          try {
            vectors = await embed([for (final r in batch) r.rgb!]);
          } catch (e) {
            logSwallowed('identify_embed', e);
            for (final r in batch) {
              writeRecord('crop_skipped', {'key': r.key, 'reason': 'embed_error', 'error': '$e'});
              failed++;
            }
            continue;
          }
          final dt = (clock.elapsed - t0).inMicroseconds / 1000.0;
          embedMs += dt;
          embedCount += batch.length;
          for (var j = 0; j < batch.length; j++) {
            final r = batch[j];
            final t = byKey[r.key]!;
            final v = vectors[j];
            // Vector first, then its record: a kill in between leaves an
            // orphan vector that the resume logic truncates away.
            binSink.add(vectorBytes(v));
            writeRecord('crop', EmbeddingRecord(
              key: t.key,
              source: t.source,
              photo: t.photo,
              boxSource: t.boxSource,
              trackId: t.trackId,
              box: [t.left, t.top, t.right, t.bottom],
              cropPx: r.cropPx,
              padFrac: r.padFrac,
              sharpness: r.sharpness,
              detConf: t.detConf,
              capturedAtMs: t.captureMs,
              row: nextRow,
            ).toJson());
            nextRow++;
            embedded++;
          }
        }
        // Progress is reported per PHOTO (all its crops at once), so the
        // counter can advance by more than one.
        if (clock.elapsed - lastEmit > const Duration(milliseconds: 300)) emit('embedding', tempC: temp);
      }
      emit('embedding');
    } catch (e) {
      logSwallowed('identify_run', e);
      error = '$e';
    } finally {
      writeRecord('identify_end', {
        'embedded': embedded,
        'skipped': skipped,
        'failed': failed,
        'thermal_pauses': pauses,
        'cancelled': cancelled,
        'elapsed_ms': clock.elapsedMilliseconds,
        'avg_embed_ms': embedCount == 0 ? null : embedMs / embedCount,
        'error': ?error,
      });
      await binSink.flush();
      await binSink.close();
      await sink.flush();
      await sink.close();
    }

    Map<String, dynamic>? summary;
    if (!cancelled && error == null && scoreAfter) {
      onProgress?.call(IdentifyProgress(stage: 'scoring', done: pending.length, total: pending.length, avgMs: embedCount == 0 ? 0 : embedMs / embedCount));
      try {
        summary = await scoreSession(
          sessionDir,
          modelName: settings.modelName,
          modelId: settings.modelId,
          packFile: packFile,
          settings: settings.toJson(),
          appVersion: appVersion,
        );
      } catch (e) {
        logSwallowed('identify_score', e);
        error = 'Scoring failed: $e';
      }
    }
    onProgress?.call(IdentifyProgress(stage: 'done', done: pending.length, total: pending.length, avgMs: embedCount == 0 ? 0 : embedMs / embedCount));
    return IdentifyResult(
      planned: tasks.length,
      embedded: embedded,
      skipped: skipped,
      failed: failed,
      resumedDone: done.length,
      thermalPauses: pauses,
      elapsed: DateTime.now().difference(started),
      cancelled: cancelled,
      summary: summary,
      error: error,
    );
  }

  /// The crop settings the stored embeddings of [modelName] were made with
  /// (round 213), or null when there are none. The screen compares them with
  /// the current settings before a re-run.
  static Future<EmbeddingIndex?> storedIndex(Directory sessionDir, String modelName) async {
    final f = IdentificationPaths(sessionDir).embeddingsJsonl(stemOf(modelName));
    if (!f.existsSync()) return null;
    return EmbeddingIndex.parse(await f.readAsString());
  }

  /// Phase 2 alone: fuse every track from the stored embeddings and write the
  /// outputs for [packFile]. Runs in a worker isolate (a softmax over tens of
  /// thousands of names per crop is CPU work). Returns the summary map.
  static Future<Map<String, dynamic>> scoreSession(
    Directory sessionDir, {
    required String modelName,
    required String modelId,
    required File packFile,
    required Map<String, dynamic> settings,
    String appVersion = '',
  }) {
    final sessionPath = sessionDir.path;
    final packPath = packFile.path;
    return Isolate.run(
      () => scoreSessionSync(
        Directory(sessionPath),
        modelName: modelName,
        modelId: modelId,
        packFile: File(packPath),
        settings: settings,
        appVersion: appVersion,
      ),
    );
  }

  /// Same-isolate scoring (tests, and the body of [scoreSession]).
  static Map<String, dynamic> scoreSessionSync(
    Directory sessionDir, {
    required String modelName,
    required String modelId,
    required File packFile,
    required Map<String, dynamic> settings,
    String appVersion = '',
  }) {
    final paths = IdentificationPaths(sessionDir);
    final modelStem = stemOf(modelName);
    final jsonl = paths.embeddingsJsonl(modelStem);
    if (!jsonl.existsSync()) {
      throw StateError('No embeddings for $modelName in this session yet');
    }
    final index = EmbeddingIndex.parse(jsonl.readAsStringSync());
    final pack = LabelPack.parseBytes(packFile.readAsBytesSync());
    final dim = index.dim ?? pack.dim;
    if (dim != pack.dim) {
      throw StateError('Embedding size $dim does not match the pack (${pack.dim}); the pack was built for another model');
    }
    final rows = readEmbeddingRows(paths.embeddingsBin(modelStem), index.rows, dim);

    // Track spans + ids from the session log (cheap head/tail-free parse of
    // only the record types the index keeps; done synchronously here because
    // we are already on a worker isolate).
    final spans = <int, (int, int)>{};
    final detCounts = <int, int>{};
    final log = File('${sessionDir.path}/session.jsonl');
    String deviceId = '';
    // Round 216: the session's photo schedule, so the results screen can say
    // "one photo every 1 s during the first 10 s of a track id" with the
    // real values instead of the defaults.
    double? photoStepS, photoDurationS;
    if (log.existsSync()) {
      for (final line in const LineSplitter().convert(log.readAsStringSync())) {
        if (!line.contains('"track') && !line.contains('"start_of_session"')) continue;
        Map<String, dynamic> rec;
        try {
          rec = jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        final t = (rec['time_ms'] as num?)?.toInt();
        if (rec['type'] == 'start_of_session') {
          final d = rec['device'];
          if (d is Map && d['model'] != null) deviceId = '${d['model']}';
          if (deviceId.isEmpty && rec['device_model'] != null) deviceId = '${rec['device_model']}';
          final cfg = rec['config'];
          if (cfg is Map) {
            photoStepS = (cfg['stepSeconds'] as num?)?.toDouble();
            photoDurationS = (cfg['durationSeconds'] as num?)?.toDouble();
          }
        }
        void extend(int? id) {
          if (id == null || t == null) return;
          detCounts[id] = (detCounts[id] ?? 0) + 1;
          final s = spans[id];
          spans[id] = s == null ? (t, t) : (s.$1 < t ? s.$1 : t, s.$2 > t ? s.$2 : t);
        }
        if (rec['type'] == 'detections') {
          final tracks = rec['tracks'];
          if (tracks is List) {
            for (final e in tracks) {
              if (e is Map) extend((e['track_id'] as num?)?.toInt());
            }
          }
        } else if (rec['type'] == 'detection') {
          extend((rec['track_id'] as num?)?.toInt());
        }
      }
    }

    // Group crops per track (crops without a track id stand alone).
    final groups = <String, List<EmbeddingRecord>>{};
    final order = <String>[];
    for (final r in index.records) {
      final g = r.trackId == null ? 'crop:${r.key}' : 'track:${r.trackId}';
      if (!groups.containsKey(g)) order.add(g);
      (groups[g] ??= []).add(r);
    }
    final scorer = Scorer(pack);
    final tau = (settings['tau'] as num?)?.toDouble() ?? 0.6;
    final dropFactor = (settings['drop_factor'] as num?)?.toDouble() ?? 10;
    var scored = <ScoredTrack>[];
    for (final g in order) {
      final recs = groups[g]!;
      final crops = [
        for (final r in recs)
          CropEmbedding(
            jpeg: r.source,
            trackId: r.trackId,
            vector: Float32List.sublistView(rows, r.row * dim, (r.row + 1) * dim),
          ),
      ];
      final fused = scorer.fuse(crops, tau: tau, dropFactor: dropFactor);
      final span = recs.first.trackId == null ? null : spans[recs.first.trackId!];
      final capMs = [for (final r in recs) ?r.capturedAtMs];
      scored.add(
        ScoredTrack(
          fused: fused,
          crops: recs,
          startMs: span?.$1 ?? (capMs.isEmpty ? null : capMs.reduce((a, b) => a < b ? a : b)),
          endMs: span?.$2 ?? (capMs.isEmpty ? null : capMs.reduce((a, b) => a > b ? a : b)),
          detections: recs.first.trackId == null ? null : detCounts[recs.first.trackId!],
        ),
      );
    }
    if (settings['merge_visits'] == true) {
      final gapS = (settings['merge_gap_s'] as num?)?.toDouble() ?? 3;
      final noneThreshold = (settings['none_threshold'] as num?)?.toDouble() ?? 0.5;
      scored = mergeConsecutiveVisits(
        scored,
        gapMs: (gapS * 1000).round(),
        sizeTol: (settings['merge_size_tol'] as num?)?.toDouble() ?? 0.5,
        minCos: (settings['merge_min_cos'] as num?)?.toDouble() ?? 0.85,
        noneThreshold: noneThreshold,
        refuse: (recs) => scorer.fuse(
          [
            for (final r in recs)
              CropEmbedding(
                jpeg: r.source,
                trackId: r.trackId,
                vector: Float32List.sublistView(rows, r.row * dim, (r.row + 1) * dim),
              ),
          ],
          tau: tau,
          dropFactor: dropFactor,
        ),
      );
    }
    scored.sort((a, b) {
      final ta = a.fused.trackId, tb = b.fused.trackId;
      if (ta != null && tb != null) return ta.compareTo(tb);
      return (a.startMs ?? 0).compareTo(b.startMs ?? 0);
    });
    return writeOutputs(
      paths: paths,
      packStem: stemOf(packFile.path),
      pack: pack,
      modelId: modelId,
      sessionId: sessionDir.path.split('/').last,
      deviceId: deviceId,
      tracks: scored,
      settings: settings,
      appVersion: appVersion,
      capture: {'photo_step_s': photoStepS, 'photo_duration_s': photoDurationS},
    );
  }
}
