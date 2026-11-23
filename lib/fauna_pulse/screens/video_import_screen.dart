// FaunaPulse (round 227): the step between picking videos and analysing
// them, for clips filmed outside FaunaPulse (the phone's camera app, a
// collaborator, a published dataset).
//
// [pickAndImportVideos] picks the files; this screen shows what was picked and
// when each clip started (and how sure that is), lets the user fix the start
// and name the session, then moves the files into a new session folder
// (postprocess/video_import.dart). Detection runs later, on the "Find animals
// in videos" screen, which the finished import offers to open.
//
// Round 277: the pick-and-import flow moved here from the home screen, so the
// home screen's "Find animals in videos" (when no videos are imported yet),
// the Sessions screen's ⋮ menu and the Find animals in videos screen start the
// same flow. The home screen's ⋮ menu no longer has it. Later in round 277
// (owner: start where the camera's videos are): Android's photo picker, whose
// own ⋮ menu browses the phone's folders (the file picker and its round 233
// hint are gone); a note on this screen says the videos are copies that take
// storage twice.
//
// Round 306 (owner): the line under the start says, before any change, what
// the file name and the time stored in the video gave; a time set by hand
// starts at second 0 (the time picker has no seconds); the undo button says
// what it restores; the suggested session name follows a changed day.
//
// Round 319 (stress test): a failed pick (storage full) says so in plain
// words and deletes the picker's half copies; the free-storage check runs
// again when the app comes back to the front and before the copy starts.
//
// Round 395 (owner): Android's file chooser instead of the photo picker,
// which hands over only a number as the file name (1000071485.mp4), so the
// date in a name never arrived. Each clip shows its day and has its own
// Change…; "Set all clips…" keeps the gaps, puts the clips one after the
// other or starts them all at one time (one shift for all had moved clips
// whose times came from elsewhere into the future). The suggested session
// name is the import day.

import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart' show VideoFrameSource, VideoInfo;

import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';
import '../logging/past_sessions.dart' show sessionsRoot;
import '../postprocess/video_detector.dart' show VideoDetector;
import '../postprocess/video_import.dart';
import '../postprocess/video_start_time.dart';
import '../widgets/dialog_title.dart';
import '../widgets/setting_help.dart';
import '../widgets/home_button.dart';

/// Picks videos with Android's file chooser and opens [VideoImportScreen]
/// (round 227; the file chooser again since round 395: it keeps the file
/// names, lists recent videos first and browses the phone's folders). The
/// chooser copies every chosen file into the app's cache before it returns,
/// which takes a while for long videos, so a dialog says so meanwhile.
/// Closing the chooser without a choice just returns. Returns the new
/// session folder when the user chose to find animals in it right away,
/// else null (also when a session was imported without that choice).
Future<String?> pickAndImportVideos(BuildContext context) async {
  // The chooser's progress report adds nothing here: the dialog opens under
  // it and shows once it closes, while the chosen videos are copied.
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('Reading the videos…')),
          ],
        ),
      ),
    ),
  );
  List<PickedVideo> files = const [];
  // Round 319: what a failed pick leaves is told apart from what was there.
  Directory? cache;
  var before = <String>{};
  int? freeBefore;
  try {
    cache = await getTemporaryDirectory();
    before = {for (final d in pickerVideoCopyFolders(cache)) d.path};
    freeBefore = (await DeviceStorage.read(path: cache.path)).freeBytes;
  } catch (e) {
    logSwallowed('video_pick_cache', e);
  }
  String? failure;
  try {
    Object? error;
    try {
      // By ending, not FileType.video: for that the plugin (file_picker
      // 10.3) sends the list of types as one text, and Android's chooser
      // then shows every file (seen on the Xiaomi 11T); for endings it sends
      // a proper list.
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: VideoDetector.videoExtensions.toList(),
        allowMultiple: true,
      );
      files = [
        for (final f in picked?.files ?? const <PlatformFile>[])
          if (f.path != null) PickedVideo(f.path!, f.name, f.size),
      ];
    } catch (e) {
      logSwallowed('video_pick', e);
      error = e;
    }
    // The chooser leaves out a file whose copy failed (storage full) and
    // keeps its half copy, so a copy of this pick it did not hand over failed.
    final handed = {for (final f in files) f.path};
    final copyFailed =
        cache != null &&
        pickerVideoCopyFolders(cache).any(
          (d) => !before.contains(d.path) && d.listSync().any((f) => f is File && !handed.contains(f.path)),
        );
    if (error != null || copyFailed) {
      files = const [];
      failure = await failedPickMessage(
        cache: cache,
        before: before,
        freeBeforeBytes: freeBefore,
        copyFailed: copyFailed,
      );
    }
  } finally {
    if (context.mounted) Navigator.of(context).pop(); // the dialog
  }
  if (failure != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(failure), duration: const Duration(seconds: 10), showCloseIcon: true),
    );
  }
  if (files.isEmpty || !context.mounted) return null;
  return Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => VideoImportScreen(files: files)));
}

