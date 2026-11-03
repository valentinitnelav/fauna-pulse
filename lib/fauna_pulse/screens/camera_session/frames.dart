// FaunaPulse, live recording screen:
// what happens with every frame result from the native camera view.
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

extension _CameraFrames on _CameraSessionScreenState {
  // --- Per-frame pipeline -------------------------------------------------

  void _onStreamingData(Map<String, dynamic> data) {
    // Any event from the native side means the camera is alive: feed the
    // camera-delivery watchdog and clear its banner if it had fired.
    _lastStreamEventMs = DateTime.now().millisecondsSinceEpoch;
    if (_cameraSilent) {
      _cameraSilent = false;
      if (_recording) {
        _logger?.logAppError({
          'source': 'watchdog',
          'message': 'Camera frame delivery resumed.',
        });
      }
      if (mounted && _inferenceError == _cameraSilentError) {
        setState(() => _inferenceError = null);
      }
    }
    // Motion-gate idle heartbeat: while the gate keeps the detector asleep the
    // native side sends ~1 Hz maps with only gate state + camera FPS (no
    // detections). Update the gate indicator and bail out — no tracking, no
    // watchdog (0 detector FPS is *intentional* here).
    if (data['gateIdle'] == true) {
      final hbCamFps = (data['cameraFps'] as num?)?.toDouble() ?? 0;
      _motionScoreVN.value = (data['motionScore'] as num?)?.toDouble() ?? 0;
      // The detector is asleep: no inference is happening, so every
      // inference-derived number must read 0 now. These used to keep their
      // last awake values ("Pipeline: 11.7 fps", frozen inf_ms flat-lining
      // the end-of-session graphs) — round 77.
      _fpsVN.value = 0;
      _perfVN.value = const [0, 0, 0];
      _lastTrackMs = 0;
      _fpsTrioVN.value = [hbCamFps, 0, 0];
      _setGateIdle(true);
      return;
    }
    if (data.containsKey('gateIdle')) _setGateIdle(false);
    if (data.containsKey('motionScore')) {
      _motionScoreVN.value = (data['motionScore'] as num?)?.toDouble() ?? 0;
    }

    // Motion-only capture mode: the detector never runs, so the native side
    // sends awake gate maps (`motionOnly: true`, no detections) instead of
    // results. Drive the motion time-lapse photos from them and bail out —
    // no tracking, and the 0-FPS detector watchdog below must NEVER see these
    // frames (0 detector FPS is the whole point of the mode, not a failure).
    if (_config.motionOnlyCapture && data['motionOnly'] == true) {
      final w = (data['imageWidth'] as num?)?.toInt() ?? _imageWidth;
      final h = (data['imageHeight'] as num?)?.toInt() ?? _imageHeight;
      final cameraFps = (data['cameraFps'] as num?)?.toDouble() ?? 0;
      // No inference is happening: every inference-derived number reads 0
      // (same honesty rule as the gate-idle heartbeat above, round 77).
      _fpsVN.value = 0;
      _perfVN.value = const [0, 0, 0];
      _lastTrackMs = 0;
      _fpsTrioVN.value = [cameraFps, 0, 0];
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_recorder.recordMotionFrame(
        nowMs,
        motionScore: _motionScoreVN.value,
      )) {
        _flashCaptureCue();
      }
      if (mounted && (w != _imageWidth || h != _imageHeight)) {
        setState(() {
          _imageWidth = w;
          _imageHeight = h;
          _snapRoiToSourceGrid();
        });
      }
      // Same one-time bootstrap as the detector path below: these maps carry
      // the analysis dims precisely so the ROI push + photo-size probe can
      // run when the app starts straight into motion-only mode.
      _startUpOnce(w, h);
      return;
    }

    // Time-lapse capture mode: photos are driven by [_timeLapseTick]'s clock,
    // NOT by these maps — the native side only heartbeats ~1 Hz (with dims)
    // so the bootstrap and the camera watchdog stay fed. Zero the inference
    // numbers and bail out before the 0-FPS detector watchdog, exactly like
    // the motion-only branch above.
    if (_config.timeLapseCapture && data['timeLapse'] == true) {
      final w = (data['imageWidth'] as num?)?.toInt() ?? _imageWidth;
      final h = (data['imageHeight'] as num?)?.toInt() ?? _imageHeight;
      final cameraFps = (data['cameraFps'] as num?)?.toDouble() ?? 0;
      _fpsVN.value = 0;
      _perfVN.value = const [0, 0, 0];
      _lastTrackMs = 0;
      _fpsTrioVN.value = [cameraFps, 0, 0];
      if (mounted && (w != _imageWidth || h != _imageHeight)) {
        setState(() {
          _imageWidth = w;
          _imageHeight = h;
          _snapRoiToSourceGrid();
        });
      }
      _startUpOnce(w, h);
      return;
    }

