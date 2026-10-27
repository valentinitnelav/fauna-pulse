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
import '../logging/track_source.dart';
import 'visit_merge.dart';
import '../logging/session_log_index.dart';
import '../models/field_notes.dart' show deviceNameOf, phoneModelOf;
import '../postprocess/post_detector.dart' show PostDetector;
import '../postprocess/video_tracker.dart' show KeepFramesSettings, VideoTracker;
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

  /// Round 319, part 2: time spent on the crops since the first one, heat pauses left out (the
  /// time left on the Identify screen; counted with the pause it grew while nothing ran).
  final int activeMs;
  const IdentifyProgress({
    required this.stage,
    required this.done,
    required this.total,
    required this.avgMs,
    this.tempC,
    this.note = '',
    this.activeMs = 0,
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

  /// Round 262: false = crops keep the box shape (stretched to the input).
  final bool squareCrops;
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
    this.margin = kDefaultCropMargin,
    this.squareCrops = true,
    this.minCropPx = 48,
    this.maxCropsPerTrack = 10,
    this.tau = 0.7,
    this.noneThreshold = 0.5,
    this.thermalLimitC = kDefaultPauseTempC,
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
    'square_crops': squareCrops,
    'min_crop_px': minCropPx,
    'max_crops_per_track': maxCropsPerTrack,
    'tau': tau,
    'none_threshold': noneThreshold,
    'thermal_limit_c': thermalLimitC,
    'target_rank': targetRank,
    'merge_track_ids': mergeVisits, // "merge_visits" before round 248
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

  /// Round 319, part 2: the part of [failed] whose photos could not be read (not a model error;
  /// the store counts these as done, so a re-run does not try them again).
  final int unreadable;
  final int resumedDone;
  final int thermalPauses;
  final Duration elapsed;

  /// Round 319, part 3: the heat pauses' share of [elapsed].
  final Duration pausedTime;

  /// Round 250: time spent inside the model calls alone (what "s per crop"
  /// reports); [elapsed] also covers reading the photos and scoring.
  final Duration modelTime;
  final bool cancelled;
  final Map<String, dynamic>? summary;
  final String? error;

  const IdentifyResult({
    required this.planned,
    required this.embedded,
    required this.skipped,
    required this.failed,
    this.unreadable = 0,
    required this.resumedDone,
    required this.thermalPauses,
    required this.elapsed,
    this.pausedTime = Duration.zero,
    this.modelTime = Duration.zero,
    required this.cancelled,
    this.summary,
    this.error,
  });

  /// The whole run's time per identified crop (photos read, scoring), heat pauses left out as in
  /// the time left (round 319, part 2): what the next run's estimate on the Identify page uses.
  double get msPerCrop => (elapsed - pausedTime).inMilliseconds / embedded;
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
        tasks = planFromPostDetections(utf8.decode(await post.readAsBytes(), allowMalformed: true));
      }
    }
    tasks = tasks.where((t) => exists(t.source)).toList();
    return sampleTracks(tasks, maxCropsPerTrack);
  }

  /// Session folders with a job running now. Two jobs on one session would
  /// both append to `embeddings_<model>.jsonl/.bin`, each numbering rows from
  /// what it read at its start: lines tear and a row is used twice, yet both
  /// report success. Keyed by session, not session + model, because the
  /// native embedder is one shared instance.
  static final Set<String> _activeSessions = {};

  /// Throws (plain words, shown by the Identify screen) when [sessionDir]
  /// already has a job running, for example after Back and Start again.
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
    final key = sessionDir.absolute.path;
    // Checked and added with no await between, so two calls cannot both pass.
    if (!_activeSessions.add(key)) {
      throw Exception('This session is already being identified. Wait for that run to finish, or cancel it first.');
    }
    try {
      return await _run(
        sessionDir,
        settings: settings,
        packFile: packFile,
        onProgress: onProgress,
        isCancelled: isCancelled,
        appVersion: appVersion,
        scoreAfter: scoreAfter,
        restart: restart,
      );
    } finally {
      _activeSessions.remove(key);
    }
  }

  Future<IdentifyResult> _run(
    Directory sessionDir, {
    required IdentifyRunSettings settings,
    required File packFile,
    void Function(IdentifyProgress p)? onProgress,
    bool Function()? isCancelled,
    required String appVersion,
    required bool scoreAfter,
    required bool restart,
  }) async {
    final started = DateTime.now();
    final paths = IdentificationPaths(sessionDir);
    paths.dir.createSync(recursive: true);
    final modelStem = stemOf(settings.modelName);
    final jsonlFile = paths.embeddingsJsonl(modelStem);
    final binFile = paths.embeddingsBin(modelStem);
    // Round 213: the caller chose to recompute every crop (e.g. after a
    // margin or crop shape change, which the resume key does not see).
    if (restart) {
      if (jsonlFile.existsSync()) jsonlFile.deleteSync();
      if (binFile.existsSync()) binFile.deleteSync();
    }

    onProgress?.call(const IdentifyProgress(stage: 'planning', done: 0, total: 0, avgMs: 0));
    final tasks = await planSession(sessionDir, maxCropsPerTrack: settings.maxCropsPerTrack);
    // Round 234: visits found in videos are numbered anew by each "Find
    // visits"; crops stored under the old numbers can't be continued.
    final visitsRunId = await currentVisitsRunId(sessionDir);

    // Resume state: an intact jsonl/bin pair is continued; anything
    // inconsistent (dim changed, rows missing, bin short) is redone.
    var existing = const EmbeddingIndex(records: [], skippedKeys: {}, dim: null, modelId: null);
    if (jsonlFile.existsSync()) {
      // allowMalformed here and in the reads below: a kill can leave the last
      // line cut inside a multi-byte letter; readAsString would throw before
      // the parser skips that torn line, and resume / scoring would fail.
      existing = EmbeddingIndex.parse(utf8.decode(await jsonlFile.readAsBytes(), allowMalformed: true));
      final binLen = binFile.existsSync() ? binFile.lengthSync() : 0;
      final intact = existing.contiguous &&
          (existing.dim == null || existing.dim == settings.dim) &&
          binLen >= existing.rows * settings.dim * 4;
      final renumbered = existing.visitsRunId != visitsRunId;
      if (!intact || renumbered) {
        logSwallowed(
          'identify_resume_reset',
          StateError(
            renumbered ? 'track IDs were found again since; starting over' : 'inconsistent embeddings files; starting over',
          ),
        );
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
      'track_ids_run_id': ?visitsRunId, // "visits_run_id" before round 248
      if (appVersion.isNotEmpty) 'app_version': appVersion,
    });

    var embedded = 0, skipped = 0, failed = 0, unreadable = 0, pauses = 0;
    var cancelled = false;
    String? error;
    final clock = Stopwatch()..start();
    // Heat pauses so far, and the start of the one going on (left out of activeMs).
    var paused = Duration.zero;
    Duration? pauseFrom;
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
          activeMs: ((pauseFrom ?? clock.elapsed) - paused).inMilliseconds,
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
          onPaused: (t, note) {
            pauseFrom ??= clock.elapsed;
            emit('paused', tempC: t, note: note);
          },
          errorTag: 'identify_thermal',
        );
        if (pauseFrom != null) {
          paused += clock.elapsed - pauseFrom!;
          pauseFrom = null;
        }
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
              square: settings.squareCrops,
              minCropPx: settings.minCropPx,
              outSize: settings.inputSize,
            ),
          );
        } catch (e) {
          logSwallowed('identify_crop', e);
          for (final t in group) {
            writeRecord('crop_skipped', {'key': t.key, 'src': t.source, 'track_id': t.trackId, 'reason': 'read_or_decode'});
            failed++;
            unreadable++;
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
        'unreadable': unreadable,
        'thermal_pauses': pauses,
        'cancelled': cancelled,
        'elapsed_ms': clock.elapsedMilliseconds,
        'paused_ms': paused.inMilliseconds,
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
      unreadable: unreadable,
      resumedDone: done.length,
      thermalPauses: pauses,
      elapsed: DateTime.now().difference(started),
      pausedTime: paused,
      modelTime: Duration(microseconds: (embedMs * 1000).round()),
      cancelled: cancelled,
      summary: summary,
      error: error,
    );
  }

  /// The `run_id` of the "Find visits" run whose numbers a session's visits
  /// carry now, for visits found afterwards in videos; null for visits
  /// tracked live (their numbers never change). Round 235.
  static Future<int?> currentVisitsRunId(Directory sessionDir) async =>
      trackSourceOf(sessionDir) == TrackSource.afterwards ? (await VideoTracker.readSummary(sessionDir))?.runId : null;

  /// The stored crops of [modelName] carry visit numbers of an earlier "Find
  /// visits" run: re-scoring them would pair answers with the wrong visits,
  /// and the next run starts over (round 235).
  static Future<bool> cropsOutdated(Directory sessionDir, String modelName) async {
    final stored = await storedIndex(sessionDir, modelName);
    return stored != null && stored.visitsRunId != await currentVisitsRunId(sessionDir);
  }

  /// The crop settings the stored embeddings of [modelName] were made with
  /// (round 213), or null when there are none. The screen compares them with
  /// the current settings before a re-run.
  static Future<EmbeddingIndex?> storedIndex(Directory sessionDir, String modelName) async {
    final f = IdentificationPaths(sessionDir).embeddingsJsonl(stemOf(modelName));
    if (!f.existsSync()) return null;
    return EmbeddingIndex.parse(utf8.decode(await f.readAsBytes(), allowMalformed: true));
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
    final index = EmbeddingIndex.parse(utf8.decode(jsonl.readAsBytesSync(), allowMalformed: true));
    final pack = LabelPack.parseBytes(packFile.readAsBytesSync());
    final dim = index.dim ?? pack.dim;
    if (dim != pack.dim) {
      throw StateError('Embedding size $dim does not match the pack (${pack.dim}); the pack was built for another model');
    }
    final rows = readEmbeddingRows(paths.embeddingsBin(modelStem), index.rows, dim);

    // Track spans + ids from the session log (cheap head/tail-free parse of
    // only the record types the index keeps; done synchronously here because
    // we are already on a worker isolate). Round 229: visits found afterwards
    // in a session's videos come from post_tracks.jsonl instead (never both);
    // the start record always comes from session.jsonl. Round 305: spans and
    // frame counts follow the summary's rule (TrackSpans): from the first
    // sighting, as in track_ids.csv.
    final trackSpans = TrackSpans();
    int? sessionStartMs;
    final log = File('${sessionDir.path}/session.jsonl');
    final tracksFile = tracksFileOf(sessionDir);
    String deviceId = '', phoneModel = '';
    var startSeen = false;
    // Round 216: the session's photo schedule, so the results screen can say
    // "one photo every 1 s during the first 10 s of a track id" with the
    // real values instead of the defaults.
    double? photoStepS, photoDurationS;
    // Round 234: visits found in videos keep their frames by the rule of
    // their "Find visits" run (post_track_start), whose run_id the results
    // screen compares with the current one.
    int? visitsRunId;
    KeepFramesSettings? keep;
    for (final file in tracksFile.path == log.path ? [log] : [log, tracksFile]) {
      if (!file.existsSync()) continue;
      final readTracks = file.path == tracksFile.path;
      for (final line in const LineSplitter().convert(utf8.decode(file.readAsBytesSync(), allowMalformed: true))) {
        if (!line.contains('"track') &&
            !line.contains('"start_of_session"') &&
            !line.contains('"post_track_start"')) {
          continue;
        }
        Map<String, dynamic> rec;
        try {
          rec = jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        if (rec['type'] == 'start_of_session') {
          sessionStartMs ??= (rec['time_ms'] as num?)?.toInt();
          // Round 335: the device's name (the Device ID field, FaunaLapse phone ID, phone model;
          // deviceNameOf), as fauna-pulse-export writes it for insect-detect-post. Only the first start
          // record counts: the app writes it as line 1, which the export's read_start reads too.
          if (!startSeen) {
            deviceId = deviceNameOf(rec);
            phoneModel = phoneModelOf(rec) ?? '';
          }
          startSeen = true;
          final cfg = rec['config'];
          if (cfg is Map) {
            photoStepS = (cfg['stepSeconds'] as num?)?.toDouble();
            photoDurationS = (cfg['durationSeconds'] as num?)?.toDouble();
          }
        }
        if (readTracks && rec['type'] == 'post_track_start') {
          visitsRunId = (rec['run_id'] as num?)?.toInt();
          keep = KeepFramesSettings.fromJson(rec['keep_frames']);
        }
        if (readTracks) trackSpans.add(rec);
      }
    }
    final spans = trackSpans.spans(notBeforeMs: sessionStartMs);
    final detCounts = trackSpans.frameCounts;

    // Round 235: crops cut for visits that were found again since carry the
    // old numbers; scoring them against the new visits would mismatch both.
    if (visitsRunId != index.visitsRunId) {
      throw StateError(
        'The track IDs were found again since these crops were made. Run identification again '
        '("Continue / re-run"); it starts over by itself.',
      );
    }

    // Round 313: "Smallest box to identify" and "Crops per track ID" also
    // apply to crops embedded by an earlier run (Continue, Re-score): before,
    // raising the one or lowering the other changed nothing for a session
    // already identified, while the results named the new values.
    final records = cropsForScoring(
      index.records,
      minCropPx: (settings['min_crop_px'] as num?)?.toInt() ?? 0,
      maxPerTrack: (settings['max_crops_per_track'] as num?)?.toInt() ?? 0,
    );

    // Group crops per track (crops without a track id stand alone).
    final groups = <String, List<EmbeddingRecord>>{};
    final order = <String>[];
    for (final r in records) {
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
    if ((settings['merge_track_ids'] ?? settings['merge_visits']) == true) {
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
      phoneModel: phoneModel,
      tracks: scored,
      settings: settings,
      appVersion: appVersion,
      capture: {
        'photo_step_s': keep?.stepSeconds ?? photoStepS,
        'photo_duration_s': keep?.durationSeconds ?? photoDurationS,
        'track_ids_run_id': ?visitsRunId, // "visits_run_id" before round 248
      },
    );
  }
}

/// The stored crops a scoring uses (round 313): at least [minCropPx] wide, and
/// at most [maxPerTrack] per track ID (0 = all), the largest boxes, as the
/// crop planner picks them (crop_planner.dart `sampleTracks`). Crops without a
/// track ID are never dropped by the count. Keeps the stored order.
List<EmbeddingRecord> cropsForScoring(List<EmbeddingRecord> records, {int minCropPx = 0, int maxPerTrack = 0}) {
  final big = [for (final r in records) if (r.cropPx >= minCropPx) r];
  if (maxPerTrack <= 0) return big;
  double area(EmbeddingRecord r) =>
      r.box.length < 4 ? 0 : (r.box[2] - r.box[0]).clamp(0, 1) * (r.box[3] - r.box[1]).clamp(0, 1);
  final byTrack = <int, List<EmbeddingRecord>>{};
  for (final r in big) {
    if (r.trackId != null) (byTrack[r.trackId!] ??= []).add(r);
  }
  final keep = <EmbeddingRecord>{};
  for (final list in byTrack.values) {
    keep.addAll(list.length <= maxPerTrack ? list : ([...list]..sort((a, b) => area(b).compareTo(area(a)))).take(maxPerTrack));
  }
  return [
    for (final r in big)
      if (r.trackId == null || keep.contains(r)) r,
  ];
}
