// FaunaPulse (round 231): the summary's Video tab for imported videos.
//
// Plays the session's clips with the boxes the AI found (video_box_timeline
// .dart), so the user can see whether the analysed square was well placed
// and how the visits were counted. Two views of the same picture: the whole
// frame with the analysed square drawn, or zoomed onto that square ("what the
// AI saw"). The zoom only enlarges the same decoded picture, so it costs
// nothing extra.
//
// The player (video_player, ExoPlayer on Android) decodes in hardware, like
// the phone's gallery. It reports its position every 100 ms; between reports
// a ticker moves the boxes on by the elapsed time × speed, so they follow the
// insect smoothly. Paused or after a seek, the position is exact.
//
// Round 234: the summary's "Kept frames" below the player move it to a
// frame's moment ([VideoReviewPlayerState.showMoment]). Round 235: that
// scrolls the clip picker, player and controls to the top of the tab, and
// white ticks under the time bar mark the saved kept frames. Round 236: a
// clip deleted to free storage says when; its boxes and visits still list.

import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../logging/app_error_hooks.dart';
import '../postprocess/clip_cleanup.dart';
import '../postprocess/video_box_timeline.dart';
import '../postprocess/video_detector.dart' show VideoDetector;
import '../postprocess/video_tracker.dart' show VideoTracker;
import 'setting_help.dart';

class VideoReviewPlayer extends StatefulWidget {
  final Directory sessionDir;

  /// The tab's list padding (bottom system inset included).
  final EdgeInsets padding;

  /// Opens "Run AI on videos" for this session; the boxes are read again
  /// when it closes.
  final Future<void> Function() onOpenAnalysis;

  /// Shown below the player (the summary's kept frames and "Identify
  /// organisms").
  final List<Widget> footer;

  /// Shown under the tab's explanation (round 239: the clips' totals).
  final List<Widget> header;

  /// Clips recorded during a live AI session (round 240): the boxes are the
  /// live AI's own (session.jsonl), not those of "Run AI on videos".
  final bool live;

  /// Freezes the list's scrolling while a kept frame below is zoomed, so a
  /// drag pans the picture instead of scrolling the page away.
  final bool scrollLocked;

  const VideoReviewPlayer({
    super.key,
    required this.sessionDir,
    required this.padding,
    required this.onOpenAnalysis,
    this.footer = const [],
    this.header = const [],
    this.live = false,
    this.scrollLocked = false,
  });

  /// Same colours as the summary's photo viewer: tracked objects cyan,
  /// boxes straight from the detector green.
  static const visitColor = Color(0xFF00E5FF);
  static const rawColor = Color(0xFF76FF03);

  static const speeds = [0.5, 1.0, 2.0, 4.0];

  @override
  State<VideoReviewPlayer> createState() => VideoReviewPlayerState();
}

