import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'live_models.dart';

/// guoapp 的秀果面板中只登记验证为有效的常规分类。
/// 电视分类实际返回统一拦截 MP4，其他未验证分类不进入选择列表。
class GuoappLive extends LivePlatform {
  const GuoappLive();
  @override
  String get id => 'xiuguo';
  @override
  String get name => '秀果';
  static const _endpoints = [
    'http://api.hclyz.com:81/mf',
    'http://api.vipmisss.com:81/xcdsw',
  ];

  Future<List<({LiveRoom room, String url})>> _channels() async {
    Object? lastError;
    for (final endpoint in _endpoints) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final request = await client.getUrl(
          Uri.parse('$endpoint/jsonyingke.txt'),
        );
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        if (response.statusCode != 200)
          throw StateError('直播面板 HTTP ${response.statusCode}');
        final text = await response
            .timeout(const Duration(seconds: 15))
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 20));
        if (text.length > 2 * 1024 * 1024) throw StateError('直播面板数据过大');
        final dynamic decoded = jsonDecode(text);
        final dynamic rows = decoded is Map
            ? decoded['zhubo'] ?? decoded['list'] ?? decoded['data']
            : decoded;
        if (rows is! List) throw StateError('直播面板没有返回频道列表');
        final channels = <({LiveRoom room, String url})>[];
        final ids = <String>{};
        for (final raw in rows) {
          if (raw is! Map) continue;
          var title = '${raw['title'] ?? ''}'.trim();
          try {
            title = Uri.decodeComponent(title);
          } catch (_) {}
          final url = '${raw['address'] ?? ''}'.trim();
          final uri = Uri.tryParse(url);
          if (title.isEmpty ||
              uri == null ||
              !uri.hasAuthority ||
              !['https', 'http'].contains(uri.scheme) ||
              !uri.path.contains('.flv'))
            continue;
          final key = md5.convert(utf8.encode(title)).toString();
          if (!ids.add(key)) continue;
          final cover = '${raw['img'] ?? ''}';
          channels.add((
            room: LiveRoom(
              roomId: key,
              title: title,
              anchor: title,
              cover: cover.startsWith('//') ? 'https:$cover' : cover,
              area: '映客',
              online: '',
            ),
            url: url,
          ));
        }
        if (channels.isEmpty) throw StateError('直播面板暂无有效频道');
        return channels;
      } catch (error) {
        lastError = error;
      } finally {
        client.close(force: true);
      }
    }
    throw StateError('秀果映客分类暂时不可用，请稍后重试（${lastError.runtimeType}）');
  }

  @override
  Future<List<LiveCategory>> categories() async {
    await _channels();
    return const [
      LiveCategory(
        name: '常规直播',
        parentId: 'yingke',
        children: [
          LiveCategory(name: '映客', parentId: 'yingke', areaId: 'online'),
        ],
      ),
    ];
  }

  @override
  Future<List<LiveRoom>> rooms(LiveCategory category, {int page = 1}) async {
    if (category.parentId != 'yingke' || category.areaId != 'online') {
      throw StateError('当前分类没有通过有效性验证');
    }
    if (page > 1) return const [];
    return (await _channels()).map((entry) => entry.room).toList();
  }

  @override
  Future<List<LiveRoom>> search(String keyword, {int page = 1}) async {
    if (page > 1) return const [];
    final query = keyword.trim().toLowerCase();
    return (await _channels())
        .map((entry) => entry.room)
        .where((room) => room.title.toLowerCase().contains(query))
        .toList();
  }

  @override
  Future<LiveStream> resolve(LiveRoom room, {int quality = 0}) async {
    final current = (await _channels())
        .where((entry) => entry.room.roomId == room.roomId)
        .firstOrNull;
    if (current == null) throw StateError('这个主播当前未开播，收藏已保留');
    return LiveStream(
      url: current.url,
      quality: '平台默认',
      headers: const {},
      qualities: const [],
      renewAfter: const Duration(minutes: 2),
    );
  }
}
