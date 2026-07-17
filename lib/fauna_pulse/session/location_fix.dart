// FaunaPulse — one GPS fix per session (round 126).
//
// The phone is fixed (tripod) during a session, so the app takes ONE stable
// location read at session setup instead of tracking continuously (battery).
// The fix lands in the start_of_session record as `location` and is stamped
// into user-exported crops' EXIF (crop_export.dart) so identification apps
// (ObsIdentify, iNaturalist) read where-and-when directly from the file.
//
// Android facts that shaped this design: an app cannot switch the system GPS
// on or off — stopping our OWN subscription is what saves the battery. The
// GPS receiver works in flight mode, but assisted-GPS data can't download
// there, so a cold fix can take minutes: get the fix first, then enable
// flight mode (documented for the user in FIELD_GUIDE.md).

import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../logging/app_error_hooks.dart';

/// A session's single location: where the phone stood, with the fix accuracy
/// and where the value came from — `gps` (measured this session), `manual`
/// (typed by the user), or `previous` (re-used from an earlier session,
/// confirmed with a tap).
class SessionLocation {
  final double latitude;
  final double longitude;

  /// Radius of the fix's 68%-confidence circle in meters (null for manual
  /// entries — the user's number carries no measured error).
  final double? accuracyM;
  final int fixTimeMs;
  final String source; // 'gps' | 'manual' | 'previous'

  const SessionLocation({
    required this.latitude,
    required this.longitude,
    required this.fixTimeMs,
    required this.source,
    this.accuracyM,
  });

  SessionLocation withSource(String s) => SessionLocation(
    latitude: latitude,
    longitude: longitude,
    fixTimeMs: fixTimeMs,
    source: s,
    accuracyM: accuracyM,
  );

  /// Decimal degrees, 5 places ≈ 1 m — enough to relocate a flower patch.
  String get label =>
      '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}'
      '${accuracyM != null ? '  ±${accuracyM!.round()} m' : ''}';

  Map<String, dynamic> toJson() => {
    'lat': latitude,
    'lon': longitude,
    if (accuracyM != null) 'accuracy_m': accuracyM,
    'fix_time_ms': fixTimeMs,
    'source': source,
  };

  static SessionLocation? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final lat = (j['lat'] as num?)?.toDouble();
    final lon = (j['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    return SessionLocation(
      latitude: lat,
      longitude: lon,
      accuracyM: (j['accuracy_m'] as num?)?.toDouble(),
      fixTimeMs: (j['fix_time_ms'] as num?)?.toInt() ?? 0,
      source: (j['source'] as String?) ?? 'gps',
    );
  }
}

/// Pure stability logic for the one-shot acquisition, unit-testable without
/// the geolocator plugin: feed position updates, it keeps the most accurate
/// one and says when to stop — accuracy at or under [stableAccuracyM], or
/// [maxWaitMs] elapsed with at least one fix (a canyon/forest never reaches
/// 15 m; a merely-okay fix beats waiting forever).
class LocationFixTracker {
  LocationFixTracker({
    required this.startMs,
    this.stableAccuracyM = 15,
    this.maxWaitMs = 60000,
  });

  final int startMs;
  final double stableAccuracyM;
  final int maxWaitMs;

  SessionLocation? best;

  /// Returns true when acquisition should stop (stable enough / waited long
  /// enough).
  bool addFix(double lat, double lon, double? accuracyM, int timeMs) {
    final double effective = accuracyM ?? double.infinity;
    final double bestAcc = best?.accuracyM ?? double.infinity;
    if (best == null || effective < bestAcc) {
      best = SessionLocation(
        latitude: lat,
        longitude: lon,
        accuracyM: accuracyM,
        fixTimeMs: timeMs,
        source: 'gps',
      );
    }
    return isDone(timeMs);
  }

  bool isDone(int nowMs) {
    if (best == null) return false;
    final double bestAcc = best!.accuracyM ?? double.infinity;
    return bestAcc <= stableAccuracyM || nowMs - startMs >= maxWaitMs;
  }
}

/// Runs the one-shot acquisition against the real GPS. [onUpdate] fires with
/// the best fix so far and whether the search is still running; the camera
/// screen mirrors that into its pin button and the location dialog.
class SessionLocator {
  SessionLocator({required this.onUpdate});

  final void Function(SessionLocation? best, bool searching) onUpdate;

  StreamSubscription<Position>? _sub;
  Timer? _timeout;
  LocationFixTracker? _tracker;

  bool get searching => _sub != null;

  /// Starts acquiring. With [requestPermission] false (the silent screen-open
  /// auto-start) it proceeds only when permission was granted before — the
  /// user is never surprised by a prompt; the dialog's "Search" button passes
  /// true. Returns false when the location service is off or permission is
  /// missing/denied.
  Future<bool> start({bool requestPermission = false}) async {
    if (_sub != null) return true;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied && requestPermission) {
        p = await Geolocator.requestPermission();
      }
      if (p != LocationPermission.whileInUse &&
          p != LocationPermission.always) {
        return false;
      }
      final tracker = LocationFixTracker(
        startMs: DateTime.now().millisecondsSinceEpoch,
      );
      _tracker = tracker;
      _sub =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.best,
            ),
          ).listen(
            (pos) {
              final now = DateTime.now().millisecondsSinceEpoch;
              final done = tracker.addFix(
                pos.latitude,
                pos.longitude,
                pos.accuracy.isFinite && pos.accuracy > 0 ? pos.accuracy : null,
                now,
              );
              if (done) {
                stop();
              }
              onUpdate(tracker.best, !done);
            },
            onError: (Object e) {
              logSwallowed('gps_stream', e);
              stop();
              onUpdate(tracker.best, false);
            },
          );
      // Backstop: even with NO fix at all (indoors), stop searching after the
      // tracker's window + slack so the subscription can never linger.
      _timeout = Timer(Duration(milliseconds: tracker.maxWaitMs + 5000), () {
        stop();
        onUpdate(_tracker?.best, false);
      });
      onUpdate(tracker.best, true);
      return true;
    } catch (e) {
      logSwallowed('gps_start', e);
      stop();
      return false;
    }
  }

  /// Cancels the subscription — the app's entire GPS load ends here.
  void stop() {
    _sub?.cancel();
    _sub = null;
    _timeout?.cancel();
    _timeout = null;
  }
}
