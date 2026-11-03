// FaunaPulse, live recording screen:
// which detector runs, and what happens when a model fails to load.
//
// A `part` of camera_session_screen.dart: that screen's State class is split into
// extensions, one file per part of the screen, so each file stays readable
// while the private fields stay shared (Dart privacy is per library, and a
// part file belongs to the main file's library). Fields, getters and the
// lifecycle overrides stay in the main file; part files hold methods only.
//
// The extensions below are the State's own code, so calling setState here is
// correct; the analyzer cannot tell an extension from outside code.
// ignore_for_file: invalid_use_of_protected_member

part of '../camera_session_screen.dart';

extension _CameraModelChoice on _CameraSessionScreenState {
  /// Checks the chosen model's file again (after Settings or the Download &
  /// import models screen, where it may have been deleted).
  void _recheckModelFile() {
    _cameraModelFor = null;
    if (mounted) setState(() {});
  }

  /// Live detection without a usable model (round 271, owner): none chosen
  /// yet, or the chosen file is gone. The user chooses; nothing is picked
  /// silently, and the phone's models are listed only here, not on every
  /// start. "Download & import models" opens that screen and asks again when
  /// a model was added.
  Future<void> _askForDetector() async {
    final listed = await ModelCatalog.build();
    if (!mounted) return;
    final chosen = _config.modelPath;
    final missing = chosen.isNotEmpty ? chosen.split('/').last : null;
    final String title;
    final String text;
    if (missing != null) {
      title = 'Detection model missing';
      text = listed.isEmpty
          ? '$missing is no longer on this phone. Live detection cannot run; time-lapse and '
                'motion capture still work.'
          : '$missing is no longer on this phone. Choose another one:';
    } else if (listed.isEmpty) {
      title = 'No detection model';
      text = 'Live detection needs a detection model, and none is on this phone. Time-lapse and '
          'motion capture need none.';
    } else {
      title = 'Choose a detection model';
      text = 'Live detection needs one. Choose the model that finds the animals you watch:';
    }
    final answer = await showDialog<Object>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(Text(title), onClose: () => Navigator.of(ctx).pop()),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text),
              for (final m in listed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.center_focus_strong_outlined),
                  // The file name, as on Download & import models (round 275).
                  title: Text(m.name),
                  // What it finds helps to choose among the user's own files.
                  subtitle: _detectorSubtitle(m),
                  onTap: () => Navigator.of(ctx).pop(m),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('get'),
            child: const Text('Download & import models'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (answer is ModelEntry) {
      _useDetector(answer);
      return;
    }
    if (answer != 'get') return;
    await _controller.pause();
    _paused = true;
    if (!mounted) return;
    await openModelsScreen(context);
    if (!mounted) return;
    if (_paused) {
      _paused = false;
      await _controller.resume();
    }
    _recheckModelFile();
    // Ask again only when a model can now be chosen (no endless loop).
    if (_cameraModelPath.isEmpty && (await ModelCatalog.build()).isNotEmpty && mounted) {
      await _askForDetector();
    }
  }

  /// Makes [m] the camera's detection model and saves it.
  void _useDetector(ModelEntry m) {
    final updated = _config.copyWith(
      modelPath: m.id,
      task: YOLOTaskParsing.tryParse(m.task) ?? _config.task,
    );
    setState(() {
      _config = updated;
      _modelInputSize = null;
      _modelInputProbed = false;
    });
    updated.save().catchError((Object e) => logSwallowed('detector_choice_save', e));
    _refreshModelInputSize();
  }

  /// Reads the configured model's square input resolution from its metadata (via
  /// the shared [ModelCatalog.inputSizeOf]) and updates the overlay. Marks the
  /// value as "probed" either way, so the chip can show a clear "cannot read"
  /// when the metadata doesn't carry it instead of leaving the line blank.
  Future<void> _refreshModelInputSize() async {
    final path = _cameraModelPath;
    final size = path.isEmpty ? null : await ModelCatalog.inputSizeOf(path);
    if (!mounted) return;
    if (size != _modelInputSize || !_modelInputProbed) {
      setState(() {
        _modelInputSize = size;
        _modelInputProbed = true;
      });
    }
  }

  /// A model failed to load (round 151). Two shapes reach this handler:
  /// an in-place switch failure (the previous model keeps running natively,
  /// so the config must revert to it or the UI lies about what is detecting),
  /// and an initial-load failure (nothing is running; without recovery the
  /// detector never emits an analysis frame, so the calibration cycle would
  /// show "Calibrating…" forever). Both revert the config to a model that can
  /// actually run, persist it, and tell the user why.
  void _onModelLoadError(Object error, String failedPath, YOLOTask? task) {
    final reason = error is PlatformException
        ? (error.message ?? error.code)
        : '$error';
    // Reaches logcat_end.txt and, when a session is live, an app_error line.
    logSwallowed('model_load_error', '$failedPath: $reason');
    // Settings are locked while recording, so this should be unreachable then;
    // the guard keeps a late event from rebuilding config mid-log regardless.
    if (!mounted || _recording) return;
    final recovery = modelLoadRecovery(
      failedPath: failedPath,
      currentConfigPath: _config.modelPath,
      loadedModelPath: _loadedModelPath,
    );
    if (recovery == null) return; // stale: another model was picked meanwhile
    final updated = _config.copyWith(
      modelPath: recovery.revertToPath,
      task: _loadedModelTask ?? _config.task,
    );
    setState(() {
      _config = updated;
      // Show "reading…" while the reverted model's input size is re-probed.
      _modelInputSize = null;
      _modelInputProbed = false;
      if (recovery.revertToPath.isEmpty) {
        // Nothing runs natively (round 270): forget the failed model, or a
        // later failure would "revert" to it.
        _loadedModel = '';
        _loadedModelPath = '';
        _loadedModelTask = null;
      }
    });
    updated.save().catchError(
      (Object e) => logSwallowed('model_error_save', e),
    );
    _refreshModelInputSize();
    _showModelErrorDialog(failedPath, reason, recovery);
  }

  Future<void> _showModelErrorDialog(
    String failedPath,
    String reason,
    ModelLoadRecovery recovery,
  ) async {
    if (_modelErrorDialogOpen) return;
    _modelErrorDialogOpen = true;
    final failedName = failedPath.split('/').last;
    final after = recovery.revertToPath.isEmpty
        ? 'The camera runs without a detection model now. Choose another one in '
              'Settings (Detection tab).'
        : 'Switched back to ${recovery.revertToPath.split('/').last}.';
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: DialogTitle(const Text('Model failed to load'), onClose: () => Navigator.of(ctx).pop()),
          // Round 319: no raw error text (LiteRtException ...); it is in the
          // error log (model_load_error).
          content: Text(
            '$failedName could not be loaded.\n\n'
            '${modelLoadAdvice(failedPath, reason)}\n\n'
            '$after',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } finally {
      _modelErrorDialogOpen = false;
    }
  }
}
