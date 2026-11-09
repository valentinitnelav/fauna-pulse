// FaunaPulse — problem description editor.
//
// A full-screen editing window where the user describes, in their own words,
// what went wrong before a diagnostic report is created. The typed text is
// returned to the caller (or null if they back out) and embedded verbatim in
// the report.
//
// "Markdown" = a simple plain-text way to add formatting (for example **bold**,
// *italic*, or "- " bulleted lists). The user can type plain text or markdown;
// the Preview tab shows how the markdown will look. Whatever they type is saved
// as-is into the plain-text (.txt) report.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:image_picker/image_picker.dart';

import '../logging/app_error_hooks.dart';
import '../logging/error_reporter.dart';
import '../widgets/external_link.dart';
import '../widgets/home_button.dart';

/// One pickable session for the "Include session data" dropdown (round 191).
typedef ReportSessionOption = ({String name, String logPath});

/// What the editor returns: the user's words plus any screenshots they picked
/// (round 190) and the session whose data should ride along (round 191,
/// null = none). The screenshot paths point at the photo picker's temp
/// copies — the report builder must copy them somewhere durable before they
/// expire.
class ProblemDescriptionResult {
  final String description;
  final List<String> screenshotPaths;
  final String? sessionLogPath;
  const ProblemDescriptionResult({
    required this.description,
    this.screenshotPaths = const [],
    this.sessionLogPath,
  });
}

/// Opens the editor and returns the trimmed description (+ screenshots +
/// session choice), or null if cancelled. [sessions] fills the "Include
/// session data" dropdown (newest first; the first entry is preselected —
/// most reports ARE about the last session, but the user can switch to any
/// other or to "No session data"). An empty list hides the dropdown; the
/// caller then decides itself (the in-session flow always uses the live
/// session).
Future<ProblemDescriptionResult?> showProblemDescriptionEditor(
  BuildContext context, {
  List<ReportSessionOption> sessions = const [],
}) {
  return Navigator.of(context).push<ProblemDescriptionResult>(
    MaterialPageRoute<ProblemDescriptionResult>(
      fullscreenDialog: true,
      builder: (_) => ProblemDescriptionScreen(sessions: sessions),
    ),
  );
}

class ProblemDescriptionScreen extends StatefulWidget {
  final List<ReportSessionOption> sessions;
  const ProblemDescriptionScreen({super.key, this.sessions = const []});

  @override
  State<ProblemDescriptionScreen> createState() =>
      _ProblemDescriptionScreenState();
}

class _ProblemDescriptionScreenState extends State<ProblemDescriptionScreen> {
  final TextEditingController _controller = TextEditingController();
  // false = Edit tab, true = Preview tab.
  bool _previewing = false;

  // Screenshots the user attaches to the report (round 190, optional).
  // Picked via the system photo picker (no storage permission needed), which
  // hands back temp-cache copies — kept as paths and copied into the report
  // folder by ErrorReporter.build.
  final List<XFile> _shots = [];
  bool _picking = false;

  // The session whose data goes into the report (round 191): preselect the
  // newest — the common case — but the choice is the user's (they may be
  // reporting something unrelated to any session).
  String? _sessionLogPath;

  // The typed text is kept as a draft ([ErrorReporter.loadDraft] says why): saved a moment
  // after the last keystroke and when the screen closes, and put back when it opens again.
  // Sharing the report clears it.
  Timer? _draftTimer;

  /// The text in the box came back from the draft: a line under the box says so.
  bool _draftRestored = false;

