// FaunaPulse (round 307): the time bar under every video player in the app,
// the session's Video tab and the square editor of "Find animals in videos".
//
// One bar is both the slider and a map of the clip: grey where nothing was
// found, coloured stretches where at least one track ID (in "All boxes": at
// least one box) is in the video, and small white marks at the frames kept
// for a track ID. A clip can have hundreds of track IDs, so they all share
// one colour: the bar shows where they are and roughly how much of the clip
// they cover, which tells where to drag. A white line with a round knob
// marks the position. A tap jumps there; a drag moves the video with the
// finger (paused while dragging, playing again after if it played).

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class VideoTimelineBar extends StatefulWidget {
  /// The clip's player: its length, and paused while dragging.
  final VideoPlayerController controller;

  /// The position the marker shows (ms): a value that tells the bar when it
  /// changes (a notifier), so the marker moves without rebuilding the screen
  /// around it.
  final ValueListenable<int> positionMs;

  /// Moves the video to a position (ms).
  final ValueChanged<int> onSeek;

  /// Stretches (start, end in ms) drawn in [spanColor].
  final List<(int, int)> spans;
  final Color spanColor;

  /// Kept frames (ms), drawn as small white marks.
  final List<int> keptMs;

  const VideoTimelineBar({
    super.key,
    required this.controller,
    required this.positionMs,
    required this.onSeek,
    this.spans = const [],
    this.spanColor = Colors.white,
    this.keptMs = const [],
  });

  @override
  State<VideoTimelineBar> createState() => _VideoTimelineBarState();
}

class _VideoTimelineBarState extends State<VideoTimelineBar> {
  /// The finger's position while dragging (ms), null otherwise: the marker
  /// follows the finger, not the player's slower answers.
  final _dragMs = ValueNotifier<int?>(null);
  int? _sentMs;
  Timer? _throttle;
  bool _resume = false;

  int _msAt(double dx) =>
      ((dx / context.size!.width).clamp(0.0, 1.0) * widget.controller.value.duration.inMilliseconds).round();

  void _dragStart(DragStartDetails d) {
    _resume = widget.controller.value.isPlaying;
    if (_resume) widget.controller.pause();
    _sentMs = null;
    _drag(d.localPosition.dx);
  }

  void _drag(double dx) {
    _dragMs.value = _msAt(dx);
    if (!(_throttle?.isActive ?? false)) _send();
  }

  /// At most one jump every 150 ms while dragging: each one makes the phone
  /// decode a new picture, and a flood of them would only delay the last.
  void _send() {
    final ms = _dragMs.value;
    if (ms == null || ms == _sentMs) return;
    _sentMs = ms;
    widget.onSeek(ms);
    _throttle = Timer(const Duration(milliseconds: 150), _send);
  }

  void _dragEnd() {
    if (_dragMs.value == null) return;
    _send(); // where the finger left the bar
    _throttle?.cancel();
    _dragMs.value = null;
    if (_resume) widget.controller.play();
  }

  @override
  void dispose() {
    _throttle?.cancel();
    _dragMs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Horizontal drags here move the video, not the summary's tabs.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => widget.onSeek(_msAt(d.localPosition.dx)),
      onHorizontalDragStart: _dragStart,
      onHorizontalDragUpdate: (d) => _drag(d.localPosition.dx),
      onHorizontalDragEnd: (_) => _dragEnd(),
      onHorizontalDragCancel: _dragEnd,
      // Repainted every frame while playing: its own layer keeps the rest of
      // the screen from being painted again with it.
      child: RepaintBoundary(
        child: SizedBox(
          height: 36, // the touch area; the bar itself is 10 px
          width: double.infinity,
          child: CustomPaint(
            painter: _BarPainter(
              position: widget.positionMs,
              drag: _dragMs,
              durationMs: widget.controller.value.duration.inMilliseconds,
              spans: widget.spans,
              spanColor: widget.spanColor,
              keptMs: widget.keptMs,
            ),
          ),
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  final ValueListenable<int> position;
  final ValueListenable<int?> drag;
  final int durationMs;
  final List<(int, int)> spans;
  final Color spanColor;
  final List<int> keptMs;

  _BarPainter({
    required this.position,
    required this.drag,
    required this.durationMs,
    required this.spans,
    required this.spanColor,
    required this.keptMs,
  }) : super(repaint: Listenable.merge([position, drag]));

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    double x(int ms) => durationMs <= 0 ? 0 : (ms / durationMs * w).clamp(0.0, w);
    final bar = Rect.fromLTWH(0, size.height / 2 - 5, w, 10);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(bar, const Radius.circular(5)));
    canvas.drawRect(bar, Paint()..color = Colors.white24);
    final white = Paint()..color = Colors.white;
    if (durationMs > 0) {
      final fill = Paint()..color = spanColor;
      for (final (start, end) in spans) {
        // At least 2 px, so a short one in a long clip still shows.
        final l = x(start);
        canvas.drawRect(Rect.fromLTRB(l, bar.top, max(x(end), l + 2), bar.bottom), fill);
      }
      // Shorter than the bar, so they read as marks, not as a third colour.
      for (final ms in keptMs) {
        canvas.drawRect(Rect.fromLTWH(min(x(ms), w - 2), bar.top + 2, 2, bar.height - 4), white);
      }
    }
    canvas.restore();
    // The position: a line across the bar with a knob above it.
    final at = x(drag.value ?? position.value);
    canvas.drawRect(Rect.fromLTRB(at - 1, bar.top - 6, at + 1, bar.bottom + 6), white);
    canvas.drawCircle(Offset(at, bar.top - 6), 5, white);
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) =>
      old.position != position ||
      old.drag != drag ||
      old.durationMs != durationMs ||
      old.spans != spans ||
      old.spanColor != spanColor ||
      old.keptMs != keptMs;
}
