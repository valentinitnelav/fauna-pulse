// FaunaPulse (round 288, owner; round 287 made them on the watch pages): the
// models that find the animals (detection) and those that name them
// (identification) each sit in a panel of their own colour, with a thick line
// in that colour on top, so the two kinds are told apart at a glance: on the
// "What do you want to watch?" pages (Choose other models) and on Download &
// import models.
import 'package:flutter/material.dart';

import 'setting_help.dart' show helperTextStyle;

/// Light blue for finding, orange for naming: easy to tell apart on the dark
/// theme (the theme's own lavender and pink are close to each other and to
/// a chosen radio button).
const kDetectionColor = Colors.lightBlue;
const kIdentificationColor = Colors.orange;

/// The two icons of the kinds of model (round 268, owner): a framed circle
/// for detection, a microscope for identification.
const kDetectionIcon = Icons.center_focus_strong_outlined;
const kIdentificationIcon = Icons.biotech_outlined;

class ModelKindPanel extends StatelessWidget {
  final bool identification;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  const ModelKindPanel({
    super.key,
    required this.identification,
    required this.title,
    this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final color = identification ? kIdentificationColor : kDetectionColor;
    final subtitle = this.subtitle;
    // A Material (not a plain coloured box), so the ripple of a tap on a row
    // shows on the fill.
    return Material(
      color: color.withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: color, width: 4))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(identification ? kIdentificationIcon : kDetectionIcon, size: 22, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: Text(subtitle, style: helperTextStyle),
                ),
              const SizedBox(height: 4),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}
