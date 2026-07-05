/// Channel-A command opcodes (see `PROTOCOL.md` §4). Names mirror the Oudmon
/// `*Req` classes so the spec cross-references directly.
class OpA {
  OpA._();

  static const int setTime = 0x01;
  static const int battery = 0x03; // BatteryRsp: [0]=percent, [1]=charging
  static const int deviceSupport = 0x3c;
  static const int deviceTheme = 0x3d;
  static const int deviceWallpaper = 0x3f;
  static const int deviceAvatar = 0x32;

  // Display
  static const int displayClock = 0x12;
  static const int watchfaceDisplayClock = 0x18;
  static const int displayOrientation = 0x29;
  static const int displayStyle = 0x2a;
  static const int displayTime = 0x1f;
  static const int brightness = 0x1b;
  static const int degreeSwitch = 0x19;
  static const int timeFormat = 0x0a;
  static const int dnd = 0x06;
  static const int palmScreen = 0x05;
  static const int intell = 0x09;
  static const int touchControl = 0x3b;

  static const int findDevice = 0x50;
  static const int deviceFind =
      0x08; // v14 inline-dispatched find/long-press/camera branch — see
  // GHIDRA_DECOMPILATION.md §3.15 (FUN_0082d2dc inline). Sub-cmd
  // `0x00` = cancel, `0x01` = start, `0xAB 0xDC` = long-press power-off,
  // others = set motor mode.
  static const int camera = 0x02;
  static const int restoreKey =
      0x66; // RestoreKeyReq uses caller opcode; reset magic
  static const int deviceReboot =
      0xc6; // Device-reboot trigger (v14-only inline opcode — see
  // GHIDRA_DECOMPILATION.md §3.14). Payload byte 0x6C = full reboot
  // (BLE tears down, no response); other subs receive a 1-byte ack.
  static const int factoryReset =
      0xff; // Factory-reset trigger — payload `"fff"` (0x66 0x66 0x66);
  // see GHIDRA_DECOMPILATION.md §3.8 (FUN_0082cde8). The handler sends
  // NO response frame; the host treats the absence of an error as the
  // implicit ack.
  static const int switchOta = 0x0f;

  // Health
  static const int readHeartRate = 0x15;
  static const int heartRateSetting = 0x16;
  static const int realTimeHeartRate = 0x1e;
  static const int startMeasure = 0x69;
  static const int stopMeasure = 0x6a;
  static const int readPressure = 0x14;
  static const int bloodOxygenSetting = 0x2c;
  static const int bpSetting = 0x0c;
  static const int bpReadConform = 0x0e;
  static const int bpData = 0x0d;

  /// `HRVReq` (0x39): uses the shared FUN_0082c988 13-byte-chunk
  /// fragmenter per GHIDRA section 3.21. The 49-byte record is sent
  /// after the header as 4 sequenced payload frames.
  static const int hrv = 0x39;

  /// Legacy APK-era name for `0x38`.
  ///
  /// H59MA v14 does not expose a Channel-A HRV auto-measure setting at
  /// `0x38`; radare2/GHIDRA §3.17 show this opcode is the pressure/stress
  /// enable bit. Keep the alias only so older code fails at the command
  /// builder boundary instead of silently changing wire values.
  @Deprecated(
    '0x38 is pressureSetting on H59MA v14; HRV setting is unsupported',
  )
  static const int hrvSetting = 0x38;

  /// `PressureReq` (0x37): uses the shared FUN_0082c988 13-byte-chunk
  /// fragmenter per GHIDRA section 3.20. The 49-byte record is sent
  /// after the header as 4 sequenced payload frames.
  static const int pressure = 0x37;

  /// `pressure` / stress enable bit (`0x38`): simple read/write setting.
  ///
  /// The earlier APK-derived `0x36` value is not in the H59MA v14 Channel-A
  /// dispatcher table. `0x38` is verified at body offset `0x6654` and emits
  /// `[0x38, sub, value]`.
  static const int pressureSetting = 0x38;

