// FaunaPulse, session summary screen: the full-screen photo viewer (boxes, zoom, crop export).
//
// A `part` of session_summary_screen.dart: that screen's State class is split into
// extensions, one file per part of the screen, so each file stays readable
// while the private fields stay shared (Dart privacy is per library, and a
// part file belongs to the main file's library). Fields, getters and the
// lifecycle overrides stay in the main file; part files hold methods only.

part of '../session_summary_screen.dart';

/// One raw battery reading from a `power` log record, before unit correction.
/// One detection box, in ROI-normalized (0..1) coordinates — which is exactly
/// the coordinate space of the saved square ROI photo, so the rect maps onto the
/// image directly.
class _DetBox {
  final double left, top, right, bottom;
  final String label;

  /// True when this object's time-lapse schedule is what triggered the photo;
  /// false for target objects that simply happened to be detected in the same frame.
  final bool triggered;

  /// True for boxes found by the post-hoc analysis run (round 137) — drawn
  /// green to tell them apart from the session's live detections.
  final bool postHoc;

  const _DetBox({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.label,
    required this.triggered,
    this.postHoc = false,
  });
}

class _PhotoSample {
  final File file;

  /// The JPEG file name, exactly as recorded in the session log.
  final String name;
  final List<_DetBox> boxes;

  /// Unique track ids whose detections appear in this photo (sorted ascending).
  final List<int> trackIds;

  /// Detector confidence (0..1) per track id visible in this photo.
  final Map<int, double> trackConf;

  /// When the photo was captured, in milliseconds since the Unix epoch.
  final int captureMs;

  /// ROI pixel size when the photo was saved (square crop, so width == height).
  /// Null if no ROI record preceded the photo in the log.
  final int? width;
  final int? height;

  /// The r108 sync companion: the trigger-moment live-stream crop saved as
  /// `<name>_live.jpg` beside a high-res-path photo. Null when this photo took
  /// the fast path (it already IS a live crop), the session predates r108,
  /// or the companion file is missing from disk.
  final File? liveFile;
  final String? liveName;

  /// Saved square side (px) of the live companion, from the capture record.
  final int? livePx;

  /// How much OLDER the high-res photo's content is than the trigger moment (ms),
  /// from the capture record's `content_lag_ms` (r108). Null on fast-path
  /// photos and pre-r108 logs.
  final int? contentLagMs;

  /// The companion's own (small) lag behind the trigger moment (ms), from
  /// `live_lag_ms` (r112). Null on pre-r112 logs.
  final int? liveLagMs;

  /// Round 114: the high-res photo's CONTENT moment (epoch ms) — measured
  /// (`content_at_ms`) or, when [contentAtApprox], reconstructed from the
  /// r108 lags. Null for fast-path photos and pre-r108 logs.
  final int? contentAtMs;
  final bool contentAtApprox;

  /// Round 114/115: the boxes drawn on the HIGH-RES view instead of the
  /// trigger boxes — per-track positions interpolated at [contentAtMs]
  /// between the bracketing detector frames, or the nearest frame's boxes.
  /// Null → fall back to the trigger boxes; [stillMatchNote] then says why.
  final List<_DetBox>? stillBoxes;

  /// The match metadata behind [stillBoxes] (bracket deltas, interpolation
  /// flags) and whether the nearest frame sat within the session's match
  /// tolerance — both drive the "Boxes" info-row wording only.
  final PhotoBoxResult? stillMatch;
  final bool stillWithinTol;
  final String? stillMatchNote;

  /// True for a reference photo (gt_frames/): taken on a fixed clock
  /// regardless of detections, so it carries no boxes by design.
  final bool isReference;

  /// Round 234: a frame kept from an imported video, its clip and moment
  /// there (microseconds); null for camera photos.
  final String? clip;
  final int? ptsUs;

  const _PhotoSample({
    required this.file,
    required this.name,
    required this.boxes,
    required this.trackIds,
    required this.trackConf,
    required this.captureMs,
    required this.width,
    required this.height,
    this.liveFile,
    this.liveName,
    this.livePx,
    this.contentLagMs,
    this.liveLagMs,
    this.contentAtMs,
    this.contentAtApprox = false,
    this.stillBoxes,
    this.stillMatch,
    this.stillWithinTol = false,
    this.stillMatchNote,
    this.isReference = false,
    this.clip,
    this.ptsUs,
  });

  /// Width / height of the saved picture: 1 for camera photos (square
  /// crops), the video's own shape for a frame of the whole picture.
  double get aspect {
    final w = width, h = height;
    if (liveFile != null || w == null || h == null || w <= 0 || h <= 0) return 1;
    return w / h;
  }
}

/// A swipeable viewer: one saved ROI photo per page with its detection boxes
/// overlaid. The photo is a square ROI crop, so boxes (normalized to the ROI)
/// overlay directly on a 1:1 image.
class _PhotoViewer extends StatefulWidget {
  final List<_PhotoSample> photos;

  /// Fires when the viewer enters/leaves zoom mode. The parent must freeze
  /// its OWN scrollables on it (the tab ListView and the TabBarView): they
  /// sit above the photo in the gesture arena and otherwise win most drags —
  /// vertical pans scrolled the page away and horizontal pans switched tabs,
  /// which is why zoomed panning felt broken even after round 88 froze the
  /// inner PageView.
  final ValueChanged<bool> onZoomChanged;

  /// The session's single location fix (round 126), stamped into exported
  /// crops' EXIF; null when the session recorded none.
  final SessionLocation? location;

  /// Post-hoc analysis boxes per FILE name (round 137) — drawn green on top
  /// of the live boxes when the named file is the one being shown.
  final Map<String, List<_DetBox>> postBoxes;

  /// Visits were found in these photos afterwards (round 237): a photo's
  /// tracked boxes are its analysis boxes with visit numbers, so the green
  /// ones are drawn only where no visit has a box.
  final bool visitsFromPhotos;

  /// File names the post-hoc cleanup would delete (no detection nearby) —
  /// shown with a translucent red ✕ + note so the user can review before
  /// deleting.
  final Set<String> deleteMarked;

  /// WHY each kept photo is kept (round 138): photos without an own detection
  /// that survive only via a nearby detection / their pair member get a chip
  /// + an info row naming the decisive photo, so "kept but no box" is never
  /// confusing.
  final Map<String, KeepDecision> keepDecisions;

