// FaunaPulse (round 277): one row of a past session, on the Sessions screen
// and as the home screen's "Latest session". Owner choice (round 277): an
// icon at the start says how the session was recorded, the actions sit
// behind ⋮ at the end (they were behind a gear at the start since round 182),
// and the row tap opens the session. While sessions are being selected the
// icon becomes a tick box and the ⋮ is hidden.

import 'package:flutter/material.dart';

import '../logging/device_storage.dart';
import '../logging/past_sessions.dart';

/// What the ⋮ menu of a session row offers.
enum SessionAction { rename, exportPhotos, analyze, identify, delete }

/// The icon of each recording kind (live detection uses the detection
/// model icon of Download & import models).
IconData recordingKindIcon(RecordingKind kind) => switch (kind) {
  RecordingKind.liveDetection => Icons.center_focus_strong_outlined,
  RecordingKind.motion => Icons.motion_photos_on_outlined,
  RecordingKind.timeLapse => Icons.timelapse,
  RecordingKind.importedVideos => Icons.video_library_outlined,
};

/// A session length in the unit that fits: mm:ss under an hour, hh:mm:ss up
/// to a day, dd:hh:mm:ss beyond (sessions can run for days). Same style as
/// the live REC clock.
String formatSessionDuration(Duration d) {
  final total = d.inSeconds;
  final days = total ~/ 86400;
  final h = (total % 86400) ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  if (days > 0) return '${two(days)}:${two(h)}:${two(m)}:${two(s)}';
  if (h > 0) return '${two(h)}:${two(m)}:${two(s)}';
  return '${two(m)}:${two(s)}';
}

String _two(int v) => v.toString().padLeft(2, '0');

/// The calendar date, e.g. `2026-06-22`.
String sessionDate(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// The time of day, `hh:mm:ss`.
String sessionTime(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

class SessionTile extends StatelessWidget {
  final PastSession session;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// The ⋮ menu's choice; null hides the ⋮.
  final ValueChanged<SessionAction>? onAction;

  /// Non-null while sessions are being selected: whether this one is.
  final bool? selected;

  const SessionTile({
    super.key,
    required this.session,
    required this.onTap,
    this.onLongPress,
    this.onAction,
    this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final s = session;
    return ListTile(
      selected: selected == true,
      selectedTileColor: Colors.lightBlueAccent.withValues(alpha: 0.12),
      leading: selected != null
          ? Checkbox(value: selected, onChanged: (_) => onTap())
          : Tooltip(
              message: s.kind.label,
              child: Icon(recordingKindIcon(s.kind), color: Colors.amber),
            ),
      title: Row(
        children: [
          Flexible(child: Text(s.name, overflow: TextOverflow.ellipsis)),
          if (s.hasAnalysis)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Tooltip(
                message: '"Find animals" results exist',
                child: Icon(Icons.auto_awesome, size: 14, color: Colors.lightBlueAccent),
              ),
            ),
          if (s.hasIdentification)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Tooltip(
                message: 'Identification results exist',
                child: Icon(Icons.biotech, size: 14, color: Colors.greenAccent),
              ),
            ),
        ],
      ),
      // Two compact lines under the name: the date with the folder's size on
      // the right, then the start → end times with a duration pill.
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    sessionDate(s.start),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                const Icon(Icons.sd_storage_outlined, size: 13, color: Colors.white38),
                const SizedBox(width: 4),
                Text(
                  formatBytes(s.sizeBytes),
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.schedule, size: 13, color: Colors.white38),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    // "14:30:05 → 15:42:11"; "—" when there is no end record.
                    '${sessionTime(s.start)} → ${s.end != null ? sessionTime(s.end!) : '—'}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _DurationPill(s.duration),
              ],
            ),
          ],
        ),
      ),
      trailing: onAction == null || selected != null ? null : _menu(s),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  Widget _menu(PastSession s) {
    PopupMenuItem<SessionAction> item(SessionAction a, IconData icon, String text, {Color? color}) => PopupMenuItem(
      value: a,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: color),
        title: Text(text, style: color == null ? null : TextStyle(color: color)),
      ),
    );
    return PopupMenuButton<SessionAction>(
      icon: const Icon(Icons.more_vert),
      tooltip: 'Session actions',
      onSelected: onAction,
      itemBuilder: (_) => [
        item(SessionAction.rename, Icons.drive_file_rename_outline, 'Rename session'),
        item(SessionAction.exportPhotos, Icons.photo_library_outlined, 'Copy photos to Gallery'),
        item(
          SessionAction.analyze,
          Icons.auto_awesome_outlined,
          s.hasVideos ? 'Find animals in videos' : 'Find animals in photos',
        ),
        item(SessionAction.identify, Icons.biotech_outlined, 'Identify organisms'),
        item(SessionAction.delete, Icons.delete_forever, 'Delete session', color: Colors.red),
      ],
    );
  }
}

/// The session length in a small rounded pill: amber with a timer for a
/// session with an end record, orange with a warning and "incomplete" when
/// it has none (a crash or a forced stop).
class _DurationPill extends StatelessWidget {
  final Duration? duration;
  const _DurationPill(this.duration);

  @override
  Widget build(BuildContext context) {
    final complete = duration != null;
    final color = complete ? Colors.amber : Colors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(complete ? Icons.timer_outlined : Icons.warning_amber_rounded, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            complete ? formatSessionDuration(duration!) : 'incomplete',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
