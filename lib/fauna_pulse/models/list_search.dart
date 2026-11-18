// FaunaPulse (round 382, ordered since round 387): the one search rule of the search boxes over
// a list (the country box `CountryField`, the window to tick countries or orders and families,
// the "Names to choose from" page), so typing finds the same entries in the same order
// everywhere.
//
// Every entry that holds the typed letters is shown, ignoring upper and lower case and accents
// ("turk" finds "Türkiye", "cote" finds "Côte d'Ivoire"). Best matches come first: an entry that
// starts with the letters, then one with a later word that starts with them, then the rest, each
// group in the list's own order. Before round 387 the list stayed alphabetical, so "Ger" showed
// Algeria above Germany, and the keyboard's Done key (which picks the first entry) picked
// Algeria. Most autocomplete boxes match only the start of a word, because a match inside a
// word rarely is what was meant (Baymard Institute's autocomplete research); the entries that
// match inside a word stay at the end so that "bee" still finds "bumblebee". The other
// lists with a search box keep their own order on purpose: the session list is sorted as the
// user chose.

/// [s] in lower case without accents, as [searchRank] compares it. Fold the texts of a long list
/// once, not at every key press.
String foldForSearch(String s) => s.toLowerCase().split('').map((c) => _plainLetters[c] ?? c).join();

const _plainLetters = {'å': 'a', 'á': 'a', 'à': 'a', 'ä': 'a', 'ç': 'c', 'é': 'e', 'è': 'e', 'ë': 'e', 'í': 'i',
    'ô': 'o', 'ó': 'o', 'ö': 'o', 'ü': 'u', 'ú': 'u', 'ñ': 'n', '’': "'"};

/// The characters that end a word ("Côte d'Ivoire", "Guinea-Bissau", "Korea (South)", a name
/// list's "name\ndetail").
const _wordBreaks = " \n-(),./'";

/// How well the folded [query] matches the folded [text]: 0 = [text] starts with it, 1 = a later
/// word does, 2 = it is inside a word; null = not in [text].
int? searchRank(String text, String query) {
  var i = text.indexOf(query);
  if (i <= 0) return i == 0 ? 0 : null;
  for (; i > 0; i = text.indexOf(query, i + 1)) {
    if (_wordBreaks.contains(text[i - 1])) return 1;
  }
  return 2;
}

/// The entries of [items] that hold [query] (as typed), best matches first ([searchRank]), each
/// group in the order of [items]. [foldedTextOf] gives an entry's text through [foldForSearch].
List<T> searchList<T>(List<T> items, String query, String Function(T item) foldedTextOf) {
  final q = foldForSearch(query.trim());
  if (q.isEmpty) return items;
  final groups = [<T>[], <T>[], <T>[]];
  for (final item in items) {
    final rank = searchRank(foldedTextOf(item), q);
    if (rank != null) groups[rank].add(item);
  }
  return [for (final g in groups) ...g];
}
