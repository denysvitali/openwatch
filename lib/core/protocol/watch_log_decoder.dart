import 'dart:convert';
import 'dart:typed_data';

import 'activity_parser.dart';
import 'codec.dart';
import 'device_info.dart';
import 'hr_parser.dart';
import 'h59_history_parser.dart';
import 'opcodes.dart';

const _channelAUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
const _channelBUuid = 'de5bf729-d711-4e47-af26-65e3012a5dc7';
const _fee7NotifyUuid = '0000fea2-0000-1000-8000-00805f9b34fb';
const _fee7AltNotifyUuid = '0000fea1-0000-1000-8000-00805f9b34fb';

final _nrfLine = RegExp(
  r'Notification received from ([0-9a-fA-F-]+), value: \(0x\) ([0-9A-Fa-f-]+)',
);

final _timePrefix = RegExp(r'^\S\s+(\d\d:\d\d:\d\d\.\d{3})\s+');

/// Decodes nRF Connect notification logs into protocol-level frame summaries.
///
/// This is intentionally pure Dart so it can be used from a CLI and from the
/// Flutter app without depending on BLE state.
class WatchLogDecoder {
  const WatchLogDecoder({this.captureDate});

  /// Calendar date of the capture. nRF Connect lines only carry time-of-day;
  /// this fills in the date for sleep/activity summaries.
  final DateTime? captureDate;

  WatchLogReport decodeNrfConnectLog(String text) {
    final frames = <DecodedLogFrame>[];
    final state = _AssemblyState();
    var lineNo = 0;

    for (final line in const LineSplitter().convert(text)) {
      lineNo++;
      final match = _nrfLine.firstMatch(line);
      if (match == null) continue;

      final uuid = match.group(1)!.toLowerCase();
      final bytes = _parseHexBytes(match.group(2)!);
      final timestamp = _timePrefix.firstMatch(line)?.group(1);
      final frame = _decodeFrame(lineNo, timestamp, uuid, bytes);
      frames.add(frame);
      state.accept(frame);
    }

    return WatchLogReport(
      frames: frames,
      heartRateSeries: state.finishHeartRate(),
      pressureSeries: state.finishSeries(OpA.pressure),
      hrvSeries: state.finishSeries(OpA.hrv),
    );
  }

  DecodedLogFrame decodeHex(String hex, {String? uuid}) {
    final normalizedUuid = uuid?.toLowerCase() ?? _channelAUuid;
    return _decodeFrame(1, null, normalizedUuid, _parseHexBytes(hex));
  }

  DecodedLogFrame _decodeFrame(
    int lineNo,
    String? timestamp,
    String uuid,
    Uint8List bytes,
  ) {
    final channel = _channelForUuid(uuid);
    return switch (channel) {
      WatchLogChannel.channelA => _decodeChannelA(
        lineNo,
        timestamp,
        uuid,
        bytes,
      ),
      WatchLogChannel.channelB => _decodeChannelB(
        lineNo,
        timestamp,
        uuid,
        bytes,
      ),
      WatchLogChannel.fee7 => _decodeFee7(lineNo, timestamp, uuid, bytes),
      WatchLogChannel.unknown => DecodedLogFrame(
        lineNo: lineNo,
        timestamp: timestamp,
        uuid: uuid,
        channel: channel,
        bytes: bytes,
        valid: false,
        title: 'unknown notify characteristic',
        details: const {},
      ),
    };
  }

  DecodedLogFrame _decodeChannelA(
    int lineNo,
    String? timestamp,
    String uuid,
    Uint8List bytes,
  ) {
    if (bytes.length != 16) {
      return DecodedLogFrame(
        lineNo: lineNo,
        timestamp: timestamp,
        uuid: uuid,
        channel: WatchLogChannel.channelA,
        bytes: bytes,
        valid: false,
        title: 'Channel A invalid length ${bytes.length}',
        details: const {},
      );
    }

    final valid = Codec.isValidChannelA(bytes);
    final rawOpcode = Codec.rxOpcodeRaw(bytes);
    final opcode = Codec.rxOpcode(bytes);
    final payload = Codec.rxPayload(bytes);
    final isError = Codec.rxIsError(bytes);
    final label = _labelForChannelA(opcode);
    final details = <String, Object?>{
      'opcode': _hex(opcode),
      'rawOpcode': _hex(rawOpcode),
      'label': label,
      'error': isError,
      'payload': _hexList(payload),
    };

    var title = 'A ${_hex(opcode)} $label';
    if (!valid) {
      details['expectedChecksum'] = _hex(_sum8(bytes, 0, 15));
      details['checksum'] = _hex(bytes[15]);
      title = '$title checksum mismatch';
    } else if (isError) {
      final code = payload.isEmpty ? null : payload[0];
      details['errorCode'] = code == null ? null : _hex(code);
      title = '$title error code=${code == null ? 'n/a' : _hex(code)}';
    } else {
      title = _summarizeChannelA(opcode, payload, details);
    }

    return DecodedLogFrame(
      lineNo: lineNo,
      timestamp: timestamp,
      uuid: uuid,
      channel: WatchLogChannel.channelA,
      bytes: bytes,
      valid: valid,
      title: title,
      details: details,
    );
  }

  DecodedLogFrame _decodeFee7(
    int lineNo,
    String? timestamp,
    String uuid,
    Uint8List bytes,
  ) {
    final valid = bytes.length == 16 && Codec.isValidChannelA(bytes);
    final opcode = bytes.isEmpty ? 0 : bytes[0] & 0xff;
    final payload = bytes.length >= 15
        ? Uint8List.sublistView(bytes, 1, 15)
        : Uint8List.fromList(bytes);
    final details = <String, Object?>{
      'opcode': _hex(opcode),
      'label': _labelForFee7(opcode),
      'payload': _hexList(payload),
    };
    final title = valid
        ? _summarizeFee7(opcode, payload, details)
        : 'FEE7 invalid frame';
    return DecodedLogFrame(
      lineNo: lineNo,
      timestamp: timestamp,
      uuid: uuid,
      channel: WatchLogChannel.fee7,
      bytes: bytes,
      valid: valid,
      title: title,
      details: details,
    );
  }

  DecodedLogFrame _decodeChannelB(
    int lineNo,
    String? timestamp,
    String uuid,
    Uint8List bytes,
  ) {
    if (bytes.length < 6 || bytes[0] != Codec.channelBMagic) {
      return DecodedLogFrame(
        lineNo: lineNo,
        timestamp: timestamp,
        uuid: uuid,
        channel: WatchLogChannel.channelB,
        bytes: bytes,
        valid: false,
        title: 'Channel B invalid frame',
        details: const {},
      );
    }

    final cmd = Codec.rxChannelBCmd(bytes);
    final label = _labelForChannelB(cmd);
    final isEmptySentinel = Codec.isChannelBEmptySentinel(bytes);
    final payload = Codec.rxChannelBPayload(bytes);
    final declaredLength = bytes[2] | (bytes[3] << 8);
    final declaredCrc = bytes[4] | (bytes[5] << 8);
    final valid = payload != null;
    final details = <String, Object?>{
      'cmd': _hex(cmd),
      'label': label,
      'declaredLength': isEmptySentinel ? 0 : declaredLength,
      'declaredCrc': isEmptySentinel ? null : _hex(declaredCrc),
      'payload': _hexList(payload ?? Uint8List(0)),
    };

    var title = valid
        ? 'B ${_hex(cmd)} $label len=${payload.length}'
        : 'B ${_hex(cmd)} $label CRC/length mismatch';
    if (valid && payload.isNotEmpty) {
      title = _summarizeChannelB(cmd, payload, details);
    }

    return DecodedLogFrame(
      lineNo: lineNo,
      timestamp: timestamp,
      uuid: uuid,
      channel: WatchLogChannel.channelB,
      bytes: bytes,
      valid: valid,
      title: title,
      details: details,
    );
  }