  /// Continue was tapped: [_continue] stored the text, and closing must not store it again
  /// (a quick Share may have cleared the draft by then).
  bool _continued = false;

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
    if (!_continued) unawaited(ErrorReporter.saveDraft(_controller.text));
    _controller.dispose();
    super.dispose();
  }

  bool get _hasText => _controller.text.trim().isNotEmpty;

  void _onTextChanged() {
    _draftTimer?.cancel();
    final text = _controller.text;
    _draftTimer = Timer(const Duration(milliseconds: 800), () => ErrorReporter.saveDraft(text));
    // Rebuild so the Continue button enables/disables as the user types.
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
      final picked = await ImagePicker().pickMultiImage();
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

  Future<void> _continue() async {
    final text = _controller.text.trim();
    // Required (the button is disabled without text); a second tap while the draft is stored
    // does nothing.
    if (text.isEmpty || _continued) return;
    _draftTimer?.cancel();
    _continued = true;
    // The draft holds this text until the report is shared: if building the report fails,
    // or the user closes its window to correct something, the text is here again. Waited
    // for, so this write can never land after the clear that follows a Share.
    await ErrorReporter.saveDraft(_controller.text);
    if (!mounted) return;
    Navigator.of(context).pop(
      ProblemDescriptionResult(
        description: text,
        screenshotPaths: [for (final s in _shots) s.path],
        sessionLogPath: _sessionLogPath,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const FitTitle('Describe the problem'),
        actions: const [HomeButton()],
        // Closing without text returns null (the default pop result), which the
        // caller treats as "cancelled" and skips creating a report.
      ),
      // The page scrolls and the two buttons stay under it. As one fixed column with the text
      // box taking "the rest", the keyboard left the box one line high (nobody could read
      // what they typed), and attached screenshots pushed the rows below out of the screen
      // ("bottom overflowed"). Now the box has a height of its own and grows with the text.
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                children: [
                  // Round 190: the app runs its dark theme, so the helper texts
                  // on this screen use the white70/white54 palette every other
                  // screen uses — the original black54/black45 (and the r189
                  // GitHub line) were near-invisible dark-on-dark (owner report).
                  const Text(
                    'Please describe in your own words what went wrong (what you '
                    'were doing, what you expected, and what happened instead). This '
                    'is required and helps to find the cause.',
                    style: TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                  const SizedBox(height: 6),
                  // Round 189 (owner request): point at the public issue tracker
                  // as an alternative reporting channel, up front. Round 317: worded
                  // as a step after Continue, so an issue still gets the report's
                  // logs and settings instead of the user leaving without them.
                  InkWell(
                    onTap: () => openExternalLink(ErrorReporter.githubIssuesUrl, 'describe_open_issues'),
                    child: const Text.rich(
                      TextSpan(
                        style: TextStyle(fontSize: 12, color: Colors.white54),
                        children: [
                          TextSpan(
                            text: 'After Continue, you can share the report or '
                                'paste its text into a GitHub issue (issues are public, '
                                'so read the text first): ',
                          ),
                          TextSpan(
                            text: ErrorReporter.githubIssuesUrl,
                            style: TextStyle(color: Colors.lightBlueAccent),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Edit / Preview toggle.
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment<bool>(
                          value: false,
                          label: Text('Edit'),
                          icon: Icon(Icons.edit_outlined),
                        ),
                        ButtonSegment<bool>(
                          value: true,
                          label: Text('Preview'),
                          icon: Icon(Icons.visibility_outlined),
                        ),
                      ],
                      selected: {_previewing},
                      onSelectionChanged: (s) =>
                          setState(() => _previewing = s.first),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white24),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: _previewing ? _preview() : _editor(),
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
                  const Text(
                    'Plain text is fine. For formatting, you can write **bold**, '
                    '*italic*, or start a line with "- " for a list (see Preview).',
                    style: TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                  const SizedBox(height: 8),
                  // Screenshots (round 190, optional): picked here, copied into
                  // the report folder by ErrorReporter.build, and attached
                  // alongside the .txt when the report is shared.
                  // A Wrap: with a large system font the count moves under the button.
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _picking ? null : _pickScreenshots,
                        icon: const Icon(Icons.add_photo_alternate_outlined,
                            size: 18),
                        label: Text(
                          _shots.isEmpty
                              ? 'Attach screenshots…'
                              : 'Add more screenshots…',
                        ),
                      ),
                      if (_shots.isNotEmpty)
                        Text(
                          '${_shots.length} attached',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white54,
                          ),
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
                  // Which session's data rides along (round 191, owner request):
                  // the report used to silently sample the NEWEST session's log,
                  // but a problem may concern an older session or none at all —
                  // so the choice is visible and editable.
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
                                child: Text(
                                  'No session data',
                                  style: TextStyle(fontSize: 13),
                                ),
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
                      'Pick the session your problem is about: its settings and '
                      'parts of its technical logs are added to the report (without '
                      'the position and the field notes you typed). Choose "No '
                      'session data" if the problem is unrelated.',
                      style: TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                  ],
                ],
              ),
            ),
            // Outside the list, so Cancel and Continue stay in reach above the keyboard.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      // Disabled until some text is entered (description required).
                      onPressed: _hasText ? _continue : null,
                      child: const Text('Continue'),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
                onPressed: () => setState(() => _shots.remove(shot)),
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
        hintText: 'e.g. The detector froze after about 5 minutes...',
      ),
    );
  }

  Widget _preview() {
    if (!_hasText) {
      return const Text(
        'Nothing to preview yet.',
        style: TextStyle(color: Colors.white54),
      );
    }
    return MarkdownBody(data: _controller.text);
  }
}
