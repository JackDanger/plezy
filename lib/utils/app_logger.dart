import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

import 'log_redaction_manager.dart';

/// Represents a single log entry stored in memory
class LogEntry {
  final DateTime timestamp;
  final Level level;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  const LogEntry({required this.timestamp, required this.level, required this.message, this.error, this.stackTrace});

  /// Estimate the memory size of this log entry in bytes
  int get estimatedSize {
    int size = 0;
    size += 8;
    size += 4;
    size += message.length * 2;
    if (error != null) {
      size += error.toString().length * 2;
    }
    if (stackTrace != null) {
      size += stackTrace.toString().length * 2;
    }
    return size;
  }
}

/// In-memory log store with a circular buffer.
///
/// Fed by [MemoryAwareLogPrinter.log()]; console output goes through the
/// logger's default [ConsoleOutput].
class MemoryLogOutput {
  static const int maxLogSizeBytes = 5 * 1024 * 1024;
  static final ListQueue<LogEntry> _logs = ListQueue<LogEntry>();
  static int _currentSize = 0;

  /// Append [entry], evicting the oldest entries once the buffer exceeds
  /// [maxLogSizeBytes] — O(1) with ListQueue.
  static void add(LogEntry entry) {
    _logs.add(entry);
    _currentSize += entry.estimatedSize;
    while (_currentSize > maxLogSizeBytes && _logs.isNotEmpty) {
      _currentSize -= _logs.removeFirst().estimatedSize;
    }
  }

  static List<LogEntry> getLogs() => _logs.toList().reversed.toList();

  static void clearLogs() {
    _logs.clear();
    _currentSize = 0;
  }
}

/// Mirrors the log to a file while debug logging is on, so a run can be read
/// after it happened, including after the app restarts.
///
/// The file lives in the app's cache directory, which neither iOS (Library/
/// Caches) nor Android (cacheDir) backs up. It can be pulled off an iPhone with
/// `xcrun devicectl device copy from --domain-type appDataContainer`, and
/// Logs › Copy includes it.
///
/// Past [maxBytes] the file is rotated: it becomes [previousFileName] (one
/// generation, replacing the older one) and a new file starts, so the lines
/// just before a failure are always kept. Each launch rotates too, so the
/// previous run survives the restart that usually follows a problem.
///
/// Turning debug logging off, or Logs › Clear, deletes both files.
abstract final class SessionLogFile {
  static const String fileName = 'plezy-session.log';
  static const String previousFileName = 'plezy-session.log.1';

  @visibleForTesting
  static int maxBytes = 4 * 1024 * 1024;

  @visibleForTesting
  static Future<Directory> Function() directoryProvider = getApplicationCacheDirectory;

  static bool _enabled = false;
  static IOSink? _sink;
  static int _written = 0;
  static final List<String> _pending = [];
  static bool _drainScheduled = false;

  /// Every file operation runs on this chain, one at a time: an [IOSink]
  /// throws if written to during a flush, and rotation must not interleave
  /// with a write.
  static Future<void> _chain = Future<void>.value();

  static Future<void> _enqueue(Future<void> Function() op) {
    final next = _chain.then((_) => op()).catchError((Object _) {
      // A failed log file must never take the app down with it.
      _sink = null;
    });
    _chain = next;
    return next;
  }

  static bool get enabled => _enabled;

  /// Follows `SettingsService.enableDebugLogging`. Off stops writing and
  /// deletes the files.
  static Future<void> setEnabled(bool enabled) {
    if (enabled == _enabled) return _chain;
    _enabled = enabled;
    if (enabled) return _chain;
    _pending.clear();
    return _enqueue(_deleteFiles);
  }

  static void write(LogEntry entry) {
    if (!_enabled) return;
    _pending.add(
      '${entry.timestamp.toIso8601String()} [${entry.level.name}] ${entry.message}'
      '${entry.error == null ? '' : '  ERROR: ${entry.error}'}',
    );
    if (_drainScheduled) return;
    _drainScheduled = true;
    unawaited(_enqueue(_drain));
  }

  /// Delete both files. The next line written starts a new one.
  static Future<void> clear() {
    _pending.clear();
    return _enqueue(_deleteFiles);
  }

  /// The previous file followed by the current one, or null when neither has
  /// anything in it.
  static Future<String?> read() async {
    await _chain;
    try {
      final dir = await directoryProvider();
      final parts = <String>[
        for (final name in [previousFileName, fileName])
          if (File('${dir.path}/$name').existsSync()) await File('${dir.path}/$name').readAsString(),
      ].where((part) => part.trim().isNotEmpty).toList();
      return parts.isEmpty ? null : parts.join('\n');
    } catch (_) {
      return null;
    }
  }