/// Free storage under which a failed pick is put down to full storage.
const _kNearlyFullBytes = 64 * 1024 * 1024;

/// After a failed pick: deletes every copy this pick left in [cache] (the
/// folders not in [before]) and says what happened in plain words (round
/// 319). [copyFailed]: a chosen file was not copied. The chooser does not
/// say why, so full storage is told by the space left: almost none, or the
/// half copies used up what was free before the pick.
Future<String> failedPickMessage({
  Directory? cache,
  Set<String> before = const {},
  int? freeBeforeBytes,
  bool copyFailed = false,
}) async {
  final fresh = cache == null ? const <Directory>[] : pickerVideoCopyFolders(cache).where((d) => !before.contains(d.path));
  final freeAtFailure = (await DeviceStorage.read(path: cache?.path)).freeBytes;
  final copied = deletePickerCopies(fresh.toList());
  final full =
      (freeAtFailure != null && freeAtFailure < _kNearlyFullBytes) ||
      (freeBeforeBytes != null && copied > 0 && copied + _kNearlyFullBytes >= freeBeforeBytes);
  if (full) return notEnoughStorageMessage(freeBytes: (await DeviceStorage.read(path: cache?.path)).freeBytes);
  if (copied > 0 || copyFailed) {
    return 'One of the videos could not be copied into the app. Try again, or pick the videos one at a '
        'time to find the one that fails.';
  }
  return 'The videos could not be opened. Try again.';
}

/// The message when the videos do not fit, with the sizes that are known.
String notEnoughStorageMessage({int? neededBytes, int? freeBytes, String next = 'Free some space and try again.'}) {
  // One unit for both, the one of the larger number (round 319).
  final unit = max(neededBytes ?? 0, freeBytes ?? 0);
  final sizes = [
    if (neededBytes != null) '${formatBytes(neededBytes, unitOf: unit)} needed',
    if (freeBytes != null) '${formatBytes(freeBytes, unitOf: unit)} free',
  ];
  return 'The videos could not be copied: not enough free storage'
      '${sizes.isEmpty ? '' : ' (${sizes.join(', ')})'}. $next';
}

/// One file the picker returned: its path in the picker's cache, the name it
/// had on the phone, and its size.
class PickedVideo {
  final String path;
  final String name;
  final int sizeBytes;
  const PickedVideo(this.path, this.name, this.sizeBytes);
}

/// Room kept free on top of the largest clip: each clip is copied, then its
/// picker copy deleted, so at most one extra copy exists at a time.
const kImportSpareBytes = 200 * 1024 * 1024;

class VideoImportScreen extends StatefulWidget {
  final List<PickedVideo> files;

  /// Tests replace the native file reader and the sessions folder.
  final Future<VideoInfo> Function(String path)? infoFn;
  final Directory? sessionsDir;

  const VideoImportScreen({super.key, required this.files, this.infoFn, this.sessionsDir});

  @override
  State<VideoImportScreen> createState() => _VideoImportScreenState();
}

class _VideoImportScreenState extends State<VideoImportScreen> with WidgetsBindingObserver {
  bool _loading = true;
  List<ImportClip> _clips = const [];

  /// Files left out, with the reason in plain language.
  List<(String, String)> _rejected = const [];
  final _name = TextEditingController();
  Directory? _sessionsDir;
  int? _freeBytes;

  /// Starts the user set, by clip index (the others keep the read times).
  final Map<int, int> _setMs = {};

  bool _importing = false;
  int _done = 0;

  /// Share of the fragmented clip being rewritten (round 252), else null.
  double? _rewrite;
  String? _error;
  Directory? _result;

