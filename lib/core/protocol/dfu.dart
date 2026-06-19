import 'dart:async';
import 'dart:typed_data';

import '../ble/ble_transport.dart';
import 'codec.dart';
import 'commands.dart';
import 'opcodes.dart';

/// Progress of an OTA firmware flash.
class DfuProgress {
  const DfuProgress(this.phase, {this.percent = 0});
  final String phase;
  final double percent;
}

/// Drives the Channel-B firmware OTA flow (`PROTOCOL.md` §5.4) entirely from a
/// locally-stored image — no network required during flashing.
///
/// Sequence: Channel-A switch-to-OTA → start → init(meta) → raw 1024-byte
/// pockets → check → end. Each step waits for the device's unified RSP frame.
class DfuFlasher {
  DfuFlasher(this._transport);
  final BleTransport _transport;

  static const int _pocketSize = 1024;

  /// Flashes [firmware] to the connected watch, emitting [DfuProgress] events.
  Stream<DfuProgress> flash(Uint8List firmware) async* {
    if (firmware.length > 0xBB8000) {
      throw const DfuException('Firmware exceeds 12 MB device limit');
    }

    final rxSub = _transport.inboundB.listen(_onRx);

    try {
      yield const DfuProgress('Entering OTA mode');
      await _transport.sendA(Commands.switchToOta());
      await Future<void>.delayed(const Duration(milliseconds: 500));

      yield const DfuProgress('Starting session');
      await _send(OpB.otaStart);
      await _awaitRsp();

      yield const DfuProgress('Sending metadata');
      final checksum = _additive16(firmware);
      final crc = Codec.crc16(firmware);
      await _send(OpB.otaInit, [
        0x01,
        ...Codec.u32le(firmware.length),
        ...Codec.u16le(crc),
        ...Codec.u16le(checksum),
      ]);
      await _awaitRsp();

      final total = (firmware.length / _pocketSize).ceil();
      for (var i = 0; i < total; i++) {
        final start = i * _pocketSize;
        final end = (start + _pocketSize < firmware.length)
            ? start + _pocketSize
            : firmware.length;
        final chunk = Uint8List.sublistView(firmware, start, end);
        await _send(OpB.otaData, [...Codec.u16le(i + 1), ...chunk]);
        await _awaitRsp();
        yield DfuProgress('Flashing', percent: (i + 1) / total);
      }

      yield const DfuProgress('Verifying');
      await _send(OpB.otaCheck);
      await _awaitRsp();

      yield const DfuProgress('Finishing');
      await _send(OpB.otaEnd);

      yield const DfuProgress('Done', percent: 1);
    } finally {
      await rxSub.cancel();
    }
  }

  Completer<int>? _rspWaiter;

  void _onRx(Uint8List frame) {
    if (frame.length < 7 || frame[0] != Codec.channelBMagic) return;
    final type = frame[1];
    final status = frame[6];
    final waiter = _rspWaiter;
    if (waiter == null || waiter.isCompleted) return;
    if (type == OpB.rspLowBattery) {
      waiter.completeError(
        const DfuException('Device refused OTA: battery too low'),
      );
    } else if (status == 0) {
      waiter.complete(type);
    } else {
      waiter.completeError(
        DfuException('Device error: type=$type status=$status'),
      );
    }
  }

  Future<int> _awaitRsp({Duration timeout = const Duration(seconds: 10)}) {
    final c = Completer<int>();
    _rspWaiter = c;
    return c.future.timeout(timeout);
  }

  Future<void> _send(int cmd, [List<int> payload = const []]) =>
      _transport.sendB(Codec.buildChannelB(cmd, payload));

  static int _additive16(Uint8List data) {
    var sum = 0;
    for (final b in data) {
      sum += b;
    }
    return sum & 0xFFFF;
  }
}

class DfuException implements Exception {
  const DfuException(this.message);
  final String message;
  @override
  String toString() => 'DfuException: $message';
}
