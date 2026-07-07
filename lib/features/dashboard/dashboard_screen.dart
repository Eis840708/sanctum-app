import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/models/models.dart';
import '../../core/storage/providers.dart';
import '../../shared/theme/app_theme.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  /// Callbacks to jump to another tab
  final VoidCallback onGoPasswords;
  final VoidCallback onGoDiary;
  final VoidCallback onGoFinance;

  const DashboardScreen({
    super.key,
    required this.onGoPasswords,
    required this.onGoDiary,
    required this.onGoFinance,
  });

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardState();
}

class _DashboardState extends ConsumerState<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(passwordsNotifierProvider.notifier).load();
      ref.read(diaryNotifierProvider.notifier).load();
      ref.read(financeNotifierProvider.notifier).load();
    });
  }

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 5)  return '夜深了';
    if (h < 12) return '早安';
    if (h < 18) return '午安';
    return '晚安';
  }

  @override
  Widget build(BuildContext context) {
    final passwords = ref.watch(passwordsNotifierProvider);
    final diary     = ref.watch(diaryNotifierProvider);
    final finance   = ref.watch(financeNotifierProvider);

    final pwList  = passwords.valueOrNull ?? [];
    final diList  = diary.valueOrNull ?? [];
    final fiList  = finance.valueOrNull ?? [];

    // Security health
    final now = DateTime.now();
    final expiredPw  = pwList.where((p) => now.difference(p.updatedAt).inDays >= 180).length;
    final warningPw  = pwList.where((p) {
      final d = now.difference(p.updatedAt).inDays;
      return d >= 90 && d < 180;
    }).length;

    // Finance this month
    final thisMonth = fiList.where((r) =>
        r.date.year == now.year && r.date.month == now.month);
    final monthIncome  = thisMonth.where((r) => r.isIncome).fold(0.0, (s, r) => s + r.amount);
    final monthExpense = thisMonth.where((r) => !r.isIncome).fold(0.0, (s, r) => s + r.amount);

    return CustomScrollView(slivers: [
      // ── Header ─────────────────────────────────────────────
      SliverToBoxAdapter(
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          decoration: const BoxDecoration(
            color: SanctumTheme.bg2,
            border: Border(bottom: BorderSide(color: SanctumTheme.border, width: 0.5)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_greeting, style: const TextStyle(
                    fontSize: 13, color: SanctumTheme.textTertiary)),
                const SizedBox(height: 2),
                ShaderMask(
                  shaderCallback: (b) => SanctumDecor.goldGradient().createShader(b),
                  child: const Text('Sanctum', style: TextStyle(
                    fontSize: 26, fontWeight: FontWeight.w700,
                    color: Colors.white, letterSpacing: -0.5,
                  )),
                ),
              ]),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: SanctumTheme.green.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: SanctumTheme.green.withValues(alpha: 0.25)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 6, height: 6,
                    decoration: const BoxDecoration(color: SanctumTheme.green, shape: BoxShape.circle),
                  ).animate(onPlay: (c) => c.repeat()).fadeOut(duration: 900.ms).then().fadeIn(duration: 900.ms),
                  const SizedBox(width: 6),
                  const Text('已加密保護', style: TextStyle(
                      fontSize: 11, color: SanctumTheme.green)),
                ]),
              ),
            ]),
            const SizedBox(height: 20),

            // Stats row
            Row(children: [
              _StatChip(
                icon: Icons.key_rounded, color: SanctumTheme.purple,
                value: '${pwList.length}', label: '密碼',
                onTap: widget.onGoPasswords,
              ),
              const SizedBox(width: 10),
              _StatChip(
                icon: Icons.menu_book_rounded, color: SanctumTheme.blue,
                value: '${diList.length}', label: '日記',
                onTap: widget.onGoDiary,
              ),
              const SizedBox(width: 10),
              _StatChip(
                icon: Icons.account_balance_wallet_rounded, color: SanctumTheme.green,
                value: monthIncome > 0 || monthExpense > 0
                    ? (monthIncome - monthExpense >= 0 ? '+' : '') +
                      NumberFormat('#,##0').format(monthIncome - monthExpense)
                    : '—',
                label: '本月結餘',
                onTap: widget.onGoFinance,
              ),
            ]),
          ]),
        ).animate().fadeIn(duration: 400.ms),
      ),

      SliverPadding(
        padding: const EdgeInsets.all(16),
        sliver: SliverList(delegate: SliverChildListDelegate([

          // ── Security health ─────────────────────────────────
          if (expiredPw > 0 || warningPw > 0) ...[
            _SecurityCard(expired: expiredPw, warning: warningPw,
                onTap: widget.onGoPasswords),
            const SizedBox(height: 16),
          ],

          // ── Recent passwords ────────────────────────────────
          if (pwList.isNotEmpty) ...[
            _SectionTitle(
              title: '最近密碼',
              action: TextButton(
                onPressed: widget.onGoPasswords,
                child: const Text('查看全部', style: TextStyle(
                    fontSize: 12, color: SanctumTheme.gold)),
              ),
            ),
            ...pwList.take(3).map((p) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _RecentPasswordRow(entry: p),
            )),
            const SizedBox(height: 8),
          ],

          // ── Recent diary ────────────────────────────────────
          if (diList.isNotEmpty) ...[
            _SectionTitle(
              title: '最近日記',
              action: TextButton(
                onPressed: widget.onGoDiary,
                child: const Text('查看全部', style: TextStyle(
                    fontSize: 12, color: SanctumTheme.gold)),
              ),
            ),
            _RecentDiaryCard(entry: diList.first),
            const SizedBox(height: 16),
          ],

          // ── Finance summary ──────────────────────────────────
          if (fiList.isNotEmpty) ...[
            _SectionTitle(
              title: '本月財務',
              action: TextButton(
                onPressed: widget.onGoFinance,
                child: const Text('查看全部', style: TextStyle(
                    fontSize: 12, color: SanctumTheme.gold)),
              ),
            ),
            _MonthFinanceCard(income: monthIncome, expense: monthExpense),
            const SizedBox(height: 16),
          ],

          // ── Empty state ──────────────────────────────────────
          if (pwList.isEmpty && diList.isEmpty && fiList.isEmpty)
            _WelcomeCard(
              onGoPasswords: widget.onGoPasswords,
              onGoDiary: widget.onGoDiary,
              onGoFinance: widget.onGoFinance,
            ),

          const SizedBox(height: 20),
        ])),
      ),
    ]);
  }
}

