// FaunaPulse (round 308, owner): "Detection, track ID and identification
// settings" of "Find animals in videos" (video_analysis_screen.dart). Every
// number to tune, in three cards in the colours of Download & import models:
// Detection, Track IDs (the tracker's settings, the videos' own: trying
// values here never changes the live camera) and Identification (the
// settings of Identify organisms, greyed while "Also identify them" will not
// run). Reachable before the first run; everything is saved as it changes,
// and the video screen reads the values again when this screen closes.

import 'dart:math';

import 'package:flutter/material.dart';

import '../identification/identification_assets.dart';
import '../logging/app_error_hooks.dart';
import '../models/session_config.dart';
import '../tracking/byte_track.dart';
import '../tracking/c_biou_track.dart';
import '../widgets/home_button.dart';
import '../widgets/model_kind_panel.dart';
import '../widgets/numeric_setting_field.dart';
import '../widgets/setting_help.dart';
import '../widgets/tracker_tuning_fields.dart';
import 'identify_settings_fields.dart';
import 'video_analysis_screen.dart' show VideoAnalysisPrefs;

class VideoTuningScreen extends StatefulWidget {
  /// The video screen's settings: changed in place, saved on every change.
  final VideoAnalysisPrefs prefs;

  /// Length of the chosen session's clips in ms (0 when unknown): the frame
  /// count of a run.
  final int totalMs;

  /// The rate the session's frames were analyzed at by its last run when no
  /// new analysis can change it (its videos were deleted), or null: the rate
  /// set here, which the next run uses. Minimum track length in detections.
  final double? analysedFps;

  /// Clips recorded while live detection ran: their track IDs are for
  /// comparison, no frames are kept, and they are named from the session's
  /// ⋮ menu.
  final bool liveAi;

  /// Kept frames saved now, which finding the track IDs again with "Keep
  /// frames" off removes.
  final int keptSaved;

  /// "Also identify them" on the video screen, and the model and name list
  /// chosen there (file names, null when none is ready).
  final bool alsoIdentify;
  final String? identifyModel;
  final String? identifyList;

  const VideoTuningScreen({
    super.key,
    required this.prefs,
    this.totalMs = 0,
    this.analysedFps,
    this.liveAi = false,
    this.keptSaved = 0,
    this.alsoIdentify = false,
    this.identifyModel,
    this.identifyList,
  });

  @override
  State<VideoTuningScreen> createState() => _VideoTuningScreenState();
}

class _VideoTuningScreenState extends State<VideoTuningScreen> {
  VideoAnalysisPrefs get _p => widget.prefs;
  IdentifyPrefs? _identify;

  @override
  void initState() {
    super.initState();
    _loadIdentify();
  }

  Future<void> _loadIdentify() async {
    try {
      final p = await IdentifyPrefs.load();
      if (mounted) setState(() => _identify = p);
    } catch (e) {
      logSwallowed('video_tuning_identify_prefs', e);
    }
  }

  /// One change: rebuild (so a number box shows the clamped value when it
  /// loses focus) and save right away.
  void _edit(VoidCallback change) {
    setState(change);
    _p.save();
  }

