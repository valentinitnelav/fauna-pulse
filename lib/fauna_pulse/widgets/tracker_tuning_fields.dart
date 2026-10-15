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

/// "New-track confidence" is always kept at least this far above the
/// detector's confidence threshold, so there is always a band of "faint"
/// detections (between the two) that can keep an existing insect's track ID
/// alive without being strong enough to start a new one. Raising the
/// confidence pushes "New-track confidence" up to keep it.
const double kNewTrackBuffer = 0.10;

/// The lowest "New-track confidence" allowed with the detector's
/// [confidence] ([kNewTrackBuffer] above it, between 0.30 and 0.95).
double newTrackFloor(double confidence) => (confidence + kNewTrackBuffer).clamp(0.30, 0.95);

/// Both trackers' values with "New-track confidence" raised to the floor of
/// [confidence] where it is lower (each tracker has its own).
(ByteTrackParams, CBiouParams) raiseNewTrackFloor(ByteTrackParams p, CBiouParams cp, double confidence) {
  final floor = newTrackFloor(confidence);
  return (
    p.highThresh < floor ? p.copyWith(highThresh: floor) : p,
    cp.highThresh < floor ? cp.copyWith(highThresh: floor) : cp,
  );
}

/// Builds the tracker controls from the values a host holds. Only the
/// selected algorithm's own knobs are shown, so citizen-science users are
/// never faced with both sets at once.
class TrackerTuning {
  final TrackerAlgorithm algorithm;
  final ByteTrackParams byteTrack;
  final CBiouParams cbiou;

  /// The detector confidence threshold the new-track floor follows.
  final double confidence;
  final ValueChanged<TrackerAlgorithm> onAlgorithm;
  final ValueChanged<ByteTrackParams> onByteTrack;
  final ValueChanged<CBiouParams> onCbiou;

  const TrackerTuning({
    required this.algorithm,
    required this.byteTrack,
    required this.cbiou,
    required this.confidence,
    required this.onAlgorithm,
    required this.onByteTrack,
    required this.onCbiou,
  });

  bool get isCbiou => algorithm == TrackerAlgorithm.cbiou;
  String get algorithmName => isCbiou ? 'C-BIoU' : 'ByteTrack';

  /// The value "Find track IDs" or the camera uses: never below the floor.
  double get newTrackConfidence {
    final v = isCbiou ? cbiou.highThresh : byteTrack.highThresh;
    final floor = newTrackFloor(confidence);
    return v < floor ? floor : v;
  }

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
          'enlarges the boxes before comparing them. Both count track IDs '
          'the same way, so results stay comparable across sessions.',
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
  Widget newTrackField({String extraHelp = ''}) {
    final floor = newTrackFloor(confidence);
    // The floor follows the confidence threshold so a "faint detection" band
    // always exists; the value never displays below that floor.
    if (isCbiou) {
      return NumericSettingField(
        label: 'New-track confidence',
        value: newTrackConfidence,
        min: floor,
        max: 0.95,
        decimals: 2,
        helperText:
            'A detection at or above this score may START a new track ID; a '
            'fainter one (still above the Confidence threshold) may only keep '
            'an existing insect\'s ID alive, e.g. while it is half-hidden '
            'under a petal. Automatically kept above Confidence so that faint '
            'band never closes. Default 0.50.$extraHelp',
        onChanged: (v) => onCbiou(cbiou.copyWith(highThresh: v)),
      );
    }
    return NumericSettingField(
      label: 'New-track confidence',
      value: newTrackConfidence,
      min: floor,
      max: 0.95,
      decimals: 2,
      helperText:
          'The score that separates a "strong" detection from a "faint" '
          'one. A box at or above this is a clear sighting and may START a '
          'new track ID. A box below it, but still above the Confidence '
          'threshold, is a faint sighting that may ONLY keep an '
          'already-existing insect\'s ID alive, never start a new one. That '
          'faint band (between Confidence and this) is exactly what '
          'holds onto a bee whose score dips while it is half-hidden under a '
          'petal, so it is not counted twice. Higher = more cautious about '
          'starting new IDs (fewer false track IDs); lower = quicker to '
          'start a new track ID. It is automatically kept at least '
          '${kNewTrackBuffer.toStringAsFixed(2)} above Confidence (and '
          'rises with it) so the faint band never closes. Default 0.50.$extraHelp',
      onChanged: (v) => onByteTrack(byteTrack.copyWith(highThresh: v)),
    );
  }

