import 'dart:async';

import 'package:duanju_app/window_on_top.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('独立键默认关闭，保存后可恢复，不改旧偏好', () async {
    SharedPreferences.setMockInitialValues({'unrelated': 'keep'});
    final applied = <bool>[];
    final setting = WindowOnTop(apply: (value) async => applied.add(value));
    addTearDown(setting.dispose);
    await setting.initialize();
    expect(setting.value, isFalse);
    expect(applied, [false]);
    await setting.setPreferred(true);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(WindowOnTop.preferenceKey), isTrue);
    expect(preferences.getString('unrelated'), 'keep');
    final restored = WindowOnTop(apply: (value) async => applied.add(value));
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.value, isTrue);
    expect(applied.last, isTrue);
  });

  test('初始化失败不抛出且后续仍能切换', () async {
    var broken = true;
    final setting = WindowOnTop(
      load: () async => true,
      apply: (_) async {
        if (broken) throw StateError('plugin');
      },
      save: (_) async {},
    );
    addTearDown(setting.dispose);
    await setting.initialize();
    expect(setting.value, isFalse);
    broken = false;
    await setting.setPreferred(true);
    expect(setting.value, isTrue);
  });

  test('延迟初始化不会覆盖已选择的最新值', () async {
    final load = Completer<bool>();
    final setting = WindowOnTop(
      load: () => load.future,
      apply: (_) async {},
      save: (_) async {},
    );
    addTearDown(setting.dispose);
    final initialization = setting.initialize();
    final change = setting.setPreferred(true);
    load.complete(false);
    await initialization;
    expect(setting.value, isTrue);
    await change;
    expect(setting.value, isTrue);
  });

  test('快速切换串行，旧保存完成不回写最新开关', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final applied = <bool>[];
    final saved = <bool>[];
    final setting = WindowOnTop(
      apply: (value) async => applied.add(value),
      save: (value) async {
        if (saved.isEmpty) {
          started.complete();
          await release.future;
        }
        saved.add(value);
      },
    );
    addTearDown(setting.dispose);
    final first = setting.setPreferred(true);
    await started.future;
    final second = setting.setPreferred(false);
    expect(setting.value, isFalse);
    expect(applied, [true]);
    release.complete();
    await first;
    expect(setting.value, isFalse);
    await second;
    expect(applied, [true, false]);
    expect(saved, [true, false]);
  });

  test('保存失败回滚偏好和窗口；旧失败不能覆盖新选择', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final applied = <bool>[];
    var firstSave = true;
    var persisted = false;
    final setting = WindowOnTop(
      apply: (value) async => applied.add(value),
      save: (value) async {
        persisted = value;
        if (firstSave) {
          firstSave = false;
          started.complete();
          await release.future;
          throw StateError('disk');
        }
      },
    );
    addTearDown(setting.dispose);
    final first = setting.setPreferred(true);
    final failed = expectLater(first, throwsStateError);
    await started.future;
    final second = setting.setPreferred(true);
    release.complete();
    await failed;
    expect(setting.value, isTrue);
    await second;
    expect(persisted, isTrue);
    expect(applied, [true, false, true]);
  });

  test('插件失败不保存，保存失败恢复上次成功值', () async {
    var pluginFails = false;
    var saveFails = false;
    var effective = false;
    var persisted = false;
    final setting = WindowOnTop(
      apply: (value) async {
        effective = value;
        if (pluginFails) {
          pluginFails = false;
          throw StateError('plugin');
        }
      },
      save: (value) async {
        persisted = value;
        if (saveFails) {
          saveFails = false;
          throw StateError('disk');
        }
      },
    );
    addTearDown(setting.dispose);
    pluginFails = true;
    await expectLater(setting.setPreferred(true), throwsStateError);
    expect(setting.value, isFalse);
    expect(effective, isFalse);
    expect(persisted, isFalse);
    await setting.setPreferred(true);
    saveFails = true;
    await expectLater(setting.setPreferred(false), throwsStateError);
    expect(setting.value, isTrue);
    expect(effective, isTrue);
    expect(persisted, isTrue);
  });

  test('PiP 强制置顶，退出覆盖原生旧状态并恢复最新用户值', () async {
    var effective = false;
    final setting = WindowOnTop(
      apply: (value) async => effective = value,
      save: (_) async {},
    );
    addTearDown(setting.dispose);
    await setting.transitionPictureInPicture<void>(
      enabled: true,
      transition: () async {},
    );
    await setting.setPreferred(false);
    expect(effective, isTrue);
    await setting.setPreferred(true);
    await setting.transitionPictureInPicture<void>(
      enabled: false,
      transition: () async => effective = false,
    );
    expect(effective, isTrue);
    await setting.transitionPictureInPicture<void>(
      enabled: true,
      transition: () async {},
    );
    await setting.setPreferred(false);
    await setting.restore();
    expect(effective, isTrue);
    await setting.transitionPictureInPicture<void>(
      enabled: false,
      transition: () async => effective = true,
    );
    expect(effective, isFalse);
    await setting.setPreferred(true);
    effective = false;
    await setting.restore();
    expect(effective, isTrue);
  });

  test('PiP 失败恢复之前强制状态，转换中切换偏好按序执行', () async {
    var effective = false;
    final setting = WindowOnTop(
      apply: (value) async => effective = value,
      save: (_) async {},
    );
    addTearDown(setting.dispose);
    await expectLater(
      setting.transitionPictureInPicture<void>(
        enabled: true,
        transition: () async => throw StateError('enter'),
      ),
      throwsStateError,
    );
    expect(effective, isFalse);
    final started = Completer<void>();
    final release = Completer<void>();
    final entering = setting.transitionPictureInPicture<void>(
      enabled: true,
      transition: () async {
        started.complete();
        await release.future;
      },
    );
    await started.future;
    final change = setting.setPreferred(false);
    release.complete();
    await entering;
    await change;
    expect(effective, isTrue);
    await expectLater(
      setting.transitionPictureInPicture<void>(
        enabled: false,
        transition: () async => throw StateError('exit'),
      ),
      throwsStateError,
    );
    await setting.setPreferred(false);
    expect(effective, isTrue);
  });
}
