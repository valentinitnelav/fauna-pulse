// FaunaPulse, session settings sheet: the Photos tab (time-lapse save-as, photo size and source, viewer).
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

extension _SettingsPhotosTab on _SettingsSheetState {
  // --- Tab 3: Photos — what saved photos look like ------------------------

  /// Time-lapse only (round 238): photos or one video clip per burst, the
  /// clip frame rate, a storage estimate and the camera-cap warning.
  List<Widget> _timeLapseSaveAsFields() {
    final video = _c.timeLapseSaveAs == TimeLapseSaveAs.video;
    final cap = _c.cameraFpsCap;
    return [
      const SizedBox(height: 12),
      const HelpLabel(
        label: 'Save bursts as',
        helperText:
            'Photos (default) saves one photo of the yellow square (ROI) '
            'every "Photo step". Video saves each burst as one MP4 clip, so '
            'an insect can be followed from picture to picture; it needs more '
            'storage (estimate below). Insects and their track IDs are found '
            'later: Sessions screen, the session\'s ⋮ menu → "Find animals in '
            'videos".',
      ),
      DropdownButton<TimeLapseSaveAs>(
        value: _c.timeLapseSaveAs,
        isExpanded: true,
        dropdownColor: Colors.black87,
        items: const [
          DropdownMenuItem(
            value: TimeLapseSaveAs.photos,
            child: Text(
              'Photos',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          DropdownMenuItem(
            value: TimeLapseSaveAs.video,
            child: Text(
              'Video (MP4), find animals later',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
        onChanged: (v) => setState(() => _c = _c.copyWith(timeLapseSaveAs: v)),
      ),
      if (video) ...[
        const SizedBox(height: 8),
        NumericSettingField(
          label: 'Video frame rate',
          value: _c.timeLapseVideoFps.toDouble(),
          min: 1,
          max: 30,
          isInt: true,
          unitSuffix: 'FPS',
          helperText:
              'Frames per second in each clip (1 to 30). Default 5: the rate '
              '"Find animals in videos" reads by default, so no stored frame '
              'goes unused. Higher rates (up to the camera frame rate cap on '
              'the Power tab) give smoother clips and help with very fast '
              'insects, but need more storage; with fewer frames a fast insect '
              'may move too far between two frames to be recognised as the '
              'same one.',
          onChanged: (v) => setState(() => _c = _c.copyWith(timeLapseVideoFps: v.round())),
        ),
        if (cap > 0 && cap < _c.timeLapseVideoFps)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'The camera runs at $cap frames per second (Power tab → '
              '"Camera frame rate"), so the clips get at most $cap. Choose a '
              'higher camera rate or lower the video frame rate. A higher '
              'camera rate also warms the phone between bursts, unless '
              '"Turn camera off between bursts" is on.',
              style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            roiVideoStorageEstimate(_c),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      ],
    ];
  }

  Widget _photosTab() => ListView(
    children: [
      // Saved photo side leads the tab (round 159): it answers "how big are
      // my photos". The live-stream choice that feeds fast crops sits in the
      // Advanced fold below and, on "Auto", follows this value (round 122
      // coupling, placement flipped).
      NumericSettingField(
        label: 'Saved photo side (px)',
        value: _c.targetRoiSavedPx.toDouble(),
        min: 128,
        max: 2048,
        isInt: true,
        helperText:
            'Side length of the square photos (and time-lapse video clips), '
            'in pixels. Default 1024, a good balance of detail and storage. '
            'Larger crops are shrunk to this size; smaller ones are never '
            'enlarged. If the ROI line on the camera screen shows ⚠, photos '
            'come out smaller than this: move the phone closer, switch lens, '
            'or set "ROI photo source" below to Auto. Values are rounded to a '
            'multiple of 32.',
        onChanged: (v) => setState(() {
          _c = _c.copyWith(targetRoiSavedPx: snapToMultipleOf32(v));
          // The Auto stream pick follows this target (round 122): keep the
          // stored size in step so the dropdown stays WYSIWYG while on Auto.
          if (!_c.streamResolutionExplicit &&
              widget.streamResolutions.isNotEmpty) {
            final pick = autoStreamResolution(
              widget.streamResolutions,
              ceilingArea: _ceiling.$1,
              minShortSide: _c.targetRoiSavedPx,
            );
            if (pick != null) {
              _c = _c.copyWith(streamWidth: pick.$1, streamHeight: pick.$2);
            }
          }
        }),
      ),
      const SizedBox(height: 16),

      NotApplicable(
        applies: !_c.timeLapseVideo,
        note:
            'Not used for time-lapse video bursts: the clips are cut from the '
            'live frames, like fast photos.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HelpLabel(
              label: 'ROI photo source',
              helperText:
                  'Fast crops (default) are cut from the live camera picture: '
                  'no pause, and the photo shows the exact moment of the '
                  'detection. High-res photos'
                  '${widget.sensorWidth > 0 ? ' (up to ${widget.sensorWidth}×${widget.sensorHeight} on this phone)' : ''}'
                  ' have more pixels, but each one pauses detection for up to '
                  'about 1.5 s (longer on older phones), is taken a fraction of '
                  'a second later, and is often blurred, so a fast insect may '
                  'be gone or unsharp. Auto takes a fast crop when it reaches '
                  '"Saved photo side" above, and a high-res photo otherwise.',
            ),
            DropdownButton<RoiCaptureMode>(
              value: _c.captureMode,
              isExpanded: true,
              dropdownColor: Colors.black87,
              items: const [
                DropdownMenuItem(
                  value: RoiCaptureMode.fast,
                  child: Text(
                    'Fast crops only (live frame)',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                DropdownMenuItem(
                  value: RoiCaptureMode.auto,
                  child: Text(
                    'Auto (high-res only when needed)',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                DropdownMenuItem(
                  value: RoiCaptureMode.highRes,
                  child: Text(
                    'High-res photos always (full resolution)',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
              onChanged: (m) => setState(() => _c = _c.copyWith(captureMode: m)),
            ),
            HelpSwitchTile(
              title: 'Also save a fast crop with each high-res photo',
              helperText:
                  'Only for high-res photos. A high-res photo is taken up to '
                  'about 1 s after the detection, so a fast insect can be gone '
                  'from it. With this on, the fast crop from the moment of the '
                  'detection is saved next to it ("…_live.jpg"): smaller, but '
                  'the insect is in it. On by default; adds about 50–200 KB per '
                  'photo.',
              value: _c.highResSyncCompanion,
              onChanged: (v) =>
                  setState(() => _c = _c.copyWith(highResSyncCompanion: v)),
            ),
          ],
        ),
      ),
      const Divider(color: Colors.white24),
      const Text(
        'Photo viewer',
        style: TextStyle(color: Colors.white70, fontSize: 16),
      ),
      // Moved here from the old Graphs tab (round 159): it is a photo-viewer
      // preference, so it lives with the photo settings. The "1:1" chip in
      // the summary viewer toggles the same key (cropSquareLock).
      HelpSwitchTile(
        title: 'Square (1:1) export crops',
        helperText:
            'Forces the crop-and-export box in the summary photo viewer to '
            'a square. Off = free rectangle that can fit the insect\'s '
            'shape. The "1:1" chip next to the crop box toggles this same '
            'setting.',
        value: _c.cropSquareLock,
        onChanged: (v) => setState(() => _c = _c.copyWith(cropSquareLock: v)),
      ),
      HelpSwitchTile(
        title: 'Add the position to exported crops',
        helperText:
            'When on, saved and shared crops include the session position, as '
            'in a phone camera photo. This lets apps such as iNaturalist place '
            'the record on a map. Turn it off for sites that must stay '
            'private, such as sites of rare species.',
        value: _c.cropExportPosition,
        onChanged: (v) => setState(() => _c = _c.copyWith(cropExportPosition: v)),
      ),
      const Divider(color: Colors.white24),
      // The stream feeds the AI and caps fast crops; on "Auto" it follows the
      // saved-photo target above, so it sits folded (round 159; the round-122
      // coupling is unchanged, only the placement flipped).
      FoldSection(
        title: 'Advanced (camera stream)',
        subtitle: 'The live video stream the detector reads.',
        helperText:
            '"Auto" follows the saved photo size above; pick a smaller '
            'size manually on a phone that runs hot.',
        children: [
          HelpLabel(
            label: 'Live stream resolution (short × long)',
            helperText: _streamHelpText(),
          ),
          _streamResolutionDropdown(),
          const SizedBox(height: 8),
        ],
      ),
      const Divider(color: Colors.white24),
      _cameraInfoSection(),
    ],
  );
}