  /// Round 209: per-visit identifications of the newest run (null when the
  /// session was never identified); drawn as an info row under the photo.
  final LatestIdentification? identification;

  /// Round 234: moves the video player to a kept frame's moment (clip, ms);
  /// null outside the Video tab.
  final void Function(String clip, int ms)? onShowInVideo;

  const _PhotoViewer({
    required this.photos,
    required this.onZoomChanged,
    this.identification,
    this.onShowInVideo,
    this.location,
    this.postBoxes = const {},
    this.visitsFromPhotos = false,
    this.deleteMarked = const {},
    this.keepDecisions = const {},
  });

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  final _controller = PageController();
  int _page = 0;

  /// Detection boxes + labels overlay on/off (round 87, top-right tool button).
  bool _showBoxes = true;

  /// Show each high-res photo's `_live` companion instead of the photo itself
  /// (round 111, ⚡ tool button). Viewer-wide like [_showBoxes]; photos
  /// without a companion (fast-path photos are already live crops) keep
  /// showing their own file. Defaults to the companion (round 112): it is
  /// the exact trigger moment, so the detection boxes match the object's
  /// position — the later high-res photo is one tap away.
  bool _showLive = true;

  /// Whether the zoom slider is unfolded under the magnifier button.
  bool _zoomSliderOpen = false;

  /// Current page's zoom factor. Kept in sync with pinch gestures (via the
  /// transform controller's listener) so the slider thumb follows two-finger
  /// zooming too.
  double _scale = 1.0;

  /// True while the current photo is zoomed in: page-swiping is disabled so a
  /// one-finger drag pans the photo, and the zoom-mode chip is shown.
  bool get _zoomed => _scale > 1.01;

  /// Crop-and-export mode (round 91): a one-finger drag draws an export
  /// rectangle instead of panning/swiping, so the same scrollables must be
  /// frozen as in zoom mode.
  bool _cropMode = false;

  /// Where the current crop drag started, in the photo's own ("scene")
  /// coordinates — 0..[_viewerSide] on each axis, independent of zoom/pan.
  Offset? _cropDragStartScene;

  /// The drawn crop rectangle in scene coordinates; null while none is set.
  Rect? _cropSceneRect;

  /// The rectangle as it was when a MOVE drag started (drag began inside the
  /// box); null while drawing a new box instead. Moving shifts this original
  /// by the drag delta, so the size — and an enforced 1:1 — never changes.
  Rect? _cropMoveOriginRect;

  /// Mirrors [SessionConfig.cropSquareLock] (loaded in [initState]); the
  /// "1:1" chip in the crop bar writes it back, so the chip and the Settings
  /// switch are one and the same setting.
  bool _cropSquareLock = false;

  /// True while a crop is being cut/saved/shared, to debounce the buttons.
  bool _cropBusy = false;

  /// True whenever one-finger drags must NOT reach the surrounding
  /// scrollables (zoomed panning, or crop-rectangle drawing).
  bool get _scrollFrozen => _zoomed || _cropMode;

  /// Last freeze state reported to [widget.onZoomChanged], so the parent is
  /// only rebuilt on actual mode changes, not on every pinch step.
  bool _lastNotifiedFrozen = false;

  void _notifyFreeze() {
    if (_scrollFrozen == _lastNotifiedFrozen) return;
    _lastNotifiedFrozen = _scrollFrozen;
    widget.onZoomChanged(_scrollFrozen);
  }

  @override
  void initState() {
    super.initState();
    SessionConfig.load().then((c) {
      if (mounted) setState(() => _cropSquareLock = c.cropSquareLock);
    });
  }

  static const double _maxZoom = 8.0;

  /// One transform per page: PageView keeps neighbouring pages alive during a
  /// swipe, so a single shared controller would visibly zoom the incoming
  /// photo as well.
  final Map<int, TransformationController> _transforms = {};

  /// Side (logical px) of the square viewer area, captured at build time —
  /// the zoom slider needs it to keep the viewport centre fixed while scaling.
  double _viewerSide = 320;

  @override
  void dispose() {
    // If disposed mid-zoom (e.g. photos reloaded), unfreeze the parent's
    // scrollables — post-frame, because the parent may be rebuilding now.
    if (_lastNotifiedFrozen) {
      final notify = widget.onZoomChanged;
      WidgetsBinding.instance.addPostFrameCallback((_) => notify(false));
    }
    _controller.dispose();
    for (final c in _transforms.values) {
      c.dispose();
    }
    super.dispose();
  }

  TransformationController _transformFor(int page) =>
      _transforms.putIfAbsent(page, () {
        final c = TransformationController();
        // Mirror pinch zooming into [_scale] so the slider follows the fingers.
        c.addListener(() {
          if (page != _page) return;
          final s = c.value.getMaxScaleOnAxis();
          // Also rebuild on pure pans while a crop rectangle is on screen:
          // the rectangle is glued to the photo, so its viewport position
          // depends on the whole transform, not just the scale.
          if ((s - _scale).abs() > 0.01 ||
              (_cropMode && _cropSceneRect != null)) {
            setState(() => _scale = s);
            _notifyFreeze();
          }
        });
        return c;
      });

  /// Applies zoom factor [s] around the point currently at the viewport
  /// centre — so slider zooming doesn't jump away from an object the user
  /// pinch-panned to — clamping the pan so the photo keeps covering the
  /// viewport (InteractiveViewer only enforces its boundary during gestures,
  /// not for programmatic transforms).
  void _setZoom(double s) {
    s = s.clamp(1.0, _maxZoom);
    final c = _transformFor(_page);
    final centre = Offset(_viewerSide / 2, _viewerSide / 2);
    final scene = c.toScene(centre);
    final minT = _viewerSide - _viewerSide * s; // ≤ 0
    final tx = (centre.dx - scene.dx * s).clamp(minT, 0.0);
    final ty = (centre.dy - scene.dy * s).clamp(minT, 0.0);
    c.value = Matrix4.diagonal3Values(s, s, 1)..setTranslationRaw(tx, ty, 0);
    setState(() => _scale = s);
    _notifyFreeze();
  }

