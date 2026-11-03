// FaunaPulse, live recording screen:
// periodic readings (heat, fps, power), the guards that stop a session, the stats panel and problem reports.
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

extension _CameraReadings on _CameraSessionScreenState {
  Future<void> _closeSlowHint({required bool forGood}) async {
    setState(() => _slowPerSecond = null);
    if (!forGood) return;
    _hideSlowHint = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kHideSlowPhoneHintPrefKey, true);
    } catch (e) {
      logSwallowed('slow_hint_save', e);
    }
  }

  Future<void> _toggleStatsExpanded() async {
    setState(() => _statsExpanded = !_statsExpanded);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_statsExpandedKey, _statsExpanded);
    } catch (e) {
      logSwallowed('stats_expanded_save', e);
    }
  }

  /// (Re)creates the periodic sampling timers from the current config. Called
  /// at screen start and again after the settings sheet closes, so an interval
  /// change applies without leaving the screen (round 148). All three streams
  /// are always sampled and logged (owner decision, round 149): the readings
  /// are taken — or maintained per frame — for the live preview anyway, so a
  /// log line costs nothing; only their *display* is opt-in (the summary's
  /// collapsed "Extra graphs"). Safe to rebuild mid-screen: the settings
  /// button is disabled while recording.
  void _rebuildSamplingTimers() {
    _thermalTimer?.cancel();
    _fpsLogTimer?.cancel();
    _powerTimer?.cancel();
    _thermalTimer = Timer.periodic(
      Duration(seconds: _config.thermalSampleSeconds.clamp(1, 600)),
      (_) => _sampleThermal(),
    );
    // Separate, usually faster timer that logs the frame rate for the FPS graph.
    _fpsLogTimer = Timer.periodic(
      Duration(seconds: _config.fpsSampleSeconds.clamp(1, 600)),
      (_) => _sampleFps(),
    );
    // Separate timer that logs battery power (watts) + remaining charge for the
    // end-of-session energy graphs. Its own cadence (default 10 s).
    _powerTimer = Timer.periodic(
      Duration(seconds: _config.powerSampleSeconds.clamp(1, 600)),
      (_) => _samplePower(),
    );
  }

  Future<void> _sampleThermal() async {
    final reading = await DeviceThermal.read();
    // Free storage rides along on the thermal cadence: it changes on the same
    // "slowly, over hours" timescale and needs no timer of its own.
    final storage = await DeviceStorage.read();
    if (!mounted) return;
    _thermalVN.value = reading;
    _storageVN.value = storage;
    // While recording, log the temperature so heat can be reviewed afterwards
    // (plus free storage, so fill rate is visible in the session data).
    if (_recording) {
      _logger?.logThermal({...reading.toJson(), ...storage.toJson()});
      await _checkGuards(reading, storage);
    }
  }

  Future<void> _checkGuards(ThermalReading reading, StorageReading storage) async {
    if (_guardStopping) return;
    int? level;
    if (_config.lowBatteryStopPercent > 0 && reading.isPlugged != true && reading.isCharging != true) {
      try {
        level = await Battery().batteryLevel;
      } catch (e) {
        logSwallowed('guard_battery_level', e);
      }
    }
    final why = guardStopReason(
      batteryPercent: level,
      isPlugged: reading.isPlugged,
      isCharging: reading.isCharging,
      freeBytes: storage.freeBytes,
      lowBatteryPercent: _config.lowBatteryStopPercent,
      storageReserveMb: _config.storageReserveMb,
    );
    if (why == null || !_recording || !mounted) return;
    _guardStopping = true;
    try {
      _logger?.logGuardStop({
        'reason': why,
        'battery_percent': level,
        'free_storage_bytes': storage.freeBytes,
      });
      _logger?.flushNow();
      // Tell a user who is present why the recording ends. The app-wide
      // messenger keeps it visible on the summary pushed next, whose
      // "Stopped by itself" row (from the guard_stop record) keeps the reason.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            why == 'low_battery'
                ? 'Recording stopped: battery at or below ${_config.lowBatteryStopPercent} % (Settings, Stop at battery level).'
                : 'Recording stopped: less than ${_config.storageReserveMb} MB free storage (Settings, Keep free storage).',
          ),
        ),
      );
      if (_schedule != null) {
        await _abortSchedule();
      } else {
        await _stopAndShowSummary();
      }
    } finally {
      _guardStopping = false;
    }
  }

  /// Logs the current (already-computed) detector FPS. Runs on its own timer and
  /// only writes while recording; the value itself is maintained every frame, so
  /// this adds no work to the inference pipeline.
  void _sampleFps() {
    if (!_recording) return;
    // Full per-second perf fingerprint, so an *uncoupled* run still captures the
    // throttle signature (inference time climbing while temperature stays flat).
    // All values are already maintained every frame, so this adds no pipeline
    // work. `fps` (= detector fps) is kept for the existing FPS graph and for
    // sessions recorded before the extra fields existed.
    final trio = _fpsTrioVN.value; // [cameraFps, detectorFps, pipelineFps]
    final perf = _perfVN.value; // [preMs, infMs, postMs]
    double at(List<double> l, int i) => i < l.length ? l[i] : 0.0;
    // While the motion gate keeps the detector asleep, no inference happens —
    // so the inference-derived fields are OMITTED rather than logged as 0 (or,
    // worse, as their last awake values, which is what flat-lined the FPS and
    // inference-time graphs before round 77). Absent = "gate idle, detector
    // off"; present = the detector really ran at that number. Stats read the
    // gaps as missing data, exactly as the owner wants. `gate_idle` makes the
    // state explicit; camera_fps stays, it is real regardless.
    final gateIdle = _gateIdle;
    // Motion-only and time-lapse capture: the detector never runs at all, so
    // the inference-derived fields are omitted even while frames flow (same
    // rule — absent means "detector off", never a logged 0).
    final detectorOff = gateIdle || !_config.detectorEnabled;
    _logger?.logFps({
      if (gateIdle) 'gate_idle': true,
      if (_config.motionOnlyCapture) 'motion_only': true,
      if (_config.timeLapseCapture) 'time_lapse': true,
      if (!detectorOff) ...{
        'fps': _fpsVN.value,
        'detector_fps': at(trio, 1),
        'pipeline_fps': at(trio, 2),
        'pre_ms': at(perf, 0),
        'inf_ms': at(perf, 1),
        'post_ms': at(perf, 2),
        'track_ms': _lastTrackMs,
      },
      'camera_fps': at(trio, 0),
      'engine': _accelerator,
      'analysis_w': _imageWidth,
      'analysis_h': _imageHeight,
      // Auto-throttle state: the applied inference-rate cap and the smoothed
      // inference time it is acting on, so the controller's
      // behaviour is visible in the log and the throttle graph.
      'applied_cap_fps': _appliedCapFps ?? 0,
      if (_throttle != null) 'throttle_inf_ms_ema': _throttle!.infMsEma,
    });
  }

  /// Reads battery power (current × voltage) and remaining charge, and — while
  /// recording — logs a `power` record for the end-of-session energy graphs.
  /// `power_w` is the instantaneous draw; `charge_counter_uah` lets the summary
  /// cross-check the total energy against how much the battery actually drained.
  Future<void> _samplePower() async {
    if (!_recording) return;
    final reading = await DeviceThermal.read();
    if (!_recording) return;
    _logger?.logPower({
      'power_w': reading.powerW,
      'battery_current_ua': reading.batteryCurrentUa,
      'battery_voltage_mv': reading.batteryVoltageMv,
      'charge_counter_uah': reading.chargeCounterUah,
      'is_charging': reading.isCharging,
      // Round 188: any attached power source (a full battery on a power bank
      // reports NOT_CHARGING while plugged) — either flag invalidates the
      // summary's energy series.
      'is_plugged': reading.isPlugged,
    });
  }

  /// Shows the error with the full message (selectable/copyable) and lets the user
  /// create a diagnostic report (saved locally, optionally sent to the developer).
  Future<void> _showErrorReportDialog(String message) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(const Text('Problem detected'), onClose: () => Navigator.of(ctx).pop()),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Selectable so the user can copy the text directly.
              SelectableText(message, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              const Text(
                'You can create a diagnostic report (settings, session log and the '
                "app's recent technical log) and send it to the developer with "
                'Share… (for example with a messaging app or to a cloud drive).',
                // Round 317: white70 like the other windows; black54 was
                // unreadable on the dark dialog (the app always uses the dark
                // theme).
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              // Ask the user to describe the problem first (required).
              final input = await showProblemDescriptionEditor(context);
              if (input == null || !mounted) return;
              await _createReport(message, input);
            },
            child: const Text(
              'Create report',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds and saves the report, then shows its size and offers to send it.
  Future<void> _createReport(
    String message,
    ProblemDescriptionResult input,
  ) async {
    // Brief progress indicator — capturing logcat spawns a process.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    ErrorReport? report;
    try {
      report = await ErrorReporter.build(
        trigger: message,
        userDescription: input.description,
        config: _config,
        sessionLog: _logger?.file,
        attachmentPaths: input.screenshotPaths,
      );
    } catch (e) {
      report = null;
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // dismiss the spinner
    if (report == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not create the report.')),
      );
      return;
    }
    final saved = report;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(const Text('Report ready'), onClose: () => Navigator.of(ctx).pop()),
        // Round 317: the same words as the home screen's window. Reports are
        // kept in the app's private storage, which a computer cannot open
        // over USB, and no screen lists old reports.
        content: Text(
          'The report is ready (${saved.humanSize}). Tap Share… to send it now (for example with '
          'a messaging app or to a cloud drive). After you close this window, you cannot open '
          'this report again (not in the app and not from a computer).',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              ErrorReporter.share(saved);
            },
            child: const Text(
              'Share…',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}
