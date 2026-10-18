// Round 317: the screen-off cover can also be turned on in Preview, so its
// hint must say whether a recording runs (a user who believes the phone
// records could leave it in the field and get no data).

import 'package:fauna_pulse/fauna_pulse/screens/camera_session_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('screen-off hint says a recording continues only while recording', () {
    expect(
      blackoutHintText(recording: true),
      'Screen off to save power\nRecording continues (tap anywhere to wake)',
    );
    final preview = blackoutHintText(recording: false);
    expect(preview, contains('Not recording'));
    expect(preview, isNot(contains('Recording continues')));
  });

  test('screen-off hint has no em dash', () {
    for (final recording in [true, false]) {
      expect(blackoutHintText(recording: recording), isNot(contains('—')));
    }
  });
}
