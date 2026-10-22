// FaunaPulse (round 319): one identification run of one session, apart from the screen.
//
// Stress test 2026-10-20 (report item 5): with "Also identify them" on, the Find screens opened
// "Identify organisms" and that page started the run. A page is built only in a frame, and
// Flutter draws no frames while the app is in the background, so the identification waited
// until the app was shown again. Now a Find screen starts the run here ([autoStart]) when its
// own job ends, and the Identify page only shows it: it attaches to the run of its session
// ([of]); Back on the page still asks and stops it.
//
// Moved unchanged from identification_screen.dart: the model lock ([takeModel]: the app has ONE
// native model), loading the model, the IdentificationJob run, closing the model, the screen-on
// lock. The analysis service (AnalysisKeepAlive) is held from the start to the end of the run.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../logging/app_error_hooks.dart';
import '../services/analysis_keepalive.dart';
import 'identification_assets.dart';
import 'identification_choice.dart';
import 'identification_job.dart';
import 'identification_store.dart' show stemOf;
import 'identify_wait_note.dart';

/// Why the chosen model and name list cannot run together, before anything is loaded (round
/// 266); null when they may. The embedding size is checked again once the model is loaded.
String? pairingProblem(IdentificationChoice choice, String modelName) {
  final h = choice.packHeader;
  if (h == null) return null;
  final owner = '${h['model_id']}';
  if (choice.isClassList && owner != stemOf(modelName)) {
    return 'The class list ${h['pack_id']} belongs to the model $owner.tflite. Choose that model, '
        'or a name list made for $modelName.';
  }
  return null;
}

/// Round 213: the resume key (photo, track, box) does not see the crop margin (nor, round 262,
/// the crop shape), so stored vectors cut another way would silently be reused. True = start
/// over, false = keep the stored crops, null = the user must choose (the stored crops were cut
/// with other settings; the Identify screen asks).
Future<bool?> cropSettingsRestart(Directory sessionDir, IdentifyPrefs prefs, String modelName) async {
  // Crops of visits found again since are redone anyway (round 235).
  if (await IdentificationJob.cropsOutdated(sessionDir, modelName)) return true;
  final stored = await IdentificationJob.storedIndex(sessionDir, modelName);
  if (stored == null || stored.records.isEmpty || stored.margin == null) return false;
  if ((stored.margin! - prefs.margin).abs() < 1e-6 && stored.squareCrops == prefs.squareCrops) return false;
  return null;
}

/// Round 319, part 2 (owner's decision of 2026-10-21): free memory that must be left over after
/// an "Also identify them" model loads in the background, on top of Android's own threshold.
/// It covers the error of the estimate; see [identifyFitsInBackground]. The same for every phone
/// size: users are told to keep the app on the screen during identification.
const int kIdentifyMemoryMarginBytes = 100 << 20;

/// The free memory counted on: the smaller of Android's availMem and the kernel's MemAvailable
/// (availMem can count page cache that cannot be freed; MemAvailable is what the tests logged).
int identifyFreeBytes(ImageEmbedderMemory m) =>
    m.memAvailable >= 0 && m.memAvailable < m.availMem ? m.memAvailable : m.availMem;

/// Whether the model fits while the app is in the background. On the 3.6 GB test phone Android
/// ended the app at the start of every such load of BioCLIP 2 on the CPU (0.96 and 1.08 GB free,
/// about 1.31 GB needed); the same model started with the app in front ran to the end, also in
/// the background later, with 0.19 to 0.33 GB left free. With this rule (measured, and accepted)
/// that phone waits every time (0.94 to 1.25 GB free, Android's threshold 471 MB); a 7.4 GB phone
/// waited once on the CPU, by 23 MB (1542 MB free; it loaded at 1671 MB), and waits on the GPU
/// (about 2.7 GB estimated).
bool identifyFitsInBackground(ImageEmbedderMemory m) =>
    identifyFreeBytes(m) - m.needBytes >= m.threshold + kIdentifyMemoryMarginBytes;

