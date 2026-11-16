// FaunaPulse (round 376): a window to tick any number of entries of a long list, with a search
// box (the about 250 countries of a name list's country lists). A dropdown cannot do either.
// Round 377: an entry can belong to a group entry (a family to its order); ticking the group
// stands for all of its entries.

import 'package:flutter/material.dart';

import 'dialog_title.dart';

/// One entry: what is stored ([value]), what is shown ([label]) and a short grey note under
/// it ([detail], for example a number of names). [group] is the value of the entry it belongs
/// to, listed before it; such an entry is shown indented.
class PickItem {
  final String value;
  final String label;
  final String? detail;
  final String? group;

  const PickItem(this.value, this.label, {this.detail, this.group});
}

/// Shows [items] with the entries of [chosen] ticked. Returns the ticked values in the order
/// of [items], or null when the window was closed without "Use these" (nothing changes then).
/// A ticked group is returned without its entries: they show as ticked and cannot be changed
/// while the group is ticked.
/// Keep [title] to one or two words: a title of several lines leaves no room for the list
/// above the keyboard of a small phone.
Future<List<String>?> showMultiPickDialog(
  BuildContext context, {
  required String title,
  required List<PickItem> items,
  required Iterable<String> chosen,
  String searchHint = 'Search',
}) => showDialog<List<String>>(
  context: context,
  builder: (_) => _MultiPickDialog(title: title, items: items, chosen: chosen, searchHint: searchHint),
);

class _MultiPickDialog extends StatefulWidget {
  final String title;
  final List<PickItem> items;
  final Iterable<String> chosen;
  final String searchHint;

  const _MultiPickDialog({required this.title, required this.items, required this.chosen, required this.searchHint});

  @override
  State<_MultiPickDialog> createState() => _MultiPickDialogState();
}

class _MultiPickDialogState extends State<_MultiPickDialog> {
  final _search = TextEditingController();
  // Only values the list holds: an entry that is no longer offered cannot be seen or unticked.
  late final _chosen = {
    for (final i in widget.items)
      if (widget.chosen.contains(i.value) && !widget.chosen.contains(i.group)) i.value,
  };
  late final _groups = {for (final i in widget.items) ?i.group};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final shown = query.isEmpty ? widget.items : [for (final i in widget.items) if (i.label.toLowerCase().contains(query)) i];
    void close() => Navigator.of(context).pop();
    return AlertDialog(
      actionsOverflowDirection: VerticalDirection.up,
      // Wider than a window of text: the entries are long names with a number.
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: DialogTitle(Text(widget.title), onClose: close),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      // A fixed width: a dialog asks its content how wide it wants to be, which a lazily
      // built list cannot answer. The height is cut to the room the screen has, and to what
      // is left above the keyboard.
      content: SizedBox(
        width: double.maxFinite,
        height: 600,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _search,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: widget.searchHint,
                border: const OutlineInputBorder(),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(icon: const Icon(Icons.clear), tooltip: 'Clear the search', onPressed: () => setState(_search.clear)),
              ),
              onChanged: (_) => setState(() {}),
            ),
            Row(
              children: [
                Expanded(child: Text('${_chosen.length} ticked', style: const TextStyle(color: Colors.white70, fontSize: 13))),
                TextButton(onPressed: _chosen.isEmpty ? null : () => setState(_chosen.clear), child: const Text('Untick all')),
              ],
            ),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('Nothing found.', style: TextStyle(color: Colors.white54)))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (_, n) {
                        final item = shown[n];
                        final inTickedGroup = _chosen.contains(item.group);
                        return CheckboxListTile(
                          dense: true,
                          // Entries of a group are set in; in search results every entry starts at the left.
                          contentPadding: EdgeInsets.only(left: item.group != null && query.isEmpty ? 24 : 0),
                          controlAffinity: ListTileControlAffinity.leading,
                          value: inTickedGroup || _chosen.contains(item.value),
                          onChanged: inTickedGroup
                              ? null
                              : (v) => setState(() {
                                  if (v != true) {
                                    _chosen.remove(item.value);
                                  } else {
                                    _chosen.add(item.value);
                                    // The group now stands for its entries.
                                    _chosen.removeAll([for (final i in widget.items) if (i.group == item.value) i.value]);
                                  }
                                }),
                          title: Text(
                            item.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: _groups.contains(item.value) ? const TextStyle(fontWeight: FontWeight.bold) : null,
                          ),
                          subtitle: item.detail == null ? null : Text(item.detail!, maxLines: 1, overflow: TextOverflow.ellipsis),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: close, child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.of(context).pop([for (final i in widget.items) if (_chosen.contains(i.value)) i.value]),
          child: const Text('Use these', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}
