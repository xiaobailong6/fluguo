import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/portable_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

class _AppDataProvider extends PathProviderWindows {
  _AppDataProvider(this.directory);
  final String directory;

  @override
  Future<String?> getApplicationSupportPath() async => directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory portable;
  late Directory appData;
  late String executable;
  late PathProviderPlatform originalProvider;
  late SharedPreferencesStorePlatform originalPreferences;
  late SharedPreferencesAsyncPlatform? originalAsyncPreferences;
  late _AppDataProvider appDataProvider;
  late SharedPreferencesWindows legacy;
  late SharedPreferencesAsyncWindows asyncPreferences;
  const options = SharedPreferencesWindowsOptions();

  setUp(() async {
    originalProvider = PathProviderPlatform.instance;
    originalPreferences = SharedPreferencesStorePlatform.instance;
    originalAsyncPreferences = SharedPreferencesAsyncPlatform.instance;
    root = await Directory.systemTemp.createTemp('portable_data');
    final binary = await Directory(path.join(root.path, 'app')).create();
    executable = path.join(binary.path, 'FlGuo.exe');
    portable = Directory(path.join(binary.path, portableDataFolder));
    appData = await Directory(path.join(root.path, 'APPDATA', 'FlGuo')).create(
      recursive: true,
    );
    appDataProvider = _AppDataProvider(appData.path);
    PathProviderPlatform.instance = appDataProvider;
    // Match generated registration: legacy registration also installs async.
    SharedPreferencesWindows.registerWith();
    legacy = SharedPreferencesStorePlatform.instance as SharedPreferencesWindows;
    asyncPreferences =
        SharedPreferencesAsyncPlatform.instance as SharedPreferencesAsyncWindows;
    legacy.pathProvider = appDataProvider;
    asyncPreferences.pathProvider = appDataProvider;
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalProvider;
    SharedPreferencesStorePlatform.instance = originalPreferences;
    SharedPreferencesAsyncPlatform.instance = originalAsyncPreferences;
    await root.delete(recursive: true);
  });

  bool enable({bool windows = true}) => enablePortableData(
    isWindows: windows,
    executablePath: executable,
  );

  test('missing userdata keeps registered providers and APPDATA settings', () async {
    await legacy.setValue('String', 'flutter.theme', 'original');
    expect(enable(), isFalse);
    expect(await portable.exists(), isFalse);
    expect(PathProviderPlatform.instance, same(appDataProvider));
    expect(legacy.pathProvider, same(appDataProvider));
    expect(asyncPreferences.pathProvider, same(appDataProvider));
    expect(await asyncPreferences.getString('flutter.theme', options), 'original');
  });

  test('userdata in the working directory does not enable portable mode', () async {
    final unrelated = await Directory(
      path.join(root.path, 'working', 'userdata'),
    ).create(recursive: true);
    final originalDirectory = Directory.current;
    try {
      Directory.current = unrelated.parent;
      expect(enable(), isFalse);
      expect(PathProviderPlatform.instance, same(appDataProvider));
      expect(await portable.exists(), isFalse);
      expect(await unrelated.list().isEmpty, isTrue);
    } finally {
      Directory.current = originalDirectory;
    }
  });

  test('a file named userdata is not portable opt-in', () async {
    await File(portable.path).writeAsString('keep');
    expect(enable(), isFalse);
    expect(await File(portable.path).readAsString(), 'keep');
    expect(PathProviderPlatform.instance, same(appDataProvider));
  });

  test('non-Windows leaves an existing userdata directory untouched', () async {
    await portable.create();
    expect(enable(windows: false), isFalse);
    expect(PathProviderPlatform.instance, same(appDataProvider));
    expect(legacy.pathProvider, same(appDataProvider));
    expect(asyncPreferences.pathProvider, same(appDataProvider));
    expect(await portable.list().isEmpty, isTrue);
  });

  test('both preferences implementations must be registered before opt-in', () async {
    await portable.create();
    SharedPreferencesAsyncPlatform.instance = null;
    expect(enable, throwsStateError);
    expect(PathProviderPlatform.instance, same(appDataProvider));
    expect(legacy.pathProvider, same(appDataProvider));
  });

  test('support, legacy and async preferences share the exe-side directory', () async {
    await portable.create();
    final existing = File(path.join(appData.path, 'shared_preferences.json'));
    await existing.writeAsString('{"flutter.theme":"appdata"}');
    final original = await existing.readAsBytes();
    expect(enable(), isTrue);
    expect((await getApplicationSupportDirectory()).path, portable.path);
    expect(legacy.pathProvider, same(PathProviderPlatform.instance));
    expect(asyncPreferences.pathProvider, same(PathProviderPlatform.instance));
    expect(await legacy.getAll(), isEmpty);
    expect(await legacy.setValue('String', 'flutter.theme', 'portable'), isTrue);
    expect(await asyncPreferences.getString('flutter.theme', options), 'portable');
    await asyncPreferences.setString('async.theme', 'dark', options);
    final stored = jsonDecode(
      await File(path.join(portable.path, 'shared_preferences.json')).readAsString(),
    ) as Map<String, dynamic>;
    expect(stored['flutter.theme'], 'portable');
    expect(stored['async.theme'], 'dark');
    expect(await existing.readAsBytes(), original);
  });

  test('async reload reads the portable file and custom file names', () async {
    await portable.create();
    expect(enable(), isTrue);
    const customOptions = SharedPreferencesWindowsOptions(fileName: 'profile');
    await File(path.join(portable.path, 'profile.json')).writeAsString(
      '{"theme":"initial"}',
    );
    expect(await asyncPreferences.getString('theme', customOptions), 'initial');
    await File(path.join(portable.path, 'profile.json')).writeAsString(
      '{"theme":"external"}',
    );
    await asyncPreferences.reload(customOptions);
    expect(await asyncPreferences.getString('theme', customOptions), 'external');
    await asyncPreferences.setString('theme', 'saved', customOptions);
    expect(
      jsonDecode(await File(path.join(portable.path, 'profile.json')).readAsString()),
      {'theme': 'saved'},
    );
    expect(await appData.list().isEmpty, isTrue);
  });

  test('opt-in does not move APPDATA data or rewrite selected download paths', () async {
    await portable.create();
    final legacyData = await Directory(
      path.join(appData.parent.path, '真果鉴', '真果鉴'),
    ).create(recursive: true);
    final appFile = File(path.join(legacyData.path, 'library.json'));
    await appFile.writeAsString('{"saved":true}');
    final selected = path.join(root.path, 'my-downloads');
    final location = File(path.join(portable.path, 'download-location.json'));
    await location.writeAsString(jsonEncode({'directory': selected}));
    final original = await location.readAsBytes();
    expect(enable(), isTrue);
    expect((await getApplicationSupportDirectory()).path, portable.path);
    expect(await location.readAsBytes(), original);
    expect(await appFile.readAsString(), '{"saved":true}');
    expect(await Directory(selected).exists(), isFalse);
  });
}