class IdentificationRun extends ChangeNotifier {
  IdentificationRun._(this.sessionDir, this._keepAlive, {String? chain, int attempts = 0})
      : _chain = chain,
        _attempts = attempts,
        _noted = attempts > 0;

  final Directory sessionDir;

  /// For the note that keeps a chained run when Android closes the app ([IdentifyWaitNote]): the
  /// Find screen that started it, and how often the note started it again.
  final String? _chain;
  final int _attempts;

  /// A note of this run may be on disk; the run's end deletes it.
  bool _noted;

  /// Released while the run waits for the app (round 319, part 2) and taken anew after.
  AnalysisKeepAliveHold _keepAlive;

  // The app has ONE native model (ImageEmbedder: load replaces it, close releases it for every
  // caller). A run left going by Back, or a speed test, must end (close the model, switch the
  // screen-on lock off, close its files) before the next run or test loads; otherwise its end
  // cuts the next run, or both write into one session folder. The returned function MUST be
  // called when done, or later starts wait forever. Null when free: an idle app holds no
  // Future (widget tests run each test in its own zone; an old zone's Future never completes).
  static Completer<void>? _modelInUse;

  static Future<void Function()> takeModel() async {
    // A loop, not one await: when several starts wait, only the first to wake takes the model.
    while (_modelInUse != null) {
      await _modelInUse!.future;
    }
    final mine = _modelInUse = Completer<void>();
    return () {
      _modelInUse = null;
      mine.complete();
    };
  }

  /// The run of each session folder that a page should show: going on, or ended while no page
  /// showed it (a run started in the background). A stopped run is not shown.
  static final Map<String, IdentificationRun> _runs = {};

  static IdentificationRun? of(Directory sessionDir) {
    final r = _runs[sessionDir.path];
    return r == null || r._cancel ? null : r;
  }

  /// A run, or a speed test, is going on (the model is taken or a run has not ended).
  static bool get busy => _modelInUse != null || _runs.values.any((r) => !r.finished);

  /// Starts a run with what the Identify screen chose (after its questions).
  static IdentificationRun start(
    Directory sessionDir, {
    required File model,
    required File pack,
    required Map<String, dynamic>? packHeader,
    required bool isClassList,
    required IdentifyPrefs prefs,
    required bool restart,
  }) {
    final run = _register(sessionDir);
    unawaited(run._go(model: model, pack: pack, packHeader: packHeader, isClassList: isClassList, prefs: prefs, restart: restart));
    return run;
  }

  /// "Also identify them" (round 274): the run that a Find screen starts when its job ends, with
  /// the model, name list and settings remembered for Identify organisms. Holds the analysis
  /// service from this call on (the caller releases its own hold after it). Ends as [declined]
  /// when there is nothing to identify or a question must be asked first; the Identify page then
  /// does what it did before (it says why, or asks, once it is shown). [chain] ("videos" or
  /// "photos") and [attempts] (1 when Home starts it again from a note) go into the note.
  static IdentificationRun autoStart(Directory sessionDir, {String? chain, int attempts = 0}) {
    final going = of(sessionDir);
    if (going != null && !going.finished) return going;
    final run = _register(sessionDir, chain: chain, attempts: attempts);
    unawaited(run._prepare());
    return run;
  }

  static IdentificationRun _register(Directory sessionDir, {String? chain, int attempts = 0}) {
    // Taken at once, while the caller still holds its own: no stop in between (round 319, L4a).
    final run = IdentificationRun._(
      sessionDir,
      AnalysisKeepAlive.acquire(title: kIdentifyKeepAliveTitle),
      chain: chain,
      attempts: attempts,
    );
    _runs[sessionDir.path] = run;
    return run;
  }

  /// Forgets every run (tests only).
  @visibleForTesting
  static void resetForTest() => _runs.clear();

  bool _cancel = false;
  bool get cancelRequested => _cancel;

