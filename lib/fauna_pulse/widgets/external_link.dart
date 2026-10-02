// FaunaPulse (round 277): open a web page in the phone's browser, the one way
// the app does it (GitHub links on the home screen and the problem report,
// a model's source in its card on Download & import models).

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../logging/app_error_hooks.dart';

/// Opens [url] in the browser; a failure is logged under [logTag], not shown.
Future<void> openExternalLink(String url, String logTag) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (e) {
    logSwallowed(logTag, e);
  }
}

/// [url] shown as a link (blue, underlined) that opens it when tapped.
class ExternalLinkText extends StatelessWidget {
  final String url;
  final String logTag;
  final double fontSize;

  const ExternalLinkText(this.url, {super.key, required this.logTag, this.fontSize = 14});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => openExternalLink(url, logTag),
    child: Text(
      url,
      style: TextStyle(
        fontSize: fontSize,
        color: Colors.lightBlueAccent,
        decoration: TextDecoration.underline,
        decorationColor: Colors.lightBlueAccent,
      ),
    ),
  );
}
