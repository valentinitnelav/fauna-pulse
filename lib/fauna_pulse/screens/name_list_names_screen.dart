// FaunaPulse (round 378): "Names to choose from", the names of a name list as a list with a
// search box. Opened from Identify organisms ("Show these names": the names a run would choose
// from with the countries, orders and families chosen there) and from a name list's card on
// Download & import models (every name of the list). A tap on a name offers a web search for
// it and a copy (widgets/name_actions.dart).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../identification/name_list_names.dart';
import '../logging/app_error_hooks.dart';
import '../models/list_search.dart';
import '../widgets/home_button.dart';
import '../widgets/name_actions.dart';
import '../widgets/setting_help.dart';
import 'identification_choice_fields.dart' show thousands;

/// The page for every name of the name list file whose path is [arguments]. Download &
/// import models pushes it with `restorablePush`: a web search opens another app, which is
/// when Android tends to close FaunaPulse, and the user expects the page back (the pragma
/// keeps the builder in the release build).
@pragma('vm:entry-point')
Route<void> nameListNamesRoute(BuildContext context, Object? arguments) =>
    MaterialPageRoute<void>(builder: (_) => NameListNamesScreen(packFile: File(arguments! as String)));

class NameListNamesScreen extends StatefulWidget {
  final File packFile;

  /// The rows to list (NameListChoice.rowBits); null = every name of the list.
  final Uint8List? rowBits;

  /// Which names these are, in one sentence; null = every name of the list.
  final String? intro;

  const NameListNamesScreen({super.key, required this.packFile, this.rowBits, this.intro});

  @override
  State<NameListNamesScreen> createState() => _NameListNamesScreenState();
}

class _NameListNamesScreenState extends State<NameListNamesScreen> {
  final _search = TextEditingController();
  NameListNames? _names;
  bool _failed = false;

  /// The names the search box leaves, kept between builds (a page rebuilds at every frame of
  /// the keyboard sliding in, and a list can hold tens of thousands of names).
  List<NameEntry> _shown = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final names = await readNameListNames(widget.packFile, rowBits: widget.rowBits);
      if (!mounted) return;
      setState(() {
        _names = names;
        _filter();
      });
    } catch (e) {
      logSwallowed('name_list_names', e);
      if (mounted) setState(() => _failed = true);
    }
  }

  void _filter() {
    final all = _names?.names ?? const <NameEntry>[];
    _shown = searchList(all, _search.text, (n) => n.search);
  }

  @override
  Widget build(BuildContext context) {
    final names = _names;
    return Scaffold(
      appBar: AppBar(title: const FitTitle('Names to choose from'), actions: const [HomeButton()]),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Above the list, not in it: the box stays in reach while the names scroll.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                controller: _search,
                enabled: names != null,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search a name, a family or an order',
                  border: const OutlineInputBorder(),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Clear the search',
                          onPressed: () => setState(() {
                            _search.clear();
                            _filter();
                          }),
                        ),
                ),
                onChanged: (_) => setState(_filter),
              ),
            ),
            Expanded(
              child: _failed
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('This name list could not be read. It may have been deleted, or the file is damaged.'),
                    )
                  : names == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 32),
                      itemCount: _shown.length + 1,
                      itemBuilder: (context, i) {
                        if (i == 0) return _intro(names);
                        final n = _shown[i - 1];
                        return ListTile(
                          dense: true,
                          title: Text(n.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: n.detail.isEmpty ? null : Text(n.detail, maxLines: 2, overflow: TextOverflow.ellipsis),
                          onTap: () => showNameActions(context, n.name),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// The first entry of the list: which names these are, and how many the search leaves.
  Widget _intro(NameListNames names) {
    final total = thousands(names.names.length);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.intro ?? 'Every name of this name list.', style: const TextStyle(color: Colors.white70)),
          Text(widget.packFile.path.split('/').last, style: helperTextStyle),
          if (names.noneOfThese.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Always among the choices too, for a box that shows no organism: ${names.noneOfThese.join(', ')}.',
                style: helperTextStyle,
              ),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('Tap a name to search the web for it or to copy it.', style: helperTextStyle),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _search.text.trim().isEmpty
                  ? '$total names, in alphabetical order'
                  : _shown.isEmpty
                  ? 'Nothing found among the $total names.'
                  : '${thousands(_shown.length)} of $total names',
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}
