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
//
// Round 278 (owner): the page leads a first-time user step by step, like a
// wizard that stays on the screen: 1 AI models (what is on the phone, and
// "What do you want to watch?": pollinators on flowers, insects on a flat
// surface, mammals and birds, other models; each answer opens a page with the
// suggested models, screens/watch_plan_screen.dart), 2 Record, 3 Or use your
// own videos, 4 Find and name the animals. Sessions and the models moved into
// the bottom bar (Menu, Sessions | New session | Dashboard, AI models), so
// they are one tap away without scrolling. A quiet scroll bar shows that the
// page goes on below (widgets/scroll_hint.dart).
//
// Round 279 (owner, after a test user's first try on the owner's phone):
//   • step 1 says what was set up ("Set up for: Pollinators on flowers" and
//     the chosen file names, read back from the saved choices), and before a
//     choice that FaunaPulse suggests the models to download; no step gets a
//     tick any more (users can always add models);
//   • shorter step texts, and a small drawing of the yellow square in step 2
//     (the area FaunaPulse watches; "square" alone meant nothing to the user).
// Round 280 (owner): step 1 also says what is missing from a choice ("Name:
// none", or "Find: none" and what naming can still do), and step 2 shows the
// phone screen of the answer chosen last (roi_<icon>.png).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../identification/identification_store.dart' show stemOf;
import '../logging/app_error_hooks.dart';
import '../logging/error_reporter.dart';
import '../logging/past_sessions.dart';
import '../models/model_downloads.dart';
import '../models/models_on_phone.dart';
import '../models/session_config.dart';
import '../perf/slow_phone_hint.dart' show kHideSlowPhoneHintPrefKey;
import '../widgets/external_link.dart';
import '../widgets/scroll_hint.dart';
import '../widgets/support_faunapulse.dart';
import '../widgets/watch_tiles.dart';
import 'camera_session_screen.dart';
import 'dashboard_screen.dart';
import 'models_screen.dart';
import 'problem_description_screen.dart';
import 'session_actions.dart';
import 'sessions_screen.dart';
import 'watch_plan_screen.dart';

/// The answer to "What do you want to watch?" whose models were chosen last
/// (its tile is marked; written when its page saved the choice).
const kHomeWatchUsePref = 'home_watch_use';

class HomeScreen extends StatefulWidget {
  /// Reads the sessions; tests give their own.
  final Future<List<PastSession>> Function() scan;

  /// Counts the models on the phone; tests give their own.
  final Future<ModelsOnPhone> Function() countModels;

  /// Reads the download list (its `uses`); tests give their own.
  final Future<ModelDownloads> Function() loadDownloads;

  /// The model file names on the phone, for the "watch" pages; tests give
  /// their own.
  final Future<Set<String>> Function() modelNames;

  /// Reads the chosen models back (step 1); tests give their own.
  final Future<ModelChoice> Function(Set<String> onPhone) modelChoice;

