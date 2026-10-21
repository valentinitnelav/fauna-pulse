// Round 319 part 3, "Identify organisms" > Last run (completeness check after the phone checks):
// with no identified rank (all crops unreadable, or every track ID unidentified) the track ID
// line read "0 track IDs: ." or "3 track IDs: , 3 unidentified.".

import 'package:fauna_pulse/fauna_pulse/screens/identification_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no track IDs: no colon, no empty list', () {
    expect(
      trackSummaryLine({'tracks_total': 0, 'by_identified_rank': <String, int>{}, 'unidentified': 0, 'no_organism': 0}),
      '0 track IDs.',
    );
  });

  test('only unidentified track IDs: no leading comma', () {
    expect(
      trackSummaryLine({'tracks_total': 3, 'by_identified_rank': <String, int>{}, 'unidentified': 3, 'no_organism': 0}),
      '3 track IDs: 3 unidentified.',
    );
  });

  test('ranks, unidentified and no organism keep their order', () {
    expect(
      trackSummaryLine({
        'tracks_total': 6,
        'by_identified_rank': {'species': 2, 'family': 1},
        'unidentified': 2,
        'no_organism': 1,
      }),
      '6 track IDs: 2 to species, 1 to family, 2 unidentified, 1 no organism.',
    );
  });

  test('one track ID and an older summary without no_organism', () {
    expect(
      trackSummaryLine({'tracks_total': 1, 'by_identified_rank': {'species': 1}, 'unidentified': 0}),
      '1 track ID: 1 to species.',
    );
  });
}
