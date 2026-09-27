// FaunaPulse (round 227): the step between picking videos and analysing
// them, for clips filmed outside FaunaPulse (the phone's camera app, a
// collaborator, a published dataset).
//
// The home ⋮ menu picks the files; this screen shows what was picked and
// when each clip started (and how sure that is), lets the user fix the start
// and name the session, then moves the files into a new session folder
// (postprocess/video_import.dart). Detection runs later, on the "Run AI on
// videos" screen, which the finished import offers to open.

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
import '../postprocess/video_import.dart';
import '../postprocess/video_start_time.dart';
import '../widgets/setting_help.dart';

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

class _VideoImportScreenState extends State<VideoImportScreen> {
  bool _loading = true;
  List<ImportClip> _clips = const [];

  /// Files left out, with the reason in plain language.
  List<(String, String)> _rejected = const [];
  final _name = TextEditingController();
  Directory? _sessionsDir;
  int? _freeBytes;

  /// The user's correction of the start, applied to every clip.
  int _shiftMs = 0;

  bool _importing = false;
  int _done = 0;
  String? _error;
  Directory? _result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    // The picker leaves a copy of every picked file in the app's cache,
    // which can be gigabytes of video; clear it however the screen is left.
    _clearPickerCache();
    super.dispose();
  }

  Future<void> _clearPickerCache() async {
    if (widget.infoFn != null) return; // tests: no picker ran
    try {
      await FilePicker.platform.clearTemporaryFiles();
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
      );
      final problem = clip.problem;
      if (problem != null) {
        rejected.add((f.name, problem));
      } else {
        clips.add(clip);
      }
    }
    Directory? sessionsDir = widget.sessionsDir;
    if (sessionsDir == null) {
      final base = (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
      sessionsDir = Directory('${base.path}/sessions');
    }
    int? free;
    if (widget.sessionsDir == null) {
      free = (await DeviceStorage.read(path: sessionsDir.parent.path)).freeBytes;
    }
    if (!mounted) return;
    setState(() {
      _clips = clips;
      _rejected = rejected;
      _sessionsDir = sessionsDir;
      _freeBytes = free;
      if (clips.isNotEmpty) _name.text = defaultImportName(planImport(clips).first.startMs);
      _loading = false;
    });
  }

  List<ClipStart> get _plan => planImport(_clips, shiftMs: _shiftMs);

  /// Bytes needed on top of what the picker's copies already use.
  int get _neededBytes => _clips.map((c) => c.sizeBytes).fold(0, max) + kImportSpareBytes;

  bool get _enoughSpace => _freeBytes == null || _freeBytes! >= _neededBytes;

  Future<void> _changeStart() async {
    final plan = _plan;
    final current = DateTime.fromMillisecondsSinceEpoch(plan.first.startMs);
    final firstDate = DateTime(2000);
    final lastDate = DateTime.now().add(const Duration(days: 1));
    final date = await showDatePicker(
      context: context,
      // A wrong camera clock can put the guess outside the picker's range.
      initialDate: current.isAfter(lastDate) ? lastDate : (current.isBefore(firstDate) ? firstDate : current),
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: 'Day the first clip was filmed',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      helpText: 'Time the first clip started',
    );
    if (time == null) return;
    final picked = DateTime(date.year, date.month, date.day, time.hour, time.minute, current.second);
    setState(() => _shiftMs += picked.millisecondsSinceEpoch - plan.first.startMs);
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
        shiftMs: _shiftMs,
        startExtras: extras,
        onProgress: (done, total, name) {
          if (mounted) setState(() => _done = done);
        },
      );
      await _clearPickerCache();
      if (mounted) setState(() => _result = dir);
    } catch (e) {
      logSwallowed('video_import', e);
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_importing,
      child: Scaffold(
        appBar: AppBar(title: const Text('Import videos')),
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
    final first = plan.first;
    final firstWeak = first.guess.weak && _shiftMs == 0;
    final totalMs = plan.fold<int>(0, (s, c) => s + c.durationMs);
    final totalBytes = _clips.fold<int>(0, (s, c) => s + c.sizeBytes);
    return [
      const HelpLabel(
        label: 'Adds the videos as a new session. The AI runs on them afterwards, from "Run AI on videos".',
        labelStyle: TextStyle(color: Colors.white70, fontSize: 13),
        helperText:
            'The files are moved into the app\'s own folder for this session (the originals on '
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
      HelpLabel(
        label: 'Filming started: ${_dateTime(first.startMs)}',
        labelStyle: const TextStyle(color: Colors.white),
        helperText:
            'Visits are placed on the clock from this time, so graphs and exports show when '
            'insects came. The app reads it from the file name or from the time stored in the '
            'video; files sent through messengers often lose it.',
      ),
      const SizedBox(height: 4),
      Text(
        _shiftMs != 0 ? 'Set by you; every clip moves by the same amount.' : first.guess.note,
        style: TextStyle(fontSize: 12.5, color: firstWeak ? Colors.amber : Colors.white54),
      ),
      Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            onPressed: _importing ? null : _changeStart,
            icon: const Icon(Icons.edit_calendar, size: 18),
            label: const Text('Change…'),
          ),
          if (_shiftMs != 0)
            TextButton(
              onPressed: _importing ? null : () => setState(() => _shiftMs = 0),
              child: const Text('Use the file\'s time'),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        '${plan.length} ${plan.length == 1 ? 'clip' : 'clips'} · ${_length(totalMs)} · ${formatBytes(totalBytes)}',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      for (final c in plan) _clipRow(c),
      if (_rejected.isNotEmpty) ...[
        const SizedBox(height: 12),
        ..._rejectedList(),
      ],
      const SizedBox(height: 16),
      if (!_enoughSpace)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Not enough free storage: ${formatBytes(_freeBytes!)} free, about '
            '${formatBytes(_neededBytes)} needed while the files are moved. Free some space, then pick again.',
            style: const TextStyle(color: Colors.redAccent, fontSize: 12.5),
          ),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('Import failed: $_error', style: const TextStyle(color: Colors.redAccent, fontSize: 12.5)),
        ),
      if (_importing) ...[
        LinearProgressIndicator(value: _done / plan.length, minHeight: 6),
        const SizedBox(height: 8),
        Text('Moving clip ${min(_done + 1, plan.length)} of ${plan.length}…', textAlign: TextAlign.center),
      ] else
        FilledButton.icon(
          onPressed: _enoughSpace ? _import : null,
          icon: const Icon(Icons.download_done),
          label: Text('Import ${plan.length} ${plan.length == 1 ? 'clip' : 'clips'}'),
        ),
    ];
  }

  Widget _clipRow(ClipStart c) {
    final unsure = c.source == 'after_previous'
        ? ' (no time of its own: follows the clip before)'
        : c.guess.weak && _shiftMs == 0
        ? ' (time uncertain)'
        : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.movie_outlined, size: 18, color: Colors.white54),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.name, overflow: TextOverflow.ellipsis),
                Text(
                  '${_timeOnly(c.startMs)} · ${_length(c.durationMs)}$unsure',
                  style: TextStyle(fontSize: 12, color: unsure.isEmpty ? Colors.white54 : Colors.amber),
                ),
              ],
            ),
          ),
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
        label: const Text('Run AI on these videos'),
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
