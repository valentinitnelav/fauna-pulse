// FaunaPulse (round 308): the identification settings, shared by "Identify
// organisms" (its Advanced settings) and the Identification card of "Find
// animals in videos" (screens/video_tuning_screen.dart), so the texts live in
// one place. Moved out of identification_screen.dart; the texts that named
// that screen's "Test speed" now say where it is, and the merge gap's names
// the tracker's occlusion tolerance (videos have their own).

import 'package:flutter/material.dart';

import '../identification/identification_assets.dart';
import '../identification/label_pack.dart';
import '../widgets/numeric_setting_field.dart';
import '../widgets/setting_help.dart';

/// Every [IdentifyPrefs] setting but the model and the name list. The host
/// stores what changed: [onEdit] gets the change, applies it in a setState
/// (so a number box shows the typed value when it loses focus, the round 210
/// bug) and saves.
class IdentifySettingsFields extends StatelessWidget {
  final IdentifyPrefs prefs;
  final void Function(VoidCallback change) onEdit;

  /// After a change of the crops that are counted (Identify organisms counts
  /// them again).
  final VoidCallback? onCropCountChanged;

  const IdentifySettingsFields({super.key, required this.prefs, required this.onEdit, this.onCropCountChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HelpSwitchTile(
          title: 'Use the GPU when it can run the model',
          value: prefs.useGpu,
          onChanged: (v) => onEdit(() => prefs.useGpu = v),
          helperText:
              'Runs the model on the phone\'s graphics processor (GPU), on tested phones about ten times '
              'faster than the main processor (CPU). The first time, the app checks on a test picture that '
              'the GPU gives the same answers as the CPU; if not, or if the GPU cannot run the model or lacks '
              'memory, the CPU is used and the app says why. "Test speed" on the Identify organisms screen '
              'shows what this phone does. Off = CPU only.',
        ),
        NumericSettingField(
          label: 'CPU threads (0 = automatic)',
          value: prefs.cpuThreads.toDouble(),
          min: 0,
          max: 8,
          isInt: true,
          onChanged: (v) => onEdit(() => prefs.cpuThreads = v.round()),
          helperText:
              'How many processor cores the model may use on the CPU. 0 = automatic, which uses 2: '
              'on the phones it was tested on, that was almost twice as fast as 1. 4 was about a quarter faster '
              'again but keeps twice as many cores busy, so the phone warms up sooner (which '
              'triggers the pause). "Test speed" on the Identify organisms screen shows the real effect of a '
              'value on this phone.',
        ),
        HelpSwitchTile(
          title: 'Square crops',
          value: prefs.squareCrops,
          onChanged: (v) => onEdit(() => prefs.squareCrops = v),
          helperText:
              'The model always looks at a square picture. On: the box is widened to a square, so the '
              'insect keeps its shape and some flower shows around it. Off: only the box (plus the margin) '
              'is cut out and stretched to a square, so a long, thin insect looks squeezed. On by default '
              'because it keeps the insect\'s shape; which works better on pollinator photos is not yet '
              'tested. After a change, the next run asks whether to cut the stored crops again.',
        ),
        NumericSettingField(
          label: 'Crop margin',
          value: prefs.margin,
          min: 0,
          max: 0.5,
          decimals: 2,
          onChanged: (v) => onEdit(() => prefs.margin = v),
          helperText:
              'Extra border added on every side of the detector box, as a share of the box\'s '
              'longer side (0.05 = 5 % of it), because legs, antennae and wings stick out by an '
              'amount that depends on the insect\'s size. Default 0: the model sees the box itself, '
              'with as little flower or background as possible (with "Square crops" on, the square '
              'already adds some along the shorter side). Raise it if legs, antennae or wings look '
              'cut off (the cyan box on a track ID\'s photo in the results shows what was cut out). '
              'After a change, the next run asks whether to recompute the crops already stored for '
              'this session.',
        ),
        NumericSettingField(
          label: 'Smallest box to identify',
          value: prefs.minCropPx.toDouble(),
          min: 16,
          max: 512,
          isInt: true,
          unitSuffix: 'px',
          onChanged: (v) {
            onEdit(() => prefs.minCropPx = v.round());
            onCropCountChanged?.call();
          },
          helperText:
              'Boxes smaller than this (longer side, in photo pixels) are skipped. Default 48: the '
              'model looks at every crop at 224 px, so a smaller box is enlarged more than 4 times '
              'and is mostly blur. On the default 1024 px photos, 48 px is an insect about 5 % of '
              'the photo side; 96 px would skip every insect under a tenth of it. Each track ID '
              'uses its largest boxes first (see "Crops per track ID"), so this mainly decides '
              'whether insects that stay small in every photo get an answer at all.',
        ),
        NumericSettingField(
          label: 'Crops per track ID (0 = all)',
          value: prefs.maxCropsPerTrack.toDouble(),
          min: 0,
          max: 100,
          isInt: true,
          onChanged: (v) {
            onEdit(() => prefs.maxCropsPerTrack = v.round());
            onCropCountChanged?.call();
          },
          helperText:
              'Upper limit per track ID: when a track ID has more photos than this, only its LARGEST '
              'boxes are kept. How many photos a track ID has '
              'comes from the session\'s photo schedule (e.g.: the live detection default, one photo every 1 s for '
              '10 s, so about 10 per track ID); with that default the limit of 10 rarely removes '
              'anything and only bounds the runtime for long bursts. Set 0 to use all photos.',
        ),
        NumericSettingField(
          label: 'Ignore crops far less sure than the best (factor)',
          value: prefs.dropFactor,
          min: 1,
          max: 100,
          decimals: 0,
          onChanged: (v) => onEdit(() => prefs.dropFactor = v),
          helperText:
              'A crop whose Species conf. is below the surest crop\'s divided by this factor is left out '
              'of the combined answer (it still appears in the crops table, marked "left out"). '
              '1 = every crop counts. The default of 10 is a FaunaPulse estimate, not yet tested '
              'on representative data.',
        ),
        NumericSettingField(
          label: 'Confidence needed to call a rank identified',
          value: prefs.tau,
          min: 0.5,
          max: 0.99,
          decimals: 2,
          onChanged: (v) => onEdit(() => prefs.tau = v),
          helperText:
              'The model gives every species in the name list a share of 100 %; a genus or family gets the '
              'sum of its species, and so on up to kingdom. The deepest rank that reaches this value is the '
              'reported answer; deeper ranks are listed as suggestions to check. 0.60 = 60 %, the default: '
              'above one half, so the reported taxon is always the most likely one at its rank. Higher gives '
              'fewer but safer species names.',
        ),
        NumericSettingField(
          label: '"No organism" threshold',
          value: prefs.noneThreshold,
          min: 0.1,
          max: 0.9,
          decimals: 2,
          onChanged: (v) => onEdit(() => prefs.noneThreshold = v),
          helperText:
              'The name list also has a few "none of these" entries (flower, leaf, shadow, empty '
              'background). When together they get more than this share (0.50 = 50 %), the track ID is '
              'reported as "no organism": the detector most likely boxed something that is not an animal. '
              'Default 0.50: "no organism" only when it is more likely than all animals together.',
        ),
        NumericSettingField(
          label: 'Pause above battery temperature',
          value: prefs.thermalLimitC,
          min: 35,
          max: 45,
          decimals: 0,
          unitSuffix: '°C',
          onChanged: (v) => onEdit(() => prefs.thermalLimitC = v),
          helperText: 'The run pauses when the battery reaches this and resumes 3 °C lower.',
        ),
        HelpSwitchTile(
          title: 'Merge consecutive track IDs',
          value: prefs.mergeVisits,
          onChanged: (v) => onEdit(() => prefs.mergeVisits = v),
          helperText:
              'Helps when the tracker lost an insect for a moment and gave it a new track ID. On: a track '
              'ID that starts within the gap below after another one ended is joined to it when both have a '
              'fitting identification (for example Apidae, then Bombus), look alike to the model and have a '
              'similar box size; the joined track ID is identified again from all its photos. Track IDs at '
              'the same time are never joined. Off by default because it changes the number of track IDs; '
              'the CSV lists which were joined.',
        ),
        if (prefs.mergeVisits) ...[
          NumericSettingField(
            label: 'Largest gap between joined track IDs',
            value: prefs.mergeGapS,
            min: 0.5,
            max: 120,
            decimals: 1,
            unitSuffix: 's',
            onChanged: (v) => onEdit(() => prefs.mergeGapS = v),
            helperText:
                'Time from the end of one track ID to the start of the next. Compare it with the tracker\'s '
                '"Occlusion tolerance" (3 s by default): over shorter gaps the tracker itself usually '
                'keeps the same track ID. Longer gaps '
                'risk joining two different insects of the same species: the appearance check cannot '
                'tell individuals apart, only the time gap can.',
          ),
          NumericSettingField(
            label: 'Appearance similarity needed',
            value: prefs.mergeMinCos,
            min: 0.5,
            max: 0.99,
            decimals: 2,
            onChanged: (v) => onEdit(() => prefs.mergeMinCos = v),
            helperText:
                'How alike the two track IDs look to the model, from 0 to 1 (it compares the model\'s '
                'averaged descriptions of their photos): 1 = the model sees the same thing. Same species '
                'usually scores 0.8 to 0.95, different families well below. 0.85 is a cautious default; '
                'lower it if fragments of one insect stay apart.',
          ),
          NumericSettingField(
            label: 'Box size may differ by up to',
            value: prefs.mergeSizeTol * 100,
            min: 0,
            max: 100,
            decimals: 0,
            unitSuffix: '%',
            onChanged: (v) => onEdit(() => prefs.mergeSizeTol = v / 100),
            helperText:
                'Compares the average box size of the two track IDs. They are joined only if the smaller one '
                'is at most this much smaller than the larger one (50 % = it may be half the size). Default '
                '50 %: a loose check on purpose, because wings, distance to the camera and boxes cut at the '
                'edge of the square change the size. 100 % switches the check off.',
          ),
        ],
        const SizedBox(height: 8),
        const HelpLabel(
          label: 'Suspect track IDs (flags only, nothing is deleted)',
          labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          helperText:
              'Very short track IDs are often false detections (a moving petal, a shadow, a video '
              'artefact). A track ID is marked "suspect" when it is short (under "Short: duration below" or '
              '"Short: detections below") and also weak (under "Weak: detector confidence below", under '
              '"Weak: order confidence below", or "no organism"). Suspect track IDs are hidden in the '
              'results table unless you switch them on, and they stay in the CSV with a "suspect" column. '
              'Nothing is deleted.',
        ),
        NumericSettingField(
          label: 'Short: duration below',
          value: prefs.flagMinDurationS,
          min: 0,
          max: 60,
          decimals: 1,
          unitSuffix: 's',
          onChanged: (v) => onEdit(() => prefs.flagMinDurationS = v),
          helperText: 'From the first to the last frame the tracker saw the track ID in. 0 = never short by duration.',
        ),
        NumericSettingField(
          label: 'Short: detections below',
          value: prefs.flagMinDetections.toDouble(),
          min: 0,
          max: 100,
          isInt: true,
          onChanged: (v) => onEdit(() => prefs.flagMinDetections = v.round()),
          helperText:
              'Detector frames the track ID appeared in, from the first sighting (also the frames before it was '
              'confirmed as a track ID). 0 = never short by count.',
        ),
        NumericSettingField(
          label: 'Weak: detector confidence below',
          value: prefs.flagMinDetConf,
          min: 0,
          max: 1,
          decimals: 2,
          onChanged: (v) => onEdit(() => prefs.flagMinDetConf = v),
          helperText:
              'If the detector\'s average confidence over the photos of a track ID is below this, the track '
              'ID counts as weak. Weak alone changes nothing; weak and short together make it suspect. '
              'Default 0.20, the same as the track filter of the insect-detect-post tool.',
        ),
        NumericSettingField(
          label: 'Weak: order confidence below',
          value: prefs.flagMinOrderP,
          min: 0,
          max: 1,
          decimals: 2,
          onChanged: (v) => onEdit(() => prefs.flagMinOrderP = v),
          helperText:
              'If the confidence for the order (for example Diptera: the Conf. of the order row in the '
              'results) is below this, the track ID counts as weak. Weak alone changes nothing; weak and '
              'short together make it suspect. Default 0.50: below it, even the order is less likely than not.',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: DropdownButtonFormField<String>(
            initialValue: prefs.targetRank,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'CSV file only: rank of the "pred" columns'),
            items: [for (final r in kRankNames.skip(3)) DropdownMenuItem(value: r, child: Text(r))],
            onChanged: (v) {
              if (v != null) onEdit(() => prefs.targetRank = v);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            // Round 247 (owner: unclear what this does, and "default is family" next to genus).
            'Only for the CSV file of the results (tracks_<name list>.csv); the screen always shows every '
            'rank. Its "pred" columns give the answer at this one rank, like the insect-detect-post tool of '
            'Maximilian Sittinger, so the files of both can be compared; all ranks are in the other columns '
            'anyway. Column details: github.com/valentinitnelav/fauna-pulse (docs/DATA_GUIDE.md). '
            '${prefs.targetRank == 'family' ? 'Family is the app\'s default.' : 'You chose ${prefs.targetRank}; the app\'s default is family.'}',
            style: helperTextStyle,
          ),
        ),
      ],
    );
  }
}