  /// A failed import took picked copies with it: only a new pick can retry.
  bool _mustRepick = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  /// Round 319: space freed in another app counts as soon as the user is back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_loading && !_importing && _result == null) _refreshFree();
  }

  /// Free storage where sessions are saved (null in tests that give the
  /// sessions folder).
  Future<int?> _readFree(Directory sessionsDir) async =>
      widget.sessionsDir != null ? null : (await DeviceStorage.read(path: sessionsDir.parent.path)).freeBytes;

  Future<void> _refreshFree() async {
    final dir = _sessionsDir;
    if (dir == null) return;
    final free = await _readFree(dir);
    if (mounted) setState(() => _freeBytes = free);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _name.dispose();
    // The picker leaves a copy of every picked file in the app's cache,
    // which can be gigabytes of video; clear it however the screen is left.
    _clearPickerCache();
    super.dispose();
  }

  Future<void> _clearPickerCache() async {
    if (widget.infoFn != null) return; // tests: no picker ran
    try {
      // The file chooser puts each copy in a folder of its own in the app's
      // cache; an imported clip was moved away already.
      final cache = (await getTemporaryDirectory()).path;
      for (final f in widget.files) {
        final copy = File(f.path);
        if (!copy.path.startsWith('$cache/')) continue;
        if (await copy.exists()) await copy.delete();
        final folder = copy.parent;
        if (folder.path != cache && await folder.exists() && await folder.list().isEmpty) await folder.delete();
      }
    } catch (e) {
      logSwallowed('video_import_clear_cache', e);
    }
  }

  Future<void> _load() async {
    final infoFn = widget.infoFn ?? VideoFrameSource.info;
    final clips = <ImportClip>[];
    final rejected = <(String, String)>[];
    for (final f in widget.files) {
      VideoInfo info;
      try {
        info = await infoFn(f.path);
      } catch (e) {
        logSwallowed('video_import_info', e);
        rejected.add((f.name, 'Could not be read as a video.'));
        continue;
      }
      int? modified;
      try {
        modified = File(f.path).lastModifiedSync().millisecondsSinceEpoch;
      } catch (_) {}
      final clip = ImportClip(
        path: f.path,
        name: f.name,
        sizeBytes: f.sizeBytes,
        info: info,
        guess: guessClipStart(
          fileName: f.name,
          storedMs: info.creationEpochMs,
          durationMs: info.durationMs,
          fileModifiedMs: modified,
        ),
        fragmented: isFragmentedMp4(File(f.path)),
      );
      final problem = clip.problem;
      if (problem != null) {
        rejected.add((f.name, problem));
      } else {
        clips.add(clip);
      }
    }
    Directory? sessionsDir = widget.sessionsDir;
    sessionsDir ??= await sessionsRoot();
    final free = await _readFree(sessionsDir);
    if (!mounted) return;
    setState(() {
      _clips = clips;
      _rejected = rejected;
      _sessionsDir = sessionsDir;
      _freeBytes = free;
      if (clips.isNotEmpty) _name.text = defaultImportName(DateTime.now());
      _loading = false;
    });
  }

  List<ClipStart> get _plan => planImport(_clips, setMs: _setMs);

  /// Bytes needed on top of what the picker's copies already use.
  int get _neededBytes => _clips.map((c) => c.sizeBytes).fold(0, max) + kImportSpareBytes;

  bool get _enoughSpace => _freeBytes == null || _freeBytes! >= _neededBytes;

  /// [bytes] in the unit of the larger of the free and needed storage, so
  /// the line about them has one unit (round 319).
  String _sameUnit(int bytes) => formatBytes(bytes, unitOf: max(_freeBytes ?? 0, _neededBytes));

  /// The date and time pickers, opened on [initialMs]; null when cancelled.
  Future<int?> _pickStart(int initialMs, {required String dayHelp, required String timeHelp}) async {
    final current = DateTime.fromMillisecondsSinceEpoch(initialMs);
    final firstDate = DateTime(2000);
    final lastDate = DateTime.now().add(const Duration(days: 1));
    final date = await showDatePicker(
      context: context,
      // A wrong camera clock can put the guess outside the picker's range.
      initialDate: current.isAfter(lastDate) ? lastDate : (current.isBefore(firstDate) ? firstDate : current),
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: dayHelp,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      helpText: timeHelp,
      // 24 hours, as the clip rows show times.
      builder: (ctx, child) =>
          MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (time == null || !mounted) return null;
    // Round 306 (owner): the picker has no seconds, so a time set by hand
    // starts at second 0.
    return DateTime(date.year, date.month, date.day, time.hour, time.minute).millisecondsSinceEpoch;
  }

  Future<void> _changeClip(ClipStart c) async {
    final ms = await _pickStart(
      c.startMs,
      dayHelp: 'Day this clip was filmed',
      timeHelp: 'Time this clip started',
    );
    if (ms != null) setState(() => _setMs[c.index] = ms);
  }

  /// "Set all clips…": how, then the first clip's (or every clip's) start.
  Future<void> _setAll() async {
    final how = await showDialog<_SetAll>(context: context, builder: (_) => const _SetAllDialog());
    if (how == null || !mounted) return;
    final plan = _plan;
    final same = how == _SetAll.sameStart;
    final ms = await _pickStart(
      plan.first.startMs,
      dayHelp: same ? 'Day all clips were filmed' : 'Day the first clip was filmed',
      timeHelp: same ? 'Time all clips started' : 'Time the first clip started',
    );
    if (ms == null) return;
    setState(() {
      switch (how) {
        case _SetAll.keepGaps:
          for (final c in plan) {
            _setMs[c.index] = c.startMs + ms - plan.first.startMs;
          }
        case _SetAll.oneAfterAnother:
          // In name order: the parts of one recording are numbered.
          var t = ms;
          for (final c in [...plan]..sort((a, b) => a.name.compareTo(b.name))) {
            _setMs[c.index] = t;
            t += c.durationMs;
          }
        case _SetAll.sameStart:
          for (final c in plan) {
            _setMs[c.index] = ms;
          }
      }
    });
  }

  Future<void> _import() async {
    final sessionsDir = _sessionsDir;
    if (sessionsDir == null || _clips.isEmpty) return;
    setState(() {
      _importing = true;
      _done = 0;
      _error = null;
    });
    try {
      // Round 319: the storage may have filled up since the screen opened.
      _freeBytes = await _readFree(sessionsDir);
      if (!_enoughSpace) return;
      final extras = <String, dynamic>{
        'build_mode': kReleaseMode
            ? 'release'
            : kProfileMode
            ? 'profile'
            : 'debug',
      };
      if (widget.infoFn == null) {
        try {
          final p = await PackageInfo.fromPlatform();
          extras.addAll({'app_version': p.version, 'app_build': p.buildNumber});
        } catch (e) {
          logSwallowed('video_import_app_info', e);
        }
      }
      sessionsDir.createSync(recursive: true);
      final dir = await importVideos(
        sessionsDir: sessionsDir,
        sessionName: _name.text,
        clips: _clips,
        setMs: _setMs,
        startExtras: extras,
        onProgress: (done, total, name) {
          if (mounted) {
            setState(() {
              _done = done;
              _rewrite = null;
            });
          }
        },
        onRewrite: (f) {
          if (mounted) setState(() => _rewrite = f);
        },
      );
      await _clearPickerCache();
      if (mounted) setState(() => _result = dir);
    } catch (e) {
      logSwallowed('video_import', e);
      final free = await _readFree(sessionsDir);
      // A clip moved into the deleted folder is gone from the picker's copies.
      final lost = widget.files.any((f) => !File(f.path).existsSync());
      if (mounted) {
        setState(() {
          _freeBytes = free ?? _freeBytes;
          _mustRepick = lost;
          _error = _importError(e, free, lost);
        });
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// [e] from [importVideos] in plain words (round 319: no raw error text).
  String _importError(Object e, int? free, bool lost) {
    if (e is ImportRewriteFailed) return 'Import failed: $e';
    final full = e is FileSystemException && (e.osError?.errorCode == 28 || '${e.osError}'.contains('No space left'));
    final next = lost ? 'go back and pick the videos again.' : 'try again.';
    // Sizes only when they show the shortage (free can read as enough once
    // the failed copy is deleted).
    final shows = free != null && free < _neededBytes;
    if (full) {
      return notEnoughStorageMessage(
        neededBytes: shows ? _neededBytes : null,
        freeBytes: shows ? free : null,
        next: 'Free some space, then $next',
      );
    }
    return 'The videos could not be copied. ${next[0].toUpperCase()}${next.substring(1)}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_importing,
      child: Scaffold(
        appBar: AppBar(title: const Text('Import videos'), actions: const [HomeButton()]),
        // SafeArea: without it the list's last lines sit under the system
        // navigation bar and can never be scrolled into view.
        body: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: _result != null ? _finished() : _form(),
                ),
        ),
      ),
    );
  }

  List<Widget> _form() {
    if (_clips.isEmpty) {
      return [
        const Text('None of the picked files can be analyzed.'),
        const SizedBox(height: 12),
        ..._rejectedList(),
      ];
    }
    final plan = _plan;
    final names = clipFileNames(plan);
    final totalMs = plan.fold<int>(0, (s, c) => s + c.durationMs);
    final totalBytes = _clips.fold<int>(0, (s, c) => s + c.sizeBytes);
    return [
      const HelpLabel(
        label: 'Adds the videos as a new session. The detector runs on them afterwards, from "Find animals in videos".',
        labelStyle: TextStyle(color: Colors.white70, fontSize: 13),
        helperText:
            'The videos are copied into the app\'s own folder for this session (the originals on '
            'the phone stay where they are). '
            '10-bit (HDR) videos must be re-exported as ordinary 8-bit ones first.',
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _name,
        enabled: !_importing,
        decoration: const InputDecoration(
          labelText: 'Session name',
          border: OutlineInputBorder(),
          helperText: 'Letters, digits, spaces, - and _ (anything else becomes _).',
          helperMaxLines: 2,
        ),
      ),
      const SizedBox(height: 16),
      const HelpLabel(
        label: 'When filming started',
        labelStyle: TextStyle(color: Colors.white),
        helperText:
            'Track IDs are placed on the clock from these times, so graphs and exports show when '
            'insects came. The app reads each time from the file name or from the time stored in the '
            'video. Phone cameras store when filming stopped; an edited video stores when it was '
            'edited, and files sent through messengers often lose the time. Change… sets one clip, '
            'Set all clips… every clip at once. The seconds become 0 (the time picker has no seconds).',
      ),
      if (plan.length > 1 || _setMs.isNotEmpty)
        Wrap(
          spacing: 8,
          children: [
            if (plan.length > 1)
              TextButton.icon(
                onPressed: _importing ? null : _setAll,
                icon: const Icon(Icons.edit_calendar, size: 18),
                label: const Text('Set all clips…'),
              ),
            if (_setMs.isNotEmpty)
              TextButton(
                onPressed: _importing ? null : () => setState(_setMs.clear),
                child: Text(
                  plan.length == 1 ? 'Back to the time read from the file' : 'Back to the times read from the files',
                ),
              ),
          ],
        ),
      const SizedBox(height: 8),
      Text(
        '${plan.length} ${plan.length == 1 ? 'clip' : 'clips'} · ${_length(totalMs)} · ${formatBytes(totalBytes)}',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      for (final c in plan) _clipRow(c, names[c.index]!),
      if (_rejected.isNotEmpty) ...[
        const SizedBox(height: 12),
        ..._rejectedList(),
      ],
      const SizedBox(height: 16),
      // Not after a failed import that lost the clips: the error line says
      // to pick them again, and this line would say to come back here.
      if (!_enoughSpace && !_mustRepick)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Not enough free storage: ${_sameUnit(_freeBytes!)} free, about '
            '${_sameUnit(_neededBytes)} needed during the import. Free some space in another app (for example Files), '
            'then come back to this screen. If you delete sessions in FaunaPulse instead, pick the '
            'videos again afterwards.',
            style: const TextStyle(color: Colors.redAccent, fontSize: 12.5),
          ),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          // Selectable: the message can carry a command to copy (round 252).
          child: SelectableText(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12.5)),
        ),
      if (_importing) ...[
        LinearProgressIndicator(value: (_done + (_rewrite ?? 0)) / plan.length, minHeight: 6),
        const SizedBox(height: 8),
        Text(
          _rewrite == null
              ? 'Copying clip ${min(_done + 1, plan.length)} of ${plan.length}…'
              : 'Rewriting clip ${min(_done + 1, plan.length)} of ${plan.length} as a plain MP4… '
                    '${(_rewrite! * 100).round()} %',
          textAlign: TextAlign.center,
        ),
      ] else ...[
        // Read before the import (round 277, owner).
        const _StorageNote(),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _enoughSpace && !_mustRepick ? _import : null,
          icon: const Icon(Icons.download_done),
          label: Text('Import ${plan.length} ${plan.length == 1 ? 'clip' : 'clips'}'),
        ),
      ],
    ];
  }

  /// One clip: name, start with its day, where the start came from, the
  /// name it gets in the session ([savedAs]) when that differs, and its own
  /// Change….
  Widget _clipRow(ClipStart c, String savedAs) {
    final set = c.source == 'user';
    final flag = c.startMs > DateTime.now().millisecondsSinceEpoch
        ? ' (in the future: check the day)'
        : c.source == 'after_previous'
        ? ' (no time of its own: follows the clip before)'
        : c.movable
        ? ' (time uncertain)'
        : '';
    const small = TextStyle(fontSize: 12, color: Colors.white54);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.movie_outlined, size: 18, color: Colors.white54),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.name, overflow: TextOverflow.ellipsis),
                Text(
                  '${_dateTime(c.startMs)} · ${_length(c.durationMs)}$flag',
                  style: flag.isEmpty ? small : small.copyWith(color: Colors.amber),
                ),
                Text(
                  set ? 'Set by you (before: ${_dateTime(c.guess.epochMs)}).' : c.guess.note,
                  style: c.guess.weak && !set ? small.copyWith(color: Colors.amber) : small,
                ),
                // Round 395 (owner): a changed name is said, with the reason.
                if (savedAs != c.name)
                  Text(
                    'Saved as "$savedAs": spaces and signs become _ so that other programs and Windows '
                    'computers can open it.',
                    style: small,
                  ),
                if (_clips[c.index].fragmented)
                  const Text(
                    'Fragmented MP4 (as some download tools save videos): the video player cannot jump in it, so the '
                    'app writes it once more as a plain MP4 while importing. Same pictures and sound, '
                    'nothing re-compressed.',
                    style: small,
                  ),
              ],
            ),
          ),
          TextButton(onPressed: _importing ? null : () => _changeClip(c), child: const Text('Change…')),
        ],
      ),
    );
  }

  List<Widget> _rejectedList() => [
    Text(
      'Left out (${_rejected.length}):',
      style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold),
    ),
    for (final (name, reason) in _rejected)
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('$name: $reason', style: const TextStyle(fontSize: 12.5, color: Colors.white70)),
      ),
  ];

  List<Widget> _finished() {
    final name = _result!.path.split('/').last;
    return [
      const Icon(Icons.check_circle_outline, size: 48, color: Colors.lightGreen),
      const SizedBox(height: 8),
      Text(
        '${_clips.length} ${_clips.length == 1 ? 'clip' : 'clips'} imported as session "$name".',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: () => Navigator.of(context).pop(_result!.path),
        icon: const Icon(Icons.auto_awesome_outlined),
        label: const Text('Find animals in these videos'),
      ),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
    ];
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _timeOnly(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
  }

  static String _dateTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.year}-${_two(t.month)}-${_two(t.day)} ${_timeOnly(ms)}';
  }

  /// "42 s", "3 min 07 s", "1 h 05 min".
  static String _length(int ms) {
    final d = Duration(milliseconds: ms);
    if (d.inHours > 0) return '${d.inHours} h ${_two(d.inMinutes % 60)} min';
    if (d.inMinutes > 0) return '${d.inMinutes} min ${_two(d.inSeconds % 60)} s';
    return '${d.inSeconds} s';
  }
}

