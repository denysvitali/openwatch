import 'dart:async';
import 'dart:collection';
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
/// Empty-payload sentinel: the exact six-byte frame `[BC, cmd, FF, FF, FF, FF]`
/// carries no length/CRC fields and dispatches immediately.
class ChannelBParser {
  ChannelBParser(
    WatchLink transport, {
    this.fragmentTimeout = const Duration(seconds: 2),
  }) : _inboundB = transport.inboundB,
       _sendA = transport.sendA,
       _sendB = transport.sendB,
       // 4× the fragment timeout is plenty to absorb a BLE-link replay
       // storm while still allowing a legitimate re-emit after the watch
       // comes back from sleep (the firmware pushes 0x27/0x2a/0x3e on
       // every state transition).
       _seenTtl = Duration(
         milliseconds: (fragmentTimeout.inMilliseconds * 4).clamp(2000, 60000),
       );

  final Stream<Uint8List> _inboundB;

  /// Sends a fully-built Channel-A response (used for ACK/NAK).
  final Future<void> Function(Uint8List) _sendA;

  /// Sends a framed Channel-B buffer (chunked, write-without-response).
  final Future<void> Function(Uint8List) _sendB;

  /// Max time to wait between fragments before discarding the in-progress
  /// frame. Firmware uses `m_ble_packet_timer_id` at 2000 ms (`FUN_0082f098`).
  final Duration fragmentTimeout;

  /// TTL for dedup entries. See constructor body.
  final Duration _seenTtl;

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

  /// LRU of recently-emitted Channel-B frames keyed by FNV-1a(payload).
  /// Prevents duplicate-ingest storms when the watch (or firmware) replays
  /// the same `0x27`/`0x2a`/`0x3e` frame N times during a link glitch —
  /// we observed 5× back-to-back in production (`history_sync.dart`
  /// would otherwise fire `_decodeSleepNew` 5× and emit 5× `notifyListeners`
  /// storms). `cmd` is checked alongside the hash so two different
  /// commands that collide on the hash (vanishingly rare at ≤64 entries)
  /// are still treated as distinct frames.
  ///
  /// Bounded to [_maxSeenFrames]; on overflow we evict the oldest entry
  /// (LinkedHashMap iteration order is insertion-order in Dart). TTL is
  /// enforced at lookup time, so a legitimate re-emit after the watch
  /// recovers from a long sleep still gets through.
  static const int _maxSeenFrames = 64;
  final LinkedHashMap<int, _RecentFrame> _seenFrames =
      LinkedHashMap<int, _RecentFrame>();

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

  /// Builds an ACK/NAK frame for Channel-B responses.
  ///
  /// **The H59MA firmware does not require ACKs for unsolicited
  /// Channel-B pushes** — it dispatches via `FUN_0082eee6` (§2.0.1 in
  /// `GHIDRA_DECOMPILATION.md`) and processes the frame without
  /// expecting a reply. `ChannelBParser` therefore does **not** auto-ACK.
  /// This helper is kept for callers that need to manually ACK a frame
  /// (e.g. OTA file transfers where the firmware is in a "waiting for
  /// confirmation" state). Most code paths should NOT call this.
  ///
  /// The wire format is a Channel-A frame `[opcode, cmd, status]` where
  /// the opcode is `OpA.channelBAck` (`0x7E`). The high bit (`0x80`)
  /// must NOT be set on Channel-A — PROTOCOL.md §4 reserves it as the
  /// device→host error flag, and the firmware strips it before
  /// dispatch. Any opcode ≥ `0x80` aliases to a low-bit request opcode
  /// and triggers an error response from the firmware.
  Uint8List buildAck(int cmd, int status) =>
      Codec.buildChannelA(OpA.channelBAck, [cmd & 0xFF, status & 0xFF]);

  /// Wraps a payload as a Channel-B frame and sends it via the transport's
  /// `sendB` (chunked, no-response). Mirrors `FUN_0082ece0`.
  Future<void> sendB(int cmd, [List<int> payload = const []]) =>
      _sendB(Codec.buildChannelB(cmd, payload));

