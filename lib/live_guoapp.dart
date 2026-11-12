import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'live_http.dart';
import 'live_models.dart';

typedef GuoappRequest = Future<String> Function(Uri uri, Duration timeout);
typedef _Channel = ({LiveRoom room, String url});
typedef _Group = ({LiveCategory category, Uri uri, List<_Channel> channels});

/// 分类来自服务索引，只有房间列表中有直播 FLV 的分类才进入面板。
class GuoappLive extends LivePlatform {
  const GuoappLive({GuoappRequest? request}) : _request = request;
  final GuoappRequest? _request;
  @override
  String get id => 'xiuguo';
  @override
  String get name => '秀果';
  static const _endpoints = [
    'http://api.hclyz.com:81/mf/',
    'http://api.vipmisss.com:81/xcdsw/',
  ];
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  static final _states = Expando<_GuoState>();

  static Future<String> _network(Uri uri, Duration timeout) async {
    final response = await requestLiveResponse(
      () => _client.getUrl(uri),
      timeout: timeout,
    );
    if (response.status != 200) {
      throw StateError('直播面板 HTTP ${response.status}');
    }
    return utf8.decode(response.bytes);
  }

  /// 索引里的 address 是相对文件名，不能拼接猜测平台英文名。
  static List<({LiveCategory category, Uri uri})> parseIndex(
    String text, Uri base,
  ) {
    final decoded = jsonDecode(text);
    final rows = decoded is Map ? decoded['pingtai'] : null;
    if (rows is! List) throw StateError('直播面板没有返回分类索引');
    final result = <({LiveCategory category, Uri uri})>[];
    final seen = <String>{};
    for (final raw in rows.take(200)) {
      if (raw is! Map) continue;
      final title = '${raw['title'] ?? ''}'.trim();
      final address = '${raw['address'] ?? ''}'.trim();
      // 仅跟随本目录 JSON 文本，避免索引诱导读取视频或任意站点。
      if (title.isEmpty || !RegExp(r'^json[a-zA-Z0-9_-]+\.txt$').hasMatch(address)) continue;
      if (!seen.add(address)) continue;
      final key = address.substring(4, address.length - 4);
      result.add((
        category: LiveCategory(name: title, parentId: key, areaId: 'online'),
        uri: base.resolve(address),
      ));
    }
    return result;
  }

  static List<_Channel> parseChannels(String text, LiveCategory category) {
    final decoded = jsonDecode(text);
    final rows = decoded is Map ? decoded['zhubo'] : null;
    if (rows is! List) throw StateError('直播面板没有返回频道列表');
    final channels = <_Channel>[];
    final ids = <String>{};
    for (final raw in rows) {
      if (raw is! Map) continue;
      var title = '${raw['title'] ?? ''}'.trim();
      try { title = Uri.decodeComponent(title); } catch (_) {}
      final url = '${raw['address'] ?? ''}'.trim();
      final uri = Uri.tryParse(url);
      // MP4/点播 HLS 不能仅凭目录的 Number 字段冒充正在直播。
      if (title.isEmpty || uri == null || uri.host.isEmpty ||
          !['https', 'http'].contains(uri.scheme) ||
          !uri.path.toLowerCase().endsWith('.flv')) continue;
      // 映客重新上线时保留旧收藏 ID；其他平台以分类区分同名主播。
      final identity = category.parentId == 'yingke'
          ? title
          : '${category.parentId}:$title';
      final key = md5.convert(utf8.encode(identity)).toString();
      if (!ids.add(key)) continue;
      final cover = '${raw['img'] ?? ''}';
      channels.add((
        room: LiveRoom(
          roomId: key, title: title, anchor: title,
          cover: cover.startsWith('//') ? 'https:$cover' : cover,
          area: category.name, online: '',
        ),
        url: url,
      ));
    }
    // 多个主播指向同一条拦截视频时，不展示这个伪分类。
    if (channels.length > 1 && channels.map((e) => e.url).toSet().length == 1) {
      return const [];
    }
    return channels;
  }

  Future<List<_Group>> _catalog() {
    final state = _states[this] ??= _GuoState();
    if (state.groups != null && DateTime.now().isBefore(state.expires)) {
      return Future.value(state.groups!);
    }
    return state.pending ??= _discover().then((groups) {
      state.groups = groups;
      state.expires = DateTime.now().add(const Duration(minutes: 2));
      return groups;
    }).whenComplete(() => state.pending = null);
  }

