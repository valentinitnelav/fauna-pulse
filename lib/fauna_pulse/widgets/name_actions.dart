// FaunaPulse (round 378): what the app offers for the name of an organism wherever one is
// listed (the names of a name list, the identification results): a web search, to compare
// the name with photos, and a copy, because text in a table cannot be selected.
// The rows of the results open this window on a long press: a tap there already opens the
// next view. Each such view says so once ([kHoldNameHint]).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../logging/app_error_hooks.dart';
import 'dialog_title.dart';
import 'external_link.dart';

const kHoldNameHint = 'Hold a name to search the web for it or to copy it.';

/// A window for [name]: "Search the web" and "Copy the name".
Future<void> showNameActions(BuildContext context, String name) =>
    showDialog<void>(context: context, builder: (_) => _NameActionsDialog(name));

class _NameActionsDialog extends StatefulWidget {
  final String name;

  const _NameActionsDialog(this.name);

  @override
  State<_NameActionsDialog> createState() => _NameActionsDialogState();
}

class _NameActionsDialogState extends State<_NameActionsDialog> {
  var _copied = false;

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.name));
      // Said in the window: a SnackBar would lie hidden under the results' sheets.
      if (mounted) setState(() => _copied = true);
    } catch (e) {
      logSwallowed('name_copy', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    void close() => Navigator.of(context).pop();
    return AlertDialog(
      title: DialogTitle(Text(widget.name), onClose: close),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.search),
            title: const Text('Search the web'),
            subtitle: const Text('Opens the search app or the browser of this phone. Needs internet.'),
            onTap: () {
              // Closed first, so the window is not in the way when the user comes back.
              close();
              searchTheWeb(widget.name);
            },
          ),
          ListTile(
            leading: Icon(_copied ? Icons.check : Icons.copy),
            title: Text(_copied ? 'Copied' : 'Copy the name'),
            onTap: _copy,
          ),
        ],
      ),
      actions: [TextButton(onPressed: close, child: const Text('Close'))],
    );
  }
}
