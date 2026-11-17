// FaunaPulse (round 382, owner): one country chosen from a long list (about 250 countries), by
// typing its first letters or scrolling. Used by every single-country choice (the name list's
// country on Identify organisms, the user's country on "What do you want to watch?"); the
// window for several countries (multi_pick_dialog.dart) searches the same way.
//
// Built on Flutter's DropdownMenu: the field takes text, and the menu shows only the countries
// that match it (matchesSearch: no case, no accents, other names such as "Turkey" or "UK").
// The filter starts with the first typed letter, so a tap on the field still lists them all.
// The field empties when it gets focus and shows the choice again
// when left without a new one: DropdownMenu keeps the chosen entry's text in the field, so the
// first letters typed mixed into it ("Where the session waGerms recorded") and nothing matched.
// Selecting all text on focus was not used: the tap that gives focus then places the cursor.

import 'package:flutter/material.dart';

import '../identification/country_names.dart';
import 'multi_pick_dialog.dart' show matchesSearch;

class CountryField extends StatefulWidget {
  /// The chosen value (a country code, or one of [extra]'s values).
  final String? value;

  /// The countries offered, as codes, in the order to show (by name).
  final List<String> codes;

  /// Entries before the countries (value, text), for example "Where the session was recorded".
  final List<(String, String)> extra;

  /// How a country is shown in the list (its name by default).
  final String Function(String code) labelOf;
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
    this.labelOf = countryName,
    this.helperText,
  });

  @override
  State<CountryField> createState() => _CountryFieldState();
}

class _CountryFieldState extends State<CountryField> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  String? get _chosenText {
    final v = widget.value;
    if (v == null) return null;
    for (final (ev, t) in widget.extra) {
      if (ev == v) return t;
    }
    return widget.codes.contains(v) ? widget.labelOf(v) : null;
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) {
        _text.clear();
      } else if (_text.text != (_chosenText ?? '')) {
        // Left without choosing: show the choice again (a choice rebuilds the field anyway).
        _text.text = _chosenText ?? '';
      }
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final codes = w.codes, extra = w.extra, labelOf = w.labelOf, value = w.value, onChanged = w.onChanged;
    final search = {for (final c in codes) c: countrySearchText(c), for (final (v, t) in extra) v: t};
    return DropdownMenu<String>(
      // A new value (chosen elsewhere, or by the page) shows its text.
      key: ValueKey('country field $value ${onChanged == null}'),
      controller: _text,
      focusNode: _focus,
      initialSelection: value,
      enabled: onChanged != null,
      label: Text(w.label),
      helperText: w.helperText,
      expandedInsets: EdgeInsets.zero,
      menuHeight: 320,
      // Phones open the keyboard only on a tap when this is on; typing is the point here.
      requestFocusOnTap: true,
      enableFilter: true,
      filterCallback: (entries, filter) => [for (final e in entries) if (matchesSearch(search[e.value] ?? e.label, filter)) e],
      trailingIcon: const Icon(Icons.arrow_drop_down),
      dropdownMenuEntries: [
        for (final (v, t) in extra) DropdownMenuEntry(value: v, label: t),
        for (final c in codes) DropdownMenuEntry(value: c, label: labelOf(c)),
      ],
      onSelected: (v) {
        if (v != null) onChanged?.call(v);
      },
    );
  }
}
