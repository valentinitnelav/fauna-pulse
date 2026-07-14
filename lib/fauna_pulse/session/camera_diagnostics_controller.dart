// FaunaPulse — one-time camera probes & diagnostics, extracted from
// the camera screen (round 73, review item B6c).
//
// Once the camera delivers its first frame, the app asks it a batch of
// questions whose answers never change during a session: the true size of a
// full-resolution still (for the ROI resolution readout), whether the lens
// can focus manually, which analysis-stream resolutions exist, the realistic
// analysis ceiling, the available rear lenses, and the per-camera
// diagnostics for the settings sheet. This class owns those probes and their
// results; the screen just re-reads them through thin getters and rebuilds
// when [onChanged] fires.

import 'package:flutter/foundation.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../logging/app_error_hooks.dart';

import '../capture/roi_capture.dart';

/// Fires the one-time camera probes and holds their results.
class CameraDiagnosticsController {
  CameraDiagnosticsController({
    required this.controller,
    required this.onChanged,
  });

  final YOLOViewController controller;

  /// Called after any probe result lands, so the screen can rebuild. The
  /// screen's callback guards on `mounted` itself.
  final VoidCallback onChanged;

  /// Camera-supported analysis stream resolutions ("WxH"), for the settings
  /// menu. Empty until probed (settings falls back to a standard preset list).
  List<String> streamResolutions = const [];

  /// Estimated ceiling for what CameraX ImageAnalysis can actually stream on
  /// this phone (the still/preview sizes advertise more than the analysis
  /// pipeline can deliver). Keys: hardwareLevel, recommendedMax ("WxH"),
  /// previewBoundW/H, displayW/H. See round 56.
  Map<String, dynamic> analysisCeiling = const {};

  /// Full-resolution still dimensions (the photo actually saved), learned
  /// once by probing capturePhoto(). 0 until the probe (or its analysis-frame
  /// fallback) lands; recording waits for it ("Calibrating…").
  int captureWidth = 0;
  int captureHeight = 0;

  /// The lens's largest focus distance (in dioptres, 1/metres), read once
  /// from the camera; > 0 means the lens supports manual focus, so the
  /// screen shows a focus slider.
  double minFocusDistance = 0;

  /// The device's available rear lenses (main wide, ultra-wide, telephoto,
  /// …) with their effective zoom factors (1.0 = main wide), plus which one
  /// is currently selected and its short button label ("1×", "0.5×", "2×").
  List<LensInfo> lenses = const [];
  int lensIndex = 0;
  String lensLabel = '';

  /// Per-camera diagnostics (id, facing, focal lengths, logical/physical,
  /// whether usable for inference + why), for Settings → Camera.
  List<Map<String, dynamic>> cameraDiagnostics = const [];

  bool _disposed = false;

  /// Stops probe results from landing after the screen is gone (the
  /// class-level equivalent of the screen's old `mounted` checks).
  void dispose() {
    _disposed = true;
  }

  void _notify() {
    if (!_disposed) onChanged();
  }

  /// Fires all one-time probes (each is fire-and-forget and swallows its own
  /// failures). Call once, as soon as the camera is delivering frames.
  ///
  /// [analysisDims] supplies the live analysis-frame size — the still-probe's
  /// fallback when every capture attempt fails. [preferredLensZoom] is the
  /// persisted lens choice to re-apply ([SessionConfig.selectedLensZoom]).
  void begin({
    required (int, int) Function() analysisDims,
    required double preferredLensZoom,
  }) {
    _probeCaptureResolution(analysisDims);
    _probeFocusSupport();
    _fetchStreamResolutions();
    _fetchAnalysisCeiling();
    _fetchAvailableLenses(preferredLensZoom);
    _fetchCameraDiagnostics();
  }

  /// Advances to the next available rear lens (cycles round), updating
  /// [lensIndex]/[lensLabel] immediately and then applying the lens on the
  /// camera. Returns the new lens so the caller can persist the choice, or
  /// null when the phone has fewer than two usable lenses.
  Future<LensInfo?> cycleLens() async {
    if (lenses.length < 2) return null;
    lensIndex = (lensIndex + 1) % lenses.length;
    final lens = lenses[lensIndex];
    lensLabel = lensLabelFor(lens);
    _notify();
    await controller.setLens(lens.zoomFactor);
    return lens;
  }

  /// Short label for the lens button, e.g. "1×", "0.5×", "2×". Falls back to
  /// the native label (Wide / Ultra wide / Telephoto camera) if the factor is
  /// odd.
  static String lensLabelFor(LensInfo lens) {
    final z = lens.zoomFactor;
    if (z <= 0) return lens.label;
    return z < 1
        ? '${z.toStringAsFixed(1)}×'
        : '${z.toStringAsFixed(z == z.roundToDouble() ? 0 : 1)}×';
  }

