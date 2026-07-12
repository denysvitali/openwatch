import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/fitbit_gattlink.dart';

void main() {
  test('decodes captured Gattlink IPv4 UDP and DTLS headers', () {
    final packet = FitbitGattlinkPacket.parse(<int>[
      0x1b,
      0x45,
      0x00,
      0x00,
      0x50,
      0x08,
      0x8b,
      0x00,
      0x00,
      0xff,
      0x11,
      0x5f,
      0x10,
      0xa9,
      0xfe,
      0x00,
      0x03,
      0xa9,
      0xfe,
      0x00,
      0x02,
      0x16,
      0x34,
      0x16,
      0x34,
      0x00,
      0x3c,
      0xf0,
      0xb1,
      0x17,
      0xfe,
      0xfd,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x06,
      0xf7,
      0x00,
      0x27,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x06,
      0xf7,
      0xba,
      0x65,
      0xb2,
      0x5c,
      0xf6,
      0x62,
      0x76,
      0x4a,
      0x8d,
      0x0d,
      0xe3,
      0x7d,
      0x5e,
      0x85,
      0x26,
      0x20,
      0x90,
      0xa7,
      0xa3,
      0xcf,
      0xc5,
      0x73,
      0xe1,
      0x73,
      0xa7,
      0x21,
      0x26,
      0xc2,
      0xbb,
      0x7e,
      0x1a,
    ]);

    expect(packet, isNotNull);
    expect(packet!.packetSequence, 27);
    expect(packet.acknowledgedSequence, isNull);
    expect(packet.network!.sourceAddress, '169.254.0.3');
    expect(packet.network!.destinationAddress, '169.254.0.2');
    expect(packet.network!.sourcePort, 5684);
    expect(packet.network!.destinationPort, 5684);
    expect(packet.network!.dtls!.isApplicationData, isTrue);
    expect(packet.network!.dtls!.majorVersion, 0xfe);
    expect(packet.network!.dtls!.minorVersion, 0xfd);
    expect(packet.network!.dtls!.epoch, 1);
    expect(packet.network!.dtls!.sequence, 0x6f7);
    expect(packet.network!.dtls!.fragmentLength, 39);
  });

  test('decodes captured acknowledgement-only packets', () {
    final packet = FitbitGattlinkPacket.parse(<int>[0x40]);

    expect(packet, isNotNull);
    expect(packet!.isAcknowledgementOnly, isTrue);
    expect(packet.acknowledgedSequence, 0);
    expect(packet.packetSequence, isNull);
  });
}
