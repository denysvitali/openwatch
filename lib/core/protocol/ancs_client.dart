import 'dart:async';
import 'dart:typed_data';

import '../services/app_log.dart';
import 'channel_a.dart';

final _log = AppLog.instance;

/// Apple Notification Center Service (ANCS) client.
///
/// Mirrors the H59MA v14 firmware's ANCS machinery — strings
/// `ancs_send_msg_to_app`, `ancs_handle_msg`, and
/// `app_parse_notification_source_data` at v13 `0x2184a..0x21891` confirm the
/// watch runs an ANCS client that consumes iOS notifications and forwards them
/// through the Oudmon Channel-A path (opcode `0x72` — see PROTOCOL.md §4.6).
///
/// From the Ghidra decompilation:
///   * `FUN_00839e4e` (`ancs_add_client`) — registers a new ANCS client and
///     allocates a client state.
///   * `FUN_0083a116` (`ancs_client_cb`) — handles the four lifecycle events:
///     `0` connect, `1` notification, `2` data, `3` disconnect.
///   * `FUN_00839fee` — stores parsed notification-source data.
///   * `FUN_00839ac4` — pushes the ANCS data to the host app over Channel-A.
///
/// On the host side the watch pushes notifications via Channel-A opcode `0x72`,
/// which [ChannelADispatcher.onPushMsgReassembled] surfaces as [PushMsgUint]
/// after §3.3-style multi-frame chunking has been collapsed into one
/// notification. This class models the firmware's internal state so the host
/// can keep a coherent view of active ANCS sessions even though only one
/// transport is in play.
class AncsClient {
  AncsClient();

  /// Mirrors `ancs_add_client` (`FUN_00839e4e`).
  final _onEvent = StreamController<AncsEvent>.broadcast();

  /// Lifecycle events surfaced to the host.
  Stream<AncsEvent> get events => _onEvent.stream;

  /// Connected clients keyed by their assigned client id. Mirrors the firmware
  /// state table at `DAT_*` + offset.
  final Map<int, _AncsClientState> _clients = {};

  int _nextId = 1;

  /// Registers a new ANCS client. Returns the assigned id (mirrors
  /// `ancs_add_client`).
  int addClient({String? name}) {
    final id = _nextId++;
    _clients[id] = _AncsClientState(id, name ?? 'ancs-$id');
    _log.info('ancs', 'client $id added (${_clients[id]!.name})');
    _emit(AncsConnect(id: id, name: _clients[id]!.name));
    return id;
  }

  /// Dispatches a lifecycle event from the firmware (mirrors
  /// `ancs_client_cb` `FUN_0083a116` — see `GHIDRA_DECOMPILATION.md` §4.1).
  ///
  /// [event] is one of:
  ///   `0` connect, `1` notification, `2` data, `3` disconnect.
  ///
  /// [action] is the per-event action byte:
  ///   * for `event == 1` (notification): the `event[4]` NotificationAction
  ///     byte, decoded via the 16-entry switch8 table at `0x83a1b5`. Values
  ///     `0..15` map to [AncsNotificationAction].
  ///   * for `event == 2` (data): `0` = NotificationSource, `1` =
  ///     AppAttribute (FUN_0083a036). Other values are reserved.
  ///   * ignored for `event == 0/3`.
  void onFirmwareEvent(
    int event,
    int clientId,
    List<int> data, {
    int action = 0,
  }) {
    final state = _clients[clientId];
    if (state == null) {
      _log.warn('ancs', 'event $event for unknown client $clientId');
      return;
    }
    switch (event) {
      case 0:
        _emit(AncsConnect(id: clientId, name: state.name));
      case 1:
        // Notification source event — parsed body at `FUN_00839fee`.
        // The 8-byte header carries CategoryId/Count; any bytes past
        // that are the Oudmon-bridged notification text. The watch
        // only surfaces a single string per push (PROTOCOL.md §4.6
        // PushMsgUint), so we land it on `title` to keep
        // [toPushMsg] round-trippable for callers that want to
        // re-encode the same notification back over `0x72`. ANCS-
        // compliant sources (e.g. native iOS ANCS clients) never
        // deliver a tail here — attribute data arrives on the
        // separate `event == 2, action == 1` path.
        final parsed = _parseNotificationSource(data);
        if (parsed != null) {
          if (data.length > 8) {
            final tail = data.sublist(8);
            final text = String.fromCharCodes(tail.where((b) => b != 0));
            if (text.isNotEmpty) parsed.title = text;
          }
          state.lastNotification = parsed;
          _emit(
            AncsNotification(
              clientId: clientId,
              source: parsed,
              action: AncsNotificationAction.fromByte(action),
            ),
          );
        }
      case 2:
        // Data source event — sub-classified on action byte.
        state.lastData = Uint8List.fromList(data);
        if (action == 1) {
          _emit(
            AncsDataAttribute(clientId: clientId, payload: state.lastData!),
          );
        } else {
          _emit(AncsDataSource(clientId: clientId, payload: state.lastData!));
        }
      case 3:
        _emit(AncsDisconnect(id: clientId));
        _clients.remove(clientId);
      default:
        _log.warn('ancs', 'unknown event $event');
    }
  }