  /// Stops the job at its next check (after the current photo); what is done is kept.
  void cancel() {
    if (_cancel || finished) return;
    _cancel = true;
    _inFront?.complete(); // a run waiting for the app ends at once
    notifyListeners();
  }

  /// Round 319, part 2: the run waits until the app is in front, as the model does not fit in
  /// the free memory while it is in the background ([_waitForApp]).
  bool waitingForApp = false;
  Completer<void>? _inFront;

  /// What the memory check before the load found, for the identify_start record; null when no
  /// check ran (the app was in front).
  Map<String, dynamic>? _memoryCheck;

  static bool get _appInFront => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// [autoStart] found no reason to run, or a question to ask first; nothing was loaded.
  bool declined = false;

  /// True until the model is loaded (also while [autoStart] reads the settings).
  bool loadingModel = false;
  IdentifyProgress? progress;
  String accelerator = '';

  /// Round 211: why the GPU was not used (null when it was, or was not asked for).
  String? accelNote;
  DateTime? started;

  /// Round 250: how long the whole run took, model loading included (the "Elapsed" clock).
  Duration? took;
  IdentifyResult? result;
  Object? failure;

  /// The time per crop of this run, stored for the next estimate.
  double? msPerCrop;

  final _done = Completer<void>();
  bool get finished => _done.isCompleted;
  Future<void> get done => _done.future;

  /// Called by the page that shows this run: once it has seen the end, the run is forgotten.
  void seen() {
    if (finished && _runs[sessionDir.path] == this) _runs.remove(sessionDir.path);
  }

  Future<void> _prepare() async {
    try {
      final prefs = await IdentifyPrefs.load();
      final choice = await IdentificationChoice.load(modelName: prefs.modelName, packName: prefs.packName);
      final model = choice.model, pack = choice.pack;
      if (model != null && pack != null && !_cancel) {
        final modelName = model.path.split('/').last;
        final tasks = await IdentificationJob.planSession(sessionDir, maxCropsPerTrack: prefs.maxCropsPerTrack);
        if (tasks.isNotEmpty && pairingProblem(choice, modelName) == null) {
          final restart = await cropSettingsRestart(sessionDir, prefs, modelName);
          if (restart != null && !_cancel) await _checkMemory(model, prefs.useGpu);
          if (restart != null && !_cancel) {
            return await _go(
              model: model,
              pack: pack,
              packHeader: choice.packHeader,
              isClassList: choice.isClassList,
              prefs: prefs,
              restart: restart,
            );
          }
        }
      }
    } catch (e) {
      logSwallowed('identify_auto_start', e);
    }
    declined = true;
    await _end();
  }

  /// Round 319, part 2: on a 3.6 GB phone Android ended the app 3 s into loading BioCLIP 2 when
  /// "Also identify them" started it in the background (the analysis service keeps the app alive,
  /// but not through a 1.3 GB load). So, while the app is not in front, the model loads only when
  /// it fits in the free memory; otherwise the run gives the service up, shows the "Animals
  /// found" notification and waits until the app is in front. Unknown memory: it goes on as
  /// before.
  Future<void> _checkMemory(File model, bool useGpu) async {
    if (_appInFront) return;
    // From here Android may close the app (during the wait, or during the load in the background):
    // the note lets the next opening start the run again. The run's end deletes it, so a kill
    // during the load that follows a wait is covered too.
    _noted = true;
    await IdentifyWaitNote.write(sessionDir, chain: _chain, attempts: _attempts);
    ImageEmbedderMemory? m;
    try {
      m = await ImageEmbedder.memory(model.path, useGpu: useGpu);
    } catch (e) {
      logSwallowed('identify_memory_check', e);
    }
    if (m == null) return;
    const mb = 1 << 20;
    final fits = identifyFitsInBackground(m);
    _memoryCheck = {
      'need_mb': m.needBytes ~/ mb,
      'model_mb': m.fileBytes ~/ mb,
      'on_gpu': m.onGpu,
      'free_mb': identifyFreeBytes(m) ~/ mb,
      'avail_mem_mb': m.availMem ~/ mb,
      'mem_available_mb': m.memAvailable < 0 ? null : m.memAvailable ~/ mb,
      'threshold_mb': m.threshold ~/ mb,
      'margin_mb': kIdentifyMemoryMarginBytes ~/ mb,
      'total_mb': m.totalMem ~/ mb,
      'low_memory': m.lowMemory,
      'decision': fits ? 'load' : 'wait_for_app',
    };
    debugPrint('identify_memory_check: $_memoryCheck');
    // Back in front while the numbers were read: it loads now, as with the app in front.
    if (fits || _appInFront) return;
    await _waitForApp();
  }

