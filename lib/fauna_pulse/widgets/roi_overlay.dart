// FaunaPulse — the draggable/zoomable square ROI box over the preview.
//
// Gestures (one widget handles both):
//   * Drag with one finger  → move the box.
//   * Pinch with two fingers → resize the box (spread = bigger, pinch = smaller).
// The box is square in the camera frame (see Roi) and is drawn through
// [PreviewTransform] so it looks square on screen. It is always kept inside the
// VISIBLE part of the preview, so it can't be pushed off the edge.
//
// For an exact size, the size chip on the preview opens a slider (handled by the
// parent screen); here we provide direct manipulation.

import 'package:flutter/material.dart';

import '../models/roi.dart';
import 'preview_transform.dart';

class RoiOverlay extends StatefulWidget {
  /// Current ROI.
  final Roi roi;

  /// Frame aspect ratio (imageWidth / imageHeight) needed to size the square.
  final double frameAspect;

  /// Whether the box can be moved/resized (disabled while screen is dimmed).
  final bool interactive;

  /// Called with the new ROI on every gesture tick.
  final ValueChanged<Roi> onChanged;

  /// Colour of the ROI border (e.g. red while recording).
  final Color borderColor;

  /// Border thickness (briefly thickened during the photo-capture flash).
  final double borderWidth;

  const RoiOverlay({
    super.key,
    required this.roi,
    required this.frameAspect,
    required this.onChanged,
    this.interactive = true,
    this.borderColor = const Color(0xFFFFEB3B),
    this.borderWidth = 2.5,
  });

  @override
  State<RoiOverlay> createState() => _RoiOverlayState();
}

class _RoiOverlayState extends State<RoiOverlay> {
  // ROI side at the moment a pinch began, so scale is applied from a fixed base.
  double _startSide = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final transform = PreviewTransform(
          widget: Size(constraints.maxWidth, constraints.maxHeight),
          frameAspect: widget.frameAspect,
        );
        final dispW = transform.displayedWidth;
        final dispH = transform.displayedHeight;
        final visible = transform.visibleNormalizedRect();
        final px = transform.rectToScreen(
          widget.roi.normalizedRect(widget.frameAspect),
        );

        void emit(Roi candidate) {
          // Keep the square inside the frame, then inside the visible preview.
          final clamped = candidate
              .copyClamped(
                centerX: candidate.centerX,
                centerY: candidate.centerY,
                sideFraction: candidate.sideFraction,
                frameAspect: widget.frameAspect,
              )
              .clampToVisible(visible, widget.frameAspect);
          widget.onChanged(clamped);
        }

        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onScaleStart: widget.interactive
                    ? (_) => _startSide = widget.roi.sideFraction
                    : null,
                onScaleUpdate: widget.interactive
                    ? (d) {
                        // Two-finger pinch resizes (scale != 1); any drag moves
                        // by the focal-point delta. Single-finger drag has
                        // scale == 1, so it only moves.
                        final newSide = _startSide * d.scale;
                        emit(
                          Roi(
                            centerX:
                                widget.roi.centerX +
                                d.focalPointDelta.dx / dispW,
                            centerY:
                                widget.roi.centerY +
                                d.focalPointDelta.dy / dispH,
                            sideFraction: newSide,
                          ),
                        );
                      }
                    : null,
              ),
            ),
            // The box outline (does not intercept gestures).
            Positioned(
              left: px.left,
              top: px.top,
              width: px.width,
              height: px.height,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: widget.borderColor,
                      width: widget.borderWidth,
                    ),
                  ),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      color: widget.borderColor.withValues(alpha: 0.85),
                      child: const Text(
                        'drag • pinch to resize',
                        style: TextStyle(color: Colors.black, fontSize: 10),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
