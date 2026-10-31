import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/theme/glass_style.dart';
import 'package:duanju_app/ui/widgets/glass/glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Future<GlassStyle> mountGlass(
  WidgetTester tester, {
  ColorScheme? scheme,
  MediaQueryData media = const MediaQueryData(),
  FormFactor form = FormFactor.phone,
  bool enabled = true,
  bool blur = true,
  VoidCallback? onTap,
}) async {
  late GlassStyle style;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: scheme ?? ColorScheme.fromSeed(seedColor: Colors.orange),
      ),
      home: MediaQuery(
        data: media,
        child: AppScope(
          repository: FakeRepository(),
          formFactor: form,
          glass: enabled,
          child: Builder(
            builder: (context) {
              style = GlassStyleResolver.of(context);
              return Center(
                child: SizedBox(
                  width: 240,
                  height: 80,
                  child: GlassSurface(
                    blur: blur,
                    child: TextButton(
                      onPressed: onTap ?? () {},
                      child: const Text('玻璃按钮'),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return style;
}

void main() {
  setUp(GlassStyleResolver.clearCache);

  testWidgets('浮动玻璃保留真实模糊并隔离内容重绘', (tester) async {
    final style = await mountGlass(tester);
    expect(style.tier, GlassTier.full);
    expect(style.blurSigma, 18);
    final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
    expect(identical(filter.filter, style.filter), isTrue);
    expect(filter.blendMode, BlendMode.src);
    expect(filter.child, isA<RepaintBoundary>());
    expect(tester.takeException(), isNull);
  });

  testWidgets('静态卡片为稳定不透明材质且没有模糊层', (tester) async {
    var tapped = false;
    await mountGlass(tester, blur: false, onTap: () => tapped = true);
    expect(find.byType(BackdropFilter), findsNothing);
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(GlassSurface),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color!.a, 1);
    await tester.tap(find.text('玻璃按钮'));
    expect(tapped, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final reduced in [
    const MediaQueryData(disableAnimations: true),
    const MediaQueryData(accessibleNavigation: true),
  ]) {
    testWidgets('系统辅助设置使用轻量模糊：$reduced', (tester) async {
      final style = await mountGlass(tester, media: reduced);
      expect(style.tier, GlassTier.reduced);
      expect(style.blurSigma, 10);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });
  }

  testWidgets('高对比度、电视和关闭玻璃都不生成模糊', (tester) async {
    for (var mode = 0; mode < 3; mode++) {
      final style = await mountGlass(
        tester,
        media: MediaQueryData(highContrast: mode == 0),
        form: mode == 1 ? FormFactor.television : FormFactor.phone,
        enabled: mode != 2,
      );
      expect(style.tier, GlassTier.none);
      expect(style.filter, isNull);
      expect(style.tint.a, 1);
      expect(find.byType(BackdropFilter), findsNothing);
    }
  });

  testWidgets('相同配色复用滤镜，相同surface的不同主题不串色', (tester) async {
    final firstScheme = ColorScheme.fromSeed(seedColor: Colors.orange);
    final first = await mountGlass(tester, scheme: firstScheme);
    final same = await mountGlass(tester, scheme: firstScheme);
    expect(identical(first, same), isTrue);
    expect(identical(first.filter, same.filter), isTrue);
    final other = await mountGlass(
      tester,
      scheme: firstScheme.copyWith(primary: Colors.blue),
    );
    expect(identical(first, other), isFalse);
    expect(first.tint, isNot(other.tint));
  });

  testWidgets('不透明档缓存也随outline和surfaceContainer更新', (tester) async {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.orange);
    final first = await mountGlass(tester, scheme: scheme, enabled: false);
    final next = await mountGlass(
      tester,
      enabled: false,
      scheme: scheme.copyWith(
        outlineVariant: Colors.blue,
        surfaceContainer: Colors.green,
      ),
    );
    expect(first.rimHighlight, isNot(next.rimHighlight));
    expect(first.tint, isNot(next.tint));
  });
}