  String _summarizeChannelA(
    int opcode,
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    switch (opcode) {
      case OpA.battery:
        if (payload.isNotEmpty) {
          details['batteryPercent'] = payload[0];
          return 'A 0x03 battery ${payload[0]}%';
        }
      case OpA.dnd:
        return _summarizeDnd(payload, details);
      case OpA.timeFormat:
        return _summarizeTimeFormat(payload, details);
      case OpA.readHeartRate:
        return _summarizeHeartRateFrame(payload, details);
      case OpA.heartRateSetting:
        if (payload.length >= 3) {
          details['sub'] = _hex(payload[0]);
          details['enabled'] = payload.length >= 2 ? payload[1] == 1 : null;
          details['intervalMinutes'] = payload[2];
          return 'A 0x16 HR setting sub=${_hex(payload[0])} '
              'enabled=${payload.length >= 2 && payload[1] == 1} '
              'interval=${payload[2]}m';
        }
      case OpA.bloodOxygenSetting:
        if (payload.length >= 2) {
          details['sub'] = _hex(payload[0]);
          details['enabled'] = payload[1] != 0;
          return 'A 0x2c SpO2 setting sub=${_hex(payload[0])} '
              'enabled=${payload[1] != 0}';
        }
      case OpA.pressure:
      case OpA.hrv:
        return _summarizeFourChunkSeriesFrame(opcode, payload, details);
      case OpA.pressureSetting:
        if (payload.length >= 2) {
          details['sub'] = _hex(payload[0]);
          details['enabled'] = payload[1] != 0;
          return 'A ${_hex(opcode)} ${_labelForChannelA(opcode)} '
              'sub=${_hex(payload[0])} enabled=${payload[1] != 0}';
        }
      case OpA.readDetailSport:
        return _summarizeSportDetail(payload, details);
      case OpA.todaySport:
        final totals = _parseTodaySport(payload);
        if (totals != null) {
          details.addAll(totals.toJson());
          return 'A 0x48 today sport steps=${totals.steps} '
              'kcal=${totals.calories} distance=${totals.distanceMeters}m';
        }
      case OpA.readAlarm:
        return _summarizeAlarmRead(
          opcode,
          payload,
          details,
          label: 'clock alarm',
        );
      case OpA.readDrinkAlarm:
        return _summarizeAlarmRead(
          opcode,
          payload,
          details,
          label: 'drink alarm',
        );
      case OpA.startMeasure:
        final parsed = HrParser.parseStartMeasureReply(payload);
        if (parsed != null) {
          details['type'] = parsed.type;
          details['err'] = parsed.err;
          details['bpm'] = parsed.bpm;
          if (payload.length >= 7) {
            details['auxU16At5'] = Codec.readU16le(payload, 5);
          }
          return 'A 0x69 measurement type=${parsed.type} err=${parsed.err} '
              'bpm=${parsed.bpm ?? 'pending'}';
        }
      case OpA.packageLength:
        if (payload.isNotEmpty) {
          details['packageLength'] = payload[0];
          return 'A 0x2f package length ${payload[0]}';
        }
      case OpA.displayClock:
        return _summarizeDisplayClockToggle(payload, details);
      case OpA.watchfaceDisplayClock:
        return _summarizeWatchfaceDisplayClock(payload, details);
      case OpA.displayOrientation:
        return _summarizeDisplayOrientation(payload, details);
      case OpA.displayStyle:
        return _summarizeByteSetting(
          opcode,
          payload,
          details,
          label: 'displayStyle',
          field: 'style',
        );
      case OpA.displayTime:
        return _summarizeDisplayTime(payload, details);
      case OpA.brightness:
        return _summarizeByteSetting(
          opcode,
          payload,
          details,
          label: 'brightness',
          field: 'level',
        );
      case OpA.degreeSwitch:
        return _summarizeDegreeSwitch(payload, details);
      case OpA.palmScreen:
        return _summarizePalmScreen(payload, details);
      case OpA.intell:
        return _summarizeIntell(payload, details);
      case OpA.musicNotify:
        return _summarizeMusicNotify(payload, details);
      case OpA.deviceNotify:
        return 'A 0x73 device notify payload=${_compactHex(payload)}';
      case OpA.queryDataDistribution:
        if (payload.length >= 4) {
          final mask = Codec.readU32be(payload, 0);
          final days = _daysWithData(mask);
          details['mask'] = mask;
          details['daysWithData'] = days;
          return 'A 0x46 data distribution mask=${_hex32(mask)} offsets=$days';
        }
    }
    return 'A ${_hex(opcode)} ${_labelForChannelA(opcode)} '
        'payload=${_compactHex(payload)}';
  }

