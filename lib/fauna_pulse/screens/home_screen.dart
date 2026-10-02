// FaunaPulse — entry / welcome screen.
//
// Starts a new recording session, leads to the past sessions, the video
// import, the Find screens and the dashboard.
//
// Round 277 (owner): the past sessions moved to their own Sessions screen
// (search, filters, selecting several to delete). After a phone check the
// owner reshaped the screen, after the Seek app (owner choices from mock-ups):
//   • a bar at the bottom: "Menu" (the side menu that replaced the ⋮ menu),
//     a large round "New session" button raised in the middle, "Dashboard";
//     words under the three icons;
//   • under the app name: "Sessions" (how many are saved);
//   • "Import videos…" for the user's own videos; then the two Find buttons
//     for photos and videos already in the app;
//   • a "Support FaunaPulse" box (widgets/support_faunapulse.dart; no money
//     link in Google Play builds);
//   • no latest-session row (the owner preferred the space for the above).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_error_hooks.dart';
import '../logging/error_reporter.dart';
import '../logging/past_sessions.dart';
import '../models/session_config.dart';
import '../widgets/external_link.dart';
import '../widgets/support_faunapulse.dart';
import 'camera_session_screen.dart';
import 'dashboard_screen.dart';
import 'models_screen.dart';
import 'problem_description_screen.dart';
import 'session_actions.dart';
import 'sessions_screen.dart';

class HomeScreen extends StatefulWidget {
  /// Reads the sessions; tests give their own.
  final Future<List<PastSession>> Function() scan;

  const HomeScreen({super.key, this.scan = scanPastSessions});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SessionActions {
  bool _starting = false;
  bool _loadingSessions = true;
  /// Every session, newest first (counted here; the problem report offers
  /// them).
  List<PastSession> _sessions = const [];

  /// Whether the one-time setup reminder shows at session start. Mirrors the
  /// inverse of the persisted "hide" flag ([kHideSessionInfoPrefKey]); shown
  /// as a check item in the side menu.
  bool _showSetupTips = true;

  @override
  void initState() {
    super.initState();
    reloadSessions();
    _loadSetupTipsPref();
  }

  /// Reads the persisted "hide setup tips" flag so the menu check item
  /// reflects the current state.
  Future<void> _loadSetupTipsPref() async {
    final prefs = await SharedPreferences.getInstance();
    final hidden = prefs.getBool(kHideSessionInfoPrefKey) ?? false;
    if (!mounted) return;
    setState(() => _showSetupTips = !hidden);
  }

  /// Turns the one-time setup reminder on/off by writing the persisted flag.
  /// On = reminder shows next time a session screen opens; Off = stays hidden.
  Future<void> _toggleSetupTips() async {
    setState(() => _showSetupTips = !_showSetupTips);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kHideSessionInfoPrefKey, !_showSetupTips);
  }