  /// Pans the zoomed view one step in the given direction (each unit = a
  /// third of the viewport) — the button fallback for panning, so moving
  /// around never depends on winning a drag gesture. Clamped like [_setZoom].
  void _nudge(double dxDir, double dyDir) {
    final c = _transformFor(_page);
    final s = c.value.getMaxScaleOnAxis();
    if (s <= 1.01) return;
    final step = _viewerSide / 3;
    final t = c.value.getTranslation();
    final minT = _viewerSide - _viewerSide * s; // ≤ 0
    // "Look right" = content slides left = translation decreases.
    final tx = (t.x - dxDir * step).clamp(minT, 0.0);
    final ty = (t.y - dyDir * step).clamp(minT, 0.0);
    c.value = Matrix4.diagonal3Values(s, s, 1)..setTranslationRaw(tx, ty, 0);
  }

  /// One small arrow key of the pan pad shown while zoomed.
  Widget _padButton(IconData icon, VoidCallback onTap) => SizedBox(
    width: 32,
    height: 32,
    child: IconButton(
      padding: EdgeInsets.zero,
      icon: Icon(icon),
      color: Colors.white,
      iconSize: 22,
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
    ),
  );

  /// One round translucent tool button for the tool row ABOVE the viewer
  /// (round 112: buttons must never cover the photo); [active] tints the
  /// icon so the state is visible at a glance.
  Widget _toolButton({
    required IconData icon,
    required String tooltip,
    required bool active,
    required VoidCallback onTap,
  }) => Container(
    margin: const EdgeInsets.only(left: 4),
    decoration: const BoxDecoration(
      color: Colors.black54,
      shape: BoxShape.circle,
    ),
    child: IconButton(
      icon: Icon(icon),
      color: active ? const Color(0xFF00E5FF) : Colors.white70,
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      tooltip: tooltip,
      onPressed: onTap,
    ),
  );

  /// The image file to display (and crop from) for photo [p]: the `_live`
  /// companion while the ⚡ toggle is on and one exists, else the photo itself.
  File _fileFor(_PhotoSample p) =>
      _showLive && p.liveFile != null ? p.liveFile! : p.file;

  /// The file NAME currently shown for [p] — the key into the post-hoc box /
  /// deletion-mark maps, which are per file (both pair members are analyzed).
  String _shownNameFor(_PhotoSample p) =>
      _showLive && p.liveFile != null ? (p.liveName ?? p.name) : p.name;

  /// Chip text for a photo kept WITHOUT an own detection (round 138), or null
  /// when no chip is needed (own detection, or not analyzed at all).
  String? _keptChipTextFor(_PhotoSample p) {
    final d = widget.keepDecisions[_shownNameFor(p)];
    if (d == null) return null;
    return switch (d.reason) {
      KeepReason.detected => null,
      KeepReason.bridged => 'kept (detection ${formatKeepDelta(d.deltaMs!)})',
      KeepReason.pair => 'kept (pair photo has the detection)',
      KeepReason.failed => 'kept (analysis failed)',
    };
  }

  /// True when the CURRENT page is really showing its live companion (the
  /// toggle may be on while this photo has none — e.g. a fast-path photo).
  bool get _liveShown => _showLive && widget.photos[_page].liveFile != null;

  /// The boxes to draw for [p] in the CURRENT view (round 114): trigger-frame
  /// boxes on the live companion (it IS the trigger moment); on the high-res
  /// photo the time-matched frame's boxes when a good match exists, else the
  /// trigger boxes again ([_infoPanel]'s "Boxes" row says which and why).
  List<_DetBox> _boxesFor(_PhotoSample p) =>
      _showLive && p.liveFile != null ? p.boxes : (p.stillBoxes ?? p.boxes);

  /// The green analysis boxes drawn on [p].
  List<_DetBox> _postBoxesFor(_PhotoSample p) {
    if (widget.visitsFromPhotos && _boxesFor(p).isNotEmpty) return const [];
    return widget.postBoxes[_shownNameFor(p)] ?? const [];
  }

  /// The pager caption's count — everything the overlay actually DRAWS for
  /// the current view (round 178, owner bug: a SAHI-analyzed time-lapse
  /// photo read "0 detections" under five green analysis boxes, because only
  /// the live trigger-frame boxes were counted). Post-hoc analysis boxes are
  /// named separately so an AI session's live count keeps its meaning.
  String _detectionCountLabel(_PhotoSample p) {
    final live = _boxesFor(p).length;
    final post = _postBoxesFor(p).length;
    if (widget.visitsFromPhotos && live > 0) return '$live in track ID${live == 1 ? '' : 's'}';
    if (post == 0) return '$live detection${live == 1 ? '' : 's'}';
    if (live == 0) return '$post analysis detection${post == 1 ? '' : 's'}';
    return '$live live + $post analysis detections';
  }

  /// Saved square side (px) of whichever image is currently displayed for
  /// [p] — the companion's own size while it is shown. Both are square ROI
  /// crops, so one side describes them.
  int? _shownSidePx(_PhotoSample p) {
    if (_showLive && p.liveFile != null) return p.livePx;
    if (p.width == null || p.height == null) return null;
    return min(p.width!, p.height!);
  }

  /// Where the picture sits in the square scene: all of it for a square
  /// photo, centred with bars for a video frame of the whole picture
  /// (round 234).
  Rect _imageRectInScene(_PhotoSample p) {
    final a = p.aspect;
    final s = _viewerSide;
    if (a >= 1) return Rect.fromLTWH(0, (s - s / a) / 2, s, s / a);
    return Rect.fromLTWH((s - s * a) / 2, 0, s * a, s);
  }

  /// Normalized (0..1) form of the current crop rectangle on the picture,
  /// or null.
  Rect? get _cropNormRect {
    final r = _cropSceneRect;
    if (r == null) return null;
    final p = widget.photos[_page];
    if (p.aspect == 1) return normalizedRect(r, _viewerSide);
    final img = _imageRectInScene(p);
    double x(double v) => ((v - img.left) / img.width).clamp(0.0, 1.0);
    double y(double v) => ((v - img.top) / img.height).clamp(0.0, 1.0);
    return Rect.fromLTRB(x(r.left), y(r.top), x(r.right), y(r.bottom));
  }

