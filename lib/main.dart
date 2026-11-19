import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'state/app_state.dart';
import 'ui/main_shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final appState = AppState();
  await appState.initialize();
  FocusManager.instance.highlightStrategy = appState.tvMode
      ? FocusHighlightStrategy.alwaysTraditional
      : FocusHighlightStrategy.automatic;

  runApp(M3u8VideoClientApp(appState: appState));
}

class AppDesktopScrollBehavior extends MaterialScrollBehavior {
  const AppDesktopScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.unknown,
      };
}

class M3u8VideoClientApp extends StatelessWidget {
  final AppState appState;

  const M3u8VideoClientApp({
    super.key,
    required this.appState,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        return MaterialApp(
          title: '流光视频',
          debugShowCheckedModeBanner: false,
          scrollBehavior: const AppDesktopScrollBehavior(),
          theme: VideoPlatformTheme.buildTheme(appState.themeId),
          // Bind Android TV D-Pad Center (Select), Enter, and Apple TV Siri Remote / Gamepad A to ActivateIntent
          shortcuts: <ShortcutActivator, Intent>{
            ...WidgetsApp.defaultShortcuts,
            const SingleActivator(LogicalKeyboardKey.select):
                const ActivateIntent(),
            const SingleActivator(LogicalKeyboardKey.enter):
                const ActivateIntent(),
            const SingleActivator(LogicalKeyboardKey.numpadEnter):
                const ActivateIntent(),
            const SingleActivator(LogicalKeyboardKey.gameButtonA):
                const ActivateIntent(),
            const SingleActivator(LogicalKeyboardKey.gameButtonSelect):
                const ActivateIntent(),
          },
          builder: (context, child) {
            Widget content = child ?? const SizedBox.shrink();
            content = _TvRemoteKeyInterceptor(
              appState: appState,
              child: content,
            );
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                navigationMode: NavigationMode.directional,
                textScaler: appState.tvMode
                    ? const TextScaler.linear(1.06)
                    : mq.textScaler.clamp(
                        minScaleFactor: 0.85,
                        maxScaleFactor: 1.05,
                      ),
              ),
              child: content,
            );
          },
          home: MainShell(appState: appState),
        );
      },
    );
  }
}

/// Global Android TV / Apple TV / D-Pad Remote Key & Focus Interceptor.
/// Solves:
/// 1. Auto-enables `tvMode` on Android TV boxes when any D-Pad key is pressed.
/// 2. Suppresses automatic soft keyboard (IME) popup when D-Pad focus traverses over or switches into a `TextField` (`EditableText`); only opens the IME when the user explicitly presses OK / Enter on the focused input box.
/// 3. Draws a global high-visibility TV focus ring overlay and auto-scrolls focused widgets into view so focus is never lost or hidden.
/// 4. Escapes `TextField` (`EditableText`) directional arrow key focus traps.
/// 5. Ensures OK / Center / Enter (`select`, `enter`, `gameButtonA`) reliably activates focused controls.
class _TvRemoteKeyInterceptor extends StatefulWidget {
  final AppState appState;
  final Widget child;

  const _TvRemoteKeyInterceptor({
    required this.appState,
    required this.child,
  });

  @override
  State<_TvRemoteKeyInterceptor> createState() =>
      _TvRemoteKeyInterceptorState();
}