  Future<void> _waitForApp() async {
    final waitStarted = DateTime.now();
    final inFront = _inFront = Completer<void>();
    final listener = _OnResume(() {
      if (!inFront.isCompleted) inFront.complete();
    });
    WidgetsBinding.instance.addObserver(listener);
    waitingForApp = true;
    notifyListeners();
    // The results of the Find job are saved; Android may close the app now, as it may any app in
    // the background. The service would not keep it alive through the load anyway.
    _keepAlive.release();
    await AnalysisKeepAlive.showIdentifyReminder();
    if (_appInFront && !inFront.isCompleted) inFront.complete(); // came back meanwhile
    await inFront.future;
    WidgetsBinding.instance.removeObserver(listener);
    _inFront = null;
    waitingForApp = false;
    await AnalysisKeepAlive.cancelIdentifyReminder();
    _memoryCheck?['waited_s'] = DateTime.now().difference(waitStarted).inSeconds;
    debugPrint('identify_memory_check: ${_cancel ? 'stopped while waiting' : 'the app is in front, the run starts'}');
    if (!_cancel) {
      // The app is in front: Android allows the service to start again.
      _keepAlive = AnalysisKeepAlive.acquire(title: kIdentifyKeepAliveTitle);
    }
    notifyListeners();
  }

