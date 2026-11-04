// FaunaPulse, session settings sheet: the Session tab (folder, trigger, session length, schedule, display).
//
// A `part` of settings_sheet.dart: that sheet's State class is split into
// extensions, one file per tab, so each file stays readable while the private
// fields stay shared (Dart privacy is per library, and a part file belongs to
// the main file's library). Fields, getters and the lifecycle overrides stay
// in the main file; part files hold methods only.
//
// The extensions below are the State's own code, so calling setState here is
// correct; the analyzer cannot tell an extension from outside code.
// ignore_for_file: invalid_use_of_protected_member

part of '../settings_sheet.dart';

extension _SettingsSessionTab on _SettingsSheetState {
  // --- Tab 1: Session configuration --------------------------------------

  Widget _sessionTab() => ListView(
    children: [
      const HelpLabel(
        label: 'Output folder',
        helperText:
            'The folder this session\'s photos and log file are saved into. '
            'A good name says what you are recording, e.g. the target '
            'flower species.',
      ),
      TextField(
        controller: _folder,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(
          hintText: 'session',
          hintStyle: TextStyle(color: Colors.white38),
        ),
        onChanged: (v) => setState(() => _c = _c.copyWith(folderName: v)),
      ),
      const SizedBox(height: 16),

      // The helper explains the currently selected mode (it follows the
      // dropdown), so the ⓘ always answers "what does my choice mean".
      HelpLabel(
        label: 'Capture trigger (what causes photos)',
        helperText: switch (_c.captureTrigger) {
          CaptureTrigger.detector =>
            'The detection model runs on the phone during the session: it finds '
                'and follows the animals (track IDs), takes photos of each track ID '
                'and logs when each one is seen.',
          CaptureTrigger.motion =>
            'Takes photos whenever something moves in the yellow square '
                '(ROI). No detection model runs, which saves a lot of battery, '
                'so no track IDs or names are recorded during the session; '
                'find and name the animals later with "Find animals in photos" '
                'and "Identify organisms". What counts as movement is set '
                'under "Gate sensitivity" on the Power tab. Wind or shadows '
                'only cost an extra photo.',
          CaptureTrigger.timelapse =>
            'Photos or video clips on a fixed schedule, with no detection '
                'and no motion check: the cheapest mode. Each burst lasts '
                '"Photo duration" ("Burst duration" for video; photos are '
                'taken every "Photo step"), then pauses for "Time between '
                'bursts" below before the next burst. Set the pause to 0 to '
                'record without breaks. Meant for running a detector on the '
                'saved photos or videos afterwards.',
        },
      ),
      DropdownButton<CaptureTrigger>(
        value: _c.captureTrigger,
        isExpanded: true,
        dropdownColor: Colors.black87,
        items: [
          // Round 268: no model ships with the app, so AI mode is offered
          // only once a detection model is on the phone.
          DropdownMenuItem(
            value: CaptureTrigger.detector,
            enabled: _hasDetector,
            child: Text(
              _hasDetector
                  ? 'Live detection - detect & track in real time'
                  : 'Live detection (needs a detection model)',
              style: TextStyle(
                color: _hasDetector ? Colors.white : Colors.white38,
                fontSize: 13,
              ),
            ),
          ),
          const DropdownMenuItem(
            value: CaptureTrigger.motion,
            child: Text(
              'Motion-triggered photos',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          const DropdownMenuItem(
            value: CaptureTrigger.timelapse,
            child: Text(
              'Time-lapse photo or video bursts',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
        // The motion trigger needs the gate (it IS the trigger); the gate
        // runs in that mode whatever the switch says (camera_session_screen
        // _pushMotionGate), so the trigger never writes the switch (round 313:
        // a trip through "Motion-triggered photos" left the gate on for live
        // detection).
        onChanged: (t) => setState(() => _c = _c.copyWith(captureTrigger: t)),
      ),
      if (_c.timeLapseCapture) ..._timeLapseSaveAsFields(),
      if (_c.detectorEnabled && !_hasDetector)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: NoModelNotice(identification: false, onGet: _manageModels),
        ),
      // Round 240 (video plan): always visible in AI mode, not behind an ⓘ.
      if (_c.detectorEnabled && _hasDetector)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'Live detection warms the phone: the detector works on the camera picture all session '
            'long, and older or hot phones can drop to a few frames per second, missing fast '
            'insects. For long or hot sessions, choose "Time-lapse" with "Save bursts as: '
            'Video" and run the detector later at home ("Find animals in videos").',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ),
      const SizedBox(height: 12),

      // Session length sits right after the trigger (round 159): folder,
      // trigger and length are the three settings every session needs; the
      // photo-timing details below are fine on their defaults.
      ..._sessionLengthFields(),
      const SizedBox(height: 8),

      NotApplicable(
        applies: !_c.timeLapseVideo,
        note: 'Not used for video bursts: a clip keeps every frame.',
        child: NumericSettingField(
          label: 'Photo step',
          value: _c.stepSeconds,
          min: 0.1,
          max: 10,
          decimals: 1,
          unitSuffix: 's',
          helperText:
              'Seconds between saved photos of the yellow square (ROI), per '
              'track ID (live detection) or within one motion or time-lapse '
              'burst (0.1–10). Default 1 s, enough to follow a visit without '
              'filling the storage. A shorter step gives Identify more pictures '
              'of each track ID, which helps most with short track IDs; with '
              'fast crops it does not slow the detector, but the storage fills '
              'faster (0.5 s doubles it). Below about 0.5 s, set "ROI photo source" '
              '(Photos tab) to "Fast crops only": high-res photos take '
              '0.5–1.5 s each. Fast crops can be no bigger than the live '
              'camera picture: raise "Live stream resolution" (Photos tab, '
              'Advanced) if they come out too small.',
          onChanged: (v) => setState(() => _c = _c.copyWith(stepSeconds: v)),
        ),
      ),
      DurationSettingField(
        label: _c.timeLapseVideo ? 'Burst duration (clip length)' : 'Photo duration',
        valueSeconds: _c.durationSeconds,
        minSeconds: 1,
        maxSeconds: 86400,
        helperText:
            'How long photos keep being saved: per track ID (live detection), '
            'per motion event (motion trigger; a new event starts once the '
            'gate has slept and motion returns), or per time-lapse burst (burst duration). '
            'For photos, it should be a whole multiple of the step.',
        onChanged: (v) => setState(() => _c = _c.copyWith(durationSeconds: v)),
      ),
      if (_c.timeLapseCapture) ...[
        DurationSettingField(
          label: 'Time between bursts',
          valueSeconds: _c.timeLapseGapSeconds,
          minSeconds: 0,
          maxSeconds: 86400,
          helperText:
              'The break between photo bursts: after each burst the camera '
              'waits this long before the next burst starts. This break is '
              'when "Turn camera off between bursts" can power the camera '
              'down. 0 = no break (continuous photos every step). '
              'Default 30 min.',
          onChanged: (v) =>
              setState(() => _c = _c.copyWith(timeLapseGapSeconds: v)),
        ),
        // Round 163 (perf review E3): camera parking between bursts. The
        // too-short-gap warning is live status, so it stays outside the ⓘ.
        HelpSwitchTile(
          title: 'Turn camera off between bursts',
          helperText:
              'Switches the camera off after each burst and back on shortly '
              'before the next one ("Camera wake lead"). On by default, '
              'because a waiting camera is the phone\'s biggest source of '
              'heat and battery use. The picture freezes while the camera is '
              'off; that is normal. Needs at least 30 s between bursts. For '
              'unattended runs, also use the screen-off (moon) button.',
          statusText: _c.timeLapseGapSeconds < 30
              ? 'Your "Time between bursts" is under 30 s, so the camera '
                    'will stay on.'
              : null,
          statusColor: Colors.amberAccent,
          value: _c.timeLapseCameraSleep,
          onChanged: (v) =>
              setState(() => _c = _c.copyWith(timeLapseCameraSleep: v)),
        ),
        if (_c.timeLapseCameraSleep)
          NumericSettingField(
            label: 'Camera wake lead',
            value: _c.timeLapseWakeLeadSeconds,
            min: 1,
            max: 60,
            decimals: 0,
            unitSuffix: 's',
            helperText:
                'How many seconds before each burst the camera is switched '
                'back on. After being off, the camera needs a few seconds to '
                'set its brightness and move the lens back to your focus. '
                'Default 10 s, because with less the first photo of a burst '
                'can be dark or blurred. Raise it if first photos still look '
                'wrong.',
            onChanged: (v) =>
                setState(() => _c = _c.copyWith(timeLapseWakeLeadSeconds: v)),
          ),
        // Round 180: nocturnal monitoring — LED torch around each burst. The
        // torch-never-off warning is live status, so it stays outside the ⓘ.
        HelpSwitchTile(
          title: 'Torch during bursts (night)',
          helperText:
              'For night monitoring: the phone\'s flashlight switches on a '
              'few seconds before each burst ("Torch lead"), so the first '
              'photo is already bright, and switches off in the break. The '
              'first burst of a session starts at once. If the phone has no '
              'flashlight, a message says so and photos continue without '
              'light.',
          statusText:
              _c.timeLapseTorch &&
                  _c.timeLapseTorchLeadSeconds >= _c.timeLapseGapSeconds
              ? 'With your current settings the torch stays on for the '
                    'whole session (the torch lead is not shorter than the '
                    'break between bursts).'
              : null,
          statusColor: Colors.amberAccent,
          value: _c.timeLapseTorch,
          onChanged: (v) => setState(() => _c = _c.copyWith(timeLapseTorch: v)),
        ),
        if (_c.timeLapseTorch)
          NumericSettingField(
            label: 'Torch lead',
            value: _c.timeLapseTorchLeadSeconds,
            min: 1,
            max: 60,
            decimals: 0,
            unitSuffix: 's',
            helperText:
                'How many seconds before each burst the torch comes on, '
                'giving auto-exposure time to settle under the lit scene '
                'before the first photo. Exposure usually settles within 1 '
                'to 2 seconds once the light is on; the default 5 leaves '
                'margin. With "Turn camera off between bursts" the camera '
                'wakes at whichever lead is longer, and the torch lights as '
                'soon as the camera is back on.',
            onChanged: (v) =>
                setState(() => _c = _c.copyWith(timeLapseTorchLeadSeconds: v)),
          ),
      ],
      if (!_c.isTimeLapseValid && !_c.timeLapseVideo)
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            '⚠ Duration should be a whole multiple of the step.',
            style: TextStyle(color: Colors.orangeAccent, fontSize: 13),
          ),
        ),

      // Reference photos (wire names stay gt_* from the r107 "ground-truth
      // frames" original). Mode-aware per the r147 pattern: greyed and shown
      // OFF in time-lapse mode (the switch says what actually happens; the
      // stored preference survives the mode round-trip).
      HelpSwitchTile(
        title: 'Reference photos',
        helperText:
            'Saves an ROI photo at a fixed interval, whether or not '
            'anything is detected. Lets you check afterwards what the '
            'camera really saw, including animals the detector may have '
            'missed. Same size as normal photos (Photos tab → "Saved photo '
            'side").',
        statusText: _c.timeLapseCapture
            ? 'Not used in time-lapse mode; photos come on a clock there '
                  'anyway.'
            : null,
        value: !_c.timeLapseCapture && _c.gtFramesEnabled,
        onChanged: _c.timeLapseCapture
            ? null
            : (v) => setState(() => _c = _c.copyWith(gtFramesEnabled: v)),
      ),
      if (_c.gtFramesEnabled && !_c.timeLapseCapture)
        DurationSettingField(
          label: 'Reference photo interval',
          valueSeconds: _c.gtFrameSeconds,
          minSeconds: 1,
          maxSeconds: 3600,
          helperText:
              'Time between reference photos. Default 30 s (about 120 '
              'photos per hour); shorter catches insects that stay only briefly but uses '
              'more storage.',
          onChanged: (v) => setState(() => _c = _c.copyWith(gtFrameSeconds: v)),
        ),

      const Divider(color: Colors.white24),
      HelpSwitchTile(
        title: 'Scheduled recording',
        helperText:
            'The record button then starts a multi-window run: record '
            'during each daily window below, sleep (screen dark, camera '
            'off) in between. Each window is saved as its own session. The '
            'session length above is not used: each window ends at its own '
            'end time.',
        value: _c.scheduleEnabled,
        onChanged: (v) => setState(() => _c = _c.copyWith(scheduleEnabled: v)),
      ),
      if (_c.scheduleEnabled) ...[
        for (var i = 0; i < _c.scheduleWindows.length; i++) _windowRow(i),
        if (_c.scheduleWindows.length < 3)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(
                () => _c = _c.copyWith(
                  scheduleWindows: [
                    ..._c.scheduleWindows,
                    // A fresh window defaults to the afternoon so it doesn't
                    // instantly overlap the default morning one.
                    const ScheduleWindow(15 * 60, 20 * 60),
                  ],
                ),
              ),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add window'),
            ),
          ),
        if (!_c.isScheduleValid)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              '⚠ Windows must not overlap, and each must end after it starts '
              '(a window cannot cross midnight: split it in two).',
              style: TextStyle(color: Colors.orangeAccent, fontSize: 13),
            ),
          ),
        NumericSettingField(
          label: 'Days to run',
          value: _c.scheduleDays.toDouble(),
          min: 1,
          max: 14,
          decimals: 0,
          helperText:
              'The windows repeat every day for this many days (1–14). '
              'Day 1 is the day you start the run; windows already past '
              'at that moment are skipped.',
          onChanged: (v) =>
              setState(() => _c = _c.copyWith(scheduleDays: v.round())),
        ),
      ],

      const Divider(color: Colors.white24),
      // Display toggles all have good defaults, so they sit folded (round
      // 159). "Show FPS" moved in from the AI tab the same round: it is a
      // display toggle, not an AI setting. "Show tips and notes" left for the
      // home screen's menu (an app-level preference, not per-session).
      FoldSection(
        title: 'On-screen display',
        subtitle: 'Boxes, info panel, FPS readout, capture flash.',
        helperText:
            'Display choices only: drawing overlays uses the phone briefly '
            'each frame, but detection, tracking and logging run the same '
            'either way.',
        children: [
          // Locked off in the no-AI modes: the detector never runs there, so
          // there is nothing to draw. The saved preference is untouched — it
          // comes back when the AI mode is selected again (r147).
          HelpSwitchTile(
            title: 'Show detection boxes & track IDs',
            helperText:
                'The light-blue boxes drawn around each detected insect on '
                'the live picture, with its track ID, name and score (for '
                'example "#3 bee  Conf.: 0.72").',
            statusText: _c.detectorEnabled
                ? null
                : 'Live detection mode only; there are no detections to draw '
                      'in this mode.',
            value: _c.detectorEnabled && _c.showBoxes,
            onChanged: _c.detectorEnabled
                ? (v) => setState(() => _c = _c.copyWith(showBoxes: v))
                : null,
          ),
          HelpSwitchTile(
            title: 'Show on-screen info panel',
            helperText:
                'The top-left readouts (FPS, model, engine, stream, ROI '
                'size, temperature, track count). Off = only the ROI box '
                'and recording controls remain.',
            value: _c.showOverlayInfo,
            onChanged: (v) =>
                setState(() => _c = _c.copyWith(showOverlayInfo: v)),
          ),
          HelpSwitchTile(
            title: 'Show FPS',
            helperText:
                'Includes the frames-per-second numbers (camera and '
                'detector rate) in the on-screen info panel and its '
                'collapsed one-line summary.',
            value: _c.showFps,
            onChanged: (v) => setState(() => _c = _c.copyWith(showFps: v)),
          ),
          HelpSwitchTile(
            title: 'Flash ROI border when a photo is saved',
            helperText:
                'The ROI outline blinks green for a split second each time '
                'a photo is captured, so you can see captures happening.',
            value: _c.flashOnCapture,
            onChanged: (v) =>
                setState(() => _c = _c.copyWith(flashOnCapture: v)),
          ),
          const SizedBox(height: 8),
        ],
      ),
      const SizedBox(height: 8),
    ],
  );

  /// Session-length input: typed number + Minutes/Hours toggle. Extracted so
  /// the Setup tab can place it directly after the capture trigger (round 159).
  List<Widget> _sessionLengthFields() => [
    const HelpLabel(
      label: 'Session length',
      helperText:
          'Recording stops by itself after this time (default 60 min). In '
          'Hours you can type decimals, for example 1.5. Not used for '
          'scheduled recording: there each window ends at its own end time.',
    ),
    Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextField(
            controller: _sessionLen,
            keyboardType: TextInputType.numberWithOptions(decimal: _sessionInHours),
            inputFormatters: [
              _sessionInHours
                  ? FilteringTextInputFormatter.allow(RegExp(r'^\d*[.,]?\d{0,2}'))
                  : FilteringTextInputFormatter.digitsOnly,
            ],
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: '60',
              hintStyle: const TextStyle(color: Colors.white38),
              errorText: _sessionLenError,
              errorMaxLines: 2,
            ),
            onChanged: (_) => _applySessionLength(),
          ),
        ),
        const SizedBox(width: 12),
        ToggleButtons(
          isSelected: [!_sessionInHours, _sessionInHours],
          borderColor: Colors.white24,
          selectedBorderColor: Colors.lightBlueAccent,
          color: Colors.white54,
          selectedColor: Colors.white,
          fillColor: Colors.white10,
          constraints: const BoxConstraints(minWidth: 64, minHeight: 40),
          // The unit changes how the length is shown, never the length
          // (round 313: 60 minutes switched to "60 h").
          onPressed: (i) => setState(() {
            _sessionInHours = i == 1;
            _sessionLenError = null;
            _sessionLen.text = _sessionLengthText();
          }),
          children: const [Text('Minutes'), Text('Hours')],
        ),
      ],
    ),
    // Live conversion readout: only worth showing in hours (in minutes it
    // would just repeat the typed number).
    if (_sessionInHours)
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          '= ${_c.sessionMinutes} min total',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ),
  ];

  /// One schedule-window row: "Window N  [06:00] – [10:00]  🗑". The time
  /// buttons open the system time picker; the delete icon appears only while
  /// more than one window remains (a schedule needs at least one).
  Widget _windowRow(int index) {
    final w = _c.scheduleWindows[index];
    // Round 313: compact buttons and a label that gives way, so two windows
    // (with the delete icon) fit a 360-dp phone such as the Galaxy M12.
    Widget timeButton({required bool isStart}) => OutlinedButton(
      onPressed: () => _pickWindowTime(index, isStart: isStart),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.white24),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 40),
      ),
      child: Text(isStart ? w.startLabel : w.endLabel),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Window ${index + 1}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          timeButton(isStart: true),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: Text('–', style: TextStyle(color: Colors.white54)),
          ),
          timeButton(isStart: false),
          if (_c.scheduleWindows.length > 1)
            IconButton(
              icon: const Icon(
                Icons.delete_outline,
                color: Colors.white54,
                size: 20,
              ),
              onPressed: () => setState(() {
                final windows = [..._c.scheduleWindows]..removeAt(index);
                _c = _c.copyWith(scheduleWindows: windows);
              }),
            ),
        ],
      ),
    );
  }

  /// Opens the system time picker for one end of a window and stores the
  /// result as minutes since midnight. An invalid combination (start ≥ end,
  /// overlap with another window) is allowed here and flagged by the warning
  /// under the rows — same lenient pattern as the time-lapse check.
  Future<void> _pickWindowTime(int index, {required bool isStart}) async {
    final w = _c.scheduleWindows[index];
    final current = isStart ? w.startMinute : w.endMinute;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
    );
    if (picked == null || !mounted) return;
    final minutes = picked.hour * 60 + picked.minute;
    setState(() {
      final windows = [..._c.scheduleWindows];
      windows[index] = isStart
          ? ScheduleWindow(minutes, w.endMinute)
          : ScheduleWindow(w.startMinute, minutes);
      _c = _c.copyWith(scheduleWindows: windows);
    });
  }
}
