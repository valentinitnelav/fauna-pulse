// FaunaPulse, live recording screen:
// lens, stream size, focus, the ROI (yellow square) and everything pushed to the native view.
//
// A `part` of camera_session_screen.dart: that screen's State class is split into
// extensions, one file per part of the screen, so each file stays readable
// while the private fields stay shared (Dart privacy is per library, and a
// part file belongs to the main file's library). Fields, getters and the
// lifecycle overrides stay in the main file; part files hold methods only.
//
// The extensions below are the State's own code, so calling setState here is
// correct; the analyzer cannot tell an extension from outside code.
// ignore_for_file: invalid_use_of_protected_member

part of '../camera_session_screen.dart';

extension _CameraControls on _CameraSessionScreenState {
  /// The focus state recorded in the session log: 'manual' (locked — the
  /// only mode since round 164) or 'fixed' (fixed-focus lens — no control).
  /// The 'auto' branch is an honesty fallback for the sliver of time before
  /// the preset has applied; it should be unreachable in practice (REC is
  /// calibration-gated) and never occurs by user choice any more. Wire
  /// values are unchanged, so logs from all rounds parse the same way.
  String _focusModeForLog() {
    if (_minFocusDistance <= 0) return 'fixed';
    return _focusManual ? 'manual' : 'auto';
  }

  /// Advances to the next available rear lens (cycles round; the probe
  /// controller updates the label and applies the lens). Only reachable
  /// before recording (the button is disabled while recording, because a lens
  /// change rebinds the camera and shifts the field of view). Persists the new
  /// choice so the next session reopens on the same lens.
  Future<void> _cycleLens() async {
    final lens = await _probes.cycleLens();
    if (lens == null) return;
    final updated = _config.copyWith(selectedLensZoom: lens.zoomFactor);
    setState(() => _config = updated);
    await updated.save();
  }

  /// Round 109: while the user has never chosen a stream resolution
  /// ([SessionConfig.streamResolutionExplicit] false), default it — once per
  /// screen, as soon as BOTH probes have answered — to the smallest supported
  /// size whose short side is ≥ the user's saved-photo target (round 122;
  /// was a fixed 1024, the target's default), so fast ROI crops can reach the
  /// target instead of falling back to the laggy high-res path
  /// (round 108: ~0.4–0.8 s behind the trigger). Runs from the probe
  /// controller's onChanged; the guards keep it out of recordings/scheduled
  /// runs (a stream change rebinds the camera) and stop the rebind's fresh
  /// probe callbacks from looping it.
  void _maybeApplyAutoStreamDefault() {
    if (_autoStreamApplied ||
        _config.streamResolutionExplicit ||
        _recording ||
        _schedule != null ||
        _streamResolutions.isEmpty ||
        !_probes.analysisCeilingProbed) {
      return;
    }
    _autoStreamApplied = true;
    // Same ceiling parsing as the settings sheet's dropdown annotation.
    final recMax = (_analysisCeiling['recommendedMax'] as String?) ?? '';
    final p = recMax.split('x');
    final ceilArea = p.length == 2
        ? (int.tryParse(p[0]) ?? 0) * (int.tryParse(p[1]) ?? 0)
        : 0;
    final pick = autoStreamResolution(
      _streamResolutions,
      ceilingArea: ceilArea,
      minShortSide: _config.targetRoiSavedPx,
    );
    if (pick == null ||
        (pick.$1 == _config.streamWidth && pick.$2 == _config.streamHeight)) {
      return;
    }
    final updated = _config.copyWith(
      streamWidth: pick.$1,
      streamHeight: pick.$2,
      // Stays an AUTO choice: a future device/phone can re-derive its own.
      streamResolutionExplicit: false,
    );
    setState(() => _config = updated);
    updated.save().catchError(
      (Object e) => logSwallowed('auto_stream_save', e),
    );
  }

  void _setManualFocus(double v) {
    _controller.setManualFocus(v);
    setState(() {
      _focusManual = true;
      _focusValue = v;
      // Only the slider calls this — the user has now chosen their focus,
      // so the reminder badge on the focus button goes away (round 164).
      _focusUserAdjusted = true;
    });
    if (_recording) {
      _focusLogDebounce.notify((manual: true, value: v), _writeFocusChange);
    }
  }

