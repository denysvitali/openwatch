import 'dart:async';
import 'dart:typed_data';

import 'package:flutterrific_opentelemetry/flutterrific_opentelemetry.dart'
    hide Logger;

import '../ble/ble_transport.dart';
import '../ble/fee7_service.dart';
import '../protocol/ancs_client.dart';
import '../protocol/channel_a.dart';
import '../protocol/channel_b.dart';
import '../protocol/fee7_dispatcher.dart';
import '../protocol/ota_state.dart';
import 'app_log.dart';
import 'opentelemetry_service.dart';

final _log = AppLog.instance;

/// Wires the reverse-engineered H59MA v14 subsystems to the BLE transport.
///
/// Owns:
///   * [ChannelADispatcher] — typed view of every Channel-A response (opcodes
///     `0x01..0x72`), per-protocol spec in `firmwares/RE_FIRMWARE.md`.
///   * [ChannelBParser] — fragment reassembly + CRC-16/MODBUS verification
///     for large Channel-B frames (OTA, file transfer, custom watch faces).
///   * [AncsClient] — mirrors `ancs_add_client` / `ancs_client_cb` /
///     `app_parse_notification_source_data` so the host tracks the firmware's
///     internal ANCS state.
///   * [Fee7Service] + [Fee7Dispatcher] — vendor `0xFEE7` parallel channel
///     (SpO2, status, find-phone, vibration, OTA triggers; see
///     `GHIDRA_DECOMPILATION.md` §8).
///
/// Streams surface every typed event; consumers pick the ones they care
/// about. The hub itself only logs at info level — keep heavy work in the
/// subscribers.
class ProtocolHub {
  ProtocolHub(this._transport) {
    _dispatcher = ChannelADispatcher(_transport);
    _parser = ChannelBParser(_transport);
    _ancs = AncsClient();

    // The vendor 0xFEE7 service is optional — only attach a dispatcher when
    // the transport actually discovered the write characteristic. Otherwise
    // every inbound frame would error-log and the dispatcher would never see
    // traffic on watches that omit the service.
    if (_transport.hasFee7Write) {
      _fee7 = Fee7Service.attach(_transport);
      _fee7Dispatcher = Fee7Dispatcher(_fee7!)..bind();
    }

    // The dispatcher already listens to inboundA inside bind(); the parser
    // binds its own inboundB subscription too. The hub just composes the
    // resulting typed streams.
    _aSub = _dispatcher.bind();
    _bSub = _parser.bind();

    // Mirror the firmware's `ancs_handle_msg` path: Channel-A opcode 0x72 is
    // the push frame the watch emits whenever a notification crosses the
    // bridge. We forward it as a synthetic firmware event 1 (notification).
    _pushSub = _dispatcher.onPushMsg.listen((push) {
      // Trace every push message the firmware emits so notification
      // arrival latency (and the synthetic ANCS encoding) is visible.
      final span = OpenTelemetryService().startTrace(
        'hub.push_msg',
        kind: SpanKind.internal,
        attributes: {
          'ble.cmd': (push.type & 0xFF).toRadixString(16),
          'ble.payload.length': push.text.length,
        },
      );
      try {
        final id = _ancsClientId ?? _ensureAncsClient();
        _ancs.onFirmwareEvent(1, id, _encodePushForAncs(push));
      } finally {
        span?.end();
      }
    });

    // Channel-B OTA replies (`0x01..0x05`) are surfaced via the parser; a
    // dedicated OTA driver owns the state machine (see [startOta]).
    _bCmdSub = _parser.commands.listen((cmd) {
      // One span per Channel-B command so OTA/file transfer traffic is
      // easy to slice apart from push notifications.
      final span = OpenTelemetryService().startTrace(
        'hub.channel_b_cmd',
        kind: SpanKind.internal,
        attributes: {
          'ble.cmd': (cmd.cmd & 0xFF).toRadixString(16),
          'ble.payload.length': cmd.payload.length,
        },
      );
      try {
        _log.info(
          'hub',
          'Channel-B cmd=0x${cmd.cmd.toRadixString(16)} '
              'len=${cmd.payload.length}',
        );
      } finally {
        span?.end();
      }
    });
  }

  final BleTransport _transport;
  late final ChannelADispatcher _dispatcher;
  late final ChannelBParser _parser;
  late final AncsClient _ancs;
  Fee7Service? _fee7;
  Fee7Dispatcher? _fee7Dispatcher;

