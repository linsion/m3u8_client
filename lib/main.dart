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
            if (!appState.tvMode || child == null) return child ?? const SizedBox.shrink();
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.06),
              ),
              child: child,
            );
          },
          home: MainShell(appState: appState),
        );
      },
    );
  }
}
