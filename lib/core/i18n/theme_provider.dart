import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ThemeNotifier extends StateNotifier<ThemeMode> {
  static const _storage = FlutterSecureStorage();
  static const _key = 'sanctum_theme';

  ThemeNotifier(ThemeMode initial) : super(initial);

  Future<void> setTheme(ThemeMode mode) async {
    state = mode;
    await _storage.write(key: _key, value: _encode(mode));
  }

  static Future<ThemeMode> loadSaved() async {
    try {
      final val = await _storage.read(key: _key);
      return _decode(val);
    } catch (_) {
      return ThemeMode.system;
    }
  }

  static ThemeMode _decode(String? val) => switch (val) {
    'light'  => ThemeMode.light,
    'dark'   => ThemeMode.dark,
    _        => ThemeMode.system,
  };

  static String _encode(ThemeMode m) => switch (m) {
    ThemeMode.light  => 'light',
    ThemeMode.dark   => 'dark',
    _                => 'system',
  };
}

final themeProvider = StateNotifierProvider<ThemeNotifier, ThemeMode>(
  (_) => ThemeNotifier(ThemeMode.system),
);