  StreamSubscription<Uint8List>? _aSub;
  StreamSubscription<Uint8List>? _bSub;
  StreamSubscription<PushMsgUint>? _pushSub;
  StreamSubscription<ChannelBCommand>? _bCmdSub;

  /// Currently-allocated ANCS client id (or `null` if [enableAncs] has not
  /// been called since the last link reset).
  int? _ancsClientId;

  /// Direct accessors — most callers only need one or two streams.
  ChannelADispatcher get channelA => _dispatcher;
  ChannelBParser get channelB => _parser;
  AncsClient get ancs => _ancs;

  /// Vendor `0xFEE7` dispatcher; `null` if the connected watch did not
  /// advertise the service. Always check before subscribing.
  Fee7Dispatcher? get fee7 => _fee7Dispatcher;

  /// Underlying vendor service handle, also nullable for the same reason as
  /// [fee7]. Useful for raw-frame observability when the typed stream is
  /// too narrow.
  Fee7Service? get fee7Service => _fee7;

  /// Whether the vendor `0xFEE7` channel is active for this hub.
  bool get hasFee7 => _fee7 != null;

  /// Pushes a single Channel-A frame into the hub. Useful for tests; in
  /// production the transport's notify stream drives this directly via
  /// [ChannelADispatcher.bind].
  void ingestFrame(Uint8List frame) {
    _dispatcher.decode(frame);
  }

  /// Optimistically fires `onFactoryReset` on the dispatcher. The
  /// `0xff "fff"` handler (FUN_0082cde8) sends no response frame, so the
  /// host has to drive this from the outbound send completing without
  /// error — see `GHIDRA_DECOMPILATION.md` §3.8.
  void notifyFactoryResetAccepted() {
    _dispatcher.emitFactoryReset();
  }

  /// Optimistically fires `onRestoreKey` on the dispatcher. The
  /// `0xc6` device-reboot handler (inline in `FUN_0082d2dc` —
  /// `GHIDRA_DECOMPILATION.md` §3.14) tears down BLE on the `0x6C`
  /// sub-byte before any response frame can be parsed. The host
  /// treats the loss of the link as the success indicator.
  void notifyDeviceRebootAccepted() {
    _dispatcher.emitRestoreKey();
  }

  /// Allocates a default ANCS client so a notification arriving before
  /// [enableAncs] still gets attributed somewhere. Mirrors the firmware's
  /// behaviour of always having at least one registered client.
  int _ensureAncsClient() {
    _ancsClientId = _ancs.addClient(name: 'auto');
    return _ancsClientId!;
  }

  /// Registers an ANCS client and returns its id. Mirrors the firmware's
  /// `ancs_add_client`. Re-registering on reconnect is safe — the previous
  /// client is dropped.
  int enableAncs({String? name}) {
    _ancsClientId = _ancs.addClient(name: name);
    return _ancsClientId!;
  }

  /// Clears ANCS state on link reset.
  void resetAncs() {
    _ancsClientId = null;
  }

  /// Builds an [OtaStateMachine] for the supplied image. The state machine is
  /// pure — the flasher drives transitions via [transition] and ships each
  /// frame through [channelB] (which already handles chunking + ACKs).
  OtaStateMachine startOta({required Uint8List image, required int sizeBytes}) {
    final session = OtaSession(image: image, sizeBytes: sizeBytes);
    return OtaStateMachine(session: session);
  }

  /// Encodes a [PushMsgUint] in the 8-byte notification-source header format
  /// the firmware expects (`FUN_00839fee`). The body text is appended as
  /// continuation data, but ANCS itself only inspects the header.
  List<int> _encodePushForAncs(PushMsgUint push) {
    final buf = <int>[
      0, // EventId: 0 = added
      0, // EventFlags
      push.type & 0xFF,
      (push.type >> 8) & 0xFF,
      (push.type >> 16) & 0xFF,
      (push.type >> 24) & 0xFF,
      1, // CategoryCount
      0,
      ...push.text.codeUnits,
    ];
    return buf;
  }

  void dispose() {
    _aSub?.cancel();
    _bSub?.cancel();
    _pushSub?.cancel();
    _bCmdSub?.cancel();
    _dispatcher.dispose();
    _parser.dispose();
    _ancs.dispose();
    _fee7?.dispose();
  }
}
