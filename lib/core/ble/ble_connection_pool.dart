import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_transport.dart';

/// Owns one transport per physical watch.  A transport is deliberately not
/// shared: its protocol queues and notification subscriptions are
/// device-specific.
class BleConnectionPool extends ChangeNotifier {
  final Map<String, BleTransport> _transports = {};
  BleTransport? _idle;
  String? _activeId;

  Iterable<String> get deviceIds => _transports.keys;
  String? get activeId => _activeId;
  BleTransport? get active =>
      _activeId == null ? null : _transports[_activeId!];
  BleTransport? operator [](String id) => _transports[id];
  BleTransport get idle => _idle ??= BleTransport();

  Future<BleTransport> connect(BluetoothDevice device) async {
    final id = device.remoteId.str;
    final transport = _transports.putIfAbsent(id, () {
      final value = _idle ?? BleTransport();
      _idle = null;
      return value;
    });
    await transport.connect(device);
    _activeId = id;
    notifyListeners();
    return transport;
  }

  void select(String id) {
    if (!_transports.containsKey(id)) {
      throw ArgumentError.value(id, 'id', 'Device is not connected');
    }
    _activeId = id;
    notifyListeners();
  }

  Future<void> disconnect([String? id]) async {
    final target = id ?? _activeId;
    if (target == null) return;
    final transport = _transports.remove(target);
    if (transport == null) return;
    await transport.disconnect();
    transport.dispose();
    if (_activeId == target) {
      _activeId = _transports.keys.firstOrNull;
    }
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    for (final transport in _transports.values) {
      await transport.disconnect();
      transport.dispose();
    }
    await _idle?.disconnect();
    _idle?.dispose();
    _idle = null;
    _transports.clear();
    _activeId = null;
    notifyListeners();
    super.dispose();
  }
}

extension on Iterable<String> {
  String? get firstOrNull => isEmpty ? null : first;
}
