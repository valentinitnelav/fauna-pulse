// FaunaPulse — a labelled numeric text box for one setting.
//
// Replaces the draggable sliders that used to live in the settings sheet.
// Sliders were unusable inside the swipeable settings tabs: a horizontal drag
// on the slider was stolen by the TabBarView's page-swipe, so the value never
// moved (the whole tab slid sideways instead). A plain number box has no
// horizontal drag, so it can't fight the tab swipe, and it lets the user type
// an exact value instead of nudging a thumb.
//
// The box "commits" (calls [onChanged]) on every valid keystroke, clamping the
// number into [min]..[max]. The visible text is only re-formatted to the
// canonical value when the field loses focus, so the user can type freely
// (e.g. "0.3") without the box rewriting their input mid-typing.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class NumericSettingField extends StatefulWidget {
  /// Short description shown to the left of the box (e.g. "Confidence threshold").
  final String label;

  /// Optional one-line explanation shown under the row, in muted text.
  final String? helperText;

  /// Current value (the field is initialised and re-synced from this).
  final double value;

  /// Smallest / largest value the box will accept; typed values are clamped
  /// into this range before [onChanged] is called.
  final double min;
  final double max;

  /// When true the value is a whole number (no decimal point allowed/shown).
  final bool isInt;

  /// Decimal places shown when [isInt] is false.
  final int decimals;

  /// Optional unit printed inside the box after the number (e.g. "s", "/s").
  final String? unitSuffix;

  /// Called with the clamped value whenever the user types a valid number.
  final ValueChanged<double> onChanged;

  const NumericSettingField({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.helperText,
    this.isInt = false,
    this.decimals = 2,
    this.unitSuffix,
  });

  @override
  State<NumericSettingField> createState() => _NumericSettingFieldState();
}

class _NumericSettingFieldState extends State<NumericSettingField> {
  late final TextEditingController _controller;
  late final FocusNode _focus;

  String _format(double v) =>
      widget.isInt ? v.round().toString() : v.toStringAsFixed(widget.decimals);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _format(widget.value));
    _focus = FocusNode();
    // When the box loses focus, snap the visible text back to the canonical
    // formatting of the (clamped) value — e.g. "200" typed into a 0..120 box
    // becomes "120", and "0.3" becomes "0.30".
    _focus.addListener(() {
      if (!_focus.hasFocus) {
        _controller.text = _format(widget.value);
      }
    });
  }

  @override
  void didUpdateWidget(NumericSettingField old) {
    super.didUpdateWidget(old);
    // Keep the text in sync if the value changes from outside while the user
    // isn't editing (so it can't clobber what they're typing).
    if (!_focus.hasFocus && _format(widget.value) != _controller.text) {
      _controller.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    final parsed = double.tryParse(text.trim());
    if (parsed == null) return; // mid-typing (e.g. "0." or ""), wait for more
    final clamped = parsed.clamp(widget.min, widget.max).toDouble();
    widget.onChanged(clamped);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 96,
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  textAlign: TextAlign.right,
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: !widget.isInt,
                  ),
                  inputFormatters: [
                    widget.isInt
                        ? FilteringTextInputFormatter.digitsOnly
                        : FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    isDense: true,
                    suffixText: widget.unitSuffix,
                    suffixStyle: const TextStyle(color: Colors.white54),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    enabledBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.lightBlueAccent),
                    ),
                  ),
                  onChanged: _onChanged,
                ),
              ),
            ],
          ),
          if (widget.helperText != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                widget.helperText!,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
