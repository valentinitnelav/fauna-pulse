// FaunaPulse (round 382, owner): one country chosen from a long list (about 250 countries), by
// typing its first letters or scrolling. Used by every single-country choice (the name list's
// country on Identify organisms, the user's country on "What do you want to watch?"); the
// window for several countries (multi_pick_dialog.dart) searches the same way.
//
// Built on Flutter's DropdownMenu: the field takes text, and the menu shows only the countries
// that match it, best matches first (models/list_search.dart: no case, no accents, other names
// such as "Turkey" or "UK"). The first entry is highlighted, so the keyboard's Done key picks it.
// The filter starts with the first typed letter, so a tap on the field still lists them all.
// The field empties when it gets focus and shows the choice again
// when left without a new one: DropdownMenu keeps the chosen entry's text in the field, so the
// first letters typed mixed into it ("Where the session waGerms recorded") and nothing matched.
// Selecting all text on focus was not used: the tap that gives focus then places the cursor.
// A tap outside the field and its menu takes the focus away (so the choice shows again and the
// keyboard closes): on phones Flutter's text fields keep the focus on such a tap. The TapRegion
// shares the menu's group (its MenuController), so a tap on a menu entry counts as inside.
// Flutter's menu places itself again only when the field moves or its rows are replaced, not
// when the keyboard comes up after it opened, so on a Redmi Note 9S (field low on the page) the
// matching countries stayed under the keyboard. So once the keyboard has stopped moving, an open
// menu gets its entries as a new list, which replaces its rows and places it above the field.
// Round 387 (Samsung M12): a pick takes the focus away too. Without that, the field kept it on a
// page that keeps this widget after a pick ("What do you want to watch?"), so the next tap neither
// emptied the field nor scrolled it above the keyboard; on Identify organisms the page rebuilds
// the widget after a pick, which dropped the focus there. Back with the field focused does what a
// tap outside does (Back closes the menus of the other dropdowns too; before, it left the page).
// It is an entry in the page's local history, as Flutter's drawers use, not a PopScope: a PopScope
// that refuses Back makes every PopScope of the page hear "Back refused", and Identify organisms
// then asked whether to stop an identification that was not running (Redmi Note 9S).
// The field is drawn like the app's other dropdowns (an underline): DropdownMenu draws a frame.
// Round 389: the entries are made once, and a new list goes to the menu only that one time after
// the keyboard moved. DropdownMenu builds a row for every entry, not only the visible ones, and a
// new list makes it replace all of them; until then that happened at every build, also at every
// frame of the keyboard's slide, and the first tap on the field froze a debug build for more than
// a second on a Xiaomi 11T Pro (a profile build, as fast as the app on Google Play: 0.8 s).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../identification/country_names.dart';
import '../models/list_search.dart';

class CountryField extends StatefulWidget {
  /// The chosen value (a country code, or one of [extra]'s values).
  final String? value;

  /// The countries offered, as codes, in the order to show (by name).
  final List<String> codes;

  /// Entries before the countries (value, text), for example "Where the session was recorded".
  final List<(String, String)> extra;
  final String label;
  final String? helperText;

  /// Null greys the field.
  final ValueChanged<String>? onChanged;

  const CountryField({
    super.key,
    required this.value,
    required this.codes,
    required this.label,
    required this.onChanged,
    this.extra = const [],
    this.helperText,
  });

  @override
  State<CountryField> createState() => _CountryFieldState();
}

