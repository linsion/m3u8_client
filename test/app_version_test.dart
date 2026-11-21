import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3u8_client/state/app_state.dart';
import 'package:m3u8_client/ui/screens/login_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the login badge uses the installed package version', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: '流光视频',
      packageName: 'com.linsion.m3u8Client',
      version: '9.8.7',
      buildNumber: '654',
      buildSignature: '',
    );
    final state = AppState();
    addTearDown(state.dispose);
    await tester.runAsync(state.initialize);

    await tester.pumpWidget(MaterialApp(home: LoginScreen(appState: state)));
    expect(find.text('v9.8.7'), findsOneWidget);
    expect(state.appFullVersion, 'v9.8.7 (Build 654)');
  });
}
