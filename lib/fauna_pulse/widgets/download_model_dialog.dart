// FaunaPulse: the "Download model" dialog of the AI models screen (moved
// from the camera's settings sheet in round 267). Downloads a detection model
// from a direct link with a progress bar.

import 'package:flutter/material.dart';

import '../models/model_catalog.dart';

/// Asks for a direct link to a model file (e.g. a GitHub release asset),
/// downloads it with a progress bar and pops the saved file path — or null on
/// cancel. Errors show inline so the URL can be corrected without retyping.
class DownloadModelDialog extends StatefulWidget {
  const DownloadModelDialog({super.key});

  @override
  State<DownloadModelDialog> createState() => _DownloadModelDialogState();
}

class _DownloadModelDialogState extends State<DownloadModelDialog> {
  final _url = TextEditingController();
  bool _downloading = false;
  bool _cancelRequested = false;
  String? _error;
  int _received = 0;
  int? _total;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _downloading = true;
      _cancelRequested = false;
      _error = null;
      _received = 0;
      _total = null;
    });
    try {
      final path = await ModelCatalog.downloadModel(
        _url.text,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
        isCancelled: () => _cancelRequested,
      );
      if (mounted) Navigator.of(context).pop(path);
    } catch (e) {
      if (!mounted) return;
      if (_cancelRequested) {
        Navigator.of(context).pop(); // user cancelled; partial file cleaned up
        return;
      }
      setState(() {
        _downloading = false;
        // Exception.toString() prefixes "Exception: " — drop it for the UI.
        _error = '$e'.replaceFirst('Exception: ', '');
      });
    }
  }

  String get _progressLabel {
    String mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
    final total = _total;
    return total != null
        ? 'Downloading… ${mb(_received)} of ${mb(total)} MB'
        : 'Downloading… ${mb(_received)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final validUrl = modelFileNameFromUrl(_url.text) != null;
    return AlertDialog(
      title: const Text('Download model'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _url,
            enabled: !_downloading,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: 'Link to a .tflite or *_qnn.onnx model file',
              helperText:
                  'Model links are published at\n'
                  'github.com/valentinitnelav/fauna-pulse/releases',
              helperMaxLines: 3,
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (_downloading) ...[
            const SizedBox(height: 14),
            LinearProgressIndicator(
              value: _total != null && _total! > 0 ? _received / _total! : null,
            ),
            const SizedBox(height: 6),
            Text(
              _progressLabel,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '⚠ $_error',
                style: const TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 13,
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          // While downloading, Cancel signals downloadModel between chunks;
          // its cleanup deletes the partial file, then _start pops the dialog.
          onPressed: _downloading && _cancelRequested
              ? null
              : () {
                  if (_downloading) {
                    setState(() => _cancelRequested = true);
                  } else {
                    Navigator.of(context).pop();
                  }
                },
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _downloading || !validUrl ? null : _start,
          child: const Text(
            'Download',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
