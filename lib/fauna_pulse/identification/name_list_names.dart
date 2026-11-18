// FaunaPulse (round 378): the names of a name list as a list to read and search, for the page
// that shows which names a run chooses from (screens/name_list_names_screen.dart).
//
// The names come from the file's header only (LabelPack.readLabelsSync): the vectors of a
// BioCLIP list (100 MB and more in memory) are not read. Which rows are listed is not decided
// here: the caller passes the rows on offer (NameListChoice.rowBits, name_list_region.dart),
// so the page shows what a run uses.

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/list_search.dart';
import 'label_pack.dart';

/// One name as the page shows it.
class NameEntry {
  /// "Bombus terrestris"; for a row that stops above the species, its last name ("Apidae").
  final String name;

  /// Where the name belongs, and its common name when the list has one:
  /// "Apidae, Hymenoptera · Buff-tailed bumblebee", "Family of Hymenoptera".
  final String detail;

  /// What the search box looks in: [name] and [detail] through foldForSearch.
  final String search;

  const NameEntry(this.name, this.detail, this.search);
}

/// The names of a name list, read for the page.
class NameListNames {
  /// The names on offer, in alphabetical order.
  final List<NameEntry> names;

  /// The "none of these" entries (flower, leaf, shadow ...), in the order of the file. They
  /// are always on offer, whatever the choice of countries, orders and families.
  final List<String> noneOfThese;

  const NameListNames(this.names, this.noneOfThese);
}

/// [rows] as the page lists them: only the rows of [rowBits] (one bit per row, as
/// PackRegions.rowBits; null = every row), without the "none of these" rows, which come back
/// apart.
NameListNames nameEntriesOf(List<LabelRow> rows, {Uint8List? rowBits}) {
  final names = <NameEntry>[], none = <String>[];
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    if (row.isSink) {
      none.add(row.speciesName);
      continue;
    }
    if (rowBits != null && ((r >> 3) >= rowBits.length || !PackRegions.hasRow(rowBits, r))) continue;
    final name = row.speciesName;
    if (name.isEmpty) continue;
    // The row's own rank: the species, or the last rank it names.
    final own = row.ranks[6].isNotEmpty ? 6 : row.ranks.lastIndexWhere((n) => n.isNotEmpty);
    // The groups a reader knows a name by: its family and its order; for a family or
    // anything above it, the rank just above.
    final above = [
      for (final k in own > 4 ? const [4, 3] : [own - 1])
        if (k >= 0 && row.ranks[k].isNotEmpty) row.ranks[k],
    ].join(', ');
    final rank = '${kRankNames[own][0].toUpperCase()}${kRankNames[own].substring(1)}';
    final detail = [
      if (own == 6) above else if (above.isEmpty) rank else '$rank of $above',
      if (row.common.isNotEmpty) row.common,
    ].where((s) => s.isNotEmpty).join(' · ');
    names.add(NameEntry(name, detail, foldForSearch('$name\n$detail')));
  }
  names.sort((a, b) => a.search.compareTo(b.search));
  return NameListNames(names, none);
}

/// [nameEntriesOf] for the name list file [pack], in a helper isolate (the header of a list of
/// 35,000 names takes 0.1 s and more to decode). Throws a FormatException or a
/// FileSystemException when the file cannot be read.
Future<NameListNames> readNameListNames(File pack, {Uint8List? rowBits}) {
  final path = pack.path;
  return Isolate.run(() => nameEntriesOf(LabelPack.readLabelsSync(File(path)), rowBits: rowBits));
}
