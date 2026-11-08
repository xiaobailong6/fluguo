import 'dart:async';

import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../playback_preferences.dart';
import '../widgets/app_notice.dart';
import '../widgets/group_card.dart';
import 'settings_rows.dart';

typedef OpenDanmakuSubpage = void Function(String title, WidgetBuilder body);

const _scales = [.75, 1.0, 1.25, 1.5];
final _scaleLabels = {0.75: '小', 1.0: '标准', 1.25: '大', 1.5: '特大'};

const _opacities = [.25, .5, .75, 1.0];

const _strokes = [0.0, 1.0, 2.0, 4.0];

const _shadows = [0.0, 3.0, 6.0, 12.0];

T nearest<T extends num>(List<T> options, T value) => options.reduce(
  (a, b) => (a - value).abs() <= (b - value).abs() ? a : b,
);

/// 设置 › 弹幕：开关、字号、颜色、透明度、加粗、描边、阴影、显示区域和屏蔽词。
List<Widget> danmakuSettingsRows(
  BuildContext context,
  LocalStore store,
  OpenDanmakuSubpage open,
) {
  final preferences = store.playbackPreferences;
  void savePreferences(PlaybackPreferences next) =>
      saveSetting(context, () => store.setPlaybackPreferences(next));
  return [
    SettingsCard(
      children: [
        SwitchTile(
          title: '显示弹幕',
          subtitle: '关闭后播放页默认不加载弹幕，播放器内仍可临时打开',
          value: preferences.danmaku,
          onChanged: (value) => savePreferences(preferences.copyWith(danmaku: value)),
        ),
        ValueTile<double>(
          title: '弹幕字号',
          options: _scaleLabels,
          value: nearest(_scales, preferences.danmakuScale),
          onChanged: (scale) => savePreferences(
            preferences.copyWith(danmakuScale: scale),
          ),
        ),
        ValueTile<int>(
          title: '弹幕颜色',
          options: const {
            0xFFFFFFFF: '白色',
            0xFFFFE066: '黄色',
            0xFF66E0FF: '青色',
            0xFFFF8FB8: '粉色',
            0xFF8CF08C: '绿色',
          },
          value: preferences.danmakuColor,
          onChanged: (color) =>
              savePreferences(preferences.copyWith(danmakuColor: color)),
        ),
        ValueTile<double>(
          title: '弹幕不透明度',
          options: {for (final opacity in _opacities) opacity: '${(opacity * 100).round()}%'},
          value: nearest(_opacities, preferences.danmakuOpacity),
          onChanged: (opacity) => savePreferences(
            preferences.copyWith(danmakuOpacity: opacity),
          ),
        ),
        SwitchTile(
          title: '弹幕加粗',
          value: preferences.danmakuBold,
          onChanged: (value) =>
              savePreferences(preferences.copyWith(danmakuBold: value)),
        ),
      ],
    ),
    SettingsCard(
      children: [
        ValueTile<double>(
          title: '描边宽度',
          subtitle: '文字外侧的黑色轮廓，亮背景下更清楚',
          options: {
            for (final stroke in _strokes)
              stroke: stroke <= 0 ? '无' : stroke.toStringAsFixed(0),
          },
          value: nearest(_strokes, preferences.danmakuStroke),
          onChanged: (stroke) =>
              savePreferences(preferences.copyWith(danmakuStroke: stroke)),
        ),
        ValueTile<double>(
          title: '阴影强度',
          options: {
            for (final shadow in _shadows)
              shadow: shadow <= 0 ? '无' : shadow.toStringAsFixed(0),
          },
          value: nearest(_shadows, preferences.danmakuShadow),
          onChanged: (shadow) =>
              savePreferences(preferences.copyWith(danmakuShadow: shadow)),
        ),
        ValueTile<DanmakuCoverage>(
          title: '显示区域',
          subtitle: '弹幕允许占用的画面高度',
          options: {
            for (final coverage in DanmakuCoverage.values) coverage: coverage.label,
          },
          value: preferences.danmakuCoverage,
          onChanged: (coverage) => savePreferences(
            preferences.copyWith(danmakuCoverage: coverage),
          ),
        ),
      ],
    ),
    SettingsCard(
      children: [
        SettingsTile(
          title: '屏蔽词',
          subtitle: preferences.danmakuWords.isEmpty
              ? '命中关键词的弹幕不再显示'
              : '已添加 ${preferences.danmakuWords.length} 个关键词',
          onTap: () => open('弹幕屏蔽词', (_) => DanmakuWordsView(store: store)),
        ),
      ],
    ),
  ];
}

class DanmakuWordsView extends StatefulWidget {
  const DanmakuWordsView({super.key, required this.store});
  final LocalStore store;

  @override
  State<DanmakuWordsView> createState() => _DanmakuWordsViewState();
}

class _DanmakuWordsViewState extends State<DanmakuWordsView> {
  final _controller = TextEditingController();

  LocalStore get _store => widget.store;

  Future<void> _save(List<String> words) => saveSetting(
    context,
    () => _store.setPlaybackPreferences(
      _store.playbackPreferences.copyWith(danmakuWords: words),
    ),
  );

  Future<void> _add() async {
    final word = _controller.text.trim();
    if (word.isEmpty) return;
    _controller.clear();
    final existing = List<String>.of(_store.playbackPreferences.danmakuWords);
    if (existing.length >= danmakuWordLimit) {
      if (mounted) showAppNotice(context, '屏蔽词最多 $danmakuWordLimit 个');
      return;
    }
    if (word.length > danmakuWordLength) {
      if (mounted) showAppNotice(context, '单个屏蔽词最长 $danmakuWordLength 字');
      return;
    }
    await _save([...existing, word]);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final words = _store.playbackPreferences.danmakuWords;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _controller,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => unawaited(_add()),
                decoration: InputDecoration(
                  hintText: '输入关键词后回车添加',
                  suffixIcon: IconButton(
                    onPressed: () => unawaited(_add()),
                    icon: const Icon(Icons.add_rounded),
                    tooltip: '添加',
                  ),
                ),
              ),
            ),
            Expanded(
              child: words.isEmpty
                  ? const Center(child: Text('暂无屏蔽词'))
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        for (final (index, word) in words.indexed)
                          ListTile(
                            title: Text(word),
                            trailing: IconButton(
                              onPressed: () => unawaited(
                                _save([...words]..removeAt(index)),
                              ),
                              icon: const Icon(Icons.close_rounded),
                              tooltip: '删除',
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}