// ── Section title ─────────────────────────────────────────────
class _SectionTitle extends StatelessWidget {
  final String title;
  final Widget? action;
  const _SectionTitle({required this.title, this.action});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(children: [
      Text(title, style: const TextStyle(
          fontSize: 13, fontWeight: FontWeight.w600,
          color: SanctumTheme.textSecondary, letterSpacing: 0.2)),
      const Spacer(),
      if (action != null) action!,
    ]),
  );
}

// ── Stat chip ─────────────────────────────────────────────────
class _StatChip extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String value, label;
  final VoidCallback onTap;

  const _StatChip({required this.icon, required this.color,
      required this.value, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => Expanded(
    child: GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 8),
          Text(value, style: TextStyle(
              fontSize: 18, fontWeight: FontWeight.w700, color: color)),
          Text(label, style: const TextStyle(
              fontSize: 10, color: SanctumTheme.textTertiary)),
        ]),
      ),
    ),
  );
}

// ── Security health card ──────────────────────────────────────
class _SecurityCard extends StatelessWidget {
  final int expired, warning;
  final VoidCallback onTap;
  const _SecurityCard({required this.expired, required this.warning, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: SanctumTheme.red.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SanctumTheme.red.withValues(alpha: 0.25)),
      ),
      child: Row(children: [
        const Icon(Icons.security_outlined, size: 20, color: SanctumTheme.red),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('密碼安全提示', style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: SanctumTheme.red)),
          const SizedBox(height: 3),
          Text([
            if (expired > 0) '$expired 個密碼已過期（>180天）',
            if (warning > 0) '$warning 個密碼建議更新（>90天）',
          ].join('，'), style: const TextStyle(
              fontSize: 11, color: SanctumTheme.textSecondary, height: 1.4)),
        ])),
        const Icon(Icons.arrow_forward_ios, size: 12, color: SanctumTheme.textTertiary),
      ]),
    ).animate().fadeIn(duration: 400.ms, delay: 100.ms).slideY(begin: 0.05),
  );
}

