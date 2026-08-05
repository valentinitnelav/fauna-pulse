// Tests for SessionLogIndex (round 163, perf review E5): the one streaming
// parse of session.jsonl that serves the summary screen's graphs, photos,
// ROI history and track spans. The fixtures cover every record shape the
// three old widget-side parsers understood — legacy per-track `detection`
// lines (≤ r68) AND batched `detections` (r69+), capture/motion/timelapse/
// gt_capture photo discovery, roi_update history, diagnostic series — plus
// crash-truncated lines and unknown record types (which must be ignored,
// per the "readers ignore unknown types" logging invariant).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/logging/session_log_index.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('log_index_test');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<String> writeLog(List<String> lines, {String name = 'a'}) async {
    final f = File('${tmp.path}/session_$name.jsonl');
    await f.writeAsString(lines.join('\n'));
    return f.path;
  }

  const start =
      '{"type":"start_of_session","time_ms":1000,'
      '"analysis_frame_width_px":1440,"analysis_frame_height_px":1080,'
      '"roi":{"width_px":416,"height_px":416,'
      '"frame_width_px":1440,"frame_height_px":1080}}';

  group('mixed-record fixture', () {
    late SessionLogIndex index;

    setUp(() async {
      final path = await writeLog([
        start,
        // r69+ batched frame record: track 1 triggered the photo, track 2
        // was co-detected in the same frame (must inherit the filename).
        '{"type":"detections","time_ms":2000,"frame_ms":2000,"tracks":['
            '{"track_id":1,"class_name":"bee","confidence":0.9,'
            '"box_in_roi":{"left":0.1,"top":0.2,"right":0.3,"bottom":0.4},'
            '"jpeg":"roi_a.jpg"},'
            '{"track_id":2,"class_name":"fly","confidence":0.8,'
            '"box_in_roi":{"left":0.5,"top":0.5,"right":0.6,"bottom":0.6}}]}',
        '{"type":"detections","time_ms":2500,"frame_ms":2500,"tracks":['
            '{"track_id":1,"class_name":"bee","confidence":0.85,'
            '"box_in_roi":{"left":0.1,"top":0.2,"right":0.3,"bottom":0.4}}]}',
        // The capture record lands later and overrides the seeded time with
        // the exact trigger moment, and the size with the real saved side.
        '{"type":"capture","time_ms":2100,"file":"roi_a.jpg",'
            '"captured_at_ms":1995,"saved_px":1024}',
        // Legacy per-track record (sessions ≤ round 68).
        '{"type":"detection","time_ms":3000,"track_id":7,"class_name":"bee",'
            '"confidence":0.7,'
            '"box_in_roi":{"left":0.2,"top":0.2,"right":0.4,"bottom":0.4},'
            '"jpeg":"roi_b.jpg"}',
        // Diagnostics: thermal (with the pre-split legacy embedded fps),
        // dedicated fps (pipeline_fps preferred), power.
        '{"type":"thermal","time_ms":4000,"battery_temp_c":37.5,'
            '"thermal_headroom":0.6,"fps":4.5}',
        '{"type":"fps","time_ms":5000,"fps":9.0,"pipeline_fps":10.0,'
            '"inf_ms":55.0}',
        '{"type":"power","time_ms":6000,"battery_current_ua":500000,'
            '"battery_voltage_mv":3900,"charge_counter_uah":1200000,'
            '"power_w":1.95,"is_charging":false,"is_plugged":true}',
        // No-AI-mode photo discovery lines.
        '{"type":"motion_capture","time_ms":7000,"jpeg":"roi_m.jpg",'
            '"captured_at_ms":6990,"motion_score":0.02}',
        '{"type":"gt_capture","time_ms":8000,"jpeg":"ref_g.jpg",'
            '"captured_at_ms":7995,"saved_px":512}',
        // Settled ROI change (round 109+ shape, direct stream side).
        '{"type":"roi_update","time_ms":9000,'
            '"roi":{"width_px":800,"height_px":800,'
            '"frame_width_px":1440,"frame_height_px":1080},'
            '"roi_side_stream_px":800,"saves_px":800,"roi_source":"stream"}',
        // Photo after the ROI change carries the NEW carried-forward size.
        '{"type":"timelapse_capture","time_ms":9500,"jpeg":"roi_t.jpg",'
            '"captured_at_ms":9490,"burst":0}',
        // Unknown record types must be ignored (the r163 camera_sleep is a
        // convenient real example), as must blank and truncated lines.
        '{"type":"camera_sleep","time_ms":9600,"state":"parked",'
            '"reason":"between_bursts","next_burst_at_ms":99999}',
        '',
        '{"type":"detections","time_ms":99',
      ]);
      index = await SessionLogIndex.parseFile(path);
    });

    test('track spans from both record generations', () {
      expect(index.trackSpans[1], (2000, 2500));
      expect(index.trackSpans[2], (2000, 2000));
      expect(index.trackSpans[7], (3000, 3000));
      expect(index.trackSpans.length, 3);
    });

    test('diagnostic series (incl. legacy thermal-embedded fps)', () {
      expect(index.temps, [(4000, 37.5)]);
      expect(index.headroom, [(4000, 0.6)]);
      expect(index.fps, [(4000, 4.5), (5000, 10.0)]); // pipeline_fps preferred
      expect(index.infMs, [(5000, 55.0)]);
      expect(index.powerSamples.length, 1);
      final p = index.powerSamples.first;
      expect(p.ms, 6000);
      expect(p.currentUa, 500000);
      expect(p.voltageMv, 3900);
      expect(p.chargeUah, 1200000);
      expect(p.loggedW, 1.95);
      expect(p.isCharging, false);
      // Round 188: the plugged-but-not-charging flag (power-bank, battery
      // full) parses too; older logs without the key read as null.
      expect(p.isPlugged, true);
    });

    test('photo discovery in log order across all trigger kinds', () {
      expect(index.photoOrder, [
        'roi_a.jpg',
        'roi_b.jpg',
        'roi_m.jpg',
        'ref_g.jpg',
        'roi_t.jpg',
      ]);
      expect(index.referenceNames, {'ref_g.jpg'});
    });

    test('trigger vs co-detected boxes, ids and confidences', () {
      final a = index.photos['roi_a.jpg']!;
      expect(a.boxes.length, 2);
      expect(a.boxes[0].triggered, true);
      expect(a.boxes[0].trackId, 1);
      expect(a.boxes[0].className, 'bee');
      expect(a.boxes[1].triggered, false);
      expect(a.boxes[1].trackId, 2);
      expect(a.boxes[1].left, 0.5);
      expect(a.trackIds, [1, 2]);
      expect(a.trackConf, {1: 0.9, 2: 0.8});
    });

    test('capture record overrides seeded time and size', () {
      final a = index.photos['roi_a.jpg']!;
      expect(a.captureMs, 1995); // captured_at_ms, not the seeded 2000
      expect(a.resW, 1024); // saved_px, not the ROI-geometry 416
      expect(a.resH, 1024);
    });

    test('photos without a capture record keep the carried-forward ROI size', () {
      final b = index.photos['roi_b.jpg']!;
      expect(b.captureMs, 3000);
      expect(b.resW, 416);
      final m = index.photos['roi_m.jpg']!;
      expect(m.captureMs, 6990); // trigger moment preferred over time_ms
      expect(m.resW, 416);
      // After the roi_update the carried-forward size is the new one.
      final t = index.photos['roi_t.jpg']!;
      expect(t.resW, 800);
    });

    test('reference photo: marked, exact saved side, no boxes', () {
      final g = index.photos['ref_g.jpg']!;
      expect(g.isReference, true);
      expect(g.resW, 512);
      expect(g.boxes, isEmpty);
    });

    test('ROI history entry (direct round-109+ stream side)', () {
      expect(index.roiHistory, [
        (timeMs: 9000, sidePx: 800, savesPx: 800, source: 'stream'),
      ]);
    });

    test('start record captured for derived values', () {
      expect(index.startRecord?['analysis_frame_width_px'], 1440);
    });
  });

  test('pre-109 roi_update: stream side recomputed from the roi block', () async {
    final path = await writeLog([
      start,
      // No roi_side_stream_px — must be re-projected against the start
      // record's analysis frame (416/1440 of 1440 → snapped 416).
      '{"type":"roi_update","time_ms":5000,'
          '"roi":{"width_px":416,"height_px":416,'
          '"frame_width_px":1440,"frame_height_px":1080}}',
    ], name: 'legacyroi');
    final index = await SessionLogIndex.parseFile(path);
    expect(index.roiHistory.single.sidePx, 416);
    expect(index.roiHistory.single.savesPx, null);
  });

  group('pass 2: high-res box time-matching', () {
    test('interpolates between the bracketing frames', () async {
      final path = await writeLog([
        start,
        '{"type":"detections","time_ms":10000,"frame_ms":10000,"tracks":['
            '{"track_id":5,"class_name":"bee","confidence":0.9,'
            '"box_in_roi":{"left":0.1,"top":0.1,"right":0.2,"bottom":0.2},'
            '"jpeg":"roi_hr.jpg"}]}',
        '{"type":"capture","time_ms":10500,"file":"roi_hr.jpg",'
            '"captured_at_ms":10050,"saved_px":1024,"content_at_ms":10400,'
            '"content_lag_ms":350}',
        '{"type":"detections","time_ms":11000,"frame_ms":11000,"tracks":['
            '{"track_id":5,"class_name":"bee","confidence":0.8,'
            '"box_in_roi":{"left":0.5,"top":0.1,"right":0.6,"bottom":0.2}}]}',
      ], name: 'bracket');
      final index = await SessionLogIndex.parseFile(path);
      final p = index.photos['roi_hr.jpg']!;
      expect(p.contentAtMs, 10400);
      expect(p.contentAtApprox, false);
      final still = p.stillMatch;
      expect(still, isNotNull);
      expect(still!.boxes.single.interpolated, true);
      // Weight 0.4 between left 0.1 (at −400 ms) and 0.5 (at +600 ms).
      expect(still.boxes.single.left, closeTo(0.26, 1e-9));
      // Nearest frame 400 ms away; single 1000 ms interval → tolerance
      // max(250, 1.5×1000) = 1500 → within.
      expect(p.stillWithinTol, true);
      expect(p.stillMatchNote, null);
    });

    test('no frame near the content moment → explanatory note', () async {
      final path = await writeLog([
        start,
        '{"type":"detections","time_ms":10000,"frame_ms":10000,"tracks":['
            '{"track_id":5,"class_name":"bee","confidence":0.9,'
            '"box_in_roi":{"left":0.1,"top":0.1,"right":0.2,"bottom":0.2},'
            '"jpeg":"roi_far.jpg"}]}',
        // Content moment 40 s after the only frames — outside the ±1.5 s
        // bracket window.
        '{"type":"capture","time_ms":50000,"file":"roi_far.jpg",'
            '"captured_at_ms":10050,"saved_px":1024,"content_at_ms":50000}',
      ], name: 'far');
      final index = await SessionLogIndex.parseFile(path);
      final p = index.photos['roi_far.jpg']!;
      expect(p.stillMatch, null);
      expect(p.stillMatchNote, contains('no detector frame within'));
    });

    test('an ROI move between trigger and content rejects the match', () async {
      final path = await writeLog([
        start,
        '{"type":"detections","time_ms":10000,"frame_ms":10000,"tracks":['
            '{"track_id":5,"class_name":"bee","confidence":0.9,'
            '"box_in_roi":{"left":0.1,"top":0.1,"right":0.2,"bottom":0.2},'
            '"jpeg":"roi_mv.jpg"}]}',
        '{"type":"roi_update","time_ms":10100,'
            '"roi":{"width_px":800,"height_px":800,'
            '"frame_width_px":1440,"frame_height_px":1080},'
            '"roi_side_stream_px":800}',
        '{"type":"capture","time_ms":10500,"file":"roi_mv.jpg",'
            '"captured_at_ms":10050,"saved_px":1024,"content_at_ms":10400}',
        '{"type":"detections","time_ms":10450,"frame_ms":10450,"tracks":['
            '{"track_id":5,"class_name":"bee","confidence":0.8,'
            '"box_in_roi":{"left":0.5,"top":0.1,"right":0.6,"bottom":0.2}}]}',
      ], name: 'roimove');
      final index = await SessionLogIndex.parseFile(path);
      final p = index.photos['roi_mv.jpg']!;
      expect(p.stillMatch, null);
      expect(p.stillMatchNote, contains('ROI was moved'));
    });
  });

  test('build() produces the same result through the worker isolate', () async {
    final path = await writeLog([
      start,
      '{"type":"detections","time_ms":2000,"frame_ms":2000,"tracks":['
          '{"track_id":1,"class_name":"bee","confidence":0.9,'
          '"box_in_roi":{"left":0.1,"top":0.2,"right":0.3,"bottom":0.4},'
          '"jpeg":"roi_a.jpg"}]}',
      '{"type":"fps","time_ms":5000,"pipeline_fps":10.0}',
    ], name: 'isolate');
    final index = await SessionLogIndex.build(File(path));
    expect(index.trackSpans[1], (2000, 2000));
    expect(index.fps, [(5000, 10.0)]);
    expect(index.photoOrder, ['roi_a.jpg']);
    expect(index.photos['roi_a.jpg']!.boxes.single.triggered, true);
  });

  test('100k-line session parses completely (streaming, bounded state)', () async {
    final f = File('${tmp.path}/session_big.jsonl');
    final sink = f.openWrite();
    sink.writeln(start);
    // ~90k batched detections records (2 tracks each, 100 distinct ids) +
    // ~10k diagnostic records — the shape of a long, busy field session.
    for (var i = 0; i < 90000; i++) {
      final t = 10000 + i * 100;
      final id1 = i % 100, id2 = 100; // id 100 spans the whole session
      sink.writeln(
        '{"type":"detections","time_ms":$t,"frame_ms":$t,"tracks":['
        '{"track_id":$id1,"class_name":"bee","confidence":0.9,'
        '"box_in_roi":{"left":0.1,"top":0.2,"right":0.3,"bottom":0.4}},'
        '{"track_id":$id2,"class_name":"fly","confidence":0.8,'
        '"box_in_roi":{"left":0.5,"top":0.5,"right":0.6,"bottom":0.6}}]}',
      );
      if (i % 9 == 0) {
        sink.writeln(
          '{"type":"fps","time_ms":$t,"pipeline_fps":10.0,"inf_ms":50.0}',
        );
      }
    }
    // Crash truncation at the very end.
    sink.write('{"type":"detections","time_ms":999');
    await sink.close();

    final index = await SessionLogIndex.parseFile(f.path);
    expect(index.trackSpans.length, 101);
    expect(index.trackSpans[100], (10000, 10000 + 89999 * 100));
    expect(index.fps.length, 10000);
    // No photo names were ever logged: the photo maps stay empty — the
    // index's memory is bounded by photos/series, never by frame count.
    expect(index.photoOrder, isEmpty);
  });
}
