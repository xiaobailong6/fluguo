import 'dart:async';

import 'package:flutter/material.dart';

import '../../live_bilibili.dart';
import '../../local_store.dart';
import '../widgets/glass/glass_surface.dart';
import '../widgets/status_view.dart';
import 'live_favorite_button.dart';
import 'live_navigation.dart';

class LiveFavoritesPage extends StatelessWidget {
  const LiveFavoritesPage({super.key, required this.store});
  final LocalStore store;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('直播收藏')),
    body: ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final entries = store.liveFavorites;
        if (entries.isEmpty)
          return const StatusView(
            title: '还没有收藏主播',
            message: '在直播播放页点击收藏按钮，主播会出现在这里',
            icon: Icons.bookmark_border_rounded,
          );
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          primary: false,
          itemCount: entries.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final entry = entries[index];
            final platform = livePlatformById(entry.platformId);
            final room = entry.room;
            return GlassSurface(
              blur: false,
              showShadow: false,
              child: ListTile(
                leading: SizedBox(
                  width: 64,
                  height: 48,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: room.cover.isEmpty
                        ? const Icon(Icons.live_tv_rounded)
                        : Image.network(
                            room.cover,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.live_tv_rounded),
                          ),
                  ),
                ),
                title: Text(
                  room.anchor.isEmpty ? room.title : room.anchor,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${platform?.name ?? entry.platformId} · ${room.title}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: LiveFavoriteButton(
                  store: store,
                  platformId: entry.platformId,
                  room: room,
                ),
                onTap: platform == null
                    ? () => ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('这个直播平台当前不可用，收藏已保留')),
                      )
                    : () => unawaited(
                        openLivePlayer(context, store, platform, room),
                      ),
              ),
            );
          },
        );
      },
    ),
  );
}
