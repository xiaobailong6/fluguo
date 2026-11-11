import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/player/playback_sheets.dart';
import 'package:duanju_app/ui/theme/glass_style.dart';
import 'package:duanju_app/ui/widgets/glass/glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Widget _host(Widget child) => MaterialApp(
  builder: (context, page) => AppScope(
    repository: FakeRepository(),
    formFactor: FormFactor.phone,
    child: page!,
  ),
  home: Scaffold(body: child),
);

final _panel = find.byWidgetPredicate(
  (widget) => widget is GlassSurface && widget.role == GlassRole.panel,
);

void main() {
  testWidgets('播放页底部选集面板使用液态玻璃', (tester) async {
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showPlayerSheet(
                context,
                (_) => const Center(child: Text('选集内容')),
              ),
              child: const Text('打开选集'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开选集'));
    await tester.pumpAndSettle();
    expect(find.text('选集内容'), findsOneWidget);
    expect(_panel, findsOneWidget);
    final style = tester.widget<GlassSurface>(_panel).style!;
    // 视频持续变化，播放面板保持零模糊，但仍有玻璃染色、内高光与描边。
    expect(style.blurSigma, 0);
    expect(style.tier, GlassTier.full);
    expect(style.tint.a, greaterThan(.5));
    // 即使在浅色主题下，播放面板也必须使用深色玻璃。
    expect(style.tint.computeLuminance(), lessThan(.2));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('选集内容'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放设置悬浮面板使用液态玻璃而非不透明对话框', (tester) async {
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showPlayerPanel(
                context,
                (_) => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('设置内容'),
                ),
              ),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    expect(find.text('设置内容'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(_panel, findsOneWidget);
    final style = tester.widget<GlassSurface>(_panel).style!;
    expect(style.blurSigma, 0);
    expect(style.tier, GlassTier.full);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('设置内容'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
