// FaunaPulse — session settings sheet.
//
// Opened from the live preview (a bottom sheet). Edits a working copy of the
// SessionConfig and returns it via Navigator.pop when the user taps Apply, so
// the caller can persist it and push the new thresholds to the detector.
//
// The controls are grouped into four tabs so the sheet stays readable:
//   • Setup — output folder, photo time-lapse, session length.
//   • AI — model, thresholds, FPS/GPU, tracker tuning.
//   • Camera — live stream resolution and ROI-photo quality.
//   • Graphs — end-of-session graph sampling rates.
//
// Every numeric control is a typed number box (NumericSettingField), not a
// slider. Sliders were unusable here: a horizontal drag on a slider was stolen
// by the swipeable TabBarView (the tab slid sideways instead of the value
// moving). A number box has no horizontal drag, and lets the user enter exact
// values. All boxes clamp the typed number into the documented range.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../capture/roi_capture.dart';
import '../models/model_catalog.dart';
import '../models/roi.dart';
import '../models/schedule_window.dart';
import '../models/session_config.dart';
import '../tracking/byte_track.dart';
import '../tracking/c_biou_track.dart';
import '../tracking/tracker.dart';
import '../widgets/duration_setting_field.dart';
import '../widgets/numeric_setting_field.dart';

class SettingsSheet extends StatefulWidget {
  final SessionConfig config;

  /// Camera-supported analysis stream resolutions ("WxH"), from the HAL. When
  /// empty the sheet falls back to a standard preset list.
  final List<String> streamResolutions;

  /// Estimated ceiling for what CameraX ImageAnalysis can actually stream on this
  /// phone (the [streamResolutions] above are photo/preview sizes and over-promise
  /// — see round 56). Keys: `hardwareLevel`, `recommendedMax` ("WxH"),
  /// `previewBoundW`/`previewBoundH`, `displayW`/`displayH`. Used to flag sizes the
  /// device will silently shrink. Empty when unavailable.
  final Map<String, dynamic> analysisCeiling;

  /// Full-resolution photo size the camera can deliver (from the probe), shown
  /// to explain what the high-res photo source captures. 0 when unknown.
  final int sensorWidth;
  final int sensorHeight;

  /// Per-camera diagnostics from the native enumeration (one map per camera/lens:
  /// id, facing, focal lengths, logical vs physical, whether usable for inference
  /// + reason, supported analysis sizes). Shown read-only under the Camera tab so
  /// a user can see which lenses their phone actually offers the detector. Empty
  /// when the camera wasn't running when the sheet was opened.
  final List<Map<String, dynamic>> cameraDiagnostics;

  const SettingsSheet({
    super.key,
    required this.config,
    this.streamResolutions = const [],
    this.analysisCeiling = const {},
    this.sensorWidth = 0,
    this.sensorHeight = 0,
    this.cameraDiagnostics = const [],
  });

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late SessionConfig _c;
  late final TextEditingController _folder;

  /// The High-score threshold is always kept at least this far above the
  /// detector Confidence threshold, so there is always a band of "faint"
  /// detections (between Confidence and High-score) that can keep an existing
  /// insect's track id alive without being strong enough to spawn a new id.
  /// Raising Confidence pushes High-score up automatically to preserve it.
  static const double _highScoreBuffer = 0.10;

  /// The lowest the High-score threshold is allowed to sit given the current
  /// Confidence threshold (Confidence + [_highScoreBuffer], capped at 0.95).
  double get _minHighScore =>
      (_c.confidenceThreshold + _highScoreBuffer).clamp(0.30, 0.95);

  /// Session-length input: a typed number plus a Minutes/Hours unit toggle. The
  /// underlying config always stores minutes ([SessionConfig.sessionMinutes]);
  /// these two only drive the text field.
  late final TextEditingController _sessionLen;
  late bool _sessionInHours;

  /// The model list, scanned from disk (so newly-imported models appear) plus
  /// the bundled and official ones. Loaded asynchronously in [initState].
  List<ModelEntry> _models = const [];
  Set<String> _duplicateNames = const {};
  bool _modelsLoading = true;

  /// Whether the one-time setup reminder is enabled (shown at session start).
  /// Mirrors the inverse of the persisted "hide" flag; loaded in [initState].
  bool _showSetupTips = true;

  /// True while the engine benchmark runs (disables its button).
  bool _benchmarkRunning = false;

  @override
  void initState() {
    super.initState();
    _c = widget.config;
    _loadSetupTipsPref();
    _folder = TextEditingController(text: _c.folderName);
    // Show whole hours when the saved length divides cleanly into hours
    // (e.g. 120 → "2 h"); otherwise show minutes.
    _sessionInHours = _c.sessionMinutes >= 60 && _c.sessionMinutes % 60 == 0;
    _sessionLen = TextEditingController(
      text: _sessionInHours
          ? '${_c.sessionMinutes ~/ 60}'
          : '${_c.sessionMinutes}',
    );
    _reloadModels();
  }

  /// Reads the session-length text field in the current unit and writes the
  /// resulting whole-minute count back into the config.
  void _applySessionLength() {
    final n = int.tryParse(_sessionLen.text.trim());
    if (n == null || n <= 0) return;
    final minutes = _sessionInHours ? n * 60 : n;
    setState(() => _c = _c.copyWith(sessionMinutes: minutes));
  }

  Future<void> _reloadModels() async {
    setState(() => _modelsLoading = true);
    final entries = await ModelCatalog.build();
    if (!mounted) return;
    setState(() {
      _models = entries;
      _duplicateNames = ModelCatalog.duplicateNames(entries);
      _modelsLoading = false;
    });
  }

