// FaunaPulse (round 277): every past session on its own screen, opened from
// the home screen's "Sessions" button (owner: the home screen listed every
// session under its buttons; a separate screen leaves room for filters).
// Owner choices (round 277, from mock-ups):
//   • A search field, a "Filters" button opening a panel from the bottom
//     (date, length, how it was recorded, Find animals done, identified) and
//     a Sort menu; the filters that are set show as chips to remove with ✕,
//     with "8 of 23 sessions".
//   • Pressing and holding a session starts selecting (the usual Android way);
//     the top bar then shows "3 selected" with Select all and Delete. Find
//     animals for one session is in the row's ⋮ menu (it was the long-press
//     until now).
//   • "Delete all sessions…" moved here from the home screen's ⋮ menu, with
//     "Import videos…". Deleting every session still asks to type "delete".

import 'package:flutter/material.dart';

import '../logging/device_storage.dart';
import '../logging/past_sessions.dart';
import '../logging/session_filter.dart';
import '../widgets/session_tile.dart';
import '../widgets/setting_help.dart' show helperTextStyle;
import 'session_actions.dart';

enum _MenuAction { select, importVideos, deleteAll }

class SessionsScreen extends StatefulWidget {
  /// Reads the sessions; tests give a temporary folder.
  final Future<List<PastSession>> Function() scan;

  /// "Today" for the date filters; tests fix it.
  final DateTime Function() now;

