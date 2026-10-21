// Widget test for the "Report ready" window (ReportSavedDialog).
//
// Round 317: reports live in internal app storage (no USB access, and no
// screen lists old reports), so the window must not show the file path or
// promise that the report can be fetched later; Share is the way out.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/logging/error_reporter.dart';
import 'package:fauna_pulse/fauna_pulse/screens/home_screen.dart';

void main() {
  testWidgets('Report ready says to share now, with no path or USB promise', (tester) async {
    const path = '/data/user/0/app/files/error_reports/report_x.txt';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportSavedDialog(report: ErrorReport(file: File(path), sizeBytes: 2048)),
        ),
      ),
    );
    expect(find.text('Report ready'), findsOneWidget);
    expect(find.textContaining('The report is ready'), findsOneWidget);
    expect(find.textContaining('Tap Share… to send it now'), findsOneWidget);
    expect(find.textContaining('USB'), findsNothing);
    expect(find.textContaining(path), findsNothing);
    expect(find.text('Share…'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });
}