  /// Waits for everything written so far to reach the disk.
  @visibleForTesting
  static Future<void> flushed() => _chain;

  /// Forget all state, as a fresh launch would.
  @visibleForTesting
  static Future<void> resetForTesting() async {
    await _chain;
    await _closeSink();
    _enabled = false;
    _pending.clear();
    _drainScheduled = false;
  }

  static Future<void> _drain() async {
    _drainScheduled = false;
    if (!_enabled || _pending.isEmpty) return;
    final batch = _pending.join('\n');
    _pending.clear();
    if (_sink == null || _written > maxBytes) await _rotate();
    final sink = _sink;
    if (sink == null) return;
    sink.writeln(batch);
    _written += batch.length + 1;
    await sink.flush();
  }

  /// Move the current file aside, replacing the older one, and start anew.
  static Future<void> _rotate() async {
    await _closeSink();
    final dir = await directoryProvider();
    final file = File('${dir.path}/$fileName');
    if (file.existsSync()) await file.rename('${dir.path}/$previousFileName');
    // Never closed while in use: closing it on the way down would lose exactly
    // the lines that explain why.
    // ignore: close_sinks
    final sink = file.openWrite(mode: FileMode.write);
    final header = '--- log started ${DateTime.now().toIso8601String()} ---';
    sink.writeln(header);
    _sink = sink;
    _written = header.length + 1;
  }

  static Future<void> _closeSink() async {
    final sink = _sink;
    _sink = null;
    _written = 0;
    if (sink != null) await sink.close();
  }

  static Future<void> _deleteFiles() async {
    await _closeSink();
    final dir = await directoryProvider();
    for (final name in [fileName, previousFileName]) {
      final file = File('${dir.path}/$name');
      if (file.existsSync()) await file.delete();
    }
  }
}

/// Custom log printer that also stores error and stack trace information
class MemoryAwareLogPrinter extends LogPrinter {
  final LogPrinter _wrappedPrinter;

  MemoryAwareLogPrinter(this._wrappedPrinter);

  @override
  List<String> log(LogEvent event) {
    final message = LogRedactionManager.redact(event.message.toString());
    final error = event.error != null ? LogRedactionManager.redact(event.error.toString()) : null;
    final stackTrace = event.stackTrace != null
        ? StackTrace.fromString(LogRedactionManager.redact(event.stackTrace.toString()))
        : null;

    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: event.level,
      message: message,
      error: error,
      stackTrace: stackTrace,
    );
    MemoryLogOutput.add(entry);
    // Here rather than in a LogOutput: `appLogger` is built without an
    // `output:`, so this printer is the one path every line takes.
    SessionLogFile.write(entry);

    return _wrappedPrinter.log(LogEvent(event.level, message, time: event.time, error: error, stackTrace: stackTrace));
  }
}

/// Custom production filter that respects our level setting even in release mode
class ProductionFilter extends LogFilter {
  Level _currentLevel = Level.debug;

  void setLevel(Level level) {
    _currentLevel = level;
  }

  bool isEnabledFor(Level level) => level.value >= _currentLevel.value;

  @override
  bool shouldLog(LogEvent event) => isEnabledFor(event.level);
}

final _productionFilter = ProductionFilter();

/// Whether [appLogger].d would actually emit.
///
/// Dart builds a log call's message argument *before* the filter can drop it,
/// so a `.d()` whose message costs real work — string interpolation in a loop,
/// `redact()`, `jsonEncode`, a collection `toString()` — pays that cost on
/// every call in release, where the line is then discarded. Guard those call
/// sites with this; plain constant or cheap messages need no guard.
bool get debugLoggingEnabled => _productionFilter.isEnabledFor(Level.debug);

/// Centralized logger instance for the application.
///
/// Usage:
/// ```dart
/// import 'package:plezy/utils/app_logger.dart';
///
/// appLogger.d('Debug message');
/// appLogger.i('Info message');
/// appLogger.w('Warning message');
/// appLogger.e('Error message', error: e, stackTrace: stackTrace);
/// ```
///
/// Non-final so tests can swap in a recording logger.
Logger appLogger = Logger(printer: MemoryAwareLogPrinter(SimplePrinter()), filter: _productionFilter);

/// Update the logger's level dynamically based on the debug setting.
///
/// [ProductionFilter] is the only gate: [Logger] asks its filter on every
/// event, so changing the filter level is sufficient even in release mode.
void setLoggerLevel(bool debugEnabled) {
  unawaited(SessionLogFile.setEnabled(debugEnabled));
  _productionFilter.setLevel(debugEnabled ? Level.debug : Level.info);
}
