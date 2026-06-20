import 'dart:async';
import 'dart:typed_data';

import '../ble/ble_transport.dart';
import '../services/app_log.dart';
import 'codec.dart';
import 'opcodes.dart';

final _log = AppLog.instance;

/// Channel-B fragment reassembly + dispatcher.
///
/// Mirrors `FUN_0082efea` (parser), `FUN_0082eee6` (dispatcher), `FUN_0082f114`
/// (CRC-16/MODBUS), `FUN_0082ee00` (ACK/NAK sender), and `FUN_0082f098`
/// (fragment timeout) from the H59MA v14 firmware. The firmware's reassembly
/// buffer is a fixed 0x450-byte area at `DAT_0082f0f0`; we keep the same
/// semantics in a Dart state machine so the host never has to know about
/// fragment boundaries — it only sees fully-received commands.
///
/// Wire format (each chunk is a BLE write-without-response slice):
///
/// ```
///   byte 0      magic 0xBC
///   byte 1      cmd id (OpB)
///   byte 2..3   payload length, u16 LE
///   byte 4..5   CRC-16/MODBUS of payload, u16 LE
///   byte 6..    payload bytes
/// ```
///
/// Empty-payload sentinel: `bytes[2..5]` = `FF FF FF FF` (no length/CRC). The
/// firmware treats any value with magic `0xBC` but no declared length as a
/// complete frame; we do the same.
class ChannelBParser {
  ChannelBParser(
    this._transport, {
    this.fragmentTimeout = const Duration(seconds: 2),
  })  : _inboundB = _transport.inboundB,
        _sendA = _transport.sendA;

  final BleTransport _transport;
  final Stream<Uint8List> _inboundB;

  /// Sends a fully-built Channel-A response (used for ACK/NAK).
  final Future<void> Function(Uint8List) _sendA;

  /// Max time to wait between fragments before discarding the in-progress
  /// frame. Firmware uses `m_ble_packet_timer_id` at 2000 ms (`FUN_0082f098`).
  final Duration fragmentTimeout;

  /// `DAT_0082f0f0 + 0xb`: reassembly state (`0` = waiting for first fragment,
  /// `1` = accumulating continuation, `2` = complete & queued for dispatch).
  int _state = 0;

  /// Mirrors firmware buffer size `0x450` at `DAT_0082f0f0`.
  final Uint8List _buf = Uint8List(0x450);
  int _expectedLength = 0;
  int _accumulated = 0;
  int _currentCmd = 0;
  int _declaredCrc = 0;
  Timer? _timeout;

  StreamController<ChannelBCommand>? _ctrl;
  Stream<ChannelBCommand> get commands =>
      (_ctrl ??= StreamController<ChannelBCommand>.broadcast()).stream;

  /// Subscribes to the transport and starts feeding the parser. Idempotent.
  StreamSubscription<Uint8List> bind() => _inboundB.listen(
        _onChunk,
        onError: (Object e, StackTrace _) {
          _log.error('chb', 'inbound stream error: $e');
        },
      );

  /// Builds an ACK/NAK for Channel-B responses (mirrors `FUN_0082ee00`).
  ///
  /// Sends a Channel-A frame `[0xBC, cmd, status]` where status:
  ///   `0` = OK, `2` = CRC mismatch, others = firmware-defined errors.
  Uint8List buildAck(int cmd, int status) =>
      Codec.buildChannelA(0xBC, [cmd & 0xFF, status & 0xFF]);

  /// Wraps a payload as a Channel-B frame and sends it via the transport's
  /// `sendB` (chunked, no-response). Mirrors `FUN_0082ece0`.
  Future<void> sendB(int cmd, [List<int> payload = const []]) =>
      _transport.sendB(Codec.buildChannelB(cmd, payload));

  /// Sends an ACK frame on Channel A.
  Future<void> sendAck(int cmd, {int status = 0}) =>
      _sendA(buildAck(cmd, status));

  // ---------------------------------------------------------------------------
  // Fragment ingest — mirrors FUN_0082efea (parser) + FUN_0082f098 (timer).
  // ---------------------------------------------------------------------------

  void _onChunk(Uint8List chunk) {
    _timeout?.cancel();

    if (_state == 0) {
      // First fragment: must carry the 0xBC magic.
      if (chunk.isEmpty || chunk[0] != Codec.channelBMagic) {
        _log.warn(
          'chb',
          'dropping chunk without 0xBC magic (len=${chunk.length})',
        );
        return;
      }
      _onFirstFragment(chunk);
      return;
    }

    // Continuation: append payload bytes until we've hit `_expectedLength`.
    // Continuations don't carry the 0xBC header (the firmware's parser splits
    // before forwarding them to the buffer).
    final remaining = _expectedLength - _accumulated;
    if (remaining <= 0) {
      _reset();
      _onChunk(chunk); // re-process as new frame
      return;
    }
    final take = chunk.length < remaining ? chunk.length : remaining;
    _buf.setRange(_accumulated, _accumulated + take, chunk);
    _accumulated += take;
    _log.debug(
      'chb',
      'continuation cmd=0x${_currentCmd.toRadixString(16)} '
          '+$take → $_accumulated/$_expectedLength',
    );
    if (_accumulated >= _expectedLength) {
      _dispatch();
    } else {
      _armTimeout();
    }
  }

