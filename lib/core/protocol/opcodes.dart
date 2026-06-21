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
  static const int hrv = 0x39;
  static const int hrvSetting = 0x38;
  static const int pressure = 0x37;
  static const int pressureSetting = 0x36;
  static const int ultraViolet = 0x7d;
  static const int uvSetting = 0x3e;
  static const int sugarLipidsSetting = 0x3a;
  static const int menstruation = 0x2b;

  // Activity / sport / sleep / alarm / target
  static const int readBandSport = 0x13;
  static const int readDetailSport = 0x43;
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

  static const int customWatchFace = 0x3a;

  // LargeData actions (PROTOCOL.md §4.7)
  static const int sleepNew = 0x27; // new sleep protocol (night) — Ch B
  static const int activitySummary =
      0x2a; // v14 activity/sport summary — see GHIDRA §2.8
  static const int sleepLunchNew = 0x3e; // new sleep (lunch/nap) — Ch B

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
  static const int statusResponse = 0x61; // 'a' — battery / step counters

  // Mode control (multi-step + continuation)
  static const int modeControl = 0x69; // 'i'
  static const int modeControlCont = 0x6a; // 'j'

  // Low-range switch8 entries that mirror Channel-A features
  static const int camera = 0x02; // FUN_0082c4d4
  static const int battery = 0x03; // FUN_0082bc7e
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

  // Range 0x92..0x96 — vendor unary echoes / probes (one handler each).
  static const int unaryRangeStart = 0x92;
  static const int unaryRangeEnd = 0x96;

  // 0x97..0x9c are stateful vendor probes (not simple unary echoes).
  static const int probeRangeStart = 0x97;
  static const int probeRangeEnd = 0x9c;

  // Out-of-range unary opcodes handled as standalone cases.
  static const int unary9e = 0x9e; // FUN_00827cc8
  static const int unary9f = 0x9f; // FUN_00827b16
  static const int statusFrame = 0xa0; // FUN_00827d1a
  static const int unaryBf = 0xbf;
  static const int unaryC0 = 0xc0;
  static const int unaryC4 = 0xc4;
  static const int unaryC5 = 0xc5;
  static const int unaryC8 = 0xc8;
  static const int unaryC9 = 0xc9;
  static const int unaryCd = 0xcd;
  static const int unaryCe = 0xce; // factory/test sub-commands
  static const int vibrationPattern = 0xfe; // FUN_00844214

  // Special handling
  static const int longResponse = 0xc1; // Fragmented long reply
  static const int otaTrigger = 0xc3; // Routes into OTA state machine

  /// Whether [opcode] should be decoded as a `UnaryOpcode` (no payload decode).
  ///
  /// Note: [vibrationPattern] (0xfe) is excluded — it has structured decoding
  /// and is surfaced on its own `onVibration` stream. The stateful vendor
  /// probe range `0x97..0x9c` is also excluded; it falls through to the
  /// unknown stream until a dedicated decoder is added.
  static bool isUnary(int opcode) {
    if (opcode >= unaryRangeStart && opcode <= unaryRangeEnd) return true;
    if (opcode >= probeRangeStart && opcode <= probeRangeEnd) return false;
    switch (opcode) {
      case echoBase:
      case echoBase2:
      case unary9e:
      case unary9f:
      case statusFrame:
      case unaryBf:
      case unaryC0:
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
