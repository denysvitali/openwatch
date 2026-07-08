import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:openwatch/main.dart';

void main() {
  testWidgets('App boots to the scan screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenWatchApp()));
    await tester.pump();
    // Scan hero title (MaterialApp.title is not a rendered Text widget).
    expect(find.text('Connect your watch'), findsOneWidget);
  });
}
