import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/i18n/strings.dart';
import 'core/i18n/lang_provider.dart';
import 'core/i18n/theme_provider.dart';
import 'core/security/sensitive_clipboard.dart';
import 'core/storage/providers.dart';
import 'core/storage/vault_service.dart';
import 'features/auth/screens/lock_screen.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/passwords/screens/passwords_screen.dart';
import 'features/diary/screens/diary_screen.dart';
import 'features/finance/screens/finance_screen.dart';
import 'features/finance/screens/receipt_preview_screen.dart';
import 'features/settings/screens/settings_screen.dart';
import 'features/search/search_screen.dart';
import 'shared/theme/app_theme.dart';

/// Wipes any sensitive value left on the clipboard when the app leaves the
/// foreground (RT-C-01/02/03) — independent of any screen's lifecycle.
class _ClipboardLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      SensitiveClipboard.instance.clearNow();
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WidgetsBinding.instance.addObserver(_ClipboardLifecycleObserver());
  await vaultService.init();
  final savedLang = await LangNotifier.loadSaved();
  final savedTheme = await ThemeNotifier.loadSaved();
  S.setLang(savedLang);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(ProviderScope(
    overrides: [
      langProvider.overrideWith((_) => LangNotifier(savedLang)),
      themeProvider.overrideWith((_) => ThemeNotifier(savedTheme)),
    ],
    child: const SanctumApp(),
  ));
}

class SanctumApp extends ConsumerWidget {
  const SanctumApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(langProvider);
    final themeMode = ref.watch(themeProvider);
    return MaterialApp(
      title: 'Sanctum',
      debugShowCheckedModeBanner: false,
      theme: SanctumTheme.light,
      darkTheme: SanctumTheme.dark,
      themeMode: themeMode,
      home: const _Root(),
    );
  }
}

class _Root extends ConsumerWidget {
  const _Root();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    ref.listen<AuthState>(authProvider, (_, next) {
      if (next == AuthState.unlocked) {
        ref.read(inactivityProvider.notifier).resetTimer();
      } else {
        ref.read(inactivityProvider.notifier).cancel();
      }
    });
    return switch (auth) {
      AuthState.locked => const LockScreen(),
      AuthState.loading => const _LoadingScreen(),
      AuthState.unlocked => Listener(
          onPointerDown: (_) =>
              ref.read(inactivityProvider.notifier).resetTimer(),
          child: const _MainShell(),
        ),
    };
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: context.sc.bg,
        body: const Center(
            child: CircularProgressIndicator(color: SanctumTheme.gold)),
      );
}

// ── Language selector ─────────────────────────────────────────
class LangSelector extends ConsumerWidget {
  const LangSelector({super.key});

  // Alpha: only the 6 fully-translated locales are user-selectable.
  // fr/de/es/la are hidden until their ~190 keys are populated (tracked
  // debt); their maps still exist and back the en-fallback chain.
  static const _langs = [
    ('zh', '繁中(港)'),
    ('zh-TW', '繁中(台)'),
    ('zh-SC', '简体中文'),
    ('en', 'EN'),
    ('ja', '日本語'),
    ('ko', '한국어'),
  ];

  static const _shortName = {
    'zh': '繁港',
    'zh-TW': '繁台',
    'zh-SC': '简体',
    'en': 'EN',
    'ja': '日',
    'ko': '한',
    'fr': 'FR',
    'de': 'DE',
    'es': 'ES',
    'la': 'LAT',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sc = context.sc;
    final current = ref.watch(langProvider);
    return PopupMenuButton<String>(
      color: sc.bg2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: sc.border),
      ),
      onSelected: (lang) => ref.read(langProvider.notifier).setLang(lang),
      itemBuilder: (_) => _langs
          .map((l) => PopupMenuItem(
                value: l.$1,
                child: Row(children: [
                  if (current == l.$1)
                    Icon(Icons.check, size: 14, color: SanctumTheme.gold)
                  else
                    const SizedBox(width: 14),
                  const SizedBox(width: 8),
                  Text(l.$2,
                      style: TextStyle(fontSize: 13, color: sc.textPrimary)),
                ]),
              ))
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: sc.bg3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: sc.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.language, size: 14, color: sc.textTertiary),
          const SizedBox(width: 4),
          Text(_shortName[current] ?? current.toUpperCase(),
              style: TextStyle(fontSize: 12, color: sc.textTertiary)),
        ]),
      ),
    );
  }
}

