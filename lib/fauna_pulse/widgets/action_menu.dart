// FaunaPulse (round 393): the ⋮ menu of a row looks the same wherever a list has one: each
// session on the Sessions screen, each file on Download & import models. An icon beside each
// action, a delete action in red.
import 'package:flutter/material.dart';

/// One action of a row's ⋮ menu (a PopupMenuButton).
PopupMenuItem<T> actionMenuItem<T>(T value, IconData icon, String text, {Color? color}) => PopupMenuItem(
  value: value,
  child: ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, color: color),
    title: Text(text, style: color == null ? null : TextStyle(color: color)),
  ),
);
