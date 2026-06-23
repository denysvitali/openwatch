import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/services/history_sync.dart';
import 'package:openwatch/features/history/widgets/hr_chart.dart';

void main() {
  testWidgets('HrLineChart does not expose future samples via selection', (
    tester,
  ) async {
    final day = DateTime(2026, 6, 23);
    final samples = [
      HrSample(day.add(const Duration(hours: 8)), 80),
      HrSample(day.add(const Duration(hours: 23, minutes: 55)), 120),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 184,
            child: HrLineChart(
              samples: samples,
              now: day.add(const Duration(hours: 9)),
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(310, 92));
    await tester.pump();

    expect(find.textContaining('120 bpm'), findsNothing);
    expect(find.textContaining('80 bpm'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
