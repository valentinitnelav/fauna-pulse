// FaunaPulse (round 208): "Identify organisms" for one session.
//
// Pre-flight (model + label pack, crop count, time estimate, settings),
// then the run with progress, then a completion card that leads to the
// results screen. The heavy lifting lives in identification/*; this screen
// only wires the native embedder (ImageEmbedder) into the job, keeps the
// screen awake and shows progress. Long runs are meant for a plugged-in
// phone indoors (plan section 11.12).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../identification/identification_assets.dart';
import '../identification/identification_job.dart';
import '../identification/identification_store.dart';
import '../identification/label_pack.dart';
import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';
import '../logging/device_thermal.dart';
import '../widgets/numeric_setting_field.dart';
import '../widgets/setting_help.dart';
import 'identification_results_screen.dart';

class IdentificationScreen extends StatefulWidget {
  final Directory sessionDir;
  const IdentificationScreen({super.key, required this.sessionDir});

  @override
  State<IdentificationScreen> createState() => _IdentificationScreenState();
}

class _IdentificationScreenState extends State<IdentificationScreen> {
  IdentifyPrefs? _prefs;
  List<File> _models = const [];
  List<File> _packs = const [];
  File? _model;
  File? _pack;
  Map<String, dynamic>? _packHeader;
  int? _plannedCrops;
  int? _plannedTracks;
  double? _msPerCrop;
  List<File> _summaries = const [];
  ThermalReading? _thermal;

  bool _running = false;
  bool _loadingModel = false;
  bool _cancel = false;
  IdentifyProgress? _progress;
  IdentifyResult? _result;
  String? _error;
  DateTime? _runStarted;
  Timer? _ticker;
  String _accelerator = '';

