// FaunaPulse, live recording screen:
// time-lapse bursts, video clips, the torch and the camera sleep between bursts.
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

extension _CameraTimeLapse on _CameraSessionScreenState {
  /// The clips controller of this recording (time-lapse bursts, or live AI
  /// segments when [live]).
  TimeLapseVideoClips _videoClips(Directory dir, {required int fps, bool live = false}) => TimeLapseVideoClips(
    videosDir: Directory('${dir.path}/videos'),
    fileToken: _recorder.fileToken ?? 'vid',
    fps: fps,
    live: live,
    // The same size a fast ROI photo would have now.
    sidePx: () {
      final px = savedSidePx(_roi.sideFraction, _imageWidth, _imageHeight);
      return capSavedSidePx(px > 0 ? px : _config.targetRoiSavedPx, _config.targetRoiSavedPx);
    },
    startNative: (path, side, fps) => _controller.startRoiVideo(
      path: path,
      sidePx: side,
      fps: fps,
      cx: _roi.centerX,
      cy: _roi.centerY,
      side: _roi.sideFraction,
      bitsPerPixel: kRoiVideoBitsPerPixel,
    ),
    stopNative: (reason) => _controller.stopRoiVideo(reason: reason),
    logger: () => _logger,
    storageLow: () => _storageVN.value.isLow,
    onProblem: (reason, message) {
      if (!mounted || reason == 'no_frames') return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            reason == 'storage_low'
                ? 'Storage is almost full: no video is recorded until space is freed.'
                : '${live ? 'The video' : 'The video of this burst'} could not be recorded: $message',
          ),
        ),
      );
    },
  );

  /// Live AI + ROI video (round 240): the segment that should be recording
  /// now (a new clip every [kLiveVideoSegmentMs]), none while the camera is
  /// paused (settings, summary, cool-down); the clip reopens when it is back.
  void _liveVideoTick() {
    final v = _liveVideo;
    if (v == null || !_recording) return;
    final segment = (DateTime.now().millisecondsSinceEpoch - _liveVideoStartMs) ~/ kLiveVideoSegmentMs;
    unawaited(v.sync(_paused ? null : segment, endReason: _paused ? 'camera_paused' : 'segment_end'));
    if (mounted) setState(() {}); // chip suffix
  }

  /// Time-lapse driving tick (self-rescheduling one-shot; capped at 60 s so
  /// clock jumps/doze self-heal): asks the pure [TimeLapsePlan] what phase
  /// we're in, re-arms the capture window at each burst start, triggers the
  /// due photo, and re-pushes the native sampling rate on phase changes.
  void _timeLapseTick() {
    _timeLapseTimer = null;
    final plan = _timeLapsePlan;
    if (!_recording || !_config.timeLapseCapture || plan == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final t = nowMs - _timeLapseStartMs;
    final inBurst = plan.inBurstAt(t);
    final cam = _tlCamera;
    // Round 163 (E3): while the camera is parked or still warming up after a
    // wake, the native frame cache holds the PRE-PARK frame — a photo now
    // could show the scene from half an hour ago. Skip triggering (and keep
    // [_tlLastCycle] untouched so the burst window is re-armed the moment
    // fresh frames confirm); the plan math preserves the wall-clock grid, so
    // a late wake starts this burst's photos late without shifting the next.
    final video = _tlVideo;
    // Round 290: the camera can also stop without being told (power button,
    // Home, another app): a photo would then be cut from an old frame. Skip,
    // and say so once per outage.
    final framesFresh = _cameraFramesFresh(nowMs);
    final cameraUp = cam == null || cam.framesUsable;
    if (inBurst && cameraUp && !_paused && !framesFresh) {
      if (!_timeLapseSkipLogged) {
        _timeLapseSkipLogged = true;
        _logger?.logTimeLapseSkipped({
          'reason': _appHidden && !_cameraHeld ? 'app_hidden' : 'no_camera_frames',
          'silent_ms': _lastStreamEventMs == 0 ? null : nowMs - _lastStreamEventMs,
        });
      }
    } else if (framesFresh) {
      _timeLapseSkipLogged = false;
    }
    if (video != null) {
      // Video bursts (round 238): one clip per burst (a continuous time-lapse
      // starts a new clip every burst length). No clip while the camera is
      // paused, parked or still warming up: its frames would be stale.
      final cameraOn = !_paused && cameraUp && framesFresh;
      final String endReason;
      if (!inBurst || cameraOn) {
        endReason = 'burst_end';
      } else if (_paused || !cameraUp) {
        endReason = 'camera_paused';
      } else {
        endReason = _appHidden && !_cameraHeld ? 'app_hidden' : 'no_camera_frames';
      }
      unawaited(
        video.sync(
          inBurst && cameraOn ? plan.cycleIndexAt(t) : null,
          endReason: endReason,
        ),
      );
    } else if (inBurst && cameraUp && framesFresh) {
      final cycle = plan.cycleIndexAt(t);
      if (cycle != _tlLastCycle) {
        _tlLastCycle = cycle;
        _recorder.beginTimeLapseBurst();
      }
      if (_recorder.recordTimeLapseFrame(nowMs, burstIndex: cycle)) {
        _flashCaptureCue();
      }
    }
    if (inBurst != _tlBurstActive) {
      _tlBurstActive = inBurst;
      _pushTimeLapse();
      if (mounted) setState(() {}); // chip label flips
    }
    // Nocturnal torch (round 180): apply the schedule whenever the commanded
    // state drifts from it. Skipped while parked or warming (the camera is
    // unbound or mid-rebind — a call now could only fail, and a transient
    // failure would be indistinguishable from "this lens has no torch"); the
    // wake path re-ticks the moment fresh frames confirm, so after a parking
    // wake the LED ignites with most of the (≥ torch) wake lead still ahead.
    // A failed call leaves [_tlTorchOn] on the confirmed state, so the next
    // tick retries — this mismatch-retry is also what re-lights the torch
    // after every park/wake cycle (the unbind kills the LED physically).
    final torchPlan = _tlTorchPlan;
    if (torchPlan != null && !_tlTorchBusy && !_recorder.stopping) {
      final wantOn = torchPlan.shouldBeOnAt(t);
      final cameraUsable = cam == null || cam.framesUsable;
      if (wantOn != _tlTorchOn && cameraUsable) {
        unawaited(_setTorch(wantOn, wantOn ? 'burst_lead' : 'burst_end'));
      }
    }
    // Park/wake decision. Busy = a pause/resume is already mid-flight; the
    // next tick re-asks the (pure) coordinator, so nothing is lost.
    if (cam != null && !_tlCameraBusy && !_recorder.stopping) {
      switch (cam.actionAt(t)) {
        case TimeLapseCameraAction.park:
          unawaited(_parkTimeLapseCamera(cam));
        case TimeLapseCameraAction.wake:
          unawaited(_wakeTimeLapseCamera(cam));
        case TimeLapseCameraAction.none:
          break;
      }
    }
    // While parked, a tick must also land at the prewake moment — the plan's
    // own cadence (next burst start) would wake 10 s too late. Same for the
    // torch's flip edges (torch-on lead, burst-end OFF edge).
    var delayMs = plan.nextTickDelayMs(t);
    if (video != null) {
      // Clips start and end on the burst edges; inside a burst a tick every
      // second notices a paused or resumed camera.
      final edge = plan.nextEdgeDelayMs(t);
      delayMs = inBurst && edge > 1000 ? 1000 : edge;
    }
    final camDelay = cam?.nextEventDelayMs(t);
    if (camDelay != null && camDelay < delayMs) delayMs = camDelay;
    final torchDelay = _tlTorchPlan?.nextEventDelayMs(t);
    if (torchDelay != null && torchDelay < delayMs) delayMs = torchDelay;
    final delay = delayMs.clamp(100, 60000);
    _timeLapseTimer = Timer(Duration(milliseconds: delay), _timeLapseTick);
  }

  /// Commands the camera's LED torch and reconciles [_tlTorchOn] with what
  /// the platform CONFIRMED (false when the lens has no flash unit or the
  /// camera is unbound mid-rebind — the tick's mismatch check retries those).
  /// Logs `torch` records only on outcome transitions, and warns the user
  /// once per recording when the phone reports no torch.
  Future<void> _setTorch(bool on, String reason) async {
    _tlTorchBusy = true;
    try {
      final wasOn = _tlTorchOn;
      try {
        await _controller.setTorchMode(on);
      } catch (e) {
        _logAsyncError('timelapse_torch', e);
        return;
      }
      final confirmed = _controller.isTorchEnabled;
      _tlTorchOn = confirmed;
      final success = confirmed == on;
      if (success) {
        _tlTorchLoggedFailure = false;
        if (wasOn != confirmed) {
          _logger?.logTorch({'on': on, 'success': true, 'reason': reason});
          if (mounted) setState(() {}); // chip torch suffix
        }
      } else if (!_tlTorchLoggedFailure) {
        // First failure since the last success: one log line, then silence
        // until the outcome changes (a torch-less phone must not flood the
        // log at every retry).
        _tlTorchLoggedFailure = true;
        _logger?.logTorch({'on': on, 'success': false, 'reason': reason});
        if (on && !_tlTorchWarned && mounted) {
          _tlTorchWarned = true;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'The torch did not turn on with this camera. The '
                'time-lapse continues without light.',
              ),
            ),
          );
        }
      }
    } finally {
      _tlTorchBusy = false;
    }
  }

  /// Epoch ms of the next scheduled burst start — the audit anchor every
  /// `camera_sleep` record carries, so intentional camera-off gaps can be
  /// told apart from camera failure in post-processing.
  int _nextBurstEpochMs(TimeLapsePlan plan, int nowMs) =>
      _timeLapseStartMs + plan.nextBurstStartAt(nowMs - _timeLapseStartMs);

  /// Unbinds the camera between time-lapse bursts (round 163, E3). Uses the
  /// same `pause()` the r94 scheduled sleep uses — analysis, photo capture
  /// and preview all stop; the preview freezes on its last frame. A failed
  /// park disables parking for the session (never retry into an unknown
  /// camera state mid-recording).
  Future<void> _parkTimeLapseCamera(TimeLapseCameraCoordinator cam) async {
    _tlCameraBusy = true;
    try {
      final plan = _timeLapsePlan;
      if (plan == null || !_recording) return;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      // A clip still open (a doze-late tick) ends before the camera goes.
      await _tlVideo?.stop('camera_parked');
      try {
        await _controller.pause();
        _paused = true;
      } catch (e) {
        cam.disableParking();
        _logger?.logCameraSleep({
          'state': 'fallback_bound',
          'reason': 'park_failed',
          'next_burst_at_ms': _nextBurstEpochMs(plan, nowMs),
        });
        _logAsyncError('timelapse_park', e);
        return;
      }
      cam.parked();
      // The unbind physically killed the torch (round 180): keep the Dart
      // caches honest so the post-wake mismatch check re-lights it. Normally
      // the torch is already off well before a park; a doze-late park while
      // it was still lit is worth its own audit line.
      if (_tlTorchOn) {
        _tlTorchOn = false;
        _logger?.logTorch({
          'on': false,
          'success': true,
          'reason': 'camera_parked',
        });
      }
      _controller.resetTorchState();
      _logger?.logCameraSleep({
        'state': 'parked',
        'reason': 'between_bursts',
        'next_burst_at_ms': _nextBurstEpochMs(plan, nowMs),
      });
      if (mounted) setState(() {}); // chip shows "camera off"
      // Round 245: plan the next tick again now that the coordinator says parked. The tick that
      // started this park computed its delay while the camera still counted as running, so it
      // knew no prewake moment and waited for the burst start (or the torch-on edge): with
      // breaks up to about a minute the camera then woke late, at the burst itself.
      if (_recording && identical(_tlCamera, cam)) {
        _timeLapseTimer?.cancel();
        _timeLapseTimer = Timer(Duration.zero, _timeLapseTick);
      }
    } finally {
      _tlCameraBusy = false;
    }
  }

  /// Rebinds the camera ahead of the next burst and waits (bounded) for a
  /// fresh frame before photos may flow again. On timeout: leave the camera
  /// bound, disable parking for the rest of the session, and let the
  /// camera-delivery watchdog surface the failure — reliability over saving.
  Future<void> _wakeTimeLapseCamera(TimeLapseCameraCoordinator cam) async {
    _tlCameraBusy = true;
    try {
      final plan = _timeLapsePlan;
      if (plan == null || !_recording) return;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final t = nowMs - _timeLapseStartMs;
      // The burst this wake serves: the upcoming one on a normal prewake, the
      // CURRENT cycle's on a late (doze-delayed) wake that landed inside it.
      final nextBurstAtMs = plan.inBurstAt(t)
          ? _timeLapseStartMs + plan.cycleIndexAt(t) * plan.cycleMs
          : _nextBurstEpochMs(plan, nowMs);
      cam.wakeStarted();
      _logger?.logCameraSleep({
        'state': 'warming',
        // late_wake: a doze-delayed tick landed inside (or past) the burst —
        // the wake is happening after the burst was already due.
        'reason': plan.inBurstAt(t) ? 'late_wake' : 'prewake',
        'next_burst_at_ms': nextBurstAtMs,
      });
      try {
        await _controller.resume();
        _paused = false;
      } catch (e) {
        cam.disableParking();
        _logger?.logCameraSleep({
          'state': 'fallback_bound',
          'reason': 'wake_failed',
          'next_burst_at_ms': nextBurstAtMs,
        });
        _logAsyncError('timelapse_wake', e);
        return;
      }
      // The rebind re-attached the preview; if the blackout cover is up, put
      // the preview back into the measured power-save state (same re-assert
      // the scheduled wake does).
      if (_blackout) await _applyBlackoutSteadyState();
      final fresh = await _waitForFrames(
        Duration(milliseconds: cam.wakeAllowanceMs),
        active: () => _recording && identical(_tlCamera, cam),
      );
      if (!mounted || !_recording || !identical(_tlCamera, cam)) return;
      if (fresh) {
        cam.wakeSucceeded();
        _logger?.logCameraSleep({
          'state': 'running',
          'reason': 'fresh_frame',
          'next_burst_at_ms': nextBurstAtMs,
          'wake_ms': DateTime.now().millisecondsSinceEpoch - nowMs,
        });
        if (mounted) setState(() {}); // chip drops "camera off"
        // Frames are fresh NOW — don't wait for the (≤ 60 s) scheduled tick
        // to notice: a late wake inside a burst should start photos at once.
        _timeLapseTimer?.cancel();
        _timeLapseTimer = Timer(Duration.zero, _timeLapseTick);
      } else {
        cam.disableParking();
        _logger?.logCameraSleep({
          'state': 'fallback_bound',
          'reason': 'wake_timeout',
          'next_burst_at_ms': nextBurstAtMs,
        });
        // The camera stays bound; [_checkCameraDelivery] resumes checking
        // from here on (cameraIntentionallyDown is false now) and raises the
        // red banner + app_error if frames never return.
        _logAsyncError(
          'timelapse_wake',
          'Camera produced no frames within ${cam.wakeAllowanceMs} ms of the '
              'time-lapse wake — parking disabled for this session.',
        );
      }
    } finally {
      _tlCameraBusy = false;
    }
  }
}
