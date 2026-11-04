// FaunaPulse, session settings sheet: the camera information section and the stream resolution (end of the Photos tab).
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

extension _SettingsCameraInfo on _SettingsSheetState {
  /// Collapsible "Camera & lens info" section: lists every camera/lens the phone
  /// reports and whether the detector can actually use it. This is the diagnostic
  /// that used to sit on the live camera screen; it lives here so the recording
  /// screen stays uncluttered. Read-only; selectable text so it can be copied
  /// into a problem report. Explains, per device, why a given lens may not be
  /// selectable (e.g. a telephoto hidden inside a logical multi-camera, or a
  /// vendor that exposes only one rear camera to third-party apps).
  Widget _cameraInfoSection() {
    final cams = widget.cameraDiagnostics;
    return Theme(
      // ExpansionTile draws its divider lines from the theme; clear them so the
      // dark sheet doesn't get stray bright separators.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        iconColor: Colors.white,
        collapsedIconColor: Colors.white,
        title: const Text(
          'Camera & lens info (advanced)',
          style: TextStyle(color: Colors.white),
        ),
        subtitle: const Text(
          'Which rear/front lenses this phone exposes, and which the detector '
          'can use.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: cams.isEmpty
            ? const [
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Camera details are not available yet. Close Session '
                    'settings, wait until the camera picture shows, then open '
                    'Session settings again.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              ]
            : _cameraInfoChildren(cams),
      ),
    );
  }

  /// Builds the body of the camera-info section: a plain-language explanation,
  /// then the **rear** cameras (the ones used for monitoring) first, then the
  /// **front** cameras tucked into a collapsed subsection. The list shows the
  /// cameras Android exposes to this app — which is a manufacturer-curated subset,
  /// not a 1:1 map of the glass lenses on the back of the phone.
  List<Widget> _cameraInfoChildren(List<Map<String, dynamic>> cams) {
    bool isBack(Map<String, dynamic> c) =>
        (c['lensFacing'] ?? '').toString() == 'back';
    final rear = cams.where(isBack).toList();
    final front = cams.where((c) => !isBack(c)).toList();
    final usableRear = rear
        .where((c) => c['usableForInference'] == true)
        .length;

    return [
      // Estimated analysis-stream ceiling for this phone (round 56): the largest
      // size CameraX can actually feed the detector, usually below the photo sizes
      // the camera advertises.
      _analysisCeilingInfo(),
      // Why the list may not match the lenses you can physically count.
      const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: Text(
          'These are the cameras Android lets this app use. Phone makers choose '
          'which lenses to expose: on many phones (e.g. Xiaomi/MIUI) the '
          'ultra-wide, macro and telephoto lenses are reserved for the built-in '
          'camera app, so they won\'t appear here even though you can see them on '
          'the back of the phone. That\'s a phone/OS limitation, not a fault of '
          'this app. "Detector can use it" means the detector can read that '
          'camera\'s frames.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ),
      // Rear cameras first — these are what fieldwork uses.
      const Padding(
        padding: EdgeInsets.only(top: 4, bottom: 4),
        child: Text(
          'Rear cameras (used for monitoring)',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
      if (rear.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'This phone does not let apps use any rear camera.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        )
      else
        for (final cam in rear) _cameraInfoCard(cam),
      // Empty list: the line above already says it, so no second line.
      if (rear.isNotEmpty && usableRear < 2)
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Text(
            usableRear == 0
                ? 'The detector cannot use any of these rear cameras.'
                : 'Only one rear camera can be used by apps on this phone, so '
                      'the lens-switch button is off. Other lenses are kept for '
                      'the phone\'s own camera app, or can only be reached by '
                      'zooming.',
            style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
          ),
        ),
      // Front cameras, collapsed — not used for monitoring.
      if (front.isNotEmpty)
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            iconColor: Colors.white54,
            collapsedIconColor: Colors.white54,
            title: const Text(
              'Front cameras (not used for monitoring)',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            childrenPadding: const EdgeInsets.only(bottom: 8),
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(
                  'Selfie-facing cameras. Field monitoring uses the rear cameras, '
                  'so these aren\'t selectable. Some phones '
                  'report a second, duplicate front camera: this comes from the '
                  'phone\'s own software and is not an extra physical lens.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              for (final cam in front) _cameraInfoCard(cam),
            ],
          ),
        ),
    ];
  }

  /// Friendly, plain-language name for a camera, derived from its facing and the
  /// native lens-type classification (which comes from the 35mm-equivalent focal
  /// length). The technical id/focal detail is shown separately on the card.
  String _cameraTitle(String facing, String type) {
    if (facing != 'back') return 'Front camera';
    switch (type) {
      case 'Wide':
        return 'Main (wide) camera';
      case 'Ultra wide':
        return 'Ultra-wide camera';
      case 'Telephoto':
        return 'Telephoto camera';
      default:
        return 'Rear camera';
    }
  }

  /// One card describing a single camera/lens, with a colour-coded usability
  /// badge (green = the detector can use it, amber = zoom-only hidden lens,
  /// grey = reported but the app cannot open it) and a plain-language reason.
  Widget _cameraInfoCard(Map<String, dynamic> cam) {
    final usable = cam['usableForInference'] == true;
    final physicalOnly = cam['isPhysicalOnly'] == true;
    final facing = (cam['lensFacing'] ?? 'unknown').toString();
    final type = (cam['lensType'] ?? 'unknown').toString();
    final id = (cam['cameraId'] ?? '?').toString();
    final equiv = (cam['equiv35mm'] as num?)?.toDouble() ?? 0.0;
    final focals =
        (cam['focalLengthsMm'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        const <double>[];
    final analysis =
        (cam['analysisSizes'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];
    final reason = (cam['reason'] ?? '').toString();

    final Color badgeColor = usable
        ? Colors.greenAccent
        : (physicalOnly ? Colors.amberAccent : Colors.white38);
    final String badgeText = usable
        ? 'Detector can use it'
        : (physicalOnly ? 'Zoom only (hidden lens)' : 'Not available to this app');

    final String title = _cameraTitle(facing, type);

    String detailText() {
      final parts = <String>['id $id'];
      if (focals.isNotEmpty) {
        final list = focals.map((f) => '${f.toStringAsFixed(1)} mm').join(', ');
        final eq = equiv > 0 ? ' (~${equiv.round()} mm eq.)' : '';
        parts.add('focal $list$eq');
      }
      if (physicalOnly) parts.add('physical sub-camera');
      return parts.join(' • ');
    }

    return Card(
      color: Colors.white10,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: badgeColor),
                  ),
                  child: Text(
                    badgeText,
                    style: TextStyle(
                      color: badgeColor,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SelectableText(
              detailText(),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            if (analysis.isNotEmpty)
              SelectableText(
                'analysis sizes: ${analysis.take(4).join(', ')}'
                '${analysis.length > 4 ? ', …' : ''}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            if (reason.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SelectableText(
                  reason,
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Dropdown of the camera's actual HAL-supported analysis sizes (verbatim — no
  /// 32-rounding, which would force a non-native size). Labelled "short × long".
  // Parses the estimated analysis ceiling ("WxH") into (area, short, long). Zero
  // area means "unknown" (no native ceiling reported). See round 56.
  (int area, int lo, int hi) get _ceiling {
    final recMax = (widget.analysisCeiling['recommendedMax'] as String?) ?? '';
    if (!recMax.contains('x')) return (0, 0, 0);
    final p = recMax.split('x');
    final w = int.tryParse(p[0]) ?? 0,
        h = int.tryParse(p.length > 1 ? p[1] : '0') ?? 0;
    return (w * h, w < h ? w : h, w < h ? h : w);
  }

  Widget _streamResolutionDropdown() {
    final all = widget.streamResolutions.isNotEmpty
        ? widget.streamResolutions
        : const ['640x480', '1280x960', '1600x1200'];
    final current = '${_c.streamWidth}x${_c.streamHeight}';
    final (ceilArea, ceilLo, ceilHi) = _ceiling;
    int area(String wh) {
      final p = wh.split('x');
      return (int.tryParse(p[0]) ?? 0) *
          (int.tryParse(p.length > 1 ? p[1] : '0') ?? 0);
    }

    // Round 123 (Samsung field test): sizes above the analysis ceiling used
    // to be listed with a "(may cap to …)" tag — offering a size the phone
    // will shrink anyway just annoys. They are now filtered OUT, with one
    // exception: the user's already-saved choice stays listed (annotated) so
    // an old config remains visible and re-selectable. If the ceiling would
    // remove everything, the unfiltered list is kept.
    var options = all;
    if (ceilArea > 0) {
      final within = all
          .where((wh) => area(wh) <= ceilArea || wh == current)
          .toList();
      if (within.isNotEmpty) options = within;
    }
    String label(String wh) {
      final p = wh.split('x');
      final w = int.tryParse(p[0]) ?? 0,
          h = int.tryParse(p.length > 1 ? p[1] : '0') ?? 0;
      final lo = w < h ? w : h, hi = w < h ? h : w;
      // Only reachable for the kept legacy choice above the ceiling.
      if (ceilArea > 0 && w * h > ceilArea) {
        return '$lo × $hi  (phone will shrink it to $ceilLo×$ceilHi)';
      }
      return '$lo × $hi';
    }

    // Round 109 "Auto": the app picks the smallest supported size whose short
    // side reaches the saved-photo target (round 122: the user's actual
    // "Saved photo side" value, not a fixed 1024), so fast (no-stall) ROI
    // crops can meet it and the laggy high-res photo path is needed less
    // often. On a phone that can't reach the target at all, the pick is the
    // largest size the phone streams. Only computable from real device
    // probes; on the preset fallback the auto item still exists but keeps
    // the current size until probes land.
    final target = _c.targetRoiSavedPx;
    final autoPick = widget.streamResolutions.isEmpty
        ? null
        : autoStreamResolution(
            widget.streamResolutions,
            ceilingArea: ceilArea,
            minShortSide: target,
          );
    const autoValue = 'auto';
    final String autoLabel;
    if (autoPick == null) {
      autoLabel = 'Auto (device-chosen)';
    } else if ((autoPick.$1 < autoPick.$2 ? autoPick.$1 : autoPick.$2) >=
        target) {
      autoLabel =
          'Auto (matches Saved photo side, $target px): '
          '${label('${autoPick.$1}x${autoPick.$2}')}';
    } else {
      autoLabel =
          'Auto (largest this phone streams, below $target px): '
          '${label('${autoPick.$1}x${autoPick.$2}')}';
    }

    return DropdownButton<String>(
      value: !_c.streamResolutionExplicit
          ? autoValue
          : (options.contains(current) ? current : null),
      isExpanded: true,
      dropdownColor: Colors.black87,
      hint: Text(
        'Device default (nearest to ${_c.streamHeight} × ${_c.streamWidth})',
        style: const TextStyle(color: Colors.white54),
      ),
      items: [
        DropdownMenuItem(
          value: autoValue,
          child: Text(autoLabel, style: const TextStyle(color: Colors.white)),
        ),
        ...options.map(
          (wh) => DropdownMenuItem(
            value: wh,
            child: Text(label(wh), style: const TextStyle(color: Colors.white)),
          ),
        ),
      ],
      onChanged: (v) {
        if (v == null) return;
        if (v == autoValue) {
          setState(
            () => _c = _c.copyWith(
              streamResolutionExplicit: false,
              // Apply the computed size right away so the choice is WYSIWYG;
              // without probes the camera screen applies it once they land.
              streamWidth: autoPick?.$1,
              streamHeight: autoPick?.$2,
            ),
          );
          return;
        }
        final p = v.split('x');
        setState(
          () => _c = _c.copyWith(
            streamWidth: int.parse(p[0]),
            streamHeight: int.parse(p[1]),
            streamResolutionExplicit: true,
          ),
        );
      },
    );
  }

  // The ⓘ helper for the stream-resolution label (round 181; was an
  // always-visible note under the dropdown). Explains that the live analysis
  // stream is capped by the phone (not a bug), that this does NOT affect
  // detection accuracy, and that detailed photos come from the high-res
  // path. See round 56.
  String _streamHelpText() {
    final (ceilArea, ceilLo, ceilHi) = _ceiling;
    final parts = <String>[
      'The size of the live camera picture the detector looks at. It does '
          'not change detection accuracy (each picture is shrunk to the '
          'model\'s size anyway); it only limits how big fast crops can be. '
          'Larger sizes cost more heat and battery. "Auto" picks the smallest '
          'size that still reaches "Saved photo side".',
    ];
    if (ceilArea > 0) {
      parts.add(
        'This phone can send at most about $ceilLo×$ceilHi px, so larger '
        'sizes are not listed.',
      );
    }
    return parts.join(' ');
  }

  // Camera-info panel block: hardware level + estimated analysis-stream ceiling.
  // See round 56. Hidden when the device didn't report a ceiling.
  Widget _analysisCeilingInfo() {
    final (ceilArea, ceilLo, ceilHi) = _ceiling;
    if (ceilArea <= 0) return const SizedBox.shrink();
    final hwLevel = (widget.analysisCeiling['hardwareLevel'] as String?) ?? '';
    final dw = (widget.analysisCeiling['displayW'] as num?)?.toInt() ?? 0;
    final dh = (widget.analysisCeiling['displayH'] as num?)?.toInt() ?? 0;
    final lines = <String>[
      'Estimated live-stream ceiling: ~$ceilLo×$ceilHi px',
      if (hwLevel.isNotEmpty && hwLevel != 'unknown')
        'Camera hardware level: $hwLevel',
      if (dw > 0 && dh > 0) 'Screen: $dw×$dh px',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: SelectableText(
                l,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'The camera advertises larger sizes for photo capture, but when the live '
              'preview, the detector stream and photo capture run together it can only '
              'feed the detector up to about this size, so larger stream choices '
              'are scaled down. This does not affect detection accuracy.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