class _CountryFieldState extends State<CountryField> with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _menu = MenuController();

  /// Set by a pick until the focus has gone (Flutter moves the focus a moment later): the field
  /// then keeps the picked entry's text.
  bool _picked = false;

  /// While the field has the focus: Back removes this entry (and so leaves the field) instead
  /// of leaving the page.
  LocalHistoryEntry? _backEntry;

  /// The menu's entries and their folded search texts, made again only when the countries or
  /// the extra entries change (see the top of the file).
  late List<DropdownMenuEntry<String>> _entries;
  late Map<String, String> _search;

  /// Runs once the keyboard has stopped moving (see the top of the file).
  Timer? _keyboardMoved;

  void _makeEntries() {
    _entries = [
      for (final (v, t) in widget.extra) DropdownMenuEntry(value: v, label: t),
      for (final c in widget.codes) DropdownMenuEntry(value: c, label: countryName(c)),
    ];
    _search = {
      for (final c in widget.codes) c: foldForSearch(countrySearchText(c)),
      for (final (v, t) in widget.extra) v: foldForSearch(t),
    };
  }

  @override
  void didUpdateWidget(CountryField old) {
    super.didUpdateWidget(old);
    if (!listEquals(old.codes, widget.codes) || !listEquals(old.extra, widget.extra)) _makeEntries();
  }

  String? get _chosenText {
    final v = widget.value;
    if (v == null) return null;
    for (final (ev, t) in widget.extra) {
      if (ev == v) return t;
    }
    return widget.codes.contains(v) ? countryName(v) : null;
  }

  @override
  void initState() {
    super.initState();
    _makeEntries();
    WidgetsBinding.instance.addObserver(this);
    _focus.addListener(() {
      if (_focus.hasFocus) {
        _text.clear();
        if (_backEntry == null) {
          final entry = _backEntry = LocalHistoryEntry(
            impliesAppBarDismissal: false,
            onRemove: () {
              _backEntry = null;
              _menu.close();
              _focus.unfocus();
            },
          );
          ModalRoute.of(context)?.addLocalHistoryEntry(entry);
        }
      } else {
        _dropBackEntry();
        // Left without choosing: show the choice again.
        if (!_picked && _text.text != (_chosenText ?? '')) _text.text = _chosenText ?? '';
      }
      _picked = false;
    });
  }

  void _dropBackEntry() {
    final entry = _backEntry;
    _backEntry = null;
    entry?.remove();
  }

  @override
  void didChangeMetrics() {
    // Called at every frame of the keyboard's slide: wait until it has stopped.
    _keyboardMoved?.cancel();
    _keyboardMoved = Timer(const Duration(milliseconds: 150), () {
      if (mounted && _menu.isOpen) setState(() => _entries = [..._entries]);
    });
  }

  @override
  void dispose() {
    _keyboardMoved?.cancel();
    _dropBackEntry();
    WidgetsBinding.instance.removeObserver(this);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final value = w.value, onChanged = w.onChanged, search = _search;
    return TapRegion(
      groupId: _menu,
      onTapOutside: (_) {
        if (_focus.hasFocus) _focus.unfocus();
      },
      child: DropdownMenu<String>(
        // A new value (chosen elsewhere, or by the page) shows its text.
        key: ValueKey('country field $value ${onChanged == null}'),
        controller: _text,
        focusNode: _focus,
        menuController: _menu,
        initialSelection: value,
        enabled: onChanged != null,
        label: Text(w.label),
        helperText: w.helperText,
        expandedInsets: EdgeInsets.zero,
        inputDecorationTheme: Theme.of(context).inputDecorationTheme,
        menuHeight: 320,
        // Phones open the keyboard only on a tap when this is on; typing is the point here.
        requestFocusOnTap: true,
        enableFilter: true,
        filterCallback: (entries, filter) =>
            searchList(entries, filter, (e) => search[e.value] ?? foldForSearch(e.label)),
        // Flutter's default highlights the first label that holds the text, which misses a
        // country found by another name ("Turkey") and is not the best match.
        searchCallback: (entries, filter) => filter.trim().isEmpty || entries.isEmpty ? null : 0,
        trailingIcon: const Icon(Icons.arrow_drop_down),
        dropdownMenuEntries: _entries,
        onSelected: (v) {
          _picked = v != null && _focus.hasFocus;
          _focus.unfocus();
          if (v != null) onChanged?.call(v);
        },
      ),
    );
  }
}