  Future<void> _go({
    required File model,
    required File pack,
    required Map<String, dynamic>? packHeader,
    required bool isClassList,
    required IdentifyPrefs prefs,
    required bool restart,
  }) async {
    started = DateTime.now();
    loadingModel = true;
    notifyListeners();
    final modelName = model.path.split('/').last;
    IdentifyResult? r;
    // Waits ("Loading the model") while an earlier run or speed test still ends.
    final freeModel = await takeModel();
    // Round 320: should Android close the app during the run (most often after the user left it),
    // the next opening says that the identification did not finish and how to continue. Attempts
    // 1: nothing starts by itself, as the user saw the run going. The note of a chained run that
    // went on in the background ([_checkMemory], attempts 0) is kept: that run starts again once.
    // Written once the model is taken: the app has one note, and it is about the run that loads.
    if (!_noted) {
      _noted = true;
      await IdentifyWaitNote.write(sessionDir, chain: _chain, attempts: 1);
    }
    try {
      await WakelockPlus.enable();
      final info = await ImageEmbedder.load(
        model.path,
        useGpu: prefs.useGpu,
        cpuThreads: prefs.cpuThreads,
        normalize: !isClassList, // a classifier's raw class scores (round 266)
      );
      final packDim = (packHeader?['dim'] as num?)?.toInt();
      if (packDim != null && packDim != info.dim) {
        throw Exception(
          'The name list ${pack.path.split('/').last} was made for another model and does not work with '
          '$modelName. Choose the name list made for this model, or the model that list was made for.',
        );
      }
      loadingModel = false;
      accelerator = info.accelerator;
      accelNote = info.accelerationNote;
      notifyListeners();
      // Back while the model loaded (the page set cancel): no crop is started.
      if (!_cancel) {
        final pinfo = await PackageInfo.fromPlatform();
        final job = IdentificationJob(
          embed: (List<Uint8List> rgb) async {
            final b = await ImageEmbedder.embed(rgb);
            return [for (var i = 0; i < b.count; i++) Float32List.fromList(b.vector(i))];
          },
        );
        r = await job.run(
          sessionDir,
          settings: IdentifyRunSettings(
            modelName: modelName,
            modelId: stemOf(modelName),
            packName: pack.path.split('/').last,
            inputSize: info.inputWidth,
            dim: info.dim,
            accelerator: info.accelerator,
            margin: prefs.margin,
            squareCrops: prefs.squareCrops,
            minCropPx: prefs.minCropPx,
            maxCropsPerTrack: prefs.maxCropsPerTrack,
            tau: prefs.tau,
            noneThreshold: prefs.noneThreshold,
            thermalLimitC: prefs.thermalLimitC,
            targetRank: prefs.targetRank,
            mergeVisits: prefs.mergeVisits,
            mergeGapS: prefs.mergeGapS,
            mergeSizeTol: prefs.mergeSizeTol,
            mergeMinCos: prefs.mergeMinCos,
            flagMinDurationS: prefs.flagMinDurationS,
            flagMinDetections: prefs.flagMinDetections,
            flagMinDetConf: prefs.flagMinDetConf,
            flagMinOrderP: prefs.flagMinOrderP,
            dropFactor: prefs.dropFactor,
            extra: {
              'use_gpu': prefs.useGpu,
              'cpu_threads': prefs.cpuThreads,
              'cpu_threads_used': ?info.cpuThreads,
              // Round 242: why the GPU was not used, and how closely it matched the CPU.
              'gpu_note': ?info.accelerationNote,
              'gpu_agreement': ?info.gpuAgreement,
              // Round 319, part 2: the free-memory check before a load in the background.
              'memory_check': ?_memoryCheck,
            },
          ),
          packFile: pack,
          appVersion: '${pinfo.version}+${pinfo.buildNumber}',
          restart: restart,
          isCancelled: () => _cancel,
          onProgress: (p) {
            progress = p;
            notifyListeners();
          },
        );
        if (r.embedded > 0) {
          final sp = await SharedPreferences.getInstance();
          final wallMs = r.msPerCrop;
          await sp.setDouble(IdentifyPrefs.msPerCropKey(modelName), wallMs);
          msPerCrop = wallMs;
        }
      }
    } catch (e) {
      logSwallowed('identify_start', e);
      failure = e;
    } finally {
      // Round 320: the note goes while this run still holds the model. A run queued behind it
      // (Stop or Back, then Start again) writes its own note once it has the model, and a later
      // clear could delete that one (clear matches the session folder only, and reads and
      // deletes in two steps). The results are saved here, so a kill during the close below
      // leaves nothing to report.
      if (_noted) {
        _noted = false;
        await IdentifyWaitNote.clear(sessionDir);
      }
      try {
        await ImageEmbedder.close();
      } catch (e) {
        logSwallowed('identify_close', e);
      }
      try {
        await WakelockPlus.disable();
      } finally {
        freeModel(); // only after close and lock off, so the next run starts clean
      }
    }
    took = DateTime.now().difference(started!);
    result = r;
    loadingModel = false;
    await _end();
  }

  Future<void> _end() async {
    // A run that never had the model (declined, or stopped while it waited) still has its note
    // here. It goes before the service: without the service Android may close the app at once
    // (0.17 s after the model closed on the 3.6 GB phone), and the next opening would then report
    // an ended run as stopped (round 320).
    if (_noted) await IdentifyWaitNote.clear(sessionDir);
    _keepAlive.release();
    // Kept for the page only when no page showed it yet and it was not stopped.
    if (_runs[sessionDir.path] == this && (_cancel || declined || hasListeners)) _runs.remove(sessionDir.path);
    _done.complete();
    notifyListeners();
  }
}

/// Calls [onResume] each time the app comes to the front.
class _OnResume with WidgetsBindingObserver {
  _OnResume(this.onResume);

  final void Function() onResume;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}
