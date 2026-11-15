import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:plezy/utils/app_logger.dart';

LogEntry _entry(String message) => LogEntry(timestamp: DateTime(2026, 11, 14), level: Level.info, message: message);

void main() {
  late Directory dir;
  File file(String name) => File('${dir.path}/$name');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('session_log_test');
    SessionLogFile.directoryProvider = () async => dir;
    SessionLogFile.maxBytes = 4 * 1024 * 1024;
    await SessionLogFile.resetForTesting();
  });

  tearDown(() async {
    await SessionLogFile.resetForTesting();
    await dir.delete(recursive: true);
  });

  test('writes nothing while debug logging is off', () async {
    SessionLogFile.write(_entry('quiet'));
    await SessionLogFile.flushed();
    expect(file(SessionLogFile.fileName).existsSync(), isFalse);
  });

  test('writes while on, and keeps the previous launch beside the new one', () async {
    await SessionLogFile.setEnabled(true);
    SessionLogFile.write(_entry('first run'));
    await SessionLogFile.flushed();

    // A new launch.
    await SessionLogFile.resetForTesting();
    await SessionLogFile.setEnabled(true);
    SessionLogFile.write(_entry('second run'));
    await SessionLogFile.flushed();

    expect(file(SessionLogFile.previousFileName).readAsStringSync(), contains('first run'));
    expect(file(SessionLogFile.fileName).readAsStringSync(), contains('second run'));
    final both = await SessionLogFile.read();
    expect(both!.indexOf('first run'), lessThan(both.indexOf('second run')));
  });

  test('past the cap it rotates, so the latest lines are always kept', () async {
    SessionLogFile.maxBytes = 200;
    await SessionLogFile.setEnabled(true);
    for (var i = 0; i < 20; i++) {
      SessionLogFile.write(_entry('line $i ${'x' * 40}'));
      await SessionLogFile.flushed();
    }

    final current = file(SessionLogFile.fileName).readAsStringSync();
    expect(current, contains('line 19'), reason: 'the newest line must survive the cap');
    expect(current.length, lessThan(400));
    expect(file(SessionLogFile.previousFileName).existsSync(), isTrue);
    expect(file(SessionLogFile.previousFileName).readAsStringSync(), isNot(contains('line 0 ')));
  });

  test('clearing deletes both files, and the next line starts a new one', () async {
    await SessionLogFile.setEnabled(true);
    SessionLogFile.write(_entry('before'));
    await SessionLogFile.flushed();
    await SessionLogFile.resetForTesting();
    await SessionLogFile.setEnabled(true);
    SessionLogFile.write(_entry('also before'));
    await SessionLogFile.flushed();

    await SessionLogFile.clear();
    expect(file(SessionLogFile.fileName).existsSync(), isFalse);
    expect(file(SessionLogFile.previousFileName).existsSync(), isFalse);
    expect(await SessionLogFile.read(), isNull);

    SessionLogFile.write(_entry('after'));
    await SessionLogFile.flushed();
    expect(await SessionLogFile.read(), allOf(contains('after'), isNot(contains('before'))));
  });

  test('turning debug logging off deletes the files and stops writing', () async {
    await SessionLogFile.setEnabled(true);
    SessionLogFile.write(_entry('on'));
    await SessionLogFile.flushed();

    await SessionLogFile.setEnabled(false);
    SessionLogFile.write(_entry('off'));
    await SessionLogFile.flushed();

    expect(file(SessionLogFile.fileName).existsSync(), isFalse);
    expect(file(SessionLogFile.previousFileName).existsSync(), isFalse);
  });
}