  String _summarizeAlarmRead(
    int opcode,
    Uint8List payload,
    Map<String, Object?> details, {
    required String label,
  }) {
    if (payload.length < 4) {
      return 'A ${_hex(opcode)} $label short payload';
    }
    final slot = payload[0];
    final enabled = payload[1] == 1;
    final hour = Codec.fromBcd(payload[2]);
    final minute = Codec.fromBcd(payload[3]);
    final weekdays = [
      for (var i = 0; i < 7; i++)
        if (payload.length > 4 + i && payload[4 + i] != 0) i,
    ];
    var weekMask = 0;
    for (final day in weekdays) {
      weekMask |= 1 << day;
    }
    details.addAll({
      'slot': slot,
      'enabled': enabled,
      'hour': hour,
      'minute': minute,
      'weekMask': weekMask,
      'weekdays': weekdays,
    });
    return 'A ${_hex(opcode)} $label slot=$slot enabled=$enabled '
        'time=${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')} weekMask=0x'
        '${weekMask.toRadixString(16).padLeft(2, '0')}';
  }

  String _summarizeDnd(Uint8List payload, Map<String, Object?> details) {
    if (payload.length < 6) return 'A 0x06 doNotDisturb short payload';
    final sub = _addSub(details, payload[0]);
    final enabled = _addWireBool12(details, 'enabled', payload[1]);
    details.addAll({
      'startHour': payload[2],
      'startMinute': payload[3],
      'endHour': payload[4],
      'endMinute': payload[5],
    });
    return 'A 0x06 doNotDisturb sub=$sub enabled=${_boolText(enabled)} '
        'window=${_hhmm(payload[2], payload[3])}-${_hhmm(payload[4], payload[5])}';
  }

  String _summarizeTimeFormat(Uint8List payload, Map<String, Object?> details) {
    if (payload.length < 2) return 'A 0x0a timeFormat short payload';
    final sub = _addSub(details, payload[0]);
    final is24Hour = _wireBoolInverted01(payload[1]);
    final metric = payload.length >= 3 ? _wireBoolInverted01(payload[2]) : null;
    details['is24Hour'] = is24Hour;
    details['metric'] = metric;
    return 'A 0x0a timeFormat sub=$sub '
        'is24Hour=${_boolText(is24Hour)} metric=${_boolText(metric)}';
  }

  String _summarizeDisplayClockToggle(
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    if (payload.length < 2) {
      return 'A 0x12 display clock short payload';
    }
    final sub = payload[0];
    final state = payload[1];
    final subHex = _addSub(details, sub);
    details['state'] = state;
    final enabled = _wireBool12(state);
    if (enabled != null) {
      details['enabled'] = enabled;
    }
    return 'A 0x12 displayClock sub=$subHex state=$state '
        'enabled=${_boolText(enabled)}';
  }

  String _summarizeWatchfaceDisplayClock(
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    if (payload.length < 3) {
      return 'A 0x18 watchface display clock short payload';
    }
    final style = payload[0];
    final length = payload[1];
    final echoedLength = payload[2];
    final labelStart = payload.length > 3 ? 3 : payload.length;
    final labelEnd = (labelStart + echoedLength).clamp(0, payload.length);
    final labelBytes = payload.sublist(labelStart, labelEnd);
    final label = String.fromCharCodes(labelBytes.where((b) => b != 0)).trim();
    details.addAll({
      'style': style,
      'length': length,
      'echoedLength': echoedLength,
      'echoedLabel': label,
    });
    return 'A 0x18 watchfaceDisplayClock style=${_hex(style)} length=$length '
        'echoedLength=$echoedLength label=${label.isEmpty ? 'none' : '"$label"'}';
  }

  String _summarizeDisplayOrientation(
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    if (payload.length < 3) {
      return 'A 0x29 displayOrientation short payload';
    }
    final sub = _addSub(details, payload[0]);
    final autoRotate = _addWireBool12(details, 'autoRotate', payload[1]);
    final landscape = _addWireBool12(details, 'landscape', payload[2]);
    return 'A 0x29 displayOrientation sub=$sub '
        'autoRotate=${_boolText(autoRotate)} '
        'landscape=${_boolText(landscape)}';
  }

  String _summarizeByteSetting(
    int opcode,
    Uint8List payload,
    Map<String, Object?> details, {
    required String label,
    required String field,
  }) {
    if (payload.length < 2) {
      return 'A ${_hex(opcode)} $label short payload';
    }
    final sub = _addSub(details, payload[0]);
    details[field] = payload[1];
    return 'A ${_hex(opcode)} $label sub=$sub $field=${payload[1]}';
  }

  String _summarizeDisplayTime(
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    if (payload.length < 7) return 'A 0x1f displayTime short payload';
    final sub = _addSub(details, payload[0]);
    details.addAll({
      'displayTime': payload[1],
      'displayType': payload[2],
      'alpha': payload[3],
      'reserved': payload[4],
      'total': payload[5],
      'current': payload[6],
    });
    return 'A 0x1f displayTime sub=$sub '
        'time=${payload[1]} type=${payload[2]} alpha=${payload[3]} '
        'index=${payload[6]}/${payload[5]}';
  }

  String _summarizeDegreeSwitch(
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    if (payload.length < 3) return 'A 0x19 degreeSwitch short payload';
    final sub = _addSub(details, payload[0]);
    final enabled = _addWireBool12(details, 'enabled', payload[1]);
    final isCelsius = _addWireBool12(details, 'isCelsius', payload[2]);
    return 'A 0x19 degreeSwitch sub=$sub '
        'enabled=${_boolText(enabled)} '
        'unit=${isCelsius == null ? 'unknown' : (isCelsius ? 'C' : 'F')}';
  }

  String _summarizePalmScreen(Uint8List payload, Map<String, Object?> details) {
    if (payload.length < 4) return 'A 0x05 palmScreen short payload';
    final sub = _addSub(details, payload[0]);
    final enabled = _addWireBool12(details, 'enabled', payload[1]);
    final secondary = _addWireBool12(details, 'secondary', payload[2]);
    final commitFlag = (payload[3] & 0x04) != 0;
    details.addAll({'commitFlag': commitFlag, 'flags': _hex(payload[3])});
    return 'A 0x05 palmScreen sub=$sub '
        'enabled=${_boolText(enabled)} secondary=${_boolText(secondary)} '
        'commitFlag=$commitFlag flags=${_hex(payload[3])}';
  }

  String _summarizeIntell(Uint8List payload, Map<String, Object?> details) {
    if (payload.length < 3) return 'A 0x09 intell short payload';
    final sub = _addSub(details, payload[0]);
    final enabled = _addWireBool12(details, 'enabled', payload[1]);
    details.addAll({'delaySeconds': payload[2]});
    return 'A 0x09 intell sub=$sub '
        'enabled=${_boolText(enabled)} delay=${payload[2]}s';
  }

  String _summarizeMusicNotify(
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    if (payload.length < 4) {
      return 'A 0x1d music notify short payload';
    }
    final playing = (payload[0] ^ 0x01) != 0;
    final progress = payload[1] & 0xFF;
    final volume = payload[2] & 0xFF;
    var start = 3;
    if (start < payload.length && payload[start] == 0) start++;
    final title = String.fromCharCodes(
      payload.sublist(start).where((b) => b != 0),
    ).trim();
    details.addAll({
      'playing': playing,
      'progress': progress,
      'volume': volume,
      'track': title,
    });
    final trackSummary = title.isEmpty ? 'untitled' : '"$title"';
    return 'A 0x1d music playing=$playing progress=$progress '
        'volume=$volume track=$trackSummary';
  }

  String _summarizeFee7(
    int opcode,
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    switch (opcode) {
      case Fee7.battery:
        final battery = payload.isNotEmpty ? payload[0] : null;
        final charging = payload.length >= 2 ? payload[1] != 0 : null;
        details.addAll({'batteryPercent': battery, 'charging': charging});
        return 'FEE7 ${_hex(opcode)} battery'
            '${battery == null ? '' : ' $battery%'}'
            '${charging == null ? '' : ' charging=$charging'}';
      case Fee7.statusResponse:
        final statusValue = payload.length >= 4
            ? Codec.readU32le(payload, 0)
            : 0;
        final statusLowByte = statusValue & 0xFF;
        details.addAll({
          'statusValue': statusValue,
          'statusLowByte': statusLowByte,
          'idle': statusValue == 0,
        });
        return 'FEE7 ${_hex(opcode)} status value=${_hex32(statusValue)} '
            'low=${_hex(statusLowByte)} idle=${statusValue == 0}';
      case Fee7.otaTrigger:
        final action = payload.isNotEmpty ? payload[0] : 0;
        final serviceResetRequested = payload.length >= 2 && payload[1] == 1;
        final startsDfu = action == 1;
        final exitsDfu = action == 2;
        details.addAll({
          'action': action,
          'serviceResetRequested': serviceResetRequested,
          'startsDfu': startsDfu,
          'exitsDfu': exitsDfu,
          'routesToOta': startsDfu,
        });
        return 'FEE7 ${_hex(opcode)} otaControl action=$action '
            'reset=$serviceResetRequested';
      case Fee7.firmwareBuildInfo:
        final versionBuild = _trimNulAscii(payload);
        final headerAck = versionBuild.isEmpty && payload.every((b) => b == 0);
        details.addAll({
          'versionBuild': versionBuild.isEmpty ? null : versionBuild,
          'headerAck': headerAck,
        });
        return headerAck
            ? 'FEE7 ${_hex(opcode)} firmwareBuildInfo header'
            : 'FEE7 ${_hex(opcode)} firmwareBuildInfo "$versionBuild"';
      case Fee7.sessionMode1Ack:
      case Fee7.sessionMode2Ack:
        final mode = opcode == Fee7.sessionMode1Ack ? 1 : 2;
        details['mode'] = mode;
        return 'FEE7 ${_hex(opcode)} sessionModeAck mode=$mode';
      case Fee7.sessionModeStatus:
        final stateByte = payload.isNotEmpty ? payload[0] : null;
        details.addAll({'stateByte': stateByte, 'isMode2': stateByte == 0x88});
        return 'FEE7 ${_hex(opcode)} sessionModeStatus'
            '${stateByte == null ? '' : ' state=${_hex(stateByte)}'}';
      case Fee7.factoryStop:
        return 'FEE7 ${_hex(opcode)} factoryStop';
      case Fee7.modelName:
        final modelName = _trimNulAscii(payload);
        details['modelName'] = modelName;
        return 'FEE7 ${_hex(opcode)} modelName "$modelName"';
      case Fee7.highStatusFrame:
        details.addAll({
          'dataBytes': payload.length,
          'field0': payload.isNotEmpty ? payload[0] : null,
          'marker23': payload.length >= 2 ? payload[1] == 0x23 : null,
          'marker21': payload.length >= 3 ? payload[2] == 0x21 : null,
        });
        return 'FEE7 ${_hex(opcode)} highStatus bytes=${payload.length}';
      case Fee7.memoryRead:
        details['dataBytes'] = payload.length;
        return 'FEE7 ${_hex(opcode)} memoryRead chunk bytes=${payload.length}';
      case Fee7.syntheticSleep:
        final durationMinutes = payload.length >= 2
            ? payload[0] | (payload[1] << 8)
            : null;
        if (durationMinutes != null) {
          details['durationMinutes'] = durationMinutes;
        }
        return 'FEE7 ${_hex(opcode)} syntheticSleep'
            '${durationMinutes == null ? '' : ' duration=${durationMinutes}m'}';
      default:
        final label = _labelForFee7(opcode);
        if (Fee7.isUnary(opcode)) {
          return 'FEE7 ${_hex(opcode)} ${label == 'unary' ? 'unary' : label}';
        }
        return 'FEE7 ${_hex(opcode)} $label';
    }
  }

  String _summarizeHeartRateFrame(
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    if (payload.isEmpty) return 'A 0x15 HR empty payload';
    final tag = payload[0];
    if (tag == 0x00 && payload.length >= 3 && payload[1] > 0) {
      final totalFrames = payload[1];
      details['hrHeaderShape'] = 'seq0-totalFrames';
      details['totalFrames'] = totalFrames;
      details['expectedChunks'] = totalFrames - 1;
      details['sampleIntervalMinutes'] = payload[2];
      return 'A 0x15 HR history header chunks=${totalFrames - 1} '
          'interval=${payload[2]}m';
    }
    if (tag == 0x18) {
      details['hrHeaderShape'] = 'legacy-size-tag';
      return 'A 0x15 HR history header legacy tag=0x18';
    }
    if (tag == 0xff) return 'A 0x15 HR no-data/end marker';
    details['seq'] = tag;
    details['dataBytes'] = payload.length - 1;
    return 'A 0x15 HR chunk seq=$tag bytes=${payload.length - 1}';
  }

  String _summarizeFourChunkSeriesFrame(
    int opcode,
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    final label = _labelForChannelA(opcode);
    if (payload.length >= 3 && payload[0] == 0x00 && payload[2] == 0x1e) {
      details['seriesHeader'] = true;
      details['slotId'] = payload[0];
      details['totalFrames'] = payload[1];
      return 'A ${_hex(opcode)} $label header slot=${payload[0]} '
          'frames=${payload[1]}';
    }
    if (payload.isNotEmpty && payload[0] >= 1 && payload[0] <= 4) {
      details['seq'] = payload[0];
      details['dataBytes'] = payload.length - 1;
      return 'A ${_hex(opcode)} $label chunk seq=${payload[0]} '
          'bytes=${payload.length - 1}';
    }
    return 'A ${_hex(opcode)} $label payload=${_compactHex(payload)}';
  }

  String _summarizeSportDetail(
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    if (payload.length < 4) return 'A 0x43 sport detail short payload';
    if (payload[0] == 0xf0 || payload[0] == 0xff) {
      details['endOfData'] = payload[0] == 0xff;
      details['recordCount'] = payload[1];
      details['unitFlag'] = payload[2];
      return payload[0] == 0xff
          ? 'A 0x43 sport detail empty/end'
          : 'A 0x43 sport detail header records=${payload[1]} '
                'unit=${payload[2]}';
    }
    if (payload.length >= 12) {
      final year = 2000 + Codec.fromBcd(payload[0]);
      final month = Codec.fromBcd(payload[1]);
      final day = Codec.fromBcd(payload[2]);
      final slot = (payload[3] >> 2) & 0x3f;
      final recordIdx = payload[4];
      final recordCount = payload[5];
      final durationSeconds = Codec.readU16le(payload, 6);
      final steps = Codec.readU16le(payload, 8);
      final distance = Codec.readU16le(payload, 10);
      details.addAll({
        'date': _dateString(year, month, day),
        'slot': slot,
        'recordIdx': recordIdx,
        'recordCount': recordCount,
        'durationSeconds': durationSeconds,
        'steps': steps,
        'distanceMeters': distance,
      });
      return 'A 0x43 sport detail ${_dateString(year, month, day)} '
          'slot=$slot idx=$recordIdx/$recordCount steps=$steps '
          'distance=${distance}m';
    }
    return 'A 0x43 sport detail payload=${_compactHex(payload)}';
  }

  String _summarizeChannelB(
    int cmd,
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    if (_isH59NoopChannelB(cmd)) {
      details['firmwareBehavior'] = 'no-op';
      details['payloadBytes'] = payload.length;
      return 'B ${_hex(cmd)} ${_labelForChannelB(cmd)} no-op '
          'payloadBytes=${payload.length}';
    }
    if (_isH59ExplicitRejectChannelB(cmd)) {
      details['firmwareBehavior'] = 'compact-nak-2';
      details['compactNakCode'] = 2;
      details['payloadBytes'] = payload.length;
      return 'B ${_hex(cmd)} ${_labelForChannelB(cmd)} explicit-reject '
          'compactNak=2 payloadBytes=${payload.length}';
    }
    if (_isUnsupportedApkFileHandleChannelB(cmd)) {
      details['firmwareBehavior'] = 'compact-nak-0';
      details['payloadBytes'] = payload.length;
      return 'B ${_hex(cmd)} ${_labelForChannelB(cmd)} unsupported '
          'compactNak=0 payloadBytes=${payload.length}';
    }
    if (_isUnsupportedApkSidecarChannelB(cmd)) {
      details['firmwareBehavior'] = 'compact-nak-0';
      details['payloadBytes'] = payload.length;
      return 'B ${_hex(cmd)} ${_labelForChannelB(cmd)} unsupported '
          'compactNak=0 payloadBytes=${payload.length}';
    }

    switch (cmd) {
      case OpB.h59SleepSummary:
        if (payload.isEmpty) {
          details['firmwareBehavior'] = 'empty-payload';
          return 'B 0x11 H59 sleep summary empty payload';
        }
        final dayOffset = payload[0] & 0xff;
        final bodyBytes = payload.length - 1;
        details['dayOffset'] = dayOffset;
        details['summaryBytes'] = bodyBytes;
        final summary = H59HistoryParser.parseSummary(payload);
        if (summary != null) {
          details['startMinute'] = summary.startMinute;
          details['endMinute'] = summary.endMinute;
          details['segmentCount'] = summary.segments.length;
        } else {
          details['layoutValid'] = false;
        }
        return 'B 0x11 H59 sleep summary dayOffset=$dayOffset '
            'segments=${summary?.segments.length ?? 'invalid'} bytes=$bodyBytes';
      case OpB.h59SleepDetail:
        final dayOffset = payload[0] & 0xff;
        if (payload.length == 1) {
          details['compactStatusCode'] = dayOffset;
          details['firmwareBehavior'] = 'compact-status';
          details['payloadBytes'] = payload.length;
          return 'B 0x12 H59 sleep detail compactStatus=${_hex(dayOffset)}';
        }
        final bodyBytes = payload.length - 1;
        details['dayOffset'] = dayOffset;
        details['detailBytes'] = bodyBytes;
        final detail = H59HistoryParser.parseDetail(payload);
        if (detail != null) {
          details.addAll({
            'steps': detail.steps,
            'calories': detail.calories,
            'distanceMeters': detail.distanceMeters,
            'durationSeconds': detail.durationSeconds,
          });
        } else {
          details['layoutValid'] = false;
        }
        return 'B 0x12 H59 sleep detail dayOffset=$dayOffset '
            'steps=${detail?.steps ?? 'invalid'} '
            'distance=${detail?.distanceMeters ?? 'invalid'}m bytes=$bodyBytes';
      case OpB.sleepNew:
        final summary = _parseSleep(
          payload,
          isNight: true,
          captureDate: captureDate,
        );
        details.addAll(summary.toJson());
        return 'B 0x27 night sleep dayOffset=${summary.dayOffset ?? 'n/a'} '
            'segments=${summary.segmentCount} total=${summary.totalMinutes}m';
      case OpB.sleepLunchNew:
        final summary = _parseSleep(
          payload,
          isNight: false,
          captureDate: captureDate,
        );
        details.addAll(summary.toJson());
        return 'B 0x3e nap sleep segments=${summary.segmentCount} '
            'total=${summary.totalMinutes}m';
      case OpB.activitySummary:
        final records = _parseActivitySummary(payload);
        details['records'] = records.map((r) => r.toJson()).toList();
        return 'B 0x2a SpO2-hour records=${records.length} '
            '${records.map((r) => 'd${r.dayOffset}:spo2=${r.spo2Max ?? 'n/a'}/${r.spo2Min ?? 'n/a'}').join(', ')}';
      case OpB.alarm:
        return _summarizeChannelBAlarm(payload, details);
      case OpB.h59FileListResponse:
        final summary = _parseH59FileList(payload);
        details.addAll(summary.toJson());
        return 'B 0x42 H59 file list records=${summary.declaredCount} '
            'parsed=${summary.records.length} bytes=${summary.recordBytes}'
            '${summary.malformed ? ' malformed' : ''}';
      case OpB.h59FileMetadata:
        return _summarizeH59FileMetadata(payload, details);
      case OpB.h59FileChunk:
        return _summarizeH59FileChunk(payload, details);
      case OpB.deviceInfoConfig:
        return _summarizeDeviceInfoConfig(payload, details);
    }
    if (_labelForChannelB(cmd) == 'unknown' && payload.length == 1) {
      final status = payload[0] & 0xff;
      details['compactStatusCode'] = status;
      details['firmwareBehavior'] = 'compact-status';
      details['payloadBytes'] = payload.length;
      return 'B ${_hex(cmd)} unknown compactStatus=${_hex(status)}';
    }
    return 'B ${_hex(cmd)} ${_labelForChannelB(cmd)} '
        'payload=${_compactHex(payload)}';
  }

  String _summarizeChannelBAlarm(
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    if (payload.isEmpty) return 'B 0x2c alarm empty payload';

    final sub = payload[0] & 0xff;
    details['sub'] = _hex(sub);
    if (sub == 0x02) {
      details['ack'] = true;
      return 'B 0x2c alarm write ack';
    }
    if (sub != 0x01) {
      return 'B 0x2c alarm sub=${_hex(sub)} payload=${_compactHex(payload)}';
    }
    if (payload.length < 2) return 'B 0x2c alarm read short payload';

    final declaredCount = payload[1] & 0xff;
    final records = <Map<String, Object?>>[];
    var offset = 2;
    var malformed = false;
    for (var i = 0; i < declaredCount && offset < payload.length; i++) {
      final recordLen = payload[offset] & 0x7f;
      if (recordLen < 4 || offset + recordLen > payload.length) {
        malformed = true;
        break;
      }
      final flags = payload[offset + 1] & 0xff;
      final minuteOfDay = Codec.readU16le(payload, offset + 2);
      final hour = (minuteOfDay ~/ 60) % 24;
      final minute = minuteOfDay % 60;
      final labelBytes = Uint8List.sublistView(
        payload,
        offset + 4,
        offset + recordLen,
      );
      final label = _trimNulAscii(labelBytes).trim();
      records.add({
        'length': recordLen,
        'flags': _hex(flags),
        'flag80': (flags & 0x80) != 0,
        'weekMask': flags & 0x7f,
        'weekdays': [
          for (var d = 0; d < 7; d++)
            if ((flags & (1 << d)) != 0) d,
        ],
        'minuteOfDay': minuteOfDay,
        'time': _hhmm(hour, minute),
        'label': label,
        'labelBytes': labelBytes.length,
      });
      offset += recordLen;
    }
    if (records.length < declaredCount) malformed = true;

    details['declaredCount'] = declaredCount;
    details['alarmRecords'] = records;
    details['malformed'] = malformed;
    details['trailingBytes'] = payload.length - offset;
    final first = records.isEmpty ? null : records.first;
    final firstSummary = first == null
        ? ''
        : ' first=${first['time']}'
              '${(first['label'] as String).isEmpty ? '' : ' "${first['label']}"'}';
    return 'B 0x2c alarm read records=${records.length}/$declaredCount'
        '$firstSummary${malformed ? ' malformed' : ''}';
  }

  String _summarizeDeviceInfoConfig(
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    if (payload.isEmpty) return 'B 0x5a device info empty payload';

    final sub = payload[0] & 0xff;
    details['sub'] = _hex(sub);

    if (sub == 0x01) {
      final cfg = DeviceInfoConfig.tryParse(payload);
      if (cfg == null) return 'B 0x5a device info query invalid TLV';
      details['tlvCount'] = cfg.count;
      return 'B 0x5a device info query tlvs=${cfg.count}';
    }

    if (sub == 0x03) {
      final info = DeviceInfoStatic.tryParse(payload);
      if (info == null) return 'B 0x5a device info static invalid TLV';
      details.addAll({
        'tlvCount': info.count,
        'modelName': info.modelName,
        'productName': info.productName,
        'hardwareId': info.hardwareId,
        'firmwareVersion': info.firmwareVersion,
        'buildCode': info.buildCode,
      });
      return 'B 0x5a device info static ${info.firmwareVersion ?? 'unknown'}';
    }

    if (payload.length >= 3 && sub == 0x5a) {
      details['status'] = payload[1] & 0xff;
      details['error'] = payload[2] & 0xff;
      return 'B 0x5a device info status=${payload[1]} err=${payload[2]}';
    }

    return 'B 0x5a device info sub=${_hex(sub)} '
        'payload=${_compactHex(payload)}';
  }

  String _summarizeH59FileMetadata(
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    final status = payload[0] & 0xff;
    details['fileStatus'] = _hex(status);
    details['metadataBytes'] = payload.length;

    if (status == 0x00) {
      if (payload.length < 6) {
        details['metadataMalformed'] = true;
        return 'B 0x44 H59 file metadata ok short bytes=${payload.length}';
      }
      final chunkCount = payload[1] | (payload[2] << 8);
      details['chunkCount'] = chunkCount;
      details['metadataByte3'] = _hex(payload[3]);
      details['metadataByte4'] = _hex(payload[4]);
      details['metadataByte5'] = _hex(payload[5]);
      return 'B 0x44 H59 file metadata ok chunks=$chunkCount';
    }

    if (status == 0x01) {
      final selector = payload.length > 1 ? payload[1] & 0xff : null;
      final recordId = payload.length >= 6 ? Codec.readU32le(payload, 2) : null;
      details['selector'] = selector == null ? null : _hex(selector);
      details['recordId'] = recordId == null ? null : _hex32(recordId);
      details['metadataMalformed'] = payload.length < 6;
      return 'B 0x44 H59 file metadata not-found '
          'selector=${selector == null ? 'n/a' : _hex(selector)} '
          'recordId=${recordId == null ? 'n/a' : _hex32(recordId)}';
    }

    if (status == 0x02) {
      final selector = payload.length > 1 ? payload[1] & 0xff : null;
      details['selector'] = selector == null ? null : _hex(selector);
      details['metadataMalformed'] = payload.length < 2;
      return 'B 0x44 H59 file metadata invalid-selector '
          '${selector == null ? 'n/a' : _hex(selector)}';
    }

    details['metadataMalformed'] = true;
    return 'B 0x44 H59 file metadata status=${_hex(status)} '
        'bytes=${payload.length}';
  }

  String _summarizeH59FileChunk(
    Uint8List payload,
    Map<String, Object?> details,
  ) {
    if (payload.length < 2) {
      details['chunkMalformed'] = true;
      details['chunkDataBytes'] = 0;
      return 'B 0x45 H59 file chunk short bytes=${payload.length}';
    }

    final chunkIndex = payload[0] & 0xff;
    final reserved = payload[1] & 0xff;
    final dataBytes = payload.length - 2;
    details['chunkIndex'] = chunkIndex;
    details['chunkReserved'] = _hex(reserved);
    details['chunkDataBytes'] = dataBytes;
    details['chunkMalformed'] = reserved != 0;
    return 'B 0x45 H59 file chunk index=$chunkIndex bytes=$dataBytes'
        '${reserved == 0 ? '' : ' reserved=${_hex(reserved)}'}';
  }
}

