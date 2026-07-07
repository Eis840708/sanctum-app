
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/i18n/strings.dart';
import '../../../core/i18n/lang_provider.dart';
import '../../../core/storage/providers.dart';
import '../../../shared/theme/app_theme.dart';
import 'backup_screen.dart';
import 'shamir_screen.dart';
import '../../transfer/screens/transfer_screen.dart';
import '../../../core/storage/vault_service.dart';
import '../../passwords/screens/import_passwords_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(langProvider);
    final autoLockSecs = ref.watch(inactivityTimeoutProvider);
    return CustomScrollView(slivers: [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        sliver: SliverToBoxAdapter(child: Text(S.settings, style: const TextStyle(
          fontSize: 22, fontWeight: FontWeight.w600,
          color: SanctumTheme.textPrimary, letterSpacing: -0.3,
        ))),
      ),
      SliverPadding(
        padding: const EdgeInsets.all(16),
        sliver: SliverList(delegate: SliverChildListDelegate([

          _Section(title: S.security, rows: [
            _Row(icon: Icons.shield_outlined, iconColor: SanctumTheme.purple,
              label: S.encryption,
              trailing: const Text('AES-256-GCM', style: TextStyle(fontSize: 12, color: SanctumTheme.textTertiary))),
            _Row(icon: Icons.key_outlined, iconColor: SanctumTheme.gold,
              label: S.keyDerivation,
              trailing: const Text('PBKDF2-SHA256', style: TextStyle(fontSize: 12, color: SanctumTheme.textTertiary))),
          _Row(
  icon: Icons.shield_moon_outlined,
iconColor: SanctumTheme.gold,
  label: '碎片備份',
  onTap: () => Navigator.push(context,
    MaterialPageRoute(builder: (_) => ShamirScreen())),
),
_Row(
  icon: Icons.lock_clock,
  iconColor: SanctumTheme.purple,
  label: '自動上鎖',
  trailing: Text(
    autoLockSecs == 0 ? '永不' : '$autoLockSecs 秒',
    style: const TextStyle(fontSize: 12, color: SanctumTheme.textTertiary),
  ),
  onTap: () {
    int cur = ref.read(inactivityTimeoutProvider);
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, ss) => AlertDialog(
          backgroundColor: SanctumTheme.bg2,
          title: const Text('自動上鎖', style: TextStyle(color: SanctumTheme.textPrimary)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(cur == 0 ? '永不' : '$cur 秒',
              style: const TextStyle(color: SanctumTheme.gold, fontSize: 20)),
            Slider(
              value: cur.toDouble(), min: 0, max: 120, divisions: 12,
              activeColor: SanctumTheme.gold,
              inactiveColor: SanctumTheme.border,
              onChanged: (v) => ss(() => cur = v.round()),
            ),
            const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('永不', style: TextStyle(color: SanctumTheme.textTertiary, fontSize: 11)),
                Text('120 秒', style: TextStyle(color: SanctumTheme.textTertiary, fontSize: 11)),
              ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('取消', style: TextStyle(color: SanctumTheme.textTertiary))),
            TextButton(
              onPressed: () {
                ref.read(inactivityTimeoutProvider.notifier).state = cur;
                if (cur > 0) ref.read(inactivityProvider.notifier).resetTimer();
                else ref.read(inactivityProvider.notifier).cancel();
                Navigator.pop(ctx);
              },
              child: const Text('確定', style: TextStyle(color: SanctumTheme.gold))),
          ],
        ),
      ),
    );
  },
),
]),

          const SizedBox(height: 20),

          _Section(title: S.backup, rows: [
            _Row(
              icon: Icons.backup_outlined, iconColor: SanctumTheme.blue,
              label: S.backupVault,
              sublabel: '本地備份 + 分享',
              trailing: const Icon(Icons.chevron_right, size: 18, color: SanctumTheme.textTertiary),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupScreen())),
            ),
            _Row(
              icon: Icons.download_outlined, iconColor: SanctumTheme.amber,
              label: S.restore,
              trailing: const Icon(Icons.chevron_right, size: 18, color: SanctumTheme.textTertiary),
              onTap: () => _showRestoreInfo(context),
            ),
            _Row(
              icon: Icons.swap_horiz_rounded, iconColor: SanctumTheme.gold,
              label: '換機轉移',
              sublabel: '透過 QR 碼安全轉移至新手機',
              trailing: const Icon(Icons.chevron_right, size: 18, color: SanctumTheme.textTertiary),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const TransferScreen())),
            ),
          ]),

          const SizedBox(height: 20),

          _Section(title: '資料管理', rows: [
            _Row(
              icon: Icons.download_outlined, iconColor: SanctumTheme.textSecondary,
              label: '匯入密碼（CSV）',
              trailing: const Icon(Icons.chevron_right, size: 18, color: SanctumTheme.textTertiary),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ImportPasswordsScreen())),
            ),
            _Row(
              icon: Icons.delete_forever_outlined, iconColor: SanctumTheme.red,
              label: S.clearData, labelColor: SanctumTheme.red,
              trailing: const Icon(Icons.chevron_right, size: 18, color: SanctumTheme.red),
              onTap: () => _clearAll(context, ref),
            ),
          ]),

          const SizedBox(height: 20),

          _Section(title: S.about, rows: [
            _Row(icon: Icons.info_outline, iconColor: SanctumTheme.textTertiary,
              label: S.version,
              trailing: const Text('Sanctum 1.5.0', style: TextStyle(fontSize: 12, color: SanctumTheme.textTertiary))),
            _Row(icon: Icons.cloud_off, iconColor: SanctumTheme.textTertiary,
              label: S.storage,
              trailing: Text(S.localOnly, style: const TextStyle(fontSize: 12, color: SanctumTheme.green))),
            _Row(icon: Icons.wifi_off, iconColor: SanctumTheme.textTertiary,
              label: S.network,
              trailing: Text(S.zeroRequests, style: const TextStyle(fontSize: 12, color: SanctumTheme.green))),
          ]),

          const SizedBox(height: 20),

          GestureDetector(
            onTap: () => ref.read(authProvider.notifier).lock(),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: SanctumTheme.bg2,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: SanctumTheme.border),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.lock_outline, size: 16, color: SanctumTheme.textSecondary),
                const SizedBox(width: 8),
                Text(S.lockVault, style: const TextStyle(fontSize: 15, color: SanctumTheme.textSecondary)),
              ]),
            ),
          ),
          const SizedBox(height: 32),
        ])),
      ),
    ]);
  }

  void _showRestoreInfo(BuildContext context) {
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: SanctumTheme.bg2,
      title: Text(S.restore, style: const TextStyle(color: SanctumTheme.textPrimary, fontSize: 16)),
      content: const Text(
        '找到你的 .vault 備份檔案，用 Sanctum 開啟，\n輸入主密鑰即可還原所有資料。',
        style: TextStyle(color: SanctumTheme.textSecondary, fontSize: 13, height: 1.6),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context),
          child: Text(S.confirm, style: const TextStyle(color: SanctumTheme.gold))),
      ],
    ));
  }

  void _clearAll(BuildContext context, WidgetRef ref) {
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: SanctumTheme.bg2,
      title: Text(S.clearData, style: const TextStyle(color: SanctumTheme.textPrimary)),
      content: Text(S.clearConfirm, style: const TextStyle(color: SanctumTheme.textSecondary, fontSize: 14, height: 1.5)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context),
          child: Text(S.cancel, style: const TextStyle(color: SanctumTheme.textSecondary))),
        TextButton(
          onPressed: () async {
                  Navigator.pop(context);
                  await vaultService.clearVault();
                  ref.read(authProvider.notifier).lock();
                },
          child: Text(S.delete, style: const TextStyle(color: SanctumTheme.red))),
      ],
    ));
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> rows;
  const _Section({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(title.toUpperCase(), style: const TextStyle(
          fontSize: 10, color: SanctumTheme.textTertiary, letterSpacing: 0.8)),
      ),
      Container(
        decoration: BoxDecoration(
          color: SanctumTheme.bg2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: SanctumTheme.border, width: 0.5),
        ),
        child: Column(children: rows.asMap().entries.map((e) => Column(children: [
          e.value,
          if (e.key < rows.length - 1) const Divider(height: 0.5, color: SanctumTheme.border, indent: 48),
        ])).toList()),
      ),
    ],
  );
}

class _Row extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String? sublabel;
  final Color labelColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _Row({
    required this.icon, required this.iconColor, required this.label,
    this.sublabel, this.labelColor = SanctumTheme.textPrimary,
    this.trailing, this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        Container(
          width: 28, height: 28,
          decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(7)),
          child: Icon(icon, size: 15, color: iconColor),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 14, color: labelColor)),
          if (sublabel != null)
            Text(sublabel!, style: const TextStyle(fontSize: 11, color: SanctumTheme.textTertiary)),
        ])),
        if (trailing != null) trailing!,
      ]),
    ),
  );
}
