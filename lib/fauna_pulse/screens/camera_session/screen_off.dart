// FaunaPulse, live recording screen: the screen-off cover (power saving) and idle dimming.
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

extension _CameraScreenOff on _CameraSessionScreenState {
  /// Enters blackout power-save mode: covers the whole UI with opaque black while
  /// the camera, detector, tracker and photo capture keep running underneath. A
  /// wakelock keeps the screen technically on (so the OS can't sleep it and pause
  /// the camera) even when not recording. The "tap to wake" hint fades out over
  /// [_blackoutFade] at normal brightness (so it can be read), and only then is
  /// the brightness dropped to minimum — so the screen dims down gently rather
  /// than snapping to black. Waking (tap anywhere) is handled by the cover layer.
  Future<void> _enterBlackout() async {
    if (_blackout) return;
    setState(() {
      _blackout = true;
      _blackoutHint = true; // starts fully visible…
    });
    // Screen state is a major heat/power variable (round 82): log the toggle
    // so recorded sessions can be compared thermally afterwards (round 132).
    _logger?.logBlackout({'on': true});
    // Hide Android's status bar (clock/battery) and navigation bar (the 3 buttons)
    // so the whole screen is truly black. A swipe from an edge briefly reveals them
    // then they auto-hide; tapping to wake restores them in [_exitBlackout].
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Round 293: not when the screen-off timer has let the screen go.
    if (!(_screenIdle?.released ?? false)) await WakelockPlus.enable();
    // …then fades out over [_blackoutFade]: flip the flag on the next frame so
    // the AnimatedOpacity animates 1 → 0 from the start.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _blackout) setState(() => _blackoutHint = false);
    });
    // Once the hint has faded, drop the brightness to minimum (its big saving on
    // LCD panels; OLED already draws ≈ nothing on the black cover).
    _blackoutHintTimer?.cancel();
    _blackoutHintTimer = Timer(_blackoutFade, _applyBlackoutSteadyState);
  }

  /// The blackout's steady-state power savings: preview stream detached at the
  /// camera + brightness at minimum. Split out of [_enterBlackout]'s hint
  /// timer so a scheduled wake — which starts recording underneath a cover
  /// that is ALREADY up — can re-apply it directly (the resumed camera comes
  /// back with the preview attached and compositing frames nobody can see).
  Future<void> _applyBlackoutSteadyState() async {
    if (!_blackout) return;
    // Round 82: dropping brightness alone was measured to save almost
    // nothing — the camera kept producing and compositing preview frames
    // behind the black cover (~1 CPU core). Detach the preview stream at
    // the camera; detection, tracking and photo capture keep running.
    // Skipped while the whole camera is unbound (scheduled sleep): there is
    // no bound preview use-case to detach, only a dead channel call.
    if (!_paused) {
      _controller
          .setPreviewEnabled(false)
          .catchError((Object e) => _logAsyncError('preview_off', e));
    }
    try {
      await ScreenBrightness().setApplicationScreenBrightness(0.0);
    } catch (e) {
      // Some devices reject 0.0 or lack the API; the opaque black cover alone
      // still hides the screen.
      logSwallowed('screen_dim', e);
    }
  }

  /// Leaves blackout: restores the previous screen brightness and the normal UI
  /// (which is rebuilt honouring the user's on-screen display settings — boxes,
  /// info panel, capture flash). Drops the wakelock again only if a session is
  /// not recording (an active recording keeps its own wakelock).
  Future<void> _exitBlackout() async {
    if (!_blackout) return;
    _blackoutHintTimer?.cancel();
    _sleepStatusTimer?.cancel();
    // Reattach the preview stream first (round 82) so the live image is back
    // within ~0.2 s of the wake tap; the native side re-asserts the focus
    // lock and camera fps cap after the reattach. Skipped while the whole
    // camera is unbound (scheduled sleep) — resume() rebinds everything.
    if (!_paused) {
      _controller
          .setPreviewEnabled(true)
          .catchError((Object e) => _logAsyncError('preview_on', e));
    }
    setState(() {
      _blackout = false;
      _blackoutHint = false;
      _sleepStatusVisible = false;
    });
    _logger?.logBlackout({'on': false});
    // Bring back the status/navigation bars (edge-to-edge matches the Activity's
    // default) and the screen brightness.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    try {
      await ScreenBrightness().resetApplicationScreenBrightness();
    } catch (e) {
      logSwallowed('screen_brightness_reset', e);
    }
    // An active recording keeps its own wakelock; so does a scheduled run —
    // even between windows the sleeping app must stay alive for days.
    if (!_recording && _schedule == null) await WakelockPlus.disable();
  }

  void _syncScreenIdle() {
    final active = _cameraHeld && _config.screenOffAfterMin > 0;
    if (active && _screenIdle == null) {
      _screenIdle = ScreenIdle(
        afterMs: _config.screenOffAfterMin * 60000,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      _screenIdleTimer = Timer.periodic(const Duration(seconds: 1), (_) => _screenIdleTick());
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onAnyPointer);
    } else if (!active) {
      _stopScreenIdle();
    } else if (_screenIdle!.released) {
      // A window that starts while the screen is let go turns the hold back on
      // (SessionRecorder.start); let go again.
      unawaited(WakelockPlus.disable());
    }
  }

  void _stopScreenIdle() {
    if (_screenIdle == null) return;
    _screenIdleTimer?.cancel();
    _screenIdleTimer = null;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onAnyPointer);
    _screenIdle = null;
  }

  void _screenIdleTick() {
    final idle = _screenIdle;
    if (idle == null || !idle.tick(DateTime.now().millisecondsSinceEpoch)) return;
    unawaited(WakelockPlus.disable());
    if (mounted && !_blackout) unawaited(_enterBlackout());
  }

  /// Any touch on the screen, dialogs and sheets included.
  void _onAnyPointer(PointerEvent event) {
    if (event is PointerDownEvent) _touchScreenIdle();
  }

  void _touchScreenIdle() {
    if (_screenIdle?.touch(DateTime.now().millisecondsSinceEpoch) ?? false) {
      unawaited(WakelockPlus.enable());
    }
  }
}
