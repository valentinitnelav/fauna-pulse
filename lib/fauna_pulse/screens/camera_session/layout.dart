// FaunaPulse, live recording screen: the widget tree (build) and its small widget helpers.
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

extension _CameraLayout on _CameraSessionScreenState {
  // --- UI -----------------------------------------------------------------

  Widget _buildScreen(BuildContext context) {
    // Show the ROI side at the resolution of the saved photo, snapped to the
    // multiple of 32 the crop actually uses. The full-resolution photo size is
    // learned by a one-time probe right after the camera starts; until it
    // returns we show "measuring…" rather than flashing a placeholder number.
    // Two separate numbers, deliberately (round 62): the BOX size in stream
    // pixels (one scale, goes down monotonically as the user shrinks it) and
    // the FILE size the active source would save from it ("saves N×N"). On the
    // high-res path the file is usually larger than the box's stream-pixel size —
    // that's the point of paying for a high-res photo for a small box.
    final bool haveRoiDim = _roiSourceWidth > 0;
    final int roiSidePx = haveRoiDim
        ? snapToMultipleOf32(
            _roi.sideFraction * _roiSourceWidth,
          ).clamp(32, _maxRoiPx)
        : 0;
    final int savedPxNow = haveRoiDim ? _savedSideNow : 0;
    // Warn when even the chosen source can't reach the minimum saved size —
    // no software can add those pixels; the fixes are physical (move the
    // phone closer, or switch to a telephoto lens).
    final String warnTag = (haveRoiDim && savedPxNow < _config.targetRoiSavedPx)
        ? '  ⚠ below ${_config.targetRoiSavedPx} px'
        : '';
    final String roiLabel = !haveRoiDim
        ? 'ROI: measuring…'
        : (savedPxNow != roiSidePx
              ? 'ROI: $roiSidePx×$roiSidePx px → saves $savedPxNow×$savedPxNow (${_activePath.uiName})$warnTag'
              : 'ROI: $roiSidePx×$roiSidePx px (${_activePath.uiName})$warnTag');
    // Live analysis-stream size (its short side caps the fast ROI crop). Shows a
    // "measuring…" placeholder until the first frame arrives (like ROI), so the
    // line is always present rather than appearing late. If the phone delivered a
    // smaller frame than was requested (it can't stream the asked-for size — see
    // round 56), show both so the cap is never silent.
    final String streamLabel;
    if (_imageWidth <= 0) {
      streamLabel = 'Stream: measuring…';
    } else {
      final int reqArea = _config.streamWidth * _config.streamHeight;
      final int gotArea = _imageWidth * _imageHeight;
      // >~5% smaller by area = a genuine cap, not just a rotation swap.
      final bool capped = reqArea > 0 && gotArea < reqArea * 0.95;
      final int reqLo = _config.streamWidth < _config.streamHeight
          ? _config.streamWidth
          : _config.streamHeight;
      final int reqHi = _config.streamWidth < _config.streamHeight
          ? _config.streamHeight
          : _config.streamWidth;
      streamLabel = capped
          ? "Stream: $_imageWidth×$_imageHeight px (the phone's maximum; asked $reqLo×$reqHi)"
          : 'Stream: $_imageWidth×$_imageHeight px';
    }
    // Calibration = the whole start-up probe cycle (see _calibrating);
    // recording and the controls row wait for it.
    final bool calibrationDone = !_calibrating;
    // (Full-sensor photo size is shown in Settings, next to the ROI photo
    // source, rather than cluttering the live preview.)
    // Engine/Model/Input are always shown, with a clear waiting/unknown state
    // instead of a blank line, so the overlay layout doesn't shift as they load.
    // Round 270: the camera may run without a model (motion and time-lapse
    // capture need none), so "none" rather than a "loading…" that never ends.
    final bool noModel = _cameraModelPath.isEmpty;
    final String engineLabel = noModel
        ? 'Engine: none'
        : _accelerator.isEmpty
        ? 'Engine: detecting…'
        : 'Engine: $_accelerator';
    // The model's input resolution, shown in brackets right after the model name:
    // "reading…" until probed, then the value, or a clear "cannot read" when the
    // model's metadata doesn't carry it.
    final String inputSuffix = !_modelInputProbed
        ? '(input: reading…)'
        : _modelInputSize == null
        ? '(input: cannot read)'
        : '($_modelInputSize×$_modelInputSize px)';
    // A very long model name (e.g. a custom .tflite filename with no spaces) is
    // made wrap-friendly so it flows onto multiple lines in its chip instead of
    // overflowing — see [_wrappable]. The bracketed input size follows the name.
    final String modelLabel = noModel
        ? 'Model: none'
        : _loadedModel.isEmpty
        ? 'Model: loading… $inputSuffix'
        : 'Model: ${_wrappable(_loadedModel)} $inputSuffix';

    // REC banner, built once and slotted into the Stack at one of two depths
    // (round 145): normally ABOVE the status strip (today's look), but BELOW
    // it while the info panel is expanded, so every stat line stays readable —
    // the red ROI border still signals recording, and collapsing the panel
    // brings the banner back on top. The ValueKey lets Flutter MOVE the live
    // countdown widget between the two slots on toggle instead of tearing it
    // down and rebuilding it (widgets are matched by key across rebuilds).
    final Widget? recBanner = !_recording
        ? null
        : SafeArea(
            key: const ValueKey('rec-banner'),
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 52),
                child: ValueListenableBuilder<int>(
                  valueListenable: _recordElapsedVN,
                  builder: (_, secs, _) {
                    final leftSecs = _recordEndAt
                        ?.difference(DateTime.now())
                        .inSeconds;
                    final left = leftSecs == null
                        ? null
                        : (leftSecs < 0 ? 0 : leftSecs);
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.fiber_manual_record,
                            color: Colors.white,
                            size: 14,
                          ),
                          const SizedBox(width: 6),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'REC  ${_formatElapsed(secs)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                              if (left != null)
                                Text(
                                  '${_formatElapsed(left)} left'
                                  '${_recordSlotLabel == null ? '' : '  ·  $_recordSlotLabel'}',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          );

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          YOLOView(
            // Recreate the camera view when the stream resolution changes so the
            // new analysis resolution is bound immediately (the in-place update
            // path is unreliable for resolution). Keyed ONLY on stream size, so
            // ROI/threshold/model changes don't trigger a rebuild.
            key: ValueKey(
              'stream_${_config.streamWidth}x${_config.streamHeight}',
            ),
            modelPath: _cameraModelPath,
            task: _config.task,
            controller: _controller,
            useGpu: _config.useGpu,
            cpuThreads: _config.cpuThreads,
            stillZeroShutterLag: _stillZslFor(_config),
            confidenceThreshold: _config.confidenceThreshold,
            iouThreshold: _config.iouThreshold,
            // Cap how often the model runs (camera preview is unaffected). This
            // is the main lever for heat and battery on a long field session.
            streamingConfig: YOLOStreamingConfig.custom(
              // Rate cap fed to the native detector. With auto-throttle on this
              // is managed live by the AdaptiveInferenceThrottle; with it off it
              // is the manual cap. Changing it re-sends the
              // config (no camera rebind — analysis resolution is unchanged).
              inferenceFrequency: _appliedCapFps,
              includeOriginalImage: false,
              // Requested analysis-stream resolution (user-configurable). The
              // live-frame ROI crops are taken from this stream; inference still
              // downscales to the model input, so the extra cost is only the
              // per-frame copy. The device delivers the nearest it supports — the
              // actual size shows in the on-screen "Stream" readout.
              analysisResolution: Size(
                _config.streamWidth.toDouble(),
                _config.streamHeight.toDouble(),
              ),
            ),
            onStreamingData: _onStreamingData,
            // A new native view (round 244): the first one, and a new one whenever the stream
            // size (the key above) changes, by the automatic pick or in Settings. It starts with
            // only the model and thresholds, so the next frame map runs the start-up sequence
            // again: ROI, motion gate, camera frame-rate cap, time-lapse mode, lens and focus.
            // Before, a new view ran without them (no ROI crop, gate off) until the screen closed.
            onNativeViewCreated: () => _captureProbeStarted = false,
            onModelLoad: (modelPath, task) {
              _controller.setShowOverlays(false);
              // Tell the native side to run inference only on the ROI crop.
              _pushInferenceRoi();
              // Record which model actually loaded. If a requested switch fails
              // (e.g. a size that isn't bundled), this callback isn't called for
              // it, so the displayed model stays the one really running.
              final loaded = modelPath.split('/').last;
              _loadedModelPath = modelPath;
              _loadedModelTask = task;
              if (mounted && loaded != _loadedModel) {
                setState(() => _loadedModel = loaded);
              }
            },
            onModelError: _onModelLoadError,
          ),
          // Darken everything outside the ROI: the model only looks inside it.
          // (All these overlays are skipped while blacked out — nothing is drawn
          // and no per-frame painting happens — the camera/pipeline run on
          // underneath, hidden by the opaque blackout layer added at the end.)
          if (!_blackout)
            RoiMask(
              roi: _roi,
              frameAspect: _frameAspect,
              opacity: _recording ? 0.78 : 0.7,
            ),
          // Our own track-id boxes. Wrapped in a RepaintBoundary so that, when
          // the tracks notifier fires each frame, only this layer repaints — the
          // camera preview and everything else are left alone. Skipped entirely
          // when the user turns boxes off (no per-frame repaint at all), and
          // in the no-AI modes — the detector never runs there, so a box could
          // only be a stale leftover from an earlier AI-mode frame.
          if (!_blackout && _config.showBoxes && _config.detectorEnabled)
            IgnorePointer(
              child: RepaintBoundary(
                child: ValueListenableBuilder<List<Track>>(
                  valueListenable: _tracksVN,
                  builder: (_, tracks, _) => CustomPaint(
                    painter: TrackBoxPainter(tracks, frameAspect: _frameAspect),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
          // Draggable ROI square (border turns red while recording, and blinks
          // bright green for a split second each time a photo is saved). Only
          // this border rebuilds on the flash, at the photo cadence.
          if (!_blackout)
            ValueListenableBuilder<bool>(
              valueListenable: _captureFlashVN,
              builder: (_, flashing, _) => RoiOverlay(
                roi: _roi,
                frameAspect: _frameAspect,
                interactive: true,
                onChanged: _onRoiChanged,
                borderColor: flashing
                    ? const Color(0xFF00FF6A) // capture flash
                    // Gate idle: detector deliberately asleep — grey the ROI so
                    // the state reads at a glance from arm's length in the field.
                    : (((_config.motionGateEnabled &&
                                  _config.detectorEnabled) ||
                              _config.motionOnlyCapture) &&
                          _gateIdle)
                    ? const Color(0x99B0BEC5)
                    : (_recording ? Colors.red : const Color(0xFFFFEB3B)),
                borderWidth: flashing ? 4.0 : 2.5,
              ),
            ),
          // While the info panel is expanded, the REC banner slots in HERE —
          // under the status strip that follows — so the expanded panel stays
          // readable on top of it (round 145).
          if (recBanner != null && _statsExpanded) recBanner,
          // Top-left status strip: one chip per line, top to bottom. It may sit
          // over the ROI if the ROI is large — that's fine. Hidden entirely when
          // the user turns the on-screen info panel off (removes those periodic
          // chip rebuilds, leaving only the ROI box and controls). Keyed so the
          // REC banner's slot swap around it can never make Flutter mistake the
          // strip for the banner (both are SafeArea widgets).
          if (!_blackout && _config.showOverlayInfo)
            SafeArea(
              key: const ValueKey('status-strip'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Capture-mode badge — round 145: shown in EVERY mode
                      // (previously plain AI mode had no chip at all). Green =
                      // photos happening/possible right now, grey = waiting.
                      // Big and color-coded so it reads from arm's length in
                      // the field.
                      //
                      // Round 124/125: the chip and the collapsible-stats
                      // toggle share ONE row so the whole header stays above
                      // the REC banner (its top padding was sized to clear
                      // the chip; a line BELOW the chip would sit under the
                      // banner). Round 145: the chip sits in a Flexible, so a
                      // long label shrinks to "…" instead of pushing the tap
                      // target off-screen (the old right-overflow stripes).
                      // This relies on the row having a bounded width from
                      // SafeArea+Padding — don't wrap this header in a
                      // horizontally unbounded scroller. Collapsed, the line
                      // keeps the field essentials visible — detector fps
                      // (camera fps in the no-AI modes, labelled so the unit
                      // change is never silent) + phone temperature; tap
                      // toggles, and the choice is remembered.
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(child: _modeChip()),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: _toggleStatsExpanded,
                            child: ValueListenableBuilder<List<double>>(
                              valueListenable: _fpsTrioVN,
                              builder: (_, f, _) => ValueListenableBuilder<ThermalReading>(
                                valueListenable: _thermalVN,
                                builder: (_, thermal, _) {
                                  if (_statsExpanded) {
                                    return _statLine('▾ hide info');
                                  }
                                  final parts = <String>[
                                    if (_config.showFps)
                                      _config.detectorEnabled
                                          ? 'det ${f[1].toStringAsFixed(1)} fps'
                                          : 'cam ${f[0].toStringAsFixed(0)} fps',
                                    if (thermal.batteryTempC != null)
                                      thermal.shortLabel,
                                  ];
                                  return _statLine(
                                    '▸ ${parts.isEmpty ? 'info' : parts.join(' · ')}',
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_statsExpanded)
                        // One shared ~75%-black backdrop behind all the stat
                        // lines so they stay readable even when this panel is
                        // drawn over the red REC banner (see the Stack-order
                        // note at the REC banner slots below).
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xC0000000),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_config.showFps)
                                ValueListenableBuilder<List<double>>(
                                  valueListenable: _fpsTrioVN,
                                  builder: (_, f, _) => Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // This number counts the frames the app
                                      // actually KEEPS, not what the sensor
                                      // produces. In time-lapse mode the app
                                      // deliberately discards most frames
                                      // before the costly image conversion
                                      // (~1/s between bursts, slightly more
                                      // during one) to save heat, so a low
                                      // reading is the saving working — not a
                                      // camera fault (same honesty rule as the
                                      // r63 gate-idle readout). The label
                                      // spells that out in that mode.
                                      _statLine(
                                        _config.timeLapseCapture
                                            ? 'Camera: ${f[0].toStringAsFixed(0)} fps '
                                                  '(only the frames kept for time-lapse, '
                                                  'so a low number is normal)'
                                            : 'Camera: ${f[0].toStringAsFixed(0)} fps (sensor→app)',
                                      ),
                                      // Detector/pipeline rates are meaningless while
                                      // the detector never runs (motion-only and
                                      // time-lapse modes).
                                      if (_config.detectorEnabled) ...[
                                        _statLine(
                                          'Detector: ${f[1].toStringAsFixed(1)} fps '
                                          '(prepare + detect + remove duplicate boxes)',
                                        ),
                                        _statLine(
                                          'All steps: ${f[2].toStringAsFixed(1)} fps '
                                          '(with tracking and drawing)',
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              if (_config.showFps && _config.detectorEnabled)
                                ValueListenableBuilder<List<double>>(
                                  valueListenable: _perfVN,
                                  builder: (_, p, _) => _statLine(
                                    'prepare ${p[0].toStringAsFixed(0)} · '
                                    'detect ${p[1].toStringAsFixed(0)} · '
                                    'clean-up ${p[2].toStringAsFixed(0)} ms',
                                  ),
                                ),
                              // Motion gate status: "idle" means the detector is
                              // deliberately asleep (nothing moving in the ROI) — the
                              // 0-fps Detector line above is expected, not a fault. The
                              // live motion % helps tune the trigger-area setting.
                              if ((_config.motionGateEnabled &&
                                      _config.detectorEnabled) ||
                                  _config.motionOnlyCapture)
                                ValueListenableBuilder<double>(
                                  valueListenable: _motionScoreVN,
                                  builder: (_, score, _) => _statLine(
                                    _gateIdle
                                        ? 'Gate: idle (detector asleep) · '
                                              'motion ${(score * 100).toStringAsFixed(2)}%'
                                        : 'Gate: awake · '
                                              'motion ${(score * 100).toStringAsFixed(2)}%',
                                  ),
                                ),
                              // Engine first (just under the perf line), then the Model
                              // line, which carries the input resolution in brackets.
                              // Detector-off modes replace the Engine line: no engine
                              // is doing any work (the model loaded but never runs).
                              _statLine(
                                _config.motionOnlyCapture
                                    ? 'Mode: motion-only capture (detector off)'
                                    : _config.timeLapseCapture
                                    ? 'Mode: time-lapse (detector off)'
                                    : engineLabel,
                              ),
                              // The model line only makes sense when the
                              // detector actually runs: in the motion and
                              // time-lapse modes the model file is loaded but
                              // never asked to predict, so naming it here only
                              // misleads (owner-reported, round 146).
                              if (_config.detectorEnabled)
                                _statLine(modelLabel),
                              _statLine(streamLabel),
                              // Tappable: opens the exact-size slider when we know the
                              // capture resolution.
                              GestureDetector(
                                onTap: haveRoiDim ? _editRoiSize : null,
                                child: _statLine(
                                  haveRoiDim ? '$roiLabel  ✎' : roiLabel,
                                ),
                              ),
                              ValueListenableBuilder<ThermalReading>(
                                valueListenable: _thermalVN,
                                builder: (_, thermal, _) {
                                  final label = thermal.shortLabel;
                                  if (label.isEmpty) {
                                    return const SizedBox.shrink();
                                  }
                                  // Label it as the battery sensor only when it really is
                                  // a temperature; a bare thermal-status string is left
                                  // unprefixed.
                                  return _statLine(
                                    thermal.batteryTempC != null
                                        ? 'Battery temp.: $label'
                                        : label,
                                  );
                                },
                              ),
                              // Free storage on the session volume — hours of JPEGs can
                              // fill a phone, so the user sees when to clean up before
                              // mounting it. Refreshed on the thermal cadence.
                              ValueListenableBuilder<StorageReading>(
                                valueListenable: _storageVN,
                                builder: (_, storage, _) {
                                  final label = storage.label;
                                  if (label.isEmpty) {
                                    return const SizedBox.shrink();
                                  }
                                  return _statLine(label);
                                },
                              ),
                              // Live count of insects currently on the flower, plus the
                              // running total of unique insects confirmed so far this
                              // session (same figure as the summary Graphs tab's
                              // "Insect visits (track IDs)").
                              // Both sit in one per-frame builder, so the total stays live
                              // without a separate notifier. Hidden in the no-AI modes,
                              // same as the detector/pipeline fps lines above — no
                              // tracker runs there, so the numbers could only be stale.
                              if (_config.detectorEnabled)
                                ValueListenableBuilder<List<Track>>(
                                  valueListenable: _tracksVN,
                                  builder: (_, tracks, _) => Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _statLine(
                                        'Track IDs now: ${tracks.length}',
                                      ),
                                      _statLine(
                                        'Track IDs this session: ${_tracker.totalConfirmed}',
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          // REC banner makes it unmistakable that a session is live. Second
          // line: countdown to the auto-stop (manual: session length;
          // scheduled: this window's end) and, in a scheduled run, which
          // session of the planned bundle this is. This slot (above the
          // strip) is used only while the info panel is collapsed; the
          // expanded panel takes the top spot instead (see recBanner above).
          // The two slots are mutually exclusive — never render both.
          if (recBanner != null && !_statsExpanded) recBanner,
          // Big "Calibrating…" banner for the WHOLE start-up cycle (first
          // frame + full-res probe + ceiling probe), so the user sees one
          // calibration phase, not two sequential indicators.
          if (_calibrating)
            const IgnorePointer(child: Center(child: CalibratingBanner())),
          // Error banner: a broken session log (storage full) outranks a
          // detector error — the watchdog auto-clears _inferenceError once
          // frames flow again, but a log-write failure must stay visible.
          if ((_logWriteError ?? _inferenceError) != null &&
              !_errorBannerDismissed)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: _errorBanner((_logWriteError ?? _inferenceError)!),
              ),
            )
          else if (_slowPerSecond != null)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: SlowPhoneBanner(
                  perSecond: _slowPerSecond!,
                  onOk: () => _closeSlowHint(forGood: false),
                  onNeverAgain: () => _closeSlowHint(forGood: true),
                ),
              ),
            ),
          // Bottom controls.
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Manual focus slider (only when the lens supports it and the
                    // user has tapped the focus button). Sits above the controls so
                    // the preview inside the ROI stays visible while adjusting.
                    if (_showFocusSlider && _minFocusDistance > 0)
                      _focusSliderBar(),
                    // FittedBox(scaleDown) guarantees the control strip can never
                    // overflow the screen width (it shrinks to fit on narrow
                    // phones / large text scales) instead of showing Flutter's
                    // yellow/black overflow stripes. The camera & lens diagnostic
                    // lives in Settings → Camera now, not on this live screen.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            iconSize: 32,
                            color: Colors.white,
                            icon: const Icon(Icons.settings),
                            // Locked while calibrating (the sheet would show
                            // half-probed data, e.g. an incomplete stream-
                            // resolution list), during recording, and during
                            // a scheduled run's sleep phase: settings changes
                            // mid-run would desync the plan.
                            onPressed:
                                (_calibrating ||
                                    _recording ||
                                    _schedule != null)
                                ? null
                                : _openSettings,
                          ),
                          const SizedBox(width: 16),
                          IconButton(
                            iconSize: 32,
                            color: Colors.white,
                            icon: const Icon(Icons.dark_mode),
                            tooltip:
                                'Screen off to save power (tap the screen to wake it)',
                            // Blackout would hide the calibrating banner.
                            onPressed: _calibrating ? null : _enterBlackout,
                          ),
                          const SizedBox(width: 16),
                          _recordButton(),
                          const SizedBox(width: 16),
                          // Lens switch — immediately right of the record button.
                          // Cycles the rear lenses; disabled while recording.
                          _lensSwitchButton(),
                          const SizedBox(width: 16),
                          // Round 164: the amber dot reminds the user to
                          // check/set the focus for THIS lens — it vanishes
                          // once they drag the slider, and re-arms on a lens
                          // switch (the preset is a starting point, not a
                          // confirmation the flower is sharp).
                          Badge(
                            isLabelVisible:
                                _minFocusDistance > 0 &&
                                !_calibrating &&
                                !_focusUserAdjusted,
                            smallSize: 10,
                            backgroundColor: Colors.amber,
                            child: IconButton(
                              iconSize: 32,
                              color: (_minFocusDistance > 0 && !_calibrating)
                                  ? (_showFocusSlider
                                        ? Colors.amber
                                        : Colors.white)
                                  : Colors.white24,
                              icon: Icon(
                                _focusManual
                                    ? Icons.center_focus_strong
                                    : Icons.center_focus_weak,
                              ),
                              tooltip: _focusUserAdjusted
                                  ? 'Manual focus'
                                  : 'Manual focus (preset applied: check '
                                        'sharpness)',
                              onPressed:
                                  (_minFocusDistance > 0 && !_calibrating)
                                  ? () => setState(
                                      () =>
                                          _showFocusSlider = !_showFocusSlider,
                                    )
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 16),
                          // Session location pin (round 126): green = set,
                          // amber = GPS searching, dim = none. Locked while
                          // recording — the start record is already written.
                          IconButton(
                            iconSize: 32,
                            color: _locationVN.value != null
                                ? Colors.lightGreenAccent
                                : _locSearchingVN.value
                                ? Colors.amber
                                : Colors.white24,
                            // Round 297: opens the Field notes page; the
                            // position is its first part.
                            icon: const Icon(Icons.edit_location_alt),
                            tooltip:
                                'Field notes and position (saved with the '
                                'session)',
                            onPressed: _recording ? null : _openFieldNotes,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _schedule != null
                            ? (_recording
                                  ? 'Scheduled recording (tap ■ to stop the run)'
                                  : 'Scheduled run active')
                            : _recording
                            ? 'Recording (tap ■ to stop)'
                            : calibrationDone
                            ? (_config.scheduleEnabled
                                  ? 'Tap ● to start scheduled run '
                                        '(${_config.scheduleWindows.length} '
                                        'window'
                                        '${_config.scheduleWindows.length == 1 ? '' : 's'}'
                                        ' × ${_config.scheduleDays} '
                                        'day${_config.scheduleDays == 1 ? '' : 's'})'
                                  : 'Preview (tap ● to start recording)')
                            : 'Calibrating, please wait…',
                        style: TextStyle(
                          color: _recording
                              ? Colors.redAccent
                              : calibrationDone
                              ? Colors.white
                              : Colors.white54,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Blackout power-save cover: opaque black over the whole screen, on top
          // of everything (so it also swallows control taps). The camera + AI
          // pipeline keep running underneath; brightness was dropped to minimum in
          // [_enterBlackout]. A tap anywhere wakes the display. A brief hint fades
          // out so the steady state is pure black (≈ no screen power on OLED).
          if (_blackout)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // While scheduled-sleeping a tap shows the status (then
                // re-dims) instead of waking: the camera is OFF between
                // windows and a full wake would misleadingly show a dead
                // preview. Only the overlay's stop button leaves the run.
                onTap: _scheduleSleeping ? _showSleepStatus : _exitBlackout,
                child: Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: _scheduleSleeping
                      ? _sleepStatusOverlay()
                      : AnimatedOpacity(
                          opacity: _blackoutHint ? 1.0 : 0.0,
                          // Slow fade (held at normal brightness) so the message is easy
                          // to read; easeIn keeps it bright most of the window, then
                          // fades near the end. Kept in sync with the brightness-drop
                          // timer via [_blackoutFade].
                          duration: _blackoutFade,
                          curve: Curves.easeIn,
                          child: Text(
                            blackoutHintText(recording: _recording),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                            ),
                          ),
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Formats a recording duration (elapsed or remaining), adding coarser
  /// units only once they become relevant so short sessions stay compact:
  ///   • under 1 hour  → mm:ss
  ///   • 1–24 hours    → hh:mm:ss
  ///   • 24 hours+     → dd:hh:mm:ss
  /// Called once per second from the REC banner (not in the detection path), so
  /// it has no effect on the frame rate.
  String _formatElapsed(int totalSeconds) {
    final d = totalSeconds ~/ 86400;
    final h = (totalSeconds % 86400) ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    if (d > 0) return '${two(d)}:${two(h)}:${two(m)}:${two(s)}';
    if (h > 0) return '${two(h)}:${two(m)}:${two(s)}';
    return '${two(m)}:${two(s)}';
  }

  /// Inserts zero-width spaces (invisible) after common filename separators so a
  /// very long, space-less model name can wrap onto several lines inside its
  /// status chip instead of overflowing/clipping the line. Flutter only breaks
  /// lines at allowed points, and a token like `a_b_c_d.tflite` has none — the
  /// zero-width spaces add break opportunities without changing the visible text.
  String _wrappable(String s) =>
      s.replaceAllMapped(RegExp(r'[_\-./]'), (m) => '${m[0]}\u200B');

  /// A status chip with a little gap beneath, for the vertical left-side stack.
  Widget _statLine(String text) =>
      Padding(padding: const EdgeInsets.only(bottom: 6), child: _chip(text));

  /// The visual shell every mode-chip state shares: a dark rounded badge with
  /// a colored dot and a bold label. The label sits in a Flexible and is
  /// ellipsized, so on a narrow screen (or with a huge system font) the chip
  /// shortens itself with "…" instead of overflowing the header row (the
  /// pre-round-145 yellow/black overflow stripes).
  Widget _modeChipShell({required Color color, required String label}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 12, color: color),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One badge that always says which capture mode this session runs in and
  /// whether photos can happen right now (round 145 — previously plain AI
  /// mode showed no chip at all). Exactly one mode is active at a time
  /// (CaptureTrigger is a single enum), so the dispatch below is exhaustive:
  /// - AI detector: "DETECTOR ON" ("NO DETECTION MODEL" without one, round
  ///   270); with the motion gate, "DETECTOR SLEEPING"
  ///   while nothing moves in the ROI (expected on a mounted phone over an
  ///   empty flower, NOT a fault — the finer motion % lives on the expanded
  ///   panel's "Gate:" line).
  /// - Motion-trigger: "MOTION: CAPTURING" / "MOTION: WAITING".
  /// - Time-lapse: burst state + countdown to the next burst (ticks via
  ///   [_recordElapsedVN], which the 1 s record ticker already updates).
  Widget _modeChip() {
    if (_config.timeLapseCapture) {
      return ValueListenableBuilder<int>(
        valueListenable: _recordElapsedVN,
        builder: (_, _, _) {
          String label;
          bool active;
          final plan = _timeLapsePlan;
          // Short enough for the chip at phone width (round 238: "TIME-LAPSE
          // VIDEO: RECORDING" was cut off on the Xiaomi).
          final kind = _config.timeLapseVideo ? 'VIDEO' : 'TIME-LAPSE';
          if (!_recording || plan == null) {
            label = '$kind: tap ●';
            active = false;
          } else {
            final t = DateTime.now().millisecondsSinceEpoch - _timeLapseStartMs;
            active = plan.inBurstAt(t);
            if (active) {
              label = !_config.timeLapseVideo
                  ? '$kind: CAPTURING'
                  : switch ((_tlVideo?.recording ?? false, _tlVideo?.problem)) {
                      (true, _) => '$kind: RECORDING',
                      (_, 'storage_low') => '$kind: STORAGE FULL',
                      (_, 'start_failed') => '$kind: FAILED',
                      _ => '$kind: STARTING',
                    };
            } else {
              final waitS = ((plan.nextBurstStartAt(t) - t) / 1000).ceil();
              // "Time between bursts" goes up to 24 h; mm:ss alone would show
              // "1439:59", which reads like a clock time.
              if (waitS >= 3600) {
                label =
                    'NEXT BURST in ${waitS ~/ 3600} h ${(waitS % 3600) ~/ 60} min';
              } else {
                final mm = (waitS ~/ 60).toString().padLeft(2, '0');
                final ss = (waitS % 60).toString().padLeft(2, '0');
                label = 'NEXT BURST in $mm:$ss';
              }
              // Round 163: the frozen preview while parked is the feature
              // working, not a hang — say so where the user is looking.
              if (_tlCamera?.cameraIntentionallyDown ?? false) {
                label += ' · camera off';
              }
            }
            // Round 180: confirm the nocturnal torch where the user is
            // looking (during the pre-burst lead AND the burst itself).
            if (_tlTorchOn) label += ' · torch';
          }
          return _modeChipShell(
            color: active ? _chipActiveColor : _chipWaitingColor,
            label: label,
          );
        },
      );
    }
    if (_config.motionOnlyCapture) {
      return _modeChipShell(
        color: _gateIdle ? _chipWaitingColor : _chipActiveColor,
        label: _gateIdle ? 'MOTION: WAITING' : 'MOTION: CAPTURING',
      );
    }
    // Round 240: a live-AI clip is recording (short labels: the chip holds
    // about 20 characters at phone width).
    final video = _liveVideo?.recording ?? false;
    // Round 270: AI mode with no model loaded runs no detector; say so
    // instead of "DETECTOR ON" (recording is blocked with a dialog).
    if (_cameraModelPath.isEmpty) {
      return _modeChipShell(color: _chipWaitingColor, label: 'NO DETECTION MODEL');
    }
    if (_config.motionGateEnabled) {
      return _modeChipShell(
        color: _gateIdle ? _chipWaitingColor : _chipActiveColor,
        label: _gateIdle
            ? (video ? 'SLEEPING · VIDEO ON' : 'DETECTOR SLEEPING')
            : (video ? 'DETECTOR ON · VIDEO' : 'DETECTOR ON'),
      );
    }
    // Plain AI mode (no gate): the detector runs on every frame.
    return _modeChipShell(color: _chipActiveColor, label: video ? 'DETECTOR ON · VIDEO' : 'DETECTOR ON');
  }

  Widget _chip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white, fontSize: 13),
    ),
  );

  /// Horizontal manual-focus slider. 0 = far (infinity), 1 = near (closest
  /// the lens can focus). No "Auto" reset since round 164: focus is always
  /// manual — it opens on the close-up preset and only the user moves it.
  Widget _focusSliderBar() => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Far',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
        SizedBox(
          width: 200,
          child: Slider(
            value: _focusValue.clamp(0.0, 1.0),
            onChanged: _setManualFocus,
          ),
        ),
        const Text(
          'Near',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    ),
  );

  /// Top warning banner shown when the detector errors or stalls. Offers a quick
  /// way to open the error/report dialog, and a dismiss button.
  Widget _errorBanner(String message) => Container(
    margin: const EdgeInsets.all(10),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.red.shade900.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline, color: Colors.white, size: 22),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
        TextButton(
          onPressed: () => _showErrorReportDialog(message),
          child: const Text(
            'Report',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
        ),
        InkWell(
          onTap: () => setState(() => _errorBannerDismissed = true),
          child: const Padding(
            padding: EdgeInsets.all(4),
            child: Icon(Icons.close, color: Colors.white70, size: 18),
          ),
        ),
      ],
    ),
  );

  Widget _recordButton() {
    // Round 319: "Stopping…" while the stop closes the clips and files.
    return ValueListenableBuilder<bool>(
      valueListenable: _stopInProgressVN,
      builder: (_, stopping, _) => RecordButton(
        // Greyed out until calibration completes (recording is blocked before then).
        ready: _recording || !_calibrating,
        // While a scheduled run is active (recording or sleeping) the button is a
        // stop-square; when idle with scheduling enabled it carries a clock badge
        // so the different tap behaviour (launches the whole run) is visible.
        // It stays a square while stopping (the recorder ends "recording" first).
        square: _recording || _schedule != null || stopping,
        scheduleBadge: _config.scheduleEnabled,
        stopping: stopping,
        onTap: _toggleRecording,
      ),
    );
  }

  /// Lens-switch button shown immediately right of the record button. Tapping it
  /// cycles through the device's available rear lenses (main wide → ultra-wide →
  /// telephoto → …) and shows the current lens's short label (e.g. "1×", "0.5×",
  /// "2×"). Disabled while recording (a lens change rebinds the camera and shifts
  /// the field of view) and on phones that expose only one usable lens.
  Widget _lensSwitchButton() {
    // Also locked while calibrating: a lens change rebinds the camera and
    // would invalidate the in-flight full-res probe.
    final bool enabled = !_recording && !_calibrating && _lenses.length >= 2;
    final Color tint = enabled ? Colors.white : Colors.white24;
    return Tooltip(
      message: _lenses.length < 2
          ? 'Only one usable lens on this phone'
          : (_recording
                ? 'Stop recording to switch lens'
                : 'Switch camera lens'),
      child: InkWell(
        onTap: enabled ? _cycleLens : null,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cameraswitch, size: 30, color: tint),
              const SizedBox(height: 2),
              Text(
                _lensLabel.isEmpty ? '1×' : _lensLabel,
                style: TextStyle(
                  color: tint,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