    // No detection model loaded (round 270: none on this phone, or it failed
    // to load) and neither no-AI mode set yet: the native side heartbeats
    // ~1 Hz with the frame size, so the start-up runs (it switches the native
    // side into motion-only or time-lapse capture, which need no model) and
    // the camera readout stays live. Nothing to track and no detector
    // watchdog: there is no detector.
    if (data['noModel'] == true) {
      final w = (data['imageWidth'] as num?)?.toInt() ?? _imageWidth;
      final h = (data['imageHeight'] as num?)?.toInt() ?? _imageHeight;
      final cameraFps = (data['cameraFps'] as num?)?.toDouble() ?? 0;
      _fpsVN.value = 0;
      _perfVN.value = const [0, 0, 0];
      _lastTrackMs = 0;
      _fpsTrioVN.value = [cameraFps, 0, 0];
      if (mounted && (w != _imageWidth || h != _imageHeight)) {
        setState(() {
          _imageWidth = w;
          _imageHeight = h;
          _snapRoiToSourceGrid();
        });
      }
      _startUpOnce(w, h);
      return;
    }

    final w = (data['imageWidth'] as num?)?.toInt() ?? _imageWidth;
    final h = (data['imageHeight'] as num?)?.toInt() ?? _imageHeight;
    final fps = (data['fps'] as num?)?.toDouble() ?? _fpsVN.value;
    final accel = (data['accelerator'] as String?) ?? _accelerator;
    final preMs = (data['preMs'] as num?)?.toDouble() ?? 0;
    final inferMs = (data['inferenceMs'] as num?)?.toDouble() ?? 0;
    final postMs = (data['postMs'] as num?)?.toDouble() ?? 0;
    final cameraFps = (data['cameraFps'] as num?)?.toDouble() ?? 0;
    _perfVN.value = [preMs, inferMs, postMs];

    // Pipeline FPS: rate at which the app fully handles inferred frames (this
    // callback runs the ROI mapping + tracking + overlay update). Smoothed,
    // maintained by the frame processor.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _fpsTrioVN.value = [cameraFps, fps, _frame.updatePipelineFps(nowMs)];

    // Too slow for live detection? (round 278; work per picture, not fps).
    if (_config.detectorEnabled &&
        !_hideSlowHint &&
        !_calibrating &&
        _slowHint.add(nowMs, preMs + inferMs + postMs)) {
      final perSecond = 1000 / _slowHint.medianMs!;
      debugPrint('SLOW_PHONE_HINT median ${_slowHint.medianMs!.toStringAsFixed(0)} ms per picture');
      setState(() => _slowPerSecond = perSecond);
    }

    // Inference watchdog: if the camera is delivering frames but the detector
    // never produces any (0 FPS) for a while, the model is likely failing
    // silently. Raise the same error banner so the user can report it. If the
    // detector recovers, clear the warning.
    if (fps > 0.01) {
      _detectorEverRan = true;
      if (_inferenceError != null) {
        setState(() => _inferenceError = null);
      }
    } else if (cameraFps > 1) {
      if (_camDeliverStartMs == 0) _camDeliverStartMs = nowMs;
      if (!_detectorEverRan &&
          _inferenceError == null &&
          nowMs - _camDeliverStartMs > 8000) {
        _logger?.logAppError({
          'source': 'watchdog',
          'message':
              'Detector produced no results for 8 s while the camera '
              'was delivering frames.',
        });
        setState(() {
          _inferenceError =
              'The detection model gives no results although the camera is '
              'running. It may not work on this phone: choose another model in '
              'Session settings (Detection tab), or tap Report.';
          _errorBannerDismissed = false;
        });
      }
    }