  String get _sessionName => widget.sessionDir.path.split('/').last;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await IdentifyPrefs.load();
    final models = await IdentificationAssets.listModels();
    final packs = await IdentificationAssets.listPacks();
    File? pick(List<File> files, String? name) {
      if (files.isEmpty) return null;
      for (final f in files) {
        if (name != null && f.path.endsWith('/$name')) return f;
      }
      return files.first;
    }
    final model = pick(models, prefs.modelName);
    final pack = pick(packs, prefs.packName);
    Map<String, dynamic>? header;
    if (pack != null) {
      try {
        header = await LabelPack.readHeader(pack);
      } catch (e) {
        logSwallowed('identify_pack_header', e);
      }
    }
    ThermalReading? thermal;
    try {
      thermal = await DeviceThermal.read();
    } catch (e) {
      logSwallowed('identify_thermal_probe', e);
    }
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _models = models;
      _packs = packs;
      _model = model;
      _pack = pack;
      _packHeader = header;
      _thermal = thermal;
      _summaries = IdentificationPaths(widget.sessionDir).existingSummaries();
    });
    await _plan();
    await _loadSpeed();
  }

  Future<void> _plan() async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      final tasks = await IdentificationJob.planSession(
        widget.sessionDir,
        maxCropsPerTrack: prefs.maxCropsPerTrack,
      );
      final tracks = <int>{for (final t in tasks) if (t.trackId != null) t.trackId!};
      if (!mounted) return;
      setState(() {
        _plannedCrops = tasks.length;
        _plannedTracks = tracks.length;
      });
    } catch (e) {
      logSwallowed('identify_plan', e);
      if (mounted) setState(() => _plannedCrops = 0);
    }
  }

  Future<void> _loadSpeed() async {
    final m = _model;
    if (m == null) return;
    final prefs = await IdentifyPrefs.load();
    final name = m.path.split('/').last;
    // Stored by the last run of this model on this phone.
    final sp = await SharedPreferences.getInstance();
    final v = sp.getDouble(IdentifyPrefs.msPerCropKey(name));
    if (!mounted) return;
    setState(() {
      _msPerCrop = v;
      _prefs ??= prefs;
    });
  }

  Future<void> _selectPack(File? f) async {
    Map<String, dynamic>? header;
    if (f != null) {
      try {
        header = await LabelPack.readHeader(f);
      } catch (e) {
        logSwallowed('identify_pack_header', e);
        if (mounted) _snack('Could not read this label pack: ${plainError(e)}');
      }
    }
    if (!mounted) return;
    setState(() {
      _pack = f;
      _packHeader = header;
    });
  }

  Future<void> _import({required bool packs}) async {
    final outcome = await IdentificationAssets.importFiles(packs: packs);
    if (!mounted) return;
    final msg = StringBuffer();
    if (outcome.imported.isNotEmpty) {
      msg.write('Imported ${outcome.imported.join(', ')}.');
    }
    if (outcome.rejected.isNotEmpty) {
      msg.write(' Rejected: ${outcome.rejected.join(' ')}');
    }
    if (msg.isNotEmpty) _snack(msg.toString());
    final models = await IdentificationAssets.listModels();
    final packsList = await IdentificationAssets.listPacks();
    if (!mounted) return;
    setState(() {
      _models = models;
      _packs = packsList;
      if (packs && outcome.imported.isNotEmpty) {
        _pack = packsList.firstWhere((f) => f.path.endsWith('/${outcome.imported.last}'), orElse: () => _pack ?? packsList.first);
      }
      if (!packs && outcome.imported.isNotEmpty) {
        _model = models.firstWhere((f) => f.path.endsWith('/${outcome.imported.last}'), orElse: () => _model ?? models.first);
      }
    });
    if (packs) await _selectPack(_pack);
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _savePrefs() async {
    final p = _prefs;
    if (p == null) return;
    p.modelName = _model?.path.split('/').last;
    p.packName = _pack?.path.split('/').last;
    await p.save();
  }

  Future<void> _start() async {
    final model = _model, pack = _pack, prefs = _prefs;
    if (model == null || pack == null || prefs == null) return;
    await _savePrefs();
    setState(() {
      _running = true;
      _loadingModel = true;
      _cancel = false;
      _error = null;
      _result = null;
      _progress = null;
      _runStarted = DateTime.now();
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    await WakelockPlus.enable();
    final modelName = model.path.split('/').last;
    IdentifyResult? result;
    try {
      final info = await ImageEmbedder.load(
        model.path,
        useGpu: prefs.useGpu,
        cpuThreads: prefs.cpuThreads,
      );
      if (!mounted) return;
      setState(() {
        _loadingModel = false;
        _accelerator = info.accelerator;
      });
      final pinfo = await PackageInfo.fromPlatform();
      final job = IdentificationJob(
        embed: (List<Uint8List> rgb) async {
          final b = await ImageEmbedder.embed(rgb);
          return [for (var i = 0; i < b.count; i++) Float32List.fromList(b.vector(i))];
        },
      );
      result = await job.run(
        widget.sessionDir,
        settings: IdentifyRunSettings(
          modelName: modelName,
          modelId: stemOf(modelName),
          packName: pack.path.split('/').last,
          inputSize: info.inputWidth,
          dim: info.dim,
          accelerator: info.accelerator,
          margin: prefs.margin,
          minCropPx: prefs.minCropPx,
          maxCropsPerTrack: prefs.maxCropsPerTrack,
          tau: prefs.tau,
          noneThreshold: prefs.noneThreshold,
          thermalLimitC: prefs.thermalLimitC,
          targetRank: prefs.targetRank,
          extra: {'use_gpu': prefs.useGpu, 'cpu_threads': prefs.cpuThreads},
        ),
        packFile: pack,
        appVersion: '${pinfo.version}+${pinfo.buildNumber}',
        isCancelled: () => _cancel,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (result.embedded > 0) {
        final sp = await SharedPreferences.getInstance();
        final wallMs = result.elapsed.inMilliseconds / result.embedded;
        await sp.setDouble(IdentifyPrefs.msPerCropKey(modelName), wallMs);
        _msPerCrop = wallMs;
      }
    } catch (e) {
      logSwallowed('identify_start', e);
      _error = plainError(e);
    } finally {
      try {
        await ImageEmbedder.close();
      } catch (e) {
        logSwallowed('identify_close', e);
      }
      await WakelockPlus.disable();
      _ticker?.cancel();
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _loadingModel = false;
      _result = result;
      _summaries = IdentificationPaths(widget.sessionDir).existingSummaries();
    });
  }

  /// Scores the stored embeddings again with the selected pack (no model run).
  Future<void> _rescore() async {
    final model = _model, pack = _pack, prefs = _prefs;
    if (model == null || pack == null || prefs == null) return;
    await _savePrefs();
    setState(() {
      _running = true;
      _error = null;
      _result = null;
      _progress = const IdentifyProgress(stage: 'scoring', done: 0, total: 0, avgMs: 0);
    });
    try {
      final pinfo = await PackageInfo.fromPlatform();
      final modelName = model.path.split('/').last;
      final summary = await IdentificationJob.scoreSession(
        widget.sessionDir,
        modelName: modelName,
        modelId: stemOf(modelName),
        packFile: pack,
        settings: {
          ...prefs.toJson(),
          'model': modelName,
          'pack': pack.path.split('/').last,
        },
        appVersion: '${pinfo.version}+${pinfo.buildNumber}',
      );
      _result = IdentifyResult(
        planned: 0,
        embedded: 0,
        skipped: 0,
        failed: 0,
        resumedDone: 0,
        thermalPauses: 0,
        elapsed: Duration.zero,
        cancelled: false,
        summary: summary,
      );
    } catch (e) {
      logSwallowed('identify_rescore', e);
      _error = plainError(e);
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _summaries = IdentificationPaths(widget.sessionDir).existingSummaries();
    });
  }

  bool get _hasEmbeddings {
    final m = _model;
    if (m == null) return false;
    return IdentificationPaths(widget.sessionDir)
        .embeddingsJsonl(stemOf(m.path.split('/').last))
        .existsSync();
  }

  String _fmtDuration(Duration d) {
    if (d.inHours > 0) return '${d.inHours} h ${d.inMinutes % 60} min';
    if (d.inMinutes > 0) return '${d.inMinutes} min ${d.inSeconds % 60} s';
    return '${d.inSeconds} s';
  }

  void _openResults([File? summary]) {
    final s = summary ?? (_summaries.isNotEmpty ? _summaries.first : null);
    if (s == null) return;
    final name = s.path.split('/').last; // summary_<pack>.json
    final packStem = name.substring('summary_'.length, name.length - '.json'.length);
    final paths = IdentificationPaths(widget.sessionDir);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => IdentificationResultsScreen(
          sessionDir: widget.sessionDir,
          tracksJson: paths.tracksJson(packStem),
          summaryJson: s,
          tracksCsv: paths.tracksCsv(packStem),
        ),
      ),
    );
  }

  Future<void> _shareCsv() async {
    final s = _summaries.isNotEmpty ? _summaries.first : null;
    if (s == null) return;
    final name = s.path.split('/').last;
    final packStem = name.substring('summary_'.length, name.length - '.json'.length);
    final csv = IdentificationPaths(widget.sessionDir).tracksCsv(packStem);
    if (!csv.existsSync()) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(csv.path)]));
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;
    return Scaffold(
      appBar: AppBar(title: Text('Identify organisms — $_sessionName')),
      body: prefs == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_running) ..._progressSection() else ...[
                  ..._filesSection(prefs),
                  const Divider(height: 32, color: Colors.white24),
                  ..._preflightSection(prefs),
                  if (_result != null || _error != null) ...[
                    const Divider(height: 32, color: Colors.white24),
                    ..._completionSection(),
                  ],
                  const Divider(height: 32, color: Colors.white24),
                  _advancedSection(prefs),
                ],
              ],
            ),
    );
  }

  List<Widget> _filesSection(IdentifyPrefs prefs) {
    String label(File f) =>
        '${f.path.split('/').last} (${formatBytes(f.lengthSync())})';
    return [
      const HelpLabel(
        label: 'Model and label pack',
        labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        helperText:
            'Two files made on a PC with tool/bioclip_export (see docs/IDENTIFICATION.md). '
            'The MODEL is the BioCLIP image tower (0.3 to 1.3 GB, downloaded once, it turns a '
            'crop into numbers). The LABEL PACK holds the names the model may choose from '
            '(a few MB for some orders, up to ~0.6 GB for all insects and spiders) plus their '
            'taxonomy and a few "none of these" entries. Import copies them into the app\'s '
            'private storage; the originals can then be deleted.',
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        initialValue: _model?.path,
        decoration: const InputDecoration(labelText: 'Model (.tflite)'),
        items: [for (final f in _models) DropdownMenuItem(value: f.path, child: Text(label(f), overflow: TextOverflow.ellipsis))],
        onChanged: (p) {
          setState(() => _model = _models.firstWhere((f) => f.path == p));
          _loadSpeed();
        },
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        initialValue: _pack?.path,
        decoration: const InputDecoration(labelText: 'Label pack (.fpack)'),
        items: [for (final f in _packs) DropdownMenuItem(value: f.path, child: Text(label(f), overflow: TextOverflow.ellipsis))],
        onChanged: (p) => _selectPack(_packs.firstWhere((f) => f.path == p)),
      ),
      if (_packHeader != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Pack ${_packHeader!['pack_id']} for ${_packHeader!['model_id']}: '
            '${_packHeader!['rows']} names, ${_packHeader!['sink_rows']} "none" entries, '
            'scale ${(_packHeader!['logit_scale'] as num?)?.toStringAsFixed(1)}',
            style: helperTextStyle,
          ),
        ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: () => _import(packs: false),
            icon: const Icon(Icons.file_download_outlined),
            label: const Text('Import model…'),
          ),
          OutlinedButton.icon(
            onPressed: () => _import(packs: true),
            icon: const Icon(Icons.file_download_outlined),
            label: const Text('Import label pack…'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _preflightSection(IdentifyPrefs prefs) {
    final crops = _plannedCrops;
    final estimate = (crops != null && _msPerCrop != null)
        ? Duration(milliseconds: (crops * _msPerCrop!).round())
        : null;
    final plugged = _thermal?.isPlugged == true || _thermal?.isCharging == true;
    final ready = _model != null && _pack != null && (crops ?? 0) > 0;
    return [
      const HelpLabel(
        label: 'Run',
        labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        helperText:
            'Every saved photo of every tracked insect is cut to a square crop and run through '
            'the model; the crops of one track id are then combined into one identification '
            'with a confidence per taxonomic rank. Nothing is uploaded. The run can take from '
            'minutes to hours; it can be cancelled and resumed at any time, and it pauses by '
            'itself while the phone is warm. Plug the phone in for long runs.',
      ),
      const SizedBox(height: 6),
      Text(
        crops == null
            ? 'Counting crops…'
            : '$crops crops from ${_plannedTracks ?? 0} tracked visits'
                  '${estimate == null ? '' : ' — about ${_fmtDuration(estimate)} on this phone'}',
        style: const TextStyle(color: Colors.white),
      ),
      if (crops == 0)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            'No crops to identify: this session has no photos with tracked insects '
            '(no-AI sessions need "Run AI on photos" first).',
            style: helperTextStyle,
          ),
        ),
      if (!plugged)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('The phone is not plugged in.', style: TextStyle(color: Colors.amber, fontSize: 12)),
        ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: ready ? _start : null,
            icon: const Icon(Icons.biotech),
            label: Text(_hasEmbeddings ? 'Continue / re-run' : 'Start'),
          ),
          if (_hasEmbeddings && _pack != null)
            OutlinedButton.icon(
              onPressed: _rescore,
              icon: const Icon(Icons.refresh),
              label: const Text('Re-score with this pack'),
            ),
          if (_summaries.isNotEmpty)
            OutlinedButton.icon(
              onPressed: () => _openResults(),
              icon: const Icon(Icons.table_rows_outlined),
              label: const Text('View results'),
            ),
        ],
      ),
    ];
  }

  List<Widget> _progressSection() {
    final p = _progress;
    final elapsed = _runStarted == null ? Duration.zero : DateTime.now().difference(_runStarted!);
    final total = p?.total ?? 0;
    final done = p?.done ?? 0;
    Duration? remaining;
    if (p != null && done > 0 && total > done && p.stage != 'scoring') {
      remaining = Duration(milliseconds: (elapsed.inMilliseconds / done * (total - done)).round());
    }
    final stageText = _loadingModel
        ? 'Loading the model (the first time can take a minute)…'
        : switch (p?.stage) {
            'planning' => 'Planning crops…',
            'embedding' => 'Identifying crops on the $_accelerator…',
            'paused' => 'Paused: ${p!.note}',
            'scoring' => 'Combining crops per visit and writing results…',
            'done' => 'Finishing…',
            _ => 'Starting…',
          };
    return [
      Text(stageText, style: const TextStyle(color: Colors.white, fontSize: 16)),
      const SizedBox(height: 12),
      LinearProgressIndicator(
        value: (p == null || total == 0 || p.stage == 'scoring' || _loadingModel) ? null : done / total,
      ),
      const SizedBox(height: 8),
      if (p != null && total > 0)
        Text('$done of $total crops', style: const TextStyle(color: Colors.white)),
      Text('Elapsed ${_fmtDuration(elapsed)}'
          '${remaining == null ? '' : ' — about ${_fmtDuration(remaining)} left'}'
          '${p != null && p.avgMs > 0 ? ' — ${(p.avgMs / 1000).toStringAsFixed(1)} s per crop' : ''}',
          style: helperTextStyle),
      if (p?.tempC != null)
        Text('Battery ${p!.tempC!.toStringAsFixed(1)} °C', style: helperTextStyle),
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _cancel ? null : () => setState(() => _cancel = true),
          icon: const Icon(Icons.stop_circle_outlined),
          label: Text(_cancel ? 'Stopping after this photo…' : 'Cancel (keeps what is done)'),
        ),
      ),
    ];
  }

  List<Widget> _completionSection() {
    final r = _result;
    final s = r?.summary;
    return [
      const Text('Last run', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
      const SizedBox(height: 6),
      if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
      if (r != null) ...[
        if (r.cancelled) const Text('Cancelled — progress is kept; Continue resumes.', style: TextStyle(color: Colors.amber)),
        Text(
          '${r.embedded} crops identified now (${r.resumedDone} done earlier, ${r.skipped} skipped, '
          '${r.failed} failed, ${r.thermalPauses} heat pauses) in ${_fmtDuration(r.elapsed)}.',
          style: const TextStyle(color: Colors.white),
        ),
        if (s != null) ...[
          const SizedBox(height: 6),
          Text(
            '${s['tracks_total']} visits: '
            '${(s['by_identified_rank'] as Map).entries.map((e) => '${e.value} to ${e.key}').join(', ')}'
            '${s['unidentified'] != 0 ? ', ${s['unidentified']} unidentified' : ''}'
            '${s['none'] != 0 ? ', ${s['none']} no organism' : ''}.',
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => _openResults(),
                icon: const Icon(Icons.table_rows_outlined),
                label: const Text('View results'),
              ),
              OutlinedButton.icon(
                onPressed: _shareCsv,
                icon: const Icon(Icons.share_outlined),
                label: const Text('Share CSV'),
              ),
            ],
          ),
        ],
      ],
    ];
  }

  Widget _advancedSection(IdentifyPrefs prefs) {
    return ExpansionTile(
      title: const Text('Advanced settings', style: TextStyle(color: Colors.white)),
      childrenPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: [
        HelpSwitchTile(
          title: 'Use the GPU when it can run the model',
          value: prefs.useGpu,
          onChanged: (v) => setState(() => prefs.useGpu = v),
          helperText:
              'GPU is usually faster for the fp16 model; the app falls back to the CPU when the '
              'GPU cannot compile it. Turn off to force the CPU (int8 models, or to compare).',
        ),
        NumericSettingField(
          label: 'CPU threads (0 = automatic)',
          value: prefs.cpuThreads.toDouble(),
          min: 0,
          max: 8,
          isInt: true,
          onChanged: (v) => prefs.cpuThreads = v.round(),
          helperText: 'Fewer threads run cooler and slower.',
        ),
        NumericSettingField(
          label: 'Crop margin',
          value: prefs.margin,
          min: 0,
          max: 0.5,
          decimals: 2,
          onChanged: (v) => prefs.margin = v,
          helperText:
              'Extra border around the detector box before the square crop (0.15 = 15 % per side), '
              'so legs, wings and antennae are not cut off.',
        ),
        NumericSettingField(
          label: 'Smallest box to identify',
          value: prefs.minCropPx.toDouble(),
          min: 16,
          max: 512,
          isInt: true,
          unitSuffix: 'px',
          onChanged: (v) {
            prefs.minCropPx = v.round();
            _plan();
          },
          helperText: 'Boxes smaller than this (longer side, in photo pixels) are skipped as too small.',
        ),
        NumericSettingField(
          label: 'Crops per visit (0 = all)',
          value: prefs.maxCropsPerTrack.toDouble(),
          min: 0,
          max: 100,
          isInt: true,
          onChanged: (v) {
            prefs.maxCropsPerTrack = v.round();
            _plan();
          },
          helperText: 'Keeps the largest boxes of each track id when a visit has more photos than this.',
        ),
        NumericSettingField(
          label: 'Confidence needed to call a rank identified',
          value: prefs.tau,
          min: 0.5,
          max: 0.99,
          decimals: 2,
          onChanged: (v) => prefs.tau = v,
          helperText:
              'The deepest rank (order, family, genus, species) whose probability mass reaches '
              'this value is reported as the identification. The full ladder is always shown.',
        ),
        NumericSettingField(
          label: '"No organism" threshold',
          value: prefs.noneThreshold,
          min: 0.1,
          max: 0.9,
          decimals: 2,
          onChanged: (v) => prefs.noneThreshold = v,
          helperText: 'Mass on the "none of these" entries (flower, leaf, shadow, …) above which a track is reported as no organism.',
        ),
        NumericSettingField(
          label: 'Pause above battery temperature',
          value: prefs.thermalLimitC,
          min: 35,
          max: 45,
          decimals: 0,
          unitSuffix: '°C',
          onChanged: (v) => prefs.thermalLimitC = v,
          helperText: 'The run pauses when the battery reaches this and resumes 3 °C lower.',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: DropdownButtonFormField<String>(
            initialValue: prefs.targetRank,
            decoration: const InputDecoration(labelText: 'Rank for the CSV "pred" columns'),
            items: [for (final r in kRankNames.skip(3)) DropdownMenuItem(value: r, child: Text(r))],
            onChanged: (v) {
              if (v != null) setState(() => prefs.targetRank = v);
            },
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: () async {
            await _savePrefs();
            if (mounted) _snack('Settings saved');
          }, child: const Text('Save settings')),
        ),
      ],
    );
  }
}

/// Plain-language error text (strips the "Exception: " prefix).
String plainError(Object e) => '$e'.replaceFirst('Exception: ', '').replaceFirst('PlatformException', 'Error');
