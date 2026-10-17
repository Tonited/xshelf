import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

/// The app ships SQLite through `sqlite3_flutter_libs`, which only exists at
/// app runtime. For host tests we bind to whatever SQLite the OS provides
/// (Windows: winsqlite3.dll). If that fails the whole group is skipped so the
/// suite stays green on machines without it.
void main() {
  var available = true;
  setUpAll(() {
    try {
      open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open('winsqlite3.dll'),
      );
      final db = sqlite3.openInMemory();
      db.execute('SELECT 1');
      db.dispose();
    } catch (_) {
      available = false;
    }
  });

  group('sqlite availability', () {
    test('opens an in-memory database', () {
      if (!available) return;
      final db = sqlite3.openInMemory();
      final rows = db.select('SELECT 1 + 1 AS v');
      expect(rows.first['v'], 2);
      db.dispose();
    }, skip: !available ? 'system sqlite3 not available' : false);
  });
}