    // Log the timing breakdown ~once a second so it can be read from `flutter
    // run` / logcat to diagnose the frame rate.
    if (nowMs - _lastPerfLogMs >= 1000) {
      _lastPerfLogMs = nowMs;
      // Re-derive the tracker's frame-based buffers (occlusion tolerance and
      // min-hits-to-confirm) from the current (smoothed) detector FPS once a
      // second, so the user's seconds-based settings stay correct as the frame
      // rate drifts during the session.
      final wantedBuffer = _config.occlusionFramesFor(fps);
      final wantedHits = _config.minHitsFramesFor(fps);
      if (wantedBuffer != _tracker.trackBuffer ||
          wantedHits != _tracker.minHitsToConfirm) {
        _tracker.setFrameBudgets(
          trackBuffer: wantedBuffer,
          minHitsToConfirm: wantedHits,
        );
      }
      // Same seconds setting as a time limit for pauses in frames (see
      // InsectTracker.maxFrameGapMs), but never under three frame intervals,
      // so a slow (throttled) detector does not expire lost tracks early.
      final occlusionMs = (_config.occlusionSeconds * 1000).round();
      final slowFramesMs = (fps.isFinite && fps > 0) ? (3000 / fps).round() : 0;
      _tracker.maxFrameGapMs =
          occlusionMs > slowFramesMs ? occlusionMs : slowFramesMs;
      // Auto thermal-aware throttle: feed the latest inference time and apply the
      // resulting rate cap. A change re-sends the streaming config (declaratively,
      // via the YOLOView prop) which updates the native frame-skip interval with
      // no camera rebind (analysis resolution is unchanged).
      final thr = _throttle;
      // Only the AI mode's inference times (round 243): the detector also runs for a moment
      // before a time-lapse or motion session's mode reaches the native side, and a slow
      // phone's first frames pulled the cap down for the whole session.
      if (thr != null && inferMs > 0 && _config.detectorEnabled) {
        final cap = thr.update(inferMs);
        if (cap != _appliedCapFps && mounted) {
          setState(() => _appliedCapFps = cap);
        }
      }
      debugPrint(
        'PERF camera=${cameraFps.toStringAsFixed(1)} '
        'detector=${fps.toStringAsFixed(1)} '
        'pipeline=${_frame.pipelineFpsEma.toStringAsFixed(1)} engine=$accel '
        'pre=${preMs.toStringAsFixed(1)} inf=${inferMs.toStringAsFixed(1)} '
        'post=${postMs.toStringAsFixed(1)} '
        'track=${_lastTrackMs.toStringAsFixed(2)} '
        'cap=${_appliedCapFps ?? 0} analysis=${w}x$h',
      );
    }
    // Detection mapping + tracking live in [FrameProcessor] (round 73, review
    // B6a) so the core per-frame logic is unit-testable: it maps the
    // ROI-normalized boxes back onto the full frame (or filters full-frame
    // boxes by ROI centre on the fallback path), confines them to the ROI,
    // and advances the tracker.
    final result = _frame.process(
      data: data,
      roi: _roi,
      width: w,
      height: h,
      fallbackAspect: _frameAspect,
    );
    _lastTrackMs = result.trackMs;

    // While recording, log this frame's tracks and trigger a shared ROI photo
    // when one is due; blink the border as the visual cue if it was. Detector
    // mode only: during startup a few detector-style frames can arrive before
    // the first setMotionGate/setTimeLapse lands natively, and they must
    // never write `detections` records into a motion-only/time-lapse log.
    if (_config.detectorEnabled &&
        _recorder.recordFrame(
          result.tracks,
          result.roiRect,
          result.timestampMs,
          // Evaluation toggle (round 105): also log the pre-tracking boxes so
          // this session can be replayed offline through either tracker.
          rawDetections: _config.logRawDetections ? result.detections : null,
          frameSensorMs: result.frameSensorMs,
          // Round 116: explicit lifecycle lines (created/lost/recovered/
          // removed) so post-processing can stitch fragmented track ids.
          trackEvents: result.events,
        )) {
      _flashCaptureCue();
    }

    // High-frequency updates go through notifiers (no full rebuild).
    _tracksVN.value = result.tracks;
    _fpsVN.value = fps;

    // The frame size and accelerator change only when the camera/model first
    // start, so a real setState here is rare and cheap. It refreshes the ROI
    // overlay's aspect ratio and the status readouts.
    if (mounted &&
        (w != _imageWidth || h != _imageHeight || accel != _accelerator)) {
      setState(() {
        _imageWidth = w;
        _imageHeight = h;
        _accelerator = accel;
        // A crop source is now known: align a loaded box to the ÷32 grid
        // (no-op if the active path's source size is still unknown).
        _snapRoiToSourceGrid();
      });
    }

