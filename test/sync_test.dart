import 'dart:convert';
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/open.dart';
import 'package:xlikemanage/src/db/app_database.dart';
import 'package:xlikemanage/src/sync/reconciler.dart';
import 'package:xlikemanage/src/sync/sync_service.dart';
import 'package:xlikemanage/src/sync/x_client.dart';

/// 用 MockClient 把 X 的响应喂进来，验证「翻页 → 落库 → 续传 → 核对」这条链路。
void main() {
  var sqliteReady = true;

  setUpAll(() {
    try {
      open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open('winsqlite3.dll'),
      );
      AppDatabase.open(':memory:').dispose();
    } catch (_) {
      sqliteReady = false;
    }
  });

  Map<String, Object?> tweet(
    String id, {
    String text = 'hello',
    String createdAt = 'Mon Jan 04 00:00:00 +0000 2021',
    String author = 'alice',
  }) =>
      {
        'rest_id': id,
        '__typename': 'Tweet',
        'core': {
          'user_results': {
            'result': {
              'rest_id': 'u_$author',
              'core': {'screen_name': author, 'name': author},
            }
          }
        },
        'legacy': {'full_text': text, 'created_at': createdAt, 'lang': 'en'},
      };

  Map<String, Object?> likesPage(
    List<Map<String, Object?>> items, {
    String? bottom,
  }) =>
      {
        'data': {
          'user': {
            'result': {
              'timeline_v2': {
                'timeline': {
                  'instructions': [
                    {
                      'type': 'TimelineAddEntries',
                      'entries': [
                        for (final it in items)
                          {
                            'entryId': 'tweet-${it['rest_id']}',
                            'content': {
                              'entryType': 'TimelineTimelineItem',
                              'itemContent': {
                                'itemType': 'TimelineTweet',
                                'tweet_results': {'result': it},
                              },
                            },
                          },
                        if (bottom != null)
                          {
                            'entryId': 'cursor-bottom-1',
                            'content': {
                              'entryType': 'TimelineTimelineCursor',
                              'cursorType': 'Bottom',
                              'value': bottom,
                            },
                          },
                      ],
                    }
                  ],
                },
              },
            },
          },
        },
      };

  /// cursor -> 一项「这一页返回什么」的映射。
  XClient clientWithPages(
    Map<String?, ({List<Map<String, Object?>> items, String? next})> pages, {
    bool Function(String path)? unlikeOk,
  }) {
    final httpClient = MockClient((request) async {
      final path = request.url.path;
      if (path.contains('UnfavoriteTweet')) {
        final ok = unlikeOk?.call(path) ?? true;
        if (!ok) {
          return http.Response(jsonEncode({'errors': [{'message': 'nope'}]}), 200);
        }
        return http.Response(jsonEncode({'data': {'favorite_tweet': 'Done'}}), 200);
      }
      final vars = request.url.queryParameters['variables'];
      final cursor = vars == null
          ? null
          : (jsonDecode(vars) as Map)['cursor'] as String?;
      final page = pages[cursor];
      if (page == null) {
        return http.Response(jsonEncode({'errors': [{'message': 'no page'}]}), 200);
      }
      return http.Response(
        jsonEncode(likesPage(page.items, bottom: page.next)),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    return XClient(
      session: const XSession(authToken: 'a', ct0: 'c', userId: '42'),
      httpClient: httpClient,
      presetQueryIds: const {'Likes': 'q1', 'UnfavoriteTweet': 'q2'},
    );
  }

  group('backfill', () {
    test('walks pages, assigns descending seq, records cursors', () async {
      if (!sqliteReady) return;
      final db = AppDatabase.open(':memory:');
      addTearDown(db.dispose);

      final client = clientWithPages({
        null: (
          items: [tweet('t0'), tweet('t1')],
          next: 'c1',
        ),
        'c1': (
          items: [tweet('t2')],
          next: null,
        ),
      });
      final svc = SyncService(
        db: db,
        client: client,
        pace: Duration.zero,
      );

      final report = await svc.backfill(accountId: 1);
      expect(report.fetched, 3);
      expect(report.inserted, 3);

      expect(db.getLike('t0')!.feedRank, 0);
      expect(db.getLike('t1')!.feedRank, -AppDatabase.seqStep);
      expect(db.getLike('t2')!.feedRank, -AppDatabase.seqStep * 2);

      // 列表顺序：最新在前
      final page = db.fetchPage(
        mode: SortMode.likeOrder,
        filter: const LikesFilter(),
        limit: 10,
      );
      expect(page.items.map((i) => i.tweetId), ['t0', 't1', 't2']);

      final state = db.loadSyncState(1);
      expect(state.backfillDone, isTrue);
      // 到底了也**不清空**游标：下次点「继续回填」从最后一页重试一次就能确认，
      // 而万一这次是误判（X 收紧过深度限制），还能从断点接着往下抓。
      expect(state.backfillCursor, 'c1');
      expect(state.minSeq, -AppDatabase.seqStep * 2);
      expect(state.maxSeq, 0);
    });

    test('resumes from the saved cursor after being cut off', () async {
      if (!sqliteReady) return;
      final db = AppDatabase.open(':memory:');
      addTearDown(db.dispose);

      final client = clientWithPages({
        null: (
          items: [tweet('t0'), tweet('t1')],
          next: 'c1',
        ),
        'c1': (
          items: [tweet('t2')],
          next: null,
        ),
      });
      final svc = SyncService(db: db, client: client, pace: Duration.zero);

      // 第一轮只允许抓一条
      await svc.backfill(accountId: 1, maxItems: 1);
      expect(db.countLikes(), 2); // 整页都会被写入
      expect(db.loadSyncState(1).backfillCursor, 'c1');
      expect(db.loadSyncState(1).backfillDone, isFalse);

      // 第二轮从 c1 继续
      await svc.backfill(accountId: 1);
      expect(db.getLike('t2'), isNotNull);
      expect(db.getLike('t2')!.feedRank, -AppDatabase.seqStep * 2);
    });
  });

  group('syncNew', () {
    test('stacks new likes above the existing newest', () async {
      if (!sqliteReady) return;
      final db = AppDatabase.open(':memory:');
      addTearDown(db.dispose);

      // 已有：old（seq 0）
      final initial = clientWithPages({
        null: (
          items: [tweet('old')],
          next: null,
        ),
      });
      await SyncService(db: db, client: initial, pace: Duration.zero)
          .backfill(accountId: 1);

      // 新增两条，翻到 old 就停
      final client = clientWithPages({
        null: (
          items: [tweet('n0'), tweet('n1'), tweet('old')],
          next: null,
        ),
      });
      final report = await SyncService(db: db, client: client, pace: Duration.zero)
          .syncNew(accountId: 1);

      expect(report.inserted, 2);
      final page = db.fetchPage(
        mode: SortMode.likeOrder,
        filter: const LikesFilter(),
        limit: 10,
      );
      expect(page.items.map((i) => i.tweetId), ['n0', 'n1', 'old']);
      expect(db.getLike('n0')!.feedRank! > db.getLike('old')!.feedRank!, isTrue);
      expect(db.loadSyncState(1).maxSeq, db.getLike('n0')!.feedRank);
    });
  });

  group('unlike', () {
    test('取消喜欢后列表里查不到，但数据还在（能点回喜欢）', () async {
      if (!sqliteReady) return;
      final db = AppDatabase.open(':memory:');
      addTearDown(db.dispose);

      final client = clientWithPages({
        null: (
          items: [tweet('a')],
          next: null,
        ),
      });
      final svc = SyncService(db: db, client: client, pace: Duration.zero);
      await svc.backfill(accountId: 1);
      expect(db.getLike('a'), isNotNull);

      await svc.unlike('a');
      // 整行还在（重新喜欢能原样恢复、缓存也不丢）……
      expect(db.getLike('a'), isNotNull);
      // ……但任何列表查询都不再返回它（state = removed 被过滤掉）。
      final page = db.fetchPage(
        mode: SortMode.likeOrder,
        filter: const LikesFilter(),
        limit: 10,
      );
      expect(page.items.map((i) => i.tweetId), isNot(contains('a')));
    });
  });

  group('rate limiting', () {
    test('waits and retries once when X answers 429', () async {
      if (!sqliteReady) return;
      final db = AppDatabase.open(':memory:');
      addTearDown(db.dispose);

      var calls = 0;
      final httpClient = MockClient((request) async {
        calls++;
        if (calls == 1) {
          final reset = DateTime.now().add(const Duration(seconds: 30));
          return http.Response('', 429, headers: {
            'x-rate-limit-reset':
                '${reset.millisecondsSinceEpoch ~/ 1000}',
          });
        }
        return http.Response(
          jsonEncode(likesPage([tweet('after-retry')])),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = XClient(
        session: const XSession(authToken: 'a', ct0: 'c', userId: '42'),
        httpClient: httpClient,
        presetQueryIds: const {'Likes': 'q1'},
      );

      final notices = <String>[];
      final svc = SyncService(
        db: db,
        client: client,
        pace: Duration.zero,
        retryDelay: Duration.zero,
      );
      await svc.backfill(
        accountId: 1,
        onProgress: (p) {
          if (p.message != null) notices.add(p.message!);
        },
      );

      expect(calls, 2, reason: '第一次 429，第二次成功');
      expect(db.getLike('after-retry'), isNotNull);
      expect(notices.any((n) => n.contains('限流')), isTrue);
    });

    test('gives up after repeated 429s', () async {
      if (!sqliteReady) return;
      final db = AppDatabase.open(':memory:');
      addTearDown(db.dispose);

      var calls = 0;
      final httpClient = MockClient((request) async {
        calls++;
        return http.Response('', 429, headers: {
          'x-rate-limit-reset': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
        });
      });
      final client = XClient(
        session: const XSession(authToken: 'a', ct0: 'c', userId: '42'),
        httpClient: httpClient,
        presetQueryIds: const {'Likes': 'q1'},
      );
      final svc = SyncService(
        db: db,
        client: client,
        pace: Duration.zero,
        retryDelay: Duration.zero,
      );

      final report = await svc.backfill(accountId: 1);
      // 限流用尽只算「本轮暂停」：游标已落库，下次点继续就从这里接着抓。
      // 以前这里 rethrow，用户只看到一个红色错误，以为同步坏了。
      expect(report.done, isFalse);
      expect(report.pages, 0);
      expect(calls, 3, reason: '1 次原始请求 + 2 次重试');
    });
  });

  group('reconciler', () {
    test('drops the like that disappeared and inserts the one it missed',
        () async {
      if (!sqliteReady) return;
      final db = AppDatabase.open(':memory:');
      addTearDown(db.dispose);

      final client = clientWithPages({
        null: (
          items: [
            tweet('a'),
            tweet('b'),
            tweet('c'),
            tweet('d'),
          ],
          next: null,
        ),
      });
      await SyncService(db: db, client: client, pace: Duration.zero)
          .backfill(accountId: 1);
      expect(db.countLikes(), 4);

      // 登记一个覆盖全部数据的区段（seq ∈ [-2e8, 0)）
      const segStart = -AppDatabase.seqStep * 200;
      db.upsertSegment(
        accountId: 1,
        startSeq: segStart,
        endSeq: 0,
        cursor: 'seg-cursor',
      );

      // 服务端：a 还在，b 没了（被取消），x 是新漏抓的，c/d 还在
      final refreshed = clientWithPages({
        'seg-cursor': (
          items: [tweet('a'), tweet('x'), tweet('c'), tweet('d')],
          next: null,
        ),
      });
      final reconciler = Reconciler(
        db: db,
        client: refreshed,
        accountId: 1,
        minInterval: Duration.zero,
        maxPerMinute: 100,
      );

      final report = await reconciler.tick();
      expect(report, isNotNull);
      expect(report!.removed, 1, reason: 'b 应被删除');
      expect(report.inserted, 1, reason: 'x 应被插回');

      expect(db.getLike('b'), isNull);
      final order = db
          .fetchPage(
            mode: SortMode.likeOrder,
            filter: const LikesFilter(),
            limit: 20,
          )
          .items
          .map((i) => i.tweetId)
          .toList();
      expect(order, ['a', 'x', 'c', 'd']);
    });

    test('does nothing when the page does not match anything locally',
        () async {
      if (!sqliteReady) return;
      final db = AppDatabase.open(':memory:');
      addTearDown(db.dispose);

      final client = clientWithPages({
        null: (
          items: [tweet('a'), tweet('b')],
          next: null,
        ),
      });
      await SyncService(db: db, client: client, pace: Duration.zero)
          .backfill(accountId: 1);

      const segStart = -AppDatabase.seqStep * 200;
      db.upsertSegment(
        accountId: 1,
        startSeq: segStart,
        endSeq: 0,
        cursor: 'drifted',
      );

      final drifted = clientWithPages({
        'drifted': (
          items: [tweet('zzz'), tweet('yyy')],
          next: null,
        ),
      });
      final reconciler = Reconciler(
        db: db,
        client: drifted,
        accountId: 1,
        minInterval: Duration.zero,
        maxPerMinute: 100,
      );

      final report = await reconciler.tick();
      expect(report, isNotNull);
      expect(report!.removed, 0);
      expect(report.inserted, 0);
      // 保守：对不上就什么都不动，已有数据必须完好
      expect(db.countLikes(), 2);
    });
  });
}
