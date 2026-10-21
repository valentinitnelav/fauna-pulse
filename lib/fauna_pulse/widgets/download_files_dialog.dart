// FaunaPulse (round 268): downloads the files of one AI models screen entry
// (a detection model, or an identification model and/or a name list) after
// showing their total size; one progress bar over all files, Cancel between
// chunks. Pops true when every file arrived.

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';
import '../models/model_downloads.dart';
import '../models/model_file_security.dart' show isNetworkError, modelStorageNeededBytes, plainModelError;
import '../models/phone_state.dart';
import '../services/phone_settings.dart';
import 'dialog_title.dart';

/// Downloads one catalogue file into the folder of its kind (injectable for
/// tests; Download & import models and the "watch" page, round 278).
typedef CatalogueFileDownloader =
    Future<void> Function(
      DownloadFile file,
      bool identification,
      void Function(int receivedBytes, int? totalBytes) onProgress,
      bool Function() isCancelled,
    );

Future<void> downloadCatalogueFileForReal(
  DownloadFile file,
  bool identification,
  void Function(int receivedBytes, int? totalBytes) onProgress,
  bool Function() isCancelled,
) async {
  await downloadCatalogueFile(file, identification: identification, onProgress: onProgress, isCancelled: isCancelled);
}

/// Downloads one file, reporting progress; injectable for tests.
typedef CatalogueDownloader =
    Future<void> Function(
      DownloadFile file,
      void Function(int receivedBytes, int? totalBytes) onProgress,
      bool Function() isCancelled,
    );

class DownloadFilesDialog extends StatefulWidget {
  final String title;

  /// What arrives, in words ("the model and its 104 classes").
  final String description;
  final List<DownloadFile> files;
  final CatalogueDownloader download;

  /// Read after a network error, to name airplane mode (injectable for tests).
  final Future<PhoneState> Function() readPhoneState;

  const DownloadFilesDialog({
    super.key,
    required this.title,
    required this.description,
    required this.files,
    required this.download,
    this.readPhoneState = PhoneSettings.read,
  });

  @override
  State<DownloadFilesDialog> createState() => _DownloadFilesDialogState();
}

/// Free bytes on the storage of the model folders (all in the app's private
/// folder), or null when the phone does not say.
Future<int?> _modelStorageFreeBytes() async {
  try {
    return (await DeviceStorage.read(path: (await getApplicationSupportDirectory()).path)).freeBytes;
  } catch (e) {
    logSwallowed('download_storage_check', e);
    return null;
  }
}

class _DownloadFilesDialogState extends State<DownloadFilesDialog> with WidgetsBindingObserver {
  /// Large enough to suggest Wi-Fi (mobile data plans).
  static const _largeBytes = 100 * 1024 * 1024;

  bool _running = false;
  bool _cancel = false;
  int _index = 0;
  int _doneBytes = 0;
  int _received = 0;
  String? _error;

  /// [_error] is about too little storage and holds amounts that go out of
  /// date when space is freed.
  bool _storageError = false;

  /// Free storage, read when the dialog opens, when the app comes back to
  /// the front and after a failed download (round 319: before, the warning
  /// came only after Download was pressed). Null when unknown.
  int? _free;

  int get _total => widget.files.fold(0, (s, f) => s + f.bytes);

  /// The files still to download and the same margin as the check at the
  /// start of each file (ensureModelStorageAvailable).
  int get _needed => modelStorageNeededBytes(_total - _doneBytes);

  bool get _tooLittleRoom => !_running && _free != null && _free! < _needed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _readFree();
  }

  // Back from another app (space may have been freed there): read again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _readFree(afterLeaving: true);
  }

  /// [afterLeaving]: the user was in another app. When there is enough room
  /// now, a storage error goes: its amount ("About 1.1 GB more is needed")
  /// is no longer true (round 319, phone test PB1). Not right after a
  /// failure: deleting the half file may give the room back, and the
  /// message must still say why the download stopped.
  Future<void> _readFree({bool afterLeaving = false}) async {
    final free = await _modelStorageFreeBytes();
    if (!mounted) return;
    setState(() {
      _free = free;
      if (afterLeaving && _storageError && !_running && free != null && free >= _needed) {
        _error = null;
        _storageError = false;
      }
    });
  }

  Future<void> _start() async {
    // "Try again" continues with the file that failed; finished files stay.
    setState(() {
      _running = true;
      _cancel = false;
      _error = null;
      _storageError = false;
      _received = 0;
    });
    try {
      for (final f in widget.files.skip(_index)) {
        await widget.download(f, (received, _) {
          if (mounted) setState(() => _received = received);
        }, () => _cancel);
        if (!mounted) return;
        setState(() {
          _doneBytes += f.bytes;
          _received = 0;
          _index++;
        });
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      if (_cancel) {
        Navigator.of(context).pop(false);
        return;
      }
      // The technical text, for a problem report (the user sees plain words).
      logSwallowed('catalogue_download', e);
      // Round 319: no network because of airplane mode is said as such.
      final phone = isNetworkError(e) ? await widget.readPhoneState() : null;
      if (!mounted) return;
      final error = plainModelError(e, phone: phone);
      setState(() {
        _running = false;
        _error = error;
        _storageError = error.startsWith('Not enough free storage');
      });
      await _readFree();
    }
  }

  @override
  void dispose() {
    // Safety net: if the route goes away some other way while a file is
    // downloading, the downloader sees the cancel at its next chunk and
    // deletes the partial file instead of running on with nobody watching.
    _cancel = true;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _total;
    final n = widget.files.length;
    final done = _doneBytes + _received;
    // While downloading, Cancel (and the X) is checked between chunks; the
    // partial file is deleted and the dialog closes.
    final VoidCallback? cancel = _running && _cancel
        ? null
        : () {
            if (_running) {
              setState(() => _cancel = true);
            } else {
              Navigator.of(context).pop(false);
            }
          };
    // The phone's Back button acts like Cancel while a file is downloading
    // (barrierDismissible: false blocks only a tap outside). The dialog stays
    // until the download has really stopped, so a second Download of the same
    // file cannot overlap with this one; it then pops false as for Cancel.
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _running && !_cancel) setState(() => _cancel = true);
      },
      child: AlertDialog(
      actionsOverflowDirection: VerticalDirection.up,
      title: DialogTitle(Text('Download ${widget.title}'), onClose: cancel),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${widget.description} In total ${formatBytes(total)}.'),
          if (total >= _largeBytes)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'A large download: use Wi-Fi if you can.',
                style: TextStyle(color: Colors.amber, fontSize: 13),
              ),
            ),
          if (_running) ...[
            const SizedBox(height: 14),
            LinearProgressIndicator(value: total > 0 ? (done / total).clamp(0.0, 1.0) : null),
            const SizedBox(height: 6),
            Text(
              '${n > 1 ? 'File ${(_index + 1).clamp(1, n)} of $n: ' : ''}'
              '${formatBytes(done)} of ${formatBytes(total)}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
          // Too little room says what to do and replaces an older error (it
          // is usually the same problem, in other words).
          if (_tooLittleRoom || _error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _tooLittleRoom
                    ? '⚠ Not enough free storage: the download needs ${formatBytes(_needed)}, but '
                          '${freeStorageClause(_free!, unitOf: _needed)}. Delete some files (for example old '
                          'sessions on the Sessions screen), then come back here.'
                    : '⚠ $_error',
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 13),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: cancel, child: const Text('Cancel')),
        TextButton(
          onPressed: _running || _tooLittleRoom ? null : _start,
          child: Text(_error == null ? 'Download' : 'Try again', style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
      ),
    );
  }
}
