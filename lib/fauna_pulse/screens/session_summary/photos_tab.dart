// FaunaPulse, session summary screen:
// the Photos tab (samples, identification, photo clean-up afterwards).
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

extension _SummaryPhotosTab on _SessionSummaryScreenState {
  Widget _photosTab() {
    // Auto-load the default random sample once (round 187 — the tab used to
    // wait for a "Show" button press). Fields are set directly (we are mid-
    // build, setState would assert); the microtask does the real work.
    if (!_photosRequested) {
      _photosRequested = true;
      _photosLoading = true;
      Future.microtask(_loadPhotos);
    }
    return ListView(
      padding: _tabPadding,
      // Frozen while a photo is zoomed: the list's vertical drag otherwise
      // wins vertical/diagonal photo pans and scrolls the viewer away.
      physics: _photoViewerZoomed ? const NeverScrollableScrollPhysics() : null,
      children: _photoSection(),
    );
  }

  /// The photo viewer with its explanations and actions; with [videoFrames]
  /// the frames kept from imported videos (round 234, under the player).
  List<Widget> _photoSection({bool videoFrames = false, bool withVideoCopy = false}) {
    final noun = videoFrames ? 'kept frame' : 'saved photo';
    return [
      if (videoFrames) ...[
        const Divider(height: 32, color: Colors.white24),
        const Text('Kept frames', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text(
          'Pictures of each track ID, kept from the videos when the track IDs were found (set under '
          '"Find animals in videos" → "Detection, track ID and identification settings", Track IDs card). '
          'A random sample of $_randomSampleCount is shown; pick more '
          'below. Swipe or use the arrows to step through them in time order. "Show in video" moves '
          'the player above to that moment.',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ] else ...[
      const Text(
        'Saved photos (with detection boxes if a detector was used)',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        '$_randomSampleCount photos picked at random are shown; choose more '
        'below. Swipe, or use the arrows, to step through them in the order '
        'they were taken. Reference photos (taken at fixed times, whether or '
        'not an animal was there) are marked and have no boxes.',
        style: TextStyle(color: Colors.white70, fontSize: 12),
      ),
      ],
      const SizedBox(height: 4),
      // Box-color legend (round 86): a photo shows EVERY object detected in
      // the frame that scheduled it, not only the one(s) whose time-lapse
      // step was due.
      const Text(
        'Box colors (if a detector was used):',
        style: TextStyle(color: Colors.white70, fontSize: 12),
      ),
      const SizedBox(height: 2),
      Text.rich(
        TextSpan(
          style: const TextStyle(color: Colors.white70, fontSize: 12),
          children: [
            const TextSpan(
              text: '■ ',
              style: TextStyle(color: _BoxPainter.triggerColor),
            ),
            TextSpan(
              text: videoFrames
                  ? 'the track ID this frame was kept for'
                  : 'the track ID this photo was taken for',
            ),
          ],
        ),
      ),
      const Text.rich(
        TextSpan(
          style: TextStyle(color: Colors.white70, fontSize: 12),
          children: [
            TextSpan(
              text: '■ ',
              style: TextStyle(color: _BoxPainter.coDetectedColor),
            ),
            TextSpan(text: 'other animals detected in the same picture'),
          ],
        ),
      ),
      const SizedBox(height: 8),
      // Round 209: sample-size chips (10 / 50 / 100 / all) — only the sizes
      // smaller than the session's photo count are offered, plus a fresh
      // random draw. A session of 10 photos or fewer shows no chips at all.
      if (_photosRequested && !_photosLoading && _totalSavedPhotos > _randomSampleCount)
        ..._sampleChips(),
      if (_photosRequested && !_photosLoading)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Showing ${_photos.length} of $_totalSavedPhotos $noun'
            '${_totalSavedPhotos == 1 ? '' : 's'} this session'
            '${_totalReferencePhotos > 0 ? ' ($_totalReferencePhotos reference)' : ''}'
            '${_photos.length < _totalSavedPhotos ? ', picked at random' : ''}.',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      // Round 209: which identification run labels the photos below.
      if (_identification != null && _identificationStale)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            'The track IDs were found again since identification ran, so its answers no longer match '
            'these frames. Run Identify organisms again.',
            style: TextStyle(color: Colors.amber, fontSize: 12),
          ),
        )
      else if (_identification case final id?)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Identifications (name list ${id.packId}, '
            '${id.generatedIso.length >= 16 ? id.generatedIso.substring(0, 16).replaceFirst('T', ' ') : id.generatedIso}) '
            'are shown under each photo. With track IDs, the answer is per track ID '
            '(all photos of that track ID combined); without track IDs, each photo '
            'has its own answer.',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      // Post-hoc analysis results (round 137): counts, what the cleanup would
      // delete, and the delete action itself — so the user can review the
      // green post-hoc boxes / red deletion marks in the viewer below and
      // delete right here.
      ..._postHocSection(),
      // Round 111: explain the high-res/companion pair when this session saved
      // any — otherwise the ⚡ button (and the second file per photo on
      // disk) is a mystery.
      if (_photosRequested &&
          !_photosLoading &&
          _photos.any((p) => p.liveFile != null))
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            'High-res photos are saved twice: a smaller photo taken at the '
            'moment of detection, and a sharp photo taken a fraction of a second '
            'later. The viewer shows the smaller one first, because its boxes '
            'match where the animal was. The ⚡ button switches to the sharp '
            'photo; a fast animal may have moved by then (see the "Lag" row; '
            'the "Boxes" row says how its boxes were placed).',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      if (_photosLoading)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_photosRequested && _photos.isEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            videoFrames
                ? 'No kept frames yet. In "Find animals in videos", find the track IDs with '
                      '"Keep frames of each track ID" on.'
                : 'No saved photos found for this session.',
            style: const TextStyle(color: Colors.white70),
          ),
        )
      else if (_photos.isNotEmpty)
        _PhotoViewer(
          photos: _photos,
          identification: _identificationStale ? null : _identification,
          location: SessionLocation.fromJson(
            (_startRec?['location'] as Map?)?.cast<String, dynamic>(),
          ),
          postBoxes: _postBoxesByName,
          visitsFromPhotos: _visitsFromPhotos,
          deleteMarked: _postDeleteMarked,
          keepDecisions: _postDecisions,
          onShowInVideo: videoFrames
              ? (clip, ms) => _videoPlayerKey.currentState?.showMoment(clip, ms)
              : null,
          onZoomChanged: (z) {
            if (mounted && z != _photoViewerZoomed) {
              setState(() => _photoViewerZoomed = z);
            }
          },
        ),
      // --- Copy the video clips to the Gallery (round 239, Video tab) ---
      if (videoFrames || withVideoCopy) ...[
        const Divider(height: 32, color: Colors.white24),
        const HelpLabel(
          label: 'Copy videos to Gallery',
          labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          helperText:
              'Copies the video clips of this session into the phone\'s own Gallery app, as one '
              'album under Movies/FaunaPulse, to watch them or share them with other apps. The '
              'copies take extra storage (the originals stay in the session folder). They are '
              'plain videos: the detector\'s boxes are not drawn into them.',
        ),
        const SizedBox(height: 8),
        ..._galleryProgress(videos: true),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: _galleryExportBusy ? null : _confirmExportVideosToGallery,
            icon: const Icon(Icons.video_library),
            label: const Text('Copy videos'),
          ),
        ),
      ],
      // --- Copy photos to the phone's own Gallery app (round 93; moved here
      // from the retired Overview tab, round 187) ---
      const Divider(height: 32, color: Colors.white24),
      const HelpLabel(
        label: 'Copy photos to Gallery',
        labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        helperText:
            'Copies every saved photo of this session into the phone\'s Gallery '
            'app, as an album under Pictures/FaunaPulse. The copies take extra '
            'storage; the originals stay in the session folder. The copies are '
            'plain photos, without the detection boxes. Some gallery apps need '
            'a while to show a new album.',
      ),
      const SizedBox(height: 8),
      ..._galleryProgress(videos: false),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          onPressed: _galleryExportBusy ? null : _confirmExportPhotosToGallery,
          icon: const Icon(Icons.photo_library),
          label: const Text('Copy photos'),
        ),
      ),
      ..._identifySection(),
    ];
  }

  /// "Identify organisms" (round 208), at the end of the Photos tab and of
  /// the Video tab (round 231).
  List<Widget> _identifySection() => [
    // --- Identify organisms (round 208): per-visit taxonomic identification
    // with the BioCLIP image tower, run on the phone from the saved photos.
    const Divider(height: 32, color: Colors.white24),
    const HelpLabel(
      label: 'Identify organisms',
      labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
      helperText:
          'Names the animals on this session\'s saved photos with an identification model '
          'and its list of species names. With track IDs, all photos of one track ID give '
          'one answer. Sessions without live detection need "Find animals in photos" (for '
          'videos: "Find animals in videos") first. It can take minutes to hours, so keep '
          'the phone plugged in; a "View results" button then appears here. The names are '
          'suggestions: mistakes are possible, especially for animals that are not in the '
          'name list.',
    ),
    const SizedBox(height: 8),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.tonalIcon(
          onPressed: () => Navigator.of(context)
              .push(
                MaterialPageRoute(
                  builder: (_) =>
                      IdentificationScreen(sessionDir: widget.logFile.parent),
                ),
              )
              .then((_) => _loadIdentification()),
          icon: const Icon(Icons.biotech_outlined),
          label: const Text('Identify organisms'),
        ),
        // Round 213: straight to the newest results when a run exists.
        if (_identification case final id?)
          FilledButton.icon(
            onPressed: () {
              final paths = IdentificationPaths(widget.logFile.parent);
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => IdentificationResultsScreen(
                    sessionDir: widget.logFile.parent,
                    tracksJson: paths.tracksJson(id.packStem),
                    summaryJson: id.summaryFile,
                    tracksCsv: paths.tracksCsv(id.packStem),
                  ),
                ),
              );
            },
            icon: const Icon(Icons.table_rows_outlined),
            label: const Text('View results'),
          ),
      ],
    ),
  ];

  /// The sample-size chip row (round 209): 10 / 50 / 100 (those below the
  /// photo count) / All, plus a "new random draw" button.
  List<Widget> _sampleChips() {
    final current = _photoSampleSize;
    return [
      Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('Sample:', style: TextStyle(color: Colors.white70, fontSize: 12)),
          for (final n in _sampleChoices.where((n) => n < _totalSavedPhotos))
            ChoiceChip(
              label: Text('$n'),
              selected: current == n,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => _loadPhotos(sample: n),
            ),
          ChoiceChip(
            label: Text('All ($_totalSavedPhotos)'),
            selected: current == null,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => _confirmShowAllPhotos(),
          ),
          if (current != null)
            IconButton(
              tooltip: 'New random sample',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.casino_outlined, size: 20),
              onPressed: () => _loadPhotos(),
            ),
        ],
      ),
    ];
  }

  /// "Show all photos", with a heads-up first when the session is large:
  /// thousands of photos load lazily as the user swipes, but building the
  /// list still takes noticeably long on a phone.
  Future<void> _confirmShowAllPhotos() async {
    if (_totalSavedPhotos <= _showAllWarnThreshold) {
      await _loadPhotos(all: true);
      return;
    }
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(Text('Show all $_totalSavedPhotos photos?'), onClose: () => Navigator.of(ctx).pop(false)),
        content: const Text(
          'This session has a lot of photos, so loading and swiping through '
          'all of them on the phone can be slow. For big sessions it is '
          'usually easier to connect the phone to a computer over USB and '
          'copy the session folder there.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Show all',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (sure == true && mounted) await _loadPhotos(all: true);
  }

  /// The Photos tab's post-hoc block: shown only when this session has
  /// post_detections.jsonl results. Mirrors the analysis screen's cleanup
  /// (same keep rule and saved gap), so the numbers match across screens.
  List<Widget> _postHocSection() {
    final outcomes = _postOutcomes;
    if (outcomes == null || outcomes.isEmpty) return const [];
    final withBoxes = outcomes.where((o) => o.hasBoxes == true).length;
    final plan = planCleanup(widget.logFile.parent, outcomes, _postKeep);
    final kept = _postKeep.length;
    final deleted = outcomes.length - kept;
    // Integer percents that provably sum to 100: one rounded, one complement.
    final keptPct = outcomes.isEmpty
        ? 0
        : (kept * 100 / outcomes.length).round();
    final deletedPct = 100 - keptPct;
    return [
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.blueGrey.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '"Find animals in photos" found a detection in $withBoxes of '
                '${outcomes.length} photos (green boxes). Photos within '
                '${formatKeepWindow(_postGapSeconds)} of such a photo are kept '
                'too ("keep window", set under "Photo cleanup" on the "Find '
                'animals in photos" screen): $kept kept ($keptPct%), $deleted '
                'marked for deletion ($deletedPct%) with a red ✕.',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red.shade300,
                ),
                onPressed: (plan.deleteNames.isEmpty || _postDeleting)
                    ? null
                    : () => _confirmPostHocDelete(plan),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(
                  plan.deleteNames.isEmpty
                      ? 'Nothing to delete'
                      : 'Delete ${plan.deleteNames.length} marked photos '
                            '(${formatBytes(plan.deleteBytes)})…',
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  Future<void> _confirmPostHocDelete(CleanupPlan plan) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(const Text('Delete photos without detections?'), onClose: () => Navigator.of(ctx).pop(false)),
        content: Text(
          'This permanently deletes ${plan.deleteNames.length} photos '
          '(${formatBytes(plan.deleteBytes)}): the ones marked with a red ✕. '
          '${plan.keepCount} photos stay. The session log keeps its records; '
          'this cannot be undone.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Delete ${plan.deleteNames.length}',
              style: const TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _postDeleting = true);
    final deleted = await runCleanup(
      widget.logFile.parent,
      plan,
      gapSeconds: _postGapSeconds,
      minBoxFrac: _postMinBoxFrac,
    );
    if (!mounted) return;
    setState(() => _postDeleting = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Deleted $deleted photos.')));
    await _loadPostHoc();
    // The photo list still points at deleted files; reload it (keeping the
    // user's sample/all choice) and the Setup tab's storage numbers.
    if (_photosRequested) await _loadPhotos();
    await _loadStorageInfo();
  }
}
