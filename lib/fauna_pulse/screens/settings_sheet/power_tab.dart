// FaunaPulse, session settings sheet: the Power tab (heat, battery and rates).
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

extension _SettingsPowerTab on _SettingsSheetState {
  // --- Tab 4: Power — heat, battery and rates -----------------------------

  /// Round 355: a list instead of a number box. Each lens offers only certain
  /// rates, and a typed 20 on a lens with 15 and 30 ran at 15 without a word.
  /// Without a list from the camera, only the stored rate is shown: offering
  /// standard rates here could promise one this camera does not have.
  Widget _cameraRateDropdown() {
    final offered = widget.cameraFrameRates;
    final cap = _c.cameraFpsCap;
    // The rate the sheet opened with, not the current one: choosing "No limit"
    // must not take the old rate off the list.
    final opened = widget.config.normalizedFpsCaps().cameraFpsCap;
    final rates = offered.isNotEmpty ? offered : [if (opened > 0) opened];
    const itemStyle = TextStyle(color: Colors.white);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButton<int>(
          value: SessionConfig.cameraRateFor(cap, offered),
          isExpanded: true,
          dropdownColor: Colors.black87,
          items: [
            for (final rate in rates) DropdownMenuItem(value: rate, child: Text('$rate FPS', style: itemStyle)),
            const DropdownMenuItem(value: 0, child: Text('No limit (the phone chooses)', style: itemStyle)),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _c = _c.withCameraFpsCap(v));
          },
        ),
        if (offered.isEmpty)
          const Text(
            'The rates of this camera are shown once its picture is on screen.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
      ],
    );
  }

  Widget _powerTab() => ListView(
    children: [
      const HelpLabel(
        label: 'Trade detection speed against phone heat and battery',
        helperText:
            'The defaults suit long field sessions. A dark screen saves the '
            'most power of all: switch it off with the power button (the '
            'recording goes on), or use the screen-off (moon) button on the '
            'live camera screen.',
      ),
      const SizedBox(height: 4),
      // Round 293 (idea from FaunaLapse): the screen goes dark by itself.
      NumericSettingField(
        label: 'Screen off by itself after',
        value: _c.screenOffAfterMin.toDouble(),
        min: 0,
        max: SessionConfig.maximumScreenOffAfterMin.toDouble(),
        isInt: true,
        unitSuffix: 'min',
        helperText:
            'During a recording the screen stays on until this many minutes '
            'after your last touch. Then the screen turns black and the '
            "phone's own screen timeout switches it off; the recording goes "
            'on with the screen off. A touch, or waking the phone, brings it '
            'back. 0 = never (the default): the screen stays on for the '
            'whole recording. For unattended runs, 3 minutes leaves time to '
            'check the first photos. If the "Stay awake" developer option is '
            'switched on in the phone\'s own settings, the screen does not '
            'switch off while the phone charges (also from a power bank); it '
            'only turns black.',
        onChanged: (v) => setState(() => _c = _c.copyWith(screenOffAfterMin: v.round())),
      ),
      // Round 296 (idea from FaunaLapse): clean stops before the battery or
      // the storage runs out.
      NumericSettingField(
        label: 'Stop at battery level',
        value: _c.lowBatteryStopPercent.toDouble(),
        min: 0,
        max: 50,
        isInt: true,
        unitSuffix: '%',
        helperText:
            'When the phone runs on its own battery (not on a charger or '
            'power bank), the recording stops at this level and its files '
            'are closed properly, instead of the phone switching off in the '
            'middle of a video. 0 = never. Default 15 %: enough left for '
            'the phone to stay usable.',
        onChanged: (v) => setState(() => _c = _c.copyWith(lowBatteryStopPercent: v.round())),
      ),
      NumericSettingField(
        label: 'Keep free storage',
        value: _c.storageReserveMb.toDouble(),
        min: 50,
        max: 5000,
        isInt: true,
        unitSuffix: 'MB',
        helperText:
            'The recording stops when the free storage drops below this, '
            'with its files closed properly. Lowest 50 MB, so the phone and '
            'the last files still have room. Default 200 MB.',
        onChanged: (v) => setState(() => _c = _c.copyWith(storageReserveMb: v.round())),
      ),
      // Locked out in the no-AI modes — there is no inference to throttle.
      // The saved preference is untouched and returns with the AI mode
      // (r147; the detail fields below are hidden entirely then).
      HelpSwitchTile(
        title: 'Auto-adjust detector rate (reduces heat)',
        helperText:
            'At full speed the detector keeps the processor busy all the '
            'time; after a short while many phones overheat and slow '
            'themselves down, so far fewer pictures per second are checked. '
            'With this on, the app lowers the rate just enough to let the '
            'phone cool, which gives a steady rate instead. On by default; '
            'leave it on for long sessions.',
        statusText: _c.detectorEnabled
            ? null
            : 'Live detection mode only; the detector does not run in this '
                  'mode.',
        value: _c.detectorEnabled && _c.autoThrottle,
        onChanged: _c.detectorEnabled
            ? (v) => setState(() => _c = _c.copyWith(autoThrottle: v))
            : null,
      ),
      if (_c.detectorEnabled) ...[
        // This is the inference-FPS ceiling. A positive camera rate is also the
        // input's upper bound because the model cannot analyze absent frames.
        // It stays a typed number: unlike the camera, the detector can run at
        // any rate up to the camera's by skipping frames.
        NumericSettingField(
          // One name in both switch states (it is a ceiling either way), so
          // other help texts can refer to it by a single label.
          label: 'Max detector rate',
          value: _c.inferenceFps.toDouble(),
          min: SessionConfig.minimumInferenceFps.toDouble(),
          max: SessionConfig.maximumInferenceFps.toDouble(),
          isInt: true,
          unitSuffix: 'FPS',
          zeroMeans: 'same as the camera',
          warning: _c.effectiveInferenceFps < _c.inferenceFps
              ? 'Used: ${_c.effectiveInferenceFps} FPS, the Camera frame rate below.'
              : null,
          note: _c.inferenceFps == 0 ? 'Same as the camera: ${_c.effectiveInferenceFps} FPS.' : null,
          // The "ceiling, not a guarantee" paragraph used to sit as its own
          // text block under this section; merged into the ⓘ (round 181).
          helperText:
              'The most camera frames per second the detector may analyze '
              '(not the frame rate of the camera picture). 0 (the default) '
              'means the same as the Camera frame rate below, so the detector '
              'follows it when you choose another rate. ${_c.autoThrottle ? 'Auto-adjust may lower it when the phone is hot. ' : ''}'
              '${_c.cameraFpsCap > 0 ? 'It never runs above the Camera frame rate (now ${_c.cameraFpsCap} FPS): the detector cannot analyze frames the camera did not capture. ' : 'The camera has no limit below, so up to ${SessionConfig.maximumInferenceFps} FPS can be used. '}'
              'This is a ceiling, not a guaranteed speed: the real rate is '
              'also limited by the phone and the selected model. Lower rates '
              'use less power and are often steadier during long sessions.',
          onChanged: (v) {
            setState(() => _c = _c.withInferenceFps(v.round()));
          },
        ),
        // Floor + duty target are expert tuning, folded (round 159); the Max
        // rate above stays visible as the one day-to-day heat lever.
        if (_c.autoThrottle)
          FoldSection(
            title: 'Advanced (detector rate tuning)',
            subtitle:
                'The floor and the processor-load target the auto-adjust '
                'works within. Defaults suit most phones.',
            children: [
              NumericSettingField(
                label: 'Min detector rate',
                value: _c.minInferenceFps.toDouble(),
                min: 1,
                max: SessionConfig.maximumInferenceFps.toDouble(),
                isInt: true,
                unitSuffix: 'FPS',
                warning: _c.effectiveMinInferenceFps < _c.minInferenceFps
                    ? 'Used: ${_c.effectiveMinInferenceFps} FPS (never above the detector rate used).'
                    : null,
                helperText:
                    'The lowest the auto-adjust will drop to when the phone is hot, so '
                    'a session stays usable. Never above "Max detector rate". Default 3.',
                onChanged: (v) => setState(() => _c = _c.copyWith(minInferenceFps: v.round())),
              ),
              NumericSettingField(
                label: 'Target processor load',
                value: _c.throttleDutyTarget,
                min: 0.3,
                max: 0.8,
                decimals: 2,
                helperText:
                    'How busy the auto-adjust lets the processor stay on detection '
                    '(0.3–0.8; default 0.50 = about half the time). Lower = cooler and '
                    'steadier but fewer frames per second; higher = more frames but more '
                    'heat. 0.50 suits most phones.',
                onChanged: (v) =>
                    setState(() => _c = _c.copyWith(throttleDutyTarget: v)),
              ),
            ],
          ),
      ],
      const Divider(color: Colors.white24),

      // Asks the camera hardware itself to capture slower. Different from the
      // inference rate cap above, which only skips frames in software after
      // the camera already produced them. Heat territory, so it lives here
      // next to that cap (round 159; it sat on the Camera tab before).
      HelpLabel(
        label: 'Camera frame rate',
        // Round 110 wording: the old text used "default" for two different
        // things (the camera's own uncapped rate vs the app's factory
        // setting), which confused in the field. Keep the two ideas apart.
        helperText:
            'How many pictures per second the camera takes. Each phone and '
            'each lens offers only certain rates, so this list shows what this '
            'camera can do. ${SessionConfig.defaultCameraFpsCap} FPS is the '
            'starting choice because the running camera is the main source of '
            'heat, even while the detector sleeps. Lower = cooler phone but a '
            'less smooth picture. The detector never runs faster than this'
            '${_c.detectorEnabled ? ' (a note under "Max detector rate" says when this limits it)' : ''}. '
            '"No limit" lets the phone choose, about 30 on most phones.',
      ),
      _cameraRateDropdown(),
      const Divider(color: Colors.white24),

      // The capture trigger itself (AI detector / motion photos / time-lapse)
      // moved to the Setup tab in round 97 — this section keeps the motion
      // GATE and its sensitivity tuning, which serve both the detector mode
      // (sleep while the flower is empty) and the motion trigger.
      HelpSwitchTile(
        title: 'Motion gate (experimental): sleep while the flower is empty',
        helperText:
            'Runs the detector only when something moves inside the yellow '
            'square (ROI); a cheap brightness check looks at a few camera '
            'pictures per second ("Idle check rate" under "Gate sensitivity", '
            'shown below when the gate is on). This saves a lot of heat and '
            'battery during long empty periods. Made for a mounted phone: in '
            'the hand, shaking counts as movement, so the gate stays awake; '
            'that is normal. Off by default, because it can miss an insect '
            'that is very small or arrives very slowly. Before using it for '
            'counts, record the same flower once with the gate on and once '
            'with it off, and compare the track IDs.',
        statusText: _c.motionOnlyCapture
            ? 'Locked on: the motion capture trigger (Setup tab) needs it.'
            : _c.timeLapseCapture
            ? 'Not used in time-lapse mode.'
            : null,
        // Shown OFF in time-lapse mode even if the preference is on — the
        // gate is forced off natively there, and the switch should say what
        // actually happens (r147). The stored preference itself survives.
        value:
            !_c.timeLapseCapture &&
            (_c.motionOnlyCapture || _c.motionGateEnabled),
        // Locked on while the motion trigger depends on it; locked out in
        // time-lapse mode where it does nothing.
        onChanged: _c.motionOnlyCapture || _c.timeLapseCapture
            ? null
            : (v) => setState(() => _c = _c.copyWith(motionGateEnabled: v)),
      ),
      // Sensitivity tuning is hidden in time-lapse mode (the gate never runs
      // there). In motion mode these fields ARE the capture sensitivity (the
      // gate always runs in that mode), so the fold arrives OPEN
      // there; in AI mode it is collapsed expert tuning. The ValueKey rebuilds
      // the tile when the mode flips so initiallyExpanded applies again.
      if ((_c.motionGateEnabled || _c.motionOnlyCapture) && !_c.timeLapseCapture)
        FoldSection(
          key: ValueKey(_c.motionOnlyCapture),
          title: 'Gate sensitivity',
          subtitle: _c.motionOnlyCapture
              ? 'In motion-trigger mode these settings decide what causes a '
                    'photo.'
              : 'When the gate wakes and how touchy it is. Defaults suit '
                    'most flowers.',
          initiallyExpanded: _c.motionOnlyCapture,
          children: [
            // These tuning fields double as the motion-only capture sensitivity
            // controls — the same gate decides both "wake the detector" and
            // "take a photo".
            NumericSettingField(
              label: 'Wake duration after motion',
              value: _c.motionGateWakeSeconds,
              min: 0.5,
              max: 60,
              decimals: 1,
              unitSuffix: 's',
              // The same wake window has a different practical meaning per mode:
              // AI mode = how long the detector stays on; motion mode = how long
              // photos keep being taken (they stop when the gate goes idle).
              helperText: _c.motionOnlyCapture
                  ? 'How long the gate stays awake after the last movement; '
                        'every new movement restarts this window. Photos are '
                        'taken while it is awake, but for at most "Photo '
                        'duration" (Setup tab) per motion event. The next event '
                        'starts only after the gate has gone back to sleep and '
                        'motion returns. Default 3 s.'
                  : 'How long the detector keeps running after the last movement '
                        'or detection. Every new detection restarts this window, '
                        'so a sitting insect is not lost. Longer = fewer missed animals, '
                        'less heat saving. Default 3 s.',
              onChanged: (v) =>
                  setState(() => _c = _c.copyWith(motionGateWakeSeconds: v)),
            ),
            NumericSettingField(
              label: 'Pixel sensitivity',
              value: _c.motionGatePixelDelta.toDouble(),
              min: 5,
              max: 100,
              isInt: true,
              helperText:
                  'How much a pixel\'s brightness (0–255) must change to count as '
                  'movement. Lower = more sensitive (wakes on small insects, but also '
                  'on petal shadows); higher = stricter. Default 25.',
              onChanged: (v) => setState(
                () => _c = _c.copyWith(
                  motionGatePixelDelta: v.round().clamp(5, 100),
                ),
              ),
            ),
            NumericSettingField(
              label: 'Trigger area',
              value: _c.motionGateAreaFraction * 100,
              min: 0.05,
              max: 20,
              decimals: 2,
              unitSuffix: '%',
              helperText:
                  'How much of the ROI must change in one frame to wake the detector. '
                  'Keep small: an insect covers little of the ROI. Default 0.5%.',
              onChanged: (v) => setState(
                () => _c = _c.copyWith(motionGateAreaFraction: v / 100),
              ),
            ),
            NumericSettingField(
              label: 'Motion grid resolution',
              value: _c.motionGateGridSize.toDouble(),
              min: 16,
              max: 160,
              isInt: true,
              helperText:
                  'How finely the yellow square is divided when looking for '
                  'movement. At the default 48, an insect smaller than about 2% '
                  'of the square\'s width may not be noticed; at 128, about '
                  '0.8%. Raise it for very small insects (and lower "Trigger '
                  'area" too); higher values use slightly more battery.',
              onChanged: (v) => setState(
                () => _c = _c.copyWith(
                  motionGateGridSize: v.round().clamp(16, 160),
                ),
              ),
            ),
            NumericSettingField(
              label: 'Idle check rate (frames/s)',
              value: _c.motionGateIdleFps.toDouble(),
              min: 1,
              max: 30,
              isInt: true,
              helperText:
                  'How many camera pictures per second are checked for movement '
                  'while the detector sleeps. Default 5: an arriving insect is '
                  'noticed within about 0.2 s while the phone stays cool. Higher '
                  'notices it sooner but warms the phone. While the gate sleeps, '
                  'the "Camera" line in the info panel shows about this number; '
                  'that is normal.',
              onChanged: (v) => setState(
                () =>
                    _c = _c.copyWith(motionGateIdleFps: v.round().clamp(1, 30)),
              ),
            ),
          ],
        ),
      const Divider(color: Colors.white24),
      // The old Graphs tab's sampling fields, folded (round 159): nobody
      // needs them before their first session, and they are thematically at
      // home here (they sample temperature and power).
      FoldSection(
        title: 'Diagnostic graph sampling (advanced)',
        subtitle:
            'Sample rates for the summary\'s "Extra graphs" (temperature, '
            'frame rate, power).',
        helperText:
            'Lower values give finer graphs but measure more often; the '
            'defaults are deliberately light so the detection pipeline is '
            'not slowed down.',
        children: [
          NumericSettingField(
            label: 'Frame-rate sample',
            value: _c.fpsSampleSeconds.toDouble(),
            min: 1,
            max: 60,
            isInt: true,
            unitSuffix: 's',
            helperText:
                'How often (1–60 s) the frame rate is sampled for the '
                'graph. Already computed every frame, so a sample is '
                'essentially free. Default 5 s.',
            onChanged: (v) =>
                setState(() => _c = _c.copyWith(fpsSampleSeconds: v.round())),
          ),
          NumericSettingField(
            label: 'Phone readings sample',
            value: _c.thermalSampleSeconds.toDouble(),
            min: 1,
            max: 120,
            isInt: true,
            unitSuffix: 's',
            helperText:
                'How often (1–120 s) the battery temperature, the memory in use '
                'and the processor cores this app keeps busy are logged (one '
                'reading gives all three). Each reading asks Android for the '
                'values, so it is taken less often (heat and memory change '
                'slowly). Default 10 s.',
            onChanged: (v) => setState(
              () => _c = _c.copyWith(thermalSampleSeconds: v.round()),
            ),
          ),
          NumericSettingField(
            label: 'Power sample',
            value: _c.powerSampleSeconds.toDouble(),
            min: 1,
            max: 120,
            isInt: true,
            unitSuffix: 's',
            helperText:
                'How often (1–120 s) battery power (current × voltage) and '
                'remaining charge are sampled for the energy graphs. Each '
                'reading asks Android for the values, so it is taken less '
                'often (power changes slowly). '
                'Default 10 s.',
            onChanged: (v) =>
                setState(() => _c = _c.copyWith(powerSampleSeconds: v.round())),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ],
  );
}
