/// 本地库：schema、迁移、以及所有读写语句。
///
/// 设计要点：
/// - 直接用 `package:sqlite3` + 手写 SQL（不用 ORM/codegen，改起来快、易审）。
/// - **`feed_seq` 是稳定序号**：X 的喜欢列表按喜欢时间倒序，新增喜欢会把「第几条」
///   整体顶下去，所以不用「位置」当键，而是首次入库时分配一个**单调递减**的序号：
///   新的越小，`ORDER BY feed_seq ASC` 就是最新在前，且已有行永远不变——分页不会跳条、
///   区段不会错位、滚动锚点可以长期保存。
/// - `rand_key` 给随机模式用，稳定分页。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:sqlite3/sqlite3.dart';

import '../model/like_item.dart';

/// 视图排序模式。
enum SortMode {
  /// 喜欢顺序（默认）
  likeOrder,

  /// 按推文发布日期
  publishDate,

  /// 随机
  random;

  static SortMode fromName(String? name) =>
      SortMode.values.firstWhere((m) => m.name == name, orElse: () => SortMode.likeOrder);
}

/// 媒体类型筛选。
enum MediaFilter { video, image, gif, text }

class LikesFilter {
  const LikesFilter({
    this.media = const {},
    this.authorScreenName,
    this.authorsIn = const {},
    this.from,
    this.to,
    this.search,
    this.lang,
    this.excludeReplies = false,
    this.excludeRetweets = false,
  });

  final Set<MediaFilter> media;
  final String? authorScreenName;

  /// 限定这几个作者（`author_screen_name IN (...)`）。刷视频页的
  /// 「只看我关注的人」用它 —— 单个 [authorScreenName] 表达不了集合。
  final Set<String> authorsIn;

  final DateTime? from;
  final DateTime? to;
  final String? search;

  /// 只要某种语言（`likes.lang`）。
  final String? lang;

  /// 排除回复 / 转推。本地库里有 `reply_to` / `retweet_of`，和 X 的
  /// `-filter:replies` 语义一致，搜索页两种模式因此可以共用一套条件 UI。
  final bool excludeReplies;
  final bool excludeRetweets;

  bool get isEmpty =>
      media.isEmpty &&
      authorScreenName == null &&
      authorsIn.isEmpty &&
      from == null &&
      to == null &&
      lang == null &&
      !excludeReplies &&
      !excludeRetweets &&
      (search == null || search!.trim().isEmpty);

  /// 除关键词之外还设了几个条件（chip 上的数字用它）。
  int get conditionCount =>
      (media.isEmpty ? 0 : 1) +
      ((authorScreenName == null && authorsIn.isEmpty) ? 0 : 1) +
      (from == null && to == null ? 0 : 1) +
      (lang == null ? 0 : 1) +
      (excludeReplies ? 1 : 0) +
      (excludeRetweets ? 1 : 0);

  LikesFilter copyWith({
    Set<MediaFilter>? media,
    String? authorScreenName,
    Set<String>? authorsIn,
    DateTime? from,
    DateTime? to,
    String? search,
    String? lang,
    bool? excludeReplies,
    bool? excludeRetweets,
    bool clearAuthor = false,
    bool clearRange = false,
    bool clearSearch = false,
    bool clearLang = false,
  }) =>
      LikesFilter(
        media: media ?? this.media,
        authorScreenName:
            clearAuthor ? null : (authorScreenName ?? this.authorScreenName),
        authorsIn: clearAuthor ? const {} : (authorsIn ?? this.authorsIn),
        from: clearRange ? null : (from ?? this.from),
        to: clearRange ? null : (to ?? this.to),
        search: clearSearch ? null : (search ?? this.search),
        lang: clearLang ? null : (lang ?? this.lang),
        excludeReplies: excludeReplies ?? this.excludeReplies,
        excludeRetweets: excludeRetweets ?? this.excludeRetweets,
      );

  Map<String, Object?> toJson() => {
        'media': [for (final m in media) m.name],
        if (authorScreenName != null) 'author': authorScreenName,
        if (authorsIn.isNotEmpty) 'authors': authorsIn.toList(),
        if (from != null) 'from': from!.millisecondsSinceEpoch,
        if (to != null) 'to': to!.millisecondsSinceEpoch,
        if (search != null) 'search': search,
        if (lang != null) 'lang': lang,
        if (excludeReplies) 'noReplies': true,
        if (excludeRetweets) 'noRetweets': true,
      };

  factory LikesFilter.fromJson(Map<String, Object?> j) => LikesFilter(
        media: {
          for (final m in (j['media'] as List? ?? const []))
            MediaFilter.values.firstWhere((v) => v.name == m,
                orElse: () => MediaFilter.text),
        },
        authorScreenName: j['author'] as String?,
        authorsIn: {
          for (final a in (j['authors'] as List? ?? const [])) a.toString(),
        },
        from: j['from'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (j['from'] as num).toInt(),
                isUtc: true),
        to: j['to'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (j['to'] as num).toInt(),
                isUtc: true),
        search: j['search'] as String?,
        lang: j['lang'] as String?,
        excludeReplies: j['noReplies'] == true,
        excludeRetweets: j['noRetweets'] == true,
      );
}

/// 分页游标：三种模式各用其中一个字段。
class PageKey {
  const PageKey({this.seq, this.publishedAt, this.tweetId, this.randKey});

  final int? seq;
  final int? publishedAt;
  final String? tweetId;
  final int? randKey;
}

class PageResult {
  const PageResult(this.items, this.key);
  final List<LikeItem> items;

  /// 下一页的定位键；为 null 表示没有更多。
  final PageKey? key;
}

class AuthorCount {
  const AuthorCount(this.screenName, this.name, this.count);
  final String screenName;
  final String name;
  final int count;
}

class MonthBucket {
  const MonthBucket(this.month, this.count, this.minMs, this.maxMs);

  /// `2023-05`
  final String month;
  final int count;
  final int minMs;
  final int maxMs;
}

class SyncState {
  const SyncState({
    this.topCursor,
    this.backfillCursor,
    this.minSeq,
    this.maxSeq,
    this.backfillDone = false,
    this.probeAt,
    this.probeRemoteCount,
    this.rotateSeq,
  });

  final String? topCursor;

  /// 全量回填断点（下一页游标）；回填完成后清空。
  final String? backfillCursor;

  /// 已分配的最小序号（最新那条喜欢的 seq）
  final int? minSeq;

  /// 已分配的最大序号（最旧那条喜欢的 seq）
  final int? maxSeq;
  final bool backfillDone;
  final DateTime? probeAt;
  final int? probeRemoteCount;

  /// 陈段轮转的游标（从旧往新扫）
  final int? rotateSeq;

  SyncState copyWith({
    String? topCursor,
    String? backfillCursor,
    int? minSeq,
    int? maxSeq,
    bool? backfillDone,
    DateTime? probeAt,
    int? probeRemoteCount,
    int? rotateSeq,
    bool clearBackfillCursor = false,
  }) =>
      SyncState(
        topCursor: topCursor ?? this.topCursor,
        backfillCursor:
            clearBackfillCursor ? null : (backfillCursor ?? this.backfillCursor),
        minSeq: minSeq ?? this.minSeq,
        maxSeq: maxSeq ?? this.maxSeq,
        backfillDone: backfillDone ?? this.backfillDone,
        probeAt: probeAt ?? this.probeAt,
        probeRemoteCount: probeRemoteCount ?? this.probeRemoteCount,
        rotateSeq: rotateSeq ?? this.rotateSeq,
      );
}

