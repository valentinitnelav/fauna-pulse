// FaunaPulse, live recording screen:
// scheduled recording (time windows, sleeping between them).
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

extension _CameraSchedule on _CameraSessionScreenState {
  // --- Scheduled recording --------------------------------------------------

  /// Spells out the run before starting it (windows, days, and that the
  /// screen goes dark between windows) — a scheduled run can hold the phone
  /// for days, so a stray tap must not launch one silently.
  Future<void> _confirmStartSchedule() async {
    if (!_config.isScheduleValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The schedule cannot start: windows overlap or end before they '
            'start. Fix them in Session settings (Setup tab, Scheduled '
            'recording).',
          ),
        ),
      );
      return;
    }
    final windows = _config.scheduleWindows.map((w) => w.label).join(', ');
    final days = _config.scheduleDays;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(const Text('Start scheduled run?'), onClose: () => Navigator.of(ctx).pop(false)),
        content: Text(
          'Recording windows: $windows\n'
          'Days: $days\n\n'
          'Each window is saved as its own session. Between windows the '
          'screen goes dark and the camera turns off to save power. The screen '
          'may also be switched off; keep the app running (do not close it) '
          'and the phone on power. Tap the dark screen to see the status; the '
          'record button stops the run.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Start',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await _startSchedule();
  }

  Future<void> _startSchedule({bool batteryNudge = true}) async {
    final plan = SchedulePlan(
      windows: _config.scheduleWindows,
      days: _config.scheduleDays,
      startedAt: DateTime.now(),
    );
    if (plan.phaseAt(DateTime.now()) == SchedulePhase.finished) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "All of today's windows are already over, so there is nothing to "
            'record. '
            'Adjust the windows or the number of days in Settings.',
          ),
        ),
      );
      return;
    }
    // Same one-time battery-optimization nudge as a manual session — even
    // more important here, where the app may sleep unattended overnight.
    // Round 298: not after the "Before you record" sheet, which shows it.
    if (batteryNudge) await _ensureUnrestricted();
    if (!mounted) return;
    setState(() {
      _schedule = plan;
      _scheduleSessionsDone = 0;
      _storageSkipSlot = null;
      _storageSkipNote = null;
    });
    _pushCameraHold();
    // Protect the WHOLE run up front (not just each window): the foreground
    // service + wakelock must already be up if the run starts with a sleep
    // phase (e.g. started at 22:00 for a 06:00 window). Both are idempotent,
    // so the per-window SessionRecorder.start() calls are harmless.
    await Permission.notification.request();
    await RecordingKeepAlive.start();
    await WakelockPlus.enable();
    _scheduleTick();
  }

  /// The reconciler: compares what the plan says SHOULD be happening against
  /// what IS happening and transitions if they differ, then re-arms the timer
  /// for the next boundary (capped at 60 s). Everything derives from the wall
  /// clock on each call, so a missed/late tick — OS doze, a clock jump, a
  /// failed wake — is corrected by the next one instead of compounding.
  void _scheduleTick() {
    final plan = _schedule;
    if (plan == null) return;
    if (!_scheduleBusy && !_recorder.stopping) {
      switch (plan.phaseAt(DateTime.now())) {
        case SchedulePhase.recording:
          if (!_recording) {
            final slot = plan.activeSlotAt(DateTime.now());
            if (slot != null) _wakeForWindow(slot);
          }
        case SchedulePhase.sleeping:
          if (_recording) {
            _endWindow();
          } else if (!_scheduleSleeping) {
            // Sleep-first start (or a wake that found its window already
            // over): park the camera and go dark until the next window.
            _enterScheduledSleep();
          }
        case SchedulePhase.finished:
          _finishSchedule();
          return; // run over — don't re-arm
      }
    }
    _armScheduleTimer();
  }

  void _armScheduleTimer() {
    _scheduleTimer?.cancel();
    final plan = _schedule;
    if (plan == null) return;
    final now = DateTime.now();
    // Aim just past the next boundary so the tick lands cleanly inside the
    // new phase; never sleep longer than 60 s so doze gaps, clock changes and
    // failed wakes are retried promptly.
    var delay = const Duration(seconds: 60);
    final next = plan.nextTransitionAt(now);
    if (next != null) {
      final toNext = next.difference(now) + const Duration(milliseconds: 500);
      if (toNext < delay) delay = toNext;
    }
    if (delay <= Duration.zero) delay = const Duration(seconds: 1);
    _scheduleTimer = Timer(delay, _scheduleTick);
  }

  /// A window's end: close this window's session normally (its own folder +
  /// summary data, `ended_normally: true`) WITHOUT the summary screen — the
  /// user is asleep/away — and go into scheduled sleep until the next window.
  Future<void> _endWindow() async {
    _scheduleBusy = true;
    try {
      // Keep the foreground service + wakelock: the run isn't over, and the
      // sleeping app must survive until the next window (MIUI kills easily).
      await _stopRecording(normal: true, retainKeepAlive: true);
      _scheduleSessionsDone++;
      await _enterScheduledSleep();
    } finally {
      _scheduleBusy = false;
    }
  }

  /// Scheduled sleep = the real between-windows power save: the camera is
  /// FULLY unbound (analysis + photo capture + preview — `pause()` is the
  /// same call the summary/settings cool-down uses), and the blackout cover
  /// goes up with the sleep-status variant (tap shows status, never wakes).
  Future<void> _enterScheduledSleep() async {
    if (!_paused) {
      try {
        await _controller.pause();
        _paused = true;
      } catch (e) {
        _logAsyncError('schedule_pause', e);
      }
    }
    if (!mounted) return;
    setState(() => _scheduleSleeping = true);
    await _enterBlackout();
    // Show the status once on entry (next window, day X/Y) at readable
    // brightness; it re-dims by itself like a tap would.
    _showSleepStatus();
  }

  /// A window's start: rebind the camera (cover stays up), wait until frames
  /// actually flow, then start this window's session and re-assert the
  /// blackout steady state. On a wake failure the camera is parked again and
  /// the ≤60 s tick retries — a transient camera error at 06:00 must not
  /// silently cost the whole morning window.
  Future<void> _wakeForWindow(ScheduleSlot slot) async {
    _scheduleBusy = true;
    try {
      // Round 319: no window starts with free storage already below "Keep
      // free storage" (the guard would stop it at once and end the run). No
      // pop-up, as the user is away. The camera stays parked and the next tick
      // (at most 60 s) checks again, so space freed meanwhile still counts.
      final storage = await DeviceStorage.read();
      if (!mounted || _schedule == null) return;
      final free = storage.freeBytes;
      if (storageBelowReserve(free, _config.storageReserveMb)) {
        _skipWindowForStorage(slot, free!);
        return;
      }
      if (_paused) {
        await _controller.resume();
        _paused = false;
      }
      final gotFrames = await _waitForFrames(
        const Duration(seconds: 20),
        active: () => _schedule != null,
      );
      if (!mounted || _schedule == null) return;
      if (!gotFrames) {
        logSwallowed(
          'schedule_wake',
          'Camera produced no frames within 20 s of the scheduled wake — '
              'parked again, retrying on the next tick.',
        );
        try {
          await _controller.pause();
          _paused = true;
        } catch (e) {
          _logAsyncError('schedule_wake_pause', e);
        }
        return;
      }
      _sleepStatusTimer?.cancel();
      setState(() {
        _scheduleSleeping = false;
        _sleepStatusVisible = false;
      });
      _storageSkipSlot = null;
      _storageSkipNote = null;
      await _startRecording(focusMode: _focusModeForLog(), scheduleSlot: slot);
      // The cover never came down: put the display + preview back into the
      // measured power-save state now that the camera is running again. (If
      // the cover happens to be down — user was watching — recording proceeds
      // visibly and the moon button re-darkens as usual.)
      if (_blackout) await _applyBlackoutSteadyState();
    } finally {
      _scheduleBusy = false;
    }
  }

  /// Logs a window skipped for low free storage and shows why, once per
  /// window: a snack bar like the guard's, and a line in the sleep status
  /// (kept until a window starts).
  void _skipWindowForStorage(ScheduleSlot slot, int freeBytes) {
    if (slot == _storageSkipSlot) return;
    _storageSkipSlot = slot;
    final reserve = _config.storageReserveMb;
    debugPrint(
      'FaunaPulse schedule: window d${slot.day + 1}w${slot.windowIndex + 1} not started: '
      '$freeBytes bytes free, below the $reserve MB reserve (storage_low)',
    );
    setState(
      () => _storageSkipNote =
          'Window not started: ${formatMegabytes(freeBytes)} free, less than $reserve MB '
          '(Settings, Keep free storage).',
    );
    // Under the dark cover: show the status (with this line) for a few seconds.
    if (_scheduleSleeping) _showSleepStatus();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(
          'Scheduled window not started: less than $reserve MB of storage is free (Settings, Keep free storage). '
          'It still starts if space is freed before the window ends.',
        ),
      ),
    );
  }

  /// Polls [_lastStreamEventMs] (fed by every native stream event, including
  /// gate-idle heartbeats) until a frame newer than the call arrives.
  /// [active] aborts the wait early when the state it belongs to is gone —
  /// the scheduled wake passes the run's liveness, the time-lapse wake
  /// (round 163) the recording's.
  Future<bool> _waitForFrames(
    Duration timeout, {
    required bool Function() active,
  }) async {
    final since = DateTime.now().millisecondsSinceEpoch;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted || !active()) return false;
      if (_lastStreamEventMs >= since) return true;
    }
    return false;
  }

  /// The run's natural end: close everything, release the keep-alive service
  /// + wakelock, restore the screen and tell the user what was recorded. The
  /// per-window sessions are on the Sessions screen (no summary stack).
  Future<void> _finishSchedule() async {
    final plan = _schedule;
    if (plan == null) return;
    _scheduleBusy = true;
    try {
      _scheduleTimer?.cancel();
      _scheduleTimer = null;
      if (_recording) {
        // Final window ran to the end of the run: a plain stop releases the
        // keep-alive service and wakelock as usual.
        await _stopRecording(normal: true);
        _scheduleSessionsDone++;
      } else {
        try {
          await RecordingKeepAlive.stop();
        } catch (e) {
          logSwallowed('schedule_keepalive_stop', e);
        }
      }
      final recorded = _scheduleSessionsDone;
      _scheduleSleeping = false;
      // Clear the run BEFORE exiting blackout so its wakelock guard
      // (`_schedule == null`) really drops the wakelock.
      setState(() => _schedule = null);
      _pushCameraHold();
      await _exitBlackout();
      if (_paused && mounted) {
        _paused = false;
        await _controller.resume();
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: DialogTitle(const Text('Scheduled run complete'), onClose: () => Navigator.of(ctx).pop()),
          content: Text(
            '$recorded session${recorded == 1 ? '' : 's'} recorded. '
            'Each window is its own session. Find them under "Sessions" at '
            'the bottom of the home screen.',
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } finally {
      _scheduleBusy = false;
    }
  }

  /// Confirm-guarded abort of the whole run (record button, or the sleep
  /// overlay's stop button).
  Future<void> _confirmAbortSchedule() async {
    // Freeze the sleep-status auto-dim while the dialog is up — its 8 s timer
    // would otherwise drop the brightness to 0 mid-question.
    _sleepStatusTimer?.cancel();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(const Text('Stop the scheduled run?'), onClose: () => Navigator.of(ctx).pop(false)),
        content: Text(
          _recording
              ? 'The current window will be closed and its summary shown. '
                    'No further windows will be recorded.'
              : 'No further windows will be recorded.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep running'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Stop run',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await _abortSchedule();
    } else if (mounted && _scheduleSleeping) {
      // Kept running: restart the status display so it re-dims normally.
      _showSleepStatus();
    }
  }

  /// Ends the run right now. Mid-window the user is present, so this follows
  /// the manual-stop path (summary screen for the aborted window); mid-sleep
  /// it just releases everything and brings the live preview back.
  Future<void> _abortSchedule() async {
    _scheduleBusy = true;
    try {
      _scheduleTimer?.cancel();
      _scheduleTimer = null;
      _sleepStatusTimer?.cancel();
      final wasSleeping = _scheduleSleeping;
      _scheduleSleeping = false;
      setState(() => _schedule = null);
      _pushCameraHold();
      if (_recording) {
        await _stopAndShowSummary();
      } else if (wasSleeping) {
        try {
          await RecordingKeepAlive.stop();
        } catch (e) {
          logSwallowed('schedule_keepalive_stop', e);
        }
        await _exitBlackout();
        if (_paused && mounted) {
          _paused = false;
          await _controller.resume();
        }
      }
    } finally {
      _scheduleBusy = false;
    }
  }

  /// Tap on the dark cover while scheduled-sleeping: show the status (day,
  /// next window, sessions so far) at readable brightness for a few seconds,
  /// then drop back to dark. Deliberately NOT a full wake — the camera stays
  /// off and the cover stays up; only the stop button leaves the run.
  void _showSleepStatus() {
    _sleepStatusTimer?.cancel();
    if (mounted) setState(() => _sleepStatusVisible = true);
    ScreenBrightness().resetApplicationScreenBrightness().catchError(
      (Object e) => logSwallowed('sleep_status_brightness', e),
    );
    _sleepStatusTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || !_scheduleSleeping) return;
      setState(() => _sleepStatusVisible = false);
      ScreenBrightness()
          .setApplicationScreenBrightness(0.0)
          .catchError((Object e) => logSwallowed('sleep_status_dim', e));
    });
  }

  /// The sleep overlay's status text, recomputed on each build from the plan.
  String _sleepStatusText() {
    final plan = _schedule;
    if (plan == null) return '';
    return sleepStatusText(
      plan: plan,
      now: DateTime.now(),
      sessionsDone: _scheduleSessionsDone,
      storageSkipNote: _storageSkipNote,
      storageSkipSlot: _storageSkipSlot,
    );
  }

  /// Content of the blackout cover during scheduled sleep: the run status +
  /// a stop button, shown for a few seconds after a tap (or on sleep entry)
  /// and hidden the rest of the time (pure black). The button only accepts
  /// taps while visible — an invisible tappable stop button under a black
  /// screen would be an accidental-abort trap.
  Widget _sleepStatusOverlay() => IgnorePointer(
    ignoring: !_sleepStatusVisible,
    child: AnimatedOpacity(
      opacity: _sleepStatusVisible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 400),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bedtime_outlined, color: Colors.white38, size: 36),
          const SizedBox(height: 12),
          Text(
            _sleepStatusText(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 15,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: _confirmAbortSchedule,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              side: const BorderSide(color: Colors.redAccent),
            ),
            child: const Text('Stop scheduled run'),
          ),
        ],
      ),
    ),
  );
}