  /// Real pixel size of the current crop on the SAVED photo (not the screen),
  /// or null when the photo's size isn't in the log.
  (int, int)? _cropPxSize() {
    final norm = _cropNormRect;
    final p = widget.photos[_page];
    final side = _shownSidePx(p);
    if (norm == null || side == null) return null;
    if (p.aspect != 1) return ((norm.width * p.width!).round(), (norm.height * p.height!).round());
    return ((norm.width * side).round(), (norm.height * side).round());
  }

  /// The crop rectangle mapped from scene to on-screen (viewport) coordinates
  /// for painting. The transform is a uniform scale + translation
  /// (InteractiveViewer without rotation), so the mapping is scale-and-shift.
  Rect? _viewportCropRect(int page) {
    final r = _cropSceneRect;
    if (r == null) return null;
    final m = _transformFor(page).value;
    final s = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    return Rect.fromLTRB(
      r.left * s + t.x,
      r.top * s + t.y,
      r.right * s + t.x,
      r.bottom * s + t.y,
    );
  }

  /// End of a crop drag: drop a rectangle that would come out below
  /// [kMinCropSidePx] on the saved photo — almost certainly a stray tap, and
  /// too small to identify anything from anyway. (A MOVE drag keeps its
  /// already-validated size, so it always passes.)
  void _finishCropDrag() {
    _cropDragStartScene = null;
    _cropMoveOriginRect = null;
    final r = _cropSceneRect;
    if (r == null) return;
    final p = widget.photos[_page];
    final px = _shownSidePx(p) ?? 1024;
    // Saved pixels per scene unit: a picture narrower than the scene
    // (a video frame, round 234) has more of them.
    final perScene = p.aspect == 1 ? px / _viewerSide : p.width! / _imageRectInScene(p).width;
    if (r.width * perScene < kMinCropSidePx ||
        r.height * perScene < kMinCropSidePx) {
      setState(() => _cropSceneRect = null);
    }
  }

  /// Flips the 1:1 lock and persists it via [SessionConfig]. The config is
  /// re-loaded first so only this field changes even if settings were edited
  /// since this screen opened. A live rectangle is dropped: silently
  /// reshaping it would misrepresent what the user drew.
  Future<void> _setCropSquareLock(bool v) async {
    setState(() {
      _cropSquareLock = v;
      _cropDragStartScene = null;
      _cropMoveOriginRect = null;
      _cropSceneRect = null;
    });
    final cfg = await SessionConfig.load();
    await cfg.copyWith(cropSquareLock: v).save();
  }

