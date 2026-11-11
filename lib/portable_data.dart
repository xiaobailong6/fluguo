import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

const portableDataFolder = 'userdata';

/// Call after Flutter plugin registration, before any preferences or data reads.
/// The optional platform/executable values allow isolated filesystem tests.
bool enablePortableData({bool? isWindows, String? executablePath}) {
  if (!(isWindows ?? Platform.isWindows)) return false;
  final directory = path.join(
    path.dirname(executablePath ?? Platform.resolvedExecutable),
    portableDataFolder,
  );
  // An existing directory is the opt-in; never create it or import APPDATA here.
  if (!Directory(directory).existsSync()) return false;

  final preferences = SharedPreferencesStorePlatform.instance;
  final asyncPreferences = SharedPreferencesAsyncPlatform.instance;
  if (preferences is! SharedPreferencesWindows ||
      asyncPreferences is! SharedPreferencesAsyncWindows) {
    throw StateError('Windows preferences must be registered before portable data');
  }
  final provider = _PortablePathProvider(directory);
  PathProviderPlatform.instance = provider;
  preferences.pathProvider = provider;
  asyncPreferences.pathProvider = provider;
  return true;
}

class _PortablePathProvider extends PathProviderWindows {
  _PortablePathProvider(this.directory);
  final String directory;

  // Leave temporary, documents and user-selected download paths untouched.
  @override
  Future<String?> getApplicationSupportPath() async => directory;
}
