// FaunaPulse — session settings sheet.
//
// Opened from the live preview (a bottom sheet). Edits a working copy of the
// SessionConfig and returns it via Navigator.pop when the user taps Apply, so
// the caller can persist it and push the new thresholds to the detector.
//
// The controls are grouped into four tabs BY USER INTENT (round 159), so the
// sheet stays readable and a citizen scientist can run a session touching only
// the folder, the capture trigger and the session length:
//   • Setup — what am I recording? Folder, trigger, session length, schedule,
//     on-screen display toggles (folded).
//   • AI — how does detection behave? Model, confidence, visit tracking;
//     engine/threshold knobs folded.
//   • Photos — what do saved photos look like? Size, photo source, viewer;
//     the live camera stream folded.
//   • Power — heat, battery and rates: inference throttle, camera fps cap,
//     motion gate, diagnostic graph sampling.
// Expert-only controls sit inside collapsed "Advanced" folds (FoldSection);
// every control stays user-adjustable — folding is discoverability, never
// removal (owner rule). Since round 181 every control's explanation hides
// behind a small ⓘ (the setting_help.dart widgets), matching the numeric
// fields' round-159 pattern; only live status notes and warnings that depend
// on the user's current values stay always visible.
//
// Every numeric control is a typed number box (NumericSettingField), not a
// slider. Sliders were unusable here: a horizontal drag on a slider was stolen
// by the swipeable TabBarView (the tab slid sideways instead of the value
// moving). A number box has no horizontal drag, and lets the user enter exact
// values. A box never takes a number outside its range (round 313: it says
// what is allowed instead), and no control changes another stored setting:
// rules between settings are applied where the values are used, and shown
// next to the box (the camera cap and the inference rates, the search
// margins, New-track confidence).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../capture/roi_capture.dart';
import '../capture/roi_video.dart';
import '../models/model_catalog.dart';
import '../models/model_file_kind.dart';
import '../models/roi.dart';
import '../models/schedule_window.dart';
import '../models/session_config.dart';
import '../tracking/byte_track.dart';
import '../tracking/c_biou_track.dart';
import '../widgets/duration_setting_field.dart';
import '../widgets/numeric_setting_field.dart';
import '../widgets/setting_help.dart';
import '../widgets/tracker_tuning_fields.dart';
import '../widgets/dialog_title.dart';
import 'models_screen.dart';

part 'settings_sheet/session_tab.dart';
part 'settings_sheet/ai_tab.dart';
part 'settings_sheet/photos_tab.dart';
part 'settings_sheet/power_tab.dart';
part 'settings_sheet/camera_info.dart';

/// The sheet's working copy, for the caller (round 313): closing the sheet
/// without Apply (Back, a tap above it, a swipe down) returns null, and the
/// camera screen then offers to apply what was changed instead of losing it
/// silently. Tests read it to see what each control stores.
class SettingsDraft {
  SessionConfig? value;
}

class SettingsSheet extends StatefulWidget {
  final SessionConfig config;

  /// Updated with the working copy after every change (see [SettingsDraft]).
  final SettingsDraft? draft;

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
  /// + reason, supported analysis sizes). Shown read-only under the Photos tab so
  /// a user can see which lenses their phone actually offers the detector. Empty
  /// when the camera wasn't running when the sheet was opened.
  final List<Map<String, dynamic>> cameraDiagnostics;

  const SettingsSheet({
    super.key,
    required this.config,
    this.draft,
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

  /// True while the engine benchmark runs (disables its button).
  bool _benchmarkRunning = false;

  /// Why the typed session length was not taken (0 or empty), or null.
  String? _sessionLenError;

  /// The working copy as Apply would return it.
  SessionConfig get _result => _c.copyWith(folderName: _folder.text);

  /// Every change goes through setState, so the caller's [SettingsDraft]
  /// always holds what Apply would return.
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    widget.draft?.value = _result;
  }

  @override
  void initState() {
    super.initState();
    _c = widget.config.normalizedFpsCaps();
    _folder = TextEditingController(text: _c.folderName);
    // Show whole hours when the saved length divides cleanly into hours
    // (e.g. 120 → "2 h"); otherwise show minutes.
    _sessionInHours = _c.sessionMinutes >= 60 && _c.sessionMinutes % 60 == 0;
    _sessionLen = TextEditingController(text: _sessionLengthText());
    widget.draft?.value = _result;
    _reloadModels();
  }

  /// The stored session length in the chosen unit ("90" min, "1.5" h).
  String _sessionLengthText() {
    if (!_sessionInHours) return '${_c.sessionMinutes}';
    final h = _c.sessionMinutes / 60;
    return h == h.roundToDouble() ? '${h.round()}' : h.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
  }

  /// Reads the session-length text field in the current unit and writes the
  /// resulting whole-minute count back into the config. Round 313: 0 or an
  /// empty box is refused with a note instead of being ignored silently.
  void _applySessionLength() {
    final n = double.tryParse(_sessionLen.text.trim().replaceAll(',', '.'));
    final minutes = n == null ? 0 : (_sessionInHours ? n * 60 : n).round();
    if (minutes < 1) {
      setState(() => _sessionLenError = 'At least 1 minute: the length stays ${_c.sessionMinutes} min.');
      return;
    }
    setState(() {
      _sessionLenError = null;
      _c = _c.copyWith(sessionMinutes: minutes);
    });
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

  /// Opens the AI models screen (round 267: models are added and deleted
  /// there, not here) and re-reads the list on return.
  Future<void> _manageModels() async {
    await openModelsScreen(context);
    if (mounted) await _reloadModels();
  }

  /// False once the scan found no detection model on the phone (round 268);
  /// true while scanning, so nothing flickers.
  bool get _hasDetector => _modelsLoading || _models.isNotEmpty;

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
                  // The Detection tab ("AI" until round 271) dims in the
                  // no-detection capture modes (r147): its settings have no
                  // effect there. It stays tappable — the tab body shows a
                  // notice saying why it is inactive.
                  if (_c.detectorEnabled)
                    const Tab(icon: Icon(Icons.center_focus_strong_outlined, size: 20), text: 'Detection')
                  else
                    const Tab(
                      icon: Icon(Icons.center_focus_strong_outlined, size: 20, color: Colors.white24),
                      child: Text(
                        'Detection',
                        style: TextStyle(color: Colors.white24),
                      ),
                    ),
                  const Tab(
                    icon: Icon(Icons.photo_camera, size: 20),
                    text: 'Photos',
                  ),
                  const Tab(icon: Icon(Icons.bolt, size: 20), text: 'Power'),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TabBarView(
                  children: [
                    _sessionTab(),
                    _aiPipelineTab(),
                    _photosTab(),
                    _powerTab(),
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
                    onPressed: () {
                      // A box that still has focus settles its number when it
                      // loses it (a refused number puts the old value back);
                      // the focus change runs in a microtask, so the result is
                      // read after it.
                      FocusManager.instance.primaryFocus?.unfocus();
                      Future.microtask(() {
                        if (context.mounted) Navigator.of(context).pop(_result);
                      });
                    },
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

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text(text, style: const TextStyle(color: Colors.white70)),
  );
}
