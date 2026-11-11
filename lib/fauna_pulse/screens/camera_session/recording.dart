// FaunaPulse, live recording screen:
// starting and stopping a recording (REC), and the summary afterwards.
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

extension _CameraRecording on _CameraSessionScreenState {
  Future<void> _toggleRecording() async {
    // The stop path stays unguarded: the session-length timer also calls this.
    if (_recording) return _toggleRecordingUnguarded();
    if (_recStartBusy) return;
    _recStartBusy = true;
    try {
      await _toggleRecordingUnguarded();
    } finally {
      _recStartBusy = false;
    }
  }

  Future<void> _toggleRecordingUnguarded() async {
    // A tap while the previous stop sequence is still tearing down does
    // nothing (it would otherwise start a new session mid-teardown).
    // Same for a tap while a start is still running ([_recording] is false
    // until it ends): it would open the start path, and a second session, again.
    if (_recorder.stopping || _recorder.starting) return;
    if (_stopInProgress || _summaryFlowBusy) return;
    // While a scheduled run is active the record button means "stop the whole
    // run", never "stop this one window" — confirm-guarded, since it ends a
    // possibly multi-day deployment.
    if (_schedule != null) {
      await _confirmAbortSchedule();
      return;
    }
    // Don't allow recording to start until calibration (the one-time full-res
    // probe that establishes the true ROI resolution) has finished. Before that
    // the ROI pixel size — logged at session start — isn't known yet.
    if (!_recording && _calibrating) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Still calibrating. Please wait a moment.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    // Round 268: AI mode cannot record without a detection model.
    if (!_recording && _config.detectorEnabled && _cameraModelPath.isEmpty) {
      await _askForDetector();
      return;
    }
    // Round 126: remember the location this recording uses (fire-and-forget)
    // so the next session can offer it as a one-tap default.
    if (!_recording) unawaited(_persistSessionLocation());
    if (_recording) {
      await _stopAndShowSummary();
    } else if (await beforeRecordSheetEnabled()) {
      // Round 298: one "Before you record" sheet (field notes, what and when,
      // phone for the field) replaces the battery nudge and the schedule
      // confirmation; switched off, the older pop-ups below remain.
      if (!await _showBeforeRecord() || !mounted) return;
      if (!await _enoughStorageToStart() || !mounted) return;
      if (_config.scheduleEnabled) {
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
        await _startSchedule(batteryNudge: false);
      } else {
        await _startRecording(focusMode: _focusModeForLog());
      }
    } else if (_config.scheduleEnabled) {
      // Scheduled mode: the record button launches the whole windows×days run
      // (after a confirm dialog spelling out what will happen) instead of a
      // single manual session.
      if (!await _enoughStorageToStart()) return;
      await _confirmStartSchedule();
    } else {
      // One-time nudge to exempt the app from battery optimization, so a long
      // unattended session isn't killed by the OS / an OEM battery manager.
      if (!await _enoughStorageToStart()) return;
      await _ensureUnrestricted();
      if (!mounted) return;
      // Recording starts in a single tap; the focus state (manual/auto/fixed) is
      // whatever the user set via the focus button, and is logged for the record.
      await _startRecording(focusMode: _focusModeForLog());
    }
  }

  /// Round 319 (stress finding n53): with free storage already below "Keep free
  /// storage", a started recording was stopped by the guard a few seconds
  /// later. A start by the user is blocked with a window that says why; read
  /// again here, as the sampled value can be one sample interval old. Unknown
  /// readings never block.
  Future<bool> _enoughStorageToStart() async {
    final storage = await DeviceStorage.read();
    if (!mounted) return false;
    _storageVN.value = storage;
    final free = storage.freeBytes;
    if (!storageBelowReserve(free, _config.storageReserveMb)) return true;
    await showNotEnoughStorageDialog(context, freeBytes: free!, reserveMb: _config.storageReserveMb);
    return false;
  }

