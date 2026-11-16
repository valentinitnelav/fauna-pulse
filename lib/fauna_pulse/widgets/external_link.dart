// FaunaPulse (round 277): open a web page in the phone's browser, the one way
// the app does it (GitHub links on the home screen and the problem report,
// a model's source in its card on Download & import models).
// Round 378: a web search for the name of an organism ([searchTheWeb]).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// The channel of the app's calls that open another app (native side: MainActivity).
const _channel = MethodChannel('faunapulse/keepalive');

/// Searches the web for [query] with Android's own web-search request (native `webSearch`):
/// the phone opens the search app or browser its user chose, so FaunaPulse names no search
/// engine. Only when no app answers, the search opens as a DuckDuckGo address in the browser
/// (a web address has to name a search engine; this one does not follow its users).
Future<void> searchTheWeb(String query) async {
  try {
    if (await _channel.invokeMethod<bool>('webSearch', {'query': query}) == true) return;
  } catch (e) {
    logSwallowed('web_search', e);
  }
  await openExternalLink(Uri.https('duckduckgo.com', '/', {'q': query}).toString(), 'web_search');
}

TextStyle _linkStyle(double fontSize) => TextStyle(
  fontSize: fontSize,
  color: Colors.lightBlueAccent,
  decoration: TextDecoration.underline,
  decorationColor: Colors.lightBlueAccent,
);

/// [url] shown as a link (blue, underlined) that opens it when tapped.
class ExternalLinkText extends StatelessWidget {
  final String url;
  final String logTag;
  final double fontSize;

  /// The text shown instead of the address (round 324: the FaunaPulse pages
  /// on Hugging Face, whose addresses say little to a user).
  final String? label;

  const ExternalLinkText(this.url, {super.key, required this.logTag, this.fontSize = 14, this.label});

  @override
  Widget build(BuildContext context) =>
      InkWell(onTap: () => openExternalLink(url, logTag), child: Text(label ?? url, style: _linkStyle(fontSize)));
}

/// A link that searches the web for [name] ([searchTheWeb]).
class WebSearchLink extends StatelessWidget {
  final String name;
  final double fontSize;

  const WebSearchLink(this.name, {super.key, this.fontSize = 14});

  @override
  Widget build(BuildContext context) =>
      InkWell(onTap: () => searchTheWeb(name), child: Text('Search the web for $name', style: _linkStyle(fontSize)));
}