// ── Main shell ────────────────────────────────────────────────
class _MainShell extends ConsumerStatefulWidget {
  const _MainShell();
  @override
  ConsumerState<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<_MainShell> {
  int _tab = 0;
  static const _shareChannel = MethodChannel('com.sanctum.vault/share');
  final Set<String> _activeSharedImages = <String>{};

  // Tab indices
  static const _kPasswords = 1;
  static const _kDiary = 2;
  static const _kFinance = 3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkSharedImage());
    _shareChannel.setMethodCallHandler((call) async {
      if (call.method == 'newSharedImage' && call.arguments is String) {
        unawaited(_openSharedImage(call.arguments as String));
      } else if (call.method == 'sharedImageError' &&
          call.arguments is String) {
        _showSharedImageError(call.arguments as String);
      }
    });
  }

  Future<void> _checkSharedImage() async {
    try {
      final path = await _shareChannel.invokeMethod<String>('getSharedImage');
      if (path != null && path.isNotEmpty && mounted) {
        unawaited(_openSharedImage(path));
      }
    } on PlatformException catch (error) {
      _showSharedImageError(error.code);
    }
  }

  Future<void> _openSharedImage(String path) async {
    if (!_activeSharedImages.add(path)) return;
    try {
      if (!mounted) return;
      setState(() => _tab = _kFinance);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ReceiptPreviewScreen(imageFile: File(path)),
      ));
    } finally {
      _activeSharedImages.remove(path);
      try {
        await _shareChannel.invokeMethod<bool>('releaseSharedImage', path);
      } on PlatformException {
        // Startup cleanup remains the fallback if the native side is unavailable.
      }
    }
  }

  void _showSharedImageError(String code) {
    if (!mounted) return;
    final isChinese = Localizations.localeOf(context).languageCode == 'zh';
    final message = switch (code) {
      'too_large' => isChinese
          ? '圖片超過 10 MB 上限，請縮小後再試。'
          : 'The image exceeds the 10 MB limit. Reduce it and try again.',
      'timeout' => isChinese
          ? '讀取圖片逾時，請重新分享。'
          : 'Reading the image timed out. Please share it again.',
      'invalid_image' => isChinese
          ? '無法辨識這個圖片檔案。'
          : 'This file could not be recognized as an image.',
      'unsupported_uri' => isChinese
          ? '此分享來源不受支援，請改用其他圖片來源。'
          : 'This sharing source is not supported. Try another source.',
      'busy' => isChinese
          ? '正在處理另一張圖片，請稍後再試。'
          : 'Another image is being processed. Please try again shortly.',
      _ => isChinese
          ? '目前無法讀取圖片，請重新分享。'
          : 'The image is unavailable. Please share it again.',
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _shareChannel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(langProvider);
    final sc = context.sc;

    final screens = [
      DashboardScreen(
        onGoPasswords: () => _setTab(_kPasswords),
        onGoDiary: () => _setTab(_kDiary),
        onGoFinance: () => _setTab(_kFinance),
      ),
      const PasswordsScreen(),
      const DiaryScreen(),
      const FinanceScreen(),
      const SettingsScreen(),
    ];

    return Scaffold(
      backgroundColor: sc.bg,
      appBar: AppBar(
        backgroundColor: sc.bg2,
        elevation: 0,
        titleSpacing: 16,
        title: ShaderMask(
          shaderCallback: (b) => SanctumDecor.goldGradient().createShader(b),
          child: const Text('Sanctum',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              )),
        ),
        actions: [
          // Search
          IconButton(
            icon: const Icon(Icons.search, size: 20),
            color: sc.textTertiary,
            onPressed: () {
              HapticFeedback.selectionClick();
              showSearch(context: context, delegate: _VaultSearchDelegate());
            },
          ),
          const LangSelector(),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.lock_outline, size: 20),
            color: sc.textTertiary,
            onPressed: () {
              HapticFeedback.mediumImpact();
              ref.read(authProvider.notifier).lock();
            },
            tooltip: S.lockVault,
          ),
        ],
      ),
      body: IndexedStack(index: _tab, children: screens),
      bottomNavigationBar: _BottomNav(
        current: _tab,
        onTap: _setTab,
      ),
    );
  }

  void _setTab(int i) {
    HapticFeedback.selectionClick();
    setState(() => _tab = i);
  }
}