  /// Grabs one full-resolution still, reads its pixel size, and stores it so
  /// the UI can show the true ROI resolution. Retries a few times because the
  /// very first capture right after the camera starts often fails (the
  /// still-capture use-case isn't bound yet). If it never succeeds (e.g. a
  /// model that stalls the pipeline), it falls back to the analysis-frame
  /// size and marks the reading approximate, so the "Calibrating…" banner
  /// never hangs forever.
  Future<void> _probeCaptureResolution(
    (int, int) Function() analysisDims,
  ) async {
    for (
      var attempt = 0;
      attempt < 6 && !_disposed && captureWidth == 0;
      attempt++
    ) {
      try {
        final raw = await controller.capturePhotoRaw().timeout(
          const Duration(seconds: 4),
        );
        if (raw != null) {
          final size = await probeJpegSize(raw.$1);
          if (size != null && !_disposed) {
            // Store UPRIGHT dimensions so all downstream math keeps one frame
            // of reference. uprightStillDims (round 64) handles the decoder
            // having possibly applied the EXIF rotation already — a blind
            // swap here double-rotated in session_97.
            final up = uprightStillDims(raw.$2, size.$1, size.$2);
            captureWidth = up.$1;
            captureHeight = up.$2;
            // The box's grid is the stream (round 62), so no re-snap here —
            // the still size only feeds the "saves N×N" readout and crops.
            _notify();
            return;
          }
        }
      } catch (e) {
        // Try again after a short pause (traced, rate-limited per site).
        logSwallowed('still_size_probe', e);
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    // Gave up on a real still: fall back to the analysis frame so the UI
    // stops showing "Calibrating…".
    final (analysisW, analysisH) = analysisDims();
    if (!_disposed && captureWidth == 0 && analysisW > 0) {
      captureWidth = analysisW;
      captureHeight = analysisH;
      _notify();
    }
  }

  /// Asks the camera whether it can focus manually. If so the screen exposes
  /// a focus slider; fixed-focus lenses report 0 and the control stays hidden.
  Future<void> _probeFocusSupport() async {
    try {
      final d = await controller.getMinFocusDistance();
      if (!_disposed) {
        minFocusDistance = d;
        _notify();
      }
    } catch (e) {
      // Leave at 0 (manual focus unsupported / unavailable).
      logSwallowed('min_focus_probe', e);
    }
  }

  /// Asks the camera which analysis-stream resolutions it supports, so the
  /// settings dropdown can offer only realistic options for this phone.
  Future<void> _fetchStreamResolutions() async {
    try {
      final list = await controller.getStreamResolutions();
      if (!_disposed && list.isNotEmpty) {
        streamResolutions = list;
        _notify();
      }
    } catch (e) {
      // Leave empty; settings falls back to a standard preset list.
      logSwallowed('stream_resolutions_probe', e);
    }
  }

  /// Asks the camera for the realistic analysis-stream ceiling (what CameraX
  /// can actually deliver, usually smaller than the still/preview sizes), so
  /// the settings sheet can flag sizes the phone will silently shrink.
  Future<void> _fetchAnalysisCeiling() async {
    try {
      final c = await controller.getAnalysisStreamCeiling();
      if (!_disposed && c.isNotEmpty) {
        analysisCeiling = c;
        _notify();
      }
    } catch (e) {
      // Leave empty; the dropdown simply won't annotate a ceiling.
      logSwallowed('analysis_ceiling_probe', e);
    }
  }

  /// Reads the rear-camera lenses the device exposes and snaps to the one the
  /// user picked last time. On a single-lens phone this leaves the only lens
  /// active. Failures leave the list empty so the switch button stays
  /// disabled and the app keeps using the default lens.
  Future<void> _fetchAvailableLenses(double preferredLensZoom) async {
    try {
      final found = await controller.getAvailableLenses();
      if (_disposed || found.isEmpty) return;
      // Find the lens closest to the persisted choice.
      var index = 0;
      var best = double.infinity;
      for (var i = 0; i < found.length; i++) {
        final d = (found[i].zoomFactor - preferredLensZoom).abs();
        if (d < best) {
          best = d;
          index = i;
        }
      }
      lenses = found;
      lensIndex = index;
      lensLabel = lensLabelFor(found[index]);
      _notify();
      // Apply the persisted lens (no-op if it's already the active one).
      if (found[index].zoomFactor != 1.0) {
        await controller.setLens(found[index].zoomFactor);
      }
    } catch (e) {
      // Leave empty: the switch button stays disabled, default lens in use.
      logSwallowed('lens_probe', e);
    }
  }

  /// Reads the per-camera diagnostics (every camera/lens the device reports,
  /// with focal lengths, physical-vs-logical, and whether each is usable by
  /// the inference pipeline). Shown under Settings → Camera ("Camera & lens
  /// info") — intentionally *not* on the live recording screen.
  Future<void> _fetchCameraDiagnostics() async {
    try {
      final cams = await controller.getCameraDiagnostics();
      if (!_disposed && cams.isNotEmpty) {
        cameraDiagnostics = cams;
        _notify();
      }
    } catch (e) {
      // Leave empty; the settings section shows a "not available" note.
      logSwallowed('camera_diagnostics_probe', e);
    }
  }
}