class VideoReviewPlayerState extends State<VideoReviewPlayer>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  /// The boxes of "Run AI on videos", and in a live session (round 240) the
  /// live AI's; [_showAfter] picks which one a live session shows (round 241).
  VideoBoxTimeline _afterTimeline = VideoBoxTimeline.empty;
  VideoBoxTimeline _liveTimeline = VideoBoxTimeline.empty;
  bool _showAfter = false;
  VideoBoxTimeline get _timeline => widget.live && !_showAfter ? _liveTimeline : _afterTimeline;

  /// A live session whose clips were also analysed afterwards.
  bool get _canCompare => widget.live && _afterTimeline.clips.isNotEmpty;
  bool _loading = true;

  /// Clip names: the files in videos/ plus clips known only from the records
  /// (their file was deleted).
  List<String> _clips = const [];
  Set<String> _files = const {};

  /// Clips deleted to free storage, with when (round 236).
  Map<String, DateTime> _deleted = const {};

  /// Clips cut off by a killed app: unreadable, left out of the list (round 243).
  int _cutOff = 0;
  int _clip = 0;

  VideoPlayerController? _controller;
  String? _playError;

  /// Counts clip openings, so a slow one that finishes after the user picked
  /// another clip is thrown away.
  int _opening = 0;

  bool _allBoxes = false;

  /// "Track IDs in this clip" is folded by default: long videos can have many (round 247).
  bool _trackListOpen = false;

  /// The new-track confidence the session's "Find visits" used, when logged (round 247).
  double? _newTrackConf;
  bool _aiView = false;
  bool _muted = true;
  double _speed = 1;

  TabController? _tabs;

  late final Ticker _ticker = createTicker(_onTick);

  /// Position the boxes are drawn for (ms).
  final _posMs = ValueNotifier<int>(0);

  /// Whether the clip plays. The buttons listen to this, not to the player,
  /// which reports ten times a second.
  final _playing = ValueNotifier<bool>(false);

  /// Last position the player reported, and the ticker time it arrived.
  int _reportedMs = 0;
  Duration _reportedAt = Duration.zero;
  Duration _tickerNow = Duration.zero;

  /// Whether this tab holds the wakelock (see [_keepAwake]).
  bool _awake = false;

  final _scroll = ScrollController();

  /// The clip picker, player and controls: "Show in video" scrolls it to
  /// the top of the tab.
  final _playerBlock = GlobalKey();

  /// Saved kept frames per clip, as player positions in ms (round 235).
  Map<String, List<int>> _keptMs = const {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Switching to another tab pauses: the tab stays alive (keep-alive) and
    // would otherwise play on unseen.
    final tabs = DefaultTabController.maybeOf(context);
    if (tabs != _tabs) {
      _tabs?.removeListener(_pause);
      _tabs = tabs?..addListener(_pause);
    }
  }

  @override
  void dispose() {
    _tabs?.removeListener(_pause);
    _keepAwake(false);
    _ticker.dispose();
    _controller?.removeListener(_onValue);
    _controller?.dispose();
    _posMs.dispose();
    _playing.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    var after = VideoBoxTimeline.empty, live = VideoBoxTimeline.empty;
    try {
      after = await VideoBoxTimeline.load(widget.sessionDir);
      if (widget.live) live = await VideoBoxTimeline.loadLive(widget.sessionDir);
    } catch (e) {
      logSwallowed('video_box_timeline', e);
    }
    final all = VideoDetector.clipsOf(widget.sessionDir);
    final files = {for (final f in all.where(VideoDetector.isReadableVideo)) f.uri.pathSegments.last};
    final deleted = await ClipCleanup.deletedClips(widget.sessionDir);
    final newTrackConf = (await VideoTracker.readSummary(widget.sessionDir))?.newTrackConfidence;
    final keptMs = <String, List<int>>{};
    final framesDir = '${widget.sessionDir.path}/${VideoTracker.framesDirName}';
    for (final k in await VideoTracker.readKeptFrames(widget.sessionDir)) {
      if (File('$framesDir/${k.file}').existsSync()) (keptMs[k.clip] ??= []).add(k.ptsUs ~/ 1000);
    }
    if (!mounted) return;
    final before = _clips.isEmpty ? null : _clips[_clip];
    final clips = {...files, ...after.clips.keys, ...live.clips.keys}.toList()..sort();
    setState(() {
      _afterTimeline = after;
      _liveTimeline = live;
      if (after.clips.isEmpty) _showAfter = false;
      _files = files;
      _cutOff = all.length - files.length;
      _deleted = deleted;
      _clips = clips;
      _keptMs = keptMs;
      _newTrackConf = newTrackConf;
      _loading = false;
    });
    // Reloaded after a new analysis: the same clip keeps playing.
    final keep = before == null ? -1 : clips.indexOf(before);
    if (keep >= 0 && _controller != null) {
      setState(() => _clip = keep);
    } else if (clips.isNotEmpty) {
      await _openClip(max(keep, 0));
    }
  }

  Future<void> _openClip(int index) async {
    final opening = ++_opening;
    final old = _controller;
    old?.removeListener(_onValue);
    _ticker.stop();
    _keepAwake(false);
    setState(() {
      _clip = index;
      _controller = null;
      _playError = null;
    });
    _posMs.value = 0;
    _playing.value = false;
    await old?.dispose();
    final name = _clips[index];
    if (!_files.contains(name)) return;
    final c = VideoPlayerController.file(
      File('${widget.sessionDir.path}/videos/$name'),
      // No audio focus: music the user is listening to keeps playing.
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    try {
      await c.initialize();
      await c.setVolume(_muted ? 0 : 1);
      await c.setPlaybackSpeed(_speed);
    } catch (e) {
      logSwallowed('video_review_open', e);
      await c.dispose();
      if (mounted && opening == _opening) setState(() => _playError = '$e');
      return;
    }
    if (!mounted || opening != _opening) {
      await c.dispose();
      return;
    }
    c.addListener(_onValue);
    setState(() => _controller = c);
    _onValue();
  }

  void _onValue() {
    final v = _controller?.value;
    if (v == null) return;
    final shown = _posMs.value;
    _reportedMs = v.position.inMilliseconds;
    _reportedAt = _tickerNow;
    if (v.isPlaying && !_ticker.isActive) {
      _tickerNow = _reportedAt = Duration.zero;
      _ticker.start();
    } else if (!v.isPlaying && _ticker.isActive) {
      _ticker.stop();
    }
    _keepAwake(v.isPlaying);
    _playing.value = v.isPlaying;
    // A report a moment behind the ticker's estimate would pull the boxes
    // back; a real jump (a seek) is taken as is.
    final lateReport = v.isPlaying && _reportedMs < shown && shown - _reportedMs < 250;
    if (!lateReport) _posMs.value = _reportedMs;
  }

  void _onTick(Duration elapsed) {
    _tickerNow = elapsed;
    final c = _controller;
    if (c == null) return;
    // At most 0.4 s of video ahead of the last report: a stalled player
    // must not run the boxes away.
    final ahead = min((elapsed - _reportedAt).inMicroseconds * _speed / 1000, 400 * _speed).round();
    final ms = min(_reportedMs + ahead, c.value.duration.inMilliseconds);
    if (ms > _posMs.value) _posMs.value = ms;
  }

  /// The Android player does not keep the screen on by itself (its
  /// preventsDisplaySleep setting is a no-op there): the screen stays on
  /// while a clip plays, so watching without touching the phone does not end
  /// in a dark screen.
  void _keepAwake(bool on) {
    if (on == _awake) return;
    _awake = on;
    WakelockPlus.toggle(enable: on).catchError((Object e) => logSwallowed('video_review_wakelock', e));
  }

  void _pause() {
    if (_controller?.value.isPlaying ?? false) _controller!.pause();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      // At the end, play starts again from the beginning.
      if (c.value.isCompleted || c.value.position >= c.value.duration) c.seekTo(Duration.zero);
      c.play();
    }
  }

  void _seekTo(int ms) {
    final c = _controller;
    if (c == null) return;
    final target = ms.clamp(0, c.value.duration.inMilliseconds);
    _posMs.value = target;
    c.seekTo(Duration(milliseconds: target));
  }

  void _setSpeed(double speed) {
    setState(() => _speed = speed);
    _controller?.setPlaybackSpeed(speed);
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _controller?.setVolume(_muted ? 0 : 1);
  }

  /// Visits are entered 1 s before they start, to see the insect arrive.
  int _visitEntry(TimelineVisit v) => max(0, v.startMs - 1000);

  void _jumpVisit(ClipBoxes c, {required bool next}) {
    final pos = _posMs.value;
    int? target;
    for (final v in c.visits) {
      final t = _visitEntry(v);
      if (next && t > pos + 100) {
        target = t;
        break;
      }
      // Half a second of grace: pressing twice goes one visit further back.
      if (!next && t < pos - 500) target = t;
    }
    if (target != null) _seekTo(target);
  }

  /// Shows the frame at [ms] of [clip], paused, and scrolls the player into
  /// view (a kept frame's "Show in video", round 234).
  Future<void> showMoment(String clip, int ms) async {
    final index = _clips.indexOf(clip);
    if (index < 0) return;
    _pause();
    if (index != _clip || _controller == null) await _openClip(index);
    if (!mounted) return;
    _seekTo(ms);
    if (!_scroll.hasClients) return;
    // Far down the list the block is not built: back to the top first.
    var block = _playerBlock.currentContext?.findRenderObject();
    if (block == null) {
      _scroll.jumpTo(0);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scroll.hasClients) return;
      block = _playerBlock.currentContext?.findRenderObject();
    }
    // Only this list scrolls (Scrollable.ensureVisible would also move the
    // summary's tab pager).
    if (block != null) {
      await _scroll.position.ensureVisible(
        block,
        alignment: 0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _openAnalysis() async {
    _pause();
    await widget.onOpenAnalysis();
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final name = _clips.isEmpty ? null : _clips[_clip];
    final boxes = name == null ? null : _timeline.clips[name];
    final c = _controller;
    final visits = boxes != null && boxes.tracked && !_allBoxes;
    final frameAspect = c?.value.aspectRatio ?? 1;
    final area = c == null ? null : boxes?.areaFor(frameAspect);
    final aiView = _aiView && area != null;
    return ListView(
      controller: _scroll,
      padding: widget.padding,
      physics: widget.scrollLocked ? const NeverScrollableScrollPhysics() : null,
      children: [
        Text(
          widget.live ? "Videos with the live AI's boxes" : "Videos with the AI's boxes",
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          widget.live
              ? 'Plays the ROI videos recorded during this session with the boxes the live AI '
                    'found at that moment, so you can see what it caught and what it missed. Tap '
                    'the video to pause or play. Boxes show only on the frames the live AI logged '
                    'with an insect. Sound is off unless you switch it on.'
              : 'Plays the videos of this session with the boxes the AI found. Tap the video to '
                    'pause or play. Boxes are shown only on the frames the AI analysed, so at '
                    'higher speeds they can trail a fast insect a little. Sound is off unless you '
                    'switch it on.',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        ...widget.header,
        if (_cutOff > 0) ...[
          const SizedBox(height: 6),
          Text(
            '$_cutOff ${_cutOff == 1 ? 'clip was' : 'clips were'} cut off: the app stopped while recording, so '
            '${_cutOff == 1 ? 'it was' : 'they were'} never finished and cannot be played ("Run AI on videos" '
            'can delete ${_cutOff == 1 ? 'it' : 'them'}).',
            style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
          ),
        ],
        const SizedBox(height: 8),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_clips.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No videos in this session.', style: TextStyle(color: Colors.white70)),
          )
        else ...[
          KeyedSubtree(
            key: _playerBlock,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_clips.length > 1) _clipPicker(),
                ..._notes(name!, boxes),
                _playerBox(c, boxes, frameAspect: frameAspect, area: area, aiView: aiView, visits: visits),
                if (c != null) ..._controls(c, boxes, visitsShown: visits),
              ],
            ),
          ),
          // Round 241: the live AI's boxes, or those of "Run AI on videos" on the same clips.
          if (_canCompare) ...[
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Live AI')),
                ButtonSegment(value: true, label: Text('AI afterwards')),
              ],
              selected: {_showAfter},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() {
                _showAfter = s.first;
                _allBoxes = false;
              }),
            ),
            const SizedBox(height: 4),
            const Text(
              'Live AI: the boxes found while recording (the session\'s track IDs). AI afterwards: '
              '"Run AI on videos" on these clips, with its own track ID numbers. Switch at any moment '
              'to compare the same frames.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
          if (area != null) ...[
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Whole frame')),
                ButtonSegment(value: true, label: Text('What the AI saw')),
              ],
              selected: {_aiView},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _aiView = s.first),
            ),
            const SizedBox(height: 4),
            const Text(
              'Whole frame: the square is the area the AI analysed; the darker part was left out. '
              'What the AI saw: zoomed onto that square. If insects sit outside the square or on its '
              'edge, change it and analyse again (button below).',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
          // The live log holds tracked boxes only (round 240).
          if (boxes != null && boxes.tracked && !_timeline.live) ...[
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Track IDs')),
                ButtonSegment(value: true, label: Text('All AI boxes')),
              ],
              selected: {_allBoxes},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _allBoxes = s.first),
            ),
            const SizedBox(height: 4),
            Text(
              'Track IDs: the boxes "Find track IDs" linked from frame to frame into track IDs. A new '
              'track ID starts only from a box the AI is at least '
              '${(_newTrackConf ?? 0.5).toStringAsFixed(2)} sure of (the tracker\'s "New-track '
              'confidence"); weaker boxes can only continue one. All AI boxes: what the AI detected at '
              'the confidence threshold, before any tracking. An insect with boxes here but no '
              'track ID was probably never that sure: lower "New-track confidence" (camera Settings → '
              'AI → Tracking → Advanced) and run "Find track IDs" again. The AI does not need to '
              'run again for that.',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
          if (boxes != null) ..._legend(visits),
          // The ticks sit under the time bar, which a deleted clip lacks.
          if (c != null && (_keptMs[name]?.isNotEmpty ?? false)) ...[
            const SizedBox(height: 4),
            const Text.rich(
              TextSpan(
                style: TextStyle(color: Colors.white70, fontSize: 12),
                children: [
                  TextSpan(text: '| ', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  TextSpan(text: 'a white tick under the time bar: a frame kept for a track ID (see Kept frames below).'),
                ],
              ),
            ),
          ],
          // Live view (rounds 240, 241): compare with the AI afterwards.
          if (_timeline.live) ...[
            const SizedBox(height: 12),
            const HelpLabel(
              label: 'Compare with the AI afterwards',
              labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
              helperText:
                  '"Run AI on videos" analyses these clips again, frame by frame, and "Find track IDs" '
                  'there links the boxes into track IDs. Then "AI afterwards" above shows those boxes on '
                  'the same frames, for example to see whether the live AI missed insects while the '
                  'phone was hot or the motion gate slept. The session\'s own track IDs stay the live AI\'s.',
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _files.isEmpty ? null : _openAnalysis,
                icon: const Icon(Icons.compare),
                label: Text(_afterTimeline.clips.isEmpty ? 'Run AI on videos' : 'Run AI on videos again'),
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
            // With every video deleted (round 236) nothing can be analysed
            // again; "Find visits" there still works.
            if (_files.isNotEmpty && _timeline.clips.isEmpty)
              // Round 239: before the first analysis there is no square to
              // move yet (recorded bursts, fresh imports).
              const HelpLabel(
                label: 'Not analysed yet',
                labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                helperText:
                    '"Run AI on videos" finds the insects in these videos. It is the slow step and can '
                    'be stopped and continued; keep the phone charging. "Find track IDs" there then '
                    'follows each insect from frame to frame, and the boxes and track IDs show on the '
                    'video here.',
              )
            else if (_files.isEmpty)
              const HelpLabel(
                label: 'Other track ID settings?',
                labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                helperText:
                    'The videos were deleted to free storage, so they cannot be analysed again. '
                    '"Run AI on videos" can still find the track IDs again from the saved boxes, for '
                    'example with another occlusion tolerance or minimum track length.',
              )
            else
              const HelpLabel(
                label: 'Square in the wrong place?',
                labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                helperText:
                    'Opens "Run AI on videos" for this session. There you can move or resize the '
                    'square, analyse the videos again and then press "Find track IDs". The new boxes '
                    'and track IDs replace the ones shown here.',
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _openAnalysis,
                icon: Icon(_files.isEmpty ? Icons.timeline : Icons.crop_free),
                label: Text(
                  _timeline.clips.isEmpty || _files.isEmpty ? 'Run AI on videos' : 'Change square and analyse again',
                ),
              ),
            ),
          ],
          if (boxes != null && boxes.tracked) ..._visitRows(boxes),
        ],
        ...widget.footer,
      ],
    );
  }

  Widget _clipPicker() => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: DropdownButton<int>(
      isExpanded: true,
      value: _clip,
      items: [
        for (var i = 0; i < _clips.length; i++)
          DropdownMenuItem(
            value: i,
            child: Text('${_clips[i]}${_clipNote(_clips[i])}', overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (i) {
        if (i != null && i != _clip) _openClip(i);
      },
    ),
  );

  String _clipNote(String name) {
    final b = _timeline.clips[name];
    if (!_files.contains(name)) {
      // Its visits stay (round 236).
      final v = b != null && b.tracked ? '${b.visits.length} track ID${b.visits.length == 1 ? '' : 's'}, ' : '';
      return ' · ${v}video deleted';
    }
    if (b == null) return ' · not analysed';
    if (!b.done) return ' · analysed in part';
    if (b.tracked) return ' · ${b.visits.length} track ID${b.visits.length == 1 ? '' : 's'}';
    return '';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  List<Widget> _notes(String name, ClipBoxes? boxes) {
    String? note;
    if (!_files.contains(name)) {
      final at = _deleted[name];
      note = at == null
          ? 'The video file of this clip is no longer on the phone.'
          : 'This clip was deleted on ${at.year}-${_two(at.month)}-${_two(at.day)} ${_two(at.hour)}:${_two(at.minute)} to '
                'free storage. Its boxes, track IDs and kept frames stay; only the video cannot be played.';
    } else if (_timeline.live) {
      if (boxes == null || boxes.visits.isEmpty) note = 'The live AI found no insect during this clip.';
    } else if (boxes == null) {
      note = 'This clip was not analysed yet, so there are no boxes. "Run AI on videos" '
          '(button below) finds the insects in it.';
    } else if (!boxes.done) {
      final last = boxes.lastAnalysedMs;
      note = 'The analysis of this clip stopped${last == null ? '' : ' at ${_time(last)}'}; '
          'boxes end there. "Run AI on videos" continues it.';
    } else if (_timeline.visitsStale) {
      note = 'The videos were analysed again after "Find track IDs", so the track IDs no longer match. '
          'The button below opens "Run AI on videos", where "Find track IDs" updates them. Until '
          'then all AI boxes are shown.';
    } else if (!boxes.tracked) {
      note = _timeline.hasVisits
          ? '"Find track IDs" ran before this clip was analysed. The button below opens "Run AI on '
                'videos", where "Find track IDs" adds this clip\'s track IDs. Until then all AI boxes '
                'are shown.'
          : 'No track IDs yet: "Find track IDs" on "Run AI on videos" (button below) links the boxes '
                'of each insect into track IDs. Until then all AI boxes are shown.';
    }
    if (note == null) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(note, style: const TextStyle(color: Colors.amberAccent, fontSize: 12)),
      ),
    ];
  }

  Widget _playerBox(
    VideoPlayerController? c,
    ClipBoxes? boxes, {
    required double frameAspect,
    required Rect? area,
    required bool aiView,
    required bool visits,
  }) {
    // Portrait clips would fill the screen: the player takes at most 55 % of
    // its height, so the controls stay in view.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.55;
    Widget child;
    var aspect = 16 / 9;
    if (c == null) {
      child = Container(
        color: Colors.black,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: _playError != null
            ? Text(
                'This phone could not play this clip.\n$_playError',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              )
            : _files.contains(_clips[_clip])
            ? const CircularProgressIndicator()
            : const Icon(Icons.videocam_off, color: Colors.white38),
      );
    } else {
      final view = aiView ? area! : const Rect.fromLTWH(0, 0, 1, 1);
      aspect = frameAspect * view.width / view.height;
      child = GestureDetector(
        onTap: _togglePlay,
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth / view.width;
            final h = box.maxHeight / view.height;
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(left: -view.left * w, top: -view.top * h, width: w, height: h, child: VideoPlayer(c)),
                // Repainted every frame while playing: its own layer keeps the
                // rest of the card from being painted again with it.
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _OverlayPainter(
                        position: _posMs,
                        boxesAt: (ms) => boxes == null
                            ? const []
                            : visits
                            ? boxes.trackedAt(ms)
                            : boxes.rawAt(ms),
                        view: view,
                        area: aiView ? null : area,
                        visits: visits,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: AspectRatio(aspectRatio: aspect, child: ClipRect(child: child)),
      ),
    );
  }

  List<Widget> _controls(VideoPlayerController c, ClipBoxes? boxes, {required bool visitsShown}) {
    final hasVisits = boxes != null && boxes.tracked && boxes.visits.isNotEmpty;
    return [
      VideoProgressIndicator(c, allowScrubbing: true, padding: const EdgeInsets.only(top: 10, bottom: 4)),
      if (hasVisits && visitsShown)
        SizedBox(
          height: 6,
          width: double.infinity,
          child: CustomPaint(painter: _VisitStripPainter(boxes.visits, c.value.duration.inMilliseconds)),
        )
      // All AI boxes, or not tracked yet: the frames with at least one box (round 247).
      else if (boxes != null && !visitsShown && boxes.rawBoxMs.isNotEmpty)
        SizedBox(
          key: const ValueKey('raw_box_strip'),
          height: 6,
          width: double.infinity,
          child: CustomPaint(painter: _RawStripPainter(boxes.rawBoxMs, c.value.duration.inMilliseconds)),
        ),
      if (_keptMs[_clips[_clip]] case final kept? when kept.isNotEmpty)
        SizedBox(
          key: const ValueKey('kept_frame_ticks'),
          height: 6,
          width: double.infinity,
          child: CustomPaint(painter: _KeptTickPainter(kept, c.value.duration.inMilliseconds)),
        ),
      const SizedBox(height: 4),
      RepaintBoundary(
        child: ValueListenableBuilder<int>(
          valueListenable: _posMs,
          builder: (_, ms, _) => Text(
            '${_time(ms)} / ${_time(c.value.duration.inMilliseconds)}',
            style: const TextStyle(color: Colors.white70, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ),
      ),
      ValueListenableBuilder<bool>(
        valueListenable: _playing,
        builder: (_, playing, _) => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'Previous track ID',
              onPressed: hasVisits ? () => _jumpVisit(boxes, next: false) : null,
              icon: const Icon(Icons.skip_previous),
            ),
            IconButton(
              tooltip: 'Back 5 s',
              onPressed: () => _seekTo(_posMs.value - 5000),
              icon: const Icon(Icons.replay_5),
            ),
            IconButton(
              tooltip: playing ? 'Pause' : 'Play',
              onPressed: _togglePlay,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            ),
            IconButton(
              tooltip: 'Forward 5 s',
              onPressed: () => _seekTo(_posMs.value + 5000),
              icon: const Icon(Icons.forward_5),
            ),
            IconButton(
              tooltip: 'Next track ID',
              onPressed: hasVisits ? () => _jumpVisit(boxes, next: true) : null,
              icon: const Icon(Icons.skip_next),
            ),
            IconButton(
              tooltip: _muted ? 'Sound on' : 'Sound off',
              onPressed: _toggleMute,
              icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
            ),
          ],
        ),
      ),
      Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('Speed:', style: TextStyle(color: Colors.white70, fontSize: 12)),
          for (final s in VideoReviewPlayer.speeds)
            ChoiceChip(
              label: Text('${s == s.roundToDouble() ? s.round() : s}×'),
              selected: _speed == s,
              onSelected: (_) => _setSpeed(s),
            ),
        ],
      ),
    ];
  }

  List<Widget> _legend(bool visits) => [
    const SizedBox(height: 6),
    Text.rich(
      TextSpan(
        style: const TextStyle(color: Colors.white70, fontSize: 12),
        children: visits
            ? [
                const TextSpan(text: '■ ', style: TextStyle(color: VideoReviewPlayer.visitColor)),
                TextSpan(
                  text: 'a track ID: its number (the same as ${_timeline.live ? 'on the photos and in the Graphs' : 'in visits.csv'}), '
                      "the insect class and the AI's confidence. A faded box: the AI missed the insect "
                      'on this frame and the tracker kept its place.',
                ),
              ]
            : const [
                TextSpan(text: '■ ', style: TextStyle(color: VideoReviewPlayer.rawColor)),
                TextSpan(
                  text: 'every box the AI found, with its class and confidence, also the ones no track ID '
                      'was made from (for example an insect seen too briefly, or never sure enough to '
                      'start one). The strip under the time bar marks the frames with at least one box.',
                ),
              ],
      ),
    ),
  ];

  /// "Track IDs in this clip (N)", folded by default (round 247): a long video can have
  /// hundreds. Open, each row jumps the video to its track ID.
  List<Widget> _visitRows(ClipBoxes boxes) => [
    const SizedBox(height: 12),
    // Header and note are one tap target.
    InkWell(
      key: const ValueKey('track_list_toggle'),
      onTap: boxes.visits.isEmpty ? null : () => setState(() => _trackListOpen = !_trackListOpen),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (boxes.visits.isNotEmpty) Icon(_trackListOpen ? Icons.expand_more : Icons.chevron_right, size: 20),
                Expanded(
                  child: Text(
                    'Track IDs in this clip (${boxes.visits.length})',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            Text(
              '${_timeline.live ? 'Found by the live AI. ' : ''}A track ID usually stands for one visit in '
              'pollination ecology, but some can be false detections (a '
              'leaf, a shadow, a blur): how well the AI does depends on how much these videos look like '
              'what it learned from. ${boxes.visits.isEmpty ? '' : _trackListOpen ? 'Tap a track ID below to watch it from 1 s before it starts.' : 'Tap to list them with their times.'}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    ),
    if (_trackListOpen)
      for (final v in boxes.visits)
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          contentPadding: EdgeInsets.zero,
          leading: Text('#${v.trackId}', style: const TextStyle(color: VideoReviewPlayer.visitColor)),
          title: Text(v.className, overflow: TextOverflow.ellipsis),
          trailing: Text(
            '${_time(v.startMs)} – ${_time(v.endMs)}',
            style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
          ),
          onTap: _controller == null ? null : () => _seekTo(_visitEntry(v)),
        ),
  ];

  /// m:ss.s, or h:mm:ss for an hour or more.
  static String _time(int ms) {
    final s = ms ~/ 1000;
    String two(int n) => n.toString().padLeft(2, '0');
    if (s >= 3600) return '${s ~/ 3600}:${two(s ~/ 60 % 60)}:${two(s % 60)}';
    return '${s ~/ 60}:${two(s % 60)}.${ms % 1000 ~/ 100}';
  }
}

/// The analysed square (outside dimmed) and the boxes of the current
/// position. [view] is the part of the frame on screen (normalised), so
/// lines and labels keep their size in the zoomed view.
class _OverlayPainter extends CustomPainter {
  final ValueListenable<int> position;
  final List<TimelineBox> Function(int ms) boxesAt;
  final Rect view;
  final Rect? area;
  final bool visits;

  _OverlayPainter({
    required this.position,
    required this.boxesAt,
    required this.view,
    required this.area,
    required this.visits,
  }) : super(repaint: position);

  Rect _toScreen(Rect r, Size size) => Rect.fromLTRB(
    (r.left - view.left) / view.width * size.width,
    (r.top - view.top) / view.height * size.height,
    (r.right - view.left) / view.width * size.width,
    (r.bottom - view.top) / view.height * size.height,
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (area case final a?) {
      final r = _toScreen(a, size);
      canvas.drawPath(
        Path()
          ..addRect(Offset.zero & size)
          ..addRect(r)
          ..fillType = PathFillType.evenOdd,
        Paint()..color = Colors.black.withValues(alpha: 0.55),
      );
      canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white54,
      );
    }
    for (final b in boxesAt(position.value)) {
      final color = (visits ? VideoReviewPlayer.visitColor : VideoReviewPlayer.rawColor).withValues(
        alpha: b.coasted ? 0.45 : 1,
      );
      final rect = _toScreen(b.box, size);
      canvas.drawRect(
        rect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      final label = [
        if (b.trackId != null) '#${b.trackId}',
        if (b.className.isNotEmpty) b.className,
        b.confidence.toStringAsFixed(2),
      ].join(' ');
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(color: Colors.black, fontSize: 11, backgroundColor: color),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(rect.left, (rect.top - 13).clamp(0, max(0, size.height - 13))));
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) =>
      old.view != view || old.area != area || old.visits != visits || old.boxesAt != boxesAt;
}

/// The visits of the clip as bars under the scrubber.
/// White 2-px ticks at the kept frames of a clip (round 235), scaled like
/// [_VisitStripPainter].
class _KeptTickPainter extends CustomPainter {
  final List<int> keptMs;
  final int durationMs;
  _KeptTickPainter(this.keptMs, this.durationMs);

  @override
  void paint(Canvas canvas, Size size) {
    if (durationMs <= 0) return;
    final paint = Paint()..color = Colors.white;
    for (final ms in keptMs) {
      final x = (ms / durationMs * size.width).clamp(0.0, size.width - 2);
      canvas.drawRect(Rect.fromLTWH(x, 0, 2, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _KeptTickPainter old) => old.keptMs != keptMs || old.durationMs != durationMs;
}

/// 2-px ticks in the raw box colour at the analysed frames with at least one box, under the
/// time bar in "All AI boxes" (round 247); scaled like [_VisitStripPainter].
class _RawStripPainter extends CustomPainter {
  final List<int> frameMs;
  final int durationMs;
  _RawStripPainter(this.frameMs, this.durationMs);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white10);
    if (durationMs <= 0) return;
    final paint = Paint()..color = VideoReviewPlayer.rawColor;
    for (final ms in frameMs) {
      final x = (ms / durationMs * size.width).clamp(0.0, size.width - 2);
      canvas.drawRect(Rect.fromLTWH(x, 0, 2, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RawStripPainter old) => old.frameMs != frameMs || old.durationMs != durationMs;
}

class _VisitStripPainter extends CustomPainter {
  final List<TimelineVisit> visits;
  final int durationMs;
  _VisitStripPainter(this.visits, this.durationMs);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white10);
    if (durationMs <= 0) return;
    final paint = Paint()..color = VideoReviewPlayer.visitColor;
    for (final v in visits) {
      final l = v.startMs / durationMs * size.width;
      // At least 2 px, so a short visit in a long clip still shows.
      final r = max(v.endMs / durationMs * size.width, l + 2);
      canvas.drawRect(Rect.fromLTRB(l, 0, min(r, size.width), size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _VisitStripPainter old) => old.visits != visits || old.durationMs != durationMs;
}
