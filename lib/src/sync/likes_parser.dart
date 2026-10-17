/// 把 X `Likes` 接口的响应解析成领域模型。
///
/// 响应结构见 `docs/GRAPHQL.md`。这里刻意不抛异常吞掉一切：
/// 结构对不上时抛 [LikesParseException]，让上层能区分「接口变了」和「没有更多数据」。
library;

import '../model/like_item.dart';
import 'twitter_date.dart';

class LikesParseException implements Exception {
  LikesParseException(this.message);
  final String message;
  @override
  String toString() => 'LikesParseException: $message';
}

class LikesPage {
  LikesPage({
    required this.items,
    this.topCursor,
    this.bottomCursor,
    this.deletedTweetIds = const [],
    this.entryCount = 0,
  });

  final List<LikeItem> items;
  final String? topCursor;
  final String? bottomCursor;

  /// 已删除（tombstone）的推文 id：本地应保留记录但标记为 deleted。
  final List<String> deletedTweetIds;
  final int entryCount;

  bool get hasMore => bottomCursor != null && bottomCursor!.isNotEmpty;
}

/// X 在 `errors` 里返回的错误信息，供上层展示。
List<String> graphqlErrors(Object? json) {
  if (json is! Map) return const [];
  final errors = json['errors'];
  if (errors is! List) return const [];
  return [
    for (final e in errors)
      if (e is Map) (e['message']?.toString() ?? e.toString()),
  ];
}

LikesPage parseLikesPage(Object? json) {
  if (json is! Map) throw LikesParseException('响应不是 JSON 对象');

  final errors = graphqlErrors(json);
  if (errors.isNotEmpty && json['data'] == null) {
    throw LikesParseException(errors.join('; '));
  }

  final data = json['data'];
  if (data is! Map) throw LikesParseException('响应缺少 data 字段');

  final user = _dig(data, ['user', 'result']);
  if (user is! Map) throw LikesParseException('响应缺少 data.user.result');

  final instructions = _timelineInstructions(user);
  if (instructions == null) {
    throw LikesParseException('响应缺少 timeline.instructions（接口可能已变更）');
  }

  final items = <LikeItem>[];
  final deleted = <String>[];
  String? topCursor;
  String? bottomCursor;
  var entryCount = 0;

  for (final ins in instructions) {
    if (ins is! Map) continue;
    final type = ins['type'];
    if (type == 'TimelineTerminateTimeline') {
      // 没有更多了：把 bottomCursor 置空。
      bottomCursor = null;
      continue;
    }
    final entries = ins['entries'];
    if (entries is! List) continue;

    for (final entry in entries) {
      if (entry is! Map) continue;
      entryCount++;
      final entryId = entry['entryId'] as String? ?? '';
      final content = entry['content'];
      if (content is! Map) continue;

      switch (content['entryType']) {
        case 'TimelineTimelineCursor':
          final value = content['value'] as String?;
          if (value == null || value.isEmpty) break;
          final direction = content['cursorType'] as String? ??
              (entryId.startsWith('cursor-top') ? 'Top' : 'Bottom');
          if (direction == 'Top') {
            topCursor ??= value;
          } else {
            bottomCursor = value;
          }
        case 'TimelineTimelineItem':
          final itemContent = content['itemContent'];
          if (itemContent is! Map) break;
          final result = _dig(itemContent, ['tweet_results', 'result']);
          if (result is! Map) break;

          final typename = result['__typename'] as String?;
          if (typename == 'TweetTombstone') {
            final id = _tweetIdFromEntryId(entryId);
            if (id != null) deleted.add(id);
            break;
          }

          final tweet = typename == 'TweetWithVisibilityResults'
              ? (result['tweet'] as Map?)
              : result;
          if (tweet == null) break;

          final item = _parseTweet(tweet, entryId);
          if (item != null) items.add(item);
        default:
          // TimelineTimelineModule / TimelineReplaceEntry 等：忽略。
          break;
      }
    }
  }

  return LikesPage(
    items: items,
    topCursor: topCursor,
    bottomCursor: bottomCursor,
    deletedTweetIds: deleted,
    entryCount: entryCount,
  );
}

Object? _timelineInstructions(Map user) {
  final result = user['result'];
  if (result is! Map) return null;
  return _dig(result, ['timeline_v2', 'timeline', 'instructions']) ??
      _dig(result, ['timeline', 'instructions']);
}

