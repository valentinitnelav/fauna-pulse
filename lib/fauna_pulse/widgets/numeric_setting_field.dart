// FaunaPulse — a labelled numeric text box for one setting.
//
// Replaces the draggable sliders that used to live in the settings sheet.
// Sliders were unusable inside the swipeable settings tabs: a horizontal drag
// on the slider was stolen by the TabBarView's page-swipe, so the value never
// moved (the whole tab slid sideways instead). A plain number box has no
// horizontal drag, so it can't fight the tab swipe, and it lets the user type
// an exact value instead of nudging a thumb.
//
// The box "commits" (calls [onChanged]) on every keystroke that gives a number
// inside [min]..[max], so nothing typed is lost when the screen closes. Round
// 313 (owner: "the value jumps back"): a number outside the range is NOT
// committed and never silently clamped; a line under the box says what is
// allowed (and [rangeNote] why), and the value the box had before the typing
// is put back at once (a shorter number on the way may have been valid: "6"
// of "61" in a 5 to 60 box). Only as many decimals as the box shows can be
// typed, and a comma counts as the decimal point (keyboards set to a language
// that writes 0,5), so the box, the stored value and the value used are always
// the same number. When the screen stores another number than the one typed,
// the line says so ("Saved as 5"). The visible text is re-formatted to the
// stored value when the box loses focus, so the user can type freely
// (e.g. "0.3") without the box rewriting their input mid-typing.
//
// Hosts never change a SECOND stored setting from [onChanged] (round 313):
// a rule between two settings is applied where the values are used, and the
// box shows it with [warning]. test/fauna_pulse/settings_fields_test.dart
// types into every box of every settings screen to keep it that way.
//
// The helper paragraph is collapsed behind an ⓘ icon (round 159): with ~40
// fields in the settings sheet, always-visible multi-line helpers were the
// main source of visual density. Tapping the label row (or the icon) reveals
// the full explanation; the state is per-field and resets when the sheet
// closes — deliberately, so a first-time user always starts with the compact
// view.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Colour of the line under a box when the typed number is not allowed.
const Color kFieldErrorColor = Color(0xFFFF8A80); // Colors.redAccent.shade100

/// Colour of a note under a box about the value used (round 313).
const Color kFieldWarningColor = Colors.amberAccent;

class NumericSettingField extends StatefulWidget {
  /// Short description shown to the left of the box (e.g. "Confidence threshold").
  final String label;

  /// Optional one-line explanation shown under the row, in muted text.
  final String? helperText;

  /// Current value (the field is initialised and re-synced from this).
  final double value;

  /// Smallest / largest value the box accepts; a typed number outside is not
  /// committed and the box says what is allowed.
  final double min;
  final double max;

  /// When true the value is a whole number (no decimal point allowed/shown).
  final bool isInt;

  /// Decimal places shown when [isInt] is false; 0 behaves like [isInt].
  final int decimals;

  /// Optional unit printed inside the box after the number (e.g. "s", "/s").
  final String? unitSuffix;

  /// False keeps [unitSuffix] out of the box (it still appears in the
  /// "Allowed" and error lines), for a host that shows the unit beside the
  /// box itself, like DurationSettingField's unit menu; otherwise the unit
  /// reads twice ("2.0 s  s").
  final bool showSuffixInField;

  /// Called with the typed value whenever it is a number inside the range.
  final ValueChanged<double> onChanged;

  /// Always-visible amber note under the box, for a rule the host applies when
  /// the value is used (e.g. "Used: 5, the camera's frame rate cap").
  final String? warning;

  /// Why the range is what it is, added to the "Allowed" line (for a limit
  /// that follows another setting).
  final String? rangeNote;

  /// The allowed range in words, instead of "[min] to [max]" (e.g. a duration
  /// field says "1 s to 24 h").
  final String? rangeText;

  /// False greys the box out and ignores typing (e.g. while a run uses it).
  final bool enabled;

  /// When set, 0 is also allowed below [min] and means this (e.g.
  /// "automatic", "no cap"); the "Allowed" line says so.
  final String? zeroMeans;

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
    this.showSuffixInField = true,
    this.warning,
    this.rangeNote,
    this.rangeText,
    this.enabled = true,
    this.zeroMeans,
  });

  @override
  State<NumericSettingField> createState() => _NumericSettingFieldState();
}

class _NumericSettingFieldState extends State<NumericSettingField> {
  late final TextEditingController _controller;
  late final FocusNode _focus;

  /// Whether the helper paragraph is expanded (ⓘ tapped). Ephemeral on
  /// purpose — every field starts compact each time the sheet opens.
  bool _helpOpen = false;

  /// The line under the box: the typed number is not allowed (red), or the
  /// host saved another number than the one typed (amber). Cleared by the
  /// next keystroke.
  String? _error;
  String? _adjusted;

  /// The number passed to [NumericSettingField.onChanged] by the last
  /// keystroke, until the host's rebuild shows what it stored.
  double? _lastCommitted;

  /// The value before the first keystroke of this edit: a refused number puts
  /// it back at once (typing "61" into a 5 to 60 box stores "6" on the way).
  /// Taken at the first keystroke, not when the box gets the focus, so a value
  /// the host set meanwhile (a dialog, a reset) is the one kept.
  double? _valueAtFocus;

  /// The last keystroke gave a number outside the range.
  bool _refused = false;

  bool get _whole => widget.isInt || widget.decimals <= 0;
  int get _places => _whole ? 0 : widget.decimals;

  String _format(double v) => _whole ? v.round().toString() : v.toStringAsFixed(_places);

