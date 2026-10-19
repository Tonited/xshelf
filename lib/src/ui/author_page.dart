/// 作者空间：点播放页头像进来，看这个人在你本地喜欢里都有什么。
///
/// 刻意不请求 X 的「作者主页时间线」：那需要另一套 GraphQL + 分页游标，而这里
/// 真正想回答的问题是「我从这个人身上喜欢过什么」。数据全在本地，离线也能看。
/// 想看他完整主页就点「在 X 打开」。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../core/l10n.dart';
import '../db/app_database.dart';
import '../media/media_cache.dart';
import '../model/like_item.dart';
import '../state/query_feed_source.dart';
import 'feed_page.dart';
import 'media_image.dart';
import 'post_card.dart';

class AuthorPage extends StatefulWidget {
  const AuthorPage({super.key, required this.author, this.cache});

  final Author author;
  final MediaCache? cache;

  @override
  State<AuthorPage> createState() => _AuthorPageState();
}

class _AuthorPageState extends State<AuthorPage> {
  late final QueryFeedSource _source;
  final ScrollController _scroll = ScrollController();
  bool _following = false;
  bool _busy = false;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    _source = QueryFeedSource(
      db: app.db,
      filter: LikesFilter(authorScreenName: widget.author.screenName),
    );
    _following = app.db.isFollowing(widget.author.id);
    _total = app.db.countByAuthor(widget.author.screenName);
    _scroll.addListener(_onScroll);
    _source.loadMore();
    // 本地记录只反映「在我们这个 App 里点过的关注」；用户在 X 客户端里
    // 关注的人我们并不知道，所以进来时向 X 核对一次，拿到就以远端为准。
    unawaited(_syncFollowState(app));
  }

  Future<void> _syncFollowState(AppController app) async {
    final remote = await app.isFollowingRemote(widget.author.screenName);
    if (remote == null || !mounted) return;
    if (remote == _following) return;
    setState(() => _following = remote);
    if (widget.author.id.isNotEmpty) {
      app.db.setFollowing(widget.author.id, remote);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _source.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) _source.loadMore();
  }

  Future<void> _toggleFollow() async {
    if (_busy || widget.author.id.isEmpty) return;
    setState(() => _busy = true);
    final err = await AppScope.read(context)
        .setFollowing(widget.author.id, !_following);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (err == null) _following = !_following;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          err ?? (_following ? t('play.followed') : t('play.unfollowed')),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final author = widget.author;
    final isSelf =
        author.screenName == AppScope.read(context).session?.screenName;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          author.name.isNotEmpty ? author.name : '@${author.screenName}',
        ),
      ),
      body: ListenableBuilder(
        listenable: _source,
        builder: (context, _) {
          final items = _source.items;
          return CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          author.avatarUrl == null
                              ? const CircleAvatar(
                                  radius: 30,
                                  child: Icon(Icons.person, size: 30),
                                )
                              : AuthorAvatar(
                                  url: author.avatarUrl!,
                                  radius: 30,
                                ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  author.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium,
                                ),
                                Text(
                                  '@${author.screenName}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '${t('author.likes')} · $_total',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          if (!isSelf && author.id.isNotEmpty)
                            FilledButton.tonalIcon(
                              onPressed: _busy ? null : _toggleFollow,
                              icon: _busy
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      _following
                                          ? Icons.person_remove_alt_1
                                          : Icons.person_add_alt_1,
                                      size: 18,
                                    ),
                              label: Text(
                                _following
                                    ? t('author.following')
                                    : t('author.follow'),
                              ),
                            ),
                          const SizedBox(width: 10),
                          OutlinedButton.icon(
                            onPressed: () => launchUrl(
                              Uri.parse('https://x.com/${author.screenName}'),
                              mode: LaunchMode.externalApplication,
                            ),
                            icon: const Icon(Icons.open_in_new, size: 18),
                            label: Text(t('author.openX')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: Divider(height: 1)),
              if (items.isEmpty && _source.loading)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                )
              else if (items.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(child: Text(t('author.empty'))),
                  ),
                )
              else
                SliverList.builder(
                  itemCount: items.length + (_source.hasMore ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= items.length) {
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final item = items[i];
                    return Column(
                      children: [
                        PostCard(
                          item: item,
                          cache: widget.cache,
                          onTap: () => Navigator.of(context).push(
                            // 播放页会带着「最后看的那条」pop 回来（<String>），
                            // 这里不接结果，但路由泛型要一致，否则 pop 会类型不匹配。
                            MaterialPageRoute<String>(
                              builder: (_) => FeedPage(
                                source: _source,
                                initialIndex: i,
                                cache: widget.cache,
                              ),
                            ),
                          ),
                        ),
                        const Divider(height: 1, thickness: 0.4),
                      ],
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}