  @override
  Future<void> reloadSessions() async {
    final found = await widget.scan();
    if (!mounted) return;
    setState(() {
      _sessions = found;
      _loadingSessions = false;
    });
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => _starting = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission is required.')),
        );
      }
      return;
    }
    final config = await SessionConfig.load();
    if (!mounted) return;
    setState(() => _starting = false);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CameraSessionScreen(initialConfig: config),
      ),
    );
    // A new session may have been recorded; refresh on return.
    await reloadSessions();
  }

  /// Builds a diagnostic report from outside a session (e.g. after a crash and
  /// restart): the last-used settings, the most recent session log if any, and
  /// the app's recent technical log. Saves it locally and offers to send it.
  Future<void> _reportProblem() async {
    // Ask the user to describe the problem first (required; screenshots
    // optional since round 190; the session whose data rides along is the
    // user's visible choice since round 191 — newest preselected).
    // Cancelling aborts.
    final input = await showProblemDescriptionEditor(
      context,
      sessions: [
        for (final s in _sessions) (name: s.name, logPath: s.logFile.path),
      ],
    );
    if (input == null || !mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    ErrorReport? report;
    try {
      final config = await SessionConfig.load();
      final pickedLog = input.sessionLogPath == null
          ? null
          : File(input.sessionLogPath!);
      report = await ErrorReporter.build(
        trigger: 'User-initiated report (Report a problem)',
        userDescription: input.description,
        config: config,
        sessionLog: pickedLog,
        attachmentPaths: input.screenshotPaths,
      );
    } catch (e) {
      logSwallowed('error_report_build', e);
      report = null;
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // dismiss spinner
    if (report == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not create the report.')),
      );
      return;
    }
    final saved = report;
    // Round 190 (owner decision): no email option here anymore — the share
    // sheet and the GitHub issue link are the offered channels (the dormant
    // email plumbing stays in ErrorReporter for a possible revival).
    final share = await showDialog<bool>(
      context: context,
      builder: (_) => ReportSavedDialog(report: saved),
    );
    if (share == true && mounted) await ErrorReporter.share(saved);
  }

  /// The About dialog (round 183; replaced the landing-screen tagline): a
  /// condensed version of the README's Overview, the app version (from the
  /// build, so it can never drift) and a link to the public GitHub
  /// repository. Round 184: a custom dialog instead of `showAboutDialog` —
  /// its mandatory "View licenses" button drowned the About in hundreds of
  /// framework/package entries (owner feedback). The app's OWN license
  /// (AGPL-3.0) is stated directly. Round 189 (owner decision): the muted
  /// "Third-party licenses" action (Flutter's auto-generated LicensePage)
  /// was removed too. Round 193 (owner decision, for the store release):
  /// the action is BACK, as a muted TextButton: several bundled
  /// BSD/MIT/Apache packages require their license text to accompany the
  /// distributed binary, and the auto-generated page is the zero-maintenance
  /// way to satisfy that. It stays discreet: the page opens only on demand
  /// and its header warns that the list is long.
  Future<void> _showAbout() async {
    PackageInfo? info;
    try {
      info = await PackageInfo.fromPlatform();
    } catch (e) {
      logSwallowed('about_package_info', e);
    }
    if (!mounted) return;
    final version = info != null
        ? 'v${info.version} (build ${info.buildNumber})'
        : null;
    await showDialog<void>(
      context: context,
      builder: (_) => AboutFaunaPulseDialog(version: version),
    );
  }

  /// The menu's "Support FaunaPulse": the home screen's box in a dialog.
  Future<void> _showSupport() => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      content: SingleChildScrollView(
        child: SupportFaunaPulseCard(
          framed: false,
          onReportProblem: () {
            Navigator.of(ctx).pop();
            _reportProblem();
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))],
    ),
  );

  Future<void> _openSessions() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SessionsScreen()));
    await reloadSessions();
  }

  Future<void> _openDashboard() =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DashboardScreen()));

  final _scaffold = GlobalKey<ScaffoldState>();

  /// The side menu, opened with "Menu" at the bottom left (round 277, owner;
  /// was the ⋮ menu at the top right): Download & import models first, About
  /// FaunaPulse last.
  Widget _drawer() {
    Widget item(IconData icon, String text, VoidCallback onTap) => ListTile(
      leading: Icon(icon),
      title: Text(text),
      onTap: () {
        Navigator.of(context).pop(); // the menu
        onTap();
      },
    );
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 20, 16, 16),
              child: Row(
                children: [
                  Icon(Icons.emoji_nature, size: 36, color: Colors.amber),
                  SizedBox(width: 12),
                  Text('FaunaPulse', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const Divider(height: 1),
            item(Icons.download, 'Download & import models', () => openModelsScreen(context)),
            // An explicit check box (round 184): a blank space for "off"
            // left the owner unsure whether the option was on. The menu stays
            // open, so the tick is seen to change.
            ListTile(
              leading: Icon(
                _showSetupTips ? Icons.check_box : Icons.check_box_outline_blank,
                color: _showSetupTips ? Colors.lightBlueAccent : Colors.white54,
              ),
              title: const Text('Show setup tips at session start'),
              onTap: _toggleSetupTips,
            ),
            // Round 190 (owner request): always reachable, also after a crash
            // and restart.
            item(Icons.bug_report_outlined, 'Report a problem', _reportProblem),
            const Divider(height: 1),
            item(Icons.share_outlined, 'Share FaunaPulse', shareFaunaPulse),
            item(Icons.volunteer_activism_outlined, 'Support FaunaPulse', _showSupport),
            item(Icons.info_outline, 'About FaunaPulse', _showAbout),
          ],
        ),
      ),
    );
  }

  /// The large round button raised in the middle of the bottom bar.
  Widget _newSessionButton() => SizedBox(
    width: 72,
    height: 72,
    child: FloatingActionButton(
      heroTag: 'home_new_session',
      tooltip: 'New session',
      shape: const CircleBorder(),
      onPressed: _starting ? null : _start,
      child: _starting
          ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3))
          : const Icon(Icons.videocam, size: 36),
    ),
  );

  Widget _bottomBar() => BottomAppBar(
    height: 76,
    padding: EdgeInsets.zero,
    child: Row(
      children: [
        Expanded(
          child: _BarItem(icon: Icons.menu, label: 'Menu', onTap: () => _scaffold.currentState?.openDrawer()),
        ),
        // The word under the raised button; tapping it starts too.
        Expanded(
          child: InkWell(
            onTap: _starting ? null : _start,
            child: const Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text(
                  'New session',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
        Expanded(child: _BarItem(icon: Icons.insights, label: 'Dashboard', onTap: _openDashboard)),
      ],
    ),
  );

  Widget _sectionText(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: const TextStyle(fontSize: 13, color: Colors.white70)),
  );

  @override
  Widget build(BuildContext context) {
    final n = _sessions.length;
    return Scaffold(
      key: _scaffold,
      drawer: _drawer(),
      floatingActionButton: _newSessionButton(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: _bottomBar(),
      body: SafeArea(
        bottom: false, // the bottom bar keeps clear of the system bar
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: RefreshIndicator(
              onRefresh: reloadSessions,
              child: ListView(
                // Room at the end for the raised New session button.
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 48),
                children: [
                  // One nature icon only (round 183): a camera icon beside
                  // it read as a "take a photo" button.
                  const Icon(Icons.emoji_nature, size: 56, color: Colors.amber),
                  const SizedBox(height: 8),
                  const Text(
                    'FaunaPulse',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 20),
                  _SessionsButton(
                    subtitle: _loadingSessions
                        ? '…'
                        : n == 0
                        ? 'None yet'
                        : '$n saved',
                    onTap: _openSessions,
                  ),
                  const SizedBox(height: 24),
                  _sectionText('Have your own videos? Import them to find, track and identify the animals in them.'),
                  OutlinedButton.icon(
                    onPressed: () => importVideos(),
                    icon: const Icon(Icons.video_library_outlined, size: 18),
                    label: const Text('Import videos…'),
                  ),
                  const SizedBox(height: 24),
                  _sectionText(
                    'Photos and videos already in FaunaPulse (from time-lapse or motion sessions, or '
                    'imported):',
                  ),
                  // Round 135: a (bigger) detector over saved photos, no
                  // camera, no time limit.
                  OutlinedButton.icon(
                    onPressed: () => openAnalysis(),
                    icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                    label: const Text('Find animals in photos'),
                  ),
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    onPressed: () => openVideoAnalysis(),
                    icon: const Icon(Icons.movie_filter_outlined, size: 18),
                    label: const Text('Find animals in videos'),
                  ),
                  const SizedBox(height: 28),
                  SupportFaunaPulseCard(onReportProblem: _reportProblem),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An icon with its word under it, in the bottom bar.
class _BarItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _BarItem({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 26),
        const SizedBox(height: 4),
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );
}

/// The wide "Sessions" button under the app name.
class _SessionsButton extends StatelessWidget {
  final String subtitle;
  final VoidCallback onTap;

  const _SessionsButton({required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onTap,
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    child: Row(
      children: [
        const Icon(Icons.history, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Sessions', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
          ),
        ),
        const Icon(Icons.chevron_right),
      ],
    ),
  );
}

/// Shown after a problem report is written to disk: where it landed (with
/// any screenshot copies), the GitHub issue link and the share action.
/// Pops true to open the share sheet, null/false for "Done" (keep the file,
/// send nothing). Round 190: the developer-email field and "Email…" action
/// are gone (owner decision — don't encourage emailed reports); with no
/// TextEditingController left this is a plain StatelessWidget again.
class ReportSavedDialog extends StatelessWidget {
  final ErrorReport report;
  const ReportSavedDialog({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final zip = report.bundleZip;
    final shots = report.attachments.length;
    final samples = report.bundledNames.length - shots;
    // Round 191: with screenshots/session samples everything is zipped into
    // ONE shareable file (multi-file mixed-type shares were dropped whole
    // by some targets — owner's WhatsApp test).
    final bundleNote = zip == null
        ? ''
        : 'Share sends everything as one bundle '
              '(${zip.uri.pathSegments.last}: the report'
              '${shots > 0 ? ' + $shots screenshot${shots == 1 ? '' : 's'}' : ''}'
              '${samples > 0 ? ' + $samples session file sample${samples == 1 ? '' : 's'}' : ''}). ';
    return AlertDialog(
      title: const Text('Report saved'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Saved a ${report.humanSize} report to:\n\n'
            '${report.file.path}\n\n'
            '$bundleNote'
            'You can send it now, or find it later over USB.',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 10),
          // Round 189 (owner request): the public issue tracker as the
          // suggested channel — open an issue and paste the report's text.
          InkWell(
            onTap: () => openExternalLink(ErrorReporter.githubIssuesUrl, 'report_open_issues'),
            child: const Text.rich(
              TextSpan(
                style: TextStyle(fontSize: 12, color: Colors.white54),
                children: [
                  TextSpan(
                    text: 'You can also open a GitHub issue (and paste the '
                        'report\'s text there): ',
                  ),
                  TextSpan(
                    text: ErrorReporter.githubIssuesUrl,
                    style: TextStyle(color: Colors.lightBlueAccent),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text(
            'Share…',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}

/// The menu's About dialog content (extracted as a public widget in round
/// 193 so it can be widget-tested standalone, like [DeleteAllSessionsDialog]).
/// [version] is the display string from the build (null when PackageInfo
/// failed). The "Third-party licenses" action PUSHES the auto-generated
/// LicensePage on top of this dialog (no pop, backing out of the long list
/// returns here).
class AboutFaunaPulseDialog extends StatelessWidget {
  final String? version;
  const AboutFaunaPulseDialog({super.key, this.version});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.emoji_nature, size: 32, color: Colors.amber),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('FaunaPulse'),
              if (version != null)
                Text(
                  version!,
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
            ],
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'A passive, non-invasive field tool that turns a smartphone '
              'into an AI-powered wildlife camera. Place the square region '
              'of interest over a flower, feeding site or nest entrance. '
              'In live detection mode, FaunaPulse detects, tracks and photographs visiting animals '
              'fully on-device (no internet needed) and logs every track ID '
              'with timestamps, so visitation rates can be computed afterwards. '
              'Other features include: motion-triggered photos, time-lapse capture '
              '(photo or video bursts), scheduled multi-hour or multi-day runs, finding animals afterwards '
              'in saved photos or videos, and naming them (identification).',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 14),
            InkWell(
              onTap: () => openExternalLink(ErrorReporter.githubRepoUrl, 'about_open_github'),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.code, size: 18, color: Colors.lightBlueAccent),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'github.com/valentinitnelav/fauna-pulse',
                      style: TextStyle(
                        color: Colors.lightBlueAccent,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Open source under the AGPL-3.0 license (full text in the '
              'repository).',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            showLicensePage(
              context: context,
              applicationName: 'FaunaPulse',
              applicationVersion: version,
              applicationLegalese:
                  'FaunaPulse itself is AGPL-3.0. Below is the '
                  'auto-generated license text of every third-party '
                  'package bundled in the app (a long list).',
            );
          },
          child: const Text(
            'Third-party licenses',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
