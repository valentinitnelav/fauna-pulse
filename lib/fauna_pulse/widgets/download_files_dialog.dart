// FaunaPulse (round 268): downloads the files of one AI models screen entry
// (a detection model, or an identification model and/or a name list) after
// showing their total size; one progress bar over all files, Cancel between
// chunks. Pops true when every file arrived.

import 'package:flutter/material.dart';

import '../logging/device_storage.dart' show formatBytes;
import '../models/model_downloads.dart';
import '../models/model_file_security.dart' show plainModelError;

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

  const DownloadFilesDialog({
    super.key,
    required this.title,
    required this.description,
    required this.files,
    required this.download,
  });

  @override
  State<DownloadFilesDialog> createState() => _DownloadFilesDialogState();
}

class _DownloadFilesDialogState extends State<DownloadFilesDialog> {
  /// Large enough to suggest Wi-Fi (mobile data plans).
  static const _largeBytes = 100 * 1024 * 1024;

  bool _running = false;
  bool _cancel = false;
  int _index = 0;
  int _doneBytes = 0;
  int _received = 0;
  String? _error;

  int get _total => widget.files.fold(0, (s, f) => s + f.bytes);

  Future<void> _start() async {
    // "Try again" continues with the file that failed; finished files stay.
    setState(() {
      _running = true;
      _cancel = false;
      _error = null;
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
      setState(() {
        _running = false;
        _error = plainModelError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _total;
    final n = widget.files.length;
    final done = _doneBytes + _received;
    return AlertDialog(
      title: Text('Download ${widget.title}'),
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
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('⚠ $_error', style: const TextStyle(color: Colors.orangeAccent, fontSize: 13)),
            ),
        ],
      ),
      actions: [
        TextButton(
          // While downloading, Cancel is checked between chunks; the partial
          // file is deleted and the dialog closes.
          onPressed: _running && _cancel
              ? null
              : () {
                  if (_running) {
                    setState(() => _cancel = true);
                  } else {
                    Navigator.of(context).pop(false);
                  }
                },
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _running ? null : _start,
          child: Text(_error == null ? 'Download' : 'Try again', style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}