  /// The selected algorithm's fine-tuning. [newTrack] puts "New-track
  /// confidence" among them, where the camera Settings have it.
  List<Widget> fineTuning({Widget? newTrack}) => isCbiou
      ? [
          // C-BIoU's own knobs (round 105). The buffer scales are THE tuning
          // lever of this algorithm: how far a box is enlarged before the
          // overlap test.
          NumericSettingField(
            label: 'Search margin, pass 1',
            value: cbiou.bufferScale1,
            min: 0.05,
            max: 1.0,
            decimals: 2,
            helperText:
                'Before comparing, every box is enlarged by this fraction of its '
                'own size on each side (0.3 = a 10-px box is matched as 16 px). '
                'Bigger tolerates faster movement between frames but risks mixing '
                'up two insects sitting close together. Raising it above pass 2 '
                'raises pass 2 with it. (0.05–1.0; default 0.30.)',
            onChanged: (v) => onCbiou(
              cbiou.copyWith(bufferScale1: v, bufferScale2: v > cbiou.bufferScale2 ? v : cbiou.bufferScale2),
            ),
          ),
          NumericSettingField(
            label: 'Search margin, pass 2',
            value: cbiou.bufferScale2,
            min: 0.05,
            max: 2.0,
            decimals: 2,
            helperText:
                'A second, wider matching pass for whatever pass 1 could not '
                'pair: this is what catches the big between-frame jumps. Always '
                'at least as large as pass 1. (up to 2.0; default 0.50.)',
            onChanged: (v) => onCbiou(cbiou.copyWith(bufferScale2: v < cbiou.bufferScale1 ? cbiou.bufferScale1 : v)),
          ),
          ?newTrack,
        ]
      : [
          // ByteTrack's own knobs (the pre-round-105 fields).
          NumericSettingField(
            label: 'Match overlap (IoU)',
            value: byteTrack.matchThresh,
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
                'screen (the track IDs would mix up), and 1.0 would demand pixel-identical '
                'boxes so every frame would start a new track ID.',
            onChanged: (v) => onByteTrack(byteTrack.copyWith(matchThresh: v)),
          ),
          NumericSettingField(
            label: 'Low-score association',
            value: byteTrack.lowMatchThresh,
            min: 0.02,
            max: 0.8,
            decimals: 2,
            helperText:
                'A second, looser overlap test used to re-link faint detections '
                '(a half-hidden or blurred insect that briefly drops in '
                'confidence) so it keeps its track ID. Normally set at or below '
                'Match overlap. The 0.02 floor stops a real track grabbing a '
                'random noise box; set it too high and faint insects are no '
                'longer recovered (0.02–0.80).',
            onChanged: (v) => onByteTrack(byteTrack.copyWith(lowMatchThresh: v)),
          ),
          ?newTrack,
          NumericSettingField(
            label: 'Velocity smoothing',
            value: byteTrack.velocitySmoothing,
            min: 0.0,
            max: 1.0,
            decimals: 2,
            helperText:
                'While an insect is briefly hidden, the tracker guesses where it '
                'went by continuing its recent motion. This sets how much it '
                'trusts the very latest movement. Low (≈0.2) = "assume it barely '
                'moved": steadier, best for insects that land and sit still '
                '(the usual case here). High (≈0.8) = follow the latest motion '
                'closely: better for fast, darting insects but jumpier. '
                '(0–1; default 0.5.)',
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