  /// Round 298: the "Before you record" sheet; "Change" opens the field notes
  /// or the settings and shows the sheet again. True when Start was pressed.
  Future<bool> _showBeforeRecord() async {
    while (true) {
      if (!mounted) return false;
      final loc = _locationVN.value;
      final action = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: const Color(0xFF141414),
        builder: (_) => BeforeRecordSheet(
          positionLine: loc == null ? 'No position yet.' : 'Position: ${loc.label}',
          fieldSummary: _fieldNotes.summary,
          plan: planSentence(_config),
          scheduled: _config.scheduleEnabled,
          storageReserveMb: _config.storageReserveMb,
        ),
      );
      if (!mounted) return false;
      switch (action) {
        case 'notes':
          await _openFieldNotes();
        case 'settings':
          await _openSettings();
        case 'start':
          return true;
        default:
          return false;
      }
    }
  }

  /// The manual stop path: end the session normally and review its summary.
  /// Shared by the record-button stop, the [_sessionTimer] timed end, and a
  /// schedule abort mid-window (the user is present in all three).
  Future<void> _stopAndShowSummary() async {
    if (_summaryFlowBusy) return;
    _summaryFlowBusy = true;
    try {
      await _stopAndShowSummaryUnguarded();
    } finally {
      _summaryFlowBusy = false;
    }
  }

  Future<void> _stopAndShowSummaryUnguarded() async {
    // A timed session end arrives here straight from [_sessionTimer] with the
    // blackout cover still up: the summary would otherwise be pushed on top of
    // it at minimum window brightness, with no cover left to tap (the window
    // brightness override outlives this route — it is per-Activity, and the
    // whole app is one Activity). No-op when not blacked out.
    await _exitBlackout();
    final logFile = _logger?.file;
    await _stopRecording(normal: true);
    if (!mounted || logFile == null) return;
    // Pause the camera + detector while reviewing the summary so the phone
    // stops heating — inference is the hot part and isn't needed here. Resume
    // it when the user returns to the live preview.
    await _controller.pause();
    _paused = true;
    if (!mounted) return;
    // The summary shows the headline numbers immediately (read cheaply from
    // the first/last log lines); the heavier graphs are computed only when the
    // user taps a button there.
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SessionSummaryScreen(logFile: logFile)),
    );
    // The summary's photo viewer saves its "1:1" chip into the stored config
    // (round 313): take it over, or the next save of this screen's own copy
    // (lens switch, model choice, Settings) would write the old value back.
    final saved = await SessionConfig.load();
    if (mounted && saved.cropSquareLock != _config.cropSquareLock) {
      setState(() => _config = _config.copyWith(cropSquareLock: saved.cropSquareLock));
    }
    if (mounted && _paused) {
      _paused = false;
      await _controller.resume();
    }
  }

  /// If the app isn't already exempt from battery optimization, explain once (per
  /// install) why that matters for long unattended field sessions and offer to open
  /// system settings. Never blocks recording: whatever the user chooses, the
  /// session still starts. Skipped entirely on devices already exempt.
  Future<void> _ensureUnrestricted() async {
    if (await RecordingKeepAlive.isUnrestricted()) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_batteryOptPromptedKey) == true) return;
    if (!mounted) return;
    final allow = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(const Text('Keep recording alive?'), onClose: () => Navigator.of(ctx).pop(false)),
        content: const Text(
          'For long or unattended sessions (hours or days), Android can stop '
          'the app in the background and end your recording. The "battery '
          'managers" of some phone makers do this most often.\n\n'
          'On the next screen, find FaunaPulse and choose "Unrestricted" or '
          '"Don’t optimize" if reliable unattended recording matters. '
          'On some phones you may also need to enable "Autostart" '
          'for this app in the system settings.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Open settings',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    // Remember we've asked, so we don't nag before every session.
    await prefs.setBool(_batteryOptPromptedKey, true);
    if (allow == true) {
      await RecordingKeepAlive.requestUnrestricted();
    }
  }

  /// [scheduleSlot] is set when this session is one window of a scheduled run:
  /// the folder gets a `_d<day>w<window>` suffix so the per-window sessions
  /// sort readably, the start record carries a `schedule` block, and the
  /// [_sessionTimer] auto-end is NOT armed (the window's end time governs —
  /// the default 60-min session length must not truncate a 4-hour window).
  Future<void> _startRecording({
    required String focusMode,
    ScheduleSlot? scheduleSlot,
  }) async {
    // SessionRecorder.start throws on a second start; a caller that slipped
    // past the REC guard (or a schedule tick) just does nothing here.
    if (_recording || _recorder.starting) return;
    _closeUnappliedSnack();
    _tracker.reset();

    // The session folder, logger, photo scheduler, wakelock and keep-alive
    // service are all set up by [SessionRecorder.start] (round 73, review
    // B6b); this method supplies the screen-state pieces: the start-record
    // metadata, the capture wiring, and the log-write-failure banner.
    _logWriteError = null;
    // Round 298: the phone settings that matter in the field, for the record.
    final phoneState = await PhoneSettings.read();
    // Round 302: the site photos waiting for this Start (moved in below).
    List<String> siteNames;
    try {
      siteNames = [for (final f in await waitingSitePhotos()) f.uri.pathSegments.last];
    } catch (e) {
      logSwallowed('site_photos_list', e);
      siteNames = const [];
    }
    if (!mounted) return;
    await _recorder.start(
      folderName: scheduleSlot == null
          ? _config.folderName
          : '${_config.folderName}'
                '_d${scheduleSlot.day + 1}w${scheduleSlot.windowIndex + 1}',
      onLogWriteError: (error) {
        if (!mounted) return;
        setState(() {
          _logWriteError =
              'Cannot write to the session log (storage full or removed?). '
              'The session keeps running, but detections may no longer be '
              'saved. Free up storage or stop the session.';
          _errorBannerDismissed = false;
        });
      },
      onStartReadings: (thermal, storage) {
        if (!mounted) return;
        _thermalVN.value = thermal;
        _storageVN.value = storage;
      },
      startMetadata: () => {
        'model_path': _config.modelPath,
        'task': _config.task.name,
        'use_gpu': _config.useGpu,
        'cpu_threads': _config.cpuThreads,
        // What was actually used (vs the request above). CPU fallback happens
        // per model when the GPU backend can't compile its graph — int8 models
        // CAN run on GPU (verified round 77, session_120). On the CPU also
        // cpu_16bit (round 367).
        ...engineRecordFields(_accelerator, _cpuFp16),
        'camera_full_width_px': _captureWidth,
        'camera_full_height_px': _captureHeight,
        // Round 121: the dims above load instantly from the persistent
        // calibration cache; this flags a recording that started before the
        // live test photo confirmed them (near-certainly identical, but the
        // science log says where the number came from).
        if (_probes.captureDimsFromCache) 'capture_dims_from_cache': true,
        // Round 126: the session's single location fix ('source' says gps /
        // manual / previous). Stripped from problem-report log samples.
        if (_locationVN.value != null) 'location': _locationVN.value!.toJson(),
        // Round 297: field notes in FaunaLapse's form (every key, null when
        // empty); phone maker and model are filled from `device`.
        'field': _fieldNotes.recordBlock(location: _locationVN.value, sitePhotos: siteNames),
        // Round 298: airplane mode, radios, location, Stay awake, battery
        // limits (FaunaLapse's phone_state keys).
        'phone_state': phoneState.toJson(),
        // Which rear lens was in use for this session. zoom factor 1.0 = the main
        // wide lens; 0.5 = ultra-wide; 2.0/3.0 = telephoto. The label is the
        // human-readable lens name shown on the switch button.
        'selected_lens_zoom': _lenses.isNotEmpty
            ? _lenses[_lensIndex].zoomFactor
            : _config.selectedLensZoom,
        if (_lensLabel.isNotEmpty) 'selected_lens_label': _lensLabel,
        // Focus mode chosen for this session: 'manual' (locked, recommended),
        // 'auto' (continuous autofocus), or 'fixed' (fixed-focus lens). For a
        // locked focus we also log the 0..1 distance (0 = far/infinity, 1 = near).
        'focus_mode': focusMode,
        if (focusMode == 'manual') 'focus_value': _focusValue,
        // A scheduled wake starts recording underneath a blackout cover that
        // is already up; without this flag such a session would look
        // screen-on until the first blackout toggle record (round 132).
        if (_blackout) 'blackout_at_start': true,
        'confidence_threshold': _config.confidenceThreshold,
        'iou_threshold': _config.iouThreshold,
        'step_seconds': _config.stepSeconds,
        'duration_seconds': _config.durationSeconds,
        'session_minutes': _config.sessionMinutes,
        // Effective (live) tracker params: trackBuffer and minHitsToConfirm here
        // are the *frame counts* derived from the user's occlusion/min-hit seconds
        // at the current FPS — not the static defaults. The seconds the user
        // actually set are in the `config` block (occlusionSeconds, minHitsSeconds).
        // Includes an `algorithm` key (round 105: bytetrack or cbiou) so
        // post-processing knows which tracker produced this session's ids.
        'tracker_params': _tracker.effectiveParamsJson(),
        // ROI sizes are expressed against the full-resolution photo that is
        // actually saved (capture dims); the smaller analysis frame fed to the
        // detector is logged separately for context.
        'roi': _roi.toLogJson(_roiLogDims.$1, _roiLogDims.$2),
        // Which source the ROI dims above refer to ('fast' = analysis
        // frame, 'still' = high-res photo; frozen wire names) — in auto
        // mode it depends on the box size.
        'roi_source': _activePath.wireName,
        // Exact side of the file this box would save (crop snap + max-side cap),
        // so post-processing never has to re-derive it from the fraction.
        'saves_px': _savedSideNow,
        // Round 109: the ROI side in the STREAM grid — the ÷32 number the user
        // saw on screen (the `roi` block above may be a high-res-frame
        // projection of the same square, which reads confusingly large;
        // session_6).
        'roi_side_stream_px': savedSidePx(
          _roi.sideFraction,
          _imageWidth,
          _imageHeight,
        ),
        'analysis_frame_width_px': _imageWidth,
        'analysis_frame_height_px': _imageHeight,
        'inference_fps': _config.effectiveInferenceFps,
        'fps_sample_seconds': _config.fpsSampleSeconds,
        'thermal_sample_seconds': _config.thermalSampleSeconds,
        'power_sample_seconds': _config.powerSampleSeconds,
        // Which slot of a scheduled run this session is (1-based for humans);
        // absent for a manual session. The windows themselves are in `config`.
        if (scheduleSlot != null && _schedule != null)
          'schedule': {
            'day': scheduleSlot.day + 1,
            'days_total': _schedule!.days,
            'window': scheduleSlot.windowIndex + 1,
            'windows_per_day': _schedule!.windows.length,
            'window_start':
                _schedule!.windows[scheduleSlot.windowIndex].startLabel,
            'window_end': _schedule!.windows[scheduleSlot.windowIndex].endLabel,
          },
        // Full user configuration as one self-describing block, so the end-of-session
        // summary can list *every* setting the user chose (and any setting added in
        // future automatically appears) without each one needing its own top-level
        // key here. The individual keys above are kept for existing readers and for
        // sessions recorded before this block existed.
        'config': _config.toJson(),
        // Which of the config keys above had no effect under this session's
        // capture trigger (round 147). Additive on purpose: the config values
        // keep their normal types so downstream analysis code never breaks on
        // absent fields or type changes — filter on this list (or on
        // captureTrigger) to know what applied.
        'config_not_applicable': notApplicableConfigKeys(
          _config.captureTrigger,
          saveAs: _config.timeLapseSaveAs,
          liveAiVideo: _config.liveAiVideo,
        ),
      },
      captureBuilder: (framesDir, fileToken) => RoiCaptureScheduler(
        framesDir: framesDir,
        sessionToken: fileToken,
        stepMs: (_config.stepSeconds * 1000).round(),
        durationMs: (_config.durationSeconds * 1000).round(),
        // The scheduler picks the source PER PHOTO (chooseCapturePath): the fast
        // live-frame crop when it meets the minimum saved size, otherwise a
        // full-resolution high-res photo (briefly stalls the camera).
        mode: _config.captureMode,
        targetPx: _config.targetRoiSavedPx,
        streamDims: () => (_imageWidth, _imageHeight),
        highResDims: () => (_captureWidth, _captureHeight),
        fastCaptureFn: () => _controller.captureRoiFromFrame(
          cx: _roi.centerX,
          cy: _roi.centerY,
          side: _roi.sideFraction,
          maxPx: _config.targetRoiSavedPx,
        ),
        // Round 108: pair each high-res photo with the trigger-moment live
        // crop (they land ~0.76 s late on this phone — measured r108).
        syncCompanion: _config.highResSyncCompanion,
        highResCaptureFn: () async {
          // Raw (unrotated) photo + rotation info — the round-63 lag fix: the
          // full 12 MP frame is never rotated; only the ROI crop is.
          final raw = await _controller.capturePhotoRaw();
          if (raw != null) {
            return RawHighRes(
              bytes: raw.$1,
              rotationDegrees: raw.$2,
              isFront: raw.$3,
              contentLagMs: raw.contentLagMs,
              callbackLagMs: raw.callbackLagMs,
              contentAtMs: raw.contentAtEpochMs,
            );
          }
          // Degraded fallback: preview-snapshot bytes are already upright.
          final frame = await _controller.captureFrame();
          return frame == null
              ? null
              : RawHighRes(bytes: frame, rotationDegrees: 0, isFront: false);
        },
        roiProvider: () => _roi,
        onStat: (s) {
          if (!_recording) return;
          _logger?.logCapture({
            'file': s.fileName,
            // Trigger moment (== the filename stamp); this record's own
            // time_ms is the later saved-to-storage moment.
            'captured_at_ms': s.capturedAtMs,
            'track_ids': s.trackIds,
            'total_ms': s.totalMs,
            'bytes': s.bytes,
            'full_res': s.fullRes,
            // Per-photo source + saved square side, so post-processing knows the
            // real resolution of every file (in auto mode it varies with the ROI).
            'path': s.path.wireName,
            'saved_px': s.savedPx,
            // Round 108 diagnostics: grab vs process split, and (high-res
            // path) how OLD the frame content is vs the trigger — negative means
            // zero-shutter-lag really served a past frame.
            if (s.grabMs != null) 'grab_ms': s.grabMs,
            if (s.contentLagMs != null) 'content_lag_ms': s.contentLagMs,
            if (s.callbackLagMs != null) 'callback_lag_ms': s.callbackLagMs,
            // Round 108 sync companion: the trigger-moment live crop saved
            // beside this high-res photo, when enabled and available.
            if (s.liveJpeg != null) 'live_jpeg': s.liveJpeg,
            if (s.liveBytes != null) 'live_bytes': s.liveBytes,
            if (s.liveSavedPx != null) 'live_saved_px': s.liveSavedPx,
            // Round 112: the companion's own (small) lag behind the trigger,
            // so the summary can state each shown image's honest delay.
            if (s.liveLagMs != null) 'live_lag_ms': s.liveLagMs,
            // Round 114: the high-res content's sensor moment as epoch ms —
            // lets detections records be time-matched to this photo.
            if (s.contentAtMs != null) 'content_at_ms': s.contentAtMs,
          });
        },
        onError: (fileName, error) =>
            _logAsyncError('roi_capture', 'Photo $fileName failed: $error'),
      ),
      // Reference photos (r107 as "ground-truth frames"): a second scheduler
      // on its own clock, writing into gt_frames/ regardless of detections —
      // an unbiased sample for spotting missed pollinators and hand-counting
      // true visits. The Photos tab's saved photo side governs the size.
      // Inert in time-lapse mode: that session is already clock-driven
      // photos, so a second periodic sampler would only duplicate them.
      gtCaptureBuilder: !_config.gtFramesEnabled || _config.timeLapseCapture
          ? null
          : (gtDir, fileToken) => RoiCaptureScheduler(
              framesDir: gtDir,
              sessionToken: fileToken,
              // `ref_` filenames: both schedulers share the session token, so
              // without a distinct prefix a same-millisecond capture in
              // roi_frames/ and gt_frames/ could collide by name (the gallery
              // export skips same-named files).
              filePrefix: 'ref',
              stepMs: (_config.gtFrameSeconds * 1000).round().clamp(
                1000,
                86400000,
              ),
              // Effectively unbounded: the dump's shared window must span the
              // whole session (evaluateMotion is the periodic clock here).
              durationMs: 1 << 50,
              // Always the fast live-frame crop, whatever the user's photo
              // source mode: a high-res capture pauses the analysis stream
              // 0.13–1.5 s per photo (r115), and a detection-independent
              // sampler must never tax the detection pipeline. Accepted
              // trade-off (no cross-scheduler guard): if a detection high-res
              // capture has the stream paused right now, this crop reuses the
              // last pre-pause frame — worst case ~1.5 s stale, at a 30 s
              // default cadence.
              mode: RoiCaptureMode.fast,
              targetPx: _config.targetRoiSavedPx,
              streamDims: () => (_imageWidth, _imageHeight),
              highResDims: () => (_captureWidth, _captureHeight),
              fastCaptureFn: () => _controller.captureRoiFromFrame(
                cx: _roi.centerX,
                cy: _roi.centerY,
                side: _roi.sideFraction,
                maxPx: _config.targetRoiSavedPx,
              ),
              highResCaptureFn: () async {
                final raw = await _controller.capturePhotoRaw();
                if (raw != null) {
                  return RawHighRes(
                    bytes: raw.$1,
                    rotationDegrees: raw.$2,
                    isFront: raw.$3,
                    contentLagMs: raw.contentLagMs,
                    callbackLagMs: raw.callbackLagMs,
                    contentAtMs: raw.contentAtEpochMs,
                  );
                }
                final frame = await _controller.captureFrame();
                return frame == null
                    ? null
                    : RawHighRes(
                        bytes: frame,
                        rotationDegrees: 0,
                        isFront: false,
                      );
              },
              roiProvider: () => _roi,
              onStat: (s) {
                if (!_recording) return;
                _logger?.logGtCapture({
                  'jpeg': s.fileName,
                  'captured_at_ms': s.capturedAtMs,
                  'total_ms': s.totalMs,
                  'bytes': s.bytes,
                  'path': s.path.wireName,
                  'saved_px': s.savedPx,
                  if (s.contentLagMs != null) 'content_lag_ms': s.contentLagMs,
                  if (s.contentAtMs != null) 'content_at_ms': s.contentAtMs,
                });
              },
              onError: (fileName, error) => _logAsyncError(
                'gt_capture',
                'Reference photo $fileName failed: $error',
              ),
            ),
    );
    // The screen closed (or a stop came) while start waited for the phone: the
    // recorder has already ended that session, so set up no timers on it.
    if (!mounted || !_recording) return;

    // Round 292: from now on the screen going off no longer stops the camera.
    _pushCameraHold();

    // Round 302 (as in FaunaLapse): the site photos move into this session and
    // the note about them starts empty for the next one.
    final sessionDir = _recorder.sessionDir;
    if (sessionDir != null && siteNames.isNotEmpty) {
      unawaited(moveSitePhotosInto(sessionDir).catchError((Object e) {
        logSwallowed('site_photos_move', e);
        return const <String>[];
      }));
    }
    if (_fieldNotes.values['site_photos_about'] != null) {
      final cleared = _fieldNotes.withText('site_photos_about', '');
      if (cleared != null) {
        _fieldNotes = cleared;
        unawaited(cleared.save());
      }
    }

    // The ROI just written into the start record is the debouncer's baseline:
    // a drag that ends back on this geometry logs no roi_update.
    _roiLogDebounce.seed(_roi);
    // Same for focus: the start record carries the initial focus mode/value.
    _focusLogDebounce.seed((
      manual: _focusManual,
      value: _focusManual ? _focusValue : 0,
    ));

    // The session-length auto-end applies to MANUAL sessions only: in a
    // scheduled run each window's end time governs (via _scheduleTick), and
    // the default 60-min length must not silently truncate a longer window.
    // [_recordEndAt] mirrors whichever end applies so the REC banner can
    // count down to it.
    if (scheduleSlot == null) {
      final length = Duration(minutes: _config.sessionMinutes);
      // Cancel first: an overwritten Timer still fires (a second auto-stop).
      _sessionTimer?.cancel();
      _sessionTimer = Timer(length, () => _toggleRecording());
      _recordEndAt = DateTime.now().add(length);
      _recordSlotLabel = null;
    } else {
      final plan = _schedule;
      _recordEndAt = plan?.endOf(scheduleSlot);
      _recordSlotLabel = plan == null
          ? null
          : 'session '
                '${scheduleSlot.day * plan.windows.length + scheduleSlot.windowIndex + 1}'
                '/${plan.days * plan.windows.length}';
    }

    // Start the elapsed-time clock for the REC banner. The same 1 s tick
    // hosts the camera-delivery watchdog: it must run on a timer because a
    // dead camera produces no stream callbacks at all.
    _recordStart = DateTime.now();
    _recordElapsedVN.value = 0;
    _lastStreamEventMs = DateTime.now().millisecondsSinceEpoch;
    _cameraSilent = false;
    _recordTicker?.cancel(); // an overwritten periodic timer would tick forever
    _recordTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final start = _recordStart;
      if (start != null) {
        _recordElapsedVN.value = DateTime.now().difference(start).inSeconds;
      }
      _checkCameraDelivery();
    });

    // Time-lapse mode: anchor the burst plan at the recording start and kick
    // off the self-rescheduling tick (works the same for manual sessions and
    // scheduled windows — each window is its own recording, so each anchors
    // its own plan).
    if (_config.timeLapseCapture) {
      _timeLapsePlan = TimeLapsePlan(
        stepMs: (_config.stepSeconds * 1000).round(),
        burstMs: (_config.durationSeconds * 1000).round(),
        gapMs: (_config.timeLapseGapSeconds * 1000).round(),
      );
      _timeLapseStartMs = DateTime.now().millisecondsSinceEpoch;
      _tlLastCycle = -1;
      _tlBurstActive = false;
      // Nocturnal torch (round 180, opt-in): pure on/off schedule; the tick
      // applies it and retries on mismatch (see _setTorch).
      _tlTorchPlan = _config.timeLapseTorch
          ? TimeLapseTorchPlan(
              plan: _timeLapsePlan!,
              leadMs: (_config.timeLapseTorchLeadSeconds * 1000).round(),
            )
          : null;
      _tlTorchOn = false;
      _tlTorchBusy = false;
      _tlTorchWarned = false;
      _tlTorchLoggedFailure = false;
      // Camera parking (round 163, opt-in): the coordinator itself refuses
      // to park when the plan's idle gaps are too short (or continuous), so
      // arming it is always safe. With the torch on, the camera must be awake
      // by the LONGER of the two leads — the torch can only physically ignite
      // on a bound camera.
      final wakeLeadSeconds =
          _config.timeLapseTorch &&
              _config.timeLapseTorchLeadSeconds >
                  _config.timeLapseWakeLeadSeconds
          ? _config.timeLapseTorchLeadSeconds
          : _config.timeLapseWakeLeadSeconds;
      _tlCamera = _config.timeLapseCameraSleep
          ? TimeLapseCameraCoordinator(
              plan: _timeLapsePlan!,
              prewakeLeadMs: (wakeLeadSeconds * 1000).round(),
            )
          : null;
      _tlCameraBusy = false;
      final dir = _recorder.sessionDir;
      _tlVideo = _config.timeLapseVideo && dir != null
          ? _videoClips(dir, fps: _config.timeLapseVideoFps)
          : null;
      _timeLapseTimer?.cancel();
      _timeLapseTimer = Timer(Duration.zero, _timeLapseTick);
    }

    // Live AI + ROI video (round 240, opt-in): clips while the AI records.
    final liveDir = _recorder.sessionDir;
    if (_config.detectorEnabled && _config.liveAiVideo && liveDir != null) {
      _liveVideo = _videoClips(liveDir, fps: _config.liveAiVideoFps, live: true);
      _liveVideoStartMs = DateTime.now().millisecondsSinceEpoch;
      _liveVideoTimer?.cancel();
      _liveVideoTimer = Timer.periodic(const Duration(seconds: 1), (_) => _liveVideoTick());
      _liveVideoTick();
    }

    // Reference photos: first one right away, then the 1 s tick keeps
    // asking; the scheduler's interval window answers. A true return means a
    // photo was actually scheduled — flash the capture cue like the other
    // capture paths do (it self-gates on the flash-on-capture setting).
    if (_config.gtFramesEnabled && !_config.timeLapseCapture) {
      _gtFrameTimer?.cancel();
      if (_recorder.recordGtFrame(DateTime.now().millisecondsSinceEpoch)) {
        _flashCaptureCue();
      }
      _gtFrameTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (!_cameraFramesFresh(nowMs)) return;
        if (_recorder.recordGtFrame(nowMs)) {
          _flashCaptureCue();
        }
      });
    }

    // Recording is already live inside the recorder; rebuild the screen so
    // the REC banner and controls reflect it.
    setState(() {});

    // Snapshot the engine-selection logs (still in the ring buffer at this point)
    // into the session folder for later offline diagnosis.
    await _recorder.saveLogcat('logcat_start.txt', maxLines: 2000);
  }

  /// Thin wrapper around [SessionRecorder.stop] (which owns the ordered
  /// teardown — critical records first, best-effort diagnostics after):
  /// cancels the screen's timers, hands over the tracker's visit count for
  /// the end record, then rebuilds. Safe to run unawaited from dispose().
  Future<void> _stopRecording({
    required bool normal,
    bool retainKeepAlive = false,
  }) async {
    // A second call while the first still waits for the clips does nothing
    // (see [_stopInProgress]); dispose's stop then relies on the first one.
    if (_recorder.stopping || _stopInProgress) return;
    _stopInProgressVN.value = true;
    try {
      await _stopRecordingUnguarded(
        normal: normal,
        retainKeepAlive: retainKeepAlive,
      );
    } finally {
      _stopInProgressVN.value = false;
    }
  }

  Future<void> _stopRecordingUnguarded({
    required bool normal,
    required bool retainKeepAlive,
  }) async {
    _sessionTimer?.cancel();
    _recordTicker?.cancel();
    _recordTicker = null;
    _recordEndAt = null;
    _recordSlotLabel = null;
    _timeLapseTimer?.cancel();
    _timeLapseTimer = null;
    _gtFrameTimer?.cancel();
    _gtFrameTimer = null;
    _timeLapsePlan = null;
    // Parked at stop time is fine: [_paused] is already true, so the paths
    // that follow a stop (summary review, scheduled sleep, dispose) treat it
    // exactly like their own cool-down pause and resume it when appropriate.
    _tlCamera = null;
    // Torch off with the recording (round 180). If the stop caught the camera
    // parked the LED is already physically dead — the extra call is a cheap
    // no-op; either way the Dart cache ends honest for the next recording.
    if (_tlTorchPlan != null) {
      _tlTorchPlan = null;
      if (_tlTorchOn) {
        _tlTorchOn = false;
        _logger?.logTorch({
          'on': false,
          'success': true,
          'reason': 'session_stop',
        });
      }
      unawaited(
        _controller
            .setTorchMode(false)
            .catchError((Object e) => _logAsyncError('timelapse_torch', e)),
      );
    }
    // The open video clip closes (and is logged) before the session log
    // closes; the clips controller bounds the wait.
    final video = _tlVideo;
    _tlVideo = null;
    await video?.stop('session_end');
    _liveVideoTimer?.cancel();
    _liveVideoTimer = null;
    final liveVideo = _liveVideo;
    _liveVideo = null;
    await liveVideo?.stop('session_end');
    if (_tlBurstActive) {
      _tlBurstActive = false;
      _pushTimeLapse(); // back to the low between-burst sampling rate
    }
    // A ROI change still sitting in the debounce window must land before the
    // logger closes — the session's final ROI is never lost to the timer.
    if (_recording) _roiLogDebounce.flush(_writeRoiUpdate);
    if (_recording) _focusLogDebounce.flush(_writeFocusChange);
    await _recorder.stop(
      normal: normal,
      uniqueTrackCount: _tracker.totalConfirmed,
      retainKeepAlive: retainKeepAlive,
    );
    _pushCameraHold();
    if (mounted) setState(() {});
  }

  // --- Settings -----------------------------------------------------------

  /// Builds the configured tracker (round 105: ByteTrack or C-BIoU) with the
  /// frame-based occlusion/min-hit buffers derived from the user's *seconds*
  /// and the given (smoothed) detector FPS. Centralised so the init and the
  /// settings-apply construct the tracker the same way; the per-second live
  /// refresh only re-derives the frame budgets via [InsectTracker.setFrameBudgets].
  /// The builder itself lives in [SessionConfig.buildTracker] (round 228),
  /// shared with offline tracking of videos.
  InsectTracker _buildTracker(double detectorFps) => _config.buildTracker(detectorFps);

  /// (Re)builds the auto-throttle from the current config and seeds the applied
  /// cap. Called at init and whenever settings change. When auto-throttle is off
  /// the cap is the plain manual value.
  void _rebuildThrottle() {
    if (_config.autoThrottle) {
      _throttle = AdaptiveInferenceThrottle(
        minFps: _config.effectiveMinInferenceFps,
        ceilFps: _inferenceCeilFps,
        dutyTarget: _config.throttleDutyTarget,
      );
      // Start at the ceiling; the per-second loop pulls it down within a few
      // seconds once the first inference-time measurements arrive.
      _appliedCapFps = _inferenceCeilFps;
    } else {
      _throttle = null;
      _appliedCapFps = _inferenceCeilFps;
    }
  }
}
