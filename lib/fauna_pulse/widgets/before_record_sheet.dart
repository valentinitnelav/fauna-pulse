// FaunaPulse (round 298): the "Before you record" sheet, shown when REC is tapped.
//
// Idea from the sister app FaunaLapse, whose main screen shows field metadata, the schedule
// and the "Phone for the field" checks before Start. Here one sheet sums them up, each with a
// way to change it: the field notes (and position), what and when will be recorded (one
// plain sentence), and the phone settings that matter in the field (read again when the user
// comes back from a settings page). Start starts the recording or the scheduled run. It pops
// with 'start', 'notes' (open the field notes), 'settings' (open the session settings) or
// null (cancelled).

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/phone_state.dart';
import '../services/phone_settings.dart';
import 'dialog_title.dart';
import 'setting_help.dart';

/// Whether the sheet shows before each start (pref; default yes).
const kBeforeRecordSheetKey = 'before_record_sheet';

Future<bool> beforeRecordSheetEnabled() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(kBeforeRecordSheetKey) ?? true;
  } catch (_) {
    return true;
  }
}

class BeforeRecordSheet extends StatefulWidget {
  const BeforeRecordSheet({
    super.key,
    required this.fieldSummary,
    required this.positionLine,
    required this.plan,
    required this.scheduled,
    this.readPhone = PhoneSettings.read,
  });

  /// The filled field notes in one line ('' when none).
  final String fieldSummary;
  final String positionLine;

  /// What and when, from planSentence.
  final String plan;
  final bool scheduled;

  /// Reads the phone settings (replaced in tests).
  final Future<PhoneState> Function() readPhone;

  @override
  State<BeforeRecordSheet> createState() => _BeforeRecordSheetState();
}

class _BeforeRecordSheetState extends State<BeforeRecordSheet> with WidgetsBindingObserver {
  PhoneState? _phone;
  bool _showEachTime = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _readPhone();
    beforeRecordSheetEnabled().then((v) {
      if (mounted) setState(() => _showEachTime = v);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from a settings page: read the phone again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _readPhone();
  }

  Future<void> _readPhone() async {
    final p = await widget.readPhone();
    if (mounted) setState(() => _phone = p);
  }

  Future<void> _setShowEachTime(bool v) async {
    setState(() => _showEachTime = v);
    try {
      await (await SharedPreferences.getInstance()).setBool(kBeforeRecordSheetKey, v);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: DefaultTextStyle.merge(
            style: Theme.of(context).textTheme.titleLarge,
            child: DialogTitle(const Text('Before you record'), onClose: () => Navigator.of(context).pop()),
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            children: [
              _section(
                'Field notes',
                [
                  widget.positionLine,
                  widget.fieldSummary.isEmpty ? 'No notes filled in yet.' : widget.fieldSummary,
                ],
                'notes',
              ),
              _section('What and when', [widget.plan], 'settings'),
              _phoneSection(),
            ],
          ),
        ),
        CheckboxListTile(
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          value: _showEachTime,
          onChanged: (v) => _setShowEachTime(v ?? true),
          title: const Text('Show this before each start', overflow: TextOverflow.ellipsis),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + bottom),
          // Like a dialog's buttons: side by side, stacked (Start on top) when
          // they do not fit, e.g. with a large system font size.
          child: OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: 8,
            overflowAlignment: OverflowBarAlignment.end,
            overflowDirection: VerticalDirection.up,
            overflowSpacing: 4,
            children: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
              FilledButton(
                onPressed: () => Navigator.of(context).pop('start'),
                child: Text(widget.scheduled ? 'Start the run' : 'Start'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _section(String title, List<String> lines, String action) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(onPressed: () => Navigator.of(context).pop(action), child: const Text('Change')),
            ],
          ),
          for (final l in lines) Text(l, style: const TextStyle(fontSize: 13, color: Colors.white70)),
        ],
      ),
    );
  }

  Widget _phoneSection() {
    final p = _phone;
    final tips = p?.tips ?? const <PhoneTip>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HelpLabel(
          label: 'Phone for the field',
          labelStyle: TextStyle(fontWeight: FontWeight.bold),
          helperText:
              'A phone used only as a camera lasts longest with no SIM card, no '
              'Google account, automatic app and system updates off, and other '
              'apps removed. Set the clock before turning on airplane mode. Phone '
              'makers such as Huawei, Xiaomi and Samsung also have their own '
              'battery managers: allow FaunaPulse there too.',
        ),
        const SizedBox(height: 4),
        if (p == null)
          const Text('Reading the phone settings…', style: TextStyle(fontSize: 13, color: Colors.white54))
        else if (tips.isEmpty)
          const Text(PhoneState.readyText, style: TextStyle(fontSize: 13, color: Colors.white70))
        else
          for (final t in tips)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(t.text, style: const TextStyle(fontSize: 13, color: Colors.amberAccent)),
                  ),
                  TextButton(onPressed: () => PhoneSettings.open(t.page), child: const Text('Open settings')),
                ],
              ),
            ),
      ],
    );
  }
}
