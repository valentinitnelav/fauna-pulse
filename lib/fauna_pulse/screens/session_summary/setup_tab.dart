// FaunaPulse, session summary screen:
// the Setup tab (dates, battery, storage, field notes and every session setting).
//
// A `part` of session_summary_screen.dart: that screen's State class is split into
// extensions, one file per part of the screen, so each file stays readable
// while the private fields stay shared (Dart privacy is per library, and a
// part file belongs to the main file's library). Fields, getters and the
// lifecycle overrides stay in the main file; part files hold methods only.
//
// The extensions below are the State's own code, so calling setState here is
// correct; the analyzer cannot tell an extension from outside code.
// ignore_for_file: invalid_use_of_protected_member

part of '../session_summary_screen.dart';

extension _SummarySetupTab on _SessionSummaryScreenState {
  /// A bold sub-header inside the settings card.
  Widget _subhead(String s) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 2),
    child: Text(
      s,
      style: const TextStyle(
        fontWeight: FontWeight.bold,
        color: Color(0xFFFFCA28),
        fontSize: 13,
      ),
    ),
  );

  /// All settings the user configured at the start of this session, grouped and
  /// shown so the details of a past run can be recalled at a glance. Read entirely
  /// from the start record (no extra file work). Rows whose value wasn't recorded
  /// (e.g. settings added after an older session) are simply omitted.
  ///
  /// Round 187 (owner request): EVERY recorded setting is listed — including
  /// the ones the session's capture mode made inert (e.g. detector settings
  /// in a time-lapse session, or the time-lapse settings in an AI session).
  /// Those render dimmed under a short "not applicable" note instead of
  /// being hidden (as rounds 147–186 did), so the full record is always
  /// visible in one place.
  List<Widget> _settingsSection() {
    if (_startRec == null) {
      return const [
        Text(
          'No start record found, so the settings could not be read.',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ];
    }

    final rows = <Widget>[];
    // Adds a label/value row only when [value] is non-null (and non-empty
    // text). [na] replaces an inert recorded default with an explicit label,
    // so it cannot be mistaken for a value that affected this session.
    void add(String label, Object? value, {String suffix = '', bool na = false}) {
      if (value == null) return;
      final text = value is bool
          ? (value ? 'Yes' : 'No')
          : value is num
          ? _numStr(value)
          : value.toString();
      if (text.isEmpty) return;
      rows.add(_stat(label, na ? 'Not applicable' : '$text$suffix', dim: na));
    }

    // Capture-mode awareness (round 147, presentation reworked round 187):
    // the "not applicable" notes below mark whole groups the session's mode
    // made inert; each affected value reads "Not applicable". The log's config
    // block still registers every value (see config_not_applicable there).
    final noAi = _noAiSession;
    final modeName = _importedVideoSession
        ? 'imported videos'
        : _timeLapseSession
        ? 'time-lapse'
        : _motionOnlySession
        ? 'motion-triggered photos'
        : 'live detection';
    void addNote(String text) {
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            text,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      );
    }

    // --- Model & detection ---
    rows.add(_subhead('Model & detection'));
    if (_videoSession) {
      // Round 229: what "Run AI on videos" used (video_detections.jsonl);
      // labels match that screen's controls.
      final run = _videoRun;
      final vs = run?['settings'];
      if (run == null || vs is! Map) {
        addNote(
          'Not analyzed yet: "Find animals in videos" on the home screen finds '
          'the animals in these videos.',
        );
      } else {
        addNote('Chosen on the "Find animals in videos" screen.');
        add('Model', run['model_name'] ?? vs['model']);
        add('GPU requested', run['use_gpu']);
        add('Confidence threshold', vs['confidence']);
        add('IoU threshold', vs['iou']);
        add('Frames analyzed per second', vs['analysis_fps']);
        final roi = vs['roi'];
        add(
          'Area to analyze',
          roi is List && roi.length == 3 && roi[2] is num
              ? 'a square, ${((roi[2] as num) * 100).round()} % of the '
                    'picture width'
              : 'whole picture',
        );
        add(
          'Larger pictures shrunk to',
          vs['max_side_px'],
          suffix: ' px per side',
        );
        add(
          'Pause above battery temperature',
          run['thermal_limit_c'],
          suffix: ' °C',
        );
        add('Measure the phone every', run['sample_s'], suffix: ' s');
      }
    } else if (noAi) {
      addNote(
        'Not applicable: the detector did not run during recording '
        '($modeName).',
      );
    }
    add('Model', _setting('modelPath', 'model_path'), na: noAi);
    add('Task', _setting('task', 'task'), na: noAi);
    add('GPU requested', _setting('useGpu', 'use_gpu'), na: noAi);
    add(
      'CPU threads (0 = automatic)',
      _setting('cpuThreads', 'cpu_threads'),
      na: noAi,
    );
    add('Detector ran on', _accelerator, na: noAi);
    add(
      'Confidence threshold',
      _setting('confidenceThreshold', 'confidence_threshold'),
      na: noAi,
    );
    add('IoU threshold', _setting('iouThreshold', 'iou_threshold'), na: noAi);
    // Round 313: the start record's top-level inference_fps is the rate that
    // ran (never above the camera cap); the stored setting keeps what was
    // typed. Older logs have the same number in both.
    final infFps = _startRec?['inference_fps'] ?? _setting('inferenceFps');
    // Round 317: the labels of these rows are the Settings labels, so the
    // user finds the control they record ("Max detector rate" is one label
    // whether the auto-adjust is on or off).
    add(
      'Max detector rate',
      infFps == null
          ? null
          : (infFps is num && infFps == 0
                ? 'uncapped (max)'
                : '${_numStr(infFps)} /s'),
      na: noAi,
    );

    // --- Heat management ---
    // Only for sessions that recorded these fields (config block, round 44+).
    if (_setting('autoThrottle') != null ||
        _setting('motionGateEnabled') != null) {
      rows.add(_subhead('Heat management'));
      // Camera hardware rate cap (round 82) — distinct from the inference cap.
      final camFps = _setting('cameraFpsCap');
      add(
        'Camera frame rate cap',
        camFps == null
            ? null
            : (camFps is num && camFps == 0
                  ? 'device default'
                  : '${_numStr(camFps)} /s'),
      );
      if (noAi) {
        addNote(
          'Auto-adjust detector rate was not applicable because no detector '
          'was running.',
        );
      }
      // Round 293: when the recording let the screen go dark.
      final screenOff = _setting('screenOffAfterMin');
      add(
        'Screen off by itself after',
        screenOff == null
            ? null
            : (screenOff is num && screenOff == 0 ? 'never' : '${_numStr(screenOff)} min'),
      );
      // Round 296: clean stops.
      final lowBattery = _setting('lowBatteryStopPercent');
      add(
        'Stop at battery level',
        lowBattery == null ? null : (lowBattery is num && lowBattery == 0 ? 'never' : '${_numStr(lowBattery)} %'),
      );
      // 0 ("never") is only in sessions recorded before round 319, whose lowest
      // value became 50 MB: shown as it was used then.
      final reserve = _setting('storageReserveMb');
      add(
        'Keep free storage',
        reserve == null ? null : (reserve is num && reserve == 0 ? 'never' : '${_numStr(reserve)} MB'),
      );
      add('Auto-adjust detector rate', _setting('autoThrottle'), na: noAi);
      // Never above the rate that ran (SessionConfig.effectiveMinInferenceFps).
      final minFps = _setting('minInferenceFps');
      add(
        'Min detector rate',
        minFps is num && infFps is num && infFps > 0 && minFps > infFps ? infFps : minFps,
        suffix: ' /s',
        na: noAi,
      );
      add('Target processor load', _setting('throttleDutyTarget'), na: noAi);
      // Motion-only capture: photos on ROI motion, detector never ran.
      add('Motion-only capture (detector off)', _setting('motionOnlyCapture'));
      // Motion gate (round 58+): detector sleeps while nothing moves in the
      // ROI. In a motion session these rows ARE the capture sensitivity; in
      // time-lapse the gate is forced off natively — the config may still
      // carry motionGateEnabled=true, so those rows render dimmed. The gate
      // tunables also show (dimmed) when the gate itself was off: recorded,
      // no effect.
      final gateNa = _timeLapseSession;
      // Round 313: the motion trigger runs the gate whatever the switch says
      // (the trigger no longer stores the switch on).
      final motionTrigger = _setting('captureTrigger') == 'motion';
      final gateOn = _setting('motionGateEnabled') == true || motionTrigger;
      if (gateNa) {
        addNote('Motion gate was not applicable in time-lapse mode.');
      }
      add('Motion gate', motionTrigger ? true : _setting('motionGateEnabled'), na: gateNa);
      final gateDetailNa = gateNa || !gateOn;
      add(
        'Pixel sensitivity',
        _setting('motionGatePixelDelta'),
        na: gateDetailNa,
      );
      final area = _setting('motionGateAreaFraction');
      add(
        'Trigger area',
        area is num ? area * 100 : null,
        suffix: ' %',
        na: gateDetailNa,
      );
      add(
        'Wake duration after motion',
        _setting('motionGateWakeSeconds'),
        suffix: ' s',
        na: gateDetailNa,
      );
      add(
        'Motion grid resolution',
        _setting('motionGateGridSize'),
        suffix: ' cells',
        na: gateDetailNa,
      );
      add(
        'Idle check rate (frames/s)',
        _setting('motionGateIdleFps'),
        na: gateDetailNa,
      );
    }

    // --- Photos & capture ---
    rows.add(
      _subhead(
        _importedVideoSession
            ? 'Videos'
            : _recordedVideoSession
            ? 'Time-lapse video'
            : 'Photos & capture',
      ),
    );
    add(
      'Output folder',
      _setting('folderName') ?? widget.logFile.parent.path.split('/').last,
    );
    // Imported videos (round 229): the import's totals from the start record.
    final video = _startRec?['video'];
    if (video is Map) {
      add('Clips', video['clips']);
      final bytes = video['total_bytes'];
      add('Video files', bytes is num ? formatBytes(bytes.toInt()) : null);
    } else if (_recordedVideoSession || _liveVideoSession) {
      // Round 239: from the clips' own `video_clip` records (round 240: also
      // the 5-minute clips of a live AI session).
      final t = _clipTotals;
      add('Clips', t.count);
      add('Video files', formatBytes(t.bytes));
      add('Filmed time (all clips)', _hmsLabel(t.durationMs));
      if (t.skippedBursts > 0) {
        add(_liveVideoSession ? '5-minute pieces without a clip' : 'Bursts without a clip', t.skippedBursts);
      }
    }
    if (_videosDeleted > 0) {
      add('Videos deleted', '$_videosDeleted (${formatBytes(_videosFreedBytes)} freed)');
    }
    // The session's operating mode (round 97 enum; older sessions carry the
    // motion-only bool shown in Heat management instead — add() skips null).
    add('Capture trigger', _setting('captureTrigger'));
    // Time-lapse settings (round 97+). Shown in every mode since round 187,
    // with explicit not-applicable values outside time-lapse.
    final tlNa = !_timeLapseSession;
    if (tlNa &&
        (_setting('timeLapseGapSeconds') != null ||
            _setting('timeLapseIntervalSeconds') != null)) {
      addNote(
        'Time-lapse settings were not used in this session ($modeName).',
      );
    }
    // Round 174: the key became a BREAK between bursts. Pre-174 sessions
    // carry the old start-to-start key instead — show whichever exists,
    // labeled with its true meaning (never relabel old data).
    add(
      'Time between bursts',
      _setting('timeLapseGapSeconds'),
      suffix: ' s',
      na: tlNa,
    );
    add(
      'Burst repeat interval (start to start)',
      _setting('timeLapseIntervalSeconds'),
      suffix: ' s',
      na: tlNa,
    );
    // Round 163 (E3): camera parking between bursts. Sessions recorded
    // before the setting existed carry no key — add() skips null. The lead
    // rows are dimmed whenever their parent toggle was off, too.
    add('Camera off between bursts', _setting('timeLapseCameraSleep'), na: tlNa);
    add(
      'Camera wake lead',
      _setting('timeLapseWakeLeadSeconds'),
      suffix: ' s',
      na: tlNa || _setting('timeLapseCameraSleep') != true,
    );
    // Round 180: nocturnal torch. Older sessions carry no key — add()
    // skips null.
    add('Torch during bursts', _setting('timeLapseTorch'), na: tlNa);
    add(
      'Torch lead',
      _setting('timeLapseTorchLeadSeconds'),
      suffix: ' s',
      na: tlNa || _setting('timeLapseTorch') != true,
    );
    // Round 238: bursts saved as photos or as video clips. Older sessions
    // carry no key; add() skips null.
    final tlVideo = !tlNa && _setting('timeLapseSaveAs') == 'video';
    add('Save bursts as', _setting('timeLapseSaveAs'), na: tlNa);
    add('Video frame rate', _setting('timeLapseVideoFps'), suffix: ' fps', na: !tlVideo);
    add(
      'Photo step',
      _setting('stepSeconds', 'step_seconds'),
      suffix: ' s',
      na: tlVideo,
    );
    add(
      tlVideo ? 'Burst duration (clip length)' : 'Photo duration',
      _setting('durationSeconds', 'duration_seconds'),
      suffix: ' s',
    );
    // 'still' is the frozen wire value for the high-res path (r112 rename) —
    // translate it for display only.
    add(
      'ROI photo source',
      switch (_setting('captureMode')) {
        'still' => 'High-res photos always',
        'auto' => 'Auto (high-res only when needed)',
        'fast' => 'Fast crops only (live frame)',
        final v => v,
      },
    );
    add('Saved photo side', _setting('targetRoiSavedPx'), suffix: ' px');
    // Reference photos (wire keys stay gt_* from the r107 "ground-truth
    // frames" original): periodic photos independent of detections, active in
    // every mode except time-lapse (where the whole session is already
    // clock-driven photos) — there the row renders dimmed (round 187).
    if (_setting('gtFramesEnabled') != null) {
      add(
        'Reference photos',
        _setting('gtFramesEnabled') == true
            ? 'every ${_numStr(_setting('gtFrameSeconds'))} s (gt_frames/)'
                  '${_timeLapseSession ? ', not used in time-lapse mode' : ''}'
            : 'off',
        na: _timeLapseSession,
      );
    }
    // Round 108: high-res photos get a trigger-moment live crop next to them
    // ('stillSyncCompanion' is the setting's frozen wire key).
    if (_setting('stillSyncCompanion') != null) {
      add(
        'Also save a fast crop with each high-res photo',
        _setting('stillSyncCompanion') == true ? 'on' : 'off',
        na:
            _setting('captureMode') == 'fast' ||
            (_setting('captureMode') == null &&
                _setting('fullResPhotos') == false),
      );
    }
    // Crop-and-export 1:1 lock (round 91) — only sessions recorded since then
    // carry the key (add() skips null).
    add('Square export crops', _setting('cropSquareLock'));
    // Round 328: the value when the session was recorded; exports use the setting as it is now.
    add('Position in exported crops (setting at recording)', _setting('cropExportPosition'));
    // Rows below only appear for sessions recorded with older configs.
    add('Min saved photo side', _setting('minRoiSavedPx'), suffix: ' px');
    final maxSaved = _setting('maxRoiSavedPx');
    add(
      'Max saved photo side',
      maxSaved is num && maxSaved == 0 ? 'no cap (native)' : maxSaved,
      suffix: maxSaved is num && maxSaved == 0 ? '' : ' px',
    );
    if (_setting('captureMode') == null) {
      add('Full-resolution photos', _setting('fullResPhotos'));
    }
    add(
      'Maximum camera resolution this phone can deliver',
      _dims(
        _startRec?['camera_full_width_px'],
        _startRec?['camera_full_height_px'],
      ),
    );
    add(
      'Stream resolution (requested)',
      _dims(_setting('streamWidth'), _setting('streamHeight')),
      // Round 109: the app picked this size itself (smallest with short side
      // ≥ 1024); pre-109 sessions lack the key and get no suffix.
      suffix: _setting('streamResolutionExplicit') == false ? ' (auto)' : '',
    );
    add(
      'Analysis frame',
      _dims(
        _startRec?['analysis_frame_width_px'],
        _startRec?['analysis_frame_height_px'],
      ),
    );
    // The ROI in the scale the user saw on screen (stream grid, ÷32) — round
    // 109. The raw `roi` block may be a high-res-frame projection of the same
    // square (1333 for an on-screen 480 — session_6), so it is only shown raw
    // when the stream-grid side cannot be derived (very old logs).
    final roi = _startRec?['roi'];
    final initialSide = _startRec == null ? null : _roiStreamSideOf(_startRec!);
    if (initialSide != null) {
      add('Initial ROI', '$initialSide × $initialSide px');
    } else if (roi is Map) {
      add('Initial ROI', _dims(roi['width_px'], roi['height_px']));
    }
    // The saved-photo outcome of that box, separate from its on-screen size.
    final savesPx = (_startRec?['saves_px'] as num?)?.toInt();
    if (savesPx != null && savesPx > 0) {
      final src = _startRec?['roi_source'];
      add(
        'Initial ROI saves',
        '$savesPx px${src == 'fast'
            ? ' via fast crop'
            : src == 'still'
            ? ' via high-res photo'
            : ''}',
      );
    }
    if (_roiHistory.isNotEmpty) {
      rows.add(_subhead('ROI changes during the session'));
      for (final e in _roiHistory) {
        final side = e.sidePx;
        final saves = e.savesPx;
        add(
          _offsetLabel(e.timeMs).isEmpty ? 'changed' : _offsetLabel(e.timeMs),
          side == null ? 'unknown size' : '$side × $side px',
          suffix: saves == null || saves <= 0
              ? ''
              : ' (saves $saves px${e.source == 'fast'
                    ? ' via fast crop'
                    : e.source == 'still'
                    ? ' via high-res photo'
                    : ''})',
        );
      }
    }
    final focus = _startRec?['focus_mode'];
    if (focus != null) {
      final fv = _startRec?['focus_value'];
      add(
        'Focus mode',
        fv is num ? '$focus (${fv.toStringAsFixed(2)})' : focus,
      );
    }

    // --- Session & sampling ---
    // (Nothing to list for imported videos: no camera session ran.)
    if (!_importedVideoSession) rows.add(_subhead('Session & sampling'));
    final scheduleEnabled = _setting('scheduleEnabled');
    add(
      'Session length',
      _setting('sessionMinutes', 'session_minutes'),
      suffix: ' min',
      na: scheduleEnabled == true,
    );
    // Scheduled recording (only sessions recorded with the feature carry the
    // keys; add() skips null). The `schedule` block on the start record marks
    // which slot of a run THIS session was.
    add('Scheduled recording', scheduleEnabled);
    final schedWindows = _setting('scheduleWindows');
    if (schedWindows is List) {
      final labels = <String>[
        for (final w in schedWindows)
          if (w is Map && w['start'] is num && w['end'] is num)
            '${ScheduleWindow.hhmm((w['start'] as num).toInt())}–'
                '${ScheduleWindow.hhmm((w['end'] as num).toInt())}',
      ];
      if (labels.isNotEmpty) {
        add(
          'Schedule windows',
          labels.join(', '),
          na: scheduleEnabled != true,
        );
      }
    }
    add(
      'Days to run',
      _setting('scheduleDays'),
      na: scheduleEnabled != true,
    );
    final sched = _startRec?['schedule'];
    if (sched is Map) {
      add(
        'Schedule slot',
        'day ${sched['day']}/${sched['days_total']}, '
            'window ${sched['window']} '
            '(${sched['window_start']}–${sched['window_end']})',
      );
    }
    // Only round-148-build sessions carry this key (add() skips it otherwise);
    // for those with diagnostics off, the sampling intervals had no effect and
    // are not listed (round 105 principle: never list inert knobs).
    add('Record diagnostics', _setting('diagnosticsEnabled'));
    if (!_diagnosticsOffSession) {
      add(
        'FPS sample interval',
        _setting('fpsSampleSeconds', 'fps_sample_seconds'),
        suffix: ' s',
      );
      add(
        'Temperature sample interval',
        _setting('thermalSampleSeconds', 'thermal_sample_seconds'),
        suffix: ' s',
      );
      add(
        'Power sample interval',
        _setting('powerSampleSeconds', 'power_sample_seconds'),
        suffix: ' s',
      );
    }

    // --- Visit tracking ---
    // Labels here mirror the AI-tab settings exactly so the same knob is never
    // called two different things. The user sets occlusion tolerance and min
    // visit length in *seconds*; the tracker uses *frames*, so we show the
    // seconds the user chose and, where available, the derived frame count.
    // Round 105: two selectable algorithms; only the one this session actually
    // ran is shown (its name in the sub-header), so the card never lists knobs
    // that had no effect.
    final isCbiou = _trackerAlgorithm == 'cbiou';
    // Round 229: imported videos show the settings of "Find visits"
    // (post_tracks.jsonl) once it has run.
    final afterwards = _visitsAfterwards;
    final trackNa = noAi && !afterwards;
    rows.add(
      _subhead(
        _videoSession && !afterwards
            ? 'Tracking'
            : 'Tracking (${isCbiou ? 'C-BIoU' : 'ByteTrack'})',
      ),
    );
    if (_videoSession) {
      addNote(
        afterwards
            ? 'Track IDs found afterwards with "Find track IDs" on the "Find animals in '
                  'videos" screen.'
            : 'Not run yet: "Find track IDs" on the "Find animals in videos" screen '
                  'follows each animal from frame to frame.',
      );
    } else if (_visitsFromPhotos) {
      addNote(
        'Track IDs found afterwards in the photos with "Find track IDs" on the '
        '"Find animals in photos" screen.',
      );
    } else if (noAi) {
      addNote(
        'Not applicable: track IDs need the detector during recording ($modeName).',
      );
    }
    add(
      'Occlusion tolerance',
      afterwards ? _post('occlusion_seconds') : _setting('occlusionSeconds'),
      suffix: ' s',
      na: trackNa,
    );
    // Min visit length: prefer the seconds the user set (newer sessions);
    // fall back to the raw frame count logged by older sessions.
    final tp = _trackerParams;
    final minHitsSeconds = afterwards
        ? _post('min_hits_seconds')
        : _setting('minHitsSeconds');
    if (minHitsSeconds != null) {
      add('Minimum track length', minHitsSeconds, suffix: ' s', na: trackNa);
    } else if (tp != null) {
      add(
        'Minimum track length',
        tp['minHitsToConfirm'],
        suffix: ' frames',
        na: trackNa,
      );
    }
    // Round 234: frames "Find visits" kept of each visit.
    if (afterwards && _videoSession) {
      final keep = KeepFramesSettings.fromJson(_post('keep_frames'));
      add(
        'Kept frames per track ID',
        keep == null
            ? 'none'
            : 'first frame, then one every ${_numStr(keep.stepSeconds)} s '
                  'for up to ${_numStr(keep.durationSeconds)} s',
      );
    }
    if (isCbiou) {
      final cbp = _cbiouParams;
      if (cbp != null) {
        add('Search margin, pass 1', cbp['bufferScale1'], na: trackNa);
        add('Search margin, pass 2', cbp['bufferScale2'], na: trackNa);
        add('New-track confidence', cbp['highThresh'], na: trackNa);
      }
    } else if (tp != null) {
      add('Match overlap (IoU)', tp['matchThresh'], na: trackNa);
      add('Low-score association', tp['lowMatchThresh'], na: trackNa);
      add('Velocity smoothing', tp['velocitySmoothing'], na: trackNa);
      add('New-track confidence', tp['highThresh'], na: trackNa);
    }
    // The frame counts the tracker used, derived from the seconds above at
    // the frame rate (at the start of a live session; it follows the frame
    // rate during the session).
    final used = _usedTracker;
    if (used != null) {
      final when = afterwards ? '' : ', at the start';
      add('Occlusion buffer (derived$when)', used['trackBuffer'], suffix: ' frames', na: trackNa);
      add('Minimum detections in a row (derived$when)', used['minHitsToConfirm'], na: trackNa);
    }
    // Only worth a row when it was on (it changes what the log contains).
    if (_setting('logRawDetections') == true) {
      add('Log raw detections', 'on (replayable session)', na: noAi);
    }
    // Round 240: live AI + ROI video. Older sessions carry no key.
    add('Record the ROI as video', _setting('liveAiVideo'), na: noAi);
    add('Video frame rate (live detection)', _setting('liveAiVideoFps'), suffix: ' fps', na: noAi || _setting('liveAiVideo') != true);
    return [
      const Text(
        'Everything chosen at the start of this session, so the run can be '
        'reproduced or recalled later. "Not applicable" means a saved default '
        'did not affect this session because of its mode or another setting.',
        style: TextStyle(color: Colors.white70, fontSize: 12),
      ),
      const SizedBox(height: 8),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
      ),
    ];
  }

  /// The quick "how did it go" rows that used to be the Overview tab (round
  /// 187): dates, duration, battery and storage — leading the Setup tab.
  List<Widget> _overviewSection() {
    // Same date/time formats as the home history list: yyyy-mm-dd, hh:mm:ss.
    final start = _startMs != null
        ? DateTime.fromMillisecondsSinceEpoch(_startMs!)
        : null;
    final end = _endMs != null
        ? DateTime.fromMillisecondsSinceEpoch(_endMs!)
        : null;
    // A session can run past midnight: the end then carries its own date so
    // the bare time isn't ambiguous.
    final endLabel = end == null
        ? 'unknown'
        : (start != null && sessionDate(end) != sessionDate(start))
        ? '${sessionDate(end)}, ${sessionTime(end)}'
        : sessionTime(end);
    return [
      const Text('Overview', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      _stat('Capture mode', _captureModeLabel),
      _stat('Date', start != null ? sessionDate(start) : 'unknown'),
      _stat('Start time', start != null ? sessionTime(start) : 'unknown'),
      _stat('End time', endLabel),
      // Round 126: the session's single location fix, when one was set.
      if (SessionLocation.fromJson(
            (_startRec?['location'] as Map?)?.cast<String, dynamic>(),
          )
          case final SessionLocation loc)
        _stat('Location', '${loc.label} (${locationSourceLabel(loc.source)})'),
      // Round 297: the field notes saved with the session.
      ..._fieldNoteRows(),
      _stat('Session duration', _durationLabel),
      // Imported videos (round 229): the clips' total length. The session
      // runs from the first clip's start to the last one's end, gaps
      // included, and those gaps were not filmed.
      if (((_startRec?['video'] as Map?)?['total_duration_ms'] ??
              (_recordedVideoSession ? _clipTotals.durationMs : null))
          case final num filmedMs)
        _stat('Filmed time (all clips)', _hmsLabel(filmedMs.toInt())),
      _stat(
        'Model',
        _videoSession
            ? '${_videoRun?['model_name'] ?? 'Not analyzed yet'}'
            : _noAiSession
            ? 'Not applicable (no detector used)'
            : _model ?? 'unknown',
      ),
      if (!_noAiSession && _accelerator != null && _accelerator!.isNotEmpty)
        _stat('Detector ran on', _accelerator!),
      _stat(
        'Ended normally',
        _endedNormally ? 'Yes' : 'No (crash / forced stop)',
      ),
      if (_guardStopLabel case final String why) _stat('Stopped by itself', why),
      _stat('Battery used', _batteryUsedLabel),
      if (_chargingDuringSession)
        const Padding(
          padding: EdgeInsets.only(top: 2, bottom: 6),
          child: Text(
            'The phone was plugged in during (part of) this session. This is '
            'normal with a charger or power bank. While charging, the battery '
            'sensor measures the charging, not what the phone uses, so the '
            'power graph (Graphs tab, Extra graphs) is not shown.',
            style: TextStyle(color: Color(0xFFFFB74D), fontSize: 12),
          ),
        ),
      _stat('Saved to', widget.logFile.parent.path),
      // --- Storage (round 90; Delete moved to the per-session menu of the
      // session list when the Overview tab was retired, round 187) ---
      _stat(
        'Session storage',
        _sessionSizeBytes != null
            ? formatBytes(_sessionSizeBytes!)
            : 'measuring…',
      ),
      _stat(
        'Phone storage free',
        _storage.freeGb != null
            ? '${_storage.isLow ? '⚠ ' : ''}'
                  '${_storage.freeGb!.toStringAsFixed(1)} GB'
            : 'unknown',
      ),
    ];
  }

  /// The "Setup" tab (labeled "Settings" before round 182). Round 187: it
  /// leads with the Overview rows (dates, battery, storage — the retired
  /// Overview tab's content), then the full settings record unfolds behind a
  /// tap-to-show header so the quick read stays scannable.
  Widget _setupTab() {
    // Lazy one-shot scan for mid-session ROI changes (round 109): kicked off
    // the first time this tab builds so the fast head/tail stats load is
    // untouched; setState on completion re-renders with the history rows.
    if (!_roiHistoryRequested) {
      _roiHistoryRequested = true;
      _loadRoiHistory();
    }
    return ListView(
      padding: _tabPadding,
      children: [
        ..._overviewSection(),
        const Divider(height: 32, color: Colors.white24),
        InkWell(
          onTap: () => setState(
            () => _setupSettingsExpanded = !_setupSettingsExpanded,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _setupSettingsExpanded
                  ? '▾ All session settings'
                  : '▸ All session settings (tap to show)',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ),
        if (_setupSettingsExpanded) ..._settingsSection(),
      ],
    );
  }

  /// One label/value row. [dim] renders explicit "Not applicable" rows muted.
  /// Round 297: one row per filled field note (the start record's `field`
  /// block; the notes sit under `custom` as "Notes", as in FaunaLapse).
  List<Widget> _fieldNoteRows() {
    final f = _startRec?['field'];
    if (f is! Map) return const [];
    final custom = f['custom'];
    String text(Object v) => v is num ? _numStr(v) : (v is bool ? (v ? 'Yes' : 'No') : '$v');
    return [
      for (final spec in kFieldNoteSpecs)
        if ((spec.kind == FieldNoteKind.notes ? (custom is Map ? custom['Notes'] : null) : f[spec.key])
            case final Object v)
          _stat(spec.label, text(v)),
      // Round 301: the user's own fields (also those of imported FaunaLapse sessions).
      if (custom is Map)
        for (final e in custom.entries)
          if (e.key != 'Notes' && e.value != null) _stat('${e.key}', text(e.value as Object)),
      // Round 302: the site photos moved into the session at Start.
      if (f['site_photos'] case final List photos when photos.isNotEmpty)
        _stat('Site photos', '${photos.length} (folder site_photos)'),
    ];
  }

  Widget _stat(String label, String value, {bool dim = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(
            label,
            style: TextStyle(color: dim ? Colors.white38 : Colors.white70),
          ),
        ),
        Expanded(
          flex: 3,
          child: Text(
            value,
            style: dim
                ? const TextStyle(color: Colors.white38)
                : const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}