  /// Half of the last shown digit: two numbers closer than this look the same.
  double get _tolerance => 0.5 * math.pow(10, -_places).toDouble() + 1e-9;

  String get _range {
    final unit = widget.unitSuffix == null ? '' : ' ${widget.unitSuffix}';
    final zero = widget.zeroMeans == null ? '' : '0 (${widget.zeroMeans}) or ';
    final text = widget.rangeText ?? '$zero${_format(widget.min)} to ${_format(widget.max)}$unit';
    return widget.rangeNote == null ? text : '$text (${widget.rangeNote})';
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _format(widget.value));
    _focus = FocusNode();
    // When the box loses focus, show the stored value again in its canonical
    // formatting ("0.3" becomes "0.30"); a refused number is replaced by the
    // value that stays, and the line under the box says why.
    _focus.addListener(() {
      if (_focus.hasFocus) return;
      if (_lastCommitted != null && (widget.value - _lastCommitted!).abs() > _tolerance) {
        _adjusted = 'Saved as ${_format(widget.value)}';
      }
      _lastCommitted = null;
      _error = _refused ? 'Not changed: allowed is $_range.' : null;
      _refused = false;
      _valueAtFocus = null;
      _controller.text = _format(widget.value);
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(NumericSettingField old) {
    super.didUpdateWidget(old);
    // A value changed from outside (a reset, settings read again): the notes
    // under the box were about the old one.
    if (!_focus.hasFocus && _lastCommitted == null && (old.value - widget.value).abs() > 1e-12) {
      _error = null;
      _adjusted = null;
    }
    // The host's rebuild after a keystroke: say so when it stored another
    // number than the one typed.
    if (_lastCommitted != null) {
      _adjusted = (widget.value - _lastCommitted!).abs() > _tolerance ? 'Saved as ${_format(widget.value)}' : null;
      _lastCommitted = null;
    }
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
    // An emptied box starts a new entry: a refused number then goes back to
    // the value stored when it was emptied (seen on the Samsung: "0,55", then
    // emptied, then "1.2" went back to the value from before "0,55").
    if (text.trim().isEmpty) _valueAtFocus = widget.value;
    _valueAtFocus ??= widget.value;
    final parsed = double.tryParse(text.trim().replaceAll(',', '.'));
    if (parsed == null) {
      // Mid-typing (e.g. "0." or ""): wait for more.
      _refused = false;
      if (_error != null || _adjusted != null) setState(() => _error = _adjusted = null);
      return;
    }
    final v = _whole ? parsed.roundToDouble() : double.parse(parsed.toStringAsFixed(_places));
    final zeroOk = widget.zeroMeans != null && v == 0;
    if (!zeroOk && (v < widget.min - 1e-9 || v > widget.max + 1e-9)) {
      _refused = true;
      setState(() {
        _error = 'Allowed: $_range.';
        _adjusted = null;
      });
      // Put back the value from before this edit, now: the box may leave the
      // screen before it loses the focus (a fold closes, a switch hides it),
      // and then no blur would ever come.
      final keep = _valueAtFocus!;
      if ((keep - widget.value).abs() > 1e-12) {
        _lastCommitted = null;
        widget.onChanged(keep);
      }
      return;
    }
    _refused = false;
    if (_error != null || _adjusted != null) setState(() => _error = _adjusted = null);
    _lastCommitted = v;
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final notes = <(String, Color)>[
      if (_error != null) (_error!, kFieldErrorColor),
      if (_error == null && _adjusted != null) (_adjusted!, kFieldWarningColor),
      if (widget.warning != null) (widget.warning!, kFieldWarningColor),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                // The whole label row toggles the helper, not just the small
                // icon — a fingertip-sized target in the field.
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.helperText == null
                      ? null
                      : () => setState(() => _helpOpen = !_helpOpen),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.label,
                          style: TextStyle(color: widget.enabled ? Colors.white70 : Colors.white38),
                        ),
                      ),
                      if (widget.helperText != null) ...[
                        const SizedBox(width: 4),
                        Icon(
                          _helpOpen ? Icons.info : Icons.info_outline,
                          size: 16,
                          color: Colors.white38,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 96,
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  enabled: widget.enabled,
                  textAlign: TextAlign.right,
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: !_whole,
                  ),
                  inputFormatters: [
                    _whole ? FilteringTextInputFormatter.digitsOnly : _DecimalFormatter(_places),
                  ],
                  style: TextStyle(color: widget.enabled ? Colors.white : Colors.white38),
                  decoration: InputDecoration(
                    isDense: true,
                    suffixText: widget.showSuffixInField ? widget.unitSuffix : null,
                    suffixStyle: const TextStyle(color: Colors.white54),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: _error != null ? kFieldErrorColor : Colors.white24),
                    ),
                    disabledBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white12),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: _error != null ? kFieldErrorColor : Colors.lightBlueAccent),
                    ),
                  ),
                  onChanged: _onChanged,
                ),
              ),
            ],
          ),
          for (final (text, color) in notes)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(text, style: TextStyle(color: color, fontSize: 12)),
            ),
          if (widget.helperText != null && _helpOpen) ...[
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                widget.helperText!,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('Allowed: $_range.', style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Digits with at most one decimal point (or comma) and at most [places]
/// decimals: the box can never hold more decimals than it shows.
class _DecimalFormatter extends TextInputFormatter {
  final RegExp _allowed;

  _DecimalFormatter(int places) : _allowed = RegExp('^\\d*([.,]\\d{0,$places})?\$');

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      _allowed.hasMatch(newValue.text) ? newValue : oldValue;
}
