import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app_build.dart';
import '../app_device.dart';
import '../core_bridge.dart';
import '../local_store.dart';
import '../theme_color.dart';
import 'app_scope.dart';
import 'back_intent.dart';
import 'device_registration.dart';
import 'shell/app_shell.dart';
import 'theme/app_theme.dart';
import 'theme/system_color.dart';
import 'users/unlock_page.dart';
import 'widgets/focus_ring.dart';

class DuanjuApp extends StatefulWidget {
  const DuanjuApp({
    super.key,
    required this.repository,
    this.store,
    this.bootstrapError,
    this.onRetry,
    this.television = false,
    this.version = '',
  });
  final AppRepository repository;
  final LocalStore? store;
  final String? bootstrapError;
  final VoidCallback? onRetry;
  final bool television;
  final String version;

  @override
  State<DuanjuApp> createState() => _DuanjuAppState();
}

class _DuanjuAppState extends State<DuanjuApp> with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  Color? _systemColor;
  int? _profileEpoch;
  var _television = false;
  var _phone = false;
  (Color, bool)? _themeKey;
  late (ThemeData, ThemeData) _themes;
  Object? _applicationKey;
  Timer? _historyCleanupTimer;

  void _cleanHistory() {
    unawaited(widget.store?.pruneExpiredHistory().catchError((Object _) {}));
  }

  void _scheduleHistoryCleanup() {
    _historyCleanupTimer?.cancel();
    if (widget.store == null) return;
    _cleanHistory();
    // 恢复前台另行检查；持续运行时每小时轻量判断是否已跨自然日。
    _historyCleanupTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) => _cleanHistory(),
    );
  }

  /// 根部只关心外观和身份；观看进度等资料变动由页面自己的监听处理。
  Object _configuration(LocalStore? store) => (
    store?.profileEpoch,
    store?.locked,
    store?.displayMode,
    store?.themeMode,
    store?.followSystemColor,
    store?.themeColor,
    store?.glassEffects,
    store?.sideBarExpanded,
    store?.source,
  );

  void _storeChanged() {
    final key = _configuration(widget.store);
    if (key == _applicationKey) return;
    setState(() => _applicationKey = key);
  }

  @override
  void didUpdateWidget(covariant DuanjuApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store == widget.store) return;
    oldWidget.store?.removeListener(_storeChanged);
    _applicationKey = _configuration(widget.store);
    widget.store?.addListener(_storeChanged);
    _scheduleHistoryCleanup();
  }

  @override
  void initState() {
    super.initState();
    _applicationKey = _configuration(widget.store);
    widget.store?.addListener(_storeChanged);
    WidgetsBinding.instance.addObserver(this);
    _scheduleHistoryCleanup();
    FocusManager.instance
      ..addEarlyKeyEventHandler(_blockKeyboardFocus)
      ..addEarlyKeyEventHandler(_leaveTextField);
    _loadSystemColor();
  }

  @override
  void dispose() {
    widget.store?.removeListener(_storeChanged);
    _historyCleanupTimer?.cancel();
    FocusManager.instance
      ..removeEarlyKeyEventHandler(_blockKeyboardFocus)
      ..removeEarlyKeyEventHandler(_leaveTextField);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadSystemColor();
      _cleanHistory();
    }
  }

  Future<void> _loadSystemColor() async {
    final color = await readSystemColor();
    if (mounted && color != _systemColor) {
      setState(() => _systemColor = color);
    }
  }

  static final _focusKeys = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.gameButtonA,
  };

  KeyEventResult _blockKeyboardFocus(KeyEvent event) {
    if (_television) return KeyEventResult.ignored;
    final key = event.logicalKey;
    return key == LogicalKeyboardKey.tab ||
            focusedTextField() == null &&
                !keyboardControlsFocused() &&
                _focusKeys.contains(key)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  KeyEventResult _leaveTextField(KeyEvent event) {
    if (!_television || event is KeyUpEvent) return KeyEventResult.ignored;
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null ||
        focusedTextField() == null ||
        textFieldKeepsKey(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };
    return direction != null && focus.focusInDirection(direction)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  KeyEventResult _escape(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape &&
            event.logicalKey != LogicalKeyboardKey.goBack) {
      return KeyEventResult.ignored;
    }
    final context =
        focusedTextField()?.context ??
        FocusManager.instance.primaryFocus?.context;
    if (context == null) return KeyEventResult.ignored;
    const intent = DismissIntent();
    final action = Actions.maybeFind<DismissIntent>(context, intent: intent);
    if (action != null &&
        Actions.of(context).invokeActionIfEnabled(action, intent, context).$1) {
      return KeyEventResult.handled;
    }
    final navigator = Navigator.maybeOf(context);
    if (navigator == null || !navigator.canPop()) {
      return KeyEventResult.ignored;
    }
    navigator.maybePop();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => _application(widget.store);

  void _resetRoutes(LocalStore? store) {
    final epoch = store?.profileEpoch;
    if (epoch == _profileEpoch) return;
    final previous = _profileEpoch;
    _profileEpoch = epoch;
    if (previous == null) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _navigator.currentState?.popUntil((route) => route.isFirst),
    );
  }

  Widget _application(LocalStore? store) {
    _resetRoutes(store);
    final formFactor = switch (store?.displayMode) {
      'television' => FormFactor.television,
      'phone' => FormFactor.phone,
      'pad' => FormFactor.pad,
      'window' => desktopPlatform ? FormFactor.window : FormFactor.pad,
      _ => widget.television ? FormFactor.television : null,
    };
    final television = formFactor == FormFactor.television;
    if (television != _television) {
      unawaited(AppDevice.setTelevisionMode(television));
    }
    _television = television;
    final systemColor = (store?.followSystemColor ?? true)
        ? _systemColor
        : null;
    final seed =
        systemColor ?? Color((store?.themeColor ?? ThemeColor.orange).seed);
    if ((seed, television) != _themeKey) {
      _themeKey = (seed, television);
      _themes = (
        AppTheme.build(seed, Brightness.light, television: television),
        AppTheme.build(seed, Brightness.dark, television: television),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => FocusManager.instance.highlightStrategy = television
          ? FocusHighlightStrategy.alwaysTraditional
          : FocusHighlightStrategy.alwaysTouch,
    );
    return MaterialApp(
      navigatorKey: _navigator,
      navigatorObservers: const [BackPopObserver()],
      title: appName,
      debugShowCheckedModeBanner: false,
      scrollBehavior: const FocusOutlineScrollBehavior(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: _themes.$1,
      darkTheme: _themes.$2,
      themeMode: AppTheme.mode(store?.themeMode ?? 'system'),
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemBars(Theme.of(context).brightness),
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, event) => _escape(event),
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.select, includeRepeats: false):
                  ActivateIntent(),
              SingleActivator(
                LogicalKeyboardKey.gameButtonA,
                includeRepeats: false,
              ): ActivateIntent(),
            },
            child: AppScope(
              repository: widget.repository,
              formFactor: formFactor,
              systemColorAvailable: _systemColor != null,
              glass: store?.glassEffects ?? true,
              version: widget.version,
              child: Builder(
                builder: (context) {
                  final phone =
                      AppScope.formFactorOf(context) == FormFactor.phone;
                  if (phone != _phone) {
                    _phone = phone;
                    unawaited(AppDevice.setPhoneMode(phone));
                  }
                  return FocusOutlineMotion(
                    child: FocusOutlineLayer(
                      child: FocusTraversalGroup(
                        policy: ReadingOrderTraversalPolicy(
                          requestFocusCallback: revealFocus,
                        ),
                        child: child!,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
      home: switch (store) {
        null => _BootScreen(
          error: widget.bootstrapError,
          onRetry: widget.onRetry,
        ),
        _ => DeviceRegistrationGate(
          store: store,
          child: AppShell(key: ValueKey(store.profileEpoch), store: store),
        ),
      },
    );
  }
}

class _BootScreen extends StatelessWidget {
  const _BootScreen({this.error, this.onRetry});
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 24,
          children: [
            if (error == null) const CircularProgressIndicator(),
            Text(
              error ?? '正在打开$appName',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (error != null && onRetry != null)
              FilledButton(onPressed: onRetry, child: const Text('重新打开')),
          ],
        ),
      ),
    ),
  );
}