  /// Cuts the drawn rectangle out of the ORIGINAL saved JPEG (never the
  /// screen — screen pixels are already downscaled) on a background isolate,
  /// then saves it to the Gallery or opens the share sheet.
  Future<void> _exportCrop({required bool share}) async {
    final norm = _cropNormRect;
    if (norm == null || _cropBusy) return;
    final p = widget.photos[_page];
    setState(() => _cropBusy = true);
    String msg;
    var withPosition = false;
    try {
      // Cut from whichever image is on screen — the high-res photo or (⚡ on)
      // its live companion; the export name follows the file it came from.
      // Round 126: the export gets EXIF where-and-when — the photo's trigger
      // moment plus the session's location fix (when one was recorded) — so
      // identification apps (ObsIdentify, iNaturalist) read both from the
      // file. Only exports carry EXIF; the session photos stay EXIF-free.
      // Round 328: the position only while "Add the position to exported
      // crops" is on, and the message then says so (a shared crop can reveal
      // the site of a rare species).
      final loc = widget.location;
      withPosition = loc != null && (await SessionConfig.load()).cropExportPosition;
      // Round 330: "Don't show again" on the message hides only this sentence.
      final note =
          withPosition && !((await SharedPreferences.getInstance()).getBool(kHideCropPositionNotePrefKey) ?? false)
          ? kCropPositionNote
          : '';
      final cropped = await cropJpegNormRect(
        _fileFor(p),
        norm,
        exif: exportCropExif(
          capturedAtMs: p.captureMs,
          latitude: loc?.latitude,
          longitude: loc?.longitude,
          withPosition: withPosition,
        ),
      );
      if (cropped == null) {
        msg =
            'Crop failed: the box is too small (under $kMinCropSidePx px) '
            'or the photo could not be read.';
      } else {
        final name = cropExportName(_liveShown ? p.liveName! : p.name);
        if (share) {
          await shareCrop(cropped.jpeg, name);
          msg =
              '${cropped.width} × ${cropped.height} px crop handed to the '
              'share sheet.$note';
        } else {
          // Fallback dir (older Android / MediaStore failure): keep the crop
          // with its session, next to roi_frames/.
          final res = await saveCropToGallery(
            cropped.jpeg,
            name,
            fallbackDir: Directory('${p.file.parent.parent.path}/crops'),
          );
          msg = res == null
              ? 'Saving the crop failed.'
              : 'Saved ${cropped.width} × ${cropped.height} px crop to '
                    '${res.location}.$note';
        }
      }
    } catch (e) {
      logSwallowed('crop_export', e);
      msg =
          'Could not save or share the crop. Try again; if it keeps failing, '
          'use "Report a problem" in the Home screen menu.';
    } finally {
      if (mounted) setState(() => _cropBusy = false);
    }
    if (mounted) {
      final noted = msg.contains(kCropPositionNote);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          // Round 331: 10 s (the longest Android's guidelines suggest) to read
          // the position sentence and reach its button; 8 s was too short.
          duration: Duration(seconds: noted ? 10 : 4),
          // A bar with a button stays until tapped unless told otherwise.
          persist: false,
          action: noted ? SnackBarAction(label: "Don't show again", onPressed: _hideCropPositionNote) : null,
        ),
      );
    }
  }

  Future<void> _hideCropPositionNote() async {
    try {
      await (await SharedPreferences.getInstance()).setBool(kHideCropPositionNotePrefKey, true);
    } catch (e) {
      logSwallowed('crop_note_hide', e);
    }
  }

  /// Action bar under the viewer while crop mode is on: the 1:1 lock chip,
  /// the crop's real pixel size (from the saved file, not the screen — the
  /// honest number that decides whether an identification app has enough
  /// detail), and the Save / Share actions.
  Widget _cropBar() {
    final size = _cropPxSize();
    final hasRect = _cropSceneRect != null;
    final String label;
    if (!hasRect) {
      label = 'Drag a box around the target to crop it out of the photo';
    } else if (size == null) {
      label = 'Crop set';
    } else {
      final tiny = size.$1 < 100 || size.$2 < 100;
      label = 'Crop: ${size.$1} × ${size.$2} px${tiny ? '  ⚠ tiny' : ''}';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          FilterChip(
            label: const Text('1:1'),
            selected: _cropSquareLock,
            visualDensity: VisualDensity.compact,
            tooltip:
                'Force the crop box to a square (same setting as "Square (1:1) '
                'export crops" on the Photos tab of Session settings)',
            onSelected: _setCropSquareLock,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.save_alt),
            tooltip:
                'Save the crop to the phone Gallery '
                '(Pictures/FaunaPulse)',
            color: Colors.white,
            onPressed: hasRect && !_cropBusy
                ? () => _exportCrop(share: false)
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip:
                'Share the crop to another app '
                '(e.g. Google Lens, iNaturalist)',
            color: Colors.white,
            onPressed: hasRect && !_cropBusy
                ? () => _exportCrop(share: true)
                : null,
          ),
        ],
      ),
    );
  }

  /// A round translucent ‹ / › photo-navigation button; greyed out at the
  /// ends of the gallery. Navigating first resets the zoom, so the page
  /// transition never slides a zoomed crop around.
  Widget _navButton(IconData icon, bool enabled, int toPage) => Container(
    decoration: const BoxDecoration(
      color: Colors.black54,
      shape: BoxShape.circle,
    ),
    child: IconButton(
      icon: Icon(icon),
      color: enabled ? Colors.white : Colors.white24,
      iconSize: 24,
      visualDensity: VisualDensity.compact,
      onPressed: enabled
          ? () {
              if (_zoomed) _setZoom(1);
              _controller.animateToPage(
                toPage,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
              );
            }
          : null,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 8),
        // Tool row ABOVE the photo (round 112): with four tools the old
        // top-right in-photo column reached down to the › nav button and
        // covered the image — no button may overlap the photo again, so
        // viewing/zooming/cropping is never obstructed.
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            // Round 234: a frame kept from a video moves the player above to
            // its moment.
            if (widget.onShowInVideo case final show? when widget.photos[_page].clip != null)
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      final p = widget.photos[_page];
                      show(p.clip!, p.ptsUs! ~/ 1000);
                    },
                    icon: const Icon(Icons.play_circle_outline, size: 18),
                    label: const Text('Show in video', overflow: TextOverflow.ellipsis),
                  ),
                ),
              ),
            _toolButton(
              icon: Icons.crop_din,
              tooltip: 'Show/hide detection boxes',
              active: _showBoxes,
              onTap: () => setState(() => _showBoxes = !_showBoxes),
            ),
            // Round 111/112: flip between a high-res photo and its `_live` companion —
            // only offered when this session saved any. The companion is the
            // default view (boxes match the target object's true position).
            if (widget.photos.any((p) => p.liveFile != null))
              _toolButton(
                icon: Icons.bolt,
                tooltip:
                    'Switch between the trigger-moment "_live" crop (shown '
                    'by default: lower resolution, but the detection boxes '
                    'match the object\'s real position) and the '
                    'high-resolution photo (sharper, but shows the scene a '
                    'fraction of a second later).',
                active: _showLive,
                onTap: () => setState(() => _showLive = !_showLive),
              ),
            _toolButton(
              icon: Icons.crop,
              tooltip:
                  'Crop & export: drag a box around a target object, '
                  'then save it to the Gallery or share it to an '
                  'identification app (zoom in first if needed)',
              active: _cropMode,
              onTap: () {
                setState(() {
                  _cropMode = !_cropMode;
                  _cropDragStartScene = null;
                  _cropMoveOriginRect = null;
                  _cropSceneRect = null;
                });
                _notifyFreeze();
              },
            ),
            _toolButton(
              icon: Icons.zoom_in,
              tooltip:
                  'Zoom: slider here, or pinch with two fingers; '
                  'double-tap the photo to reset',
              active: _zoomSliderOpen,
              onTap: () => setState(() => _zoomSliderOpen = !_zoomSliderOpen),
            ),
          ],
        ),
        // Zoom slider, horizontal and outside the photo too (round 112).
        if (_zoomSliderOpen)
          Row(
            children: [
              Text(
                '${_scale.toStringAsFixed(1)}×',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              Expanded(
                child: Slider(
                  value: _scale.clamp(1.0, _maxZoom),
                  min: 1,
                  max: _maxZoom,
                  onChanged: _setZoom,
                ),
              ),
            ],
          ),
        const SizedBox(height: 4),
        // Capped height (not a full-width square) so the viewer doesn't dominate
        // the page or trap the vertical scroll past it.
        SizedBox(
          height: 320,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _viewerSide = min(constraints.maxWidth, 320.0);
              return Stack(
                children: [
                  PageView.builder(
                    controller: _controller,
                    itemCount: widget.photos.length,
                    // While zoomed, one-finger drags must PAN the photo — but
                    // the PageView competes for the same horizontal drag and
                    // usually wins (this is what made panning after a pinch
                    // feel broken, round 88). So page-swiping is disabled in
                    // zoom mode (and in crop mode, where a drag draws the
                    // export box); the ‹ › buttons (which first reset the
                    // zoom) are the way to change photo.
                    physics: _scrollFrozen
                        ? const NeverScrollableScrollPhysics()
                        : null,
                    onPageChanged: (i) {
                      final old = _page;
                      setState(() {
                        _page = i;
                        _scale = 1;
                        // A crop rectangle belongs to one photo: drop it when
                        // leaving (crop mode itself stays on).
                        _cropDragStartScene = null;
                        _cropMoveOriginRect = null;
                        _cropSceneRect = null;
                      });
                      // Gallery convention: zoom belongs to one photo — reset
                      // it when leaving.
                      _transforms[old]?.value = Matrix4.identity();
                      _notifyFreeze();
                    },
                    itemBuilder: (_, i) {
                      final p = widget.photos[i];
                      // The saved ROI crop is square, and the boxes are normalized to it.
                      // Pin the image AND the overlay to the SAME square box (AspectRatio
                      // 1) so the boxes map 1:1 onto the visible photo. Previously the
                      // painter filled the whole non-square 320-tall area while the image
                      // was letterboxed inside it, so the boxes landed off the photo (they
                      // appeared to flash and vanish). Positioned.fill keeps the overlay
                      // exactly the image's size across the relayout when the file decodes,
                      // and gaplessPlayback stops the image blanking on rebuild.
                      return Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              // Two-finger pinch zooms/pans (InteractiveViewer);
                              // double-tap resets to 1×. The box overlay sits
                              // INSIDE the transformed child so it scales/pans
                              // with the photo and stays glued to the tracked objects.
                              GestureDetector(
                                onDoubleTap: () => _setZoom(1),
                                child: InteractiveViewer(
                                  transformationController: _transformFor(i),
                                  maxScale: _maxZoom,
                                  // A video frame of the whole picture is not square (round 234):
                                  // the picture and its boxes keep its shape, centred.
                                  child: Center(child: AspectRatio(aspectRatio: p.aspect, child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      // Boxes are ROI-normalized, so they
                                      // overlay either file directly; WHICH
                                      // frame's boxes depends on the view —
                                      // see _boxesFor (round 114).
                                      Image.file(
                                        _fileFor(p),
                                        fit: BoxFit.contain,
                                        gaplessPlayback: true,
                                        // The analysis screen's photo cleanup
                                        // (round 136) can delete photos the
                                        // log still references — show a plain
                                        // note instead of an error box.
                                        errorBuilder: (_, _, _) => const Center(
                                          child: Text(
                                            'Photo deleted\n(analysis cleanup)',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: Colors.white54,
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (_showBoxes)
                                        Positioned.fill(
                                          child: CustomPaint(
                                            // The page's own zoom factor: stroke
                                            // width and label size are divided by
                                            // it inside the painter so they keep a
                                            // constant ON-SCREEN thickness while
                                            // the photo underneath scales up.
                                            painter: _BoxPainter(
                                              [
                                                ..._boxesFor(p),
                                                // Post-hoc boxes (green) are
                                                // normalized to the shown file
                                                // itself, so they overlay 1:1.
                                                ..._postBoxesFor(p),
                                              ],
                                              _transformFor(
                                                i,
                                              ).value.getMaxScaleOnAxis(),
                                            ),
                                          ),
                                        ),
                                      // Cleanup preview (round 137): photos
                                      // the post-hoc cleanup would delete get
                                      // a translucent red ✕ (a marker, not a
                                      // button — r112 allows only text chips
                                      // and passive marks on the photo).
                                      if (widget.deleteMarked.contains(
                                        _shownNameFor(p),
                                      )) ...[
                                        Positioned.fill(
                                          child: IgnorePointer(
                                            child: CustomPaint(
                                              painter: _DeleteMarkPainter(),
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          bottom: 8,
                                          child: IgnorePointer(
                                            child: Center(
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 3,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.red.withValues(
                                                    alpha: 0.55,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                ),
                                                child: const Text(
                                                  'no detection: cleanup '
                                                  'will delete',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 11,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ]
                                      // Kept WITHOUT an own detection (round
                                      // 138) — say why right on the image, so
                                      // "no box but not marked" is clear.
                                      else if (_keptChipTextFor(p)
                                          case final chip?)
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          bottom: 8,
                                          child: IgnorePointer(
                                            child: Center(
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 3,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.amber
                                                      .withValues(alpha: 0.55),
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                ),
                                                child: Text(
                                                  chip,
                                                  style: const TextStyle(
                                                    color: Colors.black,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        )
                                      // Reference photo (gt_frames/): taken
                                      // on a fixed clock, no boxes by design
                                      // — say so on the image (a passive
                                      // text chip, allowed by r112). The
                                      // delete/kept chips above can't apply
                                      // to reference photos (post-hoc scans
                                      // roi_frames/ only), so the slot is
                                      // free.
                                      else if (p.isReference)
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          bottom: 8,
                                          child: IgnorePointer(
                                            child: Center(
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 3,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.blueGrey
                                                      .withValues(alpha: 0.55),
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                ),
                                                child: const Text(
                                                  'Reference photo (fixed '
                                                  'interval)',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 11,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ))),
                                ),
                              ),
                              // Crop mode (round 91): a drag layer ABOVE the
                              // viewer wins every one-finger drag and draws
                              // the export rectangle. Points are converted to
                              // the photo's scene coordinates immediately
                              // (toScene), so the rectangle stays glued to the
                              // tracked object however the view is zoomed or panned.
                              if (_cropMode && i == _page)
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onPanStart: (d) {
                                    final scene = _transformFor(
                                      i,
                                    ).toScene(d.localPosition);
                                    final r = _cropSceneRect;
                                    final scale = _transformFor(
                                      i,
                                    ).value.getMaxScaleOnAxis();
                                    // Starting INSIDE the existing box (with
                                    // a finger-friendly margin, in on-screen
                                    // pixels) MOVES it; anywhere else redraws.
                                    final moving =
                                        r != null &&
                                        r.inflate(12 / scale).contains(scene);
                                    setState(() {
                                      _cropDragStartScene = scene;
                                      _cropMoveOriginRect = moving ? r : null;
                                      if (!moving) _cropSceneRect = null;
                                    });
                                  },
                                  onPanUpdate: (d) {
                                    final a = _cropDragStartScene;
                                    if (a == null) return;
                                    final scene = _transformFor(
                                      i,
                                    ).toScene(d.localPosition);
                                    setState(() {
                                      final origin = _cropMoveOriginRect;
                                      _cropSceneRect = origin != null
                                          ? moveSceneRect(
                                              origin,
                                              scene - a,
                                              _viewerSide,
                                            )
                                          : sceneRectForDrag(
                                              a,
                                              scene,
                                              _viewerSide,
                                              square: _cropSquareLock,
                                            );
                                    });
                                  },
                                  onPanEnd: (_) => _finishCropDrag(),
                                  child: CustomPaint(
                                    painter: _CropRectPainter(
                                      _viewportCropRect(i),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  // Crop-mode chip (takes priority over the zoom chip: in
                  // crop mode a drag draws the box, whatever the zoom is).
                  if (_cropMode)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _cropSceneRect == null
                              ? 'Crop: drag a box around the object'
                              : 'Crop: drag inside the box to move it, '
                                    'outside to redraw',
                          style: const TextStyle(
                            color: _CropRectPainter.color,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    )
                  // Zoom-mode chip: makes the mode switch visible — while it
                  // shows, a one-finger drag moves the zoomed photo and the
                  // ‹ › buttons (or a double-tap) leave the mode.
                  else if (_zoomed)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'Zoom ${_scale.toStringAsFixed(1)}×: drag to move, '
                          '‹ › or double-tap to exit',
                          style: const TextStyle(
                            color: Color(0xFF00E5FF),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        if (_cropMode) ...[_cropBar(), const SizedBox(height: 8)],
        // ‹ › photo navigation UNDER the preview (round 112: buttons never
        // overlap the photo). Always present: while zoomed they are the
        // ONLY way to change photo (swiping then pans instead).
        Row(
          children: [
            _navButton(Icons.chevron_left, _page > 0, _page - 1),
            Expanded(
              child: Text(
                'Photo ${_page + 1} / ${widget.photos.length}'
                '  •  ${_detectionCountLabel(widget.photos[_page])}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
            _navButton(
              Icons.chevron_right,
              _page < widget.photos.length - 1,
              _page + 1,
            ),
          ],
        ),
        // Pan pad (round 89, moved out of the photo in round 112): button
        // fallback for moving the zoomed view, so panning never depends on
        // winning a drag gesture against the surrounding scrollables.
        if (_zoomed)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _padButton(Icons.keyboard_arrow_left, () => _nudge(-1, 0)),
                  _padButton(Icons.keyboard_arrow_up, () => _nudge(0, -1)),
                  _padButton(Icons.keyboard_arrow_down, () => _nudge(0, 1)),
                  _padButton(Icons.keyboard_arrow_right, () => _nudge(1, 0)),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        _infoPanel(widget.photos[_page]),
      ],
    );
  }

  /// "1:05.3": a kept frame's moment in its clip.
  static String _clipTime(int ms) {
    final s = ms / 1000;
    return '${s ~/ 60}:${(s % 60).toStringAsFixed(1).padLeft(4, '0')}';
  }

  /// Per-photo metadata read from the session log: resolution, the track ids
  /// visible in it, the capture time, and the file name. Follows the ⚡
  /// toggle: while the live companion is shown, resolution and file name
  /// describe THAT file, so the numbers always match the pixels on screen.
  Widget _infoPanel(_PhotoSample p) {
    final liveShown = _showLive && p.liveFile != null;
    final res = liveShown
        ? (p.livePx != null ? '${p.livePx} × ${p.livePx} px' : 'unknown')
        : (p.width != null && p.height != null)
        // Width × height: ROI crops are square; a video frame of the whole
        // picture (round 234) keeps the video's shape.
        ? '${p.width} × ${p.height} px'
        : 'unknown';
    // One "#id Conf.: 0.xy" entry per track visible in this photo. Only
    // meaningful when the live detector ran (see the rows below).
    final ids = p.trackIds.map((e) => '#$e').join(', ');
    final conf = p.trackIds
        .map(
          (e) => p.trackConf[e] != null
              ? '#$e Conf.: ${p.trackConf[e]!.toStringAsFixed(2)}'
              : '#$e Conf.: unknown',
        )
        .join(', ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Which of the photo's two files is on screen (round 112) — the
          // row only exists when there really ARE two.
          if (p.liveFile != null)
            _infoRow(
              'Showing',
              liveShown
                  ? 'trigger-moment live crop (⚡ for the high-res photo)'
                  : 'high-res photo (⚡ for the trigger-moment live crop)',
            ),
          _infoRow('Resolution', res),
          // Live-tracking rows only when the detector actually ran on this
          // photo (round 178, owner request): motion/time-lapse/SAHI-only
          // photos have no track ids or live confidences, and permanent
          // "none"/"n/a" rows only puzzled. AI-session photos keep them,
          // one entry per visible track id.
          if (p.trackIds.isNotEmpty) ...[
            _infoRow('Track IDs', ids),
            _infoRow('Confidence', conf),
          ],
          // Round 209: the identification of each visit in this photo (one
          // answer per track id, combined over all its photos; no-AI
          // sessions are identified per photo instead).
          if (_identifiedText(p) case final text?) _infoRow('Identified', text),
          _infoRow('Captured', formatCaptureStamp(p.captureMs)),
          if (p.clip case final clip? when p.ptsUs != null)
            _infoRow('In video', '$clip at ${_clipTime(p.ptsUs! ~/ 1000)}'),
          _infoRow('File', liveShown ? p.liveName! : p.name),
          // Post-hoc cleanup verdict for the shown file (round 138): a photo
          // kept without an own detection names the photo that saved it.
          if (widget.keepDecisions[_shownNameFor(p)] case final d?) ...[
            if (d.reason == KeepReason.bridged)
              _infoRow(
                'Kept',
                'decisive detection ${formatKeepDelta(d.deltaMs!)} '
                    'in ${d.decisiveName}',
              ),
            if (d.reason == KeepReason.pair)
              _infoRow(
                'Kept',
                'pair photo ${d.decisiveName} has the detection',
              ),
            if (d.reason == KeepReason.failed)
              _infoRow(
                'Kept',
                'analysis failed on this photo (kept to be safe)',
              ),
          ] else if (widget.deleteMarked.contains(_shownNameFor(p)))
            _infoRow(
              'Cleanup',
              'marked for deletion: no detection within the keep window',
            ),
          // Lag of the image ON SCREEN behind the trigger moment (round
          // 112: each view states only its OWN delay — showing the high-res
          // photo's lag under the live crop read as if the live crop were late).
          // The live figure is an upper bound (grab completion time), hence
          // the ≤; the high-res photo's is the measured `content_lag_ms`.
          if (!liveShown && p.contentLagMs != null)
            _infoRow('Lag', '${p.contentLagMs} ms behind the trigger moment'),
          if (liveShown && p.liveLagMs != null)
            _infoRow('Lag', '≤ ${p.liveLagMs} ms behind the trigger moment'),
          // Round 114: which frame the drawn boxes come from. On the high-res
          // view they are time-matched to the photo's real content moment
          // when the log allows it; otherwise the trigger frame, with the
          // reason.
          if (p.liveFile != null || p.contentAtMs != null)
            _infoRow('Boxes', _boxesSourceText(p, liveShown)),
        ],
      ),
    );
  }

  /// The "Boxes" info-row text: where the drawn boxes come from in the
  /// CURRENT view, and — on the high-res view — how far the contributing
  /// detector frame(s) sit from the photo's real content moment
  /// (round 114/115).
  String _boxesSourceText(_PhotoSample p, bool liveShown) {
    if (liveShown) return 'trigger frame (matches this image)';
    final m = p.stillMatch;
    if (p.stillBoxes != null && m != null) {
      final pre = p.contentAtApprox ? '~' : '';
      if (m.anyInterpolated) {
        return "estimated at this photo's moment from the detector frames "
            '$pre${m.beforeDeltaMs!.abs()} ms before and '
            '${m.afterDeltaMs} ms after';
      }
      if (m.beforeDeltaMs != null && m.afterDeltaMs != null) {
        // Frames on both sides but no shared track to interpolate (the
        // tracker re-assigned the id across the capture pause): each box is
        // drawn from its own side.
        return 'from the detector frames $pre${m.beforeDeltaMs!.abs()} ms '
            'before and ${m.afterDeltaMs} ms after (no shared track to '
            'merge across the capture pause)';
      }
      final delta = m.beforeDeltaMs ?? m.afterDeltaMs!;
      final n = '$pre${delta.abs()}';
      final when = delta <= 0 ? 'before' : 'after';
      if (p.stillWithinTol) {
        return "from a detector frame $n ms $when this photo's content";
      }
      // A distant single-side frame: still the best available — the
      // detector pauses while a high-res photo is captured, so frames at
      // the content moment often don't exist at all.
      return 'nearest available frame, $n ms $when (the detector pauses '
          'while a high-res photo is taken)';
    }
    if (p.stillMatchNote != null) {
      return 'trigger frame (${p.stillMatchNote})';
    }
    return 'trigger frame';
  }

  /// "#12 Bombus (genus, 87 %), #13 no organism" for the visits in [p], or
  /// the per-photo answer of a no-AI session; null when nothing is known.
  String? _identifiedText(_PhotoSample p) {
    final id = widget.identification;
    if (id == null) return null;
    final parts = [
      for (final t in p.trackIds)
        if (id.byTrack[t] case final v?) '#$t ${v.label}',
    ];
    if (parts.isEmpty) {
      final v = id.byPhoto[p.name] ?? (p.liveName == null ? null : id.byPhoto[p.liveName!]);
      if (v != null) parts.add(v.label);
    }
    return parts.isEmpty ? null : parts.join(', ');
  }

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ],
    ),
  );
}

/// Capture time as hh:mm:ss.milliseconds (local time), e.g. 14:07:32.481.
/// A dot, not a colon, before the milliseconds so they do not read as a
/// fourth time field; same form as the session log lines (session_logger.dart).
@visibleForTesting
String formatCaptureStamp(int ms) {
  if (ms <= 0) return 'unknown';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  final msPart = d.millisecond.toString().padLeft(3, '0');
  return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}.$msPart';
}

/// Draws ROI-normalized detection boxes (0..1) over the displayed square photo.
class _BoxPainter extends CustomPainter {
  final List<_DetBox> boxes;

  /// Zoom factor of the enclosing InteractiveViewer. The painter draws in the
  /// photo's (pre-zoom) coordinates, so stroke width and label size are
  /// divided by this to keep a constant ON-SCREEN thickness at any zoom —
  /// otherwise an 8× zoom turns the 2 px border into a fat 16 px band and the
  /// label into a banner covering the target object.
  final double zoom;
  _BoxPainter(this.boxes, [this.zoom = 1]);

  /// Box color of the object(s) whose time-lapse schedule triggered the photo
  /// (the color all boxes used before round 86).
  static const triggerColor = Color(0xFF00E5FF);

  /// Box color of objects that were detected in the same frame but did not
  /// trigger the photo themselves.
  static const coDetectedColor = Color(0xFFFFC107);

  /// Box color of post-hoc analysis detections (round 137).
  static const postHocColor = Color(0xFF76FF03);

  @override
  void paint(Canvas canvas, Size size) {
    for (final b in boxes) {
      final color = b.postHoc
          ? postHocColor
          : b.triggered
          ? triggerColor
          : coDetectedColor;
      final stroke = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 / zoom;
      final rect = Rect.fromLTRB(
        b.left * size.width,
        b.top * size.height,
        b.right * size.width,
        b.bottom * size.height,
      );
      canvas.drawRect(rect, stroke);
      if (b.label.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: b.label,
            style: TextStyle(
              color: Colors.black,
              fontSize: 11 / zoom,
              backgroundColor: color,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          Offset(rect.left, (rect.top - 13 / zoom).clamp(0, size.height)),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter old) =>
      old.boxes != boxes || old.zoom != zoom;
}

/// Translucent red corner-to-corner ✕ over photos the post-hoc cleanup would
/// delete (round 137) — a passive review mark, drawn under IgnorePointer.
class _DeleteMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color =
          const Color(0x59FF1744) // ~35% red
      ..strokeWidth = size.shortestSide * 0.04
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset.zero, Offset(size.width, size.height), stroke);
    canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), stroke);
  }

  @override
  bool shouldRepaint(covariant _DeleteMarkPainter old) => false;
}

/// Draws the crop-export rectangle. It paints in VIEWPORT coordinates (the
/// rectangle is re-mapped from the photo's scene coordinates every build, see
/// [_PhotoViewerState._viewportCropRect]) so it stays glued to the photo while
/// zooming/panning, and dims everything outside so the kept region is obvious.
class _CropRectPainter extends CustomPainter {
  final Rect? rect;
  _CropRectPainter(this.rect);

  static const color = Color(0xFFFF9100);

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect;
    if (r == null) return;
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRect(r),
    );
    canvas.drawPath(outside, Paint()..color = Colors.black38);
    canvas.drawRect(
      r,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // Four-arrow "move" glyph just inside the top-right corner: the visual
    // cue that a drag starting inside the box MOVES it (clamped to the
    // canvas so it stays visible when that corner is panned off-screen).
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.open_with.codePoint),
        style: const TextStyle(
          fontFamily: 'MaterialIcons',
          fontSize: 16,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(
        (r.right - tp.width - 3).clamp(0.0, size.width - tp.width),
        (r.top + 3).clamp(0.0, size.height - tp.height),
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _CropRectPainter old) => old.rect != rect;
}
