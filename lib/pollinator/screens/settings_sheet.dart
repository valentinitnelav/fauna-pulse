// Pollinator Monitor — session settings sheet.
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

import '../models/model_catalog.dart';
import '../models/roi.dart';
import '../models/session_config.dart';
import '../tracking/byte_track.dart';
import '../widgets/numeric_setting_field.dart';

class SettingsSheet extends StatefulWidget {
  final SessionConfig config;

  /// Camera-supported analysis stream resolutions ("WxH"), from the HAL. When
  /// empty the sheet falls back to a standard preset list.
  final List<String> streamResolutions;

  /// Estimated ceiling for what CameraX ImageAnalysis can actually stream on this
  /// phone (the [streamResolutions] above are still/preview sizes and over-promise
  /// — see round 56). Keys: `hardwareLevel`, `recommendedMax` ("WxH"),
  /// `previewBoundW`/`previewBoundH`, `displayW`/`displayH`. Used to flag sizes the
  /// device will silently shrink. Empty when unavailable.
  final Map<String, dynamic> analysisCeiling;

  /// Full-resolution still size the camera can deliver (from the probe), shown to
  /// explain what "Full-resolution ROI photos" captures. 0 when unknown.
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

  /// Whether the currently-selected model id is one we know is actually present
  /// (a bundled/imported file, or the bundled nano). Used to warn when an
  /// official size is picked whose file isn't on the device.
  bool get _selectedIsAvailable {
    final id = _c.modelPath;
    if (ModelCatalog.bundledIds.contains(id)) return true;
    return _models.any((m) => m.id == id && m.source != ModelSource.official);
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
              const TabBar(
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white54,
                indicatorColor: Colors.lightBlueAccent,
                labelPadding: EdgeInsets.symmetric(horizontal: 2),
                tabs: [
                  Tab(icon: Icon(Icons.tune, size: 20), text: 'Setup'),
                  Tab(icon: Icon(Icons.memory, size: 20), text: 'AI'),
                  Tab(icon: Icon(Icons.photo_camera, size: 20), text: 'Camera'),
                  Tab(icon: Icon(Icons.show_chart, size: 20), text: 'Graphs'),
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

      NumericSettingField(
        label: 'Photo step',
        value: _c.stepSeconds,
        min: 0.5,
        max: 10,
        decimals: 1,
        unitSuffix: 's',
        helperText:
            'Seconds between saved ROI photos of the same track '
            '(0.5–10). Default 1.',
        onChanged: (v) => setState(() => _c = _c.copyWith(stepSeconds: v)),
      ),
      NumericSettingField(
        label: 'Photo duration per track',
        value: _c.durationSeconds,
        min: 1,
        max: 60,
        decimals: 1,
        unitSuffix: 's',
        helperText:
            'How long photos keep being saved for one track id '
            '(1–60). Should be a whole multiple of the step.',
        onChanged: (v) => setState(() => _c = _c.copyWith(durationSeconds: v)),
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
        subtitle: const Text(
          'The blue boxes with "#id … Conf.: 0.xy" over each insect.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        value: _c.showBoxes,
        onChanged: (v) => setState(() => _c = _c.copyWith(showBoxes: v)),
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

  // --- Tab 2: AI pipeline -------------------------------------------------

  Widget _aiPipelineTab() {
    final model = _selectedModel;
    return ListView(
      children: [
        Row(
          children: [
            Expanded(child: _label('Detection model')),
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
                Text(
                  'Scanning models…',
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            ),
          )
        else
          DropdownButton<String>(
            value: _models.any((m) => m.id == _c.modelPath)
                ? _c.modelPath
                : null,
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
        if (!_modelsLoading &&
            ModelCatalog.officialModels.containsKey(_c.modelPath) &&
            !_selectedIsAvailable)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              '⚠ Only the nano model ships with the app. Until the '
              'selected size is added (or a custom model is imported), '
              'detection keeps running nano — so the frame rate will not '
              'change.',
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
            // shut when the user raises Confidence.
            final p = _c.trackerParams;
            final minHigh = (v + _highScoreBuffer).clamp(0.30, 0.95);
            _c = _c.copyWith(
              confidenceThreshold: v,
              trackerParams:
                  p.highThresh < minHigh ? p.copyWith(highThresh: minHigh) : p,
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

        const Divider(color: Colors.white24),
        const Text(
          'Tracker',
          style: TextStyle(color: Colors.white70, fontSize: 16),
        ),
        _trackerFields(),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _trackerFields() {
    final p = _c.trackerParams;
    void update(ByteTrackParams np) =>
        setState(() => _c = _c.copyWith(trackerParams: np));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(
          'Tracking links each insect\'s detections across frames into one '
          '"visit" with a stable ID — the basis of the visitation rate. With '
          'insects that land and linger, the main error is one real visit being '
          'split into several IDs (which inflates the count), so these defaults '
          'lean toward keeping an existing ID alive rather than starting new '
          'ones. Two settings work together: a detection is only seen by the '
          'tracker if it first passes the Confidence threshold (above); of '
          'those, boxes at/above "High-score" can start a new ID, while weaker '
          'ones can only keep an existing insect\'s ID alive.',
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
          label: 'Min hits to confirm',
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
          onChanged: (v) =>
              setState(() => _c = _c.copyWith(minHitsSeconds: v)),
        ),
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
      ],
    );
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
      const SizedBox(height: 16),

      _label(
        'ROI photo source. Auto (recommended): each photo is a fast crop of '
        'the live frame when that already meets the minimum size below, and a '
        'full-resolution still'
        '${widget.sensorWidth > 0 ? ' (up to ${widget.sensorWidth}×${widget.sensorHeight} on this phone)' : ''}'
        ' only when the ROI is too small in the stream. Stills put far more '
        'pixels on a small flower, but each one briefly dips the frame rate '
        'and lands a fraction of a second after the detection.',
      ),
      DropdownButton<RoiCaptureMode>(
        value: _c.captureMode,
        isExpanded: true,
        dropdownColor: Colors.black87,
        items: const [
          DropdownMenuItem(
            value: RoiCaptureMode.auto,
            child: Text(
              'Auto — still only when needed (recommended)',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          DropdownMenuItem(
            value: RoiCaptureMode.fast,
            child: Text(
              'Fast crops only (live frame)',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          DropdownMenuItem(
            value: RoiCaptureMode.still,
            child: Text(
              'Full-resolution stills always',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
        onChanged: (m) =>
            setState(() => _c = _c.copyWith(captureMode: m)),
      ),
      NumericSettingField(
        label: 'Saved photo side (px)',
        value: _c.targetRoiSavedPx.toDouble(),
        min: 128,
        max: 2048,
        isInt: true,
        helperText:
            'One number (round 63, replacing the earlier min/max pair): every '
            'photo saves at exactly this size whenever the ROI can supply it — '
            'larger crops are downscaled to it, and in Auto mode a photo takes '
            'a full still when the fast crop would come out smaller. Photos '
            'are NEVER enlarged to reach it: stretching pixels invents no '
            'detail and would hurt later insect identification. When even a '
            'still cannot reach it the photo saves smaller and the ROI readout '
            'shows a ⚠ — move the phone closer or switch lens. Snapped to a '
            'multiple of 32; default 1024 (uniform files, roomy for cropping '
            'insects out for a classifier).',
        onChanged: (v) => setState(
          () => _c = _c.copyWith(targetRoiSavedPx: snapToMultipleOf32(v)),
        ),
      ),
      const Divider(color: Colors.white24),

      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Auto-adjust inference rate (prevents overheating)',
          style: TextStyle(color: Colors.white),
        ),
        value: _c.autoThrottle,
        onChanged: (v) => setState(() => _c = _c.copyWith(autoThrottle: v)),
      ),
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
            () => _c = _c.copyWith(inferenceFps: r == 0 ? 0 : (r < 5 ? 5 : r)),
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
      const Divider(color: Colors.white24),

      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Motion gate (experimental): sleep while the flower is empty',
          style: TextStyle(color: Colors.white),
        ),
        subtitle: const Text(
          'Runs the detector only when something moves inside the ROI (a cheap '
          'brightness check watches every frame). Big heat/battery saving during '
          'long empty periods. Designed for a MOUNTED phone: handheld shake '
          'counts as motion, so in the hand the gate stays awake — that is '
          'normal, not a fault. Off by default — validate against an always-on '
          'session before trusting it for real counts.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        isThreeLine: true,
        value: _c.motionGateEnabled,
        onChanged: (v) => setState(() => _c = _c.copyWith(motionGateEnabled: v)),
      ),
      if (_c.motionGateEnabled) ...[
        NumericSettingField(
          label: 'Wake duration after motion',
          value: _c.motionGateWakeSeconds,
          min: 0.5,
          max: 60,
          decimals: 1,
          unitSuffix: 's',
          helperText:
              'How long the detector keeps running after the last movement or '
              'detection. Every new detection restarts this window, so a sitting '
              'insect is not lost. Longer = safer recall, less heat saving. '
              'Default 3 s.',
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
            () => _c = _c.copyWith(motionGatePixelDelta: v.round().clamp(5, 100)),
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
          onChanged: (v) => setState(
            () => _c = _c.copyWith(motionGateAreaFraction: v / 100),
          ),
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
      // size CameraX can actually feed the detector, usually below the still sizes
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
    final options = widget.streamResolutions.isNotEmpty
        ? widget.streamResolutions
        : const ['640x480', '1280x960', '1600x1200'];
    final current = '${_c.streamWidth}x${_c.streamHeight}';
    final (ceilArea, ceilLo, ceilHi) = _ceiling;
    String label(String wh) {
      final p = wh.split('x');
      final w = int.tryParse(p[0]) ?? 0,
          h = int.tryParse(p.length > 1 ? p[1] : '0') ?? 0;
      final lo = w < h ? w : h, hi = w < h ? h : w;
      // Flag sizes the analysis pipeline can't actually stream on this phone — it
      // would silently shrink them to the ceiling (round 56). Still selectable.
      if (ceilArea > 0 && w * h > ceilArea) {
        return '$lo × $hi  (may cap to $ceilLo×$ceilHi)';
      }
      return '$lo × $hi';
    }

    return DropdownButton<String>(
      value: options.contains(current) ? current : null,
      isExpanded: true,
      dropdownColor: Colors.black87,
      hint: Text(
        'Device default (nearest to ${_c.streamHeight} × ${_c.streamWidth})',
        style: const TextStyle(color: Colors.white54),
      ),
      items: options
          .map(
            (wh) => DropdownMenuItem(
              value: wh,
              child: Text(
                label(wh),
                style: const TextStyle(color: Colors.white),
              ),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v == null) return;
        final p = v.split('x');
        setState(
          () => _c = _c.copyWith(
            streamWidth: int.parse(p[0]),
            streamHeight: int.parse(p[1]),
          ),
        );
      },
    );
  }

  // Plain-language note under the stream dropdown. Explains that the live analysis
  // stream is capped by the phone (not a bug), that this does NOT affect detection
  // accuracy, and that sharp photos come from full-resolution stills. See round 56.
  Widget _streamCeilingNote() {
    final (ceilArea, ceilLo, ceilHi) = _ceiling;
    final hwLevel = (widget.analysisCeiling['hardwareLevel'] as String?) ?? '';
    final parts = <String>[
      'This is the live preview/analysis stream the AI reads. It does not change '
          'detection accuracy — every frame is shrunk to the model’s own input '
          'size anyway. It only affects the sharpness of fast (live-frame) ROI '
          'photos; for the sharpest crops use “Full-resolution ROI photos” below.',
    ];
    if (ceilArea > 0) {
      parts.add(
        'Your phone can stream at most about $ceilLo×$ceilHi px to the analysis '
        'pipeline${hwLevel.isNotEmpty && hwLevel != 'unknown' ? ' (camera level: $hwLevel)' : ''}. '
        'Larger choices are offered because the camera supports them for stills, '
        'but the live stream will be scaled down to this size.',
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
      if (hwLevel.isNotEmpty && hwLevel != 'unknown') 'Camera hardware level: $hwLevel',
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
              'The camera advertises larger sizes for stills, but when the live '
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
