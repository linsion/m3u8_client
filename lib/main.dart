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
  FocusManager.instance.highlightStrategy =
      FocusHighlightStrategy.alwaysTraditional;

  final appState = AppState();
  await appState.initialize();

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
            if (!appState.tvMode) return content;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.06),
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

/// Global Android TV / Apple TV / D-Pad Remote Key Interceptor.
/// Solves:
/// 1. Auto-enables `tvMode` on Android TV boxes when any D-Pad key is pressed.
/// 2. Escapes `TextField` (`EditableText`) directional arrow key focus traps.
/// 3. Restores initial focus when no widget currently has primary focus.
/// 4. Ensures OK / Center / Enter (`select`, `enter`, `gameButtonA`) reliably activates focused controls.
class _TvRemoteKeyInterceptor extends StatelessWidget {
  final AppState appState;
  final Widget child;

  const _TvRemoteKeyInterceptor({
    required this.appState,
    required this.child,
  });

  bool _isDpadOrTvKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.gameButtonSelect ||
        key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.mediaRewind;
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
    if (Platform.isAndroid && !appState.tvMode && _isDpadOrTvKey(key)) {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      appState.setTvMode(true);
    }

    final primary = FocusManager.instance.primaryFocus;
    final focusedCtx = primary?.context;
    final editableState = focusedCtx != null
        ? (focusedCtx.findAncestorStateOfType<EditableTextState>())
        : null;

    final dir = _directionForKey(key);
    if (dir != null) {
      // 1. If trapped inside a TextField (EditableText), allow Up/Down (or Left/Right at text edges) to move focus out!
      if (editableState != null && primary != null) {
        final value = editableState.textEditingValue;
        final textLen = value.text.length;
        final cursorOffset = value.selection.baseOffset;
        final shouldEscape = dir == TraversalDirection.up ||
            dir == TraversalDirection.down ||
            textLen == 0 ||
            (dir == TraversalDirection.left && cursorOffset <= 0) ||
            (dir == TraversalDirection.right && cursorOffset >= textLen);
        if (shouldEscape) {
          final moved = primary.focusInDirection(dir);
          if (!moved) {
            primary.unfocus();
            primary.enclosingScope?.nextFocus();
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

    // 3. Handle OK / Center / Enter activation fallback for widgets that only use GestureDetector or ButtonActivateIntent
    if (event is KeyDownEvent &&
        _isActivateKey(key) &&
        editableState == null &&
        focusedCtx != null) {
      final activateAction =
          Actions.maybeFind<ActivateIntent>(focusedCtx);
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
        }
      }

      tryTriggerWidget(focusedCtx.widget);
      if (!triggered) {
        int depth = 0;
        focusedCtx.visitAncestorElements((el) {
          if (depth++ > 4 || triggered) return false;
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
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleKeyEvent,
      child: child,
    );
  }
}