  /// `UltraVioletReq` (0x7d): NOT in section 10.2 fragmenter table —
  /// needs live capture. Shares the FUN_0082c988 13-byte-chunk
  /// fragmenter layout (49-byte record = 4 chunks) with 0x37/0x39,
  /// but the section 10.2 inventory does not list 0x7d under the
  /// fragmenter callers — verify before relying on the
  /// header+3-body-chunk shape.
  static const int ultraViolet = 0x7d;
  static const int uvSetting = 0x3e;
  static const int sugarLipidsSetting = 0x3a;
  static const int menstruation = 0x2b;

  // Activity / sport / sleep / alarm / target
  static const int readBandSport = 0x13;
  static const int readDetailSport = 0x43;

  /// NOT IMPLEMENTED in H59MA v14 firmware — section 10.2 Channel-A
  /// inventory has no 0x07 row. Stale legacy spec retired (subsumed by
  /// 0x48 todaySport / 0x43 readDetailSport / Ch-B 0x2a activity
  /// summary). See PROTOCOL.md section 4.4.
  static const int readTotalSport = 0x07;
  static const int phoneSport = 0x77;
  static const int phoneGps = 0x74;
  static const int readSleepDetails = 0x44;
  static const int setAlarm = 0x23;
  static const int readAlarm = 0x24;
  static const int setDrinkAlarm = 0x27;
  static const int readDrinkAlarm = 0x28;
  static const int setSitLong = 0x25;
  static const int readSitLong = 0x26;
  static const int targetSetting = 0x21;
  static const int todaySport = 0x48;

  // Notifications / weather / muslim
  static const int bindAncs = 0x04;
  static const int setAncs = 0x60;
  static const int setMessagePush = 0x61;
  static const int pushMsgUint = 0x72;
  static const int blackList = 0x2d;
  static const int loverEvent = 0x51;
  static const int callForward = 0x33;
  static const int weatherForecast = 0x1a;
  static const int agps = 0x30;
  static const int muslim = 0x7a;
  static const int muslimRemind = 0x52;
  static const int muslimTarget = 0x7b;
  static const int vibrationResponse =
      0xc7; // Vibration / motor pattern player (Channel A, fragmented
  // reply — see GHIDRA_DECOMPILATION.md §3.2 + FUN_0082b938).

  // Persistent notify-only opcodes (watch -> phone pushes)
  static const int packageLength = 0x2f;
  static const int queryDataDistribution = 0x46;
  static const int deviceNotify = 0x73;
  static const int deviceSportNotify = 0x78;
  static const int musicNotify = 0x1d;
  static const int innerCameraNotify = 0x02;

  // Mixture sub-opcodes (subData[0])
  static const int mixRead = 0x01;
  static const int mixWrite = 0x02;
  static const int mixDelete = 0x03;

  /// Channel-B ACK/NAK carrier (host→watch).
  ///
  /// Reserved low-bit opcode (`0x7E`) used exclusively by
  /// `ChannelBParser.buildAck` to signal "frame received OK / CRC fail"
  /// for inbound Channel-B traffic. Deliberately outside the documented
  /// `0x00..0x7F` request range — the high bit (`0x80`) is reserved as
  /// the **device→host** error flag on Channel A (see `Codec.errorFlag`
  /// at `codec.dart:12`), and the firmware strips it before dispatch.
  /// Any opcode ≥ `0x80` would alias to a defined low-bit request
  /// (e.g. `0xBC` → `0x3C deviceSupport`) and trigger an error loop.
  static const int channelBAck = 0x7E;
}

/// Channel-B large-data / file / OTA command ids (byte[1]).
class OpB {
  OpB._();

  // DfuHandle (firmware OTA)
  static const int otaStart = 0x01;
  static const int otaInit = 0x02;
  static const int otaData = 0x03;
  static const int otaCheck = 0x04;
  static const int otaEnd = 0x05;

  // FileHandle
  static const int fileList = 0x30;
  static const int fileInit = 0x31;
  static const int filePocket = 0x32;
  static const int fileCheck = 0x33;
  static const int fileDelete = 0x39;

