/// 作者空间：这个人在本地被喜欢过、被加入书签过的全部内容，分两个 Tab。
///
/// 两个 Tab 各自是一个独立的 [QueryFeedSource]，条件只差 `kinds`（喜欢 / 书签），
/// 所以分页、加载更多、空态都复用同一套实现。
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

class _AuthorPageState extends State<AuthorPage>
    with SingleTickerProviderStateMixin {
  late final QueryFeedSource _likes;
  late final QueryFeedSource _bookmarks;
  late final TabController _tabs;
  bool _following = false;
  bool _busy = false;
  int _likeCount = 0;
  int _bookmarkCount = 0;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    final who = widget.author.screenName;
    _likes = QueryFeedSource(
      db: app.db,
      filter: LikesFilter(authorScreenName: who, kinds: const {'like'}),
    );
    _bookmarks = QueryFeedSource(
      db: app.db,
      filter: LikesFilter(authorScreenName: who, kinds: const {'bookmark'}),
    );
    _likeCount = app.db.countByAuthor(who, kinds: const {'like'});
    _bookmarkCount = app.db.countByAuthor(who, kinds: const {'bookmark'});
    _tabs = TabController(length: 2, vsync: this);
    _following = app.db.isFollowing(widget.author.id);
    unawaited(_likes.loadMore());
    unawaited(_bookmarks.loadMore());
    // 本地记录只反映「在我们这个 App 里点过的关注」；用户在 X 客户端里关注的人
    // 我们并不知道，所以进来时向 X 核对一次，拿到就以远端为准。
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
    _tabs.dispose();
    _likes.dispose();
    _bookmarks.dispose();
    super.dispose();
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
      body: Column(
        children: [
          // 资料卡在上面，两个 Tab 紧跟在它下面（放在 AppBar 里会跟资料卡分开，
          // 看起来像是「页面的 Tab」而不是「这个人的内容分类」）。
          _profileHeader(context, theme, author, isSelf),
          TabBar(
            controller: _tabs,
            tabs: [
              Tab(text: '${t('author.likes')} $_likeCount'),
              Tab(text: '${t('author.bookmarks')} $_bookmarkCount'),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _AuthorList(source: _likes, cache: widget.cache),
                _AuthorList(source: _bookmarks, cache: widget.cache),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _profileHeader(
    BuildContext context,
    ThemeData theme,
    Author author,
    bool isSelf,
  ) {
    return Padding(
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
                  : AuthorAvatar(url: author.avatarUrl!, radius: 30),
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
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _following
                              ? Icons.person_remove_alt_1
                              : Icons.person_add_alt_1,
                          size: 18,
                        ),
                  label: Text(
                    _following ? t('author.following') : t('author.follow'),
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
    );
  }
}

/// 一个 Tab 里的列表（喜欢或书签）。
class _AuthorList extends StatefulWidget {
  const _AuthorList({required this.source, this.cache});

  final QueryFeedSource source;
  final MediaCache? cache;

  @override
  State<_AuthorList> createState() => _AuthorListState();
}

class _AuthorListState extends State<_AuthorList>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scroll = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) widget.source.loadMore();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: widget.source,
      builder: (context, _) {
        final items = widget.source.items;
        if (items.isEmpty && widget.source.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (items.isEmpty) {
          return Center(child: Text(t('author.empty')));
        }
        return ListView.builder(
          controller: _scroll,
          itemCount: items.length + (widget.source.hasMore ? 1 : 0),
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
                        source: widget.source,
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
        );
      },
    );
  }
}