class WatchLogReport {
  const WatchLogReport({
    required this.frames,
    required this.heartRateSeries,
    required this.pressureSeries,
    required this.hrvSeries,
  });

  final List<DecodedLogFrame> frames;
  final List<HeartRateSeriesSummary> heartRateSeries;
  final List<ByteSeriesSummary> pressureSeries;
  final List<ByteSeriesSummary> hrvSeries;

  int get validFrameCount => frames.where((f) => f.valid).length;

  int get invalidFrameCount => frames.length - validFrameCount;

  Map<String, int> get channelCounts {
    final counts = <String, int>{};
    for (final frame in frames) {
      counts.update(frame.channel.name, (v) => v + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  Iterable<DecodedLogFrame> get invalidFrames => frames.where((f) => !f.valid);

  Map<String, Object?> toJson({bool includeFrames = true}) => {
    'frameCount': frames.length,
    'validFrameCount': validFrameCount,
    'invalidFrameCount': invalidFrameCount,
    'channelCounts': channelCounts,
    'heartRateSeries': heartRateSeries.map((s) => s.toJson()).toList(),
    'pressureSeries': pressureSeries.map((s) => s.toJson()).toList(),
    'hrvSeries': hrvSeries.map((s) => s.toJson()).toList(),
    if (includeFrames) 'frames': frames.map((f) => f.toJson()).toList(),
  };
}

enum WatchLogChannel { channelA, channelB, fee7, unknown }

class DecodedLogFrame {
  const DecodedLogFrame({
    required this.lineNo,
    required this.timestamp,
    required this.uuid,
    required this.channel,
    required this.bytes,
    required this.valid,
    required this.title,
    required this.details,
  });

  final int lineNo;
  final String? timestamp;
  final String uuid;
  final WatchLogChannel channel;
  final Uint8List bytes;
  final bool valid;
  final String title;
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => {
    'lineNo': lineNo,
    if (timestamp != null) 'timestamp': timestamp,
    'uuid': uuid,
    'channel': channel.name,
    'valid': valid,
    'title': title,
    'bytes': _compactHex(bytes),
    'details': details,
  };
}

class HeartRateSeriesSummary {
  const HeartRateSeriesSummary({
    required this.startedAtLine,
    required this.timestamp,
    required this.expectedChunks,
    required this.receivedChunks,
    required this.sampleIntervalMinutes,
    required this.samples,
    required this.minBpm,
    required this.maxBpm,
    required this.avgBpm,
  });

  final int startedAtLine;
  final DateTime? timestamp;
  final int? expectedChunks;
  final int receivedChunks;
  final int sampleIntervalMinutes;
  final int samples;
  final int? minBpm;
  final int? maxBpm;
  final double? avgBpm;

  Map<String, Object?> toJson() => {
    'startedAtLine': startedAtLine,
    'timestamp': timestamp?.toIso8601String(),
    'expectedChunks': expectedChunks,
    'receivedChunks': receivedChunks,
    'sampleIntervalMinutes': sampleIntervalMinutes,
    'samples': samples,
    'minBpm': minBpm,
    'maxBpm': maxBpm,
    'avgBpm': avgBpm == null ? null : double.parse(avgBpm!.toStringAsFixed(1)),
  };
}

class ByteSeriesSummary {
  const ByteSeriesSummary({
    required this.opcode,
    required this.startedAtLine,
    required this.expectedChunks,
    required this.receivedChunks,
    required this.byteCount,
    required this.nonZeroCount,
    required this.minNonZero,
    required this.maxNonZero,
  });

  final int opcode;
  final int startedAtLine;
  final int? expectedChunks;
  final int receivedChunks;
  final int byteCount;
  final int nonZeroCount;
  final int? minNonZero;
  final int? maxNonZero;

  Map<String, Object?> toJson() => {
    'opcode': _hex(opcode),
    'label': _labelForChannelA(opcode),
    'startedAtLine': startedAtLine,
    'expectedChunks': expectedChunks,
    'receivedChunks': receivedChunks,
    'byteCount': byteCount,
    'nonZeroCount': nonZeroCount,
    'minNonZero': minNonZero,
    'maxNonZero': maxNonZero,
  };
}

class ActivityRecordSummary {
  const ActivityRecordSummary({
    required this.dayOffset,
    required this.spo2Max,
    required this.spo2Min,
    required this.hoursWithData,
  });

  final int dayOffset;
  final int? spo2Max;
  final int? spo2Min;
  final int hoursWithData;

  Map<String, Object?> toJson() => {
    'dayOffset': dayOffset,
    'spo2Max': spo2Max,
    'spo2Min': spo2Min,
    'hoursWithData': hoursWithData,
  };
}

class _H59FileListSummary {
  const _H59FileListSummary({
    required this.declaredCount,
    required this.recordBytes,
    required this.records,
    required this.trailingBytes,
    required this.malformed,
  });

  final int declaredCount;
  final int recordBytes;
  final List<_H59FileRecordSummary> records;
  final int trailingBytes;
  final bool malformed;

  Map<String, Object?> toJson() => {
    'fileRecordCount': declaredCount,
    'fileParsedRecordCount': records.length,
    'fileRecordBytes': recordBytes,
    'fileTrailingBytes': trailingBytes,
    'fileMalformed': malformed,
    'fileRecords': records.map((r) => r.toJson()).toList(),
  };
}

class _H59FileRecordSummary {
  const _H59FileRecordSummary({
    required this.index,
    required this.recordLength,
    required this.recordType,
    required this.fields,
    required this.rawHex,
    required this.malformed,
  });

  final int index;
  final int recordLength;
  final int? recordType;
  final List<_H59FileFieldSummary> fields;
  final String rawHex;
  final bool malformed;

  Map<String, Object?> toJson() => {
    'index': index,
    'length': recordLength,
    'recordType': recordType == null ? null : _hex(recordType!),
    'fieldCount': fields.length,
    'malformed': malformed,
    'raw': rawHex,
    'fields': fields.map((f) => f.toJson()).toList(),
  };
}

class _H59FileFieldSummary {
  const _H59FileFieldSummary({
    required this.fieldLength,
    required this.fieldId,
    required this.valueHex,
  });

  final int fieldLength;
  final int fieldId;
  final String valueHex;

  Map<String, Object?> toJson() => {
    'length': fieldLength,
    'fieldId': _hex(fieldId),
    'value': valueHex,
  };
}

class SleepSummary {
  const SleepSummary({
    required this.dayOffset,
    required this.wakeDate,
    required this.segmentCount,
    required this.totalMinutes,
    required this.stageMinutes,
  });

  final int? dayOffset;
  final String? wakeDate;
  final int segmentCount;
  final int totalMinutes;
  final Map<String, int> stageMinutes;

  Map<String, Object?> toJson() => {
    'dayOffset': dayOffset,
    'wakeDate': wakeDate,
    'segmentCount': segmentCount,
    'totalMinutes': totalMinutes,
    'stageMinutes': stageMinutes,
  };
}

class _AssemblyState {
  _AssemblyState();

  _HeartRateAccumulator? _hr;
  final _series = <int, _ByteSeriesAccumulator>{};
  final _hrDone = <HeartRateSeriesSummary>[];
  final _seriesDone = <int, List<ByteSeriesSummary>>{};

  void accept(DecodedLogFrame frame) {
    if (!frame.valid || frame.channel != WatchLogChannel.channelA) return;
    final opcode = frame.details['opcode'];
    if (opcode is! String) return;
    final op = int.parse(opcode.substring(2), radix: 16);
    final payload = _payloadFromDetails(frame);
    if (payload == null) return;

    if (op == OpA.readHeartRate) {
      _acceptHeartRate(frame, payload);
    } else if (op == OpA.pressure || op == OpA.hrv) {
      _acceptByteSeries(frame, op, payload);
    }
  }

  List<HeartRateSeriesSummary> finishHeartRate() {
    final current = _hr;
    if (current != null && current.receivedChunks > 0) {
      _hrDone.add(current.finish());
    }
    _hr = null;
    return List.unmodifiable(_hrDone);
  }

  List<ByteSeriesSummary> finishSeries(int opcode) {
    final current = _series.remove(opcode);
    if (current != null && current.receivedChunks > 0) {
      _seriesDone.putIfAbsent(opcode, () => []).add(current.finish());
    }
    return List.unmodifiable(_seriesDone[opcode] ?? const []);
  }

  void _acceptHeartRate(DecodedLogFrame frame, Uint8List payload) {
    if (payload.isEmpty) return;
    if (payload[0] == 0x00 && payload.length >= 3 && payload[1] > 0) {
      final current = _hr;
      if (current != null && current.receivedChunks > 0) {
        _hrDone.add(current.finish());
      }
      _hr = _HeartRateAccumulator(
        startedAtLine: frame.lineNo,
        expectedChunks: payload[1] - 1,
        sampleIntervalMinutes: payload[2] == 0 ? 5 : payload[2],
      );
      return;
    }
    if (payload[0] == 0xff) {
      final current = _hr;
      if (current != null && current.receivedChunks > 0) {
        _hrDone.add(current.finish());
      }
      _hr = null;
      return;
    }
    final current = _hr;
    if (current == null || payload[0] == 0 || payload[0] > 0x40) return;
    current.addChunk(payload[0], Uint8List.sublistView(payload, 1));
    if (current.isComplete) {
      _hrDone.add(current.finish());
      _hr = null;
    }
  }

  void _acceptByteSeries(DecodedLogFrame frame, int opcode, Uint8List payload) {
    if (payload.length >= 3 && payload[0] == 0x00 && payload[2] == 0x1e) {
      final current = _series[opcode];
      if (current != null && current.receivedChunks > 0) {
        _seriesDone.putIfAbsent(opcode, () => []).add(current.finish());
      }
      _series[opcode] = _ByteSeriesAccumulator(
        opcode: opcode,
        startedAtLine: frame.lineNo,
        expectedChunks: payload[1] > 0 ? payload[1] - 1 : null,
      );
      return;
    }
    final current = _series[opcode];
    if (current == null || payload.isEmpty || payload[0] < 1) return;
    current.addChunk(payload[0], Uint8List.sublistView(payload, 1));
    if (current.isComplete) {
      _seriesDone.putIfAbsent(opcode, () => []).add(current.finish());
      _series.remove(opcode);
    }
  }
}

class _HeartRateAccumulator {
  _HeartRateAccumulator({
    required this.startedAtLine,
    required this.expectedChunks,
    required this.sampleIntervalMinutes,
  });

  final int startedAtLine;
  final int? expectedChunks;
  final int sampleIntervalMinutes;
  final Map<int, Uint8List> chunks = {};

  int get receivedChunks => chunks.length;

  bool get isComplete =>
      expectedChunks != null && receivedChunks >= expectedChunks!;

  void addChunk(int seq, Uint8List data) {
    chunks[seq] = Uint8List.fromList(data);
  }

  HeartRateSeriesSummary finish() {
    final ordered = chunks.keys.toList()..sort();
    final builder = BytesBuilder();
    for (final seq in ordered) {
      builder.add(chunks[seq]!);
    }
    final data = builder.toBytes();
    DateTime? timestamp;
    final bpms = <int>[];
    if (data.length >= 4) {
      timestamp = DateTime.fromMillisecondsSinceEpoch(
        Codec.readU32le(data, 0) * 1000,
      );
      for (var i = 4; i < data.length; i++) {
        final bpm = data[i] & 0xff;
        if (HrParser.isPlausibleBpm(bpm)) bpms.add(bpm);
      }
    }
    final sum = bpms.fold<int>(0, (a, b) => a + b);
    return HeartRateSeriesSummary(
      startedAtLine: startedAtLine,
      timestamp: timestamp,
      expectedChunks: expectedChunks,
      receivedChunks: receivedChunks,
      sampleIntervalMinutes: sampleIntervalMinutes,
      samples: bpms.length,
      minBpm: bpms.isEmpty ? null : bpms.reduce((a, b) => a < b ? a : b),
      maxBpm: bpms.isEmpty ? null : bpms.reduce((a, b) => a > b ? a : b),
      avgBpm: bpms.isEmpty ? null : sum / bpms.length,
    );
  }
}

class _ByteSeriesAccumulator {
  _ByteSeriesAccumulator({
    required this.opcode,
    required this.startedAtLine,
    required this.expectedChunks,
  });

  final int opcode;
  final int startedAtLine;
  final int? expectedChunks;
  final Map<int, Uint8List> chunks = {};

  int get receivedChunks => chunks.length;

  bool get isComplete =>
      expectedChunks != null && receivedChunks >= expectedChunks!;

  void addChunk(int seq, Uint8List data) {
    chunks[seq] = Uint8List.fromList(data);
  }

  ByteSeriesSummary finish() {
    final ordered = chunks.keys.toList()..sort();
    final data = <int>[];
    for (final seq in ordered) {
      data.addAll(chunks[seq]!);
    }
    final nonZero = data.where((b) => b != 0).toList();
    return ByteSeriesSummary(
      opcode: opcode,
      startedAtLine: startedAtLine,
      expectedChunks: expectedChunks,
      receivedChunks: receivedChunks,
      byteCount: data.length,
      nonZeroCount: nonZero.length,
      minNonZero: nonZero.isEmpty
          ? null
          : nonZero.reduce((a, b) => a < b ? a : b),
      maxNonZero: nonZero.isEmpty
          ? null
          : nonZero.reduce((a, b) => a > b ? a : b),
    );
  }
}

WatchLogChannel _channelForUuid(String uuid) {
  switch (uuid) {
    case _channelAUuid:
      return WatchLogChannel.channelA;
    case _channelBUuid:
      return WatchLogChannel.channelB;
    case _fee7NotifyUuid:
    case _fee7AltNotifyUuid:
      return WatchLogChannel.fee7;
    default:
      return WatchLogChannel.unknown;
  }
}

Uint8List? _payloadFromDetails(DecodedLogFrame frame) {
  final payload = frame.details['payload'];
  if (payload is! List) return null;
  return Uint8List.fromList([
    for (final item in payload)
      if (item is String) int.parse(item.substring(2), radix: 16),
  ]);
}

Uint8List _parseHexBytes(String text) {
  final matches = RegExp(r'[0-9a-fA-F]{2}').allMatches(text);
  return Uint8List.fromList([
    for (final match in matches) int.parse(match.group(0)!, radix: 16),
  ]);
}

SleepSummary _parseSleep(
  Uint8List payload, {
  required bool isNight,
  required DateTime? captureDate,
}) {
  final body = isNight && payload.isNotEmpty
      ? Uint8List.sublistView(payload, 1)
      : payload;
  var i = 0;
  final stageMinutes = <String, int>{};
  var total = 0;
  var segments = 0;
  while (i + 2 <= body.length) {
    final endMin = (body[i] << 8) | body[i + 1];
    i += 2;
    if (endMin > 24 * 60 - 1) break;

    while (i + 2 <= body.length) {
      final stage = body[i] & 0xff;
      final dur = body[i + 1] & 0xff;
      if (stage == 0 && dur == 0) {
        i += 2;
        break;
      }
      final maybeNextEnd = (stage << 8) | dur;
      if (segments > 0 &&
          maybeNextEnd <= 24 * 60 - 1 &&
          maybeNextEnd < endMin) {
        break;
      }
      final label = _sleepStageLabel(stage);
      stageMinutes.update(label, (v) => v + dur, ifAbsent: () => dur);
      total += dur;
      segments++;
      i += 2;
    }
  }
  final dayOffset = isNight && payload.isNotEmpty ? payload[0] : null;
  DateTime? wakeDay;
  if (captureDate != null && dayOffset != null && dayOffset <= 31) {
    wakeDay = captureDate.subtract(Duration(days: dayOffset));
  }
  return SleepSummary(
    dayOffset: dayOffset,
    wakeDate: wakeDay == null
        ? null
        : _dateString(wakeDay.year, wakeDay.month, wakeDay.day),
    segmentCount: segments,
    totalMinutes: total,
    stageMinutes: stageMinutes,
  );
}

String _sleepStageLabel(int stage) {
  if (stage == 0) return 'awake';
  if (stage == 1) return 'light';
  if (stage == 2) return 'deep';
  if (stage == 3) return 'rem';
  if (stage == 4) return 'awake';
  if (stage <= 0x0f) return 'deep';
  if (stage <= 0x1f) return 'light';
  if (stage <= 0x2f) return 'rem';
  return 'awake';
}

List<ActivityRecordSummary> _parseActivitySummary(Uint8List payload) {
  final out = <ActivityRecordSummary>[];
  for (final entry in ActivityParser.parsePayload(payload)) {
    final range = ActivityParser.dayRange(entry.samples);
    out.add(
      ActivityRecordSummary(
        dayOffset: entry.dayOffset,
        spo2Max: range.max,
        spo2Min: range.min,
        hoursWithData: entry.samples.where((s) => s.hasData).length,
      ),
    );
  }
  return out;
}

_H59FileListSummary _parseH59FileList(Uint8List payload) {
  final declaredCount = payload.isEmpty ? 0 : payload[0] & 0xff;
  final recordBytes = payload.isEmpty ? 0 : payload.length - 1;
  final records = <_H59FileRecordSummary>[];
  var offset = payload.isEmpty ? 0 : 1;
  var malformed = declaredCount > 10;

  for (var index = 0; index < declaredCount; index++) {
    if (offset >= payload.length) break;
    final recordStart = offset;
    final recordLength = payload[offset] & 0xff;
    var recordMalformed = recordLength < 2;
    if (recordMalformed) malformed = true;

    var recordEnd = recordStart + (recordMalformed ? 1 : recordLength);
    if (recordEnd > payload.length) {
      recordEnd = payload.length;
      recordMalformed = true;
      malformed = true;
    }

    final recordType = recordStart + 1 < recordEnd
        ? payload[recordStart + 1] & 0xff
        : null;
    final fields = <_H59FileFieldSummary>[];
    var fieldOffset = recordStart + 2;

    while (!recordMalformed && fieldOffset < recordEnd) {
      final fieldLength = payload[fieldOffset] & 0xff;
      if (fieldLength < 2 || fieldOffset + 1 >= recordEnd) {
        recordMalformed = true;
        malformed = true;
        break;
      }

      var fieldEnd = fieldOffset + fieldLength;
      if (fieldEnd > recordEnd) {
        fieldEnd = recordEnd;
        recordMalformed = true;
        malformed = true;
      }

      final valueStart = fieldOffset + 2;
      fields.add(
        _H59FileFieldSummary(
          fieldLength: fieldLength,
          fieldId: payload[fieldOffset + 1] & 0xff,
          valueHex: _compactHex(
            Uint8List.sublistView(payload, valueStart, fieldEnd),
          ),
        ),
      );
      if (recordMalformed) break;
      fieldOffset += fieldLength;
    }

    records.add(
      _H59FileRecordSummary(
        index: index,
        recordLength: recordLength,
        recordType: recordType,
        fields: fields,
        rawHex: _compactHex(
          Uint8List.sublistView(payload, recordStart, recordEnd),
        ),
        malformed: recordMalformed,
      ),
    );

    offset = recordEnd;
    if (recordMalformed) break;
  }

  final trailingBytes = payload.length - offset;
  if (records.length < declaredCount || trailingBytes > 0) malformed = true;

  return _H59FileListSummary(
    declaredCount: declaredCount,
    recordBytes: recordBytes,
    records: records,
    trailingBytes: trailingBytes,
    malformed: malformed,
  );
}

_ActivityTotals? _parseTodaySport(Uint8List payload) {
  if (payload.length < 12) return null;
  final rawCalories = Codec.readU24be(payload, 6);
  final calories = rawCalories <= 20000
      ? rawCalories
      : (rawCalories / 1000).round();
  return _ActivityTotals(
    steps: Codec.readU24be(payload, 0),
    calories: calories,
    distanceMeters: Codec.readU24be(payload, 9),
  );
}

class _ActivityTotals {
  const _ActivityTotals({this.steps, this.calories, this.distanceMeters});

  final int? steps;
  final int? calories;
  final int? distanceMeters;

  Map<String, Object?> toJson() => {
    'steps': steps,
    'calories': calories,
    'distanceMeters': distanceMeters,
  };
}

String _labelForChannelA(int opcode) {
  switch (opcode) {
    case OpA.setTime:
      return 'setTime/capabilities';
    case OpA.battery:
      return 'battery';
    case OpA.dnd:
      return 'doNotDisturb';
    case OpA.palmScreen:
      return 'palmScreen';
    case OpA.intell:
      return 'intell';
    case OpA.timeFormat:
      return 'timeFormat';
    case OpA.bpSetting:
      return 'bloodPressureSetting';
    case OpA.bpData:
      return 'bloodPressureData';
    case OpA.readHeartRate:
      return 'readHeartRate';
    case OpA.heartRateSetting:
      return 'heartRateSetting';
    case OpA.bloodOxygenSetting:
      return 'bloodOxygenSetting';
    case OpA.deviceAvatar:
      return 'deviceAvatar';
    case OpA.pressureSetting:
      return 'pressureEnableSetting';
    case OpA.pressure:
      return 'pressureHistory';
    case OpA.hrv:
      return 'hrvHistory';
    case OpA.readDetailSport:
      return 'readDetailSport';
    case OpA.setAlarm:
      return 'setAlarm';
    case OpA.readAlarm:
      return 'readAlarm';
    case OpA.setDrinkAlarm:
      return 'setDrinkAlarm';
    case OpA.readDrinkAlarm:
      return 'readDrinkAlarm';
    case OpA.todaySport:
      return 'todaySport';
    case OpA.packageLength:
      return 'packageLength';
    case OpA.pendingStatusWrite:
      return 'pendingStatusWrite';
    case OpA.startMeasure:
      return 'startMeasure';
    case OpA.stopMeasure:
      return 'stopMeasure';
    case OpA.deviceNotify:
      return 'deviceNotify';
    case OpA.weatherForecast:
      return 'weatherForecast';
    case OpA.displayClock:
      return 'displayClock';
    case OpA.watchfaceDisplayClock:
      return 'watchfaceDisplayClock';
    case OpA.degreeSwitch:
      return 'degreeSwitch';
    case OpA.brightness:
      return 'brightness';
    case OpA.displayTime:
      return 'displayTime';
    case OpA.displayOrientation:
      return 'displayOrientation';
    case OpA.displayStyle:
      return 'displayStyle';
    case OpA.musicNotify:
      return 'musicNotify';
    case OpA.queryDataDistribution:
      return 'queryDataDistribution';
    default:
      return 'unknown';
  }
}

String _labelForChannelB(int cmd) {
  switch (cmd) {
    case OpB.apkMusicSendUnsupported:
      return 'apkMusicSendUnsupported';
    case OpB.h59CleanupBypass10:
      return 'h59CleanupBypass10';
    case OpB.h59SleepSummary:
      return 'h59SleepSummary';
    case OpB.h59SleepDetail:
      return 'h59SleepDetail';
    case OpB.h59Noop13:
      return 'h59Noop13';
    case OpB.apkLocationUnsupported:
      return 'apkLocationUnsupported';
    case OpB.h59ExplicitReject21:
      return 'h59ExplicitReject21';
    case OpB.h59ExplicitReject22:
      return 'h59ExplicitReject22';
    case OpB.h59ExplicitReject23:
      return 'h59ExplicitReject23';
    case OpB.h59ExplicitReject24:
      return 'h59ExplicitReject24';
    case OpB.apkTemperatureSeriesUnsupported:
      return 'apkTemperatureSeriesUnsupported';
    case OpB.apkTemperatureOnceUnsupported:
      return 'apkTemperatureOnceUnsupported';
    case OpB.sleepNew:
      return 'sleepNew/night';
    case OpB.apkManualHeartRateUnsupported:
      return 'apkManualHeartRateUnsupported';
    case OpB.h59Noop29:
      return 'h59Noop29';
    case OpB.activitySummary:
      return 'activitySummary';
    case OpB.alarm:
      return 'alarm';
    case OpB.apkContactUnsupported:
      return 'apkContactUnsupported';
    case OpB.apkBtMacUnsupported:
      return 'apkBtMacUnsupported';
    case OpB.apkQrCodeUnsupported:
      return 'apkQrCodeUnsupported';
    case OpB.apkPlateListUnsupported:
      return 'apkPlateListUnsupported';
    case OpB.apkCustomWatchFaceUnsupported:
      return 'apkCustomWatchFaceUnsupported';
    case OpB.h59Noop3b:
      return 'h59Noop3b';
    case OpB.sleepLunchNew:
      return 'sleepLunch/nap';
    case OpB.fileList:
      return 'apkFileListUnsupported';
    case OpB.fileInit:
      return 'apkFileInitUnsupported';
    case OpB.filePocket:
      return 'apkFilePocketUnsupported';
    case OpB.fileCheck:
      return 'apkFileCheckUnsupported';
    case OpB.fileDelete:
      return 'apkFileDeleteUnsupported';
    case OpB.h59FileList:
      return 'h59FileList';
    case OpB.h59FileListResponse:
      return 'h59FileListResponse';
    case OpB.h59FileOperation:
      return 'h59FileOperation';
    case OpB.h59FileMetadata:
      return 'h59FileMetadata';
    case OpB.h59FileChunk:
      return 'h59FileChunk';
    case OpB.h59CleanupBypass46:
      return 'h59CleanupBypass46';
    case OpB.h59Noop47:
      return 'h59Noop47';
    case OpB.apkGpsNavigationUnsupported:
      return 'apkGpsNavigationUnsupported';
    case OpB.apkManualOxygenUnsupported:
      return 'apkManualOxygenUnsupported';
    case OpB.apkAvatarDeviceUnsupported:
      return 'apkAvatarDeviceUnsupported';
    case OpB.h59Noop4b:
      return 'h59Noop4b';
    case OpB.apkSmsQuickUnsupported:
      return 'apkSmsQuickUnsupported';
    case OpB.apkAgpsUnsupported:
      return 'apkAgpsUnsupported';
    case OpB.deviceInfoConfig:
      return 'deviceInfoConfig';
    case OpB.apkIntervalBloodOxygenUnsupported:
      return 'apkIntervalBloodOxygenUnsupported';
    case OpB.apkIntervalHeartRateUnsupported:
      return 'apkIntervalHeartRateUnsupported';
    case OpB.apkAlbumEbookRecordListUnsupported:
      return 'apkAlbumEbookRecordListUnsupported';
    case OpB.apkEbookDeleteUnsupported:
      return 'apkEbookDeleteUnsupported';
    case OpB.apkRecordReadUnsupported:
      return 'apkRecordReadUnsupported';
    default:
      return 'unknown';
  }
}

bool _isH59NoopChannelB(int cmd) {
  switch (cmd) {
    case OpB.h59Noop13:
    case OpB.h59Noop29:
    case OpB.h59Noop3b:
    case OpB.h59Noop47:
    case OpB.h59Noop4b:
      return true;
    default:
      return false;
  }
}

bool _isH59ExplicitRejectChannelB(int cmd) {
  switch (cmd) {
    case OpB.h59ExplicitReject21:
    case OpB.h59ExplicitReject22:
    case OpB.h59ExplicitReject23:
    case OpB.h59ExplicitReject24:
      return true;
    default:
      return false;
  }
}

bool _isUnsupportedApkSidecarChannelB(int cmd) {
  switch (cmd) {
    case OpB.apkMusicSendUnsupported:
    case OpB.apkLocationUnsupported:
    case OpB.apkTemperatureSeriesUnsupported:
    case OpB.apkTemperatureOnceUnsupported:
    case OpB.apkManualHeartRateUnsupported:
    case OpB.apkContactUnsupported:
    case OpB.apkBtMacUnsupported:
    case OpB.apkQrCodeUnsupported:
    case OpB.apkPlateListUnsupported:
    case OpB.apkCustomWatchFaceUnsupported:
    case OpB.apkGpsNavigationUnsupported:
    case OpB.apkManualOxygenUnsupported:
    case OpB.apkAvatarDeviceUnsupported:
    case OpB.apkSmsQuickUnsupported:
    case OpB.apkAgpsUnsupported:
    case OpB.apkIntervalBloodOxygenUnsupported:
    case OpB.apkIntervalHeartRateUnsupported:
    case OpB.apkAlbumEbookRecordListUnsupported:
    case OpB.apkEbookDeleteUnsupported:
    case OpB.apkRecordReadUnsupported:
      return true;
    default:
      return false;
  }
}

bool _isUnsupportedApkFileHandleChannelB(int cmd) {
  switch (cmd) {
    case OpB.fileList:
    case OpB.fileInit:
    case OpB.filePocket:
    case OpB.fileCheck:
    case OpB.fileDelete:
      return true;
    default:
      return false;
  }
}

String _labelForFee7(int opcode) {
  switch (opcode) {
    case Fee7.battery:
      return 'battery';
    case Fee7.camera:
      return 'camera';
    case Fee7.bindAncs:
      return 'bindAncs';
    case Fee7.timeFormat:
      return 'timeFormat';
    case Fee7.bpSetting:
      return 'bpSetting';
    case Fee7.bpData:
      return 'bpData';
    case Fee7.shortAlert:
      return 'shortAlert';
    case Fee7.lowNoop14:
      return 'lowNoop';
    case Fee7.heartRateSetting:
      return 'heartRateSetting';
    case Fee7.degreeSwitch:
      return 'degreeSwitch';
    case Fee7.targetSetting:
      return 'targetSetting';
    case Fee7.spo2HrUpdate:
      return 'spo2HrUpdate';
    case Fee7.capabilityBlock:
      return 'capabilityBlock';
    case Fee7.handshakeResponse:
      return 'handshake';
    case Fee7.alertTrigger:
      return 'alertTrigger';
    case Fee7.findPhoneEvent:
      return 'findPhone';
    case Fee7.modeControl:
      return 'modeControl';
    case Fee7.modeControlCont:
      return 'modeControlCont';
    case Fee7.pendingStatusWrite:
      return 'pendingStatusWrite';
    case Fee7.statusResponse:
      return 'status';
    case Fee7.lipidsUpdate:
      return 'lipidsUpdate';
    case Fee7.hrv:
      return 'hrv';
    case Fee7.longResponse:
      return 'healthPoll';
    case Fee7.memoryWrite:
      return 'memoryWrite';
    case Fee7.memoryRead:
      return 'memoryRead';
    case Fee7.otaTrigger:
      return 'otaControl';
    case Fee7.echoBase:
      return 'selfMarkerEcho';
    case Fee7.echoBase2:
      return 'checksumEcho';
    case Fee7.stateUpdateMode1:
      return 'stateUpdateMode1';
    case Fee7.stateUpdateMode3:
      return 'stateUpdateMode3';
    case Fee7.resetState:
      return 'resetState';
    case Fee7.unaryC4:
      return 'runtimeNoop';
    case Fee7.unaryC5:
    case Fee7.unaryC8:
    case Fee7.unaryC9:
      return 'runtimeFlagWrite';
    case Fee7.unaryCd:
      return 'smallMemoryRead';
    case Fee7.unaryCe:
      return 'factoryTest';
    case Fee7.firmwareBuildInfo:
      return 'firmwareBuildInfo';
    case Fee7.sessionMode1Ack:
    case Fee7.sessionMode2Ack:
      return 'sessionModeAck';
    case Fee7.sessionModeStatus:
      return 'sessionModeStatus';
    case Fee7.factoryStop:
      return 'factoryStop';
    case Fee7.modelName:
      return 'modelName';
    case Fee7.highStatusFrame:
      return 'highStatus';
    case Fee7.highNoop92:
    case Fee7.highNoop97:
    case Fee7.highNoop99:
    case Fee7.highNoop9f:
      return 'noResponsePlaceholder';
    case Fee7.highNoop9d:
      // High-range switch8 slot for 0x9d is fee7_send_vendor_nak, not a silent return.
      return 'vendorNak';
    case Fee7.syntheticSleep:
      return 'syntheticSleep';
    default:
      if (_isFee7DeferredCommand(opcode)) return 'deferredCommand';
      if (Fee7.isUnary(opcode)) return 'unary';
      return 'unknown';
  }
}

bool _isFee7DeferredCommand(int opcode) {
  switch (opcode) {
    case 0x01:
    case 0x06:
    case 0x0e:
    case 0x15:
    case 0x18:
    case 0x1e:
    case 0x25:
    case 0x26:
    case 0x2b:
    case 0x37:
    case 0x38:
    case 0x3a:
    case 0x3b:
    case 0x43:
    case 0x72:
    case 0x77:
    case 0x7a:
    case 0x7d:
    case 0x81:
    case 0xa1:
    case 0xc6:
    case 0xc7:
    case 0xff:
      return true;
    default:
      return false;
  }
}

String _hex(int v) => '0x${(v & 0xff).toRadixString(16).padLeft(2, '0')}';

String _hex32(int v) =>
    '0x${(v & 0xffffffff).toRadixString(16).padLeft(8, '0')}';

String _trimNulAscii(Uint8List bytes) {
  final end = bytes.indexOf(0);
  final slice = end == -1 ? bytes : Uint8List.sublistView(bytes, 0, end);
  return ascii.decode(slice, allowInvalid: true);
}

String _compactHex(Iterable<int> bytes) =>
    bytes.map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0')).join('-');

List<String> _hexList(Iterable<int> bytes) => [for (final b in bytes) _hex(b)];

String _addSub(Map<String, Object?> details, int sub) {
  final hex = _hex(sub);
  details['sub'] = hex;
  return hex;
}

bool? _addWireBool12(Map<String, Object?> details, String field, int value) {
  final parsed = _wireBool12(value);
  details[field] = parsed;
  return parsed;
}

bool? _wireBool12(int value) => switch (value) {
  1 => true,
  2 => false,
  _ => null,
};

bool? _wireBoolInverted01(int value) => switch (value) {
  0 => true,
  1 => false,
  _ => null,
};

String _boolText(bool? value) => value?.toString() ?? 'unknown';

String _hhmm(int hour, int minute) =>
    '${hour.toString().padLeft(2, '0')}:'
    '${minute.toString().padLeft(2, '0')}';

List<int> _daysWithData(int mask) => [
  for (var d = 0; d < 32; d++)
    if ((mask & (1 << d)) != 0) d,
];

int _sum8(Uint8List b, int start, int end) {
  var sum = 0;
  for (var i = start; i < end; i++) {
    sum += b[i];
  }
  return sum & 0xff;
}

String _dateString(int year, int month, int day) =>
    '${year.toString().padLeft(4, '0')}-'
    '${month.toString().padLeft(2, '0')}-'
    '${day.toString().padLeft(2, '0')}';
