// Tests for the C-BIoU-style tracker (round 105): stable ids, the buffered
// matching that is its whole point (holding an id across a jump plain IoU
// would lose), and the visit semantics it must share with ByteTrack.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/c_biou_track.dart';

Detection det(Rect box, [double conf = 0.9]) =>
    Detection(box: box, confidence: conf, classIndex: 0, className: 'bee');

void main() {
  test('a single moving object keeps one stable id', () {
    final tracker = CBiouTracker(
      params: const CBiouParams(minHitsToConfirm: 3),
    );
    int? id;
    for (var f = 0; f < 6; f++) {
      final box = Rect.fromLTWH(0.40 + f * 0.01, 0.40, 0.10, 0.10);
      final tracks = tracker.update([det(box)], f * 100);
      if (f >= 2) {
        expect(tracks, hasLength(1));
        id ??= tracks.first.id;
        expect(tracks.first.id, id);
      }
    }
  });

  test('two separated objects get distinct ids', () {
    final tracker = CBiouTracker(
      params: const CBiouParams(minHitsToConfirm: 2),
    );
    List<Track> tracks = const [];
    for (var f = 0; f < 4; f++) {
      tracks = tracker.update([
        det(const Rect.fromLTWH(0.10, 0.10, 0.10, 0.10)),
        det(const Rect.fromLTWH(0.70, 0.70, 0.10, 0.10)),
      ], f * 100);
    }
    expect(tracks, hasLength(2));
    expect(tracks.map((t) => t.id).toSet(), hasLength(2));
  });

  test('bufferedRect enlarges by the scale on each side', () {
    const r = Rect.fromLTWH(0.40, 0.40, 0.10, 0.10);
    final b = bufferedRect(r, 0.5);
    expect(b.left, closeTo(0.35, 1e-9));
    expect(b.top, closeTo(0.35, 1e-9));
    expect(b.width, closeTo(0.20, 1e-9));
    expect(b.height, closeTo(0.20, 1e-9));
  });

  test('biou > 0 for disjoint boxes whose buffered versions overlap', () {
    // Two 0.1 boxes with a 0.05 gap: plain IoU 0, buffered (0.3) IoU > 0.
    const a = Rect.fromLTWH(0.30, 0.40, 0.10, 0.10);
    const b = Rect.fromLTWH(0.45, 0.40, 0.10, 0.10);
    expect(biou(a, b, 0.0), 0.0);
    expect(biou(a, b, 0.3), greaterThan(0.0));
  });

  group('buffered matching holds an id across a jump plain IoU loses', () {
    // A small insect jumps its own width and a half between two frames: the
    // raw boxes do not overlap at all. This is THE scenario C-BIoU exists
    // for; it must keep one id where an unbuffered matcher would mint a
    // second one.
    List<Track> afterJump({required double bufferScale}) {
      final t = CBiouTracker(
        params: CBiouParams(
          minHitsToConfirm: 2,
          bufferScale1: bufferScale,
          bufferScale2: bufferScale, // single-scale cascade isolates the knob
        ),
      );
      const box = Rect.fromLTWH(0.40, 0.40, 0.10, 0.10);
      t.update([det(box)], 0);
      t.update([det(box)], 100); // confirmed, velocity ~0
      // Jump by 0.15 (1.5× its own width): raw IoU is exactly 0.
      return t.update([det(const Rect.fromLTWH(0.55, 0.40, 0.10, 0.10))], 200);
    }

    test('a wide enough buffer keeps the id', () {
      final tracks = afterJump(bufferScale: 0.5);
      expect(tracks, hasLength(1));
      expect(tracks.single.id, 1);
    });
    test('a tiny buffer loses it (the knob has teeth)', () {
      final tracks = afterJump(bufferScale: 0.05);
      // The old id went "lost"; the new box is an unconfirmed tentative
      // track, so nothing confirmed is returned for it this frame.
      expect(tracks.where((t) => t.id == 1), isEmpty);
    });
  });

  test('the wider second pass catches what the strict first pass missed', () {
    final t = CBiouTracker(
      params: const CBiouParams(
        minHitsToConfirm: 2,
        bufferScale1: 0.05, // pass 1 alone loses the jump (test above)
        bufferScale2: 0.5,
      ),
    );
    const box = Rect.fromLTWH(0.40, 0.40, 0.10, 0.10);
    t.update([det(box)], 0);
    t.update([det(box)], 100);
    final tracks = t.update([
      det(const Rect.fromLTWH(0.55, 0.40, 0.10, 0.10)),
    ], 200);
    expect(tracks, hasLength(1));
    expect(tracks.single.id, 1);
  });

  test('id survives a brief occlusion (gap shorter than the buffer)', () {
    final tracker = CBiouTracker(
      params: const CBiouParams(minHitsToConfirm: 2, trackBuffer: 30),
    );
    const box = Rect.fromLTWH(0.45, 0.45, 0.10, 0.10);
    tracker.update([det(box)], 0);
    var tracks = tracker.update([det(box)], 100);
    final id = tracks.single.id;
    tracker.update(const [], 200);
    tracker.update(const [], 300);
    tracks = tracker.update([det(box)], 400);
    expect(tracks, hasLength(1));
    expect(tracks.single.id, id);
  });

  test('expireLostTracks drops lost tracks so a newcomer gets a fresh id', () {
    final tracker = CBiouTracker(
      params: const CBiouParams(minHitsToConfirm: 2, trackBuffer: 30),
    );
    const box = Rect.fromLTWH(0.45, 0.45, 0.10, 0.10);
    tracker.update([det(box)], 0);
    var tracks = tracker.update([det(box)], 100);
    final id = tracks.single.id;
    tracker.update(const [], 200); // goes "lost"
    tracker.expireLostTracks();
    tracker.update([det(box)], 10000);
    tracks = tracker.update([det(box)], 10100);
    expect(tracks, hasLength(1));
    expect(tracks.single.id, isNot(id));
  });

  group('high-score threshold decides whether a new id can start', () {
    // Same shared "faint band" rule as ByteTrack: a 0.4-confidence detection
    // can only spawn when the threshold is below 0.4.
    int confirmedFor({required double highThresh}) {
      final tracker = CBiouTracker(
        params: CBiouParams(minHitsToConfirm: 2, highThresh: highThresh),
      );
      const box = Rect.fromLTWH(0.45, 0.45, 0.10, 0.10);
      for (var f = 0; f < 4; f++) {
        tracker.update([det(box, 0.4)], f * 100);
      }
      return tracker.totalConfirmed;
    }

    test('threshold below the score lets a track start', () {
      expect(confirmedFor(highThresh: 0.3), 1);
    });
    test('threshold above the score blocks it', () {
      expect(confirmedFor(highThresh: 0.5), 0);
    });
  });

  test('a faint detection keeps an existing id alive but never spawns', () {
    final tracker = CBiouTracker(
      params: const CBiouParams(minHitsToConfirm: 2, highThresh: 0.5),
    );
    const box = Rect.fromLTWH(0.45, 0.45, 0.10, 0.10);
    tracker.update([det(box, 0.9)], 0);
    tracker.update([det(box, 0.9)], 100); // confirmed on strong boxes
    // Faint (0.3) detection at the same spot: matched, id kept.
    final tracks = tracker.update([det(box, 0.3)], 200);
    expect(tracks, hasLength(1));
    expect(tracker.totalConfirmed, 1);
  });

  test('setFrameBudgets applies the FPS-derived buffers', () {
    final tracker = CBiouTracker();
    tracker.setFrameBudgets(trackBuffer: 42, minHitsToConfirm: 7);
    expect(tracker.trackBuffer, 42);
    expect(tracker.minHitsToConfirm, 7);
    expect(tracker.effectiveParamsJson()['algorithm'], 'cbiou');
    expect(tracker.effectiveParamsJson()['trackBuffer'], 42);
  });

  test('a mis-ordered pass-2 scale never makes the cascade stricter', () {
    // bufferScale2 below bufferScale1 is a settings mistake; the tracker
    // clamps it up to pass 1, so the jump test still holds the id.
    final t = CBiouTracker(
      params: const CBiouParams(
        minHitsToConfirm: 2,
        bufferScale1: 0.5,
        bufferScale2: 0.05,
      ),
    );
    const box = Rect.fromLTWH(0.40, 0.40, 0.10, 0.10);
    t.update([det(box)], 0);
    t.update([det(box)], 100);
    final tracks = t.update([
      det(const Rect.fromLTWH(0.55, 0.40, 0.10, 0.10)),
    ], 200);
    expect(tracks, hasLength(1));
    expect(tracks.single.id, 1);
  });

  test('track lifecycle events match ByteTrack semantics (round 116): '
      'created → lost → recovered → removed', () {
    // Both trackers share the TrackEventBuffer mixin; this proves the C-BIoU
    // update loop calls it at the same transitions, so a `track_event` log
    // line means one thing regardless of the algorithm choice.
    final tracker = CBiouTracker(
      params: const CBiouParams(minHitsToConfirm: 2, trackBuffer: 2),
    );
    const box = Rect.fromLTWH(0.45, 0.45, 0.10, 0.10);

    tracker.update([det(box)], 0);
    tracker.update([det(box)], 100); // confirmed
    var events = tracker.drainEvents();
    expect(events.map((e) => e.kind), [TrackEventKind.created]);
    final id = events.single.trackId;

    tracker.update(const [], 200); // first unmatched frame
    events = tracker.drainEvents();
    expect(events.map((e) => e.kind), [TrackEventKind.lost]);

    tracker.update([det(box)], 300); // matched again, same id
    events = tracker.drainEvents();
    expect(events.map((e) => e.kind), [TrackEventKind.recovered]);
    expect(events.single.lastSeenMs, 100); // pre-gap observation
    expect(events.single.framesMissed, 1);

    tracker.update(const [], 400);
    tracker.update(const [], 500);
    tracker.update(const [], 600); // timeSinceUpdate 3 > buffer 2
    events = tracker.drainEvents();
    expect(events.first.kind, TrackEventKind.lost);
    expect(events.last.kind, TrackEventKind.removed);
    expect(events.last.trackId, id);
    expect(events.last.reason, 'aged_out');

    // Gate-expiry removals (see the ByteTrack test for the full contract).
    tracker.update([det(box)], 700);
    tracker.update([det(box)], 800);
    tracker.update(const [], 900);
    tracker.drainEvents();
    tracker.expireLostTracks();
    expect(tracker.drainEvents().single.reason, 'gate_expired');
  });
}