  const HomeScreen({
    super.key,
    this.scan = scanPastSessions,
    this.countModels = ModelsOnPhone.count,
    this.loadDownloads = ModelDownloads.load,
    this.modelNames = modelFileNamesOnPhone,
    this.modelChoice = currentModelChoice,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SessionActions {
  bool _starting = false;

  /// Every session, newest first (counted here; the problem report offers
  /// them).
  List<PastSession> _sessions = const [];

  /// Whether the one-time setup reminder shows at session start. Mirrors the
  /// inverse of the persisted "hide" flag ([kHideSessionInfoPrefKey]); shown
  /// as a check item in the side menu.
  bool _showSetupTips = true;

  /// Null while counting.
  ModelsOnPhone? _models;

  /// The models chosen for new sessions and Identify (null while reading).
  ModelChoice? _choice;

  /// The answers to "What do you want to watch?" (the download list's `uses`).
  List<WatchUse> _uses = const [];
  String? _watchUse;

  final _list = ScrollController();

  @override
  void initState() {
    super.initState();
    reloadSessions();
    _reloadModels();
    _loadSetupTipsPref();
    _loadUses();
  }

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  Future<void> _reloadModels() async {
    final m = await widget.countModels();
    final choice = await widget.modelChoice(await widget.modelNames());
    if (!mounted) return;
    setState(() {
      _models = m;
      _choice = choice;
    });
  }

  Future<void> _loadUses() async {
    final d = await widget.loadDownloads();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _uses = d.uses;
      _watchUse = prefs.getString(kHomeWatchUsePref);
    });
  }

  /// Opens the suggested models of [use]; back with them, the user is
  /// pointed at New session.
  Future<void> _openWatch(WatchUse use) async {
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => WatchPlanScreen(use: use, onPhone: widget.modelNames)));
    if (done == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kHomeWatchUsePref, use.id);
      if (mounted) setState(() => _watchUse = use.id);
    }
    await _reloadModels();
    if (done == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Done. Press New session to start.')));
    }
  }

  Future<void> _openModels() async {
    await openModelsScreen(context);
    await _reloadModels();
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
  /// Round 278: turning it on also brings back the slow-phone hint after its
  /// "Don't show again" (the only way back to it).
  Future<void> _toggleSetupTips() async {
    setState(() => _showSetupTips = !_showSetupTips);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kHideSessionInfoPrefKey, !_showSetupTips);
    if (_showSetupTips) await prefs.remove(kHideSlowPhoneHintPrefKey);
  }

  @override
  Future<void> reloadSessions() async {
    final found = await widget.scan();
    if (!mounted) return;
    setState(() => _sessions = found);
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
    // A new session may have been recorded (and a model downloaded from the
    // camera's question); refresh on return.
    await reloadSessions();
    await _reloadModels();
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
            item(Icons.download, 'Download & import models', _openModels),
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

  /// Menu, Sessions | New session (the word under the raised button) |
  /// Dashboard, AI models. The middle is a bit wider, for "New session".
  Widget _bottomBar() => BottomAppBar(
    height: 76,
    padding: EdgeInsets.zero,
    child: Row(
      children: [
        Expanded(
          flex: 4,
          child: _BarItem(icon: Icons.menu, label: 'Menu', onTap: () => _scaffold.currentState?.openDrawer()),
        ),
        Expanded(flex: 4, child: _BarItem(icon: Icons.history, label: 'Sessions', onTap: _openSessions)),
        // The word under the raised button; tapping it starts too.
        Expanded(
          flex: 5,
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
        Expanded(flex: 4, child: _BarItem(icon: Icons.insights, label: 'Dashboard', onTap: _openDashboard)),
        Expanded(flex: 4, child: _BarItem(icon: Icons.download, label: 'AI models', onTap: _openModels)),
      ],
    ),
  );

  Widget _sectionText(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: const TextStyle(fontSize: 13, color: Colors.white70)),
  );

  /// "Find: file" in step 1.
  Widget _fileLine(String label, String file) => Text.rich(
    TextSpan(
      children: [
        TextSpan(text: '$label: ', style: const TextStyle(color: Colors.white60)),
        TextSpan(text: file),
      ],
    ),
    style: const TextStyle(fontSize: 13),
  );

  /// What step 1 shows once models are chosen: the answer they were set up
  /// for (when the camera still uses one of its suggestions) and the files,
  /// or what works without the missing kind (round 280).
  Widget _chosenModels(WatchUse? use, ModelChoice c) {
    final detector = c.detector, idModel = c.idModel, list = c.nameList;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            use == null ? 'Chosen AI models' : 'Set up for: ${use.title}',
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          _fileLine('Find', detector ?? 'none (naming works only where animals were already found)'),
          _fileLine(
            'Name',
            idModel == null || list == null
                ? 'none ($kNoNamingNote)'
                // A class list has its model's name: nothing more to say.
                : stemOf(list) == stemOf(idModel)
                ? idModel
                : '$idModel with $list',
          ),
        ],
      ),
    );
  }

  /// The answer whose phone screen step 2 shows: the one chosen last, or
  /// pollinators (the main use).
  String get _stepTwoIcon {
    for (final u in _uses) {
      if (u.id == _watchUse) return u.icon;
    }
    return 'pollinators';
  }

  /// Step 1: the models on the phone, and "What do you want to watch?".
  Widget _modelsStep() {
    final m = _models;
    final none = m != null && m.none;
    final choice = _choice;
    final detector = choice?.detector;
    final chosen = detector != null || choice?.idModel != null;
    WatchUse? setUpFor;
    for (final u in _uses) {
      if (detector != null && u.id == _watchUse && u.find.any((d) => d.file?.name == detector)) setUpFor = u;
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        border: Border.all(color: none ? Colors.amber : Colors.white24),
        borderRadius: BorderRadius.circular(12),
      ),
      child: _Step(
        number: 1,
        title: 'AI models',
        children: [
          if (m != null)
            if (none)
              _sectionText(
                'FaunaPulse needs AI models: files that teach it to find animals in the picture and to '
                'name them. They are free.',
              )
            else if (chosen)
              _chosenModels(setUpFor, choice!)
            else
              _sectionText(m.summary),
          const Text('What do you want to watch?', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          if (m != null && !chosen)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                none
                    ? 'Tap one: FaunaPulse suggests which AI models to download.'
                    : 'Tap one: FaunaPulse suggests the AI models for it.',
                style: const TextStyle(fontSize: 12.5, color: Colors.white60),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final u in _uses)
                Expanded(
                  child: WatchTile(
                    icon: u.icon,
                    label: u.title,
                    selected: u == setUpFor,
                    onTap: () => _openWatch(u),
                  ),
                ),
              Expanded(
                child: WatchTile(icon: kOtherModelsIcon, label: 'Other models', onTap: _openModels),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffold,
      drawer: _drawer(),
      floatingActionButton: _newSessionButton(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: _bottomBar(),
      body: SafeArea(
        bottom: false, // the bottom bar keeps clear of the system bar
        child: ScrollHint(
          controller: _list,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: RefreshIndicator(
                onRefresh: () async {
                  await reloadSessions();
                  await _reloadModels();
                },
                child: ListView(
                  controller: _list,
                  // Room at the end for the raised New session button.
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 48),
                  children: [
                    // One nature icon only (round 183): a camera icon beside
                    // it read as a "take a photo" button.
                    const Icon(Icons.emoji_nature, size: 56, color: Colors.amber),
                    const SizedBox(height: 6),
                    const Text(
                      'FaunaPulse',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Find, follow and name animals with your phone',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: Colors.white70),
                    ),
                    const SizedBox(height: 20),
                    _modelsStep(),
                    const SizedBox(height: 20),
                    _Step(
                      number: 2,
                      title: 'Record',
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _sectionText(
                                'Press New session below. Fix the phone steady and move the yellow square over '
                                'the place to watch: FaunaPulse looks for animals only inside it. On a phone too '
                                'slow for live detection, the camera suggests time-lapse instead.',
                              ),
                            ),
                            const SizedBox(width: 10),
                            Image.asset(
                              roiPicture(_stepTwoIcon),
                              height: 120,
                              semanticLabel: roiDescription(_stepTwoIcon),
                              errorBuilder: (context, error, stack) => const SizedBox.shrink(),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _Step(
                      number: 3,
                      title: 'Or use your own videos',
                      children: [
                        _sectionText('Import videos from the phone to find and name the animals in them.'),
                        OutlinedButton.icon(
                          onPressed: () => importVideos(),
                          icon: const Icon(Icons.video_library_outlined, size: 18),
                          label: const Text('Import videos…'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _Step(
                      number: 4,
                      title: 'Find and name the animals',
                      children: [
                        _sectionText(
                          'In photos and videos already in FaunaPulse. With an identification model, finding '
                          'also names them.',
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
                      ],
                    ),
                    const SizedBox(height: 28),
                    SupportFaunaPulseCard(onReportProblem: _reportProblem),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One numbered step of the home screen: the number in a circle (always: a
/// tick for step 1 confused, round 279), the title, then [children].
class _Step extends StatelessWidget {
  final int number;
  final String title;
  final List<Widget> children;

  const _Step({required this.number, required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 1.5)),
          child: Text('$number', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 3, bottom: 6),
                child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              ...children,
            ],
          ),
        ),
      ],
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
            // Round 278 (owner): for a broad audience, and naming the
            // animals (identification on the phone) said plainly.
            const Text(
              'FaunaPulse turns a phone into a camera that watches animals for you: for example insects '
              'visiting a flower, or birds and mammals at a feeding site.\n\n'
              'With AI models (free files you download or import in the app), FaunaPulse can:\n'
              '• find the animals in the picture and follow each one while it stays, live or later in '
              'saved photos and videos;\n'
              '• name them: an identification model on the phone suggests the group or species of each '
              'animal;\n'
              '• record when each visit starts and ends, so you can count visits and see how long they '
              'last.\n\n'
              'Everything runs on the phone. No internet is needed in the field, and your photos and '
              'videos stay on your phone.\n\n'
              'It can also take photos when something moves, take time-lapse photos or videos, run for '
              'hours or days on a schedule, and work with videos from the phone\'s camera app.\n\n'
              'The AI models are made by research teams and keep their own licences (see Download & '
              'import models).',
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
