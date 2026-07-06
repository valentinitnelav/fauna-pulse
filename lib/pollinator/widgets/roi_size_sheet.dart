// Pollinator Monitor — exact ROI size bottom sheet (moved out of the camera
// screen in round 73, review item B6d; behaviour unchanged).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/roi.dart';

/// Bottom sheet for setting an exact ROI side in pixels: live slider plus a
/// type-a-number field. A proper StatefulWidget so its TextEditingController
/// is disposed by the framework when the sheet is truly gone (round 71 — the
/// previous inline builder crashed writing to an already-disposed controller
/// during the closing animation).
///
/// Every path into [_apply] snaps to the multiple-of-32 grid the crop uses
/// and clamps to [minPx]..[maxPx], and the field is rewritten to the value
/// actually applied — so the number on screen is always the real ROI size.
/// Typed input applies on the keyboard's submit, on the field losing focus,
/// and on Done, so "type a value, tap Done" can no longer leave an unapplied
/// arbitrary number standing.
class RoiSizeSheet extends StatefulWidget {
  final int minPx;
  final int maxPx;
  final int initialPx;
  final ValueChanged<int> onApply;

  const RoiSizeSheet({
    super.key,
    required this.minPx,
    required this.maxPx,
    required this.initialPx,
    required this.onApply,
  });

  @override
  State<RoiSizeSheet> createState() => _RoiSizeSheetState();
}

class _RoiSizeSheetState extends State<RoiSizeSheet> {
  late int _curPx = widget.initialPx;
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialPx.toString(),
  );
  final FocusNode _fieldFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _fieldFocus.addListener(() {
      if (!_fieldFocus.hasFocus) _applyTyped();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  /// Snap, clamp, show what was applied, and hand the value to the screen.
  void _apply(int px) {
    if (!mounted) return;
    final snapped = snapToMultipleOf32(
      px.toDouble(),
    ).clamp(widget.minPx, widget.maxPx).toInt();
    setState(() => _curPx = snapped);
    _controller.text = snapped.toString();
    widget.onApply(snapped);
  }

  void _applyTyped() {
    final v = int.tryParse(_controller.text.trim());
    if (v != null) {
      _apply(v);
    } else if (mounted) {
      // Unparseable leftovers (empty field): restore the current value.
      _controller.text = _curPx.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      // Scrollable so the sheet can never overflow while the keyboard
      // animates in for the px text field — in a debug build that overflow
      // flashes the striped "BOTTOM OVERFLOWED" banner, which reads like an
      // app error (round 65, owner report session_99).
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ROI size: $_curPx × $_curPx px  (max ${widget.maxPx})',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _curPx.toDouble().clamp(
                      widget.minPx.toDouble(),
                      widget.maxPx.toDouble(),
                    ),
                    min: widget.minPx.toDouble(),
                    max: widget.maxPx.toDouble(),
                    divisions: ((widget.maxPx - widget.minPx) ~/ 32).clamp(
                      1,
                      1000,
                    ),
                    label: '$_curPx px',
                    onChanged: (v) => _apply(v.round()),
                  ),
                ),
                SizedBox(
                  width: 88,
                  child: TextField(
                    controller: _controller,
                    focusNode: _fieldFocus,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      suffixText: 'px',
                      suffixStyle: TextStyle(color: Colors.white54),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _applyTyped(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Slide or type the exact ROI resolution (it snaps to the '
              'nearest multiple of 32). Then drag or pinch on the preview '
              'to position it. The maximum equals the full sensor width.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () {
                  // Apply whatever is typed before closing, so Done never
                  // discards a value the user can still see in the field.
                  _applyTyped();
                  Navigator.of(context).pop();
                },
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
