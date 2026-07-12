import 'dart:typed_data';

/// Structural decoder for Fitbit Golden Gate packets carried by `abbaff02`.
///
/// Gattlink provides sequencing and acknowledgements over GATT. Its payload is
/// normally an IPv4/UDP datagram; Fitbit's production stack then protects the
/// application protocol with DTLS, so [dtls] exposes record metadata but not
/// plaintext.
class FitbitGattlinkPacket {
  const FitbitGattlinkPacket._({
    required this.isControl,
    this.controlType,
    this.acknowledgedSequence,
    this.packetSequence,
    required this.payload,
    this.network,
  });

  final bool isControl;
  final int? controlType;
  final int? acknowledgedSequence;
  final int? packetSequence;
  final Uint8List payload;
  final FitbitNetworkDatagram? network;

  bool get isAcknowledgementOnly =>
      !isControl && acknowledgedSequence != null && packetSequence == null;

  static FitbitGattlinkPacket? parse(List<int> value) {
    if (value.isEmpty) return null;
    final bytes = Uint8List.fromList(value);
    final header = bytes[0];
    if ((header & 0x80) != 0) {
      return FitbitGattlinkPacket._(
        isControl: true,
        controlType: header & 0x7f,
        payload: Uint8List.sublistView(bytes, 1),
      );
    }

    var offset = 0;
    int? acknowledgedSequence;
    if ((header & 0x40) != 0) {
      acknowledgedSequence = header & 0x1f;
      offset++;
    }
    if (offset == bytes.length) {
      return FitbitGattlinkPacket._(
        isControl: false,
        acknowledgedSequence: acknowledgedSequence,
        payload: Uint8List(0),
      );
    }

    final packetSequence = bytes[offset] & 0x1f;
    offset++;
    final payload = Uint8List.sublistView(bytes, offset);
    return FitbitGattlinkPacket._(
      isControl: false,
      acknowledgedSequence: acknowledgedSequence,
      packetSequence: packetSequence,
      payload: payload,
      network: FitbitNetworkDatagram.tryParse(payload),
    );
  }
}

class FitbitNetworkDatagram {
  const FitbitNetworkDatagram._({
    required this.sourceAddress,
    required this.destinationAddress,
    required this.sourcePort,
    required this.destinationPort,
    required this.dtls,
  });

  final String sourceAddress;
  final String destinationAddress;
  final int sourcePort;
  final int destinationPort;
  final FitbitDtlsRecord? dtls;

  static FitbitNetworkDatagram? tryParse(Uint8List bytes) {
    if (bytes.length < 28 || bytes[0] >> 4 != 4) return null;
    final headerLength = (bytes[0] & 0x0f) * 4;
    if (headerLength < 20 || bytes.length < headerLength + 8) return null;
    final totalLength = _u16(bytes, 2);
    if (totalLength < headerLength + 8 || totalLength > bytes.length) {
      return null;
    }
    if (bytes[9] != 17) return null; // UDP

    final udpOffset = headerLength;
    final udpLength = _u16(bytes, udpOffset + 4);
    if (udpLength < 8 || udpOffset + udpLength > totalLength) return null;
    final udpPayload = Uint8List.sublistView(
      bytes,
      udpOffset + 8,
      udpOffset + udpLength,
    );
    return FitbitNetworkDatagram._(
      sourceAddress: _ipv4(bytes, 12),
      destinationAddress: _ipv4(bytes, 16),
      sourcePort: _u16(bytes, udpOffset),
      destinationPort: _u16(bytes, udpOffset + 2),
      dtls: FitbitDtlsRecord.tryParse(udpPayload),
    );
  }
}

class FitbitDtlsRecord {
  const FitbitDtlsRecord._({
    required this.contentType,
    required this.majorVersion,
    required this.minorVersion,
    required this.epoch,
    required this.sequence,
    required this.fragmentLength,
  });

  final int contentType;
  final int majorVersion;
  final int minorVersion;
  final int epoch;
  final int sequence;
  final int fragmentLength;

  bool get isApplicationData => contentType == 23;

  static FitbitDtlsRecord? tryParse(Uint8List bytes) {
    if (bytes.length < 13) return null;
    final fragmentLength = _u16(bytes, 11);
    if (13 + fragmentLength > bytes.length) return null;
    var sequence = 0;
    for (var i = 5; i < 11; i++) {
      sequence = (sequence << 8) | bytes[i];
    }
    return FitbitDtlsRecord._(
      contentType: bytes[0],
      majorVersion: bytes[1],
      minorVersion: bytes[2],
      epoch: _u16(bytes, 3),
      sequence: sequence,
      fragmentLength: fragmentLength,
    );
  }
}

int _u16(Uint8List bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

String _ipv4(Uint8List bytes, int offset) =>
    '${bytes[offset]}.${bytes[offset + 1]}.${bytes[offset + 2]}.'
    '${bytes[offset + 3]}';
