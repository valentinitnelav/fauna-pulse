// FaunaPulse, live recording screen:
// the settings sheet, the session location, field notes and the setup reminder.
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

extension _CameraSettingsAndNotes on _CameraSessionScreenState {
  void _onLocationUpdate(SessionLocation? best, bool searching) {
    if (!mounted) return;
    _locSearchingVN.value = searching;
    if (!_locationManuallySet && best != null) _locationVN.value = best;
    setState(() {}); // pin button color
  }

  Future<void> _openFieldNotes() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FieldNotesScreen(
          location: _locationVN,
          searching: _locSearchingVN,
          onChangePosition: _openLocationDialog,
        ),
      ),
    );
    final notes = await FieldNotes.load();
    if (mounted) setState(() => _fieldNotes = notes);
  }

  Future<void> _openLocationDialog() async {
    final res = await showDialog<LocationDialogResult>(
      context: context,
      builder: (_) => LocationDialog(
        current: _locationVN,
        searching: _locSearchingVN,
        previous: _previousLocation,
        onSearchAgain: () async {
          _locationManuallySet = false;
          return await _locator?.start(
                requestPermission: true,
                goalM: _fieldNotes.gpsGoalM.toDouble(),
                maxWaitMs: kGpsMaxWaitMs,
              ) ??
              false;
        },
      ),
    );
    if (res == null || !mounted) return;
    setState(() {
      if (res.location == null) {
        // Removed on purpose: also stop searching so a late fix can't refill.
        _locator?.stop();
        _locSearchingVN.value = false;
        _locationManuallySet = true;
      } else {
        _locationManuallySet = res.location!.source != 'gps';
      }
      _locationVN.value = res.location;
    });
  }

  /// Remembers the location a recording actually used, so the next session
  /// can offer it as a one-tap "use last session's" default.
  Future<void> _persistSessionLocation() async {
    final loc = _locationVN.value;
    if (loc == null) return;
    _previousLocation = loc;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_lastLocationKey, jsonEncode(loc.toJson()));
    } catch (e) {
      logSwallowed('location_save', e);
    }
  }

  /// Shows the setup reminder dialog unless the user has dismissed it for good.
  /// Persists the choice so a returning user goes straight to the preview.
  Future<void> _maybeShowSessionInfo() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(kHideSessionInfoPrefKey) ?? false) return;
    if (!mounted) return;
    final dontShowAgain = await showDialog<bool>(
      context: context,
      builder: (_) => const SessionInfoDialog(),
    );
    if (dontShowAgain == true) {
      await prefs.setBool(kHideSessionInfoPrefKey, true);
    }
  }

  Future<void> _openSettings() async {
    // Pause the camera + detector while the settings sheet is open so the phone
    // isn't heating from inference the user can't even see behind the sheet.
    await _controller.pause();
    _paused = true;
    if (!mounted) return;
    _closeUnappliedSnack();
    final draft = SettingsDraft();
    final updated = await showModalBottomSheet<SessionConfig>(
      context: context,
      isScrollControlled: true,
      // Fully opaque: black87 let the frozen preview bleed through, making
      // the sheet hard to read over bright scenes. Near-black (not pure
      // black) keeps a subtle sheet-vs-scrim distinction.
      backgroundColor: const Color(0xFF141414),
      builder: (_) => SettingsSheet(
        config: _config,
        draft: draft,
        streamResolutions: _streamResolutions,
        cameraFrameRates: _probes.cameraFrameRates,
        analysisCeiling: _analysisCeiling,
        sensorWidth: _captureWidth,
        sensorHeight: _captureHeight,
        cameraDiagnostics: _cameraDiagnostics,
      ),
    );
    // Round 294: before the resume below, which starts the camera again.
    if (updated != null) _pushStillZsl(updated);
    if (mounted && _paused) {
      _paused = false;
      await _controller.resume();
    }
    // The chosen model may have been deleted from the sheet (Download &
    // import models…): check its file again, nothing more.
    if (updated == null) {
      _recheckModelFile();
      // Round 313: closed with Back, a tap above it or a swipe down: say that
      // the changes were not used, and offer them, instead of losing them
      // silently (which looked like "my value jumped back").
      final changed = draft.value;
      final before = jsonEncode(_config.toJson());
      if (changed != null &&
          mounted &&
          jsonEncode(changed.toJson()) != jsonEncode(_config.normalizedFpsCaps().copyWith(folderName: _config.folderName).toJson())) {
        _unappliedSnack.show(
          ScaffoldMessenger.of(context),
          SnackBar(
            content: const Text('Settings closed without Apply: your changes are not used.'),
            duration: const Duration(seconds: 8),
            // A bar with a button stays until tapped unless told otherwise.
            persist: false,
            action: SnackBarAction(label: 'Apply', onPressed: () => unawaited(_applyLate(changed, before))),
          ),
        );
      }
      return;
    }
    await _applySettings(updated);
  }

  void _closeUnappliedSnack() => _unappliedSnack.close();

  /// The bar's Apply: only while nothing records and nothing else changed the
  /// settings meanwhile (a lens switch, a model choice), else it says so.
  Future<void> _applyLate(SessionConfig changed, String before) async {
    _unappliedSnack.forget();
    if (!mounted) return;
    if (_recording || _schedule != null || jsonEncode(_config.toJson()) != before) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not applied: something changed meanwhile. Open Settings again.')),
      );
      return;
    }
    // The photo source (zero shutter lag) is set at a camera start: restart
    // the camera only when it changes.
    if (_stillZslFor(changed) != _stillZslFor(_config)) {
      await _controller.pause();
      _pushStillZsl(changed);
      await _controller.resume();
    }
    await _applySettings(changed);
  }

  /// Stores [updated] (the Settings sheet's result) and pushes it to the live
  /// preview: tracker, throttle, thresholds, gate, camera cap, time-lapse.
  Future<void> _applySettings(SessionConfig updated) async {
    if (!mounted) return;
    // Used at the next camera start (a no-op when unchanged).
    _pushStillZsl(updated);
    await updated.save();
    final modelChanged = updated.modelPath != _config.modelPath;
    setState(() {
      _config = updated;
      // Rebuild the tracker so an algorithm or tuning change applies. Safe:
      // the settings button is disabled while recording, so ids can never
      // restart mid-log; the preview tracks it drops are cosmetic.
      _tracker = _buildTracker(_fpsVN.value);
      _frame.tracker = _tracker;
      // The rebuilt tracker starts empty, so any boxes still on screen are
      // orphans. In the no-AI modes (motion / time-lapse) no detector frame
      // ever repaints this notifier, so without this reset the last AI-mode
      // box stayed frozen on the preview after a mode switch (round 144).
      _tracksVN.value = const [];
      _rebuildThrottle();
      // Show "reading…" again while we re-probe the new model's input size.
      if (modelChanged) {
        _modelInputSize = null;
        _modelInputProbed = false;
      }
    });
    if (modelChanged) _refreshModelInputSize();
    _recheckModelFile();
    if (updated.detectorEnabled && _cameraModelPath.isEmpty) unawaited(_askForDetector());
    // Apply a sampling-interval change immediately.
    _rebuildSamplingTimers();
    await _controller.setThresholds(
      confidenceThreshold: updated.confidenceThreshold,
      iouThreshold: updated.iouThreshold,
    );
    _pushMotionGate();
    _pushCameraFpsCap();
    _pushTimeLapse();
  }
}
