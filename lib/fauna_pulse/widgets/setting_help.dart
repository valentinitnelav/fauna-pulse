// FaunaPulse — shared ⓘ help-toggle widgets for settings surfaces (round 181).
//
// NumericSettingField introduced the pattern in round 159: with dozens of
// controls on one sheet, always-visible multi-line explanations were the main
// source of visual clutter, so each explanation hides behind a small ⓘ icon
// until the user taps for it. These widgets extend the same pattern to every
// other kind of control (plain labels over dropdowns, switches, checkboxes,
// buttons, collapsible sections), so the whole settings surface behaves one
// way. The open/closed state is per-widget and deliberately ephemeral: every
// screen opens compact, even for a returning user.
//
// Live status lines (mode notes like "Not used in time-lapse mode", or
// warnings like "the camera will stay on") must NOT go behind the ⓘ — they
// describe what is happening right now with the user's current values, so
// they stay always visible via [HelpSwitchTile.statusText].

import 'package:flutter/material.dart';

const helperTextStyle = TextStyle(color: Colors.white54, fontSize: 12);

Widget _helpIcon(bool open) => Icon(
  open ? Icons.info : Icons.info_outline,
  size: 16,
  color: Colors.white38,
);

/// The expanded helper paragraph, shown under a control while its ⓘ is open.
Widget _helpBody(String text) => Padding(
  padding: const EdgeInsets.only(top: 4),
  child: Text(text, style: helperTextStyle),
);

/// A tap target for the ⓘ icon alone (used where the row itself already has
/// a tap action, e.g. a switch tile): padding enlarges the finger target
/// beyond the 16-px glyph.
Widget _helpIconButton(bool open, VoidCallback onTap) => GestureDetector(
  behavior: HitTestBehavior.opaque,
  onTap: onTap,
  child: Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: _helpIcon(open),
  ),
);

/// A label (e.g. above a dropdown or a section of fields) with its
/// explanation behind the ⓘ. Tapping anywhere on the label row toggles the
/// helper — same interaction as NumericSettingField's label.
class HelpLabel extends StatefulWidget {
  final String label;
  final String helperText;
  final TextStyle labelStyle;

  /// Optional icon shown before the label (used by section headers).
  final Widget? leading;

  const HelpLabel({
    super.key,
    required this.label,
    required this.helperText,
    this.labelStyle = const TextStyle(color: Colors.white70),
    this.leading,
  });

  @override
  State<HelpLabel> createState() => _HelpLabelState();
}

class _HelpLabelState extends State<HelpLabel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Row(
              children: [
                if (widget.leading != null) ...[
                  widget.leading!,
                  const SizedBox(width: 8),
                ],
                Flexible(child: Text(widget.label, style: widget.labelStyle)),
                const SizedBox(width: 4),
                _helpIcon(_open),
              ],
            ),
          ),
          if (_open) _helpBody(widget.helperText),
        ],
      ),
    );
  }
}

/// Wraps a control that is not a labelled field (e.g. a button) with a
/// trailing ⓘ that toggles the explanation below it.
class HelpRow extends StatefulWidget {
  final Widget child;
  final String helperText;

  const HelpRow({super.key, required this.child, required this.helperText});

  @override
  State<HelpRow> createState() => _HelpRowState();
}

class _HelpRowState extends State<HelpRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: widget.child),
            const SizedBox(width: 4),
            _helpIconButton(_open, () => setState(() => _open = !_open)),
          ],
        ),
        if (_open) _helpBody(widget.helperText),
      ],
    );
  }
}

/// A SwitchListTile (or, with [checkbox] true, a leading CheckboxListTile)
/// whose explanation hides behind the ⓘ in the title row. Only the icon
/// toggles the help — tapping the rest of the row still flips the switch,
/// as everywhere else on Android.
///
/// [statusText] is for live, value-dependent notes (why the control is
/// greyed out, or a warning that the current values disable the feature);
/// it stays always visible, in [statusColor].
class HelpSwitchTile extends StatefulWidget {
  final String title;
  final TextStyle titleStyle;
  final String? helperText;
  final String? statusText;
  final Color statusColor;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool dense;
  final bool checkbox;

  const HelpSwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.titleStyle = const TextStyle(color: Colors.white),
    this.helperText,
    this.statusText,
    this.statusColor = Colors.white54,
    this.dense = false,
    this.checkbox = false,
  });

  @override
  State<HelpSwitchTile> createState() => _HelpSwitchTileState();
}

class _HelpSwitchTileState extends State<HelpSwitchTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final title = Row(
      children: [
        Flexible(child: Text(widget.title, style: widget.titleStyle)),
        if (widget.helperText != null)
          _helpIconButton(_open, () => setState(() => _open = !_open)),
      ],
    );
    // The status/helper lines live BELOW the tile, not in its `subtitle`:
    // toggling a ListTile subtitle between null and non-null while the title
    // row contains the padded ⓘ trips a framework baseline-layout assertion
    // (RenderShiftedBox '!debugNeedsLayout', seen in the widget test).
    // Outside the tile they also span the full sheet width.
    final Widget tile = widget.checkbox
        ? CheckboxListTile(
            dense: widget.dense,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: title,
            value: widget.value,
            onChanged: widget.onChanged == null
                ? null
                : (v) => widget.onChanged!(v ?? false),
          )
        : SwitchListTile(
            dense: widget.dense,
            contentPadding: EdgeInsets.zero,
            title: title,
            value: widget.value,
            onChanged: widget.onChanged,
          );
    final showHelp = _open && widget.helperText != null;
    if (widget.statusText == null && !showHelp) return tile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        tile,
        if (widget.statusText != null)
          Text(
            widget.statusText!,
            style: TextStyle(color: widget.statusColor, fontSize: 12),
          ),
        if (showHelp) _helpBody(widget.helperText!),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// A collapsed "Advanced"-style section (the round-159 fold recipe: zero tile
/// padding, muted chevron, no divider lines when expanded) with an optional
/// ⓘ on the header. [subtitle] should stay a single short line naming what is
/// inside; the longer why/when explanation goes in [helperText]. Folding is
/// progressive disclosure only — every control inside stays fully editable.
class FoldSection extends StatefulWidget {
  final String title;
  final String? subtitle;
  final String? helperText;
  final bool initiallyExpanded;
  final List<Widget> children;

  const FoldSection({
    super.key,
    required this.title,
    this.subtitle,
    this.helperText,
    this.initiallyExpanded = false,
    required this.children,
  });

  @override
  State<FoldSection> createState() => _FoldSectionState();
}

class _FoldSectionState extends State<FoldSection> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final lines = <Widget>[
      if (widget.subtitle != null)
        Text(widget.subtitle!, style: helperTextStyle),
      if (_open && widget.helperText != null) _helpBody(widget.helperText!),
    ];
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      collapsedIconColor: Colors.white70,
      iconColor: Colors.white70,
      shape: const Border(), // no divider lines when expanded
      collapsedShape: const Border(),
      initiallyExpanded: widget.initiallyExpanded,
      title: Row(
        children: [
          Flexible(
            child: Text(
              widget.title,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          if (widget.helperText != null)
            _helpIconButton(_open, () => setState(() => _open = !_open)),
        ],
      ),
      subtitle: lines.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: lines,
            ),
      children: widget.children,
    );
  }
}
