// FaunaPulse (round 308): the tracker's own settings (the algorithm, its
// "New-track confidence" and its fine-tuning), shared by the camera Settings
// (Detection tab, Tracking → Advanced) and the Track IDs card of "Find animals
// in videos", whose values are kept apart from the camera's. Moved out of
// settings_sheet.dart so the texts live in one place; each host places the
// parts where it wants them and stores what [TrackerTuning]'s callbacks give.

import 'package:flutter/material.dart';

import '../tracking/byte_track.dart';
import '../tracking/c_biou_track.dart';
import '../tracking/tracker.dart';
import 'numeric_setting_field.dart';
import 'setting_help.dart';

/// Round 313 (owner): "New-track confidence" is the user's own value; nothing
/// raises it. It should sit above the lowest score of the boxes the tracker
/// gets (the detector's confidence threshold), so a band of "faint" boxes
/// between the two can keep an existing track ID alive without starting a new
/// one (ByteTrack's idea). Below this gap the box shows an amber note. The
/// reference trackers keep 0.15 to 0.6 between the two (Ultralytics 0.10 and
/// 0.25, the ByteTrack paper 0.1 and 0.6); none forces a gap.
const double kNewTrackGapWarning = 0.10;

/// The amber note under "New-track confidence" when it is not at least
/// [kNewTrackGapWarning] above [confidence] (the lowest score of the boxes the
/// tracker gets, named [confidenceName] in the note), or null.
String? newTrackGapWarning(double newTrack, double confidence, {String confidenceName = 'the Confidence threshold'}) {
  final gap = double.parse((newTrack - confidence).toStringAsFixed(2));
  final c = confidence.toStringAsFixed(2);
  if (gap <= 0) {
    return 'Not above $confidenceName ($c): every box can start a track ID and no box is faint, so a '
        'half-hidden insect is more easily counted twice.';
  }
  if (gap < kNewTrackGapWarning) {
    return 'Only ${gap.toStringAsFixed(2)} above $confidenceName ($c): few boxes are faint, so a half-hidden '
        'insect may get a second track ID. For counting, keep it at least '
        '${kNewTrackGapWarning.toStringAsFixed(2)} higher.';
  }
  return null;
}

/// Builds the tracker controls from the values a host holds. Only the
/// selected algorithm's own knobs are shown, so citizen-science users are
/// never faced with both sets at once.
class TrackerTuning {
  final TrackerAlgorithm algorithm;
  final ByteTrackParams byteTrack;
  final CBiouParams cbiou;

  /// The lowest score of the boxes the tracker gets (the detector's
  /// confidence threshold, or the one a session's videos were analyzed at),
  /// for the note under "New-track confidence"; [confidenceName] names it.
  final double confidence;
  final String confidenceName;
  final ValueChanged<TrackerAlgorithm> onAlgorithm;
  final ValueChanged<ByteTrackParams> onByteTrack;
  final ValueChanged<CBiouParams> onCbiou;

  const TrackerTuning({
    required this.algorithm,
    required this.byteTrack,
    required this.cbiou,
    required this.confidence,
    this.confidenceName = 'the Confidence threshold',
    required this.onAlgorithm,
    required this.onByteTrack,
    required this.onCbiou,
  });

  bool get isCbiou => algorithm == TrackerAlgorithm.cbiou;
  String get algorithmName => isCbiou ? 'C-BIoU' : 'ByteTrack';

  /// The selected algorithm's "New-track confidence", as stored and used.
  double get newTrackConfidence => isCbiou ? cbiou.highThresh : byteTrack.highThresh;

  /// The selected algorithm's fine-tuning in one line, for a closed fold.
  String get fineTuningSummary => isCbiou
      ? 'Search margins ${cbiou.bufferScale1.toStringAsFixed(2)} and ${cbiou.bufferScale2.toStringAsFixed(2)}'
      : 'Match overlap ${byteTrack.matchThresh.toStringAsFixed(2)}, low-score association '
            '${byteTrack.lowMatchThresh.toStringAsFixed(2)}, velocity smoothing '
            '${byteTrack.velocitySmoothing.toStringAsFixed(2)}';

  List<Widget> algorithmPicker() => [
    const HelpLabel(
      label: 'Tracking algorithm',
      helperText:
          'How detections are linked frame to frame. ByteTrack predicts '
          'where each insect went and matches by box overlap; C-BIoU '
          'enlarges the boxes before comparing them. The two can give a '
          'different number of track IDs for the same scene, so compare '
          'only sessions that used the same algorithm.',
    ),
    DropdownButton<TrackerAlgorithm>(
      value: algorithm,
      isExpanded: true,
      dropdownColor: Colors.black87,
      items: const [
        // Names only (owner, 2026-07-15): no "default"/"experimental"
        // qualifiers while the two are still being compared in the field.
        DropdownMenuItem(
          value: TrackerAlgorithm.bytetrack,
          child: Text('ByteTrack', style: TextStyle(color: Colors.white, fontSize: 13)),
        ),
        DropdownMenuItem(
          value: TrackerAlgorithm.cbiou,
          child: Text('C-BIoU', style: TextStyle(color: Colors.white, fontSize: 13)),
        ),
      ],
      onChanged: (a) {
        if (a != null) onAlgorithm(a);
      },
    ),
  ];