  /// Sends an ACK/NAK frame on Channel A. See [buildAck] for the wire
  /// format. **Callers should not invoke this for unsolicited Channel-B
  /// pushes** — the firmware does not expect an ACK and will echo an
  /// error (`0x7E ERR 0xee`) for every frame we send.
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
    // The firmware receiver completes on accumulated >= declared length. The
    // host decoder is intentionally stricter so trailing bytes in captures do
    // not get truncated into valid events.
    if (chunk.length > remaining) {
      _log.warn(
        'chb',
        'continuation too long cmd=0x${_currentCmd.toRadixString(16)} '
            '(len=${chunk.length} remaining=$remaining); discarding',
      );
      _reset();
      return;
    }
    final take = chunk.length;
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
    if (Codec.isChannelBEmptySentinel(chunk)) {
      _emit(chunk[1], Uint8List(0));
      // NO auto-ACK — the firmware does not expect ACKs for unsolicited
      // Channel-B pushes (see [buildAck] docstring). OTA direct commands
      // are dispatched via `FUN_0082fe52` and don't need them either.
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
    // See continuation guard above: reject malformed incoming frames rather
    // than silently dropping bytes beyond the declared payload.
    if (payloadBytes > len) {
      _log.warn(
        'chb',
        'first fragment too long cmd=0x${_currentCmd.toRadixString(16)} '
            '(payload=$payloadBytes declared=$len); discarding',
      );
      _reset();
      return;
    }
    final take = payloadBytes;
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
      // NO NAK — the firmware does not expect NAKs for frames it sends
      // (FUN_0082eee6 is one-way: host receives, processes, no reply).
      // CRC mismatches at this layer are protocol bugs in the firmware
      // and should be logged loudly, not acknowledged.
      _reset();
      return;
    }

    _log.info('chb', 'RX cmd=0x${cmd.toRadixString(16)} len=${payload.length}');

    _emit(cmd, payload);
    // NO auto-ACK — see [buildAck] docstring. Callers that need to
    // manually ACK can call [sendAck] directly.
    _reset();
  }

  void _emit(int cmd, Uint8List payload) {
    final ctrl = _ctrl;
    if (ctrl == null || ctrl.isClosed) return;

    // Garbage-collect expired entries before the dedup check so we never
    // compare against stale state. The LRU is bounded, so this loop is
    // cheap in practice (≤ 64 entries per frame).
    final now = DateTime.now();
    _seenFrames.removeWhere((_, f) => now.difference(f.emittedAt) > _seenTtl);

    final hash = _fnv1a(payload);
    final seen = _seenFrames[hash];
    if (seen != null &&
        seen.cmd == cmd &&
        now.difference(seen.emittedAt) <= _seenTtl) {
      _log.debug(
        'chb',
        'dedup cmd=0x${cmd.toRadixString(16)} '
            'hash=0x${hash.toRadixString(16)} '
            '(age=${now.difference(seen.emittedAt).inMilliseconds}ms)',
      );
      return;
    }

    _seenFrames[hash] = _RecentFrame(cmd, hash, now);
    while (_seenFrames.length > _maxSeenFrames) {
      _seenFrames.remove(_seenFrames.keys.first);
    }

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
    _seenFrames.clear();
    _ctrl?.close();
  }
}

/// Entry recorded by [ChannelBParser] for duplicate-detection purposes.
class _RecentFrame {
  _RecentFrame(this.cmd, this.payloadHash, this.emittedAt);
  final int cmd;
  final int payloadHash;
  final DateTime emittedAt;
}

/// 32-bit FNV-1a hash over [data] (offset-basis `0x811c9dc5`,
/// prime `0x01000193`). Collision rate at ≤64 entries × ~13-byte
/// average Channel-B payload is negligible (birthday bound ~2^16
/// entries) and dedup is best-effort anyway — a collision just causes
/// one missed emit, which the watch will re-push on the next state
/// transition.
int _fnv1a(Uint8List data) {
  var hash = 0x811c9dc5;
  for (final b in data) {
    hash ^= b & 0xFF;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// Fully-reassembled Channel-B command surfaced by [ChannelBParser].
class ChannelBCommand {
  ChannelBCommand(this.cmd, this.payload);
  final int cmd;
  final Uint8List payload;
}