/// How "Set all clips…" sets the starts.
enum _SetAll { keepGaps, oneAfterAnother, sameStart }

class _SetAllDialog extends StatelessWidget {
  const _SetAllDialog();

  @override
  Widget build(BuildContext context) {
    void close([_SetAll? how]) => Navigator.of(context).pop(how);
    Widget option(_SetAll how, String title, String why) => ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(why),
      onTap: () => close(how),
    );
    return AlertDialog(
      title: DialogTitle(const Text('Set all clips'), onClose: close),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            option(
              _SetAll.keepGaps,
              'Keep the gaps between them',
              'You set the first clip; the others move by the same amount. For a camera whose clock was wrong.',
            ),
            option(
              _SetAll.oneAfterAnother,
              'One after the other',
              'You set the first clip; each next clip (in name order) starts when the one before ends. For '
                  'one recording saved as several files.',
            ),
            option(
              _SetAll.sameStart,
              'All at the same time',
              'Every clip starts at the time you set. For several cameras started together.',
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: close, child: const Text('Cancel'))],
    );
  }
}

/// Round 277 (owner): imported videos are copies, so the user learns before
/// importing that they take storage twice and how to get it back.
class _StorageNote extends StatelessWidget {
  const _StorageNote();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
    decoration: BoxDecoration(border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(8)),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(top: 1),
          child: Icon(Icons.sd_storage_outlined, size: 18, color: Colors.white70),
        ),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'The videos are copied into FaunaPulse, so they take storage twice: the originals stay '
            'in your Gallery or folder. Nothing leaves the phone. If storage runs short, you can '
            'delete the originals after the import; the session can copy its videos back to the '
            'Gallery later (open the session, Video tab, "Copy videos").',
            style: TextStyle(fontSize: 13, color: Colors.white70),
          ),
        ),
      ],
    ),
  );
}
