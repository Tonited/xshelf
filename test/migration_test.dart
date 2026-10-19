/// v3 迁移测试：老库（v1/v2）升上来之后，喜欢一条不能丢、游标和区段也要跟着搬。
///
/// 数据层里最不该出错的就是迁移 —— 它只在用户升级的那一次跑，跑坏了没法回滚
/// （用户已经覆盖安装）。这里直接在临时文件里造出 v1/v2 的库，再用
/// [AppDatabase.open] 触发迁移，检查结果。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:xlikemanage/src/db/app_database.dart';

void main() {
  var available = true;

  setUpAll(() {
    try {
      open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open('winsqlite3.dll'),
      );
      final probe = AppDatabase.open(':memory:');
      probe.dispose();
    } catch (_) {
      available = false;
    }
  });

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xlike_migrate');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// v1 时代的表结构（与 `AppDatabase._migrate` 的 v1 分支保持一致，
  /// 刻意不带 `kind` 列，迁移才有意义）。
  void createV1(Database db) {
    db.execute('''
      CREATE TABLE accounts(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        x_user_id TEXT NOT NULL UNIQUE,
        screen_name TEXT,
        display_name TEXT,
        avatar_url TEXT
      );
      CREATE TABLE likes(
        tweet_id TEXT PRIMARY KEY,
        account_id INTEGER NOT NULL DEFAULT 0,
        feed_seq INTEGER,
        rand_key INTEGER,
        created_at INTEGER,
        text TEXT NOT NULL DEFAULT '',
        lang TEXT,
        author_id TEXT,
        author_name TEXT,
        author_screen_name TEXT,
        author_avatar TEXT,
        media_json TEXT,
        has_video INTEGER NOT NULL DEFAULT 0,
        has_image INTEGER NOT NULL DEFAULT 0,
        has_gif INTEGER NOT NULL DEFAULT 0,
        sensitive INTEGER NOT NULL DEFAULT 0,
        reply_to TEXT,
        quote_of TEXT,
        retweet_of TEXT,
        state TEXT NOT NULL DEFAULT 'normal',
        fetched_at INTEGER,
        verified_at INTEGER,
        raw_json TEXT
      );
      CREATE INDEX idx_likes_seq ON likes(feed_seq);
      CREATE INDEX idx_likes_created ON likes(created_at);
      CREATE INDEX idx_likes_rand ON likes(rand_key);
      CREATE INDEX idx_likes_state ON likes(state);
      CREATE INDEX idx_likes_author ON likes(author_screen_name);
      CREATE TABLE media(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        tweet_id TEXT NOT NULL,
        idx INTEGER NOT NULL,
        kind TEXT NOT NULL,
        url TEXT NOT NULL,
        playback_url TEXT,
        duration_ms INTEGER,
        local_path TEXT,
        bytes INTEGER NOT NULL DEFAULT 0,
        last_used_at INTEGER,
        UNIQUE(tweet_id, idx)
      );
      CREATE TABLE segments(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        account_id INTEGER NOT NULL DEFAULT 0,
        start_seq INTEGER NOT NULL,
        end_seq INTEGER NOT NULL,
        cursor TEXT,
        verified_at INTEGER,
        UNIQUE(account_id, start_seq)
      );
      CREATE TABLE sync_state(
        account_id INTEGER PRIMARY KEY,
        top_cursor TEXT,
        backfill_cursor TEXT,
        min_seq INTEGER,
        max_seq INTEGER,
        backfill_done INTEGER NOT NULL DEFAULT 0,
        probe_at INTEGER,
        probe_remote_count INTEGER,
        rotate_seq INTEGER
      );
      CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT);
      CREATE VIRTUAL TABLE likes_fts USING fts5(
        tweet_id UNINDEXED, text, author_name, author_screen_name,
        tokenize='unicode61'
      );
    ''');
    db.userVersion = 1;
  }

  void seed(Database db) {
    db.execute('''
      INSERT INTO likes(tweet_id, account_id, feed_seq, created_at, text,
        author_screen_name, has_video, state)
      VALUES
        ('t1', 1, 2000000, 1600000000000, 'first', 'alice', 1, 'normal'),
        ('t2', 1, 1000000, 1500000000000, 'second', 'bob', 0, 'normal'),
        ('t3', 1, 0, 1400000000000, 'gone', 'carol', 0, 'removed');
      INSERT INTO sync_state(account_id, backfill_cursor, min_seq, max_seq, backfill_done)
      VALUES(1, 'cursor-abc', 2000000, 0, 0);
      INSERT INTO segments(account_id, start_seq, end_seq, cursor)
      VALUES(1, 0, 200000000, 'seg-cursor');
      INSERT INTO likes_fts(tweet_id, text, author_name, author_screen_name)
      VALUES('t1', 'first', 'Alice', 'alice');
    ''');
  }

  File openV1File() {
    final path = p.join(tmp.path, 'v1.db');
    final db = sqlite3.open(path);
    createV1(db);
    seed(db);
    db.dispose();
    return File(path);
  }

  test('v1 库升到 v3：喜欢一条不丢，全部落成 kind=like', () {
    if (!available) return;
    final file = openV1File();

    final app = AppDatabase.open(file.path);
    addTearDown(app.dispose);

    // 三条都在（包括 removed 那条：它只是不能出现在列表里）。
    expect(app.countLikes(), 3);
    expect(app.countLikes(includeDeleted: false), 2);
    // 默认 kinds 只有 like，书签一行都没有。
    expect(app.countLikes(kinds: {'bookmark'}), 0);
    // 内容与状态原样。
    expect(app.getLike('t1')?.text, 'first');
    expect(app.getLike('t3')?.tweetId, 't3');
    // 游标 / 区段跟着搬过来。
    expect(app.loadSyncState(1).backfillCursor, 'cursor-abc');
    expect(app.loadSyncState(1).minSeq, 2000000);
    expect(app.stalestSegments(1).single.cursor, 'seg-cursor');
    expect(app.stalestSegments(1, kind: 'bookmark'), isEmpty);
  });

  test('v2 库（media 已加画质列）升到 v3 也不丢数据', () {
    if (!available) return;
    final file = openV1File();
    // 在 v1 基础上补齐 v2 的列，模拟一个升到 v2 的库。
    final db = sqlite3.open(file.path);
    db.execute('ALTER TABLE media ADD COLUMN cache_variant TEXT');
    db.execute('ALTER TABLE media ADD COLUMN best_variant TEXT');
    db.execute('ALTER TABLE media ADD COLUMN best_rank INTEGER');
    db.userVersion = 2;
    db.dispose();

    final app = AppDatabase.open(file.path);
    addTearDown(app.dispose);
    expect(app.countLikes(), 3);
    expect(app.getLike('t2')?.text, 'second');
  });

  test('升上来之后可以写书签，而且和喜欢各占一行', () {
    if (!available) return;
    final file = openV1File();
    final app = AppDatabase.open(file.path);
    addTearDown(app.dispose);

    // 同一 tweet 在两种来源各一行。
    app.markRemoved(['t1'], kind: 'bookmark');
    expect(app.countLikes(kinds: {'bookmark'}), 0);

    app.restoreLike('t1', kind: 'bookmark');
    // 书签行还不存在 → restore 不会凭空造行。
    expect(app.countLikes(kinds: {'bookmark'}), 0);

    // 喜欢被标记移除，不影响书签的读取口径。
    app.markRemoved(['t1'], kind: 'like');
    expect(app.countLikes(), 3);
    expect(app.countLikes(includeDeleted: false), 1);
  });
}