  /// Locks the close-up focus preset (round 164): called whenever the
  /// lens's focus range (re)lands — screen open and every lens switch — so
  /// each session starts manually focused at ~13 cm instead of on
  /// autofocus, which drifts onto the background on a mounted phone. The
  /// preset is NOT a user adjustment: the reminder badge stays (or comes
  /// back) until the user drags the slider for the lens in use.
  void _applyFocusPreset() {
    if (_minFocusDistance <= 0) {
      // Fixed-focus lens (or the probe failed): nothing to lock; the start
      // record then honestly logs 'fixed'.
      setState(() {
        _focusManual = false;
        _focusValue = 0;
        _focusUserAdjusted = false;
      });
      return;
    }
    final v = focusPresetNormalized(_minFocusDistance);
    _controller.setManualFocus(v);
    setState(() {
      _focusManual = true;
      _focusValue = v;
      _focusUserAdjusted = false;
    });
    // Normally the preset lands during calibration, long before REC. If a
    // late lens-settle fallback ever re-applies it mid-recording, log the
    // change like any settled focus move so the session stays auditable.
    if (_recording) {
      _focusLogDebounce.notify((manual: true, value: v), _writeFocusChange);
    }
  }

  /// Writes one focus_change record for a settled focus adjustment
  /// (debouncer callback). Same shape as the start record's focus fields.
  void _writeFocusChange(({bool manual, double value}) settled) {
    _logger?.logFocusChange({
      'focus_mode': settled.manual ? 'manual' : 'auto',
      if (settled.manual) 'focus_value': settled.value,
    });
  }

  void _onRoiChanged(Roi roi) {
    // Keep the box inside the visible preview (covers the size-slider path; the
    // drag/pinch overlay also clamps with its exact constraints).
    var clamped = roi.clampToVisible(_currentVisibleRect(), _frameAspect);
    // Snap the box geometry to the same multiple-of-32 grid the readout and the
    // saved crop use, so the box you see equals the square written to disk
    // ("what you see is what you save"). Only possible once the crop source size
    // is known; until then the box stays continuous and the readout shows
    // "measuring…". Snapping only shrinks the side, so moves are unaffected.
    if (_roiSourceWidth > 0) {
      clamped = clamped.snapSideToGrid(
        sourceWidth: _roiSourceWidth,
        maxSidePx: _maxRoiPx,
        frameAspect: _frameAspect,
      );
    }
    setState(() => _roi = clamped);
    _pushInferenceRoi();
    // Logging is debounced (round 109): the box and the inference ROI above
    // follow the finger immediately, but only the geometry the user SETTLES
    // on (unchanged for ~2 s, or recording stops) becomes a roi_update record
    // — one line per adjustment instead of one per drag tick.
    if (_recording) _roiLogDebounce.notify(_roi, _writeRoiUpdate);
  }

  /// Writes one roi_update record for a settled ROI (debouncer callback).
  /// [settled] equals the live [_roi] when it runs — the debouncer only fires
  /// while the geometry is stable — so the derived fields read current state.
  void _writeRoiUpdate(Roi settled) {
    _logger?.logRoiUpdate({
      'roi': settled.toLogJson(_roiLogDims.$1, _roiLogDims.$2),
      // Which source the ROI dims above refer to ('fast' = analysis
      // frame, 'still' = high-res photo; frozen wire names) — in auto
      // mode it depends on the box size.
      'roi_source': _activePath.wireName,
      // Exact side of the file this box would save (crop snap + max-side cap),
      // so post-processing never has to re-derive it from the fraction.
      'saves_px': _savedSideNow,
      // The ÷32 side the user saw on screen (stream grid) — see start record.
      'roi_side_stream_px': savedSidePx(
        settled.sideFraction,
        _imageWidth,
        _imageHeight,
      ),
    });
  }

  /// Re-snaps the current ROI to the saved-crop multiple-of-32 grid once the crop
  /// source size first becomes known (the first analysis frame, or the full-res
  /// still probe). A box loaded from a persisted session is stored as a raw
  /// fraction, so this lands it on the same grid the readout and crop use, making
  /// it WYSIWYG without the user having to touch it. Call from inside a setState.
  void _snapRoiToSourceGrid() {
    if (_roiSourceWidth <= 0) return;
    _roi = _roi.snapSideToGrid(
      sourceWidth: _roiSourceWidth,
      maxSidePx: _maxRoiPx,
      frameAspect: _frameAspect,
    );
  }

  /// The frame-normalized rectangle currently visible on the preview (the rest
  /// is cropped off by the camera's cover fit), used to clamp the ROI.
  Rect _currentVisibleRect() {
    final size = MediaQuery.of(context).size;
    return PreviewTransform(
      widget: size,
      frameAspect: _frameAspect,
    ).visibleNormalizedRect();
  }