  Future<void> _importModels() async {
    final n = await ModelCatalog.importModels();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          n == 0
              ? 'No .tflite models imported.'
              : 'Imported $n model${n == 1 ? '' : 's'}.',
        ),
      ),
    );
    await _reloadModels();
  }

  /// Asks for a URL (e.g. a GitHub release asset link), downloads the .tflite
  /// into the imported-models folder, then selects it like a dropdown pick.
  Future<void> _downloadModel() async {
    final savedPath = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _DownloadModelDialog(),
    );
    if (savedPath == null || !mounted) return;
    final name = savedPath.split('/').last;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Downloaded $name.')));
    await _reloadModels();
    if (!mounted) return;
    // Auto-select the new model (same as picking it in the dropdown).
    for (final m in _models) {
      if (m.id == savedPath) {
        setState(() {
          _c = _c.copyWith(
            modelPath: m.id,
            task: YOLOTaskParsing.tryParse(m.task) ?? _c.task,
          );
        });
        break;
      }
    }
  }

  /// The currently-selected model entry (for showing its input resolution), or
  /// null if the selection isn't in the scanned list yet.
  ModelEntry? get _selectedModel {
    for (final m in _models) {
      if (m.id == _c.modelPath) return m;
    }
    return null;
  }

  @override
  void dispose() {
    _folder.dispose();
    _sessionLen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottom),
      child: SizedBox(
        // Cap to 85% of the screen, but shrink by the keyboard inset so the
        // fixed-height box (plus its bottom padding) can never exceed the screen
        // and clip the Apply button when a text field is focused.
        height:
            MediaQuery.of(context).size.height * 0.85 -
            (bottom > 0 ? bottom : 0),
        child: DefaultTabController(
          length: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Session settings',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              // Non-scrollable so all four tabs share the width and are always
              // visible at once — a scrolling tab strip can hide tabs off the
              // right edge without the user realising more exist. Short labels +
              // an icon keep each tab readable in a quarter of the screen.
              TabBar(
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white54,
                indicatorColor: Colors.lightBlueAccent,
                labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                tabs: [
                  const Tab(icon: Icon(Icons.tune, size: 20), text: 'Setup'),
                  // The AI tab dims in the no-AI capture modes (r147): its
                  // settings have no effect there. It stays tappable — the
                  // tab body shows a notice saying why it is inactive.
                  if (_c.detectorEnabled)
                    const Tab(icon: Icon(Icons.memory, size: 20), text: 'AI')
                  else
                    const Tab(
                      icon: Icon(Icons.memory, size: 20, color: Colors.white24),
                      child: Text(
                        'AI',
                        style: TextStyle(color: Colors.white24),
                      ),
                    ),
                  const Tab(
                    icon: Icon(Icons.photo_camera, size: 20),
                    text: 'Camera',
                  ),
                  const Tab(
                    icon: Icon(Icons.show_chart, size: 20),
                    text: 'Graphs',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TabBarView(
                  children: [
                    _sessionTab(),
                    _aiPipelineTab(),
                    _cameraTab(),
                    _summaryTab(),
                  ],
                ),
              ),
              // Persistent bottom action, outside the TabBarView so it never
              // scrolls away. SafeArea keeps it clear of the system gesture/nav
              // bar (which was overlapping and clipping it).
              SafeArea(
                top: false,
                minimum: const EdgeInsets.only(top: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(_c.copyWith(folderName: _folder.text)),
                    child: const Text('Apply'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Tab 1: Session configuration --------------------------------------

  Widget _sessionTab() => ListView(
    children: [
      _label('Output folder (e.g. target flower species)'),
      TextField(
        controller: _folder,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(
          hintText: 'session',
          hintStyle: TextStyle(color: Colors.white38),
        ),
        onChanged: (v) => _c = _c.copyWith(folderName: v),
      ),
      const SizedBox(height: 16),

      _label('Capture trigger — what causes photos during a session'),
      DropdownButton<CaptureTrigger>(
        value: _c.captureTrigger,
        isExpanded: true,
        dropdownColor: Colors.black87,
        items: const [
          DropdownMenuItem(
            value: CaptureTrigger.detector,
            child: Text(
              'AI detector — detect, track & photograph insects',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          DropdownMenuItem(
            value: CaptureTrigger.motion,
            child: Text(
              'Motion-triggered photos — no AI',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          DropdownMenuItem(
            value: CaptureTrigger.timelapse,
            child: Text(
              'Time-lapse photo bursts — no AI, no motion check',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
        onChanged: (t) => setState(
          () => _c = _c.copyWith(
            captureTrigger: t,
            // The motion trigger cannot work without the gate — it IS the
            // trigger — so selecting it switches the gate on too.
            motionGateEnabled: t == CaptureTrigger.motion
                ? true
                : _c.motionGateEnabled,
          ),
        ),
      ),
      Text(switch (_c.captureTrigger) {
        CaptureTrigger.detector =>
          'The full pipeline: on-device detection + tracking, photos per '
              'track id, visitation data in the log.',
        CaptureTrigger.motion =>
          'Photos whenever something moves in the ROI; the AI model loads '
              'but never runs (big energy saver). No species/track data — the '
              'motion gate on the Camera tab is the trigger (forced on) and '
              'its sensitivity settings apply. Wind/shadows produce junk '
              'photos instead of wasted computation.',
        CaptureTrigger.timelapse =>
          'Photos on a pure clock — no AI, no motion check: the cheapest '
              'mode. Each burst takes a photo every "Photo step" for "Photo '
              'duration", and bursts repeat per "Repeat burst every" below. '
              'Set the repeat ≤ the duration for a continuous time-lapse. '
              'Meant for running a detector on the photos afterwards.',
      }, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      const SizedBox(height: 12),

      NumericSettingField(
        label: 'Photo step',
        value: _c.stepSeconds,
        min: 0.1,
        max: 10,
        decimals: 1,
        unitSuffix: 's',
        helperText:
            'Seconds between saved ROI photos — of the same track id (AI '
            'detector on) or within one motion/time-lapse burst (0.1–10). '
            'Default 1. Steps below ~0.5 s need the "fast" photo source: '
            'high-res photos take 0.5–1.5 s each and cannot keep up. '
            'Fast photos are capped at the live-stream short side, so raise '
            'the stream resolution if fast bursts need bigger photos.',
        onChanged: (v) => setState(() => _c = _c.copyWith(stepSeconds: v)),
      ),
      DurationSettingField(
        label: 'Photo duration',
        valueSeconds: _c.durationSeconds,
        minSeconds: 1,
        maxSeconds: 86400,
        helperText:
            'How long photos keep being saved — per track id (AI detector), '
            'per motion event (motion trigger; a new event starts once the '
            'gate has slept and motion returns), or per time-lapse burst. '
            'Should be a whole multiple of the step.',
        onChanged: (v) => setState(() => _c = _c.copyWith(durationSeconds: v)),
      ),
      if (_c.timeLapseCapture)
        DurationSettingField(
          label: 'Repeat burst every',
          valueSeconds: _c.timeLapseIntervalSeconds,
          minSeconds: 1,
          maxSeconds: 86400,
          helperText:
              'Time from the START of one photo burst to the start of the '
              'next (so "every 30 min" stays every 30 min regardless of the '
              'burst length). Set it ≤ the photo duration for a continuous '
              'time-lapse. Default 30 min.',
          onChanged: (v) =>
              setState(() => _c = _c.copyWith(timeLapseIntervalSeconds: v)),
        ),
      if (!_c.isTimeLapseValid)
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            '⚠ Duration should be a whole multiple of the step.',
            style: TextStyle(color: Colors.orangeAccent, fontSize: 13),
          ),
        ),

      const SizedBox(height: 8),
      _label('Session length (recording auto-stops after this)'),
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TextField(
              controller: _sessionLen,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: '60',
                hintStyle: TextStyle(color: Colors.white38),
              ),
              onChanged: (_) => _applySessionLength(),
            ),
          ),
          const SizedBox(width: 12),
          ToggleButtons(
            isSelected: [!_sessionInHours, _sessionInHours],
            borderColor: Colors.white24,
            selectedBorderColor: Colors.lightBlueAccent,
            color: Colors.white54,
            selectedColor: Colors.white,
            fillColor: Colors.white10,
            constraints: const BoxConstraints(minWidth: 64, minHeight: 40),
            onPressed: (i) {
              setState(() => _sessionInHours = i == 1);
              _applySessionLength();
            },
            children: const [Text('Minutes'), Text('Hours')],
          ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          _sessionInHours
              ? 'Typical 1–24 h; custom values allowed. = ${_c.sessionMinutes} min total.'
              : 'Typical 1–60 min; custom values allowed. = ${_c.sessionMinutes} min total.',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ),

      const Divider(color: Colors.white24),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Scheduled recording',
          style: TextStyle(color: Colors.white),
        ),
        subtitle: const Text(
          'The record button starts a multi-window run: record during each '
          'daily window below, sleep (screen dark, camera off) in between. '
          'Each window is saved as its own session. Session length above is '
          'ignored — the window end times govern.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        isThreeLine: true,
        value: _c.scheduleEnabled,
        onChanged: (v) => setState(() => _c = _c.copyWith(scheduleEnabled: v)),
      ),
      if (_c.scheduleEnabled) ...[
        for (var i = 0; i < _c.scheduleWindows.length; i++) _windowRow(i),
        if (_c.scheduleWindows.length < 3)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(
                () => _c = _c.copyWith(
                  scheduleWindows: [
                    ..._c.scheduleWindows,
                    // A fresh window defaults to the afternoon so it doesn't
                    // instantly overlap the default morning one.
                    const ScheduleWindow(15 * 60, 20 * 60),
                  ],
                ),
              ),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add window'),
            ),
          ),
        if (!_c.isScheduleValid)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              '⚠ Windows must not overlap, and each must end after it starts '
              '(a window cannot cross midnight — split it in two).',
              style: TextStyle(color: Colors.orangeAccent, fontSize: 13),
            ),
          ),
        NumericSettingField(
          label: 'Days to run',
          value: _c.scheduleDays.toDouble(),
          min: 1,
          max: 14,
          decimals: 0,
          helperText:
              'The windows repeat every day for this many days (1–14). '
              'Day 1 is the day you start the run; windows already past '
              'at that moment are skipped.',
          onChanged: (v) =>
              setState(() => _c = _c.copyWith(scheduleDays: v.round())),
        ),
      ],

      const Divider(color: Colors.white24),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Show setup tips at session start',
          style: TextStyle(color: Colors.white),
        ),
        subtitle: const Text(
          'The one-time reminder about fixing the flower, centring the ROI and '
          'locking focus before recording.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        isThreeLine: true,
        value: _showSetupTips,
        onChanged: _setShowSetupTips,
      ),

      const Divider(color: Colors.white24),
      const Text(
        'On-screen display',
        style: TextStyle(color: Colors.white70, fontSize: 16),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 2, bottom: 4),
        child: Text(
          'Drawing overlays uses the phone briefly each frame. Turning them off '
          'gives the lightest preview; detection and tracking keep running and '
          'everything is still logged either way.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Show detection boxes & track IDs',
          style: TextStyle(color: Colors.white),
        ),
        subtitle: Text(
          'The blue boxes with "#id … Conf.: 0.xy" over each insect.'
          '${_c.detectorEnabled ? '' : ' (AI detector mode only — there are no detections to draw in this mode.)'}',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        // Locked off in the no-AI modes: the detector never runs there, so
        // there is nothing to draw. The saved preference is untouched — it
        // comes back when the AI mode is selected again (r147).
        value: _c.detectorEnabled && _c.showBoxes,
        onChanged: _c.detectorEnabled
            ? (v) => setState(() => _c = _c.copyWith(showBoxes: v))
            : null,
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Show on-screen info panel',
          style: TextStyle(color: Colors.white),
        ),
        subtitle: const Text(
          'The top-left readouts (FPS, model, engine, stream, ROI size, '
          'temperature, track count). Off = only the ROI box and recording '
          'controls remain.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        isThreeLine: true,
        value: _c.showOverlayInfo,
        onChanged: (v) => setState(() => _c = _c.copyWith(showOverlayInfo: v)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Flash ROI border when a photo is saved',
          style: TextStyle(color: Colors.white),
        ),
        subtitle: const Text(
          'The ROI outline blinks green for a split second each time a photo is '
          'captured, so you can see captures happening.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        isThreeLine: true,
        value: _c.flashOnCapture,
        onChanged: (v) => setState(() => _c = _c.copyWith(flashOnCapture: v)),
      ),
      const SizedBox(height: 8),
    ],
  );

  /// One schedule-window row: "Window N  [06:00] – [10:00]  🗑". The time
  /// buttons open the system time picker; the delete icon appears only while
  /// more than one window remains (a schedule needs at least one).
  Widget _windowRow(int index) {
    final w = _c.scheduleWindows[index];
    Widget timeButton({required bool isStart}) => OutlinedButton(
      onPressed: () => _pickWindowTime(index, isStart: isStart),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.white24),
      ),
      child: Text(isStart ? w.startLabel : w.endLabel),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              'Window ${index + 1}',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          timeButton(isStart: true),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: Text('–', style: TextStyle(color: Colors.white54)),
          ),
          timeButton(isStart: false),
          const Spacer(),
          if (_c.scheduleWindows.length > 1)
            IconButton(
              icon: const Icon(
                Icons.delete_outline,
                color: Colors.white54,
                size: 20,
              ),
              onPressed: () => setState(() {
                final windows = [..._c.scheduleWindows]..removeAt(index);
                _c = _c.copyWith(scheduleWindows: windows);
              }),
            ),
        ],
      ),
    );
  }

  /// Opens the system time picker for one end of a window and stores the
  /// result as minutes since midnight. An invalid combination (start ≥ end,
  /// overlap with another window) is allowed here and flagged by the warning
  /// under the rows — same lenient pattern as the time-lapse check.
  Future<void> _pickWindowTime(int index, {required bool isStart}) async {
    final w = _c.scheduleWindows[index];
    final current = isStart ? w.startMinute : w.endMinute;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
    );
    if (picked == null || !mounted) return;
    final minutes = picked.hour * 60 + picked.minute;
    setState(() {
      final windows = [..._c.scheduleWindows];
      windows[index] = isStart
          ? ScheduleWindow(minutes, w.endMinute)
          : ScheduleWindow(w.startMinute, minutes);
      _c = _c.copyWith(scheduleWindows: windows);
    });
  }

  // --- Tab 2: AI pipeline -------------------------------------------------

  Widget _aiPipelineTab() {
    final model = _selectedModel;
    // Built as a plain list so the no-AI branch below can reuse it: in the
    // motion and time-lapse capture modes none of these settings has any
    // effect (the detector never runs), so the whole tab is shown greyed and
    // read-only under a notice instead of pretending to be editable (r147).
    final children = <Widget>[
      Row(
        children: [
          Expanded(child: _label('Detection model')),
          TextButton.icon(
            onPressed: _modelsLoading ? null : _downloadModel,
            icon: const Icon(Icons.cloud_download_outlined, size: 18),
            label: const Text('Download…'),
          ),
          TextButton.icon(
            onPressed: _modelsLoading ? null : _importModels,
            icon: const Icon(Icons.file_upload, size: 18),
            label: const Text('Import…'),
          ),
        ],
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
          hint: const Text(
            'Custom / other',
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
                ? 'Input resolution: ${model!.inputSize}×${model.inputSize} px '
                      '(smaller = faster, larger = more accurate on tiny insects)'
                : 'Input resolution: unknown (not in model metadata)',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
      // Covers a pre-r119 placeholder id AND an imported model whose file was
      // deleted from the phone — anything selected that isn't on the device.
      if (!_modelsLoading && !_models.any((m) => m.id == _c.modelPath))
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            '⚠ This model isn\'t on the device — the bundled nano runs '
            'instead. Use Download… or Import… above to add it.',
            style: TextStyle(color: Colors.orangeAccent, fontSize: 13),
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
            'reach the tracker — including the faint, partly-hidden ones the '
            'tracker can use to hold onto a visit. Note: raising this also '
            'raises the Tracker\'s High-score threshold below, so a band of '
            'faint detections is always kept for that purpose.',
        onChanged: (v) => setState(() {
          // Keep the High-score threshold at least _highScoreBuffer above the
          // new Confidence, so the "faint detection" band is never squeezed
          // shut when the user raises Confidence. Both trackers carry their
          // own high threshold; the floor applies to each.
          final p = _c.trackerParams;
          final cp = _c.cbiouParams;
          final minHigh = (v + _highScoreBuffer).clamp(0.30, 0.95);
          _c = _c.copyWith(
            confidenceThreshold: v,
            trackerParams: p.highThresh < minHigh
                ? p.copyWith(highThresh: minHigh)
                : p,
            cbiouParams: cp.highThresh < minHigh
                ? cp.copyWith(highThresh: minHigh)
                : cp,
          );
        }),
      ),
      NumericSettingField(
        label: 'IoU threshold (NMS — removes duplicate boxes)',
        value: _c.iouThreshold,
        min: 0.1,
        max: 0.95,
        decimals: 2,
        helperText:
            'Overlap above which two boxes are treated as the same '
            'object (0.10–0.95). Default 0.70.',
        onChanged: (v) => setState(() => _c = _c.copyWith(iouThreshold: v)),
      ),

      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Show FPS', style: TextStyle(color: Colors.white)),
        value: _c.showFps,
        onChanged: (v) => setState(() => _c = _c.copyWith(showFps: v)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Use GPU when faster',
          style: TextStyle(color: Colors.white),
        ),
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
            'CPU (GPU runs ignore this). 0 lets the runtime decide. More '
            'threads can be faster but draw more power and heat — run the '
            'benchmark below before changing it.',
        onChanged: (v) =>
            setState(() => _c = _c.copyWith(cpuThreads: v.round())),
      ),
      const SizedBox(height: 4),
      OutlinedButton.icon(
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
      const Text(
        'Times the selected model on the GPU and on the CPU at several '
        'thread counts — fed test frames at the model\'s own input '
        'resolution — then lets you apply the fastest. Runs the model at '
        'full speed for a few seconds per engine, so the phone warms up a '
        'little — run it when you change model, not before every session. '
        'The live preview keeps detecting in the background, which can make '
        'all numbers read slightly slow; their ranking is still valid.',
        style: TextStyle(color: Colors.white54, fontSize: 12),
      ),

      const Divider(color: Colors.white24),
      const Row(
        children: [
          Icon(Icons.polyline, size: 20, color: Colors.white70),
          SizedBox(width: 8),
          Text(
            'Visit tracking',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ],
      ),
      _trackerFields(),
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
            'These settings apply only to the AI detector mode. Switch '
            '"Capture trigger" on the Setup tab to edit them.',
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
          title: const Text('Benchmark failed'),
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
        title: const Text('Engine benchmark'),
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
                            'inference — up to '
                            '~${(1000 / (r['avgMs'] as num)).toStringAsFixed(0)} '
                            'inferences/s'
                            '${identical(r, fastest) ? ' — fastest' : ''}'
                      : 'Unavailable: ${r['error'] ?? 'unknown error'}',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 8),
              ],
              const Text(
                '"ms per inference" = how long ONE frame takes to go through '
                'the model on that engine, averaged over 20 timed runs (after '
                '3 untimed warm-ups). The "inferences/s" figure is just '
                '1000 ÷ that — the ceiling if the model ran back-to-back with '
                'no camera or tracking work. Your session detector rate will '
                'be at or below it (and is capped by the inference-rate '
                'setting).\n\n'
                'The test frames are random noise generated at exactly the '
                'model\'s input resolution, so camera capture and downscaling '
                'are NOT part of these timings (in a session that cost shows '
                'up separately, as pre_ms in the log).\n\n'
                'Applying the fastest sets the "Use GPU" switch and the '
                'CPU-thread count above; Apply the settings sheet as usual '
                'afterwards.',
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
    final p = _c.trackerParams;
    void update(ByteTrackParams np) =>
        setState(() => _c = _c.copyWith(trackerParams: np));
    final cp = _c.cbiouParams;
    void updateC(CBiouParams np) =>
        setState(() => _c = _c.copyWith(cbiouParams: np));
    final isCbiou = _c.trackerAlgorithm == TrackerAlgorithm.cbiou;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(
          'Tracking links each insect\'s detections across frames into one '
          '"visit" with a stable ID — the basis of the visitation rate. The '
          'two settings below are the ones that matter day to day; the '
          'defaults suit insects that land and linger on a flower. '
          'Fine-tuning and the algorithm\'s own knobs live under Advanced.',
        ),
        DropdownButton<TrackerAlgorithm>(
          value: _c.trackerAlgorithm,
          isExpanded: true,
          dropdownColor: Colors.black87,
          items: const [
            // Names only (owner, 2026-07-15): no "default"/"experimental"
            // qualifiers while the two are still being compared in the field.
            DropdownMenuItem(
              value: TrackerAlgorithm.bytetrack,
              child: Text(
                'ByteTrack',
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
            DropdownMenuItem(
              value: TrackerAlgorithm.cbiou,
              child: Text(
                'C-BIoU',
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ],
          onChanged: (a) =>
              setState(() => _c = _c.copyWith(trackerAlgorithm: a)),
        ),
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'How detections are linked frame to frame. ByteTrack predicts '
            'where each insect went and matches by box overlap; C-BIoU '
            'enlarges the boxes before comparing them. Both count visits '
            'the same way, so results stay comparable across sessions.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
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
              'How long an insect can vanish (e.g. behind a petal) before its '
              'track ID is dropped. Longer = an insect that reappears keeps its '
              'original ID instead of being counted as a second visitor (fewer '
              'split IDs); too long risks merging two genuinely different '
              'visitors into one. (0.2–10 s; default 3.) Converted to frames '
              'live from the current FPS.',
          onChanged: (v) =>
              setState(() => _c = _c.copyWith(occlusionSeconds: v)),
        ),
        // Min visit length is also exposed in SECONDS and converted to frames
        // live (like occlusion tolerance), so it stays meaningful as FPS drifts.
        NumericSettingField(
          label: 'Minimum visit length',
          value: _c.minHitsSeconds,
          min: 0.0,
          max: 2.0,
          decimals: 1,
          unitSuffix: 's',
          helperText:
              'How long an insect must stay continuously detected before it '
              'counts as a real visit (gets a counted track id). Shorter blips '
              'are dropped as noise. Lower (e.g. 0.1) counts brief touchdowns '
              'but lets in more false blips; higher (e.g. 0.5) counts only '
              'clear, sustained landings. This directly affects the visitation '
              'rate for short visits. Converted to frames live from the current '
              'FPS (0–2 s; default 0.2).',
          onChanged: (v) => setState(() => _c = _c.copyWith(minHitsSeconds: v)),
        ),
        ..._advancedTrackerSection(isCbiou, p, update, cp, updateC),
      ],
    );
  }

  /// The collapsed "Advanced" block of the Visit-tracking section: the
  /// selected algorithm's own tuning knobs (only the active algorithm's are
  /// shown, so citizen-science users are never faced with both sets at once),
  /// a reset button, and the raw-detections evaluation toggle.
  List<Widget> _advancedTrackerSection(
    bool isCbiou,
    ByteTrackParams p,
    void Function(ByteTrackParams) update,
    CBiouParams cp,
    void Function(CBiouParams) updateC,
  ) => [
    ExpansionTile(
      tilePadding: EdgeInsets.zero,
      collapsedIconColor: Colors.white70,
      iconColor: Colors.white70,
      shape: const Border(), // no divider lines when expanded
      collapsedShape: const Border(),
      title: Text(
        'Advanced (${isCbiou ? 'C-BIoU' : 'ByteTrack'} tuning)',
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
      subtitle: const Text(
        'Fine-tuning for frame-to-frame matching. The defaults suit insects '
        'on a flower — most sessions never need these.',
        style: TextStyle(color: Colors.white54, fontSize: 12),
      ),
      children: [
        if (isCbiou)
          ..._cbiouFields(cp, updateC)
        else
          ..._byteFields(p, update),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _resetTrackingDefaults,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Reset tracking to defaults'),
          ),
        ),
        const Text(
          'Puts every tracking setting above back to its default (the '
          'algorithm choice itself is kept).',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Log raw detections (evaluation)',
            style: TextStyle(color: Colors.white),
          ),
          subtitle: const Text(
            'Also writes the detector\'s unprocessed boxes for every frame '
            'into the session file, so a recorded session can be replayed '
            'through either tracker on a computer to compare them. Leave off '
            'for normal use — it grows the session file by roughly 1–2 MB '
            'per hour.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          value: _c.logRawDetections,
          onChanged: (v) =>
              setState(() => _c = _c.copyWith(logRawDetections: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Ground-truth frames (evaluation)',
            style: TextStyle(color: Colors.white),
          ),
          subtitle: const Text(
            'Saves an ROI photo at a fixed interval into a separate '
            'gt_frames folder, whether or not anything is detected — an '
            'independent record for counting the true visits by eye, so the '
            'tracker is never checked against photos it triggered itself. '
            'Uses the same photo pipeline and size as normal photos '
            '(Camera tab → Saved photo side).',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          value: _c.gtFramesEnabled,
          onChanged: (v) =>
              setState(() => _c = _c.copyWith(gtFramesEnabled: v)),
        ),
        if (_c.gtFramesEnabled)
          DurationSettingField(
            label: 'Ground-truth frame interval',
            valueSeconds: _c.gtFrameSeconds,
            minSeconds: 1,
            maxSeconds: 3600,
            helperText:
                'Time between ground-truth photos. Default 5 s — about '
                '720 photos per hour; shorter catches briefer visits but '
                'uses more storage.',
            onChanged: (v) =>
                setState(() => _c = _c.copyWith(gtFrameSeconds: v)),
          ),
      ],
    ),
  ];

  /// C-BIoU's own knobs (round 105). The buffer scales are THE tuning lever
  /// of this algorithm: how far a box is enlarged before the overlap test.
  List<Widget> _cbiouFields(
    CBiouParams cp,
    void Function(CBiouParams) updateC,
  ) => [
    NumericSettingField(
      label: 'Search margin — pass 1',
      value: cp.bufferScale1,
      min: 0.05,
      max: 1.0,
      decimals: 2,
      helperText:
          'Before comparing, every box is enlarged by this fraction of its '
          'own size on each side (0.3 = a 10-px box is matched as 16 px). '
          'Bigger tolerates faster movement between frames but risks mixing '
          'up two insects sitting close together. Raising it above pass 2 '
          'raises pass 2 with it. (0.05–1.0; default 0.30.)',
      onChanged: (v) => updateC(
        cp.copyWith(
          bufferScale1: v,
          bufferScale2: v > cp.bufferScale2 ? v : cp.bufferScale2,
        ),
      ),
    ),
    NumericSettingField(
      label: 'Search margin — pass 2',
      value: cp.bufferScale2,
      min: 0.05,
      max: 2.0,
      decimals: 2,
      helperText:
          'A second, wider matching round for whatever pass 1 could not '
          'pair — this is what catches the big between-frame jumps. Always '
          'at least as large as pass 1. (up to 2.0; default 0.50.)',
      onChanged: (v) => updateC(
        cp.copyWith(bufferScale2: v < cp.bufferScale1 ? cp.bufferScale1 : v),
      ),
    ),
    NumericSettingField(
      label: 'High-score threshold',
      // Same Confidence-coupled floor as ByteTrack's high threshold, so the
      // "faint detection" band always exists regardless of algorithm.
      value: cp.highThresh < _minHighScore ? _minHighScore : cp.highThresh,
      min: _minHighScore,
      max: 0.95,
      decimals: 2,
      helperText:
          'A detection at or above this score may START a new visit ID; a '
          'fainter one (still above the Confidence threshold) may only keep '
          'an existing insect\'s ID alive — e.g. while it is half-hidden '
          'under a petal. Automatically kept above Confidence so that faint '
          'band never closes. Default 0.50.',
      onChanged: (v) => updateC(cp.copyWith(highThresh: v)),
    ),
  ];

  /// ByteTrack's own knobs — the pre-round-105 fields, unchanged.
  List<Widget> _byteFields(
    ByteTrackParams p,
    void Function(ByteTrackParams) update,
  ) => [
    NumericSettingField(
      label: 'Match overlap (IoU)',
      value: p.matchThresh,
      min: 0.05,
      max: 0.9,
      decimals: 2,
      helperText:
          'How much a new detection box must overlap a track\'s predicted '
          'box to be treated as the same insect. This is your "movement '
          'tolerance", inverted: LOWER tolerates faster motion (a bee that '
          'jumped across the frame still matches); HIGHER is stricter. For '
          'small fast insects keep it low (0.1–0.2). The range stops at '
          '0.05–0.90 on purpose: 0 would match unrelated boxes anywhere on '
          'screen (id chaos), and 1.0 would demand pixel-identical boxes so '
          'every frame would mint a new id.',
      onChanged: (v) => update(p.copyWith(matchThresh: v)),
    ),
    NumericSettingField(
      label: 'Low-score association',
      value: p.lowMatchThresh,
      min: 0.02,
      max: 0.8,
      decimals: 2,
      helperText:
          'A second, looser overlap test used to re-link faint detections '
          '(a half-hidden or blurred insect that briefly drops in '
          'confidence) so it keeps its track id. Normally set at or below '
          'Match overlap. The 0.02 floor stops a real track grabbing a '
          'random noise box; set it too high and faint insects are no '
          'longer recovered (0.02–0.80).',
      onChanged: (v) => update(p.copyWith(lowMatchThresh: v)),
    ),
    NumericSettingField(
      label: 'High-score threshold',
      // Floor follows the Confidence threshold so a "faint detection" band
      // always exists; the value never displays below that floor.
      value: p.highThresh < _minHighScore ? _minHighScore : p.highThresh,
      min: _minHighScore,
      max: 0.95,
      decimals: 2,
      helperText:
          'The score that separates a "strong" detection from a "faint" '
          'one. A box at or above this is a clear sighting and may START a '
          'new track ID. A box below it — but still above the Confidence '
          'threshold — is a faint sighting that may ONLY keep an '
          'already-existing insect\'s ID alive, never start a new one. That '
          'faint band (between Confidence and High-score) is exactly what '
          'holds onto a bee whose score dips while it is half-hidden under a '
          'petal, so it is not counted twice. Higher = more cautious about '
          'starting new IDs (fewer false visitors); lower = quicker to '
          'register a new visitor. It is automatically kept at least '
          '${_highScoreBuffer.toStringAsFixed(2)} above Confidence (and '
          'rises with it) so the faint band never closes. Default 0.50.',
      onChanged: (v) => update(p.copyWith(highThresh: v)),
    ),
    NumericSettingField(
      label: 'Velocity smoothing',
      value: p.velocitySmoothing,
      min: 0.0,
      max: 1.0,
      decimals: 2,
      helperText:
          'While an insect is briefly hidden, the tracker guesses where it '
          'went by continuing its recent motion. This sets how much it '
          'trusts the very latest movement. Low (≈0.2) = "assume it barely '
          'moved" — steadier, best for insects that land and sit still '
          '(the usual case here). High (≈0.8) = follow the latest motion '
          'closely — better for fast, darting insects but jumpier. '
          '(0–1; default 0.5.)',
      onChanged: (v) => update(p.copyWith(velocitySmoothing: v)),
    ),
  ];

  /// Resets every Visit-tracking setting to its default: the shared
  /// seconds-based controls and BOTH algorithms' advanced knobs (a knob you
  /// can't currently see shouldn't stay silently mis-tuned). The algorithm
  /// choice itself is deliberately kept. The high-score defaults respect the
  /// Confidence-coupled floor so the reset can never close the faint band.
  void _resetTrackingDefaults() {
    const bp = ByteTrackParams();
    const cbp = CBiouParams();
    final minHigh = _minHighScore;
    setState(() {
      _c = _c.copyWith(
        occlusionSeconds: 3.0,
        minHitsSeconds: 0.2,
        trackerParams: bp.copyWith(
          highThresh: bp.highThresh < minHigh ? minHigh : bp.highThresh,
        ),
        cbiouParams: cbp.copyWith(
          highThresh: cbp.highThresh < minHigh ? minHigh : cbp.highThresh,
        ),
        logRawDetections: false,
        gtFramesEnabled: false,
        gtFrameSeconds: 5.0,
      );
    });
  }

  // --- Tab 3: Camera & resolution ----------------------------------------

  Widget _cameraTab() => ListView(
    children: [
      _label(
        'Live stream resolution (short × long) — caps the fast ROI crop; '
        'higher may cost FPS.',
      ),
      _streamResolutionDropdown(),
      _streamCeilingNote(),
      // Directly under the stream dropdown (round 122, owner request): the
      // two settings are coupled — "Auto" above picks the smallest stream
      // that can supply this many pixels to a fast crop.
      NumericSettingField(
        label: 'Saved photo side (px)',
        value: _c.targetRoiSavedPx.toDouble(),
        min: 128,
        max: 2048,
        isInt: true,
        helperText:
            'The image resolution you want saved photos to have (side length '
            'of the square photo, in pixels). Bigger crops are scaled down to '
            'exactly this size so files stay uniform; photos are NEVER '
            'enlarged to reach it — stretching pixels adds no real detail. '
            'With fast crops (the default) the photo is cut from the live '
            'stream above, so it can only reach this size when the ROI covers '
            'that many stream pixels. If not, the "ROI photo source" setting '
            'below can force it with slower full-resolution photos ("Auto" '
            'does that per photo, only when needed). When even a '
            'full-resolution photo cannot supply it, the photo saves smaller '
            'and the ROI readout on the camera screen shows ⚠ — move the '
            'phone closer or switch lens. Values snap to a multiple of 32. '
            'The app ships set to 1024, and the "Auto" stream size above '
            'follows whatever you enter here.',
        onChanged: (v) => setState(() {
          _c = _c.copyWith(targetRoiSavedPx: snapToMultipleOf32(v));
          // The Auto stream pick follows this target (round 122): keep the
          // stored size in step so the dropdown stays WYSIWYG while on Auto.
          if (!_c.streamResolutionExplicit &&
              widget.streamResolutions.isNotEmpty) {
            final pick = autoStreamResolution(
              widget.streamResolutions,
              ceilingArea: _ceiling.$1,
              minShortSide: _c.targetRoiSavedPx,
            );
            if (pick != null) {
              _c = _c.copyWith(streamWidth: pick.$1, streamHeight: pick.$2);
            }
          }
        }),
      ),
      const SizedBox(height: 16),

      // 0 = uncapped (the camera's own full rate, ~30/s); 5..30 asks the
      // camera hardware itself to capture slower. Different from the
      // inference cap on the AI tab, which only skips frames in software
      // after the camera already produced them.
      NumericSettingField(
        label: 'Camera frame rate cap',
        value: _c.cameraFpsCap.toDouble(),
        min: 0,
        max: 30,
        isInt: true,
        unitSuffix: '/s',
        // Round 110 wording: the old text said "0 = device default" and then
        // "Default 15", using "default" for two different things (the
        // camera's own uncapped rate vs the app's factory setting) — the
        // owner found it confusing in the field. Keep the two ideas in
        // separate, differently-worded sentences.
        helperText:
            'How many frames per second the camera itself captures. Enter 0 '
            'to remove the cap — the camera then runs at its own full rate '
            '(~30/s on most phones). Without a cap the sensor and image '
            'processor run at that full rate the whole session, even while '
            'the motion gate has the detector asleep — the main reason a '
            '"sleeping" phone still warms up. Lower = cooler phone but a '
            'less smooth preview; detection is unaffected as long as this '
            'stays at or above the inference rate cap. The phone only '
            'supports certain rates, so the nearest supported one is used. '
            'The app ships set to 15/s (cooler); note that capping also '
            'delays high-res photos — measured on the test phone, a '
            'high-res photo shows the scene ~0.4 s after its trigger at '
            '15/s vs ~0.17 s uncapped.',
        onChanged: (v) {
          final r = v.round();
          // Snap 1..4 up to 5 so the lowest real cap is 5/s; 0 = device default.
          setState(
            () => _c = _c.copyWith(cameraFpsCap: r == 0 ? 0 : (r < 5 ? 5 : r)),
          );
        },
      ),
      const Divider(color: Colors.white24),

      _label(
        'ROI photo source. Fast crops (the default) cut each photo out of the '
        'live video frame: no camera stall and the photo shows the exact '
        'trigger moment. High-res photos'
        '${widget.sensorWidth > 0 ? ' (up to ${widget.sensorWidth}×${widget.sensorHeight} on this phone)' : ''}'
        ' put more pixels on a small flower, but each one pauses the AI '
        'pipeline for up to ~1.5 s (more on older phones), lands a fraction '
        'of a second after the detection, and often shows motion blur — a '
        'blurred high-res photo carries LESS usable detail than a smaller '
        'crisp crop, so more pixels are not automatically better for later '
        'classification. Auto: per photo, fast crop when it meets the '
        '"Saved photo side" set above, high-res otherwise.',
      ),
      DropdownButton<RoiCaptureMode>(
        value: _c.captureMode,
        isExpanded: true,
        dropdownColor: Colors.black87,
        items: const [
          DropdownMenuItem(
            value: RoiCaptureMode.fast,
            child: Text(
              'Fast crops only (live frame)',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          DropdownMenuItem(
            value: RoiCaptureMode.auto,
            child: Text(
              'Auto — high-res only when needed',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          DropdownMenuItem(
            value: RoiCaptureMode.highRes,
            child: Text(
              'High-res photos always (full resolution)',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
        onChanged: (m) => setState(() => _c = _c.copyWith(captureMode: m)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Sync companion photo (high-res)',
          style: TextStyle(color: Colors.white),
        ),
        subtitle: const Text(
          'Only applies when a photo takes the HIGH-RES path (never in fast '
          'mode). The companion is always the fast live-frame crop: a '
          'high-res photo lands up to ~1 s after the detection that '
          'triggered it, so a fast insect can be gone from it — with this '
          'on, the trigger-moment live crop is saved next to the high-res '
          'photo ("…_live.jpg"), lower resolution but the insect is in it. '
          'Adds roughly 50–200 KB per photo.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        value: _c.highResSyncCompanion,
        onChanged: (v) =>
            setState(() => _c = _c.copyWith(highResSyncCompanion: v)),
      ),
      const Divider(color: Colors.white24),

      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Auto-adjust inference rate (prevents overheating)',
          style: TextStyle(color: Colors.white),
        ),
        // Locked out in the no-AI modes — there is no inference to throttle.
        // The saved preference is untouched and returns with the AI mode
        // (r147; the detail fields below are hidden entirely then).
        subtitle: _c.detectorEnabled
            ? null
            : const Text(
                'AI detector mode only — there is no inference to throttle '
                'in this mode.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
        value: _c.detectorEnabled && _c.autoThrottle,
        onChanged: _c.detectorEnabled
            ? (v) => setState(() => _c = _c.copyWith(autoThrottle: v))
            : null,
      ),
      if (_c.detectorEnabled) ...[
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'Running the detector flat-out keeps the processor ~100% busy; after '
            'about a minute the phone overheats and quietly slows the chip, so the '
            'frame rate collapses (e.g. to ~3/s) and stays there. With this on, the '
            'app watches how long each detection takes and automatically lowers the '
            'rate just enough to give the chip cooling gaps — holding a steady, '
            'sustainable frame rate instead. Leave it on for long field sessions.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),

        // 0 = uncapped (Max); 5..120 caps the rate. With auto-adjust on this is the
        // ceiling the throttle will not exceed. The cap is only a ceiling: the real
        // rate can't exceed what the camera delivers.
        NumericSettingField(
          label: _c.autoThrottle ? 'Max inference rate' : 'Detector rate cap',
          value: _c.inferenceFps.toDouble(),
          min: 0,
          max: 120,
          isInt: true,
          unitSuffix: '/s',
          helperText: _c.autoThrottle
              ? 'Upper limit the auto-adjust will not exceed (0 = let it use up to '
                    '15/s). It will run at or below this, lower when the phone is hot.'
              : (_c.inferenceFps == 0
                    ? 'Currently Max (uncapped — highest FPS). Type 0 for Max, or '
                          '5–120 to cap the rate (lower = cooler).'
                    : 'Type 0 for Max (uncapped), or 5–120 to cap the rate '
                          '(lower = cooler).'),
          onChanged: (v) {
            final r = v.round();
            // Snap 1..4 up to 5 so the lowest real cap is 5/s; 0 stays "Max".
            setState(
              () =>
                  _c = _c.copyWith(inferenceFps: r == 0 ? 0 : (r < 5 ? 5 : r)),
            );
          },
        ),
        if (_c.autoThrottle) ...[
          NumericSettingField(
            label: 'Min inference rate',
            value: _c.minInferenceFps.toDouble(),
            min: 1,
            max: 15,
            isInt: true,
            unitSuffix: '/s',
            helperText:
                'The lowest the auto-adjust will drop to when the phone is hot, so '
                'a session stays usable. Default 3.',
            onChanged: (v) => setState(
              () => _c = _c.copyWith(minInferenceFps: v.round().clamp(1, 15)),
            ),
          ),
          NumericSettingField(
            label: 'Target processor load',
            value: _c.throttleDutyTarget,
            min: 0.3,
            max: 0.8,
            decimals: 2,
            helperText:
                'How busy the auto-adjust lets the processor stay on detection '
                '(0.3–0.8; default 0.50 = about half the time). Lower = cooler and '
                'steadier but fewer frames per second; higher = more frames but more '
                'heat. Advanced — 0.50 suits most phones.',
            onChanged: (v) =>
                setState(() => _c = _c.copyWith(throttleDutyTarget: v)),
          ),
        ],
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'The rate is a ceiling, not a guarantee: the real rate is also limited '
            'by how fast the camera delivers frames and how fast the model runs. '
            'For insect visits (seconds long) even ~10/s is usually plenty, and a '
            'lower steady rate beats a high rate that collapses.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
      ],
      const Divider(color: Colors.white24),

      // The capture trigger itself (AI detector / motion photos / time-lapse)
      // moved to the Setup tab in round 97 — this section keeps the motion
      // GATE and its sensitivity tuning, which serve both the detector mode
      // (sleep while the flower is empty) and the motion trigger.
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Motion gate (experimental): sleep while the flower is empty',
          style: TextStyle(color: Colors.white),
        ),
        subtitle: Text(
          'Runs the detector only when something moves inside the ROI (a cheap '
          'brightness check watches every frame). Big heat/battery saving during '
          'long empty periods. Designed for a MOUNTED phone: handheld shake '
          'counts as motion, so in the hand the gate stays awake — that is '
          'normal, not a fault. Off by default — validate against an always-on '
          'session before trusting it for real counts.'
          '${_c.motionOnlyCapture ? ' (Required by the motion capture trigger — see Setup tab.)' : ''}'
          '${_c.timeLapseCapture ? ' (Not used in time-lapse mode.)' : ''}',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        isThreeLine: true,
        // Shown OFF in time-lapse mode even if the preference is on — the
        // gate is forced off natively there, and the switch should say what
        // actually happens (r147). The stored preference itself survives.
        value:
            !_c.timeLapseCapture &&
            (_c.motionOnlyCapture || _c.motionGateEnabled),
        // Locked on while the motion trigger depends on it; locked out in
        // time-lapse mode where it does nothing.
        onChanged: _c.motionOnlyCapture || _c.timeLapseCapture
            ? null
            : (v) => setState(() => _c = _c.copyWith(motionGateEnabled: v)),
      ),
      // Sensitivity tuning is hidden in time-lapse mode (the gate never runs
      // there); it stays visible in motion mode, where these fields ARE the
      // capture sensitivity (the trigger dropdown force-enables the gate).
      if (_c.motionGateEnabled && !_c.timeLapseCapture) ...[
        // These tuning fields double as the motion-only capture sensitivity
        // controls — the same gate decides both "wake the detector" and
        // "take a photo".
        NumericSettingField(
          label: 'Wake duration after motion',
          value: _c.motionGateWakeSeconds,
          min: 0.5,
          max: 60,
          decimals: 1,
          unitSuffix: 's',
          // The same wake window has a different practical meaning per mode:
          // AI mode = how long the detector stays on; motion mode = how long
          // photos keep being taken (they stop when the gate goes idle).
          helperText: _c.motionOnlyCapture
              ? 'How long photos keep being taken after the last motion, '
                    'before the gate goes back to sleep. Every new movement '
                    'restarts this window. Default 3 s.'
              : 'How long the detector keeps running after the last movement '
                    'or detection. Every new detection restarts this window, '
                    'so a sitting insect is not lost. Longer = safer recall, '
                    'less heat saving. Default 3 s.',
          onChanged: (v) =>
              setState(() => _c = _c.copyWith(motionGateWakeSeconds: v)),
        ),
        NumericSettingField(
          label: 'Pixel sensitivity',
          value: _c.motionGatePixelDelta.toDouble(),
          min: 5,
          max: 100,
          isInt: true,
          helperText:
              'How much a pixel\'s brightness (0–255) must change to count as '
              'movement. Lower = more sensitive (wakes on small insects, but also '
              'on petal shadows); higher = stricter. Default 25.',
          onChanged: (v) => setState(
            () =>
                _c = _c.copyWith(motionGatePixelDelta: v.round().clamp(5, 100)),
          ),
        ),
        NumericSettingField(
          label: 'Trigger area',
          value: _c.motionGateAreaFraction * 100,
          min: 0.05,
          max: 20,
          decimals: 2,
          unitSuffix: '%',
          helperText:
              'How much of the ROI must change in one frame to wake the detector. '
              'Keep small — an insect covers little of the ROI. Default 0.5%.',
          onChanged: (v) =>
              setState(() => _c = _c.copyWith(motionGateAreaFraction: v / 100)),
        ),
        NumericSettingField(
          label: 'Motion grid resolution',
          value: _c.motionGateGridSize.toDouble(),
          min: 16,
          max: 160,
          isInt: true,
          helperText:
              'Number of cells per side of the motion-check thumbnail (a count, '
              'not pixels): the ROI is compared as an N×N mosaic, so each cell '
              'watches 1/N of the ROI width. An insect only registers if it '
              'spans at least about one cell — e.g. at 48, an insect narrower '
              'than ~1/48th (2%) of the ROI width may pass unseen; at 128 '
              'anything wider than ~0.8% of the ROI registers. Raise it for '
              'small insects relative to your ROI (and consider lowering '
              'Trigger area too); higher costs slightly more CPU. Default 48.',
          onChanged: (v) => setState(
            () =>
                _c = _c.copyWith(motionGateGridSize: v.round().clamp(16, 160)),
          ),
        ),
        NumericSettingField(
          label: 'Idle check rate (frames/s)',
          value: _c.motionGateIdleFps.toDouble(),
          min: 1,
          max: 30,
          isInt: true,
          helperText:
              'How many camera frames per second are inspected for motion '
              'while the detector sleeps; the rest are dropped before the '
              'costly image conversion — the main source of idle heat. Higher '
              'wakes faster but runs warmer; an arriving insect is noticed '
              'within ~1/rate s (default 5 → ~0.2 s). While awake, every '
              'frame is processed regardless, so the camera FPS readout '
              'showing ~this number just means the gate is asleep.',
          onChanged: (v) => setState(
            () => _c = _c.copyWith(motionGateIdleFps: v.round().clamp(1, 30)),
          ),
        ),
      ],
      const Divider(color: Colors.white24),
      _cameraInfoSection(),
    ],
  );

  /// Collapsible "Camera & lens info" section: lists every camera/lens the phone
  /// reports and whether the detector can actually use it. This is the diagnostic
  /// that used to sit on the live camera screen; it lives here so the recording
  /// screen stays uncluttered. Read-only; selectable text so it can be copied
  /// into a problem report. Explains, per device, why a given lens may not be
  /// selectable (e.g. a telephoto hidden inside a logical multi-camera, or a
  /// vendor that exposes only one rear camera to third-party apps).
  Widget _cameraInfoSection() {
    final cams = widget.cameraDiagnostics;
    return Theme(
      // ExpansionTile draws its divider lines from the theme; clear them so the
      // dark sheet doesn't get stray bright separators.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        iconColor: Colors.white,
        collapsedIconColor: Colors.white,
        title: const Text(
          'Camera & lens info (advanced)',
          style: TextStyle(color: Colors.white),
        ),
        subtitle: const Text(
          'Which rear/front lenses this phone exposes, and which the detector '
          'can use.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: cams.isEmpty
            ? const [
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Camera details aren\'t available yet. Open Settings from the '
                    'live camera screen (with the preview running) so the app can '
                    'read the lens list first.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              ]
            : _cameraInfoChildren(cams),
      ),
    );
  }

  /// Builds the body of the camera-info section: a plain-language explanation,
  /// then the **rear** cameras (the ones used for monitoring) first, then the
  /// **front** cameras tucked into a collapsed subsection. The list shows the
  /// cameras Android exposes to this app — which is a manufacturer-curated subset,
  /// not a 1:1 map of the glass lenses on the back of the phone.
  List<Widget> _cameraInfoChildren(List<Map<String, dynamic>> cams) {
    bool isBack(Map<String, dynamic> c) =>
        (c['lensFacing'] ?? '').toString() == 'back';
    final rear = cams.where(isBack).toList();
    final front = cams.where((c) => !isBack(c)).toList();
    final usableRear = rear
        .where((c) => c['usableForInference'] == true)
        .length;

    return [
      // Estimated analysis-stream ceiling for this phone (round 56): the largest
      // size CameraX can actually feed the detector, usually below the photo sizes
      // the camera advertises.
      _analysisCeilingInfo(),
      // Why the list may not match the lenses you can physically count.
      const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: Text(
          'These are the cameras Android lets this app use. Phone makers choose '
          'which lenses to expose: on many phones (e.g. Xiaomi/MIUI) the '
          'ultra-wide, macro and telephoto lenses are reserved for the built-in '
          'camera app, so they won\'t appear here even though you can see them on '
          'the back of the phone. That\'s a phone/OS limitation, not a fault of '
          'this app. "Usable for inference" means the detector can read that '
          'camera\'s frames.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ),
      // Rear cameras first — these are what fieldwork uses.
      const Padding(
        padding: EdgeInsets.only(top: 4, bottom: 4),
        child: Text(
          'Rear cameras (used for monitoring)',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
      if (rear.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'No rear camera is exposed to this app on this phone.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        )
      else
        for (final cam in rear) _cameraInfoCard(cam),
      if (usableRear < 2)
        const Padding(
          padding: EdgeInsets.only(top: 4, bottom: 4),
          child: Text(
            'Only one rear camera is available to apps on this phone, so the '
            'lens-switch button stays off. Any extra lenses (ultra-wide / macro / '
            'telephoto) are reserved by the manufacturer.',
            style: TextStyle(color: Colors.amberAccent, fontSize: 12),
          ),
        ),
      // Front cameras, collapsed — not used for monitoring.
      if (front.isNotEmpty)
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            iconColor: Colors.white54,
            collapsedIconColor: Colors.white54,
            title: const Text(
              'Front cameras — not used for monitoring',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            childrenPadding: const EdgeInsets.only(bottom: 8),
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(
                  'Selfie-facing cameras. Field monitoring uses the rear cameras, '
                  'so these aren\'t selectable. Some phones (e.g. this Samsung) '
                  'report a second, duplicate front camera — that\'s a firmware '
                  'quirk, not an extra physical lens.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              for (final cam in front) _cameraInfoCard(cam),
            ],
          ),
        ),
    ];
  }

  /// Friendly, plain-language name for a camera, derived from its facing and the
  /// native lens-type classification (which comes from the 35mm-equivalent focal
  /// length). The technical id/focal detail is shown separately on the card.
  String _cameraTitle(String facing, String type) {
    if (facing != 'back') return 'Front camera';
    switch (type) {
      case 'Wide':
        return 'Main (wide) camera';
      case 'Ultra wide':
        return 'Ultra-wide camera';
      case 'Telephoto':
        return 'Telephoto camera';
      default:
        return 'Rear camera';
    }
  }

  /// One card describing a single camera/lens, with a colour-coded usability
  /// badge (green = usable for inference, amber = zoom-only hidden lens,
  /// grey = reported but not bindable) and a plain-language reason.
  Widget _cameraInfoCard(Map<String, dynamic> cam) {
    final usable = cam['usableForInference'] == true;
    final physicalOnly = cam['isPhysicalOnly'] == true;
    final facing = (cam['lensFacing'] ?? 'unknown').toString();
    final type = (cam['lensType'] ?? 'unknown').toString();
    final id = (cam['cameraId'] ?? '?').toString();
    final equiv = (cam['equiv35mm'] as num?)?.toDouble() ?? 0.0;
    final focals =
        (cam['focalLengthsMm'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        const <double>[];
    final analysis =
        (cam['analysisSizes'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];
    final reason = (cam['reason'] ?? '').toString();

    final Color badgeColor = usable
        ? Colors.greenAccent
        : (physicalOnly ? Colors.amberAccent : Colors.white38);
    final String badgeText = usable
        ? 'Usable for inference'
        : (physicalOnly ? 'Zoom-only (hidden lens)' : 'Not bindable');

    final String title = _cameraTitle(facing, type);

    String detailText() {
      final parts = <String>['id $id'];
      if (focals.isNotEmpty) {
        final list = focals.map((f) => '${f.toStringAsFixed(1)} mm').join(', ');
        final eq = equiv > 0 ? ' (~${equiv.round()} mm eq.)' : '';
        parts.add('focal $list$eq');
      }
      if (physicalOnly) parts.add('physical sub-camera');
      return parts.join(' • ');
    }

    return Card(
      color: Colors.white10,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: badgeColor),
                  ),
                  child: Text(
                    badgeText,
                    style: TextStyle(
                      color: badgeColor,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SelectableText(
              detailText(),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            if (analysis.isNotEmpty)
              SelectableText(
                'analysis sizes: ${analysis.take(4).join(', ')}'
                '${analysis.length > 4 ? ', …' : ''}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            if (reason.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SelectableText(
                  reason,
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Reads the persisted "hide setup tips" flag so the switch reflects the
  /// current state when the sheet opens.
  Future<void> _loadSetupTipsPref() async {
    final prefs = await SharedPreferences.getInstance();
    final hidden = prefs.getBool(kHideSessionInfoPrefKey) ?? false;
    if (!mounted) return;
    setState(() => _showSetupTips = !hidden);
  }

  /// Turns the one-time setup reminder on/off by writing the persisted flag.
  /// On = reminder shows next time a session screen opens; Off = stays hidden.
  Future<void> _setShowSetupTips(bool show) async {
    setState(() => _showSetupTips = show);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kHideSessionInfoPrefKey, !show);
  }

  // --- Tab 4: Session-summary graph sampling -----------------------------

  Widget _summaryTab() => ListView(
    children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Compute graphs automatically',
          style: TextStyle(color: Colors.white),
        ),
        subtitle: const Text(
          'Build the end-of-session graphs (visit timeline, temperature, FPS, '
          'power) as soon as the summary opens. Turn off to compute them only '
          'when you tap "Generate graphs" — handy for very long sessions where '
          'the full-log parse takes a moment. Also applies when re-opening a '
          'past session.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        isThreeLine: true,
        value: _c.autoComputeGraphs,
        onChanged: (v) =>
            setState(() => _c = _c.copyWith(autoComputeGraphs: v)),
      ),
      const Divider(color: Colors.white24),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Square (1:1) export crops',
          style: TextStyle(color: Colors.white),
        ),
        subtitle: const Text(
          'Force the crop-and-export box in the summary photo viewer to a '
          'square. Off = free rectangle that can hug the insect\'s shape. '
          'The "1:1" chip next to the crop box toggles this same setting.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        isThreeLine: true,
        value: _c.cropSquareLock,
        onChanged: (v) => setState(() => _c = _c.copyWith(cropSquareLock: v)),
      ),
      const Divider(color: Colors.white24),
      _label(
        'How often the end-of-session graphs are sampled while recording. '
        'Lower values give finer graphs but measure more often; the defaults are '
        'deliberately light so the detection pipeline is not slowed down.',
      ),
      const SizedBox(height: 12),

      NumericSettingField(
        label: 'Frame-rate sample',
        value: _c.fpsSampleSeconds.toDouble(),
        min: 1,
        max: 60,
        isInt: true,
        unitSuffix: 's',
        helperText:
            'How often (1–60 s) the frame rate is sampled for the '
            'graph. Already computed every frame, so a sample is essentially '
            'free. Default 5 s.',
        onChanged: (v) =>
            setState(() => _c = _c.copyWith(fpsSampleSeconds: v.round())),
      ),

      const Divider(color: Colors.white24),

      NumericSettingField(
        label: 'Temperature sample',
        value: _c.thermalSampleSeconds.toDouble(),
        min: 1,
        max: 120,
        isInt: true,
        unitSuffix: 's',
        helperText:
            'How often (1–120 s) the phone temperature is sampled. '
            'A system call, so kept coarser — heat changes slowly. Default '
            '10 s.',
        onChanged: (v) =>
            setState(() => _c = _c.copyWith(thermalSampleSeconds: v.round())),
      ),

      const Divider(color: Colors.white24),

      NumericSettingField(
        label: 'Power sample',
        value: _c.powerSampleSeconds.toDouble(),
        min: 1,
        max: 120,
        isInt: true,
        unitSuffix: 's',
        helperText:
            'How often (1–120 s) battery power (current × voltage) and remaining '
            'charge are sampled for the energy graphs. A system call, so kept '
            'coarse — power changes slowly. Default 10 s.',
        onChanged: (v) =>
            setState(() => _c = _c.copyWith(powerSampleSeconds: v.round())),
      ),
    ],
  );

  /// Dropdown of the camera's actual HAL-supported analysis sizes (verbatim — no
  /// 32-rounding, which would force a non-native size). Labelled "short × long".
  // Parses the estimated analysis ceiling ("WxH") into (area, short, long). Zero
  // area means "unknown" (no native ceiling reported). See round 56.
  (int area, int lo, int hi) get _ceiling {
    final recMax = (widget.analysisCeiling['recommendedMax'] as String?) ?? '';
    if (!recMax.contains('x')) return (0, 0, 0);
    final p = recMax.split('x');
    final w = int.tryParse(p[0]) ?? 0,
        h = int.tryParse(p.length > 1 ? p[1] : '0') ?? 0;
    return (w * h, w < h ? w : h, w < h ? h : w);
  }

  Widget _streamResolutionDropdown() {
    final all = widget.streamResolutions.isNotEmpty
        ? widget.streamResolutions
        : const ['640x480', '1280x960', '1600x1200'];
    final current = '${_c.streamWidth}x${_c.streamHeight}';
    final (ceilArea, ceilLo, ceilHi) = _ceiling;
    int area(String wh) {
      final p = wh.split('x');
      return (int.tryParse(p[0]) ?? 0) *
          (int.tryParse(p.length > 1 ? p[1] : '0') ?? 0);
    }

    // Round 123 (Samsung field test): sizes above the analysis ceiling used
    // to be listed with a "(may cap to …)" tag — offering a size the phone
    // will shrink anyway just annoys. They are now filtered OUT, with one
    // exception: the user's already-saved choice stays listed (annotated) so
    // an old config remains visible and re-selectable. If the ceiling would
    // remove everything, the unfiltered list is kept.
    var options = all;
    if (ceilArea > 0) {
      final within = all
          .where((wh) => area(wh) <= ceilArea || wh == current)
          .toList();
      if (within.isNotEmpty) options = within;
    }
    String label(String wh) {
      final p = wh.split('x');
      final w = int.tryParse(p[0]) ?? 0,
          h = int.tryParse(p.length > 1 ? p[1] : '0') ?? 0;
      final lo = w < h ? w : h, hi = w < h ? h : w;
      // Only reachable for the kept legacy choice above the ceiling.
      if (ceilArea > 0 && w * h > ceilArea) {
        return '$lo × $hi  (phone will shrink it to $ceilLo×$ceilHi)';
      }
      return '$lo × $hi';
    }

    // Round 109 "Auto": the app picks the smallest supported size whose short
    // side reaches the saved-photo target (round 122: the user's actual
    // "Saved photo side" value, not a fixed 1024), so fast (no-stall) ROI
    // crops can meet it and the laggy high-res photo path is needed less
    // often. On a phone that can't reach the target at all, the pick is the
    // largest size the phone streams. Only computable from real device
    // probes; on the preset fallback the auto item still exists but keeps
    // the current size until probes land.
    final target = _c.targetRoiSavedPx;
    final autoPick = widget.streamResolutions.isEmpty
        ? null
        : autoStreamResolution(
            widget.streamResolutions,
            ceilingArea: ceilArea,
            minShortSide: target,
          );
    const autoValue = 'auto';
    final String autoLabel;
    if (autoPick == null) {
      autoLabel = 'Auto (device-chosen)';
    } else if ((autoPick.$1 < autoPick.$2 ? autoPick.$1 : autoPick.$2) >=
        target) {
      autoLabel =
          'Auto — matches Saved photo side ($target px): '
          '${label('${autoPick.$1}x${autoPick.$2}')}';
    } else {
      autoLabel =
          'Auto — largest this phone streams '
          '(${label('${autoPick.$1}x${autoPick.$2}')}, below $target px)';
    }

    return DropdownButton<String>(
      value: !_c.streamResolutionExplicit
          ? autoValue
          : (options.contains(current) ? current : null),
      isExpanded: true,
      dropdownColor: Colors.black87,
      hint: Text(
        'Device default (nearest to ${_c.streamHeight} × ${_c.streamWidth})',
        style: const TextStyle(color: Colors.white54),
      ),
      items: [
        DropdownMenuItem(
          value: autoValue,
          child: Text(autoLabel, style: const TextStyle(color: Colors.white)),
        ),
        ...options.map(
          (wh) => DropdownMenuItem(
            value: wh,
            child: Text(label(wh), style: const TextStyle(color: Colors.white)),
          ),
        ),
      ],
      onChanged: (v) {
        if (v == null) return;
        if (v == autoValue) {
          setState(
            () => _c = _c.copyWith(
              streamResolutionExplicit: false,
              // Apply the computed size right away so the choice is WYSIWYG;
              // without probes the camera screen applies it once they land.
              streamWidth: autoPick?.$1,
              streamHeight: autoPick?.$2,
            ),
          );
          return;
        }
        final p = v.split('x');
        setState(
          () => _c = _c.copyWith(
            streamWidth: int.parse(p[0]),
            streamHeight: int.parse(p[1]),
            streamResolutionExplicit: true,
          ),
        );
      },
    );
  }

  // Plain-language note under the stream dropdown. Explains that the live analysis
  // stream is capped by the phone (not a bug), that this does NOT affect detection
  // accuracy, and that detailed photos come from the high-res path. See round 56.
  Widget _streamCeilingNote() {
    final (ceilArea, ceilLo, ceilHi) = _ceiling;
    final hwLevel = (widget.analysisCeiling['hardwareLevel'] as String?) ?? '';
    final parts = <String>[
      'This is the live preview/analysis stream the AI reads. It does not change '
          'detection accuracy — every frame is shrunk to the model’s own input '
          'size anyway. It only affects the sharpness of fast (live-frame) ROI '
          'photos; the “ROI photo source” setting below controls when a photo '
          'pays for a full-resolution high-res capture instead.',
      'Larger streams cost more per-frame processing (heat and battery). '
          '“Auto” picks the smallest size that still lets fast crops reach the '
          'saved-photo target; on a phone that runs hot, pick a small size '
          'manually.',
    ];
    if (ceilArea > 0) {
      parts.add(
        'Your phone can stream at most about $ceilLo×$ceilHi px to the analysis '
        'pipeline${hwLevel.isNotEmpty && hwLevel != 'unknown' ? ' (camera level: $hwLevel)' : ''}. '
        'The camera supports larger sizes for photo capture, but the live '
        'stream would be shrunk to this size anyway, so they are not listed.',
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        parts.join(' '),
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
    );
  }

  // Camera-info panel block: hardware level + estimated analysis-stream ceiling.
  // See round 56. Hidden when the device didn't report a ceiling.
  Widget _analysisCeilingInfo() {
    final (ceilArea, ceilLo, ceilHi) = _ceiling;
    if (ceilArea <= 0) return const SizedBox.shrink();
    final hwLevel = (widget.analysisCeiling['hardwareLevel'] as String?) ?? '';
    final dw = (widget.analysisCeiling['displayW'] as num?)?.toInt() ?? 0;
    final dh = (widget.analysisCeiling['displayH'] as num?)?.toInt() ?? 0;
    final lines = <String>[
      'Estimated live-stream ceiling: ~$ceilLo×$ceilHi px',
      if (hwLevel.isNotEmpty && hwLevel != 'unknown')
        'Camera hardware level: $hwLevel',
      if (dw > 0 && dh > 0) 'Screen: $dw×$dh px',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: SelectableText(
                l,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'The camera advertises larger sizes for photo capture, but when the live '
              'preview, the AI stream and photo capture run together it can only '
              'feed the detector up to about this size — so larger stream choices '
              'are scaled down. This does not affect detection accuracy.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text(text, style: const TextStyle(color: Colors.white70)),
  );
}

/// Asks for a direct link to a .tflite model (e.g. a GitHub release asset),
/// downloads it with a progress bar and pops the saved file path — or null on
/// cancel. Errors show inline so the URL can be corrected without retyping.
class _DownloadModelDialog extends StatefulWidget {
  const _DownloadModelDialog();

  @override
  State<_DownloadModelDialog> createState() => _DownloadModelDialogState();
}

class _DownloadModelDialogState extends State<_DownloadModelDialog> {
  final _url = TextEditingController();
  bool _downloading = false;
  bool _cancelRequested = false;
  String? _error;
  int _received = 0;
  int? _total;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _downloading = true;
      _cancelRequested = false;
      _error = null;
      _received = 0;
      _total = null;
    });
    try {
      final path = await ModelCatalog.downloadModel(
        _url.text,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
        isCancelled: () => _cancelRequested,
      );
      if (mounted) Navigator.of(context).pop(path);
    } catch (e) {
      if (!mounted) return;
      if (_cancelRequested) {
        Navigator.of(context).pop(); // user cancelled; partial file cleaned up
        return;
      }
      setState(() {
        _downloading = false;
        // Exception.toString() prefixes "Exception: " — drop it for the UI.
        _error = '$e'.replaceFirst('Exception: ', '');
      });
    }
  }

  String get _progressLabel {
    String mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
    final total = _total;
    return total != null
        ? 'Downloading… ${mb(_received)} of ${mb(total)} MB'
        : 'Downloading… ${mb(_received)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final validUrl = modelFileNameFromUrl(_url.text) != null;
    return AlertDialog(
      title: const Text('Download model'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _url,
            enabled: !_downloading,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: 'Link to a .tflite model file',
              helperText:
                  'Model links are published at\n'
                  'github.com/valentinitnelav/fauna-pulse/releases',
              helperMaxLines: 3,
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (_downloading) ...[
            const SizedBox(height: 14),
            LinearProgressIndicator(
              value: _total != null && _total! > 0 ? _received / _total! : null,
            ),
            const SizedBox(height: 6),
            Text(
              _progressLabel,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '⚠ $_error',
                style: const TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 13,
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          // While downloading, Cancel signals downloadModel between chunks;
          // its cleanup deletes the partial file, then _start pops the dialog.
          onPressed: _downloading && _cancelRequested
              ? null
              : () {
                  if (_downloading) {
                    setState(() => _cancelRequested = true);
                  } else {
                    Navigator.of(context).pop();
                  }
                },
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _downloading || !validUrl ? null : _start,
          child: const Text(
            'Download',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
