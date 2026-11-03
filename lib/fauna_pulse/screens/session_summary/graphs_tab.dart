// FaunaPulse, session summary screen:
// the Graphs tab (track ID timeline, visit charts, extra graphs).
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

extension _SummaryGraphsTab on _SessionSummaryScreenState {
  void _toggleExtraGraphs() {
    setState(() => _extraGraphsExpanded = !_extraGraphsExpanded);
    SharedPreferences.getInstance().then(
      (p) => p.setBool(_extraGraphsExpandedKey, _extraGraphsExpanded),
    );
  }

  void _setDurationBin(int seconds) {
    setState(() => _durationBinSeconds = seconds);
    SharedPreferences.getInstance().then(
      (p) => p.setInt(_durationBinKey, seconds),
    );
  }

  /// Tracks whether the visit-timeline section is currently within the viewport,
  /// so the floating show/hide button appears only while it's on screen and
  /// vanishes once the user scrolls to other graphs.
  void _updateTimelineInView() {
    final ctx = _timelineKey.currentContext;
    bool visible = false;
    if (ctx != null) {
      final box = ctx.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final top = box.localToGlobal(Offset.zero).dy;
        final bottom = top + box.size.height;
        final screenH = MediaQuery.of(context).size.height;
        // Visible if any part of the timeline overlaps the screen.
        visible = bottom > 80 && top < screenH - 40;
      }
    }
    if (visible != _timelineInView) {
      setState(() => _timelineInView = visible);
    }
  }

  Widget _graphsTab() {
    // Recompute timeline visibility after this frame lays out, so the floating
    // button appears even before the first scroll if the timeline starts visible.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _updateTimelineInView(),
    );
    return Stack(
      children: [
        ListView(
          controller: _scroll,
          padding: _tabPadding,
          children: [
            if (!_graphsRequested || _graphsLoading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else
              ..._graphs(),
          ],
        ),
        // Floating show/hide for the (potentially very tall) visit
        // timeline — only while that section is on screen, and only when
        // there is a collapsible timeline at all (> 10 lanes; see
        // [_timelineCollapsible]). The bottom offset must include the
        // system inset: the Stack spans the whole edge-to-edge body, so a
        // bare `bottom: 16` puts the button BEHIND the navigation/gesture
        // bar (round 165 field bug).
        if (_timelineInView && _timelineCollapsible)
          Positioned(
            left: 0,
            right: 0,
            bottom: 16 + MediaQuery.paddingOf(context).bottom,
            child: Center(
              child: FilledButton.tonalIcon(
                icon: Icon(
                  _showTimeline ? Icons.unfold_less : Icons.unfold_more,
                ),
                label: Text(_showTimeline ? 'Hide timeline' : 'Show timeline'),
                onPressed: () => setState(() => _showTimeline = !_showTimeline),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _graphs() => [
    // The session's headline number (moved here from the retired Overview
    // tab, round 187): one track id = one recorded visit, so it belongs
    // right above the timeline it summarizes.
    _stat(
      'Track IDs',
      _visitsFromPhotos
          ? '${_spans.length} (found afterwards in the photos)'
          : _motionOnlySession
          ? 'none yet ("Find track IDs" on "Find animals in photos", for photos 0.5 s apart or closer)'
          : _timeLapseSession && !_recordedVideoSession
          ? 'none yet ("Find track IDs" on "Find animals in photos", for photos 0.5 s apart or closer)'
          : _videoSession
          ? (_visitsAfterwards
                ? '${_spans.length} (found afterwards in the videos)'
                : _graphsLoading
                ? '…'
                : 'none yet ("Find track IDs" on "Find animals in videos")')
          : _uniqueTracks?.toString() ?? 'unknown',
    ),
    // Round 241: the same clips analysed afterwards, for comparison.
    if (_liveVideoSession && _afterVisits != null)
      _stat('Track IDs found afterwards in the videos', '$_afterVisits (for comparison; Video tab)'),
    const SizedBox(height: 8),
    const Text(
      'Track ID timeline (one row per track ID)',
      style: TextStyle(fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 4),
    const Text(
      'Time runs from left to right across the session. Each bar is one track ID, from the '
      'first to the last frame it was seen; bars that overlap were there at the same time. '
      'The times next to a bar count from the session start, like the axis below. A track '
      'ID is often one visit, but some are false detections or one animal split into two '
      'track IDs.',
      style: TextStyle(color: Colors.white70, fontSize: 12),
    ),
    if (_visitsAfterwards) ...[
      const SizedBox(height: 4),
      Text(
        'Found afterwards in the ${_visitsFromPhotos ? 'photos' : 'videos'} with "Find track IDs" (occlusion '
        'tolerance ${_numStr(_post('occlusion_seconds'))} s, minimum track '
        'length ${_numStr(_post('min_hits_seconds'))} s). The file track_ids.csv lists the same track IDs '
        'and lengths. '
        '${_visitsFromPhotos ? (_timeLapseSession ? 'Time between bursts was not photographed.' : '') : 'Time between clips was not filmed.'}',
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    ],
    const SizedBox(height: 12),
    _timeline(),
    if (_spans.isNotEmpty) ..._visitCharts(),
    const SizedBox(height: 28),
    // Everything below is diagnostics (round 148): hidden behind a
    // tap-to-expand header so the visitation-rate deliverable above stays
    // front and centre. Same ▸/▾ disclosure as the camera screen's stats
    // panel; the expanded state persists across summaries.
    InkWell(
      onTap: _toggleExtraGraphs,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          _extraGraphsExpanded
              ? '▾ Extra graphs (temperature, FPS, power)'
              : '▸ Extra graphs (temperature, FPS, power): tap to show',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    ),
    if (_extraGraphsExpanded && _diagnosticsOffSession)
      const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text(
          'No temperature, FPS or power data were saved for this session.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      )
    else if (_extraGraphsExpanded && _showRunGraphs) ...[
      if (_recordedVideoSession || _liveVideoSession) _graphsSourceSwitch(),
      ..._videoRunGraphs(),
    ] else if (_extraGraphsExpanded && (_recordedVideoSession || _liveVideoSession) && _videoRun != null) ...[
      _graphsSourceSwitch(),
      ..._liveGraphs(),
    ]
    else if (_extraGraphsExpanded)
      ..._liveGraphs(),
  ];

  /// The recording's own temperature, FPS and power graphs.
  List<Widget> _liveGraphs() => [
    const SizedBox(height: 12),
    const Text(
      'Battery temperature over the session (°C)',
      style: TextStyle(fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 12),
    _series(_temps, const Color(0xFFFF7043), '°'),
    _statsText(_temps, decimals: 1, unit: '°C'),
    if (_headroom.length >= 2) ...[
      const SizedBox(height: 28),
      const Text(
        'Heat level (0 = cool, 1 = phone slows down)',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        'How close the phone is to slowing itself down to cool off, from its own '
        'heat sensors (it may briefly go above 1). Near 1 the phone slows down and '
        'the FPS drops. It reacts faster than the battery temperature and compares '
        'better between phones.',
        style: TextStyle(color: Colors.white70, fontSize: 12),
      ),
      const SizedBox(height: 12),
      _series(_headroom, const Color(0xFFEF5350), ''),
    ] else ...[
      const SizedBox(height: 12),
      const Text(
        'Heat level: this phone does not report it (common, not an error). Watch '
        'the battery temperature and the detector time per frame instead: both '
        'rise when the phone gets hot.',
        style: TextStyle(color: Colors.white54, fontSize: 12),
      ),
    ],
    const SizedBox(height: 28),
    const Text(
      'Detector FPS over the session',
      style: TextStyle(fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 12),
    _series(_fps, const Color(0xFF66BB6A), ''),
    _statsText(_fps, decimals: 1, unit: ' fps'),
    if (_infMs.length >= 2) ...[
      const SizedBox(height: 28),
      const Text(
        'Detector time per frame (ms)',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      // Precision matters here (round 188, owner question): the plotted
      // `inf_ms` is the native timer around rtModel.run() ONLY — tensor
      // upload, interpreter run, output read-back. Image prep (`pre_ms`)
      // and box post-processing/NMS (`post_ms`) are logged in the same fps
      // records but are NOT in this graph. Raw per-frame values, never
      // smoothed. Keep this text in sync with ObjectDetector.kt's timing.
      const Text(
        'How long the detector needs for one frame, in milliseconds (each point '
        'is one frame). When the phone gets hot it slows its chip down to cool '
        'off: this number then climbs, often before the battery temperature '
        'rises, and the FPS above drops. Compare it with the other graphs on '
        'the same time axis.',
        style: TextStyle(color: Colors.white70, fontSize: 12),
      ),
      const SizedBox(height: 12),
      _series(_infMs, const Color(0xFF42A5F5), ' ms'),
      _statsText(_infMs, decimals: 1, unit: ' ms'),
    ],
    ..._phoneLoadGraphs(),
    const SizedBox(height: 28),
    const Text(
      'Power draw over the session (W)',
      style: TextStyle(fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 4),
    if (_chargingDuringSession)
      const Text(
        'Not shown: the phone was plugged in during (part of) this session. '
        'The battery sensor then measures the charging current, not what the '
        'phone uses, so a power or energy estimate would be wrong. '
        'Only a session fully on battery shows this graph.',
        style: TextStyle(color: Color(0xFFFFB74D), fontSize: 12),
      )
    else ...[
      // Honesty text (round 188, owner question): name the estimate's
      // source and the silent corrections, and frame the battery-% drop
      // as the cross-check. Keep in sync with [_buildEnergySeries].
      const Text(
        'How much power the phone uses, in watts (W), estimated from its own '
        'battery sensors. Phone sensors are coarse, so take it as an '
        'indication, not a lab measurement. The battery percentage used '
        '(below) is an independent check.',
        style: TextStyle(color: Colors.white70, fontSize: 12),
      ),
      const SizedBox(height: 12),
      _series(_power, const Color(0xFFFFCA28), 'W'),
      if (_powerAvg != null) ...[
        const SizedBox(height: 8),
        Text(
          'Average power ${_powerAvg!.toStringAsFixed(2)} W '
          '(median ${_powerMedian!.toStringAsFixed(2)} W; '
          'min ${_powerMin!.toStringAsFixed(2)}, max ${_powerMax!.toStringAsFixed(2)} W). '
          'Total energy this session ≈ ${_energyTotalWh!.toStringAsFixed(2)} Wh '
          '(the power curve summed over the session); '
          'battery used: $_batteryUsedLabel.',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    ],
  ];

  /// Recorded bursts (round 239): which graphs the extra section shows.
  Widget _graphsSourceSwitch() => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: SegmentedButton<bool>(
      segments: const [
        ButtonSegment(value: false, label: Text('While recording')),
        ButtonSegment(value: true, label: Text('While the detector ran')),
      ],
      selected: {_graphsOfAnalysis},
      showSelectedIcon: false,
      onSelectionChanged: (s) async {
        setState(() => _graphsOfAnalysis = s.first);
        _clearGraphData();
        await _loadGraphs();
      },
    ),
  );

  /// The extra graphs of an imported video session (round 232): the phone
  /// while "Run AI on videos" ran, from the samples [VideoDetector] writes,
  /// on the analysis clock of [VideoRunSamples] (runs back to back, a gap
  /// between two runs, cooling pauses shaded).
  List<Widget> _videoRunGraphs() {
    final s = _videoSamples;
    if (s == null || s.isEmpty) {
      return [
        const SizedBox(height: 8),
        Text(
          _graphsLoading
              ? '…'
              : 'No measurements yet. The phone\'s temperature, power and '
                    'speed are written down while "Find animals in videos" runs.',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ];
    }
    final range = (0, s.totalMs);
    final shade = s.pauses;
    const note = TextStyle(color: Colors.white70, fontSize: 12);
    const bold = TextStyle(fontWeight: FontWeight.bold);
    final mean = s.meanFramesPerS;
    final every = s.sampleSeconds.isEmpty ? '…' : s.sampleSeconds.join(' or ');
    return [
      const SizedBox(height: 12),
      const Text('While the detector ran on the videos', style: bold),
      const SizedBox(height: 4),
      Text(
        'Measured every $every s while "Find animals in videos" ran. '
        'Time runs over the analysis only: a run that was stopped and '
        'continued later shows as a gap. Grey bands: paused for the phone '
        'to cool down.',
        style: note,
      ),
      const SizedBox(height: 8),
      _stat(
        'Analysis time',
        '${_hmsLabel(s.runMs)}${s.runs > 1 ? ' in ${s.runs} runs' : ''}',
      ),
      _stat('Frames analyzed', '${s.frames}'),
      _stat(
        'Speed while running',
        mean == null ? 'unknown' : '${mean.toStringAsFixed(1)} frames per second',
      ),
      _stat(
        'Cooling pauses',
        s.pauses.isEmpty
            ? 'none'
            : '${s.pauses.length} (${_hmsLabel(s.pausedMs)} in total)',
      ),
      _stat(
        'Energy used',
        _chargingDuringSession
            ? 'not measured: the phone was plugged in'
            : _energyTotalWh == null
            ? 'unknown'
            : '≈ ${_energyTotalWh!.toStringAsFixed(2)} Wh (on battery)',
      ),
      const SizedBox(height: 20),
      const Text('Battery temperature (°C)', style: bold),
      const SizedBox(height: 12),
      _series(_temps, const Color(0xFFFF7043), '°', range: range, shade: shade),
      _statsText(_temps, decimals: 1, unit: '°C'),
      if (_headroom.length >= 2) ...[
        const SizedBox(height: 28),
        const Text(
          'Heat level (0 = cool, 1 = phone slows down)',
          style: bold,
        ),
        const SizedBox(height: 4),
        const Text(
          'How close the phone is to slowing itself down to cool off, from '
          'its own heat sensors.',
          style: note,
        ),
        const SizedBox(height: 12),
        _series(_headroom, const Color(0xFFEF5350), '', range: range, shade: shade),
      ] else ...[
        const SizedBox(height: 12),
        const Text(
          'Heat level: this phone does not report it (common, not an error).',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
      const SizedBox(height: 28),
      const Text('Frames analyzed per second', style: bold),
      const SizedBox(height: 4),
      const Text(
        'Video frames the detector finished per second of clock time, averaged '
        'since the previous measurement; 0 while paused to cool down. It '
        'drops when the phone slows itself down to cool off.',
        style: note,
      ),
      const SizedBox(height: 12),
      _series(_fps, const Color(0xFF66BB6A), '', range: range, shade: shade),
      // Not the plain average of the points: the zeros of a cooling pause
      // would pull it far below "Speed while running" above.
      if (_seriesStats(s.framesPerSRunning) case final st?)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Without the cooling pauses: median ${st.median.toStringAsFixed(1)} fps; '
            'min ${st.min.toStringAsFixed(1)} fps, max ${st.max.toStringAsFixed(1)} fps. '
            'The average is "Speed while running" above.',
            style: note,
          ),
        ),
      if (_infMs.length >= 2) ...[
        const SizedBox(height: 28),
        const Text('Detector time per frame (ms)', style: bold),
        const SizedBox(height: 4),
        // Keep in sync with VideoFrameSource.kt: inferMs times the whole
        // predict() call (input preparation, model run, box decoding + NMS).
        const Text(
          'How long the detector needs for one frame, in milliseconds, '
          'averaged since the previous measurement (reading the frame from the '
          'video is not included). It climbs when the phone slows its chip down '
          'to cool off.',
          style: note,
        ),
        const SizedBox(height: 12),
        _series(_infMs, const Color(0xFF42A5F5), ' ms', range: range, shade: shade),
        _statsText(_infMs, decimals: 1, unit: ' ms'),
      ],
      ..._phoneLoadGraphs(range: range, shade: shade),
      const SizedBox(height: 28),
      const Text('Power draw (W)', style: bold),
      const SizedBox(height: 4),
      if (_chargingDuringSession)
        const Text(
          'Not shown: the phone was plugged in during (part of) the analysis. '
          'The battery sensor then measures charging current, not what the '
          'phone uses. Run the analysis on battery to see this graph.',
          style: TextStyle(color: Color(0xFFFFB74D), fontSize: 12),
        )
      else ...[
        const Text(
          'Estimated from the phone\'s own battery sensors (current × '
          'voltage, lightly smoothed, with the same corrections as for live '
          'sessions). A good indication, not a lab measurement.',
          style: note,
        ),
        const SizedBox(height: 12),
        _series(_power, const Color(0xFFFFCA28), 'W', range: range, shade: shade),
        if (_powerAvg != null) ...[
          const SizedBox(height: 8),
          Text(
            'Average power ${_powerAvg!.toStringAsFixed(2)} W '
            '(median ${_powerMedian!.toStringAsFixed(2)} W; '
            'min ${_powerMin!.toStringAsFixed(2)}, max ${_powerMax!.toStringAsFixed(2)} W).',
            style: note,
          ),
        ],
      ],
    ];
  }

  /// The two per-session visit charts (round 187), between the timeline and
  /// the "Extra graphs" disclosure: how long visits lasted (histogram with a
  /// user-picked bin width) and at which hours they started (the Dashboard's
  /// "Visits by time of day", now also available per session). Only rendered
  /// when the session has visits — no-AI sessions already explain themselves
  /// in the timeline area.
  List<Widget> _visitCharts() {
    final durationsMs = [for (final s in _spans.values) s.$2 - s.$1];
    final hist = visitDurationHistogram(durationsMs, _durationBinSeconds);
    final n = hist.values.length;
    // Sparse x labels: the first, middle and last bin's lower edge; the
    // overflow bin (everything at/over the last bar) reads "≥ …".
    String? histLabel(int i) {
      if (i != 0 && i != n - 1 && i != n ~/ 2) return null;
      final s = compactSecondsLabel(hist.binStartSeconds(i));
      return (hist.overflow && i == n - 1) ? '≥$s' : s;
    }

    final byHour = visitsByHour([for (final s in _spans.values) s.$1]);
    final durationStats = _seriesStats([
      for (final ms in durationsMs) (0, ms / 1000.0),
    ]);
    return [
      const SizedBox(height: 28),
      const Text(
        'Track length distribution',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      Text(
        'How long the track IDs lasted, each from the first to the last frame the tracker '
        'saw the animal in${_visitsAfterwards ? ' (the same length as in track_ids.csv)' : ''}. '
        'Each bar counts the track IDs whose length falls in that time bin, so you can see at a '
        'glance whether track IDs cluster around one typical length or spread out.',
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          const Text('Bin width: ', style: TextStyle(color: Colors.white70)),
          DropdownButton<int>(
            value: _durationBinSeconds,
            isDense: true,
            items: [
              for (final s in _durationBinChoices)
                DropdownMenuItem(
                  value: s,
                  child: Text(
                    s < 60
                        ? '$s s'
                        : s < 3600
                        ? '${s ~/ 60} min'
                        : '${s ~/ 3600} h',
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) _setDurationBin(v);
            },
          ),
        ],
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 120,
        width: double.infinity,
        child: MiniBarChart(values: hist.values, xLabelFor: histLabel),
      ),
      if (durationStats != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '${durationsMs.length} track ID${durationsMs.length == 1 ? '' : 's'}; '
            'average ${durationStats.mean.toStringAsFixed(1)} s '
            '(median ${durationStats.median.toStringAsFixed(1)} s); '
            'shortest ${durationStats.min.toStringAsFixed(1)} s, '
            'longest ${durationStats.max.toStringAsFixed(1)} s.',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      const SizedBox(height: 28),
      const Text(
        'Track IDs by time of day',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        'When this session\'s track IDs began, per hour of the day (local time). '
        'The Dashboard adds this chart up over all sessions, leaving out videos that do not say when they were filmed.',
        style: TextStyle(color: Colors.white70, fontSize: 12),
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 120,
        width: double.infinity,
        child: MiniBarChart(
          values: byHour,
          xLabelFor: (i) => switch (i) {
            0 || 6 || 12 || 18 => '$i h',
            _ => null,
          },
        ),
      ),
    ];
  }

  /// A small grey line printed under a graph with the series' average, median,
  /// minimum and maximum — the same shape of summary the power graph already
  /// shows. [decimals] controls the precision and [unit] is appended to every
  /// number (e.g. "°C", " fps"). Returns an empty box when there are no samples.
  /// Round 346: memory in use and this app's processor cores, from the same
  /// readings as the temperature (live sessions and video runs alike). One
  /// line instead of empty charts for sessions of older app versions.
  List<Widget> _phoneLoadGraphs({(int, int)? range, List<(int, int)> shade = const []}) {
    const bold = TextStyle(fontWeight: FontWeight.bold);
    const note = TextStyle(color: Colors.white70, fontSize: 12);
    if (_memUsedGb.length < 2 && _appCpuCores.length < 2) {
      return const [
        SizedBox(height: 12),
        Text(
          'Memory and processor use: not in this session\'s records (an older app version '
          'recorded it).',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ];
    }
    return [
      if (_memUsedGb.length >= 2) ...[
        const SizedBox(height: 28),
        const Text('Memory in use, whole phone (GB)', style: bold),
        const SizedBox(height: 4),
        const Text(
          'Everything on the phone together, FaunaPulse and its loaded model included. When '
          'it nears the phone\'s total, Android starts closing apps (background ones first).',
          style: note,
        ),
        const SizedBox(height: 12),
        _series(_memUsedGb, const Color(0xFFAB47BC), ' GB', range: range, shade: shade),
        _statsText(_memUsedGb, decimals: 2, unit: ' GB'),
      ],
      if (_appCpuCores.length >= 2) ...[
        const SizedBox(height: 28),
        const Text('Processor cores kept busy by FaunaPulse', style: bold),
        const SizedBox(height: 4),
        const Text(
          'This app\'s own process only (the camera and the video decoder run in other '
          'Android processes). About the "CPU threads" setting while the model runs on the '
          'CPU; under 1 while it runs on the GPU.',
          style: note,
        ),
        const SizedBox(height: 12),
        _series(_appCpuCores, const Color(0xFF26A69A), '', range: range, shade: shade),
        _statsText(_appCpuCores, decimals: 1, unit: ' cores'),
      ],
    ];
  }

  Widget _statsText(
    List<(int ms, double v)> points, {
    required int decimals,
    String unit = '',
  }) {
    final s = _seriesStats(points);
    if (s == null) return const SizedBox.shrink();
    String f(double v) => '${v.toStringAsFixed(decimals)}$unit';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        'Average ${f(s.mean)} (median ${f(s.median)}); '
        'min ${f(s.min)}, max ${f(s.max)}.',
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    );
  }

  Widget _timeline() {
    if (_spans.isEmpty ||
        _startMs == null ||
        _endMs == null ||
        _endMs! <= _startMs!) {
      return Center(
        key: _timelineKey,
        child: Text(
          _visitsFromPhotos
              ? 'No track IDs found in the photos.'
              : _motionOnlySession
              ? 'Motion-triggered photos: $_photosNoTrackIdsYet'
              : _timeLapseSession && !_videoSession
              ? 'Time-lapse photos: $_photosNoTrackIdsYet'
              : _visitsAfterwards
              ? 'No track IDs found in the videos.'
              : _videoSession
              ? '${_importedVideoSession ? 'Imported videos' : 'Video bursts'}: no track IDs yet. "Find animals in videos" '
                    '(Video tab, or the session\'s ⋮ menu on the Sessions screen) finds the '
                    'animals, then "Find track IDs" there follows each one from frame to frame.'
              : 'No track IDs recorded.',
          textAlign: TextAlign.center,
        ),
      );
    }
    final ids = _spans.keys.toList()
      ..sort((a, b) => _spans[a]!.$1.compareTo(_spans[b]!.$1));
    // Collapsed: a short placeholder (keyed so the floating toggle still tracks
    // visibility), so a long Gantt no longer forces lots of scrolling.
    if (!_showTimeline) {
      return Container(
        key: _timelineKey,
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'Track ID timeline hidden (${ids.length} track ID'
          '${ids.length == 1 ? '' : 's'}). Use the button below to show it.',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      );
    }
    final laneHeight = ids.length > 120
        ? 8.0
        : ids.length > 40
        ? 14.0
        : 26.0;
    const axisHeight = 28.0;
    return SizedBox(
      key: _timelineKey,
      height: ids.length * laneHeight + axisHeight,
      child: CustomPaint(
        size: Size.infinite,
        painter: _GanttPainter(
          ids: ids,
          spans: _spans,
          startMs: _startMs!,
          endMs: _endMs!,
          laneHeight: laneHeight,
          axisHeight: axisHeight,
          showLabels: laneHeight >= 14.0,
        ),
      ),
    );
  }

  /// A line graph over the session, or over [range] (the analysis clock of
  /// an imported video session), with the [shade] spans greyed.
  Widget _series(
    List<(int ms, double v)> points,
    Color color,
    String unit, {
    (int, int)? range,
    List<(int, int)> shade = const [],
  }) {
    final startMs = range?.$1 ?? _startMs, endMs = range?.$2 ?? _endMs;
    if (points.length < 2 ||
        startMs == null ||
        endMs == null ||
        endMs <= startMs) {
      return const Center(child: Text('Not enough samples.'));
    }
    return SizedBox(
      height: 160,
      child: CustomPaint(
        size: Size.infinite,
        painter: _SeriesPainter(
          points: points,
          startMs: startMs,
          endMs: endMs,
          color: color,
          unit: unit,
          shade: shade,
        ),
      ),
    );
  }
}
