import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'strings.dart';

class LangNotifier extends StateNotifier<String> {
  static const _storage = FlutterSecureStorage();
  static const _key = 'sanctum_lang';

  LangNotifier(String initial) : super(initial) {
    S.setLang(initial);
  }

  Future<void> setLang(String lang) async {
    S.setLang(lang);
    state = lang;
    await _storage.write(key: _key, value: lang);
  }

  /// Call before runApp() to pre-load saved language.
  static Future<String> loadSaved() async {
    try {
      return await _storage.read(key: _key) ?? 'zh';
    } catch (_) {
      return 'zh';
    }
  }
}

final langProvider = StateNotifierProvider<LangNotifier, String>(
  (_) => LangNotifier('zh'),
);
