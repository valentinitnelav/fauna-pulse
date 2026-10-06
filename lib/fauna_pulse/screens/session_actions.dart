// FaunaPulse (round 277): what can be done with past sessions, shared by the
// home screen ("Latest session") and the Sessions screen. Moved here from
// home_screen.dart unchanged in what they do: open a session, Find animals,
// Identify organisms, rename, copy photos to the Gallery, delete one session,
// and (new) delete several selected sessions at once. Every action rescans
// the sessions afterwards through [SessionActions.reloadSessions].

import 'dart:async';

import 'package:flutter/material.dart';

import '../capture/crop_export.dart';
import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';
import '../logging/past_sessions.dart';
import '../logging/session_rename.dart';
import '../widgets/session_tile.dart' show SessionAction;
import '../widgets/dialog_title.dart';
import 'analysis_screen.dart';
import 'faunalapse_import_flow.dart';
import 'identification_screen.dart';
import 'session_summary_screen.dart';
import 'video_analysis_screen.dart';
import 'video_import_screen.dart';

mixin SessionActions<T extends StatefulWidget> on State<T> {
  /// Rescans the sessions after an action may have changed them.
  Future<void> reloadSessions();

  Future<void> _pushThenReload(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    // A screen can add results (badges), rename or delete its session.
    await reloadSessions();
  }

  Future<void> openSession(PastSession s) => _pushThenReload(SessionSummaryScreen(logFile: s.logFile));

  /// "Find animals in photos", optionally with [sessionDirPath] chosen.
  Future<void> openAnalysis([String? sessionDirPath]) =>
      _pushThenReload(AnalysisScreen(initialSessionPath: sessionDirPath));

  /// "Find animals in videos" (round 227), optionally with a session chosen.
  Future<void> openVideoAnalysis([String? sessionDirPath]) =>
      _pushThenReload(VideoAnalysisScreen(initialSessionPath: sessionDirPath));

  Future<void> findAnimalsIn(PastSession s) => s.hasVideos ? openVideoAnalysis(s.dir.path) : openAnalysis(s.dir.path);

  Future<void> openIdentification(PastSession s) => _pushThenReload(IdentificationScreen(sessionDir: s.dir));

  /// Picks videos and imports them as a session; "Find animals in these
  /// videos" at the end of the import opens that screen.
  Future<void> importVideos() async {
    final imported = await pickAndImportVideos(context);
    await reloadSessions();
    if (imported != null && mounted) await openVideoAnalysis(imported);
  }

  /// Round 300: a FaunaLapse photo session (its zips) becomes a session here.
  Future<void> importFaunaLapse() async {
    final imported = await pickAndImportFaunaLapse(context);
    await reloadSessions();
    if (imported != null && mounted) await openAnalysis(imported);
  }

  /// The ⋮ menu of a session row.
  void onSessionAction(PastSession s, SessionAction action) {
    switch (action) {
      case SessionAction.rename:
        askRenameSession(s);
      case SessionAction.exportPhotos:
        exportSessionPhotos(s);
      case SessionAction.analyze:
        findAnimalsIn(s);
      case SessionAction.identify:
        openIdentification(s);
      case SessionAction.delete:
        confirmDeleteSession(s);
    }
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// Rename dialog for one session (round 182). The heavy lifting (folder
  /// rename, start-record update, `session_renamed` audit record) is
  /// `renameSession` (logging/session_rename.dart); this dialog only collects
  /// the name and shows any failure inline so the user can correct it
  /// without retyping.
  Future<void> askRenameSession(PastSession s) async {
    final controller = TextEditingController(text: s.name);
    String? error;
    var busy = false;
    final renamed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          actionsOverflowDirection: VerticalDirection.up,
          title: DialogTitle(const Text('Rename session'), onClose: busy ? null : () => Navigator.of(ctx).pop(false)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                enabled: !busy,
                decoration: InputDecoration(
                  labelText: 'Session name',
                  border: const OutlineInputBorder(),
                  errorText: error,
                  errorMaxLines: 3,
                  helperText:
                      'Letters, digits, spaces, - and _ '
                      '(anything else becomes _).',
                  helperMaxLines: 2,
                ),
                onChanged: (_) {
                  if (error != null) setSt(() => error = null);
                },
              ),
              const SizedBox(height: 10),
              const Text(
                'Renames the session folder and updates the name inside the '
                'session\'s data log too (the change itself is documented '
                'there as a "session_renamed" record). Photos keep their '
                'file names.',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setSt(() => busy = true);
                      try {
                        await renameSession(s.dir, controller.text);
                        if (ctx.mounted) Navigator.of(ctx).pop(true);
                      } on SessionRenameException catch (e) {
                        setSt(() {
                          busy = false;
                          error = e.message;
                        });
                      } catch (e) {
                        setSt(() {
                          busy = false;
                          error = 'Rename failed: $e';
                        });
                      }
                    },
              child: const Text('Rename'),
            ),
          ],
        ),
      ),
    );
    final newName = sanitizeSessionName(controller.text);
    controller.dispose();
    if (renamed == true && mounted) {
      _snack('Session renamed to "$newName".');
      await reloadSessions();
    }
  }

  /// Whole-session gallery copy (round 182): the same scan → confirm → copy
  /// flow as the summary's Photos-tab "Copy photos" button (shared
  /// `scanSessionPhotos` / `exportPhotosToGallery` helpers), with the
  /// progress shown as a modal dialog since the list has no inline slot.
  Future<void> exportSessionPhotos(PastSession s) async {
    final scan = await scanSessionPhotos(s.dir.path);
    if (!mounted) return;
    if (scan.files.isEmpty) {
      _snack('This session has no saved photos to export.');
      return;
    }
    final album = galleryAlbumName(s.name);
    final n = scan.referenceCount;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(Text('Copy ${scan.files.length} photos to Gallery?'), onClose: () => Navigator.of(ctx).pop(false)),
        content: Text(
          'Copies every saved photo of this session into the phone\'s '
          'Gallery app, as the album "Pictures/FaunaPulse/$album". '
          '${n > 0 ? 'Includes $n reference photo${n == 1 ? '' : 's'} '
                    '(fixed-interval shots, taken whether or not anything '
                    'was detected). ' : ''}'
          'The copies take about ${formatBytes(scan.bytes)} of extra '
          'storage; the originals stay in the session folder. Photos '
          'already copied are skipped, so re-running is safe.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Copy', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;

    // Modal progress: the export runs in chunks, so the bar moves while the
    // dialog blocks other taps. `progressOpen` guards the final pop against
    // the Android back button dismissing the dialog first.
    var done = 0;
    final total = scan.files.length;
    StateSetter? progressUpdate;
    var progressOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('Copying photos…'),
          content: StatefulBuilder(
            builder: (ctx, setSt) {
              progressUpdate = setSt;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: total == 0 ? null : done / total),
                  const SizedBox(height: 8),
                  Text('Photo $done of $total', style: const TextStyle(fontSize: 13)),
                ],
              );
            },
          ),
        ),
      ).then((_) => progressOpen = false),
    );
    final res = await exportPhotosToGallery(
      scan.files,
      album,
      onProgress: (d, _) {
        done = d;
        progressUpdate?.call(() {});
      },
    );
    if (!mounted) return;
    if (progressOpen) Navigator.of(context, rootNavigator: true).pop();
    _snack(
      !res.supported
          ? 'Copying to Gallery needs Android 10 or newer — this phone runs an '
                'older Android. The photos are still on the phone in the '
                'session folder (reachable over USB).'
          : 'Copied ${res.exported} photos to Gallery ▸ '
                'Pictures/FaunaPulse/$album.'
                '${res.skipped > 0 ? ' ${res.skipped} were already there.' : ''}'
                '${res.failed > 0 ? ' ${res.failed} failed — try again.' : ''}',
    );
    await reloadSessions();
  }

  /// Delete ONE session from its ⋮ menu (round 182; since round 187 the only
  /// per-session delete).
  Future<void> confirmDeleteSession(PastSession s) async {
    final size = s.sizeBytes > 0 ? ' (${formatBytes(s.sizeBytes)})' : '';
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(const Text('Delete this session?'), onClose: () => Navigator.of(ctx).pop(false)),
        content: Text(
          'This permanently deletes "${s.name}"$size from the phone: the '
          'data log, all metadata and every saved photo. '
          'This cannot be undone.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      await s.dir.delete(recursive: true);
    } catch (e) {
      logSwallowed('session_delete', e);
      if (mounted) _snack('Could not delete the session.');
      return;
    }
    await reloadSessions();
  }

  /// Asks, then deletes [chosen] (round 277: several selected sessions; was
  /// "Delete all sessions" only). Bulk-deleting field data is the most
  /// destructive action in the app: when [chosen] is every one of the
  /// [total] sessions, the word "delete" must be typed first
  /// ([DeleteAllSessionsDialog]). Returns true when deleting started.
  Future<bool> confirmDeleteSessions(List<PastSession> chosen, {required int total}) async {
    if (chosen.isEmpty) return false;
    final bytes = chosen.fold<int>(0, (sum, s) => sum + s.sizeBytes);
    final n = chosen.length;
    final sure = n == total
        ? await showDialog<bool>(
            context: context,
            builder: (_) => DeleteAllSessionsDialog(count: n, totalBytes: bytes),
          )
        : await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              actionsOverflowDirection: VerticalDirection.up,
              title: DialogTitle(Text(n == 1 ? 'Delete 1 session?' : 'Delete $n sessions?'), onClose: () => Navigator.of(ctx).pop(false)),
              content: Text(
                'This permanently deletes ${n == 1 ? '"${chosen.single.name}"' : 'the $n selected sessions'} '
                '(${formatBytes(bytes)}) from the phone: the data logs, all metadata and every '
                'saved photo. This cannot be undone.',
                style: const TextStyle(fontSize: 13),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Delete', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );
    if (sure != true || !mounted) return false;
    await _deleteSessions(chosen);
    return true;
  }

  /// Each session folder is deleted on its own (never the whole sessions/
  /// folder), so anything else put there, e.g. over USB, survives. Folders
  /// with thousands of photos take a while: a progress dialog blocks the
  /// screen meanwhile so nothing races the deletes.
  Future<void> _deleteSessions(List<PastSession> sessions) async {
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 16),
                Expanded(
                  child: Text('Deleting ${sessions.length} session${sessions.length == 1 ? '' : 's'}…'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    var failures = 0;
    for (final s in sessions) {
      try {
        await s.dir.delete(recursive: true);
      } catch (e) {
        failures++;
        logSwallowed('sessions_delete', e);
      }
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // the progress dialog
    if (failures > 0) _snack('Could not delete $failures session${failures == 1 ? '' : 's'}.');
    await reloadSessions();
  }
}

/// The type-to-confirm dialog for deleting every session. Pops `true` only
/// when the user has typed `delete` and pressed the red button.
///
/// This is a real StatefulWidget (not a StatefulBuilder inside the caller) so
/// the text field's controller is owned and disposed by the dialog's own
/// State. Round 103's first field test crashed (fixed round 104) with an
/// `InheritedElement '_dependents.isEmpty'` assertion because the caller
/// disposed the controller — and pushed the progress dialog — while this
/// dialog was still animating out with the keyboard focused; letting the
/// framework drive the teardown order fixes that.
class DeleteAllSessionsDialog extends StatefulWidget {
  final int count;
  final int totalBytes;
  const DeleteAllSessionsDialog({
    super.key,
    required this.count,
    required this.totalBytes,
  });

  @override
  State<DeleteAllSessionsDialog> createState() => _DeleteAllSessionsDialogState();
}

class _DeleteAllSessionsDialogState extends State<DeleteAllSessionsDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  void _close(bool result) {
    // Dismiss the keyboard BEFORE popping — tearing the route down while the
    // text field still holds focus is part of what crashed the first field
    // test (see the class comment).
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final armed = _typed.text.trim().toLowerCase() == 'delete';
    return AlertDialog(
      actionsOverflowDirection: VerticalDirection.up,
      title: DialogTitle(const Text('Delete ALL sessions?'), onClose: () => _close(false)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This permanently deletes all ${widget.count} sessions '
            '(${formatBytes(widget.totalBytes)}) from the phone — every data '
            'log, all metadata and every saved photo. This cannot be undone.',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _typed,
            autofocus: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: 'Type "delete" to confirm',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => _close(false), child: const Text('Cancel')),
        TextButton(
          onPressed: armed ? () => _close(true) : null,
          child: Text(
            'Delete all',
            style: TextStyle(
              color: armed ? Colors.red : null,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}