  const SessionsScreen({super.key, this.scan = scanPastSessions, this.now = DateTime.now});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> with SessionActions {
  List<PastSession>? _all;
  SessionFilter _filter = const SessionFilter();
  SessionSort _sort = SessionSort.newest;
  final _search = TextEditingController();

  /// Folder paths of the selected sessions; null when not selecting.
  Set<String>? _selected;

  @override
  void initState() {
    super.initState();
    reloadSessions();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Future<void> reloadSessions() async {
    final all = await widget.scan();
    if (!mounted) return;
    setState(() {
      _all = all;
      // Deleted or renamed sessions leave the selection.
      final paths = {for (final s in all) s.dir.path};
      _selected?.removeWhere((p) => !paths.contains(p));
    });
  }

  List<PastSession> get _shown => _filter.apply(_all ?? const [], _sort, widget.now());

  void _toggle(PastSession s) => setState(() {
    final sel = _selected ??= {};
    if (!sel.remove(s.dir.path)) sel.add(s.dir.path);
  });

  void _endSelecting() => setState(() => _selected = null);

  Future<void> _deleteSelected() async {
    final sel = _selected ?? const <String>{};
    final chosen = [for (final s in _all ?? const <PastSession>[]) if (sel.contains(s.dir.path)) s];
    if (await confirmDeleteSessions(chosen, total: _all?.length ?? 0) && mounted) _endSelecting();
  }

  Future<void> _onMenu(_MenuAction a) async {
    switch (a) {
      case _MenuAction.select:
        setState(() => _selected = {});
      case _MenuAction.importVideos:
        await importVideos();
      case _MenuAction.deleteAll:
        await confirmDeleteSessions(List.of(_all ?? const []), total: _all?.length ?? 0);
    }
  }

  PreferredSizeWidget _appBar() {
    final sel = _selected;
    if (sel != null) {
      final shown = _shown;
      final allShownSelected = shown.isNotEmpty && shown.every((s) => sel.contains(s.dir.path));
      return AppBar(
        leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Stop selecting', onPressed: _endSelecting),
        title: Text('${sel.length} selected'),
        actions: [
          IconButton(
            icon: Icon(allShownSelected ? Icons.deselect : Icons.select_all),
            tooltip: allShownSelected ? 'Select none' : 'Select all shown',
            onPressed: shown.isEmpty
                ? null
                : () => setState(() {
                    if (allShownSelected) {
                      sel.removeAll(shown.map((s) => s.dir.path));
                    } else {
                      sel.addAll(shown.map((s) => s.dir.path));
                    }
                  }),
          ),
          IconButton(
            icon: Icon(Icons.delete_outline, color: sel.isEmpty ? null : Colors.red.shade300),
            tooltip: 'Delete the selected sessions',
            onPressed: sel.isEmpty ? null : _deleteSelected,
          ),
        ],
      );
    }
    final hasSessions = _all?.isNotEmpty ?? false;
    return AppBar(
      title: const Text('Sessions'),
      actions: [
        PopupMenuButton<_MenuAction>(
          tooltip: 'More',
          onSelected: _onMenu,
          itemBuilder: (_) => [
            PopupMenuItem(
              value: _MenuAction.select,
              enabled: hasSessions,
              child: const _MenuRow(Icons.checklist, 'Select sessions'),
            ),
            // Round 227: videos filmed elsewhere become a session (moved
            // here from the home screen's ⋮ menu in round 277).
            const PopupMenuItem(
              value: _MenuAction.importVideos,
              child: _MenuRow(Icons.video_library_outlined, 'Import videos…'),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: _MenuAction.deleteAll,
              enabled: hasSessions,
              child: _MenuRow(
                Icons.delete_sweep,
                'Delete all sessions…',
                color: hasSessions ? Colors.red.shade300 : Colors.white38,
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = _all;
    return PopScope(
      // Back ends the selection first, as in other Android apps.
      canPop: _selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _endSelecting();
      },
      child: Scaffold(
        appBar: _appBar(),
        body: SafeArea(
          child: all == null
              ? const Center(child: CircularProgressIndicator())
              : all.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No sessions yet.\nTap "New session" on the home screen to record one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                )
              : _list(all),
        ),
      ),
    );
  }

  Widget _list(List<PastSession> all) {
    final shown = _shown;
    final sel = _selected;
    return RefreshIndicator(
      onRefresh: reloadSessions,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 24),
        // The header rows, then one row per shown session.
        itemCount: shown.length + 1,
        separatorBuilder: (_, i) => i == 0 ? const SizedBox.shrink() : const Divider(height: 1),
        itemBuilder: (_, i) {
          if (i == 0) return _header(all, shown);
          final s = shown[i - 1];
          return SessionTile(
            session: s,
            selected: sel?.contains(s.dir.path),
            onTap: () => sel == null ? openSession(s) : _toggle(s),
            onLongPress: () => _toggle(s),
            onAction: (a) => onSessionAction(s, a),
          );
        },
      ),
    );
  }

  Widget _header(List<PastSession> all, List<PastSession> shown) {
    final chips = _filter.chips();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _search,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search by name',
              border: const OutlineInputBorder(),
              suffixIcon: _filter.query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'Clear the search',
                      onPressed: () {
                        _search.clear();
                        setState(() => _filter = _filter.copyWith(query: ''));
                      },
                    ),
            ),
            onChanged: (q) => setState(() => _filter = _filter.copyWith(query: q)),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _openFilters,
                icon: const Icon(Icons.filter_list, size: 18),
                label: Text(_filter.panelCount == 0 ? 'Filters' : 'Filters (${_filter.panelCount})'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: PopupMenuButton<SessionSort>(
                    tooltip: 'Order of the sessions',
                    initialValue: _sort,
                    onSelected: (s) => setState(() => _sort = s),
                    itemBuilder: (_) => [
                      for (final s in SessionSort.values) PopupMenuItem(value: s, child: Text(s.label)),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.sort, size: 18, color: Colors.white70),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              _sort.label,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down, color: Colors.white70),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (chips.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 0,
              children: [
                for (final c in chips)
                  InputChip(
                    label: Text(c.label),
                    visualDensity: VisualDensity.compact,
                    onDeleted: () => setState(() => _filter = c.without),
                    deleteButtonTooltipMessage: 'Remove this filter',
                  ),
              ],
            ),
          const SizedBox(height: 4),
          Text(
            '${_filter.isEmpty ? '${all.length} ${all.length == 1 ? 'session' : 'sessions'}' : '${shown.length} of ${all.length} sessions'}'
            ' (${formatBytes(shown.fold<int>(0, (sum, s) => sum + s.sizeBytes))})'
            '${_selected == null ? '. Hold one to select several.' : ''}',
            style: helperTextStyle,
          ),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Column(
                children: [
                  const Text('No session matches.', style: TextStyle(color: Colors.white54)),
                  TextButton(
                    onPressed: () {
                      _search.clear();
                      setState(() => _filter = const SessionFilter());
                    },
                    child: const Text('Clear search and filters'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openFilters() async {
    final picked = await showModalBottomSheet<SessionFilter>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FiltersPanel(
        initial: _filter,
        count: (f) => f.apply(_all ?? const [], _sort, widget.now()).length,
      ),
    );
    if (picked != null && mounted) setState(() => _filter = picked);
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  const _MenuRow(this.icon, this.text, {this.color});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 20, color: color ?? Colors.white70),
      const SizedBox(width: 10),
      Flexible(child: Text(text)),
    ],
  );
}

/// The panel of filters: pops the chosen [SessionFilter] with "Show n".
class _FiltersPanel extends StatefulWidget {
  final SessionFilter initial;

  /// How many sessions a filter shows.
  final int Function(SessionFilter) count;

  const _FiltersPanel({required this.initial, required this.count});

  @override
  State<_FiltersPanel> createState() => _FiltersPanelState();
}

class _FiltersPanelState extends State<_FiltersPanel> {
  late SessionFilter _f = widget.initial;

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
  );

  Future<void> _chooseDates() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _f.from != null && _f.to != null ? DateTimeRange(start: _f.from!, end: _f.to!) : null,
    );
    if (r != null && mounted) setState(() => _f = _f.copyWith(date: DateFilter.range, from: r.start, to: r.end));
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.count(_f);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _heading('Date'),
            Wrap(
              spacing: 6,
              children: [
                for (final d in DateFilter.values)
                  ChoiceChip(
                    label: Text(d == DateFilter.range && _f.date == DateFilter.range ? _f.dateLabel : d.label),
                    selected: _f.date == d,
                    onSelected: (_) => d == DateFilter.range
                        ? _chooseDates()
                        : setState(() => _f = _f.copyWith(date: d)),
                  ),
              ],
            ),
            _heading('Length'),
            Wrap(
              spacing: 6,
              children: [
                for (final l in LengthFilter.values)
                  ChoiceChip(
                    label: Text(l.label),
                    selected: _f.length == l,
                    onSelected: (_) => setState(() => _f = _f.copyWith(length: l)),
                  ),
              ],
            ),
            _heading('Recorded as'),
            Wrap(
              spacing: 6,
              children: [
                for (final k in RecordingKind.values)
                  FilterChip(
                    avatar: Icon(recordingKindIcon(k), size: 18),
                    label: Text(k.label),
                    selected: _f.kinds.contains(k),
                    onSelected: (on) => setState(
                      () => _f = _f.copyWith(kinds: on ? {..._f.kinds, k} : ({..._f.kinds}..remove(k))),
                    ),
                  ),
              ],
            ),
            const Text('None chosen: every kind.', style: helperTextStyle),
            _heading('Done after recording'),
            Wrap(
              spacing: 6,
              children: [
                FilterChip(
                  avatar: const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: const Text('Find animals'),
                  selected: _f.findDone,
                  onSelected: (on) => setState(() => _f = _f.copyWith(findDone: on)),
                ),
                FilterChip(
                  avatar: const Icon(Icons.biotech_outlined, size: 18),
                  label: const Text('Identify organisms'),
                  selected: _f.identified,
                  onSelected: (on) => setState(() => _f = _f.copyWith(identified: on)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                  onPressed: _f.panelCount == 0 ? null : () => setState(() => _f = _f.panelCleared),
                  child: const Text('Clear'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(_f),
                    child: Text(n == 1 ? 'Show 1 session' : 'Show $n sessions', overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
