// Tests for the best-effort failure trace (review B7): logSwallowed must
// route into the live session's app_error sink, rate-limit itself, and stay
// harmless when no session is recording or the sink itself throws.

import 'package:flutter_test/flutter_test.dart';
import 'package:pollinator_monitor/pollinator/logging/app_error_hooks.dart';

void main() {
  setUp(resetAppErrorRateLimitsForTest);
  tearDown(() => appErrorSink = null);

  test('routes the swallowed error into the app_error sink', () {
    final received = <Map<String, dynamic>>[];
    appErrorSink = received.add;

    logSwallowed('lens_probe', StateError('camera busy'));

    expect(received, hasLength(1));
    expect(received.single['source'], 'lens_probe');
    expect(received.single['message'], contains('camera busy'));
  });

  test('rate-limits: an immediately repeated failure is suppressed', () {
    final received = <Map<String, dynamic>>[];
    appErrorSink = received.add;

    logSwallowed('thermal_read', StateError('a'));
    logSwallowed('thermal_read', StateError('b'));

    // The forwarder writes at most one record every 2 s; the drop is counted
    // on the next record that gets through, so no test can see it here.
    expect(received, hasLength(1));
  });

  test('is a no-op without a session, and survives a throwing sink', () {
    appErrorSink = null;
    expect(() => logSwallowed('no_session', StateError('x')), returnsNormally);

    appErrorSink = (_) => throw StateError('sink broken');
    expect(() => logSwallowed('bad_sink', StateError('x')), returnsNormally);
  });
}
