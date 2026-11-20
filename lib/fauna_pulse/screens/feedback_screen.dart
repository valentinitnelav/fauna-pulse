// FaunaPulse: the "Send feedback" screen (Home menu, the Support box on Home, and the camera's
// "Problem detected" window).
//
// Testers are volunteers with little time, all over the world, and most have no GitHub
// account. So feedback is free text in any language plus screenshots if they like, with no
// form, and the app adds the technical details itself (ErrorReporter.build). "Send by email"
// opens the phone's own email app with the address, subject, text and one zip already filled
// in, so the tester only presses Send; on a phone where Android finds no email app, the share
// window opens instead. "Share another way" opens Android's share window (for example to a
// colleague in a messaging app, who forwards it).
//
// The report is built on each tap, so it holds what the screen shows at that moment.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../logging/app_error_hooks.dart';
import '../logging/error_reporter.dart';
import '../logging/report_bundle.dart' show kFeedbackShotMaxSide, kFeedbackShotQuality;
import '../models/session_config.dart';
import '../widgets/home_button.dart';

/// One pickable session for the "Include session data" dropdown.
typedef ReportSessionOption = ({String name, String logPath});

/// Opens the feedback screen. [trigger] is written into the report (where it was opened, or
/// the error text). [sessions] fills the "Include session data" dropdown (newest first, the
/// first one preselected: most feedback is about the last session). [sessionLog] is a fixed
/// session instead, with no dropdown (the camera's error window). [config] is the settings in
/// effect; null = the saved ones.
Future<void> showFeedbackScreen(
  BuildContext context, {
  required String trigger,
  List<ReportSessionOption> sessions = const [],
  File? sessionLog,
  SessionConfig? config,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => FeedbackScreen(trigger: trigger, sessions: sessions, sessionLog: sessionLog, config: config),
    ),
  );
}

class FeedbackScreen extends StatefulWidget {
  final String trigger;
  final List<ReportSessionOption> sessions;
  final File? sessionLog;
  final SessionConfig? config;

  const FeedbackScreen({
    super.key,
    this.trigger = 'Send feedback',
    this.sessions = const [],
    this.sessionLog,
    this.config,
  });

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final TextEditingController _controller = TextEditingController();

  // Screenshots, picked with the system photo picker (no storage permission needed), which
  // hands back temp-cache copies; ErrorReporter.build copies them into the report.
  final List<XFile> _shots = [];
  bool _picking = false;

  // The session whose data goes into the report: the newest is preselected (the common
  // case), but the choice is the user's (the feedback may be about no session at all).
  String? _sessionLogPath;

  // The typed text is kept as a draft ([ErrorReporter.loadDraft] says why): saved a moment
  // after the last keystroke and when the screen closes, and put back when it opens again.
  Timer? _draftTimer;

  /// The text in the box came back from the draft: a line under the box says so.
  bool _draftRestored = false;

  /// The feedback went to another app, which cleared the draft: closing must not store the
  /// text again.
  bool _handedOver = false;

