// FaunaPulse, session summary screen: copying photos and video clips to the phone gallery.
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

extension _SummaryGalleryExport on _SessionSummaryScreenState {
  /// Lists the session's saved photos, asks for confirmation (count + the
  /// extra storage the copies will take), then copies them into the phone's
  /// own Gallery app as one album under Pictures/FaunaPulse. Copies
  /// only — the session folder keeps its originals and the data log stays in
  /// the private session folder. The photo list comes from the real folders
  /// on disk (`roi_frames/` + the reference photos in `gt_frames/`), not
  /// from the log, so crash-ended sessions (whose log may be missing its
  /// tail) still export every file.
  /// Round 239: "Copy videos" on the Video tab, like the photos.
  Future<void> _confirmExportVideosToGallery() async {
    final files = VideoDetector.clipsOf(widget.logFile.parent);
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This session has no videos left to copy (they were deleted).')),
      );
      return;
    }
    final bytes = files.fold<int>(0, (s, f) => s + f.lengthSync());
    final album = galleryAlbumName(
      widget.logFile.parent.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
    );
    final n = files.length;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(Text('Copy $n ${n == 1 ? 'video' : 'videos'} to Gallery?'), onClose: () => Navigator.of(ctx).pop(false)),
        content: Text(
          'Copies the video clips of this session into the phone\'s Gallery '
          'app, as the album "Movies/FaunaPulse/$album" (about '
          '${formatBytes(bytes)} extra). The originals stay in the session '
          'folder; deleting them later with "Free storage" (Find animals in '
          'videos screen) does not delete the copies. Videos copied before are '
          'skipped.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Copy', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await _runGalleryExport(files, album, videos: true);
  }

  Future<void> _confirmExportPhotosToGallery() async {
    // Old sessions' gt_frames files may share roi_ names with detection
    // photos of the same millisecond — the native same-name skip would then
    // drop one album copy (vanishingly rare, originals untouched); new
    // sessions are immune via the ref_ prefix.
    final scan = await scanSessionPhotos(widget.logFile.parent.path);
    final files = scan.files;
    final bytes = scan.bytes;
    final referenceCount = scan.referenceCount;
    if (!mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This session has no saved photos to export.'),
        ),
      );
      return;
    }
    final album = galleryAlbumName(
      widget.logFile.parent.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
    );
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(Text('Copy ${files.length} photos to Gallery?'), onClose: () => Navigator.of(ctx).pop(false)),
        content: Text(
          'Copies every saved photo of this session into the phone\'s '
          'Gallery app, as the album "Pictures/FaunaPulse/$album". '
          '${referenceCount > 0 ? 'Includes $referenceCount reference '
                    'photo${referenceCount == 1 ? '' : 's'} (fixed-interval '
                    'shots, taken whether or not anything was detected). ' : ''}'
          'The copies take about ${formatBytes(bytes)} of extra storage; '
          'the originals stay in the session folder. Photos already '
          'copied are skipped, so re-running is safe.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Copy',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await _runGalleryExport(files, album);
  }

  /// Runs the chunked copy with a progress bar, then reports the counts.
  /// `exportPhotosToGallery` never throws (failures are counted and logged),
  /// so the try/finally only guarantees the busy flag resets.
  Future<void> _runGalleryExport(List<File> files, String album, {bool videos = false}) async {
    setState(() {
      _galleryExportBusy = true;
      _galleryExportVideos = videos;
      _galleryExportDone = 0;
      _galleryExportTotal = files.length;
    });
    GalleryExportResult res;
    void progress(int done, int total) {
      if (mounted) setState(() => _galleryExportDone = done);
    }

    try {
      res = videos
          ? await exportVideosToGallery(files, album, onProgress: progress)
          : await exportPhotosToGallery(files, album, onProgress: progress);
    } finally {
      if (mounted) setState(() => _galleryExportBusy = false);
    }
    if (!mounted) return;
    final what = videos ? 'videos' : 'photos';
    final msg = !res.supported
        ? 'Copying to Gallery needs Android 10 or newer. This phone runs an '
              'older Android. The $what are still on the phone in the '
              'session folder (reachable over USB).'
        : 'Copied ${res.exported} $what to Gallery ▸ '
              '${videos ? 'Movies' : 'Pictures'}/FaunaPulse/$album.'
              '${res.skipped > 0 ? ' ${res.skipped} were already there.' : ''}'
              '${res.failed > 0 ? ' ${res.failed} failed: try again.' : ''}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// The progress of a running gallery copy, under the section that started it.
  List<Widget> _galleryProgress({required bool videos}) => [
    if (_galleryExportBusy && _galleryExportVideos == videos) ...[
      LinearProgressIndicator(
        value: _galleryExportTotal == 0 ? null : _galleryExportDone / _galleryExportTotal,
      ),
      const SizedBox(height: 4),
      Text(
        'Copying ${videos ? 'video' : 'photo'} $_galleryExportDone of $_galleryExportTotal…',
        style: const TextStyle(fontSize: 12),
      ),
      const SizedBox(height: 8),
    ],
  ];
}
