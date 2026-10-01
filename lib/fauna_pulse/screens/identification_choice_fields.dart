// FaunaPulse (round 274): the identification model and name list fields,
// shared by "Identify organisms" and the "Also identify them" switch of the
// Find screens (state: identification/identification_choice.dart). Moved out
// of identification_screen.dart; texts unchanged.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../identification/identification_assets.dart';
import '../identification/identification_choice.dart';
import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart' show formatBytes;
import '../widgets/setting_help.dart';
import 'models_screen.dart';

/// 35264 → "35,264".
String thousands(num n) => '$n'.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

class IdentificationChoiceFields extends StatelessWidget {
  final IdentificationChoice choice;

  /// After the user chose a model ([modelChanged]) or a name list; the
  /// [choice] is already updated, the caller rebuilds.
  final void Function(bool modelChanged) onChanged;

  /// Opens Download & import models; null greys the link.
  final VoidCallback? onManage;

  /// The bold "Model and name list" heading with its help (Identify
  /// organisms); the Find screens' switch carries its own.
  final bool showHeading;

  const IdentificationChoiceFields({
    super.key,
    required this.choice,
    required this.onChanged,
    required this.onManage,
    this.showHeading = true,
  });

  @override
  Widget build(BuildContext context) {
    String label(File f) => '${f.path.split('/').last} (${formatBytes(f.lengthSync())})';
    const headingStyle = TextStyle(fontWeight: FontWeight.bold, color: Colors.white);
    // Round 268: no model ships with the app.
    if (choice.models.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeading) ...[const Text('Model and name list', style: headingStyle), const SizedBox(height: 8)],
          NoModelNotice(identification: true, onGet: onManage),
        ],
      );
    }
    final header = choice.packHeader;
    final lists = choice.modelPacks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeading) ...[
          const HelpLabel(
            label: 'Model and name list',
            labelStyle: headingStyle,
            helperText:
                'The model names a crop by choosing from a NAME LIST made for it; without one it cannot '
                'identify, so only the lists made for the chosen model are offered. A BioCLIP model works '
                'with many LABEL PACKS (lists of names with their taxonomy). A classifier such as insectDCT '
                'knows a fixed set of classes: its CLASS LIST has the same file name as the model and is '
                'chosen with it. Add files with Download & import models… below (also in the home '
                "screen's ⋮ menu).",
          ),
          const SizedBox(height: 8),
        ],
        // isExpanded (round 209): without it the field takes the width of its
        // longest item, and a long pack file name overflowed the screen. The
        // keys rebuild a field whose choice changed from elsewhere (a model
        // change picks its list).
        DropdownButtonFormField<String>(
          key: ValueKey('identify model ${choice.model?.path}'),
          initialValue: choice.model?.path,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Model (.tflite)'),
          items: [
            for (final f in choice.models)
              DropdownMenuItem(value: f.path, child: Text(label(f), overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (p) {
            choice.selectModel(choice.models.firstWhere((f) => f.path == p));
            onChanged(true);
          },
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: ValueKey('identify list ${choice.model?.path} ${choice.pack?.path}'),
          initialValue: choice.pack?.path,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Name list (.fpack)'),
          items: [
            for (final f in lists) DropdownMenuItem(value: f.path, child: Text(label(f), overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (p) {
            choice.selectPack(lists.firstWhere((f) => f.path == p));
            onChanged(false);
          },
        ),
        if (header != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              choice.isClassList
                  ? 'Class list of ${header['model_id']}: ${header['rows']} classes on '
                        '${(header['heads'] as List?)?.length ?? 1} levels, ${header['sink_rows']} '
                        '"none" class (e.g. vegetation)'
                  : 'Pack ${header['pack_id']} for ${header['model_id']}: '
                        // Names without the "none" rows, as on the Download & import models
                        // screen and in the catalogue (round 271).
                        '${thousands((header['rows'] as num? ?? 0) - (header['sink_rows'] as num? ?? 0))} '
                        'names, ${header['sink_rows']} "none" entries, '
                        'scale ${(header['logit_scale'] as num?)?.toStringAsFixed(1)}',
              style: helperTextStyle,
            ),
          ),
        if (lists.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              '⚠ No name list for this model, so it cannot identify. Get one with Download & import '
              'models… below.',
              style: TextStyle(color: Colors.amber, fontSize: 13),
            ),
          ),
        const SizedBox(height: 4),
        Align(alignment: Alignment.centerLeft, child: manageModelsButton(onPressed: onManage)),
      ],
    );
  }
}

/// Round 274: "Also identify them" on the Find screens. One Start finds the
/// animals and their track IDs, then names them: the Find screen opens
/// "Identify organisms", which starts by itself and ends on the results.
class AlsoIdentify {
  static const prefKey = 'find_also_identify';

  /// The model and name list remembered by Identify organisms ([injected]
  /// in tests), and whether the switch is on (the first time: on when some
  /// model has a name list). Never throws: without the files the switch just
  /// has nothing to offer.
  static Future<(IdentificationChoice, bool)> load([IdentificationChoice? injected]) async {
    var choice = injected ?? IdentificationChoice();
    if (injected == null) {
      try {
        final prefs = await IdentifyPrefs.load();
        choice = await IdentificationChoice.load(modelName: prefs.modelName, packName: prefs.packName);
      } catch (e) {
        logSwallowed('also_identify_load', e);
      }
    }
    final on = (await SharedPreferences.getInstance()).getBool(prefKey) ?? choice.anyUsable;
    return (choice, on);
  }

  static Future<void> save(bool on) async => (await SharedPreferences.getInstance()).setBool(prefKey, on);

  /// Reads the files again after Download & import models; tests (no files
  /// folder) keep their choice.
  static Future<void> reload(IdentificationChoice choice) async {
    try {
      await choice.reload();
    } catch (e) {
      logSwallowed('also_identify_reload', e);
    }
  }
}

/// The switch, why it cannot be used ([blockedReason], greyed), and the
/// model and name list under it while it is on.
class AlsoIdentifySection extends StatelessWidget {
  final bool value;

  /// Null greys the switch (a run is going on).
  final ValueChanged<bool>? onChanged;
  final String? blockedReason;
  final IdentificationChoice choice;
  final void Function(bool modelChanged) onChoiceChanged;
  final VoidCallback? onManage;

  const AlsoIdentifySection({
    super.key,
    required this.value,
    required this.onChanged,
    required this.choice,
    required this.onChoiceChanged,
    required this.onManage,
    this.blockedReason,
  });

  @override
  Widget build(BuildContext context) {
    final usable = blockedReason == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HelpSwitchTile(
          title: 'Also identify them',
          helperText:
              'After the animals and their track IDs are found, an identification model names them from '
              'its name list, and the results open (the same as "Identify organisms" in the session\'s ⋮ '
              'menu, which starts by itself). It runs on this phone and can take long with a big model: '
              'keep the phone charging.',
          statusText: blockedReason,
          statusColor: Colors.amber,
          value: usable && value,
          onChanged: usable ? onChanged : null,
        ),
        if (usable && value)
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 8),
            child: IdentificationChoiceFields(
              choice: choice,
              onChanged: onChoiceChanged,
              onManage: onManage,
              showHeading: false,
            ),
          ),
      ],
    );
  }
}