class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;

  static AppDatabase open(String path) {
    final dir = Directory(File(path).parent.path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _configured(sqlite3.open(path), wal: true);
  }

  /// 内存库（测试用）：同样的 schema，进程结束即消失。
  static AppDatabase openInMemory() =>
      _configured(sqlite3.openInMemory(), wal: false);

  static AppDatabase _configured(Database db, {required bool wal}) {
    if (wal) db.execute('PRAGMA journal_mode=WAL;');
    db.execute('PRAGMA synchronous=NORMAL;');
    db.execute('PRAGMA foreign_keys=ON;');
    // 5 万条 + 全文索引的库大约几十 MB，给 16 MB 页缓存能显著减少读盘；
    // busy_timeout 让「边同步边浏览」时偶发的写锁等待不直接抛错。
    db.execute('PRAGMA cache_size=-16000;');
    db.execute('PRAGMA busy_timeout=3000;');
    db.execute('PRAGMA temp_store=MEMORY;');
    final instance = AppDatabase._(db);
    instance._migrate();
    return instance;
  }

  // sqlite3 2.x 用 dispose()（3.x 才改名 close()）。
  void dispose() => _db.dispose();

  // ---------------------------------------------------------------- schema

  void _migrate() {
    final current = _db.userVersion;
    if (current < 1) {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS accounts(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          x_user_id TEXT NOT NULL UNIQUE,
          screen_name TEXT,
          display_name TEXT,
          avatar_url TEXT
        );

        CREATE TABLE IF NOT EXISTS likes(
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
        CREATE INDEX IF NOT EXISTS idx_likes_seq ON likes(feed_seq);
        CREATE INDEX IF NOT EXISTS idx_likes_created ON likes(created_at);
        CREATE INDEX IF NOT EXISTS idx_likes_rand ON likes(rand_key);
        CREATE INDEX IF NOT EXISTS idx_likes_state ON likes(state);
        CREATE INDEX IF NOT EXISTS idx_likes_author ON likes(author_screen_name);

        CREATE TABLE IF NOT EXISTS media(
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
        CREATE INDEX IF NOT EXISTS idx_media_tweet ON media(tweet_id);
        CREATE INDEX IF NOT EXISTS idx_media_last_used ON media(last_used_at);

        CREATE TABLE IF NOT EXISTS segments(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          account_id INTEGER NOT NULL DEFAULT 0,
          start_seq INTEGER NOT NULL,
          end_seq INTEGER NOT NULL,
          cursor TEXT,
          verified_at INTEGER,
          UNIQUE(account_id, start_seq)
        );

        CREATE TABLE IF NOT EXISTS sync_state(
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

        CREATE TABLE IF NOT EXISTS kv(
          key TEXT PRIMARY KEY,
          value TEXT
        );
      ''');
      _createFts();
      _db.userVersion = 1;
    }
    if (current < 2) {
      // 画质记忆：本地文件是哪一档、这条媒体看过的最好是哪一档。
      // 老库没有这两列时补上（ADD COLUMN 对已有表是安全的）。
      _addColumn('media', 'cache_variant', 'TEXT');
      _addColumn('media', 'best_variant', 'TEXT');
      _addColumn('media', 'best_rank', 'INTEGER');
      _db.userVersion = 2;
    }
  }

  /// 幂等地加一列（SQLite 没有 `ADD COLUMN IF NOT EXISTS`）。
  void _addColumn(String table, String column, String type) {
    final columns = _db.select('PRAGMA table_info($table)');
    if (columns.any((c) => c['name'] == column)) return;
    _db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  /// 优先 trigram（中文子串可搜），不支持时退回 unicode61。
  void _createFts() {
    try {
      _db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS likes_fts USING fts5(
          tweet_id UNINDEXED, text, author_name, author_screen_name,
          tokenize='trigram'
        );
      ''');
      _kvSet('fts.tokenizer', 'trigram');
    } catch (_) {
      _db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS likes_fts USING fts5(
          tweet_id UNINDEXED, text, author_name, author_screen_name
        );
      ''');
      _kvSet('fts.tokenizer', 'unicode61');
    }
  }

  String get ftsTokenizer => _kvGet('fts.tokenizer') ?? 'unicode61';

  /// 记住的 GraphQL queryId（X 改版后我们会在请求失败时清掉它并重新发现）。
  ///
  /// 不记住的话，每次冷启动都要抓 x.com 首页 + 十几个 JS 文件才能发出第一个
  /// 请求 —— 又慢又容易在弱网/代理下失败。
  String? cachedQueryId(String operation) => _kvGet('queryId.$operation');

  void saveQueryId(String operation, String queryId) =>
      _kvSet('queryId.$operation', queryId);

  void clearQueryId(String operation) =>
      _db.execute('DELETE FROM kv WHERE key = ?', ['queryId.$operation']);

  // ---------------------------------------------------------- follow state
  //
  // X 的喜欢接口不返回「我和这个作者是什么关系」，播放页又必须马上知道该显示
  // 「关注」还是「已关注」。所以在本地记一份：改过就记，没记录就是未知（按未关注
  // 处理，因为这里出现的作者多数是被偶喜欢进来的陌生人）。

  bool isFollowing(String userId) =>
      userId.isNotEmpty && _kvGet('follow.$userId') == '1';

  void setFollowing(String userId, bool following) {
    if (userId.isEmpty) return;
    if (following) {
      _kvSet('follow.$userId', '1');
    } else {
      _db.execute('DELETE FROM kv WHERE key = ?', ['follow.$userId']);
    }
  }

  /// 我关注过的作者（`screen_name` 列表）。
  ///
  /// kv 里记的是 userId（关注接口需要它），而刷视频页按 screen_name 过滤，
  /// 所以借 likes 表把 id 映射回名字。从没关注过任何人时返回空。
  List<String> followedScreenNames() {
    final rows = _db.select('''
      SELECT DISTINCT author_screen_name AS n
      FROM likes
      WHERE author_id IN (SELECT substr(key, 8) FROM kv WHERE key LIKE 'follow.%')
        AND author_screen_name IS NOT NULL
    ''');
    return [
      for (final r in rows)
        if ((r['n'] as String?)?.isNotEmpty ?? false) r['n'] as String,
    ];
  }

  /// 远端「我在关注谁」的缓存（JSON 字符串数组）。
  ///
  /// 每次刷视频页都去拉一遍 friends/list 太慢，先读缓存再后台刷新。
  String? get followingCache => _kvGet('following.cache');

  void setFollowingCache(String? json) {
    if (json == null || json.isEmpty) {
      _db.execute("DELETE FROM kv WHERE key = 'following.cache'");
    } else {
      _kvSet('following.cache', json);
    }
  }

  /// 作者在本地有多少条喜欢（作者空间页用来出标题与计数）。
  int countByAuthor(String screenName) {
    final rows = _db.select(
      'SELECT COUNT(*) c FROM likes WHERE author_screen_name = ?',
      [screenName],
    );
    return rows.first['c'] as int? ?? 0;
  }

  // ------------------------------------------------------------ kv helpers

  String? _kvGet(String key) {
    final rows = _db.select('SELECT value FROM kv WHERE key = ?', [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  void _kvSet(String key, String value) => _db.execute(
      'INSERT INTO kv(key, value) VALUES(?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value]);

  // -------------------------------------------------------------- accounts

  int upsertAccount({
    required String xUserId,
    String? screenName,
    String? displayName,
    String? avatarUrl,
  }) {
    _db.execute('''
      INSERT INTO accounts(x_user_id, screen_name, display_name, avatar_url)
      VALUES(?, ?, ?, ?)
      ON CONFLICT(x_user_id) DO UPDATE SET
        screen_name = COALESCE(excluded.screen_name, accounts.screen_name),
        display_name = COALESCE(excluded.display_name, accounts.display_name),
        avatar_url = COALESCE(excluded.avatar_url, accounts.avatar_url)
    ''', [xUserId, screenName, displayName, avatarUrl]);
    final rows = _db.select('SELECT id FROM accounts WHERE x_user_id = ?', [xUserId]);
    return rows.first['id'] as int;
  }

  // ----------------------------------------------------------------- likes

  SyncState loadSyncState(int accountId) {
    final rows =
        _db.select('SELECT * FROM sync_state WHERE account_id = ?', [accountId]);
    if (rows.isEmpty) return const SyncState();
    final r = rows.first;
    return SyncState(
      topCursor: r['top_cursor'] as String?,
      backfillCursor: r['backfill_cursor'] as String?,
      minSeq: r['min_seq'] as int?,
      maxSeq: r['max_seq'] as int?,
      backfillDone: (r['backfill_done'] as int? ?? 0) == 1,
      probeAt: r['probe_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(r['probe_at'] as int, isUtc: true),
      probeRemoteCount: r['probe_remote_count'] as int?,
      rotateSeq: r['rotate_seq'] as int?,
    );
  }

  void saveSyncState(int accountId, SyncState s) {
    _db.execute('''
      INSERT INTO sync_state(account_id, top_cursor, backfill_cursor, min_seq, max_seq,
        backfill_done, probe_at, probe_remote_count, rotate_seq)
      VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(account_id) DO UPDATE SET
        top_cursor = excluded.top_cursor,
        backfill_cursor = excluded.backfill_cursor,
        min_seq = excluded.min_seq,
        max_seq = excluded.max_seq,
        backfill_done = excluded.backfill_done,
        probe_at = excluded.probe_at,
        probe_remote_count = excluded.probe_remote_count,
        rotate_seq = excluded.rotate_seq
    ''', [
      accountId,
      s.topCursor,
      s.backfillCursor,
      s.minSeq,
      s.maxSeq,
      s.backfillDone ? 1 : 0,
      s.probeAt?.millisecondsSinceEpoch,
      s.probeRemoteCount,
      s.rotateSeq,
    ]);
  }

  int countLikes({bool includeDeleted = true}) {
    final rows = _db.select(
      includeDeleted
          ? 'SELECT COUNT(*) c FROM likes'
          : "SELECT COUNT(*) c FROM likes WHERE state = 'normal'",
    );
    return rows.first['c'] as int;
  }

  bool hasTweet(String tweetId) {
    final rows = _db.select('SELECT 1 FROM likes WHERE tweet_id = ?', [tweetId]);
    return rows.isNotEmpty;
  }

  /// 批量判断哪些 id 已在本地（增量同步一页 100 条，以前是 100 次点查询）。
  Set<String> existingTweetIds(Iterable<String> ids) {
    final list = ids.toList();
    if (list.isEmpty) return const {};
    final out = <String>{};
    for (var i = 0; i < list.length; i += 500) {
      final chunk = list.sublist(i, math.min(i + 500, list.length));
      final holders = List.filled(chunk.length, '?').join(',');
      final rows = _db.select(
          'SELECT tweet_id FROM likes WHERE tweet_id IN ($holders)', chunk);
      out.addAll(rows.map((r) => r['tweet_id'] as String));
    }
    return out;
  }

  /// 批量取 seq（巡边器核对一页时用）。
  Map<String, int> seqsOf(Iterable<String> ids) {
    final list = ids.toList();
    if (list.isEmpty) return const {};
    final out = <String, int>{};
    for (var i = 0; i < list.length; i += 500) {
      final chunk = list.sublist(i, math.min(i + 500, list.length));
      final holders = List.filled(chunk.length, '?').join(',');
      final rows = _db.select(
          'SELECT tweet_id, feed_seq FROM likes WHERE tweet_id IN ($holders)',
          chunk);
      for (final r in rows) {
        final seq = r['feed_seq'] as int?;
        if (seq != null) out[r['tweet_id'] as String] = seq;
      }
    }
    return out;
  }

  /// seq 之间的初始间隔：留出空隙，供「视口核对」把漏掉的条目插进中间。
  /// 相邻两条相差 10^6，插入时取中点，理论上可插 20 次再需要重排。
  static const int seqStep = 1000000;

  /// 批量写入一页喜欢。
  ///
  /// 新条目从 [startSeq] 开始、每条递减 [seqStep]；已存在的条目保留原 seq
  /// （只刷新内容与 verified_at）。返回新增条数和下一页应使用的起始 seq。
  ({int inserted, int nextSeq}) insertPage(
    List<LikeItem> items, {
    required int accountId,
    required int startSeq,
    DateTime? now,
  }) {
    final ts = (now ?? DateTime.now()).millisecondsSinceEpoch;
    var seq = startSeq;
    var inserted = 0;
    _db.execute('BEGIN');
    try {
      final existsStmt = _db.prepare(
          'SELECT feed_seq, text, author_name, author_screen_name FROM likes WHERE tweet_id = ?');
      final insertStmt = _db.prepare('''
        INSERT INTO likes(tweet_id, account_id, feed_seq, rand_key, created_at, text, lang,
          author_id, author_name, author_screen_name, author_avatar, media_json,
          has_video, has_image, has_gif, sensitive, reply_to, quote_of, retweet_of,
          state, fetched_at, verified_at, raw_json)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ''');
      final updateStmt = _db.prepare('''
        UPDATE likes SET created_at=?, text=?, lang=?, author_id=?, author_name=?,
          author_screen_name=?, author_avatar=?, media_json=?, has_video=?, has_image=?,
          has_gif=?, sensitive=?, reply_to=?, quote_of=?, retweet_of=?,
          verified_at=?, raw_json=?, state='normal'
        WHERE tweet_id=?
      ''');
      final mediaStmt = _db.prepare('''
        INSERT INTO media(tweet_id, idx, kind, url, playback_url, duration_ms)
        VALUES(?,?,?,?,?,?)
        ON CONFLICT(tweet_id, idx) DO UPDATE SET
          kind=excluded.kind, url=excluded.url, playback_url=excluded.playback_url,
          duration_ms=excluded.duration_ms
      ''');
      final ftsStmt = _db.prepare(
          'INSERT INTO likes_fts(tweet_id, text, author_name, author_screen_name) VALUES(?,?,?,?)');
      final ftsDelStmt = _db.prepare('DELETE FROM likes_fts WHERE tweet_id = ?');

      final mediaTrimStmt =
          _db.prepare('DELETE FROM media WHERE tweet_id = ? AND idx >= ?');

      try {
        for (final item in items) {
          final existing = existsStmt.select([item.tweetId]);
          final isNew = existing.isEmpty;
          final row = isNew ? null : existing.first;
          final seqValue = isNew
              ? seq
              : ((row!['feed_seq'] as int?) ?? seq);
          seq -= seqStep;
          final randKey = item.randKey ?? randomSortKey();
          final mediaJson = jsonEncode([for (final m in item.media) m.toJson()]);

          // 刷新同一页时内容往往没变：此时跳过 FTS 的删+写，
          // 回填 5 万条能省下几万次 B 树写入（trigram 索引很贵）。
          final textUnchanged = row != null &&
              row['text'] == item.text &&
              (row['author_name'] ?? '') == (item.author?.name ?? '') &&
              (row['author_screen_name'] ?? '') == (item.author?.screenName ?? '');

          if (isNew) {
            inserted++;
            insertStmt.execute([
              item.tweetId,
              accountId,
              seqValue,
              randKey,
              item.createdAt?.millisecondsSinceEpoch,
              item.text,
              item.lang,
              item.author?.id,
              item.author?.name,
              item.author?.screenName,
              item.author?.avatarUrl,
              mediaJson,
              item.hasVideo ? 1 : 0,
              item.hasImage ? 1 : 0,
              item.hasGif ? 1 : 0,
              item.sensitive ? 1 : 0,
              item.replyTo,
              item.quoteOf,
              item.retweetOf,
              LikeState.normal.name,
              ts,
              ts,
              item.raw == null ? null : jsonEncode(item.raw),
            ]);
          } else {
            updateStmt.execute([
              item.createdAt?.millisecondsSinceEpoch,
              item.text,
              item.lang,
              item.author?.id,
              item.author?.name,
              item.author?.screenName,
              item.author?.avatarUrl,
              mediaJson,
              item.hasVideo ? 1 : 0,
              item.hasImage ? 1 : 0,
              item.hasGif ? 1 : 0,
              item.sensitive ? 1 : 0,
              item.replyTo,
              item.quoteOf,
              item.retweetOf,
              ts,
              item.raw == null ? null : jsonEncode(item.raw),
              item.tweetId,
            ]);
          }

          // 媒体行：先清后插，避免残留旧索引
          mediaTrimStmt.execute([item.tweetId, item.media.length]);
          for (var i = 0; i < item.media.length; i++) {
            final m = item.media[i];
            mediaStmt.execute([
              item.tweetId,
              i,
              m.kind.name,
              m.url,
              m.bestPlaybackUrl,
              m.durationMs,
            ]);
          }

          if (!textUnchanged) {
            ftsDelStmt.execute([item.tweetId]);
            ftsStmt.execute([
              item.tweetId,
              item.text,
              item.author?.name ?? '',
              item.author?.screenName ?? '',
            ]);
          }
        }
      } finally {
        existsStmt.dispose();
        insertStmt.dispose();
        updateStmt.dispose();
        mediaStmt.dispose();
        mediaTrimStmt.dispose();
        ftsStmt.dispose();
        ftsDelStmt.dispose();
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return (inserted: inserted, nextSeq: seq);
  }

  /// 在指定 seq 上插入单条（视口核对补缺口用）。
  ///
  /// 与相邻条目的 seq 太近（没有空隙）时返回 false，交给调用方决定是否重排。
  bool insertAtSeq(LikeItem item, {required int accountId, required int seq}) {
    if (hasTweet(item.tweetId)) return false;
    return _writeSingle(item, accountId: accountId, seq: seq);
  }

  /// 计算夹在 [before]/[after] 之间的 seq；无空隙返回 null。
  int? seqBetween(int? before, int? after) {
    if (before == null && after == null) return 0;
    if (before == null) return after! - 1;
    if (after == null) return before + 1;
    if (after - before <= 1) return null;
    return before + ((after - before) ~/ 2);
  }

  /// 取相邻的 seq：比 [seq] 小的最大者、比 [seq] 大的最小者。
  ({int? above, int? below}) neighborsOf(int seq) {
    final above = _db.select(
        'SELECT MAX(feed_seq) v FROM likes WHERE feed_seq < ?', [seq]);
    final below = _db.select(
        'SELECT MIN(feed_seq) v FROM likes WHERE feed_seq > ?', [seq]);
    return (
      above: above.first['v'] as int?,
      below: below.first['v'] as int?,
    );
  }

  bool _writeSingle(LikeItem item,
      {required int accountId, required int seq}) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final randKey = item.randKey ?? randomSortKey();
    _db.execute('BEGIN');
    try {
      _db.execute('''
        INSERT INTO likes(tweet_id, account_id, feed_seq, rand_key, created_at, text, lang,
          author_id, author_name, author_screen_name, author_avatar, media_json,
          has_video, has_image, has_gif, sensitive, reply_to, quote_of, retweet_of,
          state, fetched_at, verified_at, raw_json)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ''', [
        item.tweetId,
        accountId,
        seq,
        randKey,
        item.createdAt?.millisecondsSinceEpoch,
        item.text,
        item.lang,
        item.author?.id,
        item.author?.name,
        item.author?.screenName,
        item.author?.avatarUrl,
        jsonEncode([for (final m in item.media) m.toJson()]),
        item.hasVideo ? 1 : 0,
        item.hasImage ? 1 : 0,
        item.hasGif ? 1 : 0,
        item.sensitive ? 1 : 0,
        item.replyTo,
        item.quoteOf,
        item.retweetOf,
        LikeState.normal.name,
        ts,
        ts,
        item.raw == null ? null : jsonEncode(item.raw),
      ]);
      for (var i = 0; i < item.media.length; i++) {
        final m = item.media[i];
        _db.execute('''
          INSERT INTO media(tweet_id, idx, kind, url, playback_url, duration_ms)
          VALUES(?,?,?,?,?,?)
          ON CONFLICT(tweet_id, idx) DO UPDATE SET
            kind=excluded.kind, url=excluded.url, playback_url=excluded.playback_url,
            duration_ms=excluded.duration_ms
        ''', [item.tweetId, i, m.kind.name, m.url, m.bestPlaybackUrl, m.durationMs]);
      }
      _db.execute('DELETE FROM likes_fts WHERE tweet_id = ?', [item.tweetId]);
      _db.execute(
          'INSERT INTO likes_fts(tweet_id, text, author_name, author_screen_name) VALUES(?,?,?,?)',
          [
            item.tweetId,
            item.text,
            item.author?.name ?? '',
            item.author?.screenName ?? '',
          ]);
      _db.execute('COMMIT');
      return true;
    } catch (_) {
      _db.execute('ROLLBACK');
      return false;
    }
  }

  // -------------------------------------------------------------- segments

  /// 记录/更新一个区段（供巡边器核对用）。[cursor] 是能重新翻到该段起点的游标。
  void upsertSegment({
    required int accountId,
    required int startSeq,
    required int endSeq,
    String? cursor,
    DateTime? verifiedAt,
  }) {
    _db.execute('''
      INSERT INTO segments(account_id, start_seq, end_seq, cursor, verified_at)
      VALUES(?,?,?,?,?)
      ON CONFLICT(account_id, start_seq) DO UPDATE SET
        end_seq = excluded.end_seq,
        cursor = COALESCE(excluded.cursor, segments.cursor),
        verified_at = COALESCE(excluded.verified_at, segments.verified_at)
    ''', [
      accountId,
      startSeq,
      endSeq,
      cursor,
      verifiedAt?.millisecondsSinceEpoch,
    ]);
  }

  /// 最久没核对过的区段（点名给巡边器）。
  List<({int startSeq, int endSeq, String? cursor, DateTime? verifiedAt})>
      stalestSegments(int accountId, {int limit = 20}) {
    final rows = _db.select('''
      SELECT start_seq, end_seq, cursor, verified_at FROM segments
      WHERE account_id = ? AND cursor IS NOT NULL
      ORDER BY COALESCE(verified_at, 0) ASC LIMIT ?
    ''', [accountId, limit]);
    return [
      for (final r in rows)
        (
          startSeq: r['start_seq'] as int,
          endSeq: r['end_seq'] as int,
          cursor: r['cursor'] as String?,
          verifiedAt: r['verified_at'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(r['verified_at'] as int,
                  isUtc: true),
        ),
    ];
  }

  /// 某条记录的 seq。
  int? seqOf(String tweetId) {
    final rows =
        _db.select('SELECT feed_seq FROM likes WHERE tweet_id = ?', [tweetId]);
    if (rows.isEmpty) return null;
    return rows.first['feed_seq'] as int?;
  }

  /// 某区段登记的回填游标（巡边器用它重新翻到该段）。
  String? segmentCursor(int accountId, int startSeq) {
    final rows = _db.select(
      'SELECT cursor FROM segments WHERE account_id = ? AND start_seq = ?',
      [accountId, startSeq],
    );
    if (rows.isEmpty) return null;
    return rows.first['cursor'] as String?;
  }

  /// 某条记录所在的区段起点（把任意 seq 对齐到区段边界）。
  int segmentStartFor(int seq) =>
      (seq / (AppDatabase.seqStep * 200)).floor() *
      (AppDatabase.seqStep * 200);

  /// 把条目标记为「已删除」（作者删推 / 账号受保护）。
  ///
  /// 注意和 [markRemoved] 的区别：这里**仍然要显示**（卡片上标「已删除」），
  /// 「我取消了喜欢」是另一回事。
  void markDeleted(Iterable<String> tweetIds) {
    if (tweetIds.isEmpty) return;
    final stmt = _db.prepare("UPDATE likes SET state='deleted' WHERE tweet_id = ?");
    try {
      for (final id in tweetIds) {
        stmt.execute([id]);
      }
    } finally {
      stmt.dispose();
    }
  }

  /// 标记成「我取消了喜欢」：数据留着（再点一次就能恢复、缓存也不丢），
  /// 但**列表里不该再出现**（[fetchPage] 会过滤掉这个状态）。
  void markRemoved(Iterable<String> tweetIds) {
    if (tweetIds.isEmpty) return;
    final stmt = _db.prepare("UPDATE likes SET state='removed' WHERE tweet_id = ?");
    try {
      for (final id in tweetIds) {
        stmt.execute([id]);
      }
    } finally {
      stmt.dispose();
    }
  }

  /// 取消喜欢之后删掉本地记录（连同媒体行与 FTS）。
  void deleteLike(String tweetId) {
    _db.execute('DELETE FROM likes WHERE tweet_id = ?', [tweetId]);
    _db.execute('DELETE FROM media WHERE tweet_id = ?', [tweetId]);
    _db.execute('DELETE FROM likes_fts WHERE tweet_id = ?', [tweetId]);
  }

  /// 把一条从「已删除/已取消喜欢」恢复成正常状态。
  ///
  /// 取消喜欢现在是**标记**而不是物理删除（见 `SyncService.unlike`），
  /// 所以用户在播放页里再点一次就能原样恢复，不用重新下载。
  void restoreLike(String tweetId) {
    _db.execute(
      "UPDATE likes SET state = 'normal' WHERE tweet_id = ?",
      [tweetId],
    );
  }

  LikeItem? getLike(String tweetId) {
    final rows = _db.select('SELECT * FROM likes WHERE tweet_id = ?', [tweetId]);
    if (rows.isEmpty) return null;
    return _rowToItem(rows.first);
  }

  // --------------------------------------------------------------- querying

  /// 分页查询。游标语义按模式不同。
  ///
  /// 两个方向共用这一个入口：
  /// - [after]：向「后」翻（喜欢顺序里是更旧的方向）；
  /// - [before]：向「前」翻（更新的方向）。内部用相反的顺序查、再翻回来，
  ///   所以调用方拿到的永远是「正序」的一页。
  ///
  /// [includeStart] 让游标指向的那一条本身也包含进来 —— 「按位置跳转」需要从
  /// 目标条目开始显示，而不是从它的下一条开始。
  PageResult fetchPage({
    required SortMode mode,
    required LikesFilter filter,
    required int limit,
    PageKey? after,
    PageKey? before,
    bool includeStart = false,
  }) {
    assert(after == null || before == null, '一次只能往一个方向翻');
    final where = <String>[];
    final args = <Object?>[];
    _appendFilter(filter, where, args);

    final bool backwards = before != null;
    final String orderBy;
    final String reverseOrderBy;

    switch (mode) {
      case SortMode.likeOrder:
        // 约定：feed_seq 越大 = 越新。回填时从 0 往下递减分配，
        // 增量时在 max_seq 之上递增分配。所以「最新在前」= DESC。
        orderBy = 'feed_seq DESC';
        reverseOrderBy = 'feed_seq ASC';
        final seq = after?.seq ?? before?.seq;
        if (seq != null) {
          if (after != null) {
            where.add(includeStart ? 'feed_seq <= ?' : 'feed_seq < ?');
          } else {
            where.add(includeStart ? 'feed_seq >= ?' : 'feed_seq > ?');
          }
          args.add(seq);
        }
      case SortMode.publishDate:
        orderBy = 'created_at DESC, tweet_id DESC';
        reverseOrderBy = 'created_at ASC, tweet_id ASC';
        final key = after ?? before;
        if (key?.publishedAt != null) {
          final pubAt = key!.publishedAt;
          final cmp = () {
            if (after != null) return includeStart ? '<=' : '<';
            return includeStart ? '>=' : '>';
          }();
          where.add('(created_at $cmp ? OR (created_at = ? AND tweet_id $cmp ?))');
          args
            ..add(pubAt)
            ..add(pubAt)
            ..add(key.tweetId ?? '');
        }
      case SortMode.random:
        orderBy = 'rand_key ASC';
        reverseOrderBy = 'rand_key DESC';
        final randKey = after?.randKey ?? before?.randKey;
        if (randKey != null) {
          if (after != null) {
            where.add(includeStart ? 'rand_key >= ?' : 'rand_key > ?');
          } else {
            where.add(includeStart ? 'rand_key <= ?' : 'rand_key < ?');
          }
          args.add(randKey);
        }
    }

    var sql = 'SELECT * FROM likes';
    final hasWhere = where.isNotEmpty;
    if (hasWhere) sql += ' WHERE ${where.join(' AND ')}';

    final String? search = filter.search?.trim();
    if (search != null && search.isNotEmpty) {
      final clause = _searchClause(search, args);
      if (clause == null) return const PageResult([], null);
      sql += hasWhere ? ' AND $clause' : ' WHERE $clause';
    }

    sql += ' ORDER BY ${backwards ? reverseOrderBy : orderBy} LIMIT ?';
    args.add(limit + 1);

    final rows = _db.select(sql, args);
    final hasMore = rows.length > limit;
    final pageRows = hasMore ? rows.sublist(0, limit) : rows;
    // 反向查询拿到的是倒过来的，翻回去才是调用方要的正序。
    final ordered = backwards ? pageRows.reversed.toList() : pageRows;
    final items = [for (final r in ordered) _rowToItem(r)];

    PageKey? next;
    if (hasMore && ordered.isNotEmpty) {
      // 继续往同一方向翻时，从这个边缘条目接着走：
      // 向后（更旧）用最后一条，向前（更新）用第一条。
      final edge = backwards ? ordered.first : ordered.last;
      next = switch (mode) {
        SortMode.likeOrder => PageKey(seq: edge['feed_seq'] as int?),
        SortMode.publishDate => PageKey(
            publishedAt: edge['created_at'] as int?,
            tweetId: edge['tweet_id'] as String?,
          ),
        SortMode.random => PageKey(randKey: edge['rand_key'] as int?),
      };
    }
    return PageResult(items, next);
  }

  /// 当前排序 + 筛选之下第 [offset] 条（0 基）的游标，用于「跳到第 N 条」。
  ///
  /// 用 OFFSET 而不是「数一遍再跳」：五种筛选都在 SQL 里，OFFSET 会走同样的
  /// 索引路径，5 万行下也是毫秒级。
  PageKey? keyAtOffset({
    required SortMode mode,
    required LikesFilter filter,
    required int offset,
  }) {
    if (offset < 0) return null;
    final where = <String>[];
    final args = <Object?>[];
    _appendFilter(filter, where, args);

    final orderBy = switch (mode) {
      SortMode.likeOrder => 'feed_seq DESC',
      SortMode.publishDate => 'created_at DESC, tweet_id DESC',
      SortMode.random => 'rand_key ASC',
    };

    var sql = 'SELECT feed_seq, created_at, tweet_id, rand_key FROM likes';
    final hasWhere = where.isNotEmpty;
    if (hasWhere) sql += ' WHERE ${where.join(' AND ')}';

    final search = filter.search?.trim();
    if (search != null && search.isNotEmpty) {
      final clause = _searchClause(search, args);
      if (clause == null) return null;
      sql += hasWhere ? ' AND $clause' : ' WHERE $clause';
    }

    sql += ' ORDER BY $orderBy LIMIT 1 OFFSET ?';
    args.add(offset);

    final rows = _db.select(sql, args);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return switch (mode) {
      SortMode.likeOrder => PageKey(seq: r['feed_seq'] as int?),
      SortMode.publishDate => PageKey(
          publishedAt: r['created_at'] as int?,
          tweetId: r['tweet_id'] as String?,
        ),
      SortMode.random => PageKey(randKey: r['rand_key'] as int?),
    };
  }

  /// 发布日期模式下，`created_at <= date` 的第一条（也就是那天最新的那条）。
  ///
  /// 「跳转到某个日期」用它定位；喜欢顺序模式没有发布时间排序，不能走这里。
  PageKey? keyAtOrBeforeDate({
    required LikesFilter filter,
    required DateTime date,
  }) {
    final where = <String>[];
    final args = <Object?>[];
    _appendFilter(filter, where, args);
    where.add('created_at <= ?');
    args.add(date.millisecondsSinceEpoch);

    final hasWhere = where.isNotEmpty;
    var sql = 'SELECT created_at, tweet_id FROM likes';
    if (hasWhere) sql += ' WHERE ${where.join(' AND ')}';

    final search = filter.search?.trim();
    if (search != null && search.isNotEmpty) {
      final clause = _searchClause(search, args);
      if (clause == null) return null;
      sql += hasWhere ? ' AND $clause' : ' WHERE $clause';
    }

    sql += ' ORDER BY created_at DESC, tweet_id DESC LIMIT 1';
    final rows = _db.select(sql, args);
    if (rows.isEmpty) return null;
    return PageKey(
      publishedAt: rows.first['created_at'] as int?,
      tweetId: rows.first['tweet_id'] as String?,
    );
  }

  /// 喜欢顺序模式下 `created_at <= date` 最新那条的 `feed_seq`。
  ///
  /// 「喜欢顺序里跳到某个发布日期」用它：喜欢顺序与发布时间无关，所以只能
  /// 先按时间找到那一条，再落到它在喜欢顺序里的位置。
  int? seqAtOrBeforeDate({
    required LikesFilter filter,
    required DateTime date,
  }) {
    final where = <String>[];
    final args = <Object?>[];
    _appendFilter(filter, where, args);
    where.add('created_at <= ?');
    args.add(date.millisecondsSinceEpoch);

    final hasWhere = where.isNotEmpty;
    var sql = 'SELECT feed_seq FROM likes';
    if (hasWhere) sql += ' WHERE ${where.join(' AND ')}';

    final search = filter.search?.trim();
    if (search != null && search.isNotEmpty) {
      final clause = _searchClause(search, args);
      if (clause == null) return null;
      sql += hasWhere ? ' AND $clause' : ' WHERE $clause';
    }

    sql += ' ORDER BY created_at DESC, tweet_id DESC LIMIT 1';
    final rows = _db.select(sql, args);
    if (rows.isEmpty) return null;
    return rows.first['feed_seq'] as int?;
  }

  /// 把筛选条件拼进 where/args。
  ///
  /// [fetchPage] 和 [keyAtOffset] 共用同一份 —— 两边各写一遍的话，
  /// 「按位置跳」会跳到「翻页」看不到的地方去。
  void _appendFilter(
      LikesFilter filter, List<String> where, List<Object?> args) {
    // 「我取消了喜欢」的行永远不进列表（数据保留，重新喜欢能原样恢复）。
    // 作者删掉的帖子是 `deleted`，那个要显示（卡片上标「已删除」）。
    where.add("state <> 'removed'");
    if (filter.media.isNotEmpty) {
      final clauses = <String>[];
      for (final m in filter.media) {
        switch (m) {
          case MediaFilter.video:
            clauses.add('has_video = 1 AND has_gif = 0');
          case MediaFilter.gif:
            clauses.add('has_gif = 1');
          case MediaFilter.image:
            clauses.add('has_image = 1');
          case MediaFilter.text:
            clauses.add('media_json IS NULL OR media_json = \'[]\'');
        }
      }
      where.add('(${clauses.join(' OR ')})');
    }
    if (filter.authorScreenName != null) {
      where.add('author_screen_name = ?');
      args.add(filter.authorScreenName);
    }
    if (filter.authorsIn.isNotEmpty) {
      final marks = List.filled(filter.authorsIn.length, '?').join(',');
      where.add('author_screen_name IN ($marks)');
      args.addAll(filter.authorsIn);
    }
    if (filter.from != null) {
      where.add('created_at >= ?');
      args.add(filter.from!.millisecondsSinceEpoch);
    }
    if (filter.to != null) {
      where.add('created_at <= ?');
      args.add(filter.to!.millisecondsSinceEpoch);
    }
    if (filter.lang != null) {
      where.add('lang = ?');
      args.add(filter.lang);
    }
    if (filter.excludeReplies) {
      where.add('reply_to IS NULL');
    }
    if (filter.excludeRetweets) {
      where.add('retweet_of IS NULL');
    }
  }

  /// 全文搜索条件：返回可直接拼进 WHERE 的子句，参数按顺序塞进 [args]。
  /// trigram 需要 ≥3 字符；短查询退回 LIKE。
  String? _searchClause(String query, List<Object?> args) {
    final q = query.trim();
    if (q.isEmpty) return null;

    // 已经是 FTS 表达式（搜索页多关键词会拼成 `"a" AND "b"`）就原样用；
    // 再包一层引号会把它当成单个短语，多关键词就失效了。
    final isExpression =
        RegExp(r'\b(AND|OR|NOT)\b', caseSensitive: false).hasMatch(q);

    // trigram 的索引粒度是 3 个字符，**短于 3 个字符的查询它一个都命中不了** ——
    // 而中文习惯两个字的词（「天气」「猫狗」），所以这里必须真的退回 LIKE。
    // 以前注释写了这条但代码没做，结果是中文两字搜索永远空结果。
    if (ftsTokenizer == 'trigram' && !_tooShortForTrigram(q)) {
      args.add(isExpression ? q : '"${q.replaceAll('"', '')}"');
      return 'tweet_id IN (SELECT tweet_id FROM likes_fts WHERE likes_fts MATCH ?)';
    }

    // LIKE 回退：AND/OR 拆不开，退化成按第一个词匹配。
    final word = isExpression
        ? (RegExp(r'"([^"]+)"').firstMatch(q)?.group(1) ?? q)
        : q;
    final like = '%${word.replaceAll('%', r'\%')}%';
    args
      ..add(like)
      ..add(like)
      ..add(like);
    return "(text LIKE ? ESCAPE '\\' OR author_name LIKE ? ESCAPE '\\' "
        "OR author_screen_name LIKE ? ESCAPE '\\')";
  }

  /// 查询里有没有「短到 trigram 索引不到」的词（按字符数，不是 UTF-16 长度）。
  bool _tooShortForTrigram(String q) {
    final quoted = RegExp(r'"([^"]*)"')
        .allMatches(q)
        .map((m) => m.group(1) ?? '')
        .where((t) => t.trim().isNotEmpty)
        .toList(growable: false);
    final terms = quoted.isEmpty ? [q] : quoted;
    return terms.any((t) => t.trim().runes.length < 3);
  }

  List<AuthorCount> topAuthors({int limit = 200}) {
    final rows = _db.select('''
      SELECT author_screen_name sn, MAX(author_name) nm, COUNT(*) c
      FROM likes WHERE author_screen_name IS NOT NULL
      GROUP BY author_screen_name ORDER BY c DESC LIMIT ?
    ''', [limit]);
    return [
      for (final r in rows)
        AuthorCount(
          r['sn'] as String? ?? '',
          r['nm'] as String? ?? '',
          r['c'] as int,
        ),
    ];
  }

  /// 按推文发布月份分桶（模式 B 的时间轴）。
  List<MonthBucket> months() {
    final rows = _db.select('''
      SELECT strftime('%Y-%m', created_at/1000, 'unixepoch') m, COUNT(*) c,
             MIN(created_at) mn, MAX(created_at) mx
      FROM likes WHERE created_at IS NOT NULL
      GROUP BY m ORDER BY m DESC
    ''');
    return [
      for (final r in rows)
        MonthBucket(
          r['m'] as String? ?? '',
          r['c'] as int,
          r['mn'] as int? ?? 0,
          r['mx'] as int? ?? 0,
        ),
    ];
  }

  /// 某个发布月份（`YYYY-MM`）里「喜欢顺序最靠前」的一条的 seq。
  /// 时间轴跳到某个月时用它当锚点（seq 越大越新）。
  int? newestSeqInMonth(String month) {
    final rows = _db.select('''
      SELECT MAX(feed_seq) seq FROM likes
      WHERE strftime('%Y-%m', created_at/1000, 'unixepoch') = ?
    ''', [month]);
    if (rows.isEmpty) return null;
    return rows.first['seq'] as int?;
  }

  /// 全局 seq 区间（时间轴把「拖动比例」映射成 seq 用）。
  ({int? minSeq, int? maxSeq}) seqBounds() {
    final r = _db.select('SELECT MIN(feed_seq) mn, MAX(feed_seq) mx FROM likes').first;
    return (minSeq: r['mn'] as int?, maxSeq: r['mx'] as int?);
  }

  /// 模式 A 的「估算时间轴」：把喜欢顺序切成 N 段，每段给出推文发布日期的中位数。
  ///
  /// 返回顺序**与列表一致**：最新的桶在前（seq 大 → 小）。
  ///
  /// 以前这里是「每个桶两次查询」（COUNT + 取 created_at 排序），5 万条时要跑
  /// 500 条 SQL；现在改成一次全表扫描 + 内存分桶，首帧时间轴从数百毫秒降到十几毫秒。
  List<({int fromSeq, int toSeq, int count, DateTime? approxDate})>
      estimatedBuckets({int bucketSize = 200}) {
    final width = bucketSize * AppDatabase.seqStep;
    final rows = _db.select('SELECT feed_seq, created_at FROM likes');
    if (rows.isEmpty) return const [];

    final buckets = <int, ({int count, List<int> dates})>{};
    for (final r in rows) {
      final seq = r['feed_seq'] as int?;
      if (seq == null) continue;
      final start = (seq / width).floor() * width;
      final cur = buckets[start];
      final created = r['created_at'] as int?;
      if (cur == null) {
        buckets[start] = (
          count: 1,
          dates: created == null ? <int>[] : <int>[created],
        );
      } else {
        if (created != null) cur.dates.add(created);
        buckets[start] = (count: cur.count + 1, dates: cur.dates);
      }
    }

    final starts = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final start in starts)
        (
          fromSeq: start,
          toSeq: start + width,
          count: buckets[start]!.count,
          approxDate: _medianDate(buckets[start]!.dates),
        ),
    ];
  }

  DateTime? _medianDate(List<int> values) {
    if (values.isEmpty) return null;
    final sorted = List<int>.of(values)..sort();
    return DateTime.fromMillisecondsSinceEpoch(sorted[sorted.length ~/ 2],
        isUtc: true);
  }

  /// 随机重洗：给所有条目重新分配 rand_key。
  void reshuffle() {
    final rows = _db.select('SELECT tweet_id FROM likes');
    final stmt = _db.prepare('UPDATE likes SET rand_key = ? WHERE tweet_id = ?');
    _db.execute('BEGIN');
    try {
      for (final r in rows) {
        stmt.execute([randomSortKey(), r['tweet_id']]);
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      stmt.dispose();
    }
  }

  LikedStats stats() {
    final r = _db.select('''
      SELECT COUNT(*) total,
             SUM(CASE WHEN has_video=1 THEN 1 ELSE 0 END) videos,
             SUM(CASE WHEN has_image=1 THEN 1 ELSE 0 END) images,
             SUM(CASE WHEN state='deleted' THEN 1 ELSE 0 END) deleted,
             MIN(created_at) oldest, MAX(created_at) newest
      FROM likes
    ''').first;
    return LikedStats(
      total: r['total'] as int? ?? 0,
      videos: (r['videos'] as int?) ?? 0,
      images: (r['images'] as int?) ?? 0,
      deleted: (r['deleted'] as int?) ?? 0,
      oldest: r['oldest'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(r['oldest'] as int, isUtc: true),
      newest: r['newest'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(r['newest'] as int, isUtc: true),
    );
  }

  /// 供巡边器用：取某 seq 区间内的本地 tweet_id（判定哪些「消失了」）。
  Set<String> tweetIdsInSeqRange(int fromSeq, int toSeq) {
    final rows = _db.select(
      'SELECT tweet_id FROM likes WHERE feed_seq >= ? AND feed_seq < ?',
      [fromSeq, toSeq],
    );
    return {for (final r in rows) r['tweet_id'] as String};
  }

  /// 供巡边器用：取某段最新的 seq。
  int? minSeqOverall() {
    final rows = _db.select('SELECT MIN(feed_seq) mn FROM likes');
    return rows.first['mn'] as int?;
  }

  int? maxSeqOverall() {
    final rows = _db.select('SELECT MAX(feed_seq) mx FROM likes');
    return rows.first['mx'] as int?;
  }

  // ---------------------------------------------------------------- media

  /// 记录媒体已缓存到本地。
  ///
  /// [variant] 是这一档的 [PlaybackSource.key]，[rank] 是它的清晰度分值。
  /// 两个都记下来，才能回答「本地文件到底是哪一档」以及「这条媒体看过的最好档」。
  void markMediaCached(
    String tweetId,
    int idx,
    String path,
    int bytes, {
    String? variant,
    int rank = 0,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('''
      UPDATE media SET
        local_path = ?, bytes = ?, last_used_at = ?, cache_variant = ?,
        best_variant = CASE WHEN ? > COALESCE(best_rank, -1) THEN ? ELSE best_variant END,
        best_rank    = CASE WHEN ? > COALESCE(best_rank, -1) THEN ? ELSE best_rank END
      WHERE tweet_id = ? AND idx = ?
    ''', [
      path,
      bytes,
      now,
      variant,
      rank,
      variant,
      rank,
      rank,
      tweetId,
      idx,
    ]);
  }

  /// 记住「这条媒体用过这一档」。只在比已记录的更清晰时才写。
  void rememberMediaVariant(String tweetId, int idx, String variant, int rank) {
    _db.execute('''
      UPDATE media SET best_variant = ?, best_rank = ?
      WHERE tweet_id = ? AND idx = ? AND ? > COALESCE(best_rank, -1)
    ''', [variant, rank, tweetId, idx, rank]);
  }

  /// 这条媒体**播过/看过**的最好档位。
  String? mediaBestVariant(String tweetId, int idx) {
    final rows = _db.select(
      'SELECT best_variant FROM media WHERE tweet_id = ? AND idx = ?',
      [tweetId, idx],
    );
    if (rows.isEmpty) return null;
    return rows.first['best_variant'] as String?;
  }

  /// 本地缓存文件对应哪一档（null = 没有文件，或老版本缓存没记过档位）。
  String? mediaCachedVariant(String tweetId, int idx) {
    final rows = _db.select(
      'SELECT cache_variant FROM media WHERE tweet_id = ? AND idx = ?',
      [tweetId, idx],
    );
    if (rows.isEmpty) return null;
    return rows.first['cache_variant'] as String?;
  }

  /// 一次查完「本地文件 / 文件是哪档 / 看过最好哪档」——
  /// 列表里每张卡片都要问，三次 SQL 会变成滚动的卡顿来源。
  ({
    String? path,
    String? cacheVariant,
    String? bestVariant,
    int? bestRank,
  }) mediaCacheRow(String tweetId, int idx) {
    final rows = _db.select(
      'SELECT local_path, cache_variant, best_variant, best_rank FROM media '
      'WHERE tweet_id = ? AND idx = ?',
      [tweetId, idx],
    );
    if (rows.isEmpty) {
      return (path: null, cacheVariant: null, bestVariant: null, bestRank: null);
    }
    final r = rows.first;
    return (
      path: r['local_path'] as String?,
      cacheVariant: r['cache_variant'] as String?,
      bestVariant: r['best_variant'] as String?,
      bestRank: r['best_rank'] as int?,
    );
  }

  /// 丢掉「本地文件」的记录（文件坏了/不完整时用），保留画质记忆。
  void clearMediaPath(String tweetId, int idx) {
    _db.execute(
      'UPDATE media SET local_path = NULL, bytes = 0, cache_variant = NULL '
      'WHERE tweet_id = ? AND idx = ?',
      [tweetId, idx],
    );
  }

  /// 互动数据之外的杂项 KV（翻译缓存用）。
  String? kvGet(String key) => _kvGet('misc.$key');

  void kvPut(String key, String value) => _kvSet('misc.$key', value);

  // ------------------------------------------------------------ translation
  //
  // 译文落库：同一条帖子只翻一次，重启 App 也不会再请求。
  // 这不只是省流量 —— 免费翻译接口有配额，少发一次请求就少一分被限的风险。

  String? cachedTranslation(String key) => _kvGet('tr.$key');

  void saveTranslation(String key, String value) =>
      _kvSet('tr.$key', value);

  /// 已经缓存了多少条译文（设置页可以显示/清理）。
  int translationCacheCount() {
    final rows = _db.select(
        "SELECT COUNT(*) c FROM kv WHERE key LIKE 'tr.%'");
    return rows.first['c'] as int? ?? 0;
  }

  void clearTranslations() =>
      _db.execute("DELETE FROM kv WHERE key LIKE 'tr.%'");

  /// 触摸（LRU 用）。
  void touchMedia(String tweetId) {
    _db.execute('UPDATE media SET last_used_at = ? WHERE tweet_id = ?',
        [DateTime.now().millisecondsSinceEpoch, tweetId]);
  }

  /// LRU 淘汰：超过 [maxBytes] 时从最久未用的开始删，返回删掉的字节数。
  int evictMediaCache(int maxBytes) {
    var total = _db
        .select('SELECT COALESCE(SUM(bytes),0) s FROM media WHERE local_path IS NOT NULL')
        .first['s'] as int;
    if (total <= maxBytes) return 0;
    var freed = 0;
    final rows = _db.select('''
      SELECT id, local_path, bytes FROM media
      WHERE local_path IS NOT NULL ORDER BY COALESCE(last_used_at, 0) ASC
    ''');
    final stmt = _db.prepare(
        'UPDATE media SET local_path = NULL, bytes = 0, cache_variant = NULL '
        'WHERE id = ?');
    try {
      for (final r in rows) {
        if (total <= maxBytes) break;
        final path = r['local_path'] as String?;
        final bytes = r['bytes'] as int? ?? 0;
        if (path != null) {
          final f = File(path);
          if (f.existsSync()) f.deleteSync();
        }
        stmt.execute([r['id']]);
        total -= bytes;
        freed += bytes;
      }
    } finally {
      stmt.dispose();
    }
    return freed;
  }

  int mediaCacheBytes() =>
      (_db
              .select('SELECT COALESCE(SUM(bytes),0) s FROM media WHERE local_path IS NOT NULL')
              .first['s'] as int?) ??
      0;

  String? localMediaPath(String tweetId, int idx) {
    final rows = _db.select(
      'SELECT local_path FROM media WHERE tweet_id = ? AND idx = ?',
      [tweetId, idx],
    );
    if (rows.isEmpty) return null;
    return rows.first['local_path'] as String?;
  }

  // ---------------------------------------------------------------- helpers

  LikeItem _rowToItem(Row r) {
    final mediaJson = r['media_json'] as String?;
    final media = <MediaItem>[];
    if (mediaJson != null && mediaJson.isNotEmpty) {
      final list = jsonDecode(mediaJson);
      if (list is List) {
        for (final m in list) {
          if (m is Map) {
            media.add(MediaItem.fromJson(Map<String, Object?>.from(m)));
          }
        }
      }
    }
    return LikeItem(
      tweetId: r['tweet_id'] as String,
      text: r['text'] as String? ?? '',
      createdAt: r['created_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int, isUtc: true),
      lang: r['lang'] as String?,
      author: r['author_id'] == null
          ? null
          : Author(
              id: r['author_id'] as String,
              screenName: r['author_screen_name'] as String? ?? '',
              name: r['author_name'] as String? ?? '',
              avatarUrl: r['author_avatar'] as String?,
            ),
      media: media,
      sensitive: (r['sensitive'] as int? ?? 0) == 1,
      replyTo: r['reply_to'] as String?,
      quoteOf: r['quote_of'] as String?,
      retweetOf: r['retweet_of'] as String?,
      state: LikeState.values.firstWhere(
        (s) => s.name == r['state'],
        orElse: () => LikeState.normal,
      ),
      feedRank: r['feed_seq'] as int?,
      randKey: r['rand_key'] as int?,
      verifiedAt: r['verified_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(r['verified_at'] as int, isUtc: true),
      // 正文里的 #话题 / @提及 / 外链要靠 entities 里的 indices 与
      // expanded_url 才能准确渲染（尤其 t.co 短链，只有它知道真实地址）。
      // 解析失败就当没有，UI 会退回正则兜底 —— 不能因为一条脏数据让整页挂掉。
      raw: _decodeRaw(r['raw_json'] as String?),
    );
  }

  Map<String, Object?>? _decodeRaw(String? rawJson) {
    if (rawJson == null || rawJson.isEmpty) return null;
    try {
      final decoded = jsonDecode(rawJson);
      return decoded is Map ? Map<String, Object?>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }
}

class LikedStats {
  const LikedStats({
    required this.total,
    required this.videos,
    required this.images,
    required this.deleted,
    this.oldest,
    this.newest,
  });

  final int total;
  final int videos;
  final int images;
  final int deleted;
  final DateTime? oldest;
  final DateTime? newest;

  /// 还能正常显示的条数（「已删除」的那些不算）。
  int get normal => total - deleted;
}

/// 随机键（53 位安全正整数）。
///
/// 以前用「当前微秒 + 位移混合」当随机键：同一微秒内连续调用会得到**相同**的值，
/// 而洗牌时 5 万条是在一个紧循环里分配的 —— 大量重复键会让随机模式的分页
/// （`rand_key > ?`）一次性跳过成百上千条。现在改成一次性 seed 的 PRNG。
final math.Random _rand = math.Random();

int randomSortKey() =>
    (_rand.nextInt(1 << 26) * (1 << 26)) + _rand.nextInt(1 << 26) + 1;
