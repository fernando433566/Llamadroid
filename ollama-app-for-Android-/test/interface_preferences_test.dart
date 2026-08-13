import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('system language uses Spanish only for a Spanish device', () {
    expect(
      resolvedInterfaceLanguage('system', const [Locale('es', 'ES')]),
      'es',
    );
    expect(
      resolvedInterfaceLanguage('system', const [Locale('en', 'US')]),
      'en',
    );
    expect(
      resolvedInterfaceLanguage('system', const [Locale('fr', 'FR')]),
      'en',
    );
    expect(resolvedInterfaceLanguage('system', const []), 'en');
  });

  test('an explicit interface language overrides the device language', () {
    expect(
      resolvedInterfaceLanguage('en', const [Locale('es', 'ES')]),
      'en',
    );
    expect(
      resolvedInterfaceLanguage('es', const [Locale('en', 'US')]),
      'es',
    );
  });

  test('System appearance creates Material 3 themes from Android accent',
      () async {
    SharedPreferences.setMockInitialValues({'brightness': 'system'});
    final preferences = await SharedPreferences.getInstance();

    configureAppThemes(preferences, 0xff006c4c);

    expect(theme?.useMaterial3, isTrue);
    expect(themeDark?.useMaterial3, isTrue);
    expect(theme?.colorScheme.primary, isNot(Colors.black));
    expect(theme?.colorScheme.primary, isNot(Colors.white));
    expect(themeDark?.colorScheme.primary, isNot(Colors.black));
    expect(themeDark?.colorScheme.primary, isNot(Colors.white));
  });
}
