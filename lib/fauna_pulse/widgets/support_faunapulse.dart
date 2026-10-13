// FaunaPulse (round 277, owner): "Support FaunaPulse" on the home screen and
// in the menu, and "Share FaunaPulse".
//
// Donations: Google Play allows a donation link only for a validated
// tax-exempt charity (Payments policy; in 2026 it made AnkiDroid remove even
// its Open Collective link). So the link to the developer's GitHub Sponsors
// page is built in only when asked for:
//   flutter build apk --release --dart-define=DONATION_LINK=true
// for APKs published outside Google Play (GitHub releases). The default, and
// so every Google Play build, has no money link: the box then asks to share
// the app, cite it and report problems (owner choice, round 277).
//
// Share: Android's own share window with a short text and a link (owner
// choice over one button per network: it works with every app installed and
// needs no upkeep).
//
// Round 303 (owner): the menu's "Support FaunaPulse" only repeated Share and
// Report a problem, so the menu now has "Cite FaunaPulse" instead (the box
// stays on the home screen). Citing opens a window in the app with the
// citation of the installed version and a Copy button, as in FaunaLapse: it
// works without internet, and the old link to the README's #citation heading
// did not reliably land there on a phone.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../logging/app_error_hooks.dart';
import '../logging/error_reporter.dart';
import 'dialog_title.dart';
import 'external_link.dart';

/// True only in builds made with `--dart-define=DONATION_LINK=true`.
const kDonationLink = bool.fromEnvironment('DONATION_LINK');

const kSponsorUrl = 'https://github.com/sponsors/valentinitnelav';

/// The concept DOI: it never changes and opens the newest version on Zenodo.
const kConceptDoiUrl = 'https://doi.org/10.5281/zenodo.22309221';

/// The README's citation with the installed [version] (`0.8.0-alpha.1`; none
/// if it could not be read). A test keeps it in step with CITATION.cff.
String citationText(String? version) =>
    'Ștefan, V., Sittinger, M., & Knight, T. (2026). FaunaPulse: a smartphone application for '
    'on-device detection, tracking and identification of animals'
    '${version == null ? '' : ' (Version $version)'} [Software]. Zenodo. $kConceptDoiUrl. '
    'Source code: ${ErrorReporter.githubRepoUrl}';

/// The link people get when FaunaPulse is shared. The GitHub page for now;
/// the Google Play page once the app is public there.
const kShareUrl = ErrorReporter.githubRepoUrl;

const kShareText =
    'FaunaPulse: a free, open-source app that finds, times and identifies insects and other '
    'animals on the phone, without internet. $kShareUrl';

/// Opens the phone's share window with [kShareText].
Future<void> shareFaunaPulse() async {
  try {
    await SharePlus.instance.share(ShareParams(text: kShareText, subject: 'FaunaPulse'));
  } catch (e) {
    logSwallowed('share_app', e);
  }
}

/// The text of the home screen's support box.
String supportText({bool donationLink = kDonationLink}) => donationLink
    ? 'FaunaPulse is open source and stays free for science. It is developed and maintained '
          'from the developer\'s own budget, including the AI coding tools that help build it. '
          'Donations help keep it maintained and its bugs fixed. Sharing it and citing it help too.'
    : 'FaunaPulse is open source and stays free for science. You can help: share it with '
          'others, cite it in your publications, and report problems.';

/// The home screen's "Support FaunaPulse" box.
class SupportFaunaPulseCard extends StatelessWidget {
  /// Opens "Report a problem".
  final VoidCallback onReportProblem;

  /// Tests set it; the app uses [kDonationLink].
  final bool donationLink;

  const SupportFaunaPulseCard({super.key, required this.onReportProblem, this.donationLink = kDonationLink});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
    decoration: BoxDecoration(border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(12)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.volunteer_activism_outlined, size: 20, color: Colors.amber),
            SizedBox(width: 8),
            Flexible(
              child: Text('Support FaunaPulse', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(supportText(donationLink: donationLink), style: const TextStyle(fontSize: 13, color: Colors.white70)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 4,
          children: [
            if (donationLink)
              TextButton.icon(
                onPressed: () => openExternalLink(kSponsorUrl, 'support_sponsor'),
                icon: const Icon(Icons.favorite_outline, size: 18),
                label: const Text('Sponsor on GitHub'),
              ),
            TextButton.icon(
              onPressed: shareFaunaPulse,
              icon: const Icon(Icons.share_outlined, size: 18),
              label: const Text('Share'),
            ),
            TextButton.icon(
              onPressed: () => showCitation(context),
              icon: const Icon(Icons.format_quote_outlined, size: 18),
              label: const Text('Cite this version'),
            ),
            TextButton.icon(
              onPressed: onReportProblem,
              icon: const Icon(Icons.bug_report_outlined, size: 18),
              label: const Text('Report a problem'),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Opens the "Cite FaunaPulse" window with the installed version.
Future<void> showCitation(BuildContext context) async {
  String? version;
  try {
    version = (await PackageInfo.fromPlatform()).version;
  } catch (e) {
    logSwallowed('cite_package_info', e);
  }
  if (!context.mounted) return;
  await showDialog<void>(context: context, builder: (_) => CitationDialog(version: version));
}

/// The citation (selectable), the Zenodo link, and Copy. After Copy the button
/// says "Copied" (Android 13 and newer also confirm a copy themselves; the
/// window stays open, so nothing covers that). The whole window scrolls, so
/// a large system font on a small phone does not cut it off.
class CitationDialog extends StatefulWidget {
  /// The installed version (`0.8.0-alpha.1`); null if it could not be read.
  final String? version;

  const CitationDialog({super.key, this.version});

  @override
  State<CitationDialog> createState() => _CitationDialogState();
}

class _CitationDialogState extends State<CitationDialog> {
  var _copied = false;

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: citationText(widget.version)));
      if (mounted) setState(() => _copied = true);
    } catch (e) {
      logSwallowed('cite_copy', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final version = widget.version;
    void close() => Navigator.of(context).pop();
    return AlertDialog(
      scrollable: true,
      actionsOverflowDirection: VerticalDirection.up,
      title: DialogTitle(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Cite FaunaPulse'),
            if (version != null)
              Text(
                'Version $version, installed on this phone',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
          ],
        ),
        onClose: close,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(citationText(version), style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 12),
          const Text(
            'Please cite the version you used. The DOI link opens the newest version of FaunaPulse on '
            'Zenodo. Its page lists every version: open yours there to see its own DOI or to export its '
            'citation for reference managers.',
            style: TextStyle(fontSize: 13, color: Colors.white70),
          ),
          const SizedBox(height: 8),
          const ExternalLinkText(kConceptDoiUrl, logTag: 'cite_open_doi', fontSize: 13),
        ],
      ),
      // Close first: stacked (VerticalDirection.up), Copy is on top and Close
      // at the bottom (round 289).
      actions: [
        TextButton(onPressed: close, child: const Text('Close')),
        TextButton.icon(
          onPressed: _copy,
          icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
          label: Text(_copied ? 'Copied' : 'Copy'),
        ),
      ],
    );
  }
}
