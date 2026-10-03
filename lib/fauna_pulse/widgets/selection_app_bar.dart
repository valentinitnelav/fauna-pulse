// FaunaPulse: the title bar while items are selected (Sessions, Download &
// import models), as in Android's own apps (Files, Photos, Gmail): an X at
// the left ends the selection and the title says how many are selected.
// Round 285: the bar is tinted like the selected rows, so the selection mode
// shows at a glance. Back and unticking the last item also end it (in each
// screen).
import 'package:flutter/material.dart';

AppBar selectionAppBar(
  BuildContext context, {
  required int count,
  required VoidCallback onClose,
  required List<Widget> actions,
}) => AppBar(
  backgroundColor: Color.alphaBlend(
    Colors.lightBlueAccent.withValues(alpha: 0.16),
    Theme.of(context).colorScheme.surface,
  ),
  leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Stop selecting', onPressed: onClose),
  title: Text('$count selected'),
  actions: actions,
);