  /// The confidence threshold, with "New-track confidence" raised to stay
  /// above it (as on the camera).
  void _setConfidence(double v) {
    final (p, cp) = raiseNewTrackFloor(_p.trackerParams, _p.cbiouParams, v);
    _p
      ..confidence = v
      ..trackerParams = p
      ..cbiouParams = cp;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const FitTitle('Detection, track IDs, identification'), actions: const [HomeButton()]),
      // SafeArea: without it the list's last lines sit under the system
      // navigation bar and can never be scrolled into view.
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            const Text(
              'Saved as you change them. Back on the previous screen, its main button does what a change '
              'needs next: analyze the videos again, or only find the track IDs again.',
              style: helperTextStyle,
            ),
            const SizedBox(height: 16),
            _detectionCard(),
            const SizedBox(height: 20),
            _trackCard(),
            const SizedBox(height: 20),
            _identifyCard(),
          ],
        ),
      ),
    );
  }

  Widget _slider({
    required String label,
    required String help,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HelpLabel(label: label, labelStyle: const TextStyle(color: Colors.white), helperText: help),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: (v) => setState(() => onChanged(v)),
          // Saved when the finger lifts, not at every step of a drag.
          onChangeEnd: (_) => _p.save(),
        ),
      ],
    );
  }

  Widget _detectionCard() => ModelKindPanel(
    title: 'Detection',
    subtitle:
        'What the detector looks at, and how sure it must be. A change of the confidence, the frames per second '
        'or the IoU means analyzing the videos again.',
    children: [
      _slider(
        label: 'Confidence threshold: ${_p.confidence.toStringAsFixed(2)}',
        help: 'Minimum score for a detection to count. 0.25 is the live camera\'s default.',
        value: _p.confidence,
        min: 0.05,
        max: 0.95,
        divisions: 18,
        onChanged: (v) => _setConfidence(double.parse(v.toStringAsFixed(2))),
      ),
      _slider(
        label: 'Frames analyzed per second: ${_p.analysisFps.round()}',
        help:
            'How many pictures of each second of the video the detector looks at; the pictures in '
            'between are skipped. 5 = one picture every 0.2 s of video: enough for insects that '
            'stay on a flower for a second or more, and a run takes less than half the time 15 '
            'would (not a third: the phone still has to unpack every picture). More pictures '
            'follow fast flying insects better (fewer missed or counted twice) but take longer; '
            '15 is what the live camera analyzes. This counts seconds of the video, not of the '
            'run: a slow or warm phone takes longer, it never looks at fewer pictures. Most '
            'phone videos have 30 pictures per second; asking for more than the video has '
            'changes nothing.',
        value: _p.analysisFps,
        min: 1,
        max: 30,
        divisions: 29,
        onChanged: (v) => _p.analysisFps = v.roundToDouble(),
      ),
      if (widget.totalMs > 0)
        Text(
          'About ${(widget.totalMs / 1000 * min(_p.analysisFps, 30)).round()} frames for this session.',
          style: helperTextStyle,
        ),
      const SizedBox(height: 12),
      _slider(
        label: 'IoU threshold: ${_p.iou.toStringAsFixed(2)}',
        help: 'Overlap level at which two boxes merge into one. 0.7 is the live camera\'s default.',
        value: _p.iou,
        min: 0.05,
        max: 0.95,
        divisions: 18,
        onChanged: (v) => _p.iou = double.parse(v.toStringAsFixed(2)),
      ),
      NumericSettingField(
        label: 'Pause above battery temperature',
        value: _p.thermalLimitC,
        min: 35,
        max: 45,
        decimals: 0,
        unitSuffix: '°C',
        onChanged: (v) => _edit(() => _p.thermalLimitC = v),
        helperText:
            'The run pauses when the battery reaches this and resumes 3 °C lower. A hot battery '
            'ages faster, and a hot phone slows itself down anyway.',
      ),
      NumericSettingField(
        label: 'Measure the phone every',
        value: _p.sampleSeconds,
        min: 5,
        max: 60,
        decimals: 0,
        unitSuffix: 's',
        onChanged: (v) => _edit(() => _p.sampleSeconds = v),
        helperText:
            'How often the battery temperature, power use and analysis speed are written down '
            'during a run, also while it pauses to cool down. They make the session\'s Graphs '
            'and the file phone_during_analysis.csv. 10 s, as on the live camera, shows how '
            'the phone warms up; shorter shows quick changes but gives a longer file.',
      ),
    ],
  );

  static String _fmtFps(double fps) => fps == fps.roundToDouble() ? '${fps.round()}' : fps.toStringAsFixed(1);

  Widget _trackCard() {
    final t = TrackerTuning(
      algorithm: _p.trackerAlgorithm,
      byteTrack: _p.trackerParams,
      cbiou: _p.cbiouParams,
      confidence: _p.confidence,
      onAlgorithm: (a) => _edit(() => _p.trackerAlgorithm = a),
      onByteTrack: (v) => _edit(() => _p.trackerParams = v),
      onCbiou: (v) => _edit(() => _p.cbiouParams = v),
    );
    // Seconds become frames at the rate the frames were (or will be)
    // analyzed at (round 256).
    final fps = widget.analysedFps ?? _p.analysisFps;
    final detections = SessionConfig(minHitsSeconds: _p.minVisitSeconds).minHitsFramesFor(fps);
    return ModelKindPanel(
      color: kTrackingColor,
      icon: kTrackingIcon,
      title: 'Track IDs',
      subtitle:
          'How the boxes are linked from frame to frame. A change needs only the track IDs found again '
          '(this takes a few seconds), not a new analysis.',
      children: [
        ...t.algorithmPicker(),
        t.newTrackField(
          extraHelp:
              ' If "All boxes" on the session\'s Video tab shows an insect that never gets a track ID, it '
              'was probably never this sure: lower this and find the track IDs again (the videos do not '
              'need to be analyzed again). The live camera has its own value.',
        ),
        NumericSettingField(
          label: 'Occlusion tolerance',
          value: _p.occlusionSeconds,
          min: 0.2,
          max: 10,
          decimals: 1,
          unitSuffix: 's',
          helperText:
              'How long an insect can vanish (e.g. behind a petal) and keep its number. Longer: fewer '
              'track IDs split in two; too long: two insects can merge into one. Keep it well above the '
              'time between two analyzed frames. Default 3 s, as on the live camera.',
          onChanged: (x) => _edit(() => _p.occlusionSeconds = x),
        ),
        NumericSettingField(
          label: 'Minimum track length',
          value: _p.minVisitSeconds,
          min: 0,
          max: 2,
          decimals: 1,
          unitSuffix: 's',
          helperText:
              'How long an insect must be seen before it counts as a track ID; shorter sightings are '
              'dropped as noise. The detector must find it in this many analyzed frames in a row (shown '
              'below), so an insect it sees only on and off is dropped too when the value is high. '
              'Default 1 s: at 5 frames per second that is 5 detections, while the live camera\'s '
              '0.2 s would be a single one, so any one-frame false box would become a track ID. Try '
              'other values and find the track IDs again.',
          onChanged: (x) => _edit(() => _p.minVisitSeconds = x),
        ),
        Text(
          '= $detections ${detections == 1 ? 'detection' : 'detections'} in a row at ${_fmtFps(fps)} frames per '
          'second.',
          style: helperTextStyle,
        ),
        const SizedBox(height: 4),
        if (widget.liveAi)
          const Text(
            'No frames are kept for these track IDs: live detection\'s own photos stay the session\'s pictures.',
            style: helperTextStyle,
          )
        else ...[
          HelpSwitchTile(
            title: 'Keep frames of each track ID',
            helperText:
                'Saves pictures of every track ID from the videos, like the photos the live camera takes, so '
                'you can look at the insects and identify them. Uses some storage: one picture is about '
                'as big as a live photo. On by default.',
            statusText: !_p.keepFrames && widget.keptSaved > 0
                ? 'Finding track IDs again with this off removes the ${widget.keptSaved} frames saved before; '
                      'they can be saved again from the videos later.'
                : null,
            statusColor: Colors.amber,
            value: _p.keepFrames,
            onChanged: (x) => _edit(() => _p.keepFrames = x),
          ),
          if (_p.keepFrames) ...[
            NumericSettingField(
              label: 'Keep a frame every',
              value: _p.keepStepSeconds,
              min: 0.1,
              max: 10,
              decimals: 1,
              unitSuffix: 's',
              helperText:
                  'The first frame of a track ID is always kept, then one after each such step. Default 1 s, '
                  'as the live camera\'s photo step. Shorter catches more poses but fills more storage.',
              onChanged: (x) => _edit(() => _p.keepStepSeconds = x),
            ),
            NumericSettingField(
              label: 'For up to',
              value: _p.keepDurationSeconds,
              min: 1,
              max: 300,
              decimals: 0,
              unitSuffix: 's',
              helperText:
                  'How long into a track ID frames keep being saved; a long track ID gives no more after this. '
                  'Default 10 s, as the live camera\'s photo duration.',
              onChanged: (x) => _edit(() => _p.keepDurationSeconds = x),
            ),
            Text(
              'Up to about ${1 + (_p.keepDurationSeconds / _p.keepStepSeconds).floor()} frames per track ID.',
              style: helperTextStyle,
            ),
          ],
        ],
        FoldSection(
          title: 'Fine-tuning (${t.algorithmName})',
          subtitle: t.fineTuningSummary,
          helperText: 'The defaults suit insects on a flower; most sessions never need these.',
          children: [
            ...t.fineTuning(),
            TrackerTuning.resetButton(
              helperText:
                  'Puts "New-track confidence", the occlusion tolerance, the minimum track length and the '
                  'fine-tuning of both algorithms back to their defaults. The algorithm choice and the kept '
                  'frames stay as they are.',
              onPressed: () => _edit(() {
                final (p, cp) = raiseNewTrackFloor(const ByteTrackParams(), const CBiouParams(), _p.confidence);
                _p
                  ..occlusionSeconds = 3.0
                  ..minVisitSeconds = 1.0
                  ..trackerParams = p
                  ..cbiouParams = cp;
              }),
            ),
          ],
        ),
      ],
    );
  }

  /// Why the automatic identification will not run, or null when it will.
  String? get _identifyBlocked => widget.liveAi
      ? 'Not used for this session: it was recorded with live detection, so its track IDs are named from the '
            'session\'s ⋮ menu (Identify organisms), which has these settings too.'
      : !_p.keepFrames
      ? 'Needs "Keep frames of each track ID" (Track IDs card above): identification names the saved frames.'
      : !widget.alsoIdentify
      ? 'Used only when "Also identify them" is on (on the previous screen).'
      : null;

  Widget _identifyCard() {
    final prefs = _identify;
    final model = widget.identifyModel;
    final blocked = _identifyBlocked;
    return ModelKindPanel(
      identification: true,
      title: 'Identification',
      subtitle: 'How the animals in the kept frames are named (the settings of Identify organisms).',
      children: [
        NotApplicable(
          applies: blocked == null,
          note: blocked ?? '',
          noteFirst: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                model == null
                    ? 'No model with a name list chosen yet (under "Also identify them" on the previous screen).'
                    : 'Model $model with the name list ${widget.identifyList} (chosen under "Also identify them" '
                          'on the previous screen).',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              if (prefs == null)
                const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
              else
                // Saved without the model and name list read here, which stay
                // as stored (the video screen saves its choice when it opens
                // Identify organisms).
                IdentifySettingsFields(
                  prefs: prefs,
                  onEdit: (change) {
                    setState(change);
                    prefs.save();
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}