  Future<List<_Group>> _discover() async {
    final clock = Stopwatch()..start();
    final request = _request ?? _network;
    // 两个镜像共享发现预算；有限并发，避免 130 个分类同时占用连接。
    for (final endpoint in _endpoints) {
      // 主镜像最多消耗半个总预算，超时后仍能实际尝试备用镜像。
      final deadline = endpoint == _endpoints.first
          ? const Duration(seconds: 15)
          : liveRequestTimeout;
      Duration remaining() => deadline - clock.elapsed;
      if (remaining() <= Duration.zero) continue;
      try {
        final base = Uri.parse(endpoint);
        final index = parseIndex(
          await request(base.resolve('json.txt'), remaining()), base,
        );
        final groups = <_Group>[];
        var next = 0;
        Future<void> worker() async {
          while (next < index.length && remaining() > Duration.zero) {
            final entry = index[next++];
            try {
              final budget = remaining();
              final text = await request(entry.uri,
                budget < const Duration(seconds: 4) ? budget : const Duration(seconds: 4));
              final channels = parseChannels(text, entry.category);
              if (channels.isNotEmpty) {
                groups.add((category: entry.category, uri: entry.uri, channels: channels));
              }
            } catch (_) {
              // 单个失效分类不影响其余已经验证的分类。
            }
          }
        }
        await Future.wait(List.generate(6, (_) => worker()));
        if (groups.isNotEmpty) {
          groups.sort((a, b) => index.indexWhere((e) => e.uri == a.uri)
              .compareTo(index.indexWhere((e) => e.uri == b.uri)));
          return groups;
        }
      } catch (_) {}
    }
    throw StateError('秀果暂无可用直播分类，请稍后重试');
  }

  @override
  Future<List<LiveCategory>> categories() async => [
    for (final group in await _catalog())
      LiveCategory(name: group.category.name, parentId: group.category.parentId,
        children: [group.category]),
  ];

  @override
  Future<List<LiveRoom>> rooms(LiveCategory category, {int page = 1}) async {
    if (page > 1) return const [];
    final group = (await _catalog()).where((e) =>
      e.category.parentId == category.parentId && category.areaId == 'online').firstOrNull;
    if (group == null) throw StateError('当前分类暂无可用直播');
    return group.channels.map((e) => e.room).toList();
  }

  @override
  Future<List<LiveRoom>> search(String keyword, {int page = 1}) async {
    if (page > 1 || keyword.trim().isEmpty) return const [];
    final query = keyword.trim().toLowerCase();
    return [for (final group in await _catalog())
      for (final channel in group.channels)
        if (channel.room.title.toLowerCase().contains(query)) channel.room];
  }

  @override
  Future<LiveStream> resolve(LiveRoom room, {int quality = 0}) async {
    for (final group in await _catalog()) {
      if (!group.channels.any((e) => e.room.roomId == room.roomId)) continue;
      // 主服务在发现后也可能离线；续签同样按索引文件名尝试两个镜像。
      final clock = Stopwatch()..start();
      final filename = group.uri.pathSegments.last;
      final candidates = <Uri>{
        group.uri,
        for (final endpoint in _endpoints) Uri.parse(endpoint).resolve(filename),
      }.toList();
      Object? lastError;
      for (var index = 0; index < candidates.length; index++) {
        final remaining = liveRequestTimeout - clock.elapsed;
        if (remaining <= Duration.zero) break;
        final budget = remaining ~/ (candidates.length - index);
        try {
          final text = await (_request ?? _network)(candidates[index], budget)
              .timeout(budget);
          final current = parseChannels(text, group.category)
              .where((e) => e.room.roomId == room.roomId).firstOrNull;
          if (current == null) continue;
          return LiveStream(url: current.url, quality: '平台默认', headers: const {},
            qualities: const [], renewAfter: const Duration(minutes: 2));
        } catch (error) {
          lastError = error;
        }
      }
      if (lastError != null) {
        throw StateError('直播线路刷新失败，请检查网络后重试');
      }
      break;
    }
    throw StateError('这个主播当前未开播，收藏已保留');
  }
}

class _GuoState {
  List<_Group>? groups;
  Future<List<_Group>>? pending;
  DateTime expires = DateTime.fromMillisecondsSinceEpoch(0);
}
