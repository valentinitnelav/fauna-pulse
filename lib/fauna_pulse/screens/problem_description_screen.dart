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

/// Opens the editor and returns the trimmed description, or null if cancelled.
Future<String?> showProblemDescriptionEditor(BuildContext context) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      fullscreenDialog: true,
      builder: (_) => const ProblemDescriptionScreen(),
    ),
  );
}

class ProblemDescriptionScreen extends StatefulWidget {
  const ProblemDescriptionScreen({super.key});

  @override
  State<ProblemDescriptionScreen> createState() =>
      _ProblemDescriptionScreenState();
}

class _ProblemDescriptionScreenState extends State<ProblemDescriptionScreen> {
  final TextEditingController _controller = TextEditingController();
  // false = Edit tab, true = Preview tab.
  bool _previewing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _hasText => _controller.text.trim().isNotEmpty;

  void _continue() {
    final text = _controller.text.trim();
    if (text.isEmpty) return; // Required — guarded by the disabled button too.
    Navigator.of(context).pop(text);
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
              const Text(
                'Please describe what went wrong in your own words — what you '
                'were doing, what you expected, and what happened instead. This '
                'is required and helps with debugging.',
                style: TextStyle(fontSize: 13, color: Colors.black54),
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
                    border: Border.all(color: Colors.black26),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _previewing ? _preview() : _editor(),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Markdown is allowed — e.g. **bold**, *italic*, or "- " for a '
                'bulleted list.',
                style: TextStyle(fontSize: 11, color: Colors.black45),
              ),
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
          style: TextStyle(color: Colors.black45),
        ),
      );
    }
    return SingleChildScrollView(child: MarkdownBody(data: _controller.text));
  }
}
