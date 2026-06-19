import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:openwatch/main.dart';

void main() {
  testWidgets('App boots to the scan screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenWatchApp()));
    await tester.pump();
    expect(find.text('OpenWatch'), findsOneWidget);
  });
}
