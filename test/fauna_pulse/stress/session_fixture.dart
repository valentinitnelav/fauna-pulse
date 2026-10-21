// A valid session.jsonl written with the real SessionLogger, shared by the
// fuzz tests of this folder. Not a test itself.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/session_logger.dart';

/// Writes a session of ~25 records of every shape the log index reads and
/// returns the file. Times are fixed so the file is the same on every run.
Future<File> writeValidSession(Directory dir, {int startMs = 1700000000000, bool ended = true}) async {
  dir.createSync(recursive: true);
  final file = File('${dir.path}/session.jsonl');
  final log = SessionLogger(file)..open();
  DateTime at(int plus) => DateTime.fromMillisecondsSinceEpoch(startMs + plus);
  log.logStart({
    'session_id': 'fuzz',
    'analysis_frame_width_px': 1440,
    'analysis_frame_height_px': 1080,
    'roi': {'width_px': 416, 'height_px': 416, 'frame_width_px': 1440, 'frame_height_px': 1080},
    'config': {'captureTrigger': 'detector'},
  }, at: at(0));
  log.logRoiUpdate({
    'roi': {'width_px': 448, 'height_px': 448},
    'roi_side_stream_px': 448,
    'saves_px': 1024,
    'roi_source': 'user',
  }, at: at(500));
  for (var i = 0; i < 8; i++) {
    log.logDetections(
      [
        {
          'track_id': 1 + i % 3,
          'class_name': 'bee',
          'confidence': 0.8,
          'box_in_roi': {'left': 0.1, 'top': 0.2, 'right': 0.3, 'bottom': 0.4},
          if (i % 4 == 0) 'jpeg': 'roi_$i.jpg',
        },
        {
          'track_id': 9,
          'class_name': 'fly',
          'confidence': 0.7,
          'box_in_roi': {'left': 0.5, 'top': 0.5, 'right': 0.6, 'bottom': 0.6},
        },
      ],
      frameMs: startMs + 1000 + i * 200,
      frameSensorMs: startMs + 990 + i * 200,
      at: at(1000 + i * 200),
    );
  }
  log.logTrackEvent({'event': 'created', 'track_id': 1, 'first_seen_ms': startMs + 900, 'hits': 3, 'frame_ms': startMs + 1000}, at: at(1000));
  log.logCapture({'file': 'roi_0.jpg', 'captured_at_ms': startMs + 1000, 'saved_px': 1024, 'content_lag_ms': 40.0, 'live_jpeg': 'live_0.jpg', 'live_saved_px': 416, 'live_lag_ms': 12}, at: at(1100));
  log.logCapture({'file': 'roi_4.jpg', 'captured_at_ms': startMs + 1800, 'content_at_ms': startMs + 1790, 'saved_w': 800, 'saved_h': 600, 'clip': 'c.mp4', 'pts_us': 123000}, at: at(1900));
  log.logMotionCapture({'jpeg': 'motion_1.jpg', 'captured_at_ms': startMs + 2000}, at: at(2000));
  log.logTimeLapseCapture({'jpeg': 'tl_1.jpg', 'captured_at_ms': startMs + 2100}, at: at(2100));
  log.logGtCapture({'jpeg': 'gt_1.jpg', 'captured_at_ms': startMs + 2200, 'saved_px': 2048}, at: at(2200));
  log.logThermal({'battery_temp_c': 31.5, 'thermal_headroom': 0.4, 'fps': 9.0}, at: at(2300));
  log.logFps({'pipeline_fps': 8.5, 'inf_ms': 42.0}, at: at(2400));
  log.logPower({
    'battery_current_ua': -500000,
    'battery_voltage_mv': 4100,
    'charge_counter_uah': 3000000,
    'power_w': 2.1,
    'is_charging': true,
    'is_plugged': true,
  }, at: at(2500));
  log.logVideoClip({'file': 'videos/c.mp4', 'start_epoch_ms': startMs + 800, 'duration_ms': 4000, 'start_time_source': 'file_time'}, at: at(2600));
  log.logAppError({'message': 'x'}, at: at(2700));
  if (ended) log.logEnd({'ended_normally': true}, at: at(3000));
  await log.close();
  return file;
}