  void _onFirstFragment(Uint8List chunk) {
    // Empty-payload sentinel: `[BC cmd FF FF FF FF]`.
    if (chunk.length >= 6 &&
        chunk[2] == 0xFF &&
        chunk[3] == 0xFF &&
        chunk[4] == 0xFF &&
        chunk[5] == 0xFF) {
      _emit(chunk[1], Uint8List(0));
      // ACK the same way the firmware does — except OTA direct commands
      // (mirrors the dispatcher at `FUN_0082eee6`).
      const otaDirect = {
        OpB.otaStart,
        OpB.otaInit,
        OpB.fileInit,
        OpB.fileCheck,
        OpB.fileDelete,
        OpB.customWatchFace,
      };
      if (!otaDirect.contains(chunk[1])) {
        unawaited(sendAck(chunk[1], status: 0));
      }
      return;
    }
    if (chunk.length < 6) {
      _log.warn('chb', 'first fragment too short (len=${chunk.length})');
      return;
    }
    final len = chunk[2] | (chunk[3] << 8);
    _currentCmd = chunk[1];
    _expectedLength = len;
    _declaredCrc = chunk[4] | (chunk[5] << 8);
    _accumulated = 0;
    final payloadBytes = chunk.length - 6;
    final take = payloadBytes < len ? payloadBytes : len;
    if (take > 0) {
      _buf.setRange(0, take, chunk.sublist(6, 6 + take));
      _accumulated = take;
    }
    _log.debug(
      'chb',
      'first cmd=0x${_currentCmd.toRadixString(16)} '
          'len=$len accum=$_accumulated crc=0x${_declaredCrc.toRadixString(16)}',
    );
    if (_accumulated >= _expectedLength) {
      _dispatch();
    } else {
      _state = 1;
      _armTimeout();
    }
  }

  void _armTimeout() {
    _timeout?.cancel();
    _timeout = Timer(fragmentTimeout, () {
      _log.warn(
        'chb',
        'fragment timeout cmd=0x${_currentCmd.toRadixString(16)} '
            '($_accumulated/$_expectedLength); discarding',
      );
      _reset();
    });
  }

  // ---------------------------------------------------------------------------
  // Dispatch — mirrors FUN_0082eee6 (post-CRC dispatcher).
  // ---------------------------------------------------------------------------

  void _dispatch() {
    _timeout?.cancel();
    final cmd = _currentCmd;
    final payload = Uint8List.sublistView(_buf, 0, _expectedLength);

    final got = Codec.crc16(payload);
    if (got != _declaredCrc) {
      _log.error(
        'chb',
        'CRC mismatch cmd=0x${cmd.toRadixString(16)} '
            'got=0x${got.toRadixString(16)} '
            'want=0x${_declaredCrc.toRadixString(16)}',
      );
      unawaited(sendAck(cmd, status: 2));
      _reset();
      return;
    }

    _log.info('chb', 'RX cmd=0x${cmd.toRadixString(16)} len=${payload.length}');

    _emit(cmd, payload);
    // Default ACK (status=0) for non-OTA commands — mirrors the firmware's
    // behavior. OTA consumers suppress their own ACKs via the stream.
    const otaDirect = {
      OpB.otaStart,
      OpB.otaInit,
      OpB.fileInit,
      OpB.fileCheck,
      OpB.fileDelete,
      OpB.customWatchFace,
    };
    if (!otaDirect.contains(cmd)) {
      unawaited(sendAck(cmd, status: 0));
    }
    _reset();
  }

  void _emit(int cmd, Uint8List payload) {
    final ctrl = _ctrl;
    if (ctrl == null || ctrl.isClosed) return;
    ctrl.add(ChannelBCommand(cmd, payload));
  }

  void _reset() {
    _timeout?.cancel();
    _state = 0;
    _expectedLength = 0;
    _accumulated = 0;
    _currentCmd = 0;
    _declaredCrc = 0;
  }

  void dispose() {
    _timeout?.cancel();
    _ctrl?.close();
  }
}

/// Fully-reassembled Channel-B command surfaced by [ChannelBParser].
class ChannelBCommand {
  ChannelBCommand(this.cmd, this.payload);
  final int cmd;
  final Uint8List payload;
}
