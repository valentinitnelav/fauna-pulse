// FaunaPulse (round 319, stress finding n53): a recording started with free storage
// already below "Keep free storage" was stopped by the storage guard a few seconds later,
// with no reason the user could see before. Start is blocked instead: this window when
// REC or Start is pressed, and the same facts as a red line on the "Before you record"
// sheet. Scheduled windows only log the skip (the user is away).

import 'package:flutter/material.dart';

import '../logging/device_storage.dart' show formatMegabytes;
import 'dialog_title.dart';

/// "136 MB free, but a recording needs ...": why a recording cannot start now. Both numbers
/// in MB, the unit of the setting (round 319: not "3.8 GB free ... 5000 MB").
String notEnoughStorageText(int freeBytes, int reserveMb) =>
    '${formatMegabytes(freeBytes)} free, but a recording needs at least $reserveMb MB free '
    '(Settings, Power tab, Keep free storage). Free some space first, for example by deleting old '
    'sessions or videos.';

Future<void> showNotEnoughStorageDialog(BuildContext context, {required int freeBytes, required int reserveMb}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      actionsOverflowDirection: VerticalDirection.up,
      title: DialogTitle(const Text('Not enough free storage'), onClose: () => Navigator.of(ctx).pop()),
      content: SingleChildScrollView(child: Text(notEnoughStorageText(freeBytes, reserveMb))),
      actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))],
    ),
  );
}