  /// The report is being built: the buttons wait, and Back too.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.sessions.isNotEmpty) {
      _sessionLogPath = widget.sessions.first.logPath;
    }
    ErrorReporter.loadDraft().then((draft) {
      // Never over text the user typed while the draft was read.
      if (!mounted || draft.isEmpty || _controller.text.isNotEmpty) return;
      setState(() {
        _controller.text = draft;
        _draftRestored = true;
      });
    });
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    if (!_handedOver) unawaited(ErrorReporter.saveDraft(_controller.text));
    _controller.dispose();
    super.dispose();
  }

  /// Some text, or a screenshot alone: a screenshot can say enough.
  bool get _canSend => !_busy && (_controller.text.trim().isNotEmpty || _shots.isNotEmpty);

  void _onTextChanged() {
    _draftTimer?.cancel();
    final text = _controller.text;
    _draftTimer = Timer(const Duration(milliseconds: 800), () => ErrorReporter.saveDraft(text));
    // Rebuild so the send buttons enable/disable as the user types.
    setState(() {});
  }

  void _clearText() {
    _draftTimer?.cancel();
    unawaited(ErrorReporter.saveDraft(''));
    setState(() {
      _controller.clear();
      _draftRestored = false;
    });
  }

  Future<void> _pickScreenshots() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      // The picker scales each picture to fit the box, so the report gets small files (it then
      // saves each one again as a JPEG without its hidden data, feedbackScreenshotJpeg).
      final picked = await ImagePicker().pickMultiImage(
        maxWidth: kFeedbackShotMaxSide.toDouble(),
        maxHeight: kFeedbackShotMaxSide.toDouble(),
        imageQuality: kFeedbackShotQuality,
      );
      if (!mounted) return;
      setState(() {
        // Skip files already in the list (same temp path = same pick).
        final have = _shots.map((s) => s.path).toSet();
        _shots.addAll(picked.where((p) => !have.contains(p.path)));
      });
    } catch (e) {
      logSwallowed('report_pick_screenshots', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the photo picker.')),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _send({required bool byEmail}) async {
    if (!_canSend) return;
    // A save due a moment from now must not land after the draft is cleared.
    _draftTimer?.cancel();
    final text = _controller.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    ErrorReport? report;
    try {
      final picked = _sessionLogPath;
      report = await ErrorReporter.build(
        trigger: widget.trigger,
        userDescription: text,
        config: widget.config ?? await SessionConfig.load(),
        sessionLog: widget.sessionLog ?? (picked == null ? null : File(picked)),
        attachmentPaths: [for (final s in _shots) s.path],
      );
    } catch (e) {
      logSwallowed('feedback_build', e);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (report == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not prepare the feedback. Please try again.')));
      return;
    }
    var emailed = false;
    var handed = false;
    if (byEmail) emailed = handed = await ErrorReporter.email(report, text);
    // No email app found (owner's choice: no warning window): the share list opens at once,
    // and the text ends with the address.
    if (!handed) handed = await ErrorReporter.share(report, text, title: byEmail ? 'Pick your email app' : null);
    if (!handed) return; // nothing left the phone: stay, with the text and screenshots
    _handedOver = true;
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          emailed
              ? 'Thank you for the feedback. If the email is not sent yet, press Send in your email app.'
              : 'Thank you for the feedback.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const FitTitle('Send feedback'),
          actions: const [HomeButton()],
        ),
        // The page scrolls and the two buttons stay under it. As one fixed column with the
        // text box taking "the rest", the keyboard left the box one line high, and attached
        // screenshots pushed the rows below out of the screen. Now the box has a height of its
        // own and grows with the text.
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  children: [
                    const Text(
                      'Write anything: a problem, something confusing, an idea. Any language is fine.',
                      style: TextStyle(fontSize: 13, color: Colors.white70),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white24),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: _editor(),
                    ),
                    if (_draftRestored)
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'This is your text from last time: it was not sent.',
                              style: TextStyle(fontSize: 11, color: Colors.white70),
                            ),
                          ),
                          TextButton(onPressed: _clearText, child: const Text('Clear text')),
                        ],
                      ),
                    const SizedBox(height: 8),
                    // A Wrap: with a large system font the count moves under the button.
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _picking || _busy ? null : _pickScreenshots,
                          icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                          label: Text(_shots.isEmpty ? 'Add screenshots' : 'Add more screenshots'),
                        ),
                        if (_shots.isNotEmpty)
                          Text(
                            '${_shots.length} added',
                            style: const TextStyle(fontSize: 12, color: Colors.white54),
                          ),
                      ],
                    ),
                    // Small pictures, not file names (round 362): a gallery names its files
                    // "1000071322.jpg", which tells nobody whether the right ones were picked.
                    if (_shots.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [for (final s in _shots) _thumbnail(s)],
                        ),
                      ),
                    if (widget.sessions.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Flexible(
                            child: Text(
                              'Include session data: ',
                              style: TextStyle(fontSize: 13, color: Colors.white70),
                            ),
                          ),
                          Expanded(
                            child: DropdownButton<String?>(
                              value: _sessionLogPath,
                              isExpanded: true,
                              isDense: true,
                              items: [
                                const DropdownMenuItem<String?>(
                                  value: null,
                                  child: Text('No session data', style: TextStyle(fontSize: 13)),
                                ),
                                for (final s in widget.sessions)
                                  DropdownMenuItem<String?>(
                                    value: s.logPath,
                                    child: Text(
                                      s.name,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                              ],
                              onChanged: (v) => setState(() => _sessionLogPath = v),
                            ),
                          ),
                        ],
                      ),
                      const Text(
                        'Pick the session your feedback is about: its settings and parts of its '
                        'technical logs are added (without the position and the field notes you '
                        'typed). Choose "No session data" if it is about something else.',
                        style: TextStyle(fontSize: 11, color: Colors.white54),
                      ),
                    ],
                    const SizedBox(height: 12),
                    const Text(
                      'Send by email opens your own email app with everything filled in, to '
                      '${ErrorReporter.feedbackEmail}: you only press Send. FaunaPulse adds one zip '
                      'file with your screenshots and technical details (app version, phone model, '
                      "settings and the app's recent log; no position and no field notes).",
                      style: TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                  ],
                ),
              ),
              if (_busy) const LinearProgressIndicator(),
              // Outside the list, so both buttons stay in reach above the keyboard. The close
              // button is the X at the top left (the text stays as the draft).
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _canSend ? () => _send(byEmail: false) : null,
                        child: const Text('Share another way', textAlign: TextAlign.center),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _canSend ? () => _send(byEmail: true) : null,
                        child: const Text('Send by email', textAlign: TextAlign.center),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One attached screenshot, 72 px square, with a button to take it out again.
  Widget _thumbnail(XFile shot) {
    const side = 72.0;
    return Semantics(
      label: 'Screenshot ${shot.name}',
      child: SizedBox(
        width: side,
        height: side,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(
                File(shot.path),
                fit: BoxFit.cover,
                // Decoded at thumbnail size: a screenshot at full size is 10 MB or more of
                // memory each.
                cacheWidth: (side * MediaQuery.devicePixelRatioOf(context)).round(),
                // A file the app cannot draw is still attached: show its name.
                errorBuilder: (_, _, _) => Container(
                  color: Colors.white12,
                  padding: const EdgeInsets.all(4),
                  alignment: Alignment.bottomLeft,
                  child: Text(shot.name, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9)),
                ),
              ),
            ),
            Align(
              alignment: Alignment.topRight,
              child: IconButton(
                tooltip: 'Remove this screenshot',
                onPressed: _busy ? null : () => setState(() => _shots.remove(shot)),
                icon: const Icon(Icons.close, size: 16),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                style: IconButton.styleFrom(backgroundColor: Colors.black87, foregroundColor: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Lines the text box shows before it grows with the text: enough to read a few sentences
  /// back, and it still fits between the title bar and the keyboard on a small phone.
  static const _editorMinLines = 6;

  Widget _editor() {
    return TextField(
      controller: _controller,
      minLines: _editorMinLines,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textCapitalization: TextCapitalization.sentences,
      // Room the page keeps free under the line being typed when it scrolls that line into
      // view: about the box's first height, so a tap into the empty box brings the whole box
      // above the keyboard, not only its first line.
      scrollPadding: const EdgeInsets.fromLTRB(20, 20, 20, 150),
      onChanged: (_) => _onTextChanged(),
      decoration: const InputDecoration(
        border: InputBorder.none,
        isCollapsed: true,
        hintText: 'For example: the camera stopped after about 5 minutes.',
      ),
    );
  }
}