class _TvRemoteKeyInterceptorState extends State<_TvRemoteKeyInterceptor> {
  FocusNode? _explicitlyActivatedEditableNode;
  bool _focusedIsUnactivatedInput = false;
  Timer? _imeHideGuardTimer1;
  Timer? _imeHideGuardTimer2;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onGlobalFocusChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onGlobalFocusChanged);
    _imeHideGuardTimer1?.cancel();
    _imeHideGuardTimer2?.cancel();
    super.dispose();
  }

  void _suppressImeIfNeeded() {
    if (!widget.appState.tvMode) return;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary == _explicitlyActivatedEditableNode) return;
    final ctx = primary.context;
    if (ctx == null) return;
    final editable = ctx.findAncestorStateOfType<EditableTextState>();
    if (editable != null) {
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    }
  }

  void _onGlobalFocusChanged() {
    if (!mounted) return;
    final primary = FocusManager.instance.primaryFocus;
    if (primary != _explicitlyActivatedEditableNode) {
      _explicitlyActivatedEditableNode = null;
    }

    bool nextIsUnactivatedInput = false;
    if (widget.appState.tvMode && primary != null) {
      final ctx = primary.context;
      final editable = ctx?.findAncestorStateOfType<EditableTextState>();
      if (editable != null && primary != _explicitlyActivatedEditableNode) {
        nextIsUnactivatedInput = true;
        // Prevent TextField from immediately popping up the soft keyboard when focus lands on it
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _suppressImeIfNeeded();
        });
        _imeHideGuardTimer1?.cancel();
        _imeHideGuardTimer2?.cancel();
        _imeHideGuardTimer1 = Timer(
          const Duration(milliseconds: 55),
          _suppressImeIfNeeded,
        );
        _imeHideGuardTimer2 = Timer(
          const Duration(milliseconds: 160),
          _suppressImeIfNeeded,
        );
      }

      // Ensure focused widget is scrolled into view on TV
      if (ctx != null && ctx.mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !ctx.mounted) return;
          try {
            final renderObj = ctx.findRenderObject();
            if (renderObj is RenderBox && renderObj.hasSize) {
              final screenH = MediaQuery.maybeSizeOf(ctx)?.height ?? 720;
              if (renderObj.size.height < screenH * 0.6) {
                Scrollable.ensureVisible(
                  ctx,
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOutCubic,
                  alignmentPolicy:
                      ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
                );
              }
            }
          } catch (_) {}
        });
      }
    }

    if (_focusedIsUnactivatedInput != nextIsUnactivatedInput) {
      setState(() {
        _focusedIsUnactivatedInput = nextIsUnactivatedInput;
      });
    }
  }

  bool _isDpadOrTvKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.gameButtonSelect;
  }

  TraversalDirection? _directionForKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowUp) return TraversalDirection.up;
    if (key == LogicalKeyboardKey.arrowDown) return TraversalDirection.down;
    if (key == LogicalKeyboardKey.arrowLeft) return TraversalDirection.left;
    if (key == LogicalKeyboardKey.arrowRight) return TraversalDirection.right;
    return null;
  }

  bool _isActivateKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.gameButtonSelect;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final primary = FocusManager.instance.primaryFocus;
    final focusedCtx = primary?.context;
    final editableState = focusedCtx != null
        ? (focusedCtx.findAncestorStateOfType<EditableTextState>())
        : null;

    if (Platform.isAndroid &&
        !widget.appState.tvMode &&
        editableState == null &&
        _isDpadOrTvKey(key)) {
      final mqSize = MediaQuery.maybeSizeOf(context);
      final isLandscapeTvScreen = mqSize != null &&
          mqSize.width >= 720 &&
          mqSize.width > mqSize.height;
      if (widget.appState.isHardwareTv || isLandscapeTvScreen) {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        widget.appState.setTvMode(true);
      }
    }

    final dir = _directionForKey(key);
    if (dir != null) {
      // 1. If focused on a TextField (EditableText):
      //    - If IME has NOT been explicitly opened yet on TV, allow ALL 4 directional arrows to move focus freely!
      //    - Even if IME is open, allow Up/Down (or Left/Right at text edges) to move focus out!
      if (editableState != null && primary != null) {
        final imeNotOpenOnTv = widget.appState.tvMode &&
            _explicitlyActivatedEditableNode != primary;
        final value = editableState.textEditingValue;
        final textLen = value.text.length;
        final cursorOffset = value.selection.baseOffset;
        final shouldEscape = imeNotOpenOnTv ||
            dir == TraversalDirection.up ||
            dir == TraversalDirection.down ||
            textLen == 0 ||
            (dir == TraversalDirection.left && cursorOffset <= 0) ||
            (dir == TraversalDirection.right && cursorOffset >= textLen);
        if (shouldEscape) {
          _explicitlyActivatedEditableNode = null;
          SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
          final moved = primary.focusInDirection(dir);
          if (!moved) {
            if (dir == TraversalDirection.down ||
                dir == TraversalDirection.right) {
              primary.enclosingScope?.nextFocus();
            } else {
              primary.enclosingScope?.previousFocus();
            }
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }

      // 2. If no focusable leaf widget has primary focus yet, focus the first available widget in the active scope.
      if (primary == null ||
          primary == FocusManager.instance.rootScope ||
          primary is FocusScopeNode) {
        final scope = primary is FocusScopeNode
            ? primary
            : FocusManager.instance.rootScope;
        if (scope.focusedChild == null) {
          final descendants = scope.traversalDescendants.toList();
          if (descendants.isNotEmpty) {
            descendants.first.requestFocus();
            return KeyEventResult.handled;
          }
        }
      }
      return KeyEventResult.ignored;
    }

    // 3. On TV mode, if focused on an EditableText where the soft keyboard was suppressed,
    //    pressing OK / Enter explicitly opens the soft keyboard!
    if (event is KeyDownEvent &&
        widget.appState.tvMode &&
        _isActivateKey(key) &&
        editableState != null &&
        primary != null &&
        _explicitlyActivatedEditableNode != primary) {
      _explicitlyActivatedEditableNode = primary;
      editableState.requestKeyboard();
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      if (_focusedIsUnactivatedInput) {
        setState(() => _focusedIsUnactivatedInput = false);
      }
      return KeyEventResult.handled;
    }

    // 4. Handle OK / Center / Enter activation fallback for widgets that only use GestureDetector, PopupMenuButton, or ButtonActivateIntent
    if (event is KeyDownEvent &&
        _isActivateKey(key) &&
        editableState == null &&
        focusedCtx != null) {
      final popupState = focusedCtx.findAncestorStateOfType<PopupMenuButtonState>();
      if (popupState != null && popupState.mounted) {
        popupState.showButtonMenu();
        return KeyEventResult.handled;
      }
      final activateAction = Actions.maybeFind<ActivateIntent>(focusedCtx);
      if (activateAction != null &&
          activateAction.isEnabled(const ActivateIntent())) {
        // Standard Flutter Shortcuts will invoke ActivateIntent
        return KeyEventResult.ignored;
      }
      final buttonAction =
          Actions.maybeFind<ButtonActivateIntent>(focusedCtx);
      if (buttonAction != null &&
          buttonAction.isEnabled(const ButtonActivateIntent())) {
        Actions.invoke(focusedCtx, const ButtonActivateIntent());
        return KeyEventResult.handled;
      }
      // Fallback: inspect focused widget or immediate ancestors for GestureDetector / InkResponse / ButtonStyleButton
      bool triggered = false;
      void tryTriggerWidget(Widget w) {
        if (triggered) return;
        if (w is InkResponse && w.onTap != null) {
          triggered = true;
          w.onTap!();
        } else if (w is GestureDetector && w.onTap != null) {
          triggered = true;
          w.onTap!();
        } else if (w is ButtonStyleButton && w.onPressed != null) {
          triggered = true;
          w.onPressed!();
        } else if (w is IconButton && w.onPressed != null) {
          triggered = true;
          w.onPressed!();
        } else if (w is ListTile && w.onTap != null) {
          triggered = true;
          w.onTap!();
        }
      }

      tryTriggerWidget(focusedCtx.widget);
      if (!triggered) {
        int depth = 0;
        focusedCtx.visitAncestorElements((el) {
          if (depth++ > 5 || triggered) return false;
          tryTriggerWidget(el.widget);
          return !triggered;
        });
      }
      if (triggered) {
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.kind == PointerDeviceKind.touch &&
            widget.appState.tvMode &&
            !widget.appState.isHardwareTv) {
          final mqSize = MediaQuery.maybeSizeOf(context);
          if (mqSize != null && mqSize.shortestSide < 600) {
            widget.appState.setTvMode(false);
          }
        }
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _handleKeyEvent,
        child: widget.child,
      ),
    );
  }
}