// ── Recent password row ───────────────────────────────────────
class _RecentPasswordRow extends StatelessWidget {
  final PasswordEntry entry;
  const _RecentPasswordRow({required this.entry});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: SanctumTheme.bg2,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: SanctumTheme.border, width: 0.5),
    ),
    child: Row(children: [
      Container(
        width: 32, height: 32,
        decoration: BoxDecoration(
          color: SanctumTheme.purpleDim,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(entry.site.isNotEmpty ? entry.site[0].toUpperCase() : '?',
            style: const TextStyle(fontSize: 14, color: SanctumTheme.purple,
                fontWeight: FontWeight.w600)),
      ),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(entry.site, style: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w500, color: SanctumTheme.textPrimary)),
        Text(entry.username, style: const TextStyle(
            fontSize: 11, color: SanctumTheme.textTertiary)),
      ])),
      Text(_relDays(entry.updatedAt),
          style: const TextStyle(fontSize: 11, color: SanctumTheme.textTertiary)),
    ]),
  ).animate().fadeIn(duration: 350.ms).slideX(begin: -0.03);

  String _relDays(DateTime dt) {
    final d = DateTime.now().difference(dt).inDays;
    if (d == 0) return '今天';
    if (d == 1) return '昨天';
    if (d < 30) return '$d 天前';
    return '${d ~/ 30} 個月前';
  }
}

// ── Recent diary card ─────────────────────────────────────────
class _RecentDiaryCard extends StatelessWidget {
  final DiaryEntry entry;
  const _RecentDiaryCard({required this.entry});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: SanctumTheme.bg2,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SanctumTheme.border, width: 0.5),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(entry.mood, style: const TextStyle(fontSize: 24)),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(entry.title, style: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w500, color: SanctumTheme.textPrimary)),
        const SizedBox(height: 3),
        Text(DateFormat('M月d日').format(entry.createdAt),
            style: const TextStyle(fontSize: 11, color: SanctumTheme.textTertiary)),
      ])),
    ]),
  ).animate().fadeIn(duration: 350.ms);
}

// ── Month finance card ────────────────────────────────────────
class _MonthFinanceCard extends StatelessWidget {
  final double income, expense;
  const _MonthFinanceCard({required this.income, required this.expense});

  @override
  Widget build(BuildContext context) {
    final net = income - expense;
    final fmt = NumberFormat('#,##0.##');
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: SanctumTheme.bg2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SanctumTheme.border, width: 0.5),
      ),
      child: Row(children: [
        Expanded(child: _FinStat(label: '收入', value: '+${fmt.format(income)}', color: SanctumTheme.green)),
        Container(width: 0.5, height: 40, color: SanctumTheme.border),
        Expanded(child: _FinStat(label: '支出', value: '−${fmt.format(expense)}', color: SanctumTheme.red)),
        Container(width: 0.5, height: 40, color: SanctumTheme.border),
        Expanded(child: _FinStat(
          label: '結餘',
          value: '${net >= 0 ? '+' : '−'}${fmt.format(net.abs())}',
          color: net >= 0 ? SanctumTheme.blue : SanctumTheme.red,
        )),
      ]),
    ).animate().fadeIn(duration: 350.ms);
  }
}

class _FinStat extends StatelessWidget {
  final String label, value;
  final Color color;
  const _FinStat({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Column(children: [
    Text(label, style: const TextStyle(fontSize: 10, color: SanctumTheme.textTertiary)),
    const SizedBox(height: 4),
    Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color)),
  ]);
}

// ── Welcome card (empty vault) ────────────────────────────────
class _WelcomeCard extends StatelessWidget {
  final VoidCallback onGoPasswords, onGoDiary, onGoFinance;
  const _WelcomeCard({required this.onGoPasswords,
      required this.onGoDiary, required this.onGoFinance});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: SanctumTheme.bg2,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: SanctumTheme.border),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('開始使用 Sanctum', style: TextStyle(
          fontSize: 16, fontWeight: FontWeight.w600, color: SanctumTheme.textPrimary)),
      const SizedBox(height: 16),
      ...[
        (Icons.key_rounded, SanctumTheme.purple, '儲存第一個密碼', onGoPasswords),
        (Icons.menu_book_rounded, SanctumTheme.blue, '寫下第一篇日記', onGoDiary),
        (Icons.account_balance_wallet_rounded, SanctumTheme.green, '記錄第一筆交易', onGoFinance),
      ].map((item) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: GestureDetector(
          onTap: () { HapticFeedback.selectionClick(); item.$4(); },
          child: Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: item.$2.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(item.$1, size: 18, color: item.$2),
            ),
            const SizedBox(width: 12),
            Text(item.$3, style: const TextStyle(
                fontSize: 13, color: SanctumTheme.textSecondary)),
            const Spacer(),
            Icon(Icons.arrow_forward_ios, size: 12,
                color: SanctumTheme.textTertiary.withValues(alpha: 0.5)),
          ]),
        ),
      )),
    ]),
  ).animate().fadeIn(duration: 500.ms).slideY(begin: 0.05);
}
