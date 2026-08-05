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

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../logging/app_error_hooks.dart';
import '../logging/error_reporter.dart';

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

  @override
  void initState() {
    super.initState();
    if (widget.sessions.isNotEmpty) {
      _sessionLogPath = widget.sessions.first.logPath;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _hasText => _controller.text.trim().isNotEmpty;

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

  void _continue() {
    final text = _controller.text.trim();
    if (text.isEmpty) return; // Required — guarded by the disabled button too.
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
        title: const Text('Describe the problem'),
        // Closing without text returns null (the default pop result), which the
        // caller treats as "cancelled" and skips creating a report.
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Round 190: the app runs its dark theme, so the helper texts
              // on this screen use the white70/white54 palette every other
              // screen uses — the original black54/black45 (and the r189
              // GitHub line) were near-invisible dark-on-dark (owner report).
              const Text(
                'Please describe what went wrong in your own words — what you '
                'were doing, what you expected, and what happened instead. This '
                'is required and helps with debugging.',
                style: TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 6),
              // Round 189 (owner request): point at the public issue tracker
              // as an alternative reporting channel, up front.
              InkWell(
                onTap: () async {
                  try {
                    await launchUrl(
                      Uri.parse(ErrorReporter.githubIssuesUrl),
                      mode: LaunchMode.externalApplication,
                    );
                  } catch (e) {
                    logSwallowed('describe_open_issues', e);
                  }
                },
                child: const Text.rich(
                  TextSpan(
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                    children: [
                      TextSpan(
                        text: 'Problems can also be reported as a GitHub '
                            'issue: ',
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
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white24),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _previewing ? _preview() : _editor(),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Markdown is allowed — e.g. **bold**, *italic*, or "- " for a '
                'bulleted list.',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
              const SizedBox(height: 8),
              // Screenshots (round 190, optional): picked here, copied into
              // the report folder by ErrorReporter.build, and attached
              // alongside the .txt when the report is shared.
              Row(
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
                  const SizedBox(width: 8),
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
              if (_shots.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final s in _shots)
                        InputChip(
                          label: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 140),
                            child: Text(
                              s.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                          onDeleted: () => setState(() => _shots.remove(s)),
                        ),
                    ],
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
                    const Text(
                      'Include session data: ',
                      style: TextStyle(fontSize: 13, color: Colors.white70),
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
                  'Pick the session your problem is about — its settings and '
                  'samples of its technical logs are added to the report. '
                  'Choose "No session data" if the problem is unrelated.',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ],
              const SizedBox(height: 12),
              Row(
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _editor() {
    return TextField(
      controller: _controller,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      // Rebuild so the Continue button enables/disables as the user types.
      onChanged: (_) => setState(() {}),
      decoration: const InputDecoration(
        border: InputBorder.none,
        hintText: 'e.g. The detector froze after about 5 minutes...',
      ),
    );
  }

  Widget _preview() {
    if (!_hasText) {
      return const Center(
        child: Text(
          'Nothing to preview yet.',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
    return SingleChildScrollView(child: MarkdownBody(data: _controller.text));
  }
}
