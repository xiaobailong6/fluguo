import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'local_store.dart';
import 'resource_settings.dart';

class ResourceSettingsEditor extends ChangeNotifier {
  ResourceSettingsEditor(this.repository, this.store)
    : _epoch = store.profileEpoch;
  final AppRepository repository;
  final LocalStore store;
  final int _epoch;
  ResourceSettings? _settings;
  String? _error;
  bool _saving = false;
  bool _loading = false;
  bool _disposed = false;

  ResourceSettings? get settings => allowed ? _settings : null;
  String? get error => allowed ? _error : null;
  bool get saving => _saving;
  bool get loading => _loading;
  bool get allowed =>
      !_disposed &&
      store.profileEpoch == _epoch &&
      !store.locked &&
      store.profile.admin;

  Future<void> load() async {
    if (!allowed || _loading || _saving) return;
    _loading = true;
    _error = null;
    _notify();
    try {
      final settings = await repository.resourceSettings();
      if (!allowed) return;
      _settings = settings;
    } catch (failure) {
      if (allowed) _error = '$failure';
    } finally {
      _loading = false;
    }
    _notify();
  }

  Future<void> save(ResourceSettings settings) async {
    if (_saving || _loading || !allowed || _settings == null) return;
    _error = null;
    _saving = true;
    _notify();
    try {
      final saved = await repository.saveResourceSettings(settings);
      if (allowed) _settings = saved;
    } catch (failure) {
      if (allowed) _error = '$failure';
      rethrow;
    } finally {
      _saving = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