    // Once the camera is delivering frames, probe the full-resolution photo size
    // a single time so the ROI resolution readout reflects the saved photo, and
    // (re)assert the inference ROI now the native pipeline is certainly live.
    _startUpOnce(w, h);
  }

  /// The one-time start-up once the camera delivers frames of a known size:
  /// push the ROI, motion gate, camera frame-rate cap and time-lapse mode to
  /// the native side and probe the full-resolution photo size. Runs from the
  /// first map of any kind (detector result, motion-only, time-lapse or
  /// no-model heartbeat), so the app can start straight into any mode.
  void _startUpOnce(int w, int h) {
    if (_captureProbeStarted || w <= 0 || h <= 0) return;
    _captureProbeStarted = true;
    _pushInferenceRoi();
    _pushMotionGate();
    _pushCameraFpsCap();
    _pushTimeLapse();
    _pushCameraHold();
    _pushStillZsl(_config);
    _probes.begin(
      analysisDims: () => (_imageWidth, _imageHeight),
      preferredLensZoom: _config.selectedLensZoom,
    );
  }

  /// Applies a motion-gate state change reported by the native side: the
  /// frame processor holds the state and — crucially — expires stale "lost"
  /// tracks after a sleep longer than the occlusion tolerance (see
  /// [FrameProcessor.setGateIdle]); this wrapper updates the on-screen
  /// indicator and logs the transition to the session JSONL (so gated periods
  /// are auditable when validating recall).
  void _setGateIdle(bool idle) {
    final change = _frame.setGateIdle(
      idle,
      occlusionSeconds: _config.occlusionSeconds,
    );
    if (change == null) return;
    // Motion-only capture: the gate going to sleep ends the motion event —
    // re-arm the photo burst so the NEXT wake photographs immediately
    // (round 96: without this, a second hand-wave within ~wake+duration
    // seconds of the first burst captured nothing). Transition-only: a
    // repeated idle heartbeat returns null above.
    if (change.idle && _config.motionOnlyCapture) {
      _recorder.onMotionGateIdle();
    }
    if (mounted) setState(() {});
    if (_recording) {
      _logger?.logMotionGate({
        'state': change.idle ? 'idle' : 'awake',
        'motion_score': _motionScoreVN.value,
        if (!change.idle && change.idleSeconds > 0)
          'idle_s': double.parse(change.idleSeconds.toStringAsFixed(1)),
      });
    }
  }

  /// Camera-delivery watchdog (B4), run from the 1 s recording ticker: if no
  /// stream event of any kind (detections, heartbeats) has arrived for
  /// [_cameraSilentAfterMs], the camera itself has stopped — a HAL crash,
  /// another app grabbing it, or OS resource reclaim. An unattended session
  /// would otherwise sit recording nothing for hours. Fires once per outage:
  /// app_error line (flushed, in case this precedes a bigger failure) + the
  /// red banner; both clear automatically if delivery resumes.
  void _checkCameraDelivery() {
    if (!_recording || _cameraSilent || _lastStreamEventMs == 0) return;
    // Round 163 (E3): while the time-lapse coordinator has the camera
    // intentionally parked (or a wake is still warming up), silence IS the
    // feature — the watchdog must not read it as a camera failure. After a
    // FAILED wake the coordinator reads fallbackBound (not "down"), so the
    // watchdog resumes and correctly surfaces the dead camera.
    if (_tlCamera?.cameraIntentionallyDown ?? false) return;
    final silentMs = DateTime.now().millisecondsSinceEpoch - _lastStreamEventMs;
    if (silentMs < _cameraSilentAfterMs) return;
    _cameraSilent = true;
    _logger?.logAppError({
      'source': 'watchdog',
      'message':
          'Camera delivered no frames for ${(silentMs / 1000).round()} s '
          '(camera lost: HAL crash, other app, or OS reclaim).',
    });
    _logger?.flushNow();
    if (mounted) {
      setState(() {
        _inferenceError = _cameraSilentError;
        _errorBannerDismissed = false;
      });
    }
  }

  /// Blinks the ROI border (via [_captureFlashVN]) for a split second so the
  /// user can see when a photo is taken. Off when the user disables it. Only the
  /// ROI border rebuilds, at the photo cadence, so it never touches the FPS.
  void _flashCaptureCue() {
    if (!_config.flashOnCapture) return;
    _captureFlashVN.value = true;
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 180), () {
      _captureFlashVN.value = false;
    });
  }
}