// ── Bottom navigation ─────────────────────────────────────────
class _BottomNav extends StatelessWidget {
  final int current;
  final ValueChanged<int> onTap;
  const _BottomNav({required this.current, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    return Container(
      decoration: BoxDecoration(
        color: sc.bg2,
        border: Border(top: BorderSide(color: sc.border, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _NavItem(
                  icon: Icons.home_outlined,
                  activeIcon: Icons.home_rounded,
                  label: S.navHome,
                  index: 0,
                  current: current,
                  onTap: onTap),
              _NavItem(
                  icon: Icons.key_outlined,
                  activeIcon: Icons.key_rounded,
                  label: S.navPasswords,
                  index: 1,
                  current: current,
                  onTap: onTap),
              _NavItem(
                  icon: Icons.menu_book_outlined,
                  activeIcon: Icons.menu_book_rounded,
                  label: S.navDiary,
                  index: 2,
                  current: current,
                  onTap: onTap),
              _NavItem(
                  icon: Icons.account_balance_wallet_outlined,
                  activeIcon: Icons.account_balance_wallet_rounded,
                  label: S.navFinance,
                  index: 3,
                  current: current,
                  onTap: onTap),
              _NavItem(
                  icon: Icons.settings_outlined,
                  activeIcon: Icons.settings_rounded,
                  label: S.navSettings,
                  index: 4,
                  current: current,
                  onTap: onTap),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon, activeIcon;
  final String label;
  final int index, current;
  final ValueChanged<int> onTap;
  const _NavItem(
      {required this.icon,
      required this.activeIcon,
      required this.label,
      required this.index,
      required this.current,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sc = context.sc;
    final active = index == current;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? SanctumTheme.goldDim : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(active ? activeIcon : icon,
              size: 22, color: active ? SanctumTheme.gold2 : sc.textTertiary),
          const SizedBox(height: 3),
          Text(label,
              style: TextStyle(
                fontSize: 10,
                color: active ? SanctumTheme.gold2 : sc.textTertiary,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              )),
        ]),
      ),
    );
  }
}

// ── Vault search delegate (uses existing SearchScreen logic) ──
class _VaultSearchDelegate extends SearchDelegate<String> {
  @override
  String get searchFieldLabel => S.searchHint;

  @override
  ThemeData appBarTheme(BuildContext context) {
    final sc = context.sc;
    return Theme.of(context).copyWith(
      appBarTheme: AppBarTheme(backgroundColor: sc.bg2, elevation: 0),
      inputDecorationTheme: InputDecorationTheme(
        hintStyle: TextStyle(color: sc.textTertiary),
        border: InputBorder.none,
      ),
      textTheme: TextTheme(
        titleLarge: TextStyle(color: sc.textPrimary, fontSize: 15),
      ),
    );
  }

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            icon: Icon(Icons.clear, size: 18, color: context.sc.textTertiary),
            onPressed: () => query = '',
          ),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: Icon(Icons.arrow_back, size: 20, color: context.sc.textTertiary),
        onPressed: () => close(context, ''),
      );

  @override
  Widget buildResults(BuildContext context) =>
      SearchScreen(initialQuery: query);

  @override
  Widget buildSuggestions(BuildContext context) =>
      SearchScreen(initialQuery: query.isEmpty ? null : query);
}
