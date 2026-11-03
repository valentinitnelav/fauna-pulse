// FaunaPulse, session summary screen:
// the Video tab (player and the way to Find animals in videos).
//
// A `part` of session_summary_screen.dart: that screen's State class is split into
// extensions, one file per part of the screen, so each file stays readable
// while the private fields stay shared (Dart privacy is per library, and a
// part file belongs to the main file's library). Fields, getters and the
// lifecycle overrides stay in the main file; part files hold methods only.

part of '../session_summary_screen.dart';

extension _SummaryVideoTab on _SessionSummaryScreenState {
  Widget _videoReviewTab() {
    // The frames kept for visits (round 234) load by themselves, as on the
    // Photos tab.
    if (!_photosRequested) {
      _photosRequested = true;
      _photosLoading = true;
      Future.microtask(_loadPhotos);
    }
    return VideoReviewPlayer(
      key: _videoPlayerKey,
      sessionDir: widget.logFile.parent,
      padding: _tabPadding,
      onOpenAnalysis: _openVideoAnalysis,
      live: _liveVideoSession,
      scrollLocked: _photoViewerZoomed,
      header: [
        if (_clipTotals.count > 0) ...[
          const SizedBox(height: 6),
          Text(_clipTotals.label, style: const TextStyle(fontSize: 13)),
        ],
      ],
      // A live session's own photos (round 240); otherwise the kept frames.
      footer: _photoSection(videoFrames: !_liveVideoSession, withVideoCopy: true),
    );
  }

  /// "Run AI on videos" for this session, from the Video tab. A new
  /// analysis or new visits change the Setup rows and the Graphs, so both
  /// are read again afterwards.
  Future<void> _openVideoAnalysis() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoAnalysisScreen(
          initialSessionPath: widget.logFile.parent.path,
        ),
      ),
    );
    if (!mounted) return;
    await _loadVideoRun();
    if (!mounted) return;
    _indexFuture = null;
    _clearGraphData();
    if (_graphsRequested) await _loadGraphs();
    // New visits keep other frames, and may outdate the identification.
    if (_photosRequested && mounted) await _loadPhotos();
    if (mounted) await _loadIdentification();
    if (mounted) await _loadClipTotals();
  }
}
