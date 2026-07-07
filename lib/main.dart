import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/i18n/strings.dart';
import 'core/i18n/lang_provider.dart';
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await vaultService.init();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const ProviderScope(child: SanctumApp()));
}

class SanctumApp extends ConsumerWidget {
  const SanctumApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(langProvider);
    return MaterialApp(
      title: 'Sanctum',
      debugShowCheckedModeBanner: false,
      theme: SanctumTheme.dark,
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
      if (next == AuthState.unlocked) { ref.read(inactivityProvider.notifier).resetTimer(); }
      else { ref.read(inactivityProvider.notifier).cancel(); }
    });
    return switch (auth) {
      AuthState.locked   => const LockScreen(),
      AuthState.loading  => const _LoadingScreen(),
      AuthState.unlocked => Listener(
        onPointerDown: (_) => ref.read(inactivityProvider.notifier).resetTimer(),
        child: const _MainShell(),
      ),
    };
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();
  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: SanctumTheme.bg,
    body: Center(child: CircularProgressIndicator(color: SanctumTheme.gold)),
  );
}

// ── Language selector ─────────────────────────────────────────
class LangSelector extends ConsumerWidget {
  const LangSelector({super.key});

  static const _langs = [
    ('zh', '繁中(港)'), ('zh-TW', '繁中(台)'), ('zh-SC', '简体中文'),
    ('en', 'EN'), ('ja', '日本語'), ('ko', '한국어'),
    ('fr', 'FR'), ('de', 'DE'), ('es', 'ES'), ('la', 'LAT'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(langProvider);
    return PopupMenuButton<String>(
      color: SanctumTheme.bg2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: SanctumTheme.border),
      ),
      onSelected: (lang) => ref.read(langProvider.notifier).setLang(lang),
      itemBuilder: (_) => _langs.map((l) => PopupMenuItem(
        value: l.$1,
        child: Row(children: [
          if (current == l.$1)
            const Icon(Icons.check, size: 14, color: SanctumTheme.gold)
          else
            const SizedBox(width: 14),
          const SizedBox(width: 8),
          Text(l.$2, style: const TextStyle(fontSize: 13, color: SanctumTheme.textPrimary)),
        ]),
      )).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: SanctumTheme.bg3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: SanctumTheme.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.language, size: 14, color: SanctumTheme.textTertiary),
          const SizedBox(width: 4),
          Text(current.toUpperCase(),
            style: const TextStyle(fontSize: 12, color: SanctumTheme.textTertiary)),
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

  // Tab indices
  static const _kPasswords  = 1;
  static const _kDiary      = 2;
  static const _kFinance    = 3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkSharedImage());
    _shareChannel.setMethodCallHandler((call) async {
      if (call.method == 'newSharedImage' && call.arguments is String) {
        _openSharedImage(call.arguments as String);
      }
    });
  }

  Future<void> _checkSharedImage() async {
    try {
      final path = await _shareChannel.invokeMethod<String>('getSharedImage');
      if (path != null && path.isNotEmpty && mounted) {
        _openSharedImage(path);
      }
    } catch (_) {}
  }

  void _openSharedImage(String path) {
    // Switch to finance tab and open preview
    setState(() => _tab = _kFinance);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ReceiptPreviewScreen(imageFile: File(path)),
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(langProvider);

    final screens = [
      DashboardScreen(
        onGoPasswords: () => _setTab(_kPasswords),
        onGoDiary:     () => _setTab(_kDiary),
        onGoFinance:   () => _setTab(_kFinance),
      ),
      const PasswordsScreen(),
      const DiaryScreen(),
      const FinanceScreen(),
      const SettingsScreen(),
    ];

    return Scaffold(
      backgroundColor: SanctumTheme.bg,
      appBar: AppBar(
        backgroundColor: SanctumTheme.bg2,
        elevation: 0,
        titleSpacing: 16,
        title: ShaderMask(
          shaderCallback: (b) => SanctumDecor.goldGradient().createShader(b),
          child: const Text('Sanctum', style: TextStyle(
            fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white,
          )),
        ),
        actions: [
          // Search
          IconButton(
            icon: const Icon(Icons.search, size: 20),
            color: SanctumTheme.textTertiary,
            onPressed: () {
              HapticFeedback.selectionClick();
              showSearch(context: context, delegate: _VaultSearchDelegate());
            },
          ),
          const LangSelector(),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.lock_outline, size: 20),
            color: SanctumTheme.textTertiary,
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
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: SanctumTheme.bg2,
      border: Border(top: BorderSide(color: SanctumTheme.border, width: 0.5)),
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _NavItem(icon: Icons.home_outlined,     activeIcon: Icons.home_rounded,
                label: '主頁',    index: 0, current: current, onTap: onTap),
            _NavItem(icon: Icons.key_outlined,       activeIcon: Icons.key_rounded,
                label: S.navPasswords, index: 1, current: current, onTap: onTap),
            _NavItem(icon: Icons.menu_book_outlined, activeIcon: Icons.menu_book_rounded,
                label: S.navDiary,     index: 2, current: current, onTap: onTap),
            _NavItem(icon: Icons.account_balance_wallet_outlined,
                activeIcon: Icons.account_balance_wallet_rounded,
                label: S.navFinance,   index: 3, current: current, onTap: onTap),
            _NavItem(icon: Icons.settings_outlined,  activeIcon: Icons.settings_rounded,
                label: S.navSettings,  index: 4, current: current, onTap: onTap),
          ],
        ),
      ),
    ),
  );
}

class _NavItem extends StatelessWidget {
  final IconData icon, activeIcon;
  final String label;
  final int index, current;
  final ValueChanged<int> onTap;
  const _NavItem({required this.icon, required this.activeIcon, required this.label,
      required this.index, required this.current, required this.onTap});

  @override
  Widget build(BuildContext context) {
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
              size: 22,
              color: active ? SanctumTheme.gold2 : SanctumTheme.textTertiary),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(
            fontSize: 10,
            color: active ? SanctumTheme.gold2 : SanctumTheme.textTertiary,
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
  String get searchFieldLabel => '搜尋密碼、日記、財務…';

  @override
  ThemeData appBarTheme(BuildContext context) => Theme.of(context).copyWith(
    appBarTheme: const AppBarTheme(backgroundColor: SanctumTheme.bg2, elevation: 0),
    inputDecorationTheme: const InputDecorationTheme(
      hintStyle: TextStyle(color: SanctumTheme.textTertiary),
      border: InputBorder.none,
    ),
    textTheme: const TextTheme(
      titleLarge: TextStyle(color: SanctumTheme.textPrimary, fontSize: 15),
    ),
  );

  @override
  List<Widget> buildActions(BuildContext context) => [
    if (query.isNotEmpty)
      IconButton(
        icon: const Icon(Icons.clear, size: 18, color: SanctumTheme.textTertiary),
        onPressed: () => query = '',
      ),
  ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
    icon: const Icon(Icons.arrow_back, size: 20, color: SanctumTheme.textTertiary),
    onPressed: () => close(context, ''),
  );

  @override
  Widget buildResults(BuildContext context) =>
      SearchScreen(initialQuery: query);

  @override
  Widget buildSuggestions(BuildContext context) =>
      SearchScreen(initialQuery: query.isEmpty ? null : query);
}