  /// The selected algorithm's "New-track confidence"; [extraHelp] ends its
  /// help with what the value is used for where it is shown.
  Widget newTrackField({String extraHelp = ''}) => NumericSettingField(
    key: ValueKey('newTrack.${algorithm.name}'),
    label: 'New-track confidence',
    value: newTrackConfidence,
    min: 0.05,
    max: 0.95,
    decimals: 2,
    warning: newTrackGapWarning(newTrackConfidence, confidence, confidenceName: confidenceName),
    helperText:
        'Only a box at least this sure can start a new track ID. Weaker '
        'boxes (between the Confidence threshold and this) can only continue '
        'an existing track ID, which keeps a bee half hidden under a petal '
        'from being counted twice. Higher: fewer false track IDs, but small '
        'or half-hidden insects may be missed. Default 0.50, at least '
        '${kNewTrackGapWarning.toStringAsFixed(2)} above the Confidence '
        'threshold so that this in-between band exists.$extraHelp',
    onChanged: (v) => isCbiou ? onCbiou(cbiou.copyWith(highThresh: v)) : onByteTrack(byteTrack.copyWith(highThresh: v)),
  );

  /// The selected algorithm's fine-tuning. [newTrack] puts "New-track
  /// confidence" among them, where the camera Settings have it.
  List<Widget> fineTuning({Widget? newTrack}) => isCbiou
      ? [
          // C-BIoU's own knobs (round 105). The buffer scales are THE tuning
          // lever of this algorithm: how far a box is enlarged before the
          // overlap test.
          NumericSettingField(
            key: const ValueKey('cbiou.bufferScale1'),
            label: 'Search margin, pass 1',
            value: cbiou.bufferScale1,
            min: 0.05,
            max: 1.0,
            decimals: 2,
            helperText:
                'Before comparing, every box is enlarged by this fraction of its '
                'own size on each side (0.3 = a 10-px box is matched as 16 px). '
                'Bigger tolerates faster movement between frames but risks mixing '
                'up two insects sitting close together. Pass 2 is never narrower '
                'than this. (0.05–1.0; default 0.30.)',
            onChanged: (v) => onCbiou(cbiou.copyWith(bufferScale1: v)),
          ),
          NumericSettingField(
            key: const ValueKey('cbiou.bufferScale2'),
            label: 'Search margin, pass 2',
            value: cbiou.bufferScale2,
            min: 0.05,
            max: 2.0,
            decimals: 2,
            // The tracker uses the larger of the two (c_biou_track.dart); the
            // stored values stay as typed (round 313: no ratchet).
            warning: cbiou.bufferScale2 < cbiou.bufferScale1
                ? 'Used as ${cbiou.bufferScale1.toStringAsFixed(2)}, the same as pass 1 (pass 2 is never narrower).'
                : null,
            helperText:
                'A second, wider search for boxes that pass 1 could not pair; '
                'it catches insects that jumped far between pictures. If you '
                'enter a value below pass 1, the pass 1 value is used. Default '
                '0.50 (up to 2.0).',
            onChanged: (v) => onCbiou(cbiou.copyWith(bufferScale2: v)),
          ),
          ?newTrack,
        ]
      : [
          // ByteTrack's own knobs (the pre-round-105 fields).
          NumericSettingField(
            key: const ValueKey('bytetrack.matchThresh'),
            label: 'Match overlap (IoU)',
            value: byteTrack.matchThresh,
            min: 0.05,
            max: 0.9,
            decimals: 2,
            helperText:
                'How much a new box must overlap the place where the tracker '
                'expects the insect, to count as the same insect. Lower allows '
                'faster movement between frames; higher is stricter. It matters '
                'most for an insect that just arrived; one that already has a '
                'track ID is also found again by distance. For small, fast '
                'insects keep it low (0.1 to 0.2). Default 0.10.',
            onChanged: (v) => onByteTrack(byteTrack.copyWith(matchThresh: v)),
          ),
          NumericSettingField(
            key: const ValueKey('bytetrack.lowMatchThresh'),
            label: 'Low-score association',
            value: byteTrack.lowMatchThresh,
            min: 0.02,
            max: 0.8,
            decimals: 2,
            helperText:
                'A second, looser overlap check for faint boxes (an insect that '
                'is half hidden or blurred for a moment), so it keeps its track '
                'ID. Usually at or below "Match overlap". Higher: faint boxes help '
                'less. Allowed 0.02 to 0.80 (below 0.02 a track ID could take '
                'over a random box); default 0.10.',
            onChanged: (v) => onByteTrack(byteTrack.copyWith(lowMatchThresh: v)),
          ),
          ?newTrack,
          NumericSettingField(
            key: const ValueKey('bytetrack.velocitySmoothing'),
            label: 'Velocity smoothing',
            value: byteTrack.velocitySmoothing,
            min: 0.0,
            max: 1.0,
            decimals: 2,
            helperText:
                'While an insect is briefly hidden, the tracker guesses where it '
                'went by continuing its recent motion. This sets how much it '
                'trusts the very latest movement. Low (about 0.2) = "assume it '
                'barely moved": steadier, for insects that land and sit still. '
                'High (about 0.8) = follow the latest motion closely: better for '
                'fast, darting insects but jumpier. The default 0.5 lies '
                'between the two (allowed 0–1).',
            onChanged: (v) => onByteTrack(byteTrack.copyWith(velocitySmoothing: v)),
          ),
        ];

  /// "Reset tracking to defaults", with what it resets on this host.
  static Widget resetButton({required String helperText, required VoidCallback onPressed}) => HelpRow(
    helperText: helperText,
    child: Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.restart_alt, size: 18),
        label: const Text('Reset tracking to defaults'),
      ),
    ),
  );
}