  // H59MA v14 file-table path (firmware-native; separate from APK FileHandle).
  static const int h59FileList = 0x41;
  static const int h59FileListResponse = 0x42;
  static const int h59FileOperation = 0x43;
  static const int h59FileMetadata = 0x44;
  static const int h59FileChunk = 0x45;
  static const int h59FileDelete = 0x46;

  static const int customWatchFace = 0x3a;

  // LargeData actions (PROTOCOL.md §4.7)
  static const int sleepNew = 0x27; // new sleep protocol (night) — Ch B
  static const int activitySummary =
      0x2a; // v14 activity/sport summary — see GHIDRA §2.8
  static const int sleepLunchNew = 0x3e; // new sleep (lunch/nap) — Ch B

  /// H59MA v14 device-info / config TLV handler (Channel-B `0x5a`).
  ///
  /// Sub-cmds (`payload[0]`):
  ///   `0x01` — query enabled TLV slots; response is
  ///            `[0x01, 0x01, count, ...tlvs]`.
  ///   `0x02` — write TLVs; commit-only, no visible response payload.
  ///   `0x03` — read static info TLVs (`H59MAX_`, `H59MA_V1.0`, ...).
  ///   `0x04` — clear blob0 device-info / config slots.
  ///
  /// Writable TLV ids 1..7: `1` custom name prefix (max 0x18 B),
  /// `2` BLE addr override (max 6 B), `3..6` device-info string
  /// slots (max 0x14 / 0x10 / 0x10 / 0x08 B), `7` name-format
  /// control byte (1 B). See `PROTOCOL.md` §4.8 and
  /// `GHIDRA_DECOMPILATION.md` §2.7 (`FUN_0082f6ec`).
  static const int deviceInfoConfig = 0x5a;

  // OTA response types (byte[1] of RX status frame)
  static const int rspOk = 0;
  static const int rspDataSize = 1;
  static const int rspDataContent = 2;
  static const int rspCmdStatus = 3;
  static const int rspCmdFormat = 4;
  static const int rspInner = 5;
  static const int rspLowBattery = 6;
}

/// Opcodes handled by the vendor `0xFEE7` GATT service write handler
/// (`FUN_0082c944` in H59MA v14, see `GHIDRA_DECOMPILATION.md` §8).
///
/// Wire format is identical to Channel A: a fixed 16-byte frame whose last
/// byte is the additive 8-bit checksum of bytes `0..14`. Several opcodes
/// overlap with Channel A (e.g. `0x48`, `0x50`, `0x51`, `0x69`, `0x6a`,
/// `0x3c`, `0x3e`) — the device treats the two GATT services as parallel
/// command surfaces.
class Fee7 {
  Fee7._();

  // Health
  static const int spo2HrUpdate = 0x36; // SpO2/HR read or set
  static const int hrv = 0x39; // HRV read/set (FUN_0082c9da)
  static const int capabilityBlock = 0x3c; // Returns fixed device-cap block
  static const int bloodOxygenUpdate = 0x3e; // SpO2 read/set

  // Device info / handshake
  static const int handshakeResponse = 0x48; // 'H' — 15-byte info block

  // Alerts / find-phone
  static const int alertTrigger = 0x50; // 'P' — alarm/motor pattern
  static const int findPhoneEvent = 0x51; // 'Q' — arms pattern when pl[1]==1
  static const int miscAncs = 0x60; // FUN_0082be90

  // Status
  static const int statusResponse = 0x61; // 'a' — live u32 status snapshot

  // Mode control (multi-step + continuation)
  static const int modeControl = 0x69; // 'i'
  static const int modeControlCont = 0x6a; // 'j'

  // Low-range switch8 entries that mirror Channel-A features
  static const int camera = 0x02; // FUN_0082c4d4
  static const int battery = 0x03; // [0x03, percent, charging]
  static const int bindAncs = 0x04; // FUN_0082c432
  static const int timeFormat = 0x0a; // FUN_0082b9c6
  static const int bpSetting = 0x0c; // FUN_0082c0de
  static const int bpData = 0x0d; // FUN_00834252 + FUN_0082c0a4
  static const int heartRateSetting = 0x16; // FUN_0082c164
  static const int degreeSwitch = 0x19; // FUN_0082c484
  static const int targetSetting = 0x21; // FUN_0082bfd8

