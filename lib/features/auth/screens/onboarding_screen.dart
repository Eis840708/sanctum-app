import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/i18n/lang_provider.dart';
import '../../../shared/theme/app_theme.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingState();
}

class _OnboardingState extends ConsumerState<OnboardingScreen> {
  final _pageCtrl = PageController();
  int _page = 0;

  // Pages defined as functions so they react to lang changes
  List<_Page> _buildPages(String lang) => [
    _Page(
      emoji: '🔐',
      title:    _t(lang, zh: '歡迎使用 Sanctum',          en: 'Welcome to Sanctum',            ja: 'Sanctumへようこそ',        ko: 'Sanctum에 오신 것을 환영합니다'),
      subtitle: _t(lang, zh: '你的私人加密金庫',            en: 'Your Private Encrypted Vault',  ja: 'プライベート暗号金庫',       ko: '개인 암호화 금고'),
      body:     _t(lang,
        zh: '保險庫記錄以 AES-256-GCM 加密，金鑰以 Argon2id 派生，\n完全離線儲存，不上傳任何雲端。\n你的資料只屬於你。',
        en: 'Vault records are encrypted with AES-256-GCM (keys derived with Argon2id).\nStored fully offline — nothing sent to the cloud.\nYour data belongs only to you.',
        ja: 'ボールト記録はAES-256-GCMで暗号化（鍵はArgon2idで導出）。\n完全オフライン保存、クラウド送信なし。\nあなたのデータはあなただけのもの。',
        ko: '보관소 기록은 AES-256-GCM으로 암호화됩니다 (키는 Argon2id로 파생).\n완전 오프라인 저장 — 클라우드 전송 없음.\n당신의 데이터는 오직 당신의 것입니다.',
      ),
    ),
    _Page(
      emoji: '🗝️',
      title:    _t(lang, zh: '一個主密鑰，保護一切',          en: 'One Key. Everything Protected.',   ja: '1つの鍵ですべてを守る',          ko: '하나의 키로 모든 것을 보호'),
      subtitle: _t(lang, zh: '密碼 · 日記 · 財務',           en: 'Passwords · Diary · Finance',      ja: 'パスワード・日記・財務',           ko: '비밀번호 · 일기 · 재정'),
      body:     _t(lang,
        zh: '用一個主密鑰解鎖整個金庫。\n內建密碼生成器，自動記錄財務，\n日記加密保存每個私密時刻。',
        en: 'One master key unlocks your entire vault.\nBuilt-in password generator, finance tracker,\nand encrypted diary for your private moments.',
        ja: '1つのマスターキーで金庫全体を解錠。\nパスワード生成器、家計簿、\n暗号化日記を内蔵。',
        ko: '하나의 마스터 키로 전체 금고를 잠금 해제.\n비밀번호 생성기, 재정 추적기,\n개인 순간을 위한 암호화 일기 내장.',
      ),
    ),
    _Page(
      emoji: '📱',
      title:    _t(lang, zh: '換機也不怕',                   en: 'Switch Phones Safely',             ja: '機種変更も安心',                  ko: '안전하게 폰 교체'),
      subtitle: _t(lang, zh: '安全轉移 · 即將推出',           en: 'Secure Transfer · Coming Soon',    ja: '安全転送 · 近日公開',              ko: '안전 전송 · 출시 예정'),
      body:     _t(lang,
        zh: '未來將可透過 QR 碼 + WiFi 在兩部手機間\n加密傳輸資料，不經過任何伺服器。\n（安全裝置轉移功能即將推出）',
        en: 'Soon you\'ll be able to move data between phones\nvia QR code + WiFi, encrypted, with no servers.\n(Secure device transfer — coming soon.)',
        ja: '将来、QRコード+WiFiで2台のスマートフォン間で\nデータを暗号化して転送できます。サーバー不要。\n（安全なデバイス転送は近日公開）',
        ko: '앞으로 QR 코드 + WiFi로 두 폰 간에\n데이터를 암호화하여 전송할 수 있습니다. 서버 없이.\n(안전한 기기 전송 — 출시 예정)',
      ),
    ),
  ];

  static String _t(String lang, {required String zh, required String en, required String ja, required String ko}) {
    switch (lang) {
      case 'ja': return ja;
      case 'ko': return ko;
      case 'en': case 'fr': case 'de': case 'es': case 'la': return en;
      default:   return zh; // zh, zh-TW, zh-SC all use zh content for onboarding
    }
  }

