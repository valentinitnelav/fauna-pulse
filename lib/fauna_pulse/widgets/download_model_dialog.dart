// FaunaPulse: the "Download from a link" dialog of the Download & import
// models screen (moved from the camera's settings sheet in round 267).
// Downloads a model file from a direct link with a progress bar. Round 275:
// any model file or name list; the file is checked and put where its kind
// lives (ModelImport.download), and a file already on the phone is replaced
// only when the user says so.

import 'package:flutter/material.dart';

import '../models/model_import.dart';

/// Asks whether to replace [name], already on this phone as a [kind], with
/// the new file ([fromLink]: before downloading it). Shared by the import
/// and the link download of Download & import models (round 275). With
/// [offerForAll] (more chosen files follow), a check box gives the same
/// answer for the other files already on the phone ([forAll]).
Future<({bool replace, bool forAll})> confirmReplaceModelFile(
  BuildContext context,
  String name,
  ModelFileKind kind, {
  bool fromLink = false,
  bool offerForAll = false,
}) async {
  var forAll = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Already on this phone'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$name is already on this phone (${kind.label}). '
              '${fromLink ? 'Download it again and replace the one on the phone?' : 'Replace it with the chosen file?'}',
            ),
            if (offerForAll)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: forAll,
                onChanged: (v) => setState(() => forAll = v ?? false),
                title: const Text('Same answer for the other chosen files already on the phone'),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep the one on the phone')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Replace')),
        ],
      ),
    ),
  );
  return (replace: ok ?? false, forAll: ok != null && forAll);
}

/// Downloads a link (injectable for tests): its file name and kind.
typedef LinkDownloader =
    Future<(String, ModelFileKind)> Function(
      String url, {
      void Function(int receivedBytes, int? totalBytes)? onProgress,
      bool Function()? isCancelled,
    });

/// Asks for a direct link to a model file or name list (e.g. a GitHub
/// release asset), downloads it with a progress bar and pops its name and
/// kind, or null on cancel. Errors show inline so the URL can be corrected
/// without retyping.
class DownloadModelDialog extends StatefulWidget {
  final LinkDownloader download;
  final Future<List<ModelFileKind>> Function(String name) onPhoneAs;

  const DownloadModelDialog({
    super.key,
    this.download = ModelImport.download,
    this.onPhoneAs = ModelImport.onPhoneAs,
  });

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
    final name = ModelImport.linkFileName(_url.text);
    if (name == null) return;
    final already = await widget.onPhoneAs(name);
    if (!mounted) return;
    if (already.isNotEmpty && !(await confirmReplaceModelFile(context, name, already.first, fromLink: true)).replace) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _downloading = true;
      _cancelRequested = false;
      _error = null;
      _received = 0;
      _total = null;
    });
    try {
      final saved = await widget.download(
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
      if (mounted) Navigator.of(context).pop(saved);
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
    final validUrl = ModelImport.linkFileName(_url.text) != null;
    return AlertDialog(
      title: const Text('Download from a link'),
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
              labelText: 'Link to a model file or name list',
              helperText:
                  'A .tflite, *_qnn.onnx or .fpack file. The app checks what it is '
                  'and puts it in its place. Model links are published at '
                  'github.com/valentinitnelav/fauna-pulse/releases',
              helperMaxLines: 5,
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
          // While downloading, Cancel signals the download between chunks;
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