  // Echo / unary probes
  static const int echoBase = 0x90; // FUN_00827ad2
  static const int echoBase2 = 0x91; // FUN_00827aee

  // 0x92..0x96 vendor probes / state updates.
  static const int highNoop92 = 0x92; // No response
  static const int firmwareBuildInfo = 0x93; // Version/build string
  static const int stateUpdateMode1 = 0x94; // Self-marker + mode 1
  static const int stateUpdateMode3 = 0x95; // Self-marker + mode 3
  static const int resetState = 0x96; // Self-marker + mode 4 reset
  static const int unaryRangeStart = highNoop92;
  static const int unaryRangeEnd = resetState;

  // High-range vendor session/status handlers.
  static const int highNoop97 = 0x97; // No response
  static const int sessionMode1Ack = 0x98; // Sets session mode 1, self-marker
  static const int highNoop99 = 0x99; // No response
  static const int sessionMode2Ack = 0x9a; // Sets session mode 2, self-marker
  static const int sessionModeStatus = 0x9b; // [stateByte]
  static const int factoryStop = 0x9c; // Self-marker + factory-test cleanup
  static const int highNoop9d = 0x9d; // No response / default return
  static const int modelName = 0x9e; // ASCII model string response
  static const int highNoop9f = 0x9f; // No response
  static const int highStatusFrame = 0xa0; // Opaque multi-byte status frame

  // Out-of-range unary opcodes handled as standalone cases.
  @Deprecated('Use modelName; 0x9e returns an ASCII model-name frame.')
  static const int unary9e = modelName;
  @Deprecated('Use highNoop9f; 0x9f does not emit a unary response.')
  static const int unary9f = highNoop9f;
  @Deprecated('Use highStatusFrame; 0xa0 returns a structured status frame.')
  static const int statusFrame = highStatusFrame;
  static const int memoryWrite = 0xbf; // Raw host-addressed memory write
  static const int memoryRead = 0xc0; // Raw host-addressed memory read stream
  static const int unaryBf = memoryWrite;
  @Deprecated('Use memoryRead; 0xc0 emits fragmented memory-read chunks.')
  static const int unaryC0 = memoryRead;
  static const int unaryC4 = 0xc4;
  static const int unaryC5 = 0xc5;
  static const int unaryC8 = 0xc8;
  static const int unaryC9 = 0xc9;
  static const int unaryCd = 0xcd;
  static const int unaryCe = 0xce; // factory/test sub-commands
  static const int syntheticSleep = 0xfe; // Synthetic sleep-history record
  @Deprecated(
    'Use syntheticSleep; 0xfe synthesizes sleep history, not vibration.',
  )
  static const int vibrationPattern = syntheticSleep;

  // Special handling
  static const int longResponse = 0xc1; // One-shot health/status poll
  static const int otaTrigger = 0xc3; // OTA control: action + service reset

  /// Whether [opcode] should be decoded as a `UnaryOpcode` (no payload decode).
  ///
  /// Note: [highNoop92] (0x92) is a no-response placeholder, while
  /// [firmwareBuildInfo] (0x93), [syntheticSleep] (0xfe), and the high-range
  /// session/status frames (`0x98`, `0x9a`, `0x9b`, `0x9c`, `0x9e`, `0xa0`)
  /// have structured decoding and are surfaced on their own streams.
  static bool isUnary(int opcode) {
    switch (opcode) {
      case echoBase:
      case echoBase2:
      case stateUpdateMode1:
      case stateUpdateMode3:
      case resetState:
      case memoryWrite:
      case unaryC4:
      case unaryC5:
      case unaryC8:
      case unaryC9:
      case unaryCd:
      case unaryCe:
        return true;
      default:
        return false;
    }
  }
}
