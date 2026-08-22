import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/i18n/lang_provider.dart';
import '../../../core/i18n/strings.dart';
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

  // Pages built from central i18n (strings.dart). Rebuilt on lang change via
  // ref.watch(langProvider); S.get reflects the current locale.
  List<_Page> _buildPages() => [
    _Page(
      emoji: '🔐',
      title:    S.get('onbWelcomeTitle'),
      subtitle: S.get('tagline'),
      body:     S.get('onbWelcomeBody'),
    ),
    _Page(
      emoji: '🗝️',
      title:    S.get('onbKeyTitle'),
      subtitle: S.get('onbKeySub'),
      body:     S.get('onbKeyBody'),
    ),
    _Page(
      emoji: '📱',
      title:    S.get('onbTransferTitle'),
      subtitle: S.get('onbTransferSub'),
      body:     S.get('onbTransferBody'),
    ),
  ];

  void _next() {
    final pages = _buildPages();
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
    final pages = _buildPages();

    final btnLabel = _page == pages.length - 1
        ? S.get('onbGetStarted')
        : S.get('onbNext');
    final skipLabel = S.get('onbSkip');

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

  // Alpha: only the 6 fully-translated locales are selectable, matching the
  // main app's LangSelector. fr/de/es/la are hidden until their keys are filled.
  static const _langs = [
    ('zh', '繁中(港)'), ('zh-TW', '繁中(台)'), ('zh-SC', '简体中文'),
    ('en', 'EN'), ('ja', '日本語'), ('ko', '한국어'),
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
