import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/commands.dart';
import 'package:openwatch/core/protocol/device_info.dart';
import 'package:openwatch/core/protocol/opcodes.dart';

void main() {
  group('DeviceInfoConfig parser', () {
    test('decodes the [01, 01, count, ...tlvs] query shape', () {
      // Sub-cmd 0x01 echo, marker 0x01, count 2, then two TLVs:
      //   id=1, len=6, "Hello!"  (6 ASCII bytes)
      //   id=3, len=0x14 (20), 20-byte slot
      final slot3 = List<int>.generate(0x14, (i) => (i + 0x30) & 0xFF);
      final body = <int>[
        0x01,
        0x01,
        0x02,
        0x01,
        0x06,
        ..._ascii('Hello!'),
        0x03,
        0x14,
        ...slot3,
      ];
      final cfg = DeviceInfoConfig.tryParse(Uint8List.fromList(body));
      expect(cfg, isNotNull);
      expect(cfg!.count, 2);

      expect(cfg.customNamePrefix, isNotNull);
      expect(
        cfg.customNamePrefix!.map((b) => b & 0xFF).toList(),
        _ascii('Hello!'),
      );

      expect(cfg.infoSlot3, isNotNull);
      expect(cfg.infoSlot3!.length, 0x14);
      expect(cfg.infoSlot3!.map((b) => b & 0xFF).toList(), slot3);

      // Slots that the response did not include must return null.
      expect(cfg.bleAddress, isNull);
      expect(cfg.infoSlot4, isNull);
      expect(cfg.infoSlot5, isNull);
      expect(cfg.infoSlot6, isNull);
      expect(cfg.nameFormat, isNull);
    });

    test('tryParse returns null for the 3-byte generic status fallback', () {
      // Watch returns `[0x5A, 0x00, 0x00]` for unknown sub-cmds.
      // The parser must NOT decode this as a query response.
      final body = Uint8List.fromList([0x5A, 0x00, 0x00]);
      expect(DeviceInfoConfig.tryParse(body), isNull);
    });

    test('tryParse returns null for a truncated TLV', () {
      // Count says 2 but the second TLV is missing its body.
      final body = Uint8List.fromList([
        0x01,
        0x01,
        0x02,
        0x01,
        0x06,
        ..._ascii('Hello!'),
        0x03,
        0x14,
        // 20 bytes of slot3 body intentionally absent
      ]);
      expect(DeviceInfoConfig.tryParse(body), isNull);
    });

    test('tryParse returns null for sub-cmds other than 0x01', () {
      // sub-cmd 0x03 (static info) — the parser only handles query.
      final body = Uint8List.fromList([0x03, 0x01, 0x00]);
      expect(DeviceInfoConfig.tryParse(body), isNull);
    });

    test('nameFormat accessor reads TLV id 7 as a single byte', () {
      final body = Uint8List.fromList([0x01, 0x01, 0x01, 0x07, 0x01, 0xAB]);
      final cfg = DeviceInfoConfig.tryParse(body);
      expect(cfg, isNotNull);
      expect(cfg!.nameFormat, 0xAB);
    });
  });

  group('Commands.deviceInfo* builders', () {
    test('deviceInfoQuery wraps [0x5a, 0x01] in Channel-B framing', () {
      final frame = Commands.deviceInfoQuery();
      // 6-byte Channel-B header (BC cmd len crc) + 1-byte body.
      expect(frame.length, 7);
      expect(frame[0], Codec.channelBMagic);
      expect(frame[1], OpB.deviceInfoConfig);
      final payload = Codec.rxChannelBPayload(frame);
      expect(payload, isNotNull);
      expect(payload!, <int>[0x01]);
    });

    test('deviceInfoWrite emits [0x5a, 0x02, count, ...tlvs]', () {
      final frame = Commands.deviceInfoWrite([
        (id: 1, data: Uint8List.fromList(_ascii('Hi'))),
        (id: 7, data: Uint8List.fromList([0x02])),
      ]);
      final payload = Codec.rxChannelBPayload(frame);
      expect(payload, isNotNull);
      final p = payload!;
      expect(p[0], 0x02);
      expect(p[1], 0x02); // count
      expect(p[2], 0x01); // TLV id
      expect(p[3], 0x02); // TLV len
      expect(p.sublist(4, 6), _ascii('Hi'));
      expect(p[6], 0x07); // next TLV id
      expect(p[7], 0x01); // next TLV len
      expect(p[8], 0x02); // next TLV data
    });

    test('deviceInfoClear wraps [0x5a, 0x04] in Channel-B framing', () {
      final frame = Commands.deviceInfoClear();
      expect(frame[0], Codec.channelBMagic);
      expect(frame[1], OpB.deviceInfoConfig);
      final payload = Codec.rxChannelBPayload(frame);
      expect(payload, isNotNull);
      expect(payload!, <int>[0x04]);
    });
  });
}

List<int> _ascii(String s) =>
    s.codeUnits.where((c) => c < 0x80).toList(growable: false);
