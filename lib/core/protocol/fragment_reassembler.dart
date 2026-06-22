import 'dart:async';
import 'dart:typed_data';

/// Reassembles a "header + N chunks" two-phase response into a single
/// typed record.
///
/// The H59MA Channel-A protocol uses this pattern for several opcodes
/// (e.g. `0x37` stress history, `0x39` HRV history, `0x7a` muslim,
/// `0x0d` BP record): a single header frame is emitted first, then
/// zero or more payload chunks. There is no end-of-message marker on
/// the wire — consumers close the current record after a quiet
/// period elapses with no further chunks.
///
/// This class factors out that quiet-period buffering. Callers wire
/// the dispatcher's per-opcode `on*Header` and `on*Chunk` streams in
/// and pass a [build] callback that turns the accumulated
/// (header, payload) into a typed record of their choice.
///
/// ```dart
/// final reassembler = FragmentReassembler<PressureSettingHeader,
///     PressureSettingChunk, Uint8List>(
///   headers: dispatcher.onPressureSettingHeader,
///   chunks: dispatcher.onPressureSettingChunk,
///   build: (header, payload) => payload,
/// );
/// reassembler.assembled.listen((payload) {
///   // decode `payload` against the 49-byte record layout.
/// });
/// ```
///
/// Errors from the source streams are forwarded to the output
/// stream. On source completion any in-flight record is emitted
/// first so consumers never lose the tail.
class FragmentReassembler<Header, Chunk, T> {
  FragmentReassembler({
    required Stream<Header> headers,
    required Stream<Chunk> chunks,
    required T Function(Header header, Uint8List assembledPayload) build,
    Duration quietWindow = const Duration(milliseconds: 250),
  }) : _build = build,
       _quietWindow = quietWindow {
    _subscription = _merged(headers, chunks).listen(
      _onEvent,
      onError: (Object e, StackTrace st) {
        if (!_out.isClosed) _out.addError(e, st);
      },
      onDone: () {
        // Source closed — emit any in-flight record before closing
        // the output so consumers never lose the tail.
        if (_hasInFlight) {
          _flush();
        }
        if (!_out.isClosed) _out.close();
      },
    );
  }

  /// Function supplied by the caller to convert (header, payload)
  /// into the typed output record [T].
  final T Function(Header header, Uint8List assembledPayload) _build;

  /// Time without a chunk before the current record is considered
  /// complete. Configurable per opcode: vibration chunks typically
  /// use ~100 ms, HR history ~250 ms, etc.
  final Duration _quietWindow;

  final StreamController<T> _out = StreamController<T>.broadcast();
  late final StreamSubscription<_FragEvent> _subscription;
  Timer? _quietTimer;

  // In-flight record state. `null` header means "no record in
  // progress" (i.e. between emissions, or before the first header).
  Header? _pendingHeader;
  final BytesBuilder _pendingPayload = BytesBuilder(copy: false);
  bool _hasInFlight = false;

  /// Output stream of assembled records. Each event fires once per
  /// header after the chunks have gone quiet for [quietWindow].
  Stream<T> get assembled => _out.stream;

  /// Cancel the source subscriptions, cancel any pending quiet
  /// timer, and close the output stream. Safe to call multiple times.
  void dispose() {
    _quietTimer?.cancel();
    _quietTimer = null;
    _subscription.cancel();
    if (!_out.isClosed) _out.close();
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  void _onEvent(_FragEvent ev) {
    switch (ev) {
      case _HeaderEvent(:final header):
        // A new header always starts a new record. If a previous
        // record was in-flight we flush it first — the caller issued
        // a new request without a quiet-window settle, so the prior
        // record was effectively abandoned by the firmware; we
        // surface what we have rather than dropping it.
        if (_hasInFlight) {
          _flush();
        }
        _quietTimer?.cancel();
        _quietTimer = null;
        _pendingHeader = header;
        _pendingPayload.clear();
        _hasInFlight = true;
      case _ChunkEvent(:final chunk):
        if (!_hasInFlight) {
          // Chunks before any header — firmware protocol violation,
          // but we silently drop rather than crashing. (A consumer
          // that needs stricter behavior can wrap the source stream
          // and assert.)
          return;
        }
        _pendingPayload.add(chunk.payload);
        _resetQuietTimer();
    }
  }

  void _resetQuietTimer() {
    _quietTimer?.cancel();
    _quietTimer = Timer(_quietWindow, () {
      if (_hasInFlight) _flush();
    });
  }

  void _flush() {
    final h = _pendingHeader;
    final payload = _pendingPayload.toBytes();
    _quietTimer?.cancel();
    _quietTimer = null;
    _pendingHeader = null;
    _pendingPayload.clear();
    _hasInFlight = false;
    if (h == null) return;
    if (_out.isClosed) return;
    _out.add(_build(h, payload));
  }
}

// ---------------------------------------------------------------------------
// Internal stream plumbing
// ---------------------------------------------------------------------------

/// A tagged event for the merged header/chunk stream.
sealed class _FragEvent {
  const _FragEvent();
}

class _HeaderEvent<Header> extends _FragEvent {
  const _HeaderEvent(this.header);
  final Header header;
}

class _ChunkEvent<Chunk> extends _FragEvent {
  const _ChunkEvent(this.chunk);
  final Chunk chunk;
}

/// Merge a header stream and a chunk stream into a single tagged
/// event stream. Each source is forwarded independently so a slow
/// subscriber on one side cannot back-pressure the other.
Stream<_FragEvent> _merged<Header, Chunk>(
  Stream<Header> headers,
  Stream<Chunk> chunks,
) {
  final h = headers.map<_FragEvent>((h) => _HeaderEvent<Header>(h));
  final c = chunks.map<_FragEvent>((c) => _ChunkEvent<Chunk>(c));
  // StreamGroup is provided by the `async` package; we keep the
  // helper dependency-free by composing controllers here.
  final controller = StreamController<_FragEvent>();
  final subs = <StreamSubscription<_FragEvent>>[];
  var done = 0;
  void onDone() {
    done++;
    if (done == 2 && !controller.isClosed) controller.close();
  }

  for (final s in [h, c]) {
    subs.add(
      s.listen(controller.add, onError: controller.addError, onDone: onDone),
    );
  }
  controller.onCancel = () async {
    for (final s in subs) {
      await s.cancel();
    }
  };
  return controller.stream;
}
