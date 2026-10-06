// FaunaPulse (round 300): Sessions → ⋮ → "Import a FaunaLapse session…".
//
// Picks the zip(s) FaunaLapse's "Pack" made of one photo session, imports them in a background
// isolate (postprocess/faunalapse_import.dart) and says what happened. Returns the new session
// folder, or null.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../logging/app_error_hooks.dart';
import '../logging/past_sessions.dart';
import '../postprocess/faunalapse_import.dart';
import '../widgets/dialog_title.dart';

Future<String?> pickAndImportFaunaLapse(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      actionsOverflowDirection: VerticalDirection.up,
      title: DialogTitle(const Text('Import a FaunaLapse session'), onClose: () => Navigator.of(ctx).pop(false)),
      content: const Text(
        'FaunaLapse records time-lapse photos on any phone, without AI. Its "Pack" button '
        'stores each photo session as a zip file. Choose that zip (and its "_part" zips, if '
        'there are any); the photos then become a session here, ready for "Find animals in '
        'photos". The phone needs free space for about twice the zip size while importing.\n\n'
        'FaunaLapse video sessions need no zip: use "Import videos…".',
        style: TextStyle(fontSize: 13),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Choose zip files', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return null;
  List<String> paths;
  try {
    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    paths = [for (final f in picked?.files ?? const <PlatformFile>[]) ?f.path];
  } catch (e) {
    logSwallowed('faunalapse_pick', e);
    paths = const [];
  }
  if (paths.isEmpty || !context.mounted) return null;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('Importing the photos…')),
          ],
        ),
      ),
    ),
  );
  FaunaLapseImportResult? result;
  String? problem;
  try {
    final root = await sessionsRoot();
    root.createSync(recursive: true);
    result = await importFaunaLapseZipsInBackground(paths, root);
  } on FaunaLapseImportError catch (e) {
    problem = e.message;
  } catch (e) {
    logSwallowed('faunalapse_import', e);
    problem = 'The import failed: $e';
  } finally {
    try {
      await FilePicker.platform.clearTemporaryFiles();
    } catch (e) {
      logSwallowed('faunalapse_pick_clear', e);
    }
    if (context.mounted) Navigator.of(context).pop(); // the progress window
  }
  if (!context.mounted) return null;
  final done = result;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: DialogTitle(
        Text(done == null ? 'Not imported' : 'FaunaLapse session imported'),
        onClose: () => Navigator.of(ctx).pop(),
      ),
      content: Text(
        done == null
            ? problem ?? 'Nothing was imported.'
            : '${done.photos} photos are now the session ${done.folder}'
                  '${done.sitePhotos > 0 ? ', with ${done.sitePhotos} site photos' : ''}.'
                  '${done.missingPhotos > 0 ? ' ${done.missingPhotos} photos named in its record were not in the zip files.' : ''}',
        style: const TextStyle(fontSize: 13),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))],
    ),
  );
  if (done == null) return null;
  return '${(await sessionsRoot()).path}/${done.folder}';
}
