// FaunaPulse (round 328): one cell of the app's CSV exports (track IDs, identification
// tracks and crops, phone readings during video analysis).
//
// Class and species names come from model files and name lists that users import, and clip
// names from imported videos, so they are text that someone else chose. A spreadsheet (Excel,
// LibreOffice) runs a cell that starts with = + - or @ as a formula, also after spaces, tabs or
// line breaks and in their full-width forms (＝ ＋ － ＠), and a formula can for example open a
// web link that carries the values of other cells. Such text cells get a leading apostrophe,
// which spreadsheets show as plain text. R, pandas and other CSV readers keep the apostrophe as
// part of the text; real names never start with these characters. Cells with a ";" or a tab
// are quoted too: a spreadsheet that splits on them (German Excel uses ";") would otherwise
// start a new cell there, which could begin with "=".

final _plainNumber = RegExp(r'^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$');
const _formulaStarts = '=+-@＝＋－＠';

/// [v] as one CSV cell: quoted when it holds a comma, semicolon, tab, quote or line break; a
/// text that a spreadsheet would run as a formula starts with an apostrophe. Numbers (also as
/// formatted text such as "-0.25") stay as they are.
String csvCell(Object? v) {
  var s = v == null ? '' : '$v';
  final head = s.trimLeft();
  if (v is! num && head.isNotEmpty && _formulaStarts.contains(head[0]) && !_plainNumber.hasMatch(s)) {
    s = "'$s";
  }
  if (s.contains(RegExp('[,;\t"\n\r]'))) return '"${s.replaceAll('"', '""')}"';
  return s;
}
