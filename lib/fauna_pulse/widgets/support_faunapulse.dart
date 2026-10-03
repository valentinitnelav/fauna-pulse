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

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../logging/app_error_hooks.dart';
import '../logging/error_reporter.dart';
import 'dialog_title.dart';
import 'external_link.dart';

/// True only in builds made with `--dart-define=DONATION_LINK=true`.
const kDonationLink = bool.fromEnvironment('DONATION_LINK');

const kSponsorUrl = 'https://github.com/sponsors/valentinitnelav';

/// The README's citation section (the authors keep CITATION.cff current).
const kCitationUrl = '${ErrorReporter.githubRepoUrl}#citation';

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

/// The text of the support box and dialog.
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

  /// A frame on the home screen; none inside the menu's dialog.
  final bool framed;

  const SupportFaunaPulseCard({
    super.key,
    required this.onReportProblem,
    this.donationLink = kDonationLink,
    this.framed = true,
    this.onClose,
  });

  /// In a window: its X at the right of the heading (round 289).
  final VoidCallback? onClose;

  static const _heading = Row(
    children: [
      Icon(Icons.volunteer_activism_outlined, size: 20, color: Colors.amber),
      SizedBox(width: 8),
      Flexible(
        child: Text('Support FaunaPulse', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
    decoration: framed
        ? BoxDecoration(border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(12))
        : null,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onClose case final close?) DialogTitle(_heading, onClose: close) else _heading,
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
              onPressed: () => openExternalLink(kCitationUrl, 'support_cite'),
              icon: const Icon(Icons.format_quote_outlined, size: 18),
              label: const Text('How to cite'),
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
