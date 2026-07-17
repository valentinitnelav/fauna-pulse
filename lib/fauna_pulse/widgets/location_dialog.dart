// FaunaPulse — session-location dialog (round 126).
//
// Deliberately map-free so it works fully offline (the owner runs sessions in
// flight mode): a live readout of the GPS search plus a manual coordinate
// entry as the fallback when GPS can't get a fix. Same StatefulWidget +
// AlertDialog + pop(result) pattern as SessionInfoDialog.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../session/location_fix.dart';

/// What the dialog decided. A null [location] means "remove the session
/// location"; the dialog pops plain null for "no change".
class LocationDialogResult {
  final SessionLocation? location;
  const LocationDialogResult(this.location);
}

class LocationDialog extends StatefulWidget {
  const LocationDialog({
    super.key,
    required this.current,
    required this.searching,
    required this.onSearchAgain,
    this.previous,
  });

  /// Live best fix / search state, owned by the camera screen so GPS results
  /// keep flowing into the open dialog.
  final ValueListenable<SessionLocation?> current;
  final ValueListenable<bool> searching;

  /// Starts (or restarts) the GPS search, prompting for the location
  /// permission if needed. False = service off or permission denied.
  final Future<bool> Function() onSearchAgain;

  /// The location used by an earlier session, offered as a one-tap default
  /// (the phone often returns to the same flower patch).
  final SessionLocation? previous;

  @override
  State<LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends State<LocationDialog> {
  final _latCtrl = TextEditingController();
  final _lonCtrl = TextEditingController();
  String? _hint;

  @override
  void dispose() {
    _latCtrl.dispose();
    _lonCtrl.dispose();
    super.dispose();
  }

  void _useManual() {
    final lat = double.tryParse(_latCtrl.text.trim().replaceAll(',', '.'));
    final lon = double.tryParse(_lonCtrl.text.trim().replaceAll(',', '.'));
    if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
      setState(
        () => _hint =
            'Enter decimal degrees: latitude −90…90, longitude −180…180.',
      );
      return;
    }
    Navigator.of(context).pop(
      LocationDialogResult(
        SessionLocation(
          latitude: lat,
          longitude: lon,
          fixTimeMs: DateTime.now().millisecondsSinceEpoch,
          source: 'manual',
        ),
      ),
    );
  }

  Future<void> _search() async {
    setState(() => _hint = null);
    final ok = await widget.onSearchAgain();
    if (!ok && mounted) {
      setState(
        () => _hint =
            'GPS unavailable — turn on Location and allow the permission. '
            'Tip: get the fix BEFORE enabling flight mode (assisted GPS '
            'cannot download there, so a fix takes much longer).',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final prev = widget.previous;
    return AlertDialog(
      title: const Text('Session location'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'One location per session: written to the session log and into '
              'the photo details (EXIF) of crops you export after the '
              'session, so identification apps know where the photo was '
              'taken. Read once — the GPS is released as soon as the fix is '
              'stable.',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            // Live search status: keeps updating while the dialog is open.
            ValueListenableBuilder<bool>(
              valueListenable: widget.searching,
              builder: (_, searching, _) =>
                  ValueListenableBuilder<SessionLocation?>(
                    valueListenable: widget.current,
                    builder: (_, loc, _) => Row(
                      children: [
                        if (searching)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          Icon(
                            loc != null
                                ? Icons.location_on
                                : Icons.location_off,
                            size: 16,
                            color: loc != null
                                ? Colors.lightGreenAccent
                                : Colors.white38,
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            loc != null
                                ? '${loc.label}  (${loc.source})'
                                      '${searching ? ' — improving…' : ''}'
                                : (searching
                                      ? 'Searching for GPS…'
                                      : 'No location set'),
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _search,
              icon: const Icon(Icons.my_location, size: 18),
              label: const Text('Search GPS'),
            ),
            if (prev != null)
              TextButton.icon(
                onPressed: () => Navigator.of(
                  context,
                ).pop(LocationDialogResult(prev.withSource('previous'))),
                icon: const Icon(Icons.history, size: 18),
                label: Text('Use last session\'s: ${prev.label}'),
              ),
            const Divider(),
            const Text(
              'Or type coordinates (decimal degrees):',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _latCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Latitude'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _lonCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Longitude'),
                  ),
                ),
              ],
            ),
            TextButton(
              onPressed: _useManual,
              child: const Text('Use typed coordinates'),
            ),
            if (_hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _hint!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.orangeAccent,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(const LocationDialogResult(null)),
          child: const Text('Remove'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