LikeItem? _parseTweet(Map tweet, String entryId) {
  final tweetId = (tweet['rest_id'] as String?) ?? _tweetIdFromEntryId(entryId);
  if (tweetId == null || tweetId.isEmpty) return null;

  final legacy = tweet['legacy'];
  final legacyMap = legacy is Map ? legacy : const {};

  var text = '';
  final noteText = _dig(tweet, [
    'note_tweet',
    'note_tweet_results',
    'result',
    'text',
  ]);
  if (noteText is String && noteText.isNotEmpty) {
    text = noteText;
  } else {
    text = legacyMap['full_text'] as String? ?? '';
  }

  return LikeItem(
    tweetId: tweetId,
    text: text,
    createdAt: parseTwitterDate(legacyMap['created_at'] as String?),
    lang: legacyMap['lang'] as String?,
    author: _parseAuthor(tweet),
    media: _parseMedia(legacyMap),
    sensitive: legacyMap['possibly_sensitive'] == true,
    replyTo: legacyMap['in_reply_to_status_id_str'] as String?,
    quoteOf: _dig(legacyMap, ['quoted_status_result', 'result', 'rest_id'])
        as String?,
    retweetOf:
        _dig(legacyMap, ['retweeted_status_result', 'result', 'rest_id'])
            as String?,
    raw: Map<String, Object?>.from(tweet),
  );
}

Author? _parseAuthor(Map tweet) {
  final user = _dig(tweet, ['core', 'user_results', 'result']);
  if (user is! Map) return null;
  final userLegacy = user['legacy'] is Map ? user['legacy'] as Map : const {};
  final id = user['rest_id'] as String? ?? '';
  if (id.isEmpty) return null;
  final screenName = _dig(user, ['core', 'screen_name']) as String? ??
      userLegacy['screen_name'] as String? ??
      '';
  final name = _dig(user, ['core', 'name']) as String? ??
      userLegacy['name'] as String? ??
      '';
  var avatar = _dig(user, ['avatar', 'image_url']) as String? ??
      userLegacy['profile_image_url_https'] as String?;
  if (avatar != null) avatar = avatar.replaceAll('_normal', '_bigger');
  return Author(
    id: id,
    screenName: screenName,
    name: name,
    avatarUrl: avatar,
  );
}

List<MediaItem> _parseMedia(Map legacy) {
  final rawMedia = _dig(legacy, ['extended_entities', 'media']) ??
      _dig(legacy, ['entities', 'media']);
  if (rawMedia is! List) return const [];

  final out = <MediaItem>[];
  for (final raw in rawMedia) {
    if (raw is! Map) continue;
    final type = raw['type'] as String? ?? 'photo';
    final url = raw['media_url_https'] as String?;
    if (url == null) continue;
    final info = raw['original_info'] is Map ? raw['original_info'] as Map : const {};
    final alt = raw['ext_alt_text'] as String?;

    if (type == 'photo') {
      out.add(MediaItem(
        kind: MediaKind.image,
        url: _imageVariant(url, 'large'),
        width: (info['width'] as num?)?.toInt(),
        height: (info['height'] as num?)?.toInt(),
        altText: alt,
      ));
      continue;
    }

    final videoInfo = raw['video_info'] is Map ? raw['video_info'] as Map : const {};
    final variants = <MediaVariant>[];
    final rawVariants = videoInfo['variants'];
    if (rawVariants is List) {
      for (final v in rawVariants) {
        if (v is! Map) continue;
        final vUrl = v['url'] as String?;
        if (vUrl == null || vUrl.isEmpty) continue;
        variants.add(MediaVariant(
          url: vUrl,
          contentType: v['content_type'] as String? ?? '',
          bitRate: (v['bit_rate'] as num?)?.toInt(),
        ));
      }
    }

    out.add(MediaItem(
      kind: type == 'animated_gif' ? MediaKind.gif : MediaKind.video,
      url: _imageVariant(url, 'large'),
      variants: variants,
      width: (info['width'] as num?)?.toInt(),
      height: (info['height'] as num?)?.toInt(),
      durationMs: (videoInfo['duration_millis'] as num?)?.toInt(),
      altText: alt,
    ));
  }
  return out;
}

String _imageVariant(String base, String name) {
  final clean = base.split('?').first;
  return '$clean?name=$name';
}

String? _tweetIdFromEntryId(String entryId) {
  if (entryId.startsWith('tweet-')) return entryId.substring(6);
  final m = RegExp(r'(\d{10,})').firstMatch(entryId);
  return m?.group(1);
}

Object? _dig(Object? root, List<String> path) {
  Object? cur = root;
  for (final key in path) {
    if (cur is Map) {
      cur = cur[key];
    } else {
      return null;
    }
  }
  return cur;
}
