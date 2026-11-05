// FaunaPulse, session settings sheet: the AI tab (model, confidence, engine, tracker, live video).
//
// A `part` of settings_sheet.dart: that sheet's State class is split into
// extensions, one file per tab, so each file stays readable while the private
// fields stay shared (Dart privacy is per library, and a part file belongs to
// the main file's library). Fields, getters and the lifecycle overrides stay
// in the main file; part files hold methods only.
//
// The extensions below are the State's own code, so calling setState here is
// correct; the analyzer cannot tell an extension from outside code.
// ignore_for_file: invalid_use_of_protected_member

part of '../settings_sheet.dart';

extension _SettingsAiTab on _SettingsSheetState {
  // --- Tab 2: AI pipeline -------------------------------------------------

  Widget _aiPipelineTab() {
    final model = _selectedModel;
    // Built as a plain list so the no-AI branch below can reuse it: in the
    // motion and time-lapse capture modes none of these settings has any
    // effect (the detector never runs), so the whole tab is shown greyed and
    // read-only under a notice instead of pretending to be editable (r147).
    final children = <Widget>[
      // HelpRow (not HelpLabel) so the expanded helper spans the full sheet
      // width instead of the narrow column left of the two buttons.
      HelpRow(
        helperText:
            'The detection model that finds animals in the camera image and '
            'draws a box around each one. Add or delete models with Download & '
            'import models… (also in the home screen\'s Menu). '
            'The input resolution shown under the list is the square size '
            'every camera frame is shrunk to for the model: smaller runs '
            'faster, larger sees tiny insects better.',
        // Round 240: buttons wrap under the label (two in one row with it
        // overflowed a 360-px-wide phone by 42 px); one since round 267.
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _label('Detection model'),
            manageModelsButton(
              onPressed: _modelsLoading ? null : _manageModels,
            ),
          ],
        ),
      ),
      if (_modelsLoading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text('Scanning models…', style: TextStyle(color: Colors.white70)),
            ],
          ),
        )
      else
        DropdownButton<String>(
          value: _models.any((m) => m.id == _c.modelPath) ? _c.modelPath : null,
          isExpanded: true,
          dropdownColor: Colors.black87,
          // Variable height so long names can wrap onto several lines in
          // the open menu.
          itemHeight: null,
          // Shown when no listed model is chosen (none yet, or the chosen
          // file was deleted); only the app's own model files are listed,
          // so there is no "custom" entry to name.
          hint: const Text(
            'Choose a model',
            style: TextStyle(color: Colors.white54),
          ),
          // Closed (collapsed) display: keep it to a single ellipsized line
          // so the button never overflows.
          selectedItemBuilder: (context) => _models
              .map(
                (m) => Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    m.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              )
              .toList(),
          items: _models
              .map(
                (m) => DropdownMenuItem(
                  value: m.id,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      m.label,
                      softWrap: true,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              )
              .toList(),
          onChanged: (v) {
            if (v == null) return;
            final picked = _models.firstWhere((m) => m.id == v);
            final note = unsupportedTaskNote(picked.task); // round 354, see _useDetector
            if (note != null) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${picked.name} $note.')));
              return;
            }
            setState(() {
              _c = _c.copyWith(
                modelPath: v,
                task: YOLOTaskParsing.tryParse(picked.task) ?? _c.task,
              );
            });
          },
        ),
      // Dynamic readout of the selected model's input tensor size (read from
      // its embedded metadata): the square pixel size the model "sees".
      if (!_modelsLoading)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            model?.inputSize != null
                ? 'Input resolution: ${model!.inputSize}×${model.inputSize} px'
                : 'Input resolution: unknown (not in model metadata)',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
      // Round 268: no detection model on the phone at all, or the chosen one
      // was deleted (models inside the app are no longer listed).
      if (!_hasDetector)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: NoModelNotice(identification: false, onGet: _manageModels),
        )
      else if (!_modelsLoading && !_models.any((m) => m.id == _c.modelPath))
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            // Round 270: '' = none chosen yet (no built-in default any more).
            _c.modelPath.isEmpty
                ? '⚠ No model chosen yet. Choose one above.'
                : '⚠ The chosen model is not on this phone any more. Choose one above.',
            style: const TextStyle(color: Colors.orangeAccent, fontSize: 13),
          ),
        ),
      if (!_modelsLoading && _duplicateNames.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '⚠ Two or more models share a name '
            '(${_duplicateNames.join(', ')}). Rename them on the phone so '
            'you can tell which is which.',
            style: const TextStyle(color: Colors.orangeAccent, fontSize: 13),
          ),
        ),
      const SizedBox(height: 8),

      NumericSettingField(
        label: 'Confidence threshold',
        value: _c.confidenceThreshold,
        min: 0.05,
        max: 0.95,
        decimals: 2,
        helperText:
            'Minimum score for the model to report a detection at all '
            '(0.05–0.95). Default 0.25. Lower = more (but noisier) detections '
            'reach the tracker, including the faint, partly-hidden ones the '
            'tracker can use to hold onto a track ID. Keep the tracker\'s '
            '"New-track confidence" (Tracking, Advanced) at least 0.10 above '
            'this, so a band of faint detections exists; a note there says '
            'when it is not.',
        onChanged: (v) => setState(() => _c = _c.copyWith(confidenceThreshold: v)),
      ),
      // IoU, engine and benchmark sit folded (round 159): all have good
      // defaults, and Confidence above is the one detection knob a first-time
      // user plausibly touches. "Show FPS" moved to the Setup tab's
      // On-screen display fold the same round.
      _engineAdvancedSection(),

      const Divider(color: Colors.white24),
      const HelpLabel(
        leading: Icon(Icons.polyline, size: 20, color: Colors.white70),
        label: 'Tracking',
        labelStyle: TextStyle(color: Colors.white70, fontSize: 16),
        helperText:
            'Tracking links each insect\'s detections across frames into '
            'one track ID. In pollination ecology a track ID usually stands '
            'for one visit (an insect\'s stay on the flower), the basis of the '
            'visitation rate; some can be false detections, or one insect '
            'split into two track IDs. The two settings below are the ones that matter in most '
            'sessions; the defaults suit insects that land and stay on a '
            'flower. The algorithm choice and its own settings are under '
            'Advanced.',
      ),
      _trackerFields(),
      const SizedBox(height: 8),
      const Divider(color: Colors.white24),
      _liveVideoSection(),
      const SizedBox(height: 8),
    ];
    if (_c.detectorEnabled) return ListView(children: children);
    return ListView(
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            'These settings apply to live detection mode (the Tracking '
            'settings also to "Find animals in photos"). To edit them, '
            'switch "Capture trigger" on the Setup tab to Live detection.',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        // IgnorePointer swallows every tap (nothing below can be edited);
        // the Opacity greys the block so it reads as inactive at a glance.
        // The stored values are untouched and come back editable as soon as
        // the AI detector mode is selected again.
        IgnorePointer(
          child: Opacity(
            opacity: 0.4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    );
  }

  /// Collapsed "Advanced" block of the detection section (round 159): the NMS
  /// IoU threshold and the engine controls (GPU switch, CPU threads,
  /// benchmark). All have good defaults; the benchmark button is the usual
  /// reason to open this, after switching models.
  Widget _engineAdvancedSection() => FoldSection(
    title: 'Advanced (engine & thresholds)',
    subtitle: 'Duplicate-box filtering (IoU), processor choice, benchmark.',
    helperText:
        'All defaults are good. The usual reason to open this is the '
        'benchmark, which finds the fastest engine for a newly added model.',
    children: [
      NumericSettingField(
        // "IoU threshold" stays the first words: the session summary and
        // both Find animals screens name this setting so.
        label: 'IoU threshold (removes duplicate boxes)',
        value: _c.iouThreshold,
        min: 0.1,
        max: 0.95,
        decimals: 2,
        helperText:
            'IoU is how much two boxes overlap: the area they share divided '
            'by the area they cover together. When two boxes overlap more '
            'than this, they are treated as the same animal and only the box '
            'with the higher score is kept (0.10–0.95). Default 0.70.',
        onChanged: (v) => setState(() => _c = _c.copyWith(iouThreshold: v)),
      ),
      HelpSwitchTile(
        // Same label as on the Identify settings: the GPU is used whenever
        // it can load the model; no speed check runs (only the benchmark).
        title: 'Use the GPU when it can run the model',
        helperText:
            'Lets the model run on the phone\'s graphics chip (GPU), '
            'usually faster and cooler than the main processor (CPU). A '
            'model the GPU cannot run falls back to the CPU automatically, '
            'so this is safe to leave on; the engine actually used is shown '
            'on the camera screen\'s info panel. The app does not test which '
            'is faster on this phone; "Benchmark engines (GPU vs CPU)" below '
            'does.',
        value: _c.useGpu,
        onChanged: (v) => setState(() => _c = _c.copyWith(useGpu: v)),
      ),
      NumericSettingField(
        label: 'CPU threads (0 = automatic)',
        value: _c.cpuThreads.toDouble(),
        min: 0,
        max: 8,
        isInt: true,
        helperText:
            'How many processor cores the model may use when it runs on the '
            'CPU (not used on the GPU). 0 = automatic (2 cores), because 2 is '
            'often about twice as fast as 1, while 4 is barely faster and '
            'makes more heat. Run the benchmark below to check this phone '
            'before changing it.',
        onChanged: (v) =>
            setState(() => _c = _c.copyWith(cpuThreads: v.round())),
      ),
      const SizedBox(height: 4),
      // The benchmark compiles TFLite engine variants, so it cannot time an
      // NPU (*_qnn.onnx) model — those always run on the Snapdragon NPU.
      if (isQnnModelPath(_c.modelPath))
        const Text(
          'This model runs on the phone\'s AI chip (NPU), not on the GPU or '
          'CPU, so the benchmark and "CPU threads" do not apply to it.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        )
      else
        HelpRow(
          helperText:
              'Times the selected model on the GPU and on the CPU at '
              'several thread counts (fed test frames at the model\'s own '
              'input resolution), then lets you apply the fastest. Runs '
              'the model at full speed for a few seconds per engine, so '
              'the phone warms up a little; run it when you change model, '
              'not before every session. The live preview keeps detecting '
              'in the background, which can make all numbers read slightly '
              'slow, but their ranking is still valid.',
          child: OutlinedButton.icon(
            onPressed: _benchmarkRunning ? null : _runEngineBenchmark,
            icon: _benchmarkRunning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.speed),
            label: Text(
              _benchmarkRunning
                  ? 'Benchmarking… (up to ~30 s)'
                  : 'Benchmark engines (GPU vs CPU)',
            ),
          ),
        ),
      const SizedBox(height: 8),
    ],
  );

  /// Runs the plugin's engine benchmark (perf review A4) on the currently
  /// selected model and shows the timings. User-triggered on purpose: the
  /// benchmark compiles the model once per engine and runs seconds of
  /// full-speed inference, so it should happen when the user decides (e.g.
  /// after switching models), never automatically at session start.
  Future<void> _runEngineBenchmark() async {
    setState(() => _benchmarkRunning = true);
    final clock = Stopwatch()..start();
    List<Map<String, dynamic>> results;
    try {
      results = await YOLO.benchmarkAccelerators(_c.modelPath);
    } catch (e) {
      if (!mounted) return;
      setState(() => _benchmarkRunning = false);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: DialogTitle(const Text('Benchmark failed'), onClose: () => Navigator.pop(ctx)),
          content: Text('$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _benchmarkRunning = false);
    await _showBenchmarkResults(results, clock.elapsedMilliseconds / 1000.0);
  }

  Future<void> _showBenchmarkResults(
    List<Map<String, dynamic>> results,
    double elapsedS,
  ) async {
    // Model input resolution the timings apply to, from the native side's
    // [1, height, width, 3] tensor shape (same for every configuration).
    String? inputSize;
    for (final r in results) {
      final dims = (r['inputDims'] as List?)
          ?.whereType<num>()
          .map((e) => e.toInt())
          .toList();
      if (dims != null && dims.length == 4) {
        inputSize = '${dims[2]}×${dims[1]}';
        break;
      }
    }
    // Fastest configuration that actually produced a timing.
    Map<String, dynamic>? fastest;
    for (final r in results) {
      final avg = (r['avgMs'] as num?)?.toDouble();
      if (avg == null) continue;
      if (fastest == null || avg < (fastest['avgMs'] as num).toDouble()) {
        fastest = r;
      }
    }

    final apply = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(const Text('Engine benchmark'), onClose: () => Navigator.pop(ctx, false)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${inputSize != null ? 'Model input: $inputSize px · ' : ''}'
                'benchmark took ${elapsedS.toStringAsFixed(1)} s',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              for (final r in results) ...[
                Text(
                  '${r['label']}',
                  style: TextStyle(
                    fontWeight: identical(r, fastest) ? FontWeight.bold : null,
                  ),
                ),
                Text(
                  r['avgMs'] != null
                      ? '${(r['avgMs'] as num).toStringAsFixed(1)} ms per '
                            'inference (up to about '
                            '${(1000 / (r['avgMs'] as num)).toStringAsFixed(0)} '
                            'inferences/s)'
                            '${identical(r, fastest) ? ', fastest' : ''}'
                      : 'Unavailable: ${r['error'] ?? 'unknown error'}',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 8),
              ],
              const Text(
                'Lower is faster. "ms per inference" is the time the model '
                'needs for one camera picture (average of 20 runs); '
                '"inferences/s" is the most pictures per second it could '
                'check. During a session the real rate is lower, because the '
                'camera and tracking also need time, and it never goes above '
                '"Max detector rate" (Power tab).\n\n'
                'Tap "Use …" to choose the fastest, then tap Apply at the '
                'bottom of Session settings.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Close'),
          ),
          if (fastest != null)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Use ${fastest['label']}'),
            ),
        ],
      ),
    );

    if (apply == true && fastest != null && mounted) {
      setState(() {
        _c = _c.copyWith(
          useGpu: fastest!['useGpu'] as bool? ?? true,
          // Winner on GPU: thread count stays as-is (it only matters if the
          // model ever falls back to CPU). Winner on CPU: adopt its threads.
          cpuThreads: (fastest['useGpu'] as bool? ?? true)
              ? _c.cpuThreads
              : (fastest['cpuThreads'] as num? ?? 0).toInt(),
        );
      });
    }
  }

  Widget _trackerFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Occlusion tolerance is exposed in SECONDS (intuitive); it is converted
        // to a frame count at runtime against the live detector FPS, since the
        // tracker buffers lost tracks by frames and the frame rate varies.
        NumericSettingField(
          label: 'Occlusion tolerance',
          value: _c.occlusionSeconds,
          min: 0.2,
          max: 10.0,
          decimals: 1,
          unitSuffix: 's',
          helperText:
              'How long an insect can be out of sight (for example behind a '
              'petal) before its track ID ends. Longer = an insect that comes '
              'back keeps its track ID instead of getting a second one; too '
              'long may join two different insects. Default 3 s, enough for a '
              'short hide on a flower (0.2–10 s).',
          onChanged: (v) =>
              setState(() => _c = _c.copyWith(occlusionSeconds: v)),
        ),
        // Min visit length is also exposed in SECONDS and converted to frames
        // live (like occlusion tolerance), so it stays meaningful as FPS drifts.
        NumericSettingField(
          label: 'Minimum track length',
          value: _c.minHitsSeconds,
          min: 0.0,
          max: 2.0,
          decimals: 1,
          unitSuffix: 's',
          helperText:
              'How long an insect must be seen without a break before it gets '
              'a counted track ID; shorter sightings are dropped as noise. '
              'Lower (for example 0.1) also counts brief touchdowns but lets '
              'in more false track IDs; higher (for example 0.5) counts only '
              'clear landings, so short visits are missed. Default 0.2 s, '
              'enough to drop single false boxes. At least 2 detections in a '
              'row are always needed (0–2 s).',
          onChanged: (v) => setState(() => _c = _c.copyWith(minHitsSeconds: v)),
        ),
        ..._advancedTrackerSection(),
      ],
    );
  }

  /// Round 240 (video plan 3b): record the ROI as video while the live AI
  /// runs, to check afterwards what it found and missed.
  Widget _liveVideoSection() {
    final cap = _c.cameraFpsCap;
    return FoldSection(
      title: 'Check live detection (advanced)',
      subtitle: 'Also record the yellow square (ROI) as video while the detector runs.',
      initiallyExpanded: _c.liveAiVideo,
      children: [
        HelpSwitchTile(
          title: 'Also record the ROI as video',
          helperText:
              'Records the ROI square as MP4 clips (a new clip every 5 minutes, in the session\'s '
              'videos folder) while the detector detects live. Afterwards the session summary plays '
              'the clips with the boxes live detection found, so you can see what it caught and what '
              'it missed, count the insects by hand, or run the detector again on the clips ("Find animals in '
              'videos"). Off by default: it costs storage (estimate below) and heat, because every '
              'frame of the clip is processed even while the motion gate lets the detector sleep.',
          value: _c.liveAiVideo,
          onChanged: (v) => setState(() => _c = _c.copyWith(liveAiVideo: v)),
        ),
        if (_c.liveAiVideo) ...[
          NumericSettingField(
            label: 'Video frame rate',
            value: _c.liveAiVideoFps.toDouble(),
            min: 1,
            max: 30,
            isInt: true,
            unitSuffix: 'FPS',
            helperText:
                'Frames per second in the clips (1 to 30). Default 15, the same as the starting '
                '"Camera frame rate" (Power tab), so the camera delivers every frame the clip '
                'needs. Lower rates save storage and heat.',
            onChanged: (v) => setState(() => _c = _c.copyWith(liveAiVideoFps: v.round())),
          ),
          if (cap > 0 && cap < _c.liveAiVideoFps)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'The camera runs at $cap frames per second (Power tab → "Camera frame rate"), so '
                'the clips get at most $cap.',
                style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              liveAiVideoStorageEstimate(_c),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }

  /// The collapsed "Advanced" block of the Visit-tracking section: the
  /// algorithm choice (inside the fold since round 159 — comparing trackers is
  /// a research task, not day-to-day setup), the selected algorithm's own
  /// tuning knobs (only the active algorithm's are shown, so citizen-science
  /// users are never faced with both sets at once), a reset button, and the
  /// raw-detections evaluation toggle. Round 308: the controls are shared
  /// with the video settings' Track IDs card (widgets/tracker_tuning_fields.dart).
  List<Widget> _advancedTrackerSection() {
    final t = TrackerTuning(
      algorithm: _c.trackerAlgorithm,
      byteTrack: _c.trackerParams,
      cbiou: _c.cbiouParams,
      confidence: _c.confidenceThreshold,
      onAlgorithm: (a) => setState(() => _c = _c.copyWith(trackerAlgorithm: a)),
      onByteTrack: (p) => setState(() => _c = _c.copyWith(trackerParams: p)),
      onCbiou: (p) => setState(() => _c = _c.copyWith(cbiouParams: p)),
    );
    return [
      FoldSection(
        // A fixed key: the title follows the algorithm, the fold stays open.
        key: const ValueKey('fold:tracker-advanced'),
        title: 'Advanced (${t.algorithmName} tuning)',
        subtitle: 'Algorithm choice and frame-to-frame matching fine-tuning.',
        helperText:
            'The defaults suit insects on a flower; most sessions never need '
            'these.',
        children: [
          ...t.algorithmPicker(),
          ...t.fineTuning(
            newTrack: t.newTrackField(
              extraHelp:
                  ' Used by live detection and by "Find animals in photos"; "Find animals in videos" '
                  'has its own value.',
            ),
          ),
          TrackerTuning.resetButton(
            helperText:
                'Puts every tracking setting above back to its default (the '
                'algorithm choice itself is kept) and switches off "Log raw '
                'detections" below.',
            onPressed: _resetTrackingDefaults,
          ),
          const SizedBox(height: 4),
          HelpSwitchTile(
            title: 'Log raw detections (evaluation)',
            helperText:
                'Also writes the detector\'s unprocessed boxes for every '
                'frame into the session file, so a recorded session can be '
                'replayed through either tracker on a computer to compare '
                'them. Leave off for normal use; it grows the session file '
                'by roughly 1–2 MB per hour.',
            value: _c.logRawDetections,
            onChanged: (v) =>
                setState(() => _c = _c.copyWith(logRawDetections: v)),
          ),
        ],
      ),
    ];
  }

  /// Resets every Visit-tracking setting to its default: the shared
  /// seconds-based controls and BOTH algorithms' advanced knobs (a knob you
  /// can't currently see shouldn't stay silently mis-tuned). The algorithm
  /// choice itself is deliberately kept. Round 313: plain defaults (New-track
  /// 0.50), and the focused box is unfocused first so it shows the reset value.
  void _resetTrackingDefaults() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _c = _c.copyWith(
        occlusionSeconds: 3.0,
        minHitsSeconds: 0.2,
        trackerParams: const ByteTrackParams(),
        cbiouParams: const CBiouParams(),
        logRawDetections: false,
        // Reference photos are deliberately NOT reset here: their control
        // moved to the Setup tab, and a tracking reset must not silently
        // flip a Setup-tab setting.
      );
    });
  }
}