  void _next() {
    final pages = _buildPages(ref.read(langProvider));
    if (_page < pages.length - 1) {
      _pageCtrl.nextPage(duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
    } else {
      widget.onDone();
    }
  }

  @override
  void dispose() { _pageCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    final lang  = ref.watch(langProvider);
    final pages = _buildPages(lang);

    final btnLabel = _t(lang,
      zh: _page == pages.length - 1 ? '開始設置金庫' : '下一步',
      en: _page == pages.length - 1 ? 'Get Started' : 'Next',
      ja: _page == pages.length - 1 ? '始める' : '次へ',
      ko: _page == pages.length - 1 ? '시작하기' : '다음',
    );
    final skipLabel = _t(lang, zh: '跳過', en: 'Skip', ja: 'スキップ', ko: '건너뛰기');

    return Scaffold(
      backgroundColor: sc.bg,
      body: SafeArea(
        child: Column(children: [
          // Top bar: language selector + skip
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(children: [
              _LangPicker(current: lang, onSelect: (l) => ref.read(langProvider.notifier).setLang(l)),
              const Spacer(),
              TextButton(
                onPressed: widget.onDone,
                child: Text(skipLabel, style: TextStyle(fontSize: 13, color: sc.textTertiary)),
              ),
            ]),
          ),

          // Pages
          Expanded(
            child: PageView.builder(
              controller: _pageCtrl,
              onPageChanged: (i) => setState(() => _page = i),
              itemCount: pages.length,
              itemBuilder: (_, i) => _PageView(page: pages[i], active: _page == i),
            ),
          ),

          // Dots + button
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: List.generate(
                pages.length,
                (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: _page == i ? 20 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _page == i
                        ? SanctumTheme.gold
                        : sc.textTertiary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              )),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SanctumTheme.gold,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _next,
                  child: Text(btnLabel, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ── Inline language picker ─────────────────────────────────────
class _LangPicker extends StatelessWidget {
  final String current;
  final ValueChanged<String> onSelect;
  const _LangPicker({required this.current, required this.onSelect});

  static const _langs = [
    ('zh', '繁中(港)'), ('zh-TW', '繁中(台)'), ('zh-SC', '简体中文'),
    ('en', 'EN'), ('ja', '日本語'), ('ko', '한국어'),
    ('fr', 'FR'), ('de', 'DE'), ('es', 'ES'),
  ];

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return PopupMenuButton<String>(
      color: sc.bg2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: sc.border),
      ),
      onSelected: onSelect,
      itemBuilder: (_) => _langs.map((l) => PopupMenuItem(
        value: l.$1,
        child: Row(children: [
          if (current == l.$1) const Icon(Icons.check, size: 14, color: SanctumTheme.gold)
          else const SizedBox(width: 14),
          const SizedBox(width: 8),
          Text(l.$2, style: TextStyle(fontSize: 13, color: sc.textPrimary)),
        ]),
      )).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: sc.bg3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: sc.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.language, size: 14, color: SanctumTheme.gold),
          const SizedBox(width: 5),
          Text(current.toUpperCase(), style: TextStyle(fontSize: 12, color: sc.textSecondary)),
          const SizedBox(width: 3),
          Icon(Icons.expand_more, size: 14, color: sc.textTertiary),
        ]),
      ),
    );
  }
}

// ── Data ──────────────────────────────────────────────────────
class _Page {
  final String emoji, title, subtitle, body;
  const _Page({required this.emoji, required this.title, required this.subtitle, required this.body});
}

// ── Page view ─────────────────────────────────────────────────
class _PageView extends StatelessWidget {
  final _Page page;
  final bool active;
  const _PageView({required this.page, required this.active});

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          width: 100, height: 100,
          decoration: BoxDecoration(
            color: SanctumTheme.goldDim,
            shape: BoxShape.circle,
            border: Border.all(color: SanctumTheme.gold.withValues(alpha: 0.3), width: 1.5),
          ),
          child: Center(child: Text(page.emoji, style: const TextStyle(fontSize: 44))),
        )
          .animate(target: active ? 1 : 0)
          .scale(begin: const Offset(0.85, 0.85), end: const Offset(1, 1), duration: 400.ms, curve: Curves.elasticOut),

        const SizedBox(height: 32),

        Text(page.title, style: TextStyle(
          fontSize: 24, fontWeight: FontWeight.w700,
          color: sc.textPrimary, letterSpacing: -0.3,
        )).animate(target: active ? 1 : 0).fadeIn(duration: 350.ms, delay: 100.ms).slideY(begin: 0.1, end: 0),

        const SizedBox(height: 8),

        ShaderMask(
          shaderCallback: (b) => SanctumDecor.goldGradient().createShader(b),
          child: Text(page.subtitle, style: const TextStyle(
            fontSize: 14, fontWeight: FontWeight.w500,
            color: Colors.white, letterSpacing: 0.2,
          )),
        ).animate(target: active ? 1 : 0).fadeIn(duration: 350.ms, delay: 150.ms),

        const SizedBox(height: 24),

        Text(page.body,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: sc.textSecondary, height: 1.7, letterSpacing: 0.1),
        ).animate(target: active ? 1 : 0).fadeIn(duration: 400.ms, delay: 200.ms),
      ]),
    );
  }
}
