import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'strings.dart';

class LangNotifier extends StateNotifier<String> {
  LangNotifier() : super('zh') {
    S.setLang('zh');
  }

  void setLang(String lang) {
    S.setLang(lang);
    state = lang;
  }
}

final langProvider = StateNotifierProvider<LangNotifier, String>(
  (_) => LangNotifier(),
);