  /// Converts a parsed ANCS notification into a [PushMsgUint] for Channel-A
  /// opcode `0x72`. Mirrors the firmware's `ancs_send_msg_to_app` path.
  ///
  /// Returns `null` if the notification doesn't carry text we can surface.
  PushMsgUint? toPushMsg(int clientId) {
    final s = _clients[clientId];
    final src = s?.lastNotification;
    if (s == null || src == null) return null;
    final buf = StringBuffer()
      ..write(src.title ?? '')
      ..write(src.body ?? '');
    if (buf.isEmpty) return null;
    return PushMsgUint(type: src.categoryId, text: buf.toString());
  }

  void _emit(AncsEvent e) {
    if (_onEvent.isClosed) return;
    _onEvent.add(e);
  }

  /// Parses the 8-byte ANCS notification-source frame:
  ///   `byte 0`   EventId (0=added, 1=modified, 2=removed)
  ///   `byte 1`   EventFlags
  ///   `byte 2..5` CategoryId (u32 LE)
  ///   `byte 6..7` CategoryCount (u16 LE)
  ///   `byte 8..` NotificationUID (u32 LE)
  ///
  /// The full ANCS spec continues with attribute-request data; we keep the
  /// header-only view that mirrors `FUN_00839fee` in the firmware.
  static AncsNotificationSource? _parseNotificationSource(List<int> data) {
    if (data.length < 8) return null;
    final eventId = data[0] & 0xFF;
    final flags = data[1] & 0xFF;
    final cat = data[2] | (data[3] << 8) | (data[4] << 16) | (data[5] << 24);
    final count = data[6] | (data[7] << 8);
    return AncsNotificationSource(
      eventId: eventId,
      flags: flags,
      categoryId: cat,
      count: count,
    );
  }

  void dispose() {
    _onEvent.close();
    _clients.clear();
  }
}

/// Mirrors the internal `ancs_client_t` the firmware allocates.
class _AncsClientState {
  _AncsClientState(this.id, this.name);
  final int id;
  final String name;
  AncsNotificationSource? lastNotification;
  Uint8List? lastData;
}

/// Public surface for the parsed ANCS notification-source header.
class AncsNotificationSource {
  AncsNotificationSource({
    required this.eventId,
    required this.flags,
    required this.categoryId,
    required this.count,
  });
  final int eventId;
  final int flags;
  final int categoryId;
  final int count;
  String? title;
  String? body;
}

/// Public-facing lifecycle events.
sealed class AncsEvent {
  const AncsEvent(this.clientId);
  final int clientId;
}

class AncsConnect extends AncsEvent {
  const AncsConnect({required this.id, required this.name}) : super(id);
  final int id;
  final String name;
}

class AncsDisconnect extends AncsEvent {
  const AncsDisconnect({required int id}) : super(id);
}

class AncsNotification extends AncsEvent {
  AncsNotification({
    required int clientId,
    required this.source,
    required this.action,
  }) : super(clientId);
  final AncsNotificationSource source;

  /// Per-event notification action byte (`event[4]` in
  /// `ancs_client_cb`), routed via the 16-entry switch8 table at
  /// `0x83a1b5`. See [AncsNotificationAction].
  final AncsNotificationAction action;

  /// `0` added, `1` modified, `2` removed.
  int get eventId => source.eventId;
  int get flags => source.flags;
  int get categoryId => source.categoryId;
}

/// NotificationSource data payload (event_id=2, action=0). The longer
/// attribute payload from `FUN_00839fee`.
class AncsDataSource extends AncsEvent {
  const AncsDataSource({required int clientId, required this.payload})
    : super(clientId);
  final Uint8List payload;
}

/// AppAttribute data payload (event_id=2, action=1). The
/// `FUN_0083a036` attribute parser feeds this — covers app-display-name,
/// subtitle, etc.
class AncsDataAttribute extends AncsEvent {
  const AncsDataAttribute({required int clientId, required this.payload})
    : super(clientId);
  final Uint8List payload;
}

/// Per-event notification action byte (`event[4]`), routed via the
/// 16-entry ARM-Thumb switch8 table at `0x83a1b5` (see
/// `GHIDRA_DECOMPILATION.md` §4.1).
enum AncsNotificationAction {
  added(0),
  modified(1),
  removed(2),
  action(3),
  category(4),
  subAction(7),
  fetchAttrs(10),
  appAttrResponse(11),
  pressOnly(13),
  releaseOnly(15),
  reserved(5),
  noop(6),
  other(8),
  reservedDebug(12),
  reservedDefault(14),
  unknown(-1);

  const AncsNotificationAction(this.byte);
  final int byte;

  static AncsNotificationAction fromByte(int b) {
    for (final a in AncsNotificationAction.values) {
      if (a.byte == b) return a;
    }
    return AncsNotificationAction.unknown;
  }
}
