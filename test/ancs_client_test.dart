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

    test(
      'onFirmwareEvent(1) parses notification source with action byte',
      () async {
        final c = AncsClient();
        final events = <AncsEvent>[];
        c.events.listen(events.add);
        final id = c.addClient();
        // 8-byte ANCS notification source: added(0), flags=0, cat=1, count=2.
        // action byte = 0x01 ("modified") per GHIDRA_DECOMPILATION.md §4.1.
        c.onFirmwareEvent(1, id, [
          0x00,
          0x00,
          0x01,
          0x00,
          0x00,
          0x00,
          0x02,
          0x00,
        ], action: 0x01);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(events.length, greaterThanOrEqualTo(2));
        final notification = events.whereType<AncsNotification>().first;
        expect(notification.eventId, 0);
        expect(notification.categoryId, 1);
        expect(notification.action, AncsNotificationAction.modified);
      },
    );

    test('onFirmwareEvent(1) lands post-header tail bytes on title so '
        'toPushMsg round-trips Oudmon-bridged notification text', () async {
      final c = AncsClient();
      final id = c.addClient();
      c.onFirmwareEvent(1, id, [
        // 8-byte ANCS header
        0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x01, 0x00,
        // Oudmon tail = the bridged notification text
        ...'Slack: dinner?'.codeUnits,
      ], action: 0x00);
      final push = c.toPushMsg(id);
      expect(push, isNotNull);
      expect(push!.type, 9);
      expect(push.text, contains('Slack: dinner?'));
    });

    test('onFirmwareEvent(2) action=0 emits AncsDataSource', () async {
      final c = AncsClient();
      final events = <AncsEvent>[];
      c.events.listen(events.add);
      final id = c.addClient();
      c.onFirmwareEvent(2, id, [0xde, 0xad], action: 0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final src = events.whereType<AncsDataSource>().first;
      expect(src.payload, [0xde, 0xad]);
    });

    test('onFirmwareEvent(2) action=1 emits AncsDataAttribute', () async {
      final c = AncsClient();
      final events = <AncsEvent>[];
      c.events.listen(events.add);
      final id = c.addClient();
      c.onFirmwareEvent(2, id, [0xbe, 0xef], action: 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final attr = events.whereType<AncsDataAttribute>().first;
      expect(attr.payload, [0xbe, 0xef]);
    });

    test('AncsNotificationAction.fromByte covers the switch8 table', () async {
      expect(AncsNotificationAction.fromByte(0), AncsNotificationAction.added);
      expect(
        AncsNotificationAction.fromByte(10),
        AncsNotificationAction.fetchAttrs,
      );
      expect(
        AncsNotificationAction.fromByte(99),
        AncsNotificationAction.unknown,
      );
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
