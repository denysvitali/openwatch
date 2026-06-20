import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/ancs_client.dart';

void main() {
  group('AncsClient', () {
    test('addClient assigns unique ids and emits AncsConnect', () async {
      final c = AncsClient();
      final events = <AncsEvent>[];
      final sub = c.events.listen(events.add);
      final id = c.addClient(name: 'foo');
      expect(id, greaterThan(0));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(events, isA<List<AncsEvent>>());
      expect(events.first, isA<AncsConnect>());
      expect((events.first as AncsConnect).name, 'foo');
    });

    test('onFirmwareEvent(1) parses notification source', () async {
      final c = AncsClient();
      final events = <AncsEvent>[];
      c.events.listen(events.add);
      final id = c.addClient();
      // 8-byte ANCS notification source: added(0), flags=0, cat=1, count=2
      c.onFirmwareEvent(1, id, [0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events.length, greaterThanOrEqualTo(2));
      final notification = events.whereType<AncsNotification>().first;
      expect(notification.eventId, 0);
      expect(notification.categoryId, 1);
    });

    test('toPushMsg returns null without a notification', () {
      final c = AncsClient();
      final id = c.addClient();
      expect(c.toPushMsg(id), isNull);
    });

    test('disconnect removes the client', () async {
      final c = AncsClient();
      final events = <AncsEvent>[];
      c.events.listen(events.add);
      final id = c.addClient();
      c.onFirmwareEvent(3, id, const []);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events.whereType<AncsDisconnect>(), isNotEmpty);
      expect(c.toPushMsg(id), isNull);
    });
  });
}