  /// Lets the user set an exact ROI side in pixels (of the saved full-res crop)
  /// with a live slider OR by typing a number, so they don't have to pinch
  /// precisely. Values snap to the nearest multiple of 32 (what the crop uses).
  ///
  /// The sheet is a real widget (RoiSizeSheet, round 71) rather than an
  /// inline StatefulBuilder: the old version disposed its text controller as
  /// soon as the sheet's future completed, but the builder could still run
  /// once more during the closing animation (keyboard inset animating away)
  /// and wrote to the disposed controller — a split-second red error flash
  /// on screen (caught twice by the round-67 error trap in session_107).
  Future<void> _editRoiSize() async {
    // Use the width the ROI crop is actually saved from, so the px values here
    // match the saved files and the on-screen readout.
    final srcW = _roiSourceWidth;
    if (srcW <= 0) return;
    final visible = _currentVisibleRect();
    const minPx = 96;
    // Cap by both the visible width and the source's short side (the real max).
    final maxPx = snapToMultipleOf32(
      visible.width * srcW,
    ).clamp(minPx, _maxRoiPx).toInt();
    final curPx = snapToMultipleOf32(
      _roi.sideFraction * srcW,
    ).clamp(minPx, maxPx).toInt();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      // Let the sheet grow with its content and sit above the keyboard so the
      // helper text below the slider is never clipped off the bottom.
      isScrollControlled: true,
      builder: (_) => RoiSizeSheet(
        minPx: minPx,
        maxPx: maxPx,
        initialPx: curPx,
        onApply: (px) => _onRoiChanged(
          Roi(
            centerX: _roi.centerX,
            centerY: _roi.centerY,
            sideFraction: px / srcW,
          ),
        ),
      ),
    );
  }

  /// Sends the current ROI to the native side so inference runs only on that
  /// square crop (better small-object recall; nothing outside the ROI detected).
  void _pushInferenceRoi() {
    _controller
        .setInferenceRoi(
          cx: _roi.centerX,
          cy: _roi.centerY,
          side: _roi.sideFraction,
        )
        .catchError((Object e) => _logAsyncError('set_inference_roi', e));
  }

  /// Sends the camera frame-rate cap to the native side (round 82). This slows
  /// the camera *hardware* (sensor + image processor) — the standing load that
  /// keeps warming the phone even while the motion gate has the detector
  /// asleep. The inference cap above it only skips frames in software.
  void _pushCameraFpsCap() {
    _controller
        .setCameraFpsCap(_config.cameraFpsCap)
        .catchError((Object e) => _logAsyncError('set_camera_fps_cap', e));
  }

  void _pushStillZsl(SessionConfig c) {
    _controller
        .setStillZsl(_stillZslFor(c))
        .catchError((Object e) => _logAsyncError('set_still_zsl', e));
  }

  /// Round 292: while a recording or scheduled run is active the camera keeps
  /// running when the screen goes off (power button, screen timeout) or the
  /// app is sent to the background; only the preview detaches. Sent at every
  /// change and in the start-up sequence of each new native view.
  void _pushCameraHold() {
    final hold = _recording || _schedule != null;
    _cameraHeld = hold;
    _controller
        .setCameraHold(hold)
        .catchError((Object e) => _logAsyncError('set_camera_hold', e));
    _syncScreenIdle();
  }

  /// Sends the motion-gate settings to the native pipeline. When enabled the
  /// detector sleeps while nothing moves inside the ROI (heat/battery saver);
  /// the native side always starts the gate awake so the user sees it working.
  void _pushMotionGate() {
    // In time-lapse mode the gate is irrelevant (photos are clock-driven):
    // force it off natively even if the detector-mode setting is on.
    final gateOn =
        _config.motionOnlyCapture ||
        (_config.detectorEnabled && _config.motionGateEnabled);
    _controller
        .setMotionGate(
          // Motion-only capture cannot work without the gate (it IS the
          // trigger), so it forces the gate on; the native side guards the
          // same way (belt and braces).
          enabled: gateOn,
          pixelDelta: _config.motionGatePixelDelta,
          areaFraction: _config.motionGateAreaFraction,
          wakeSeconds: _config.motionGateWakeSeconds,
          gridSize: _config.motionGateGridSize,
          idleFps: _config.motionGateIdleFps,
          motionOnly: _config.motionOnlyCapture,
        )
        .catchError((Object e) => _logAsyncError('set_motion_gate', e));
    if (!gateOn && _gateIdle) {
      // Gate switched off while idle: clear the idle indicator immediately.
      setState(_frame.forceGateAwake);
    }
  }

  /// Applies time-lapse mode natively. The frame-sampling rate follows the
  /// burst phase: high during a burst so fast ROI crops stay fresher than
  /// half a photo step, 1 fps between bursts (just frame-cache freshness for
  /// the next burst's first photo + the 1 Hz heartbeat).
  void _pushTimeLapse() {
    // Video bursts convert every frame of the clip (round 238; the clip's own
    // frame clock takes over natively once it is open).
    final burstFps = _config.timeLapseVideo
        ? _config.timeLapseVideoFps
        : (2 / _config.stepSeconds).ceil().clamp(1, 30);
    _controller
        .setTimeLapse(
          enabled: _config.timeLapseCapture,
          sampleFps: _config.timeLapseCapture && _tlBurstActive ? burstFps : 1,
        )
        .catchError((Object e) => _logAsyncError('set_time_lapse', e));
  }
}
