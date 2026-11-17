// FaunaPulse (round 382, owner): one country chosen from a long list (about 250 countries), by
// typing its first letters or scrolling. Used by every single-country choice (the name list's
// country on Identify organisms, the user's country on "What do you want to watch?"); the
// window for several countries (multi_pick_dialog.dart) searches the same way.
//
// Built on Flutter's DropdownMenu: the field takes text, and the menu shows only the countries
// that match it (matchesSearch: no case, no accents, other names such as "Turkey" or "UK").
// The filter starts with the first typed letter, so a tap on the field still lists them all.

import 'package:flutter/material.dart';

import '../identification/country_names.dart';
import 'multi_pick_dialog.dart' show matchesSearch;

class CountryField extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final search = {for (final c in codes) c: countrySearchText(c), for (final (v, t) in extra) v: t};
    return DropdownMenu<String>(
      // A new value (chosen elsewhere, or by the page) shows its text.
      key: ValueKey('country field $value ${onChanged == null}'),
      initialSelection: value,
      enabled: onChanged != null,
      label: Text(label),
      helperText: helperText,
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